# Shared bash helpers for the bootstrap-producer bats suites
# (T012-T016 + T021).
#
# Source from each .bats file's setup() with:
#   load 'lib/bootstrap-helpers'

# Path to the orchestrator under test, relative to the repo root.
BOOTSTRAP_PRODUCER_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/bootstrap-producer.sh"

# REPO_ROOT is the absolute path to the repo containing this test file.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# make_valid_inputs <tmp-dir>
#
# Materialise a structurally valid input layout under <tmp-dir>:
#
#   <tmp-dir>/chain-db/        — populated below if needed (callers
#                                 typically point this at a real
#                                 synthesised chain DB)
#   <tmp-dir>/config/          — copy of the testnet_42 fixture's
#                                 configs (config.json + genesis files)
#   <tmp-dir>/bundle/          — empty output dir
#
# Tests that need a *real* chain DB (T015 idempotent, T021 live) wire
# it via env vars set by the surrounding Nix check; pure bats invocations
# without those env vars exercise the empty-mount paths (T013).
make_valid_inputs() {
  local tmp="$1"
  mkdir -p "$tmp/chain-db" "$tmp/bundle"
  cp -r "${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config/configs/configs" \
        "$tmp/config"
  chmod -R u+w "$tmp"
}

# break_config <config-dir> <relpath>
#
# Make an otherwise-valid config invalid by removing one required file.
break_config() {
  local cfg="$1"
  local relpath="$2"
  rm -f "${cfg}/${relpath}"
}

# malform_config <config-dir>
#
# Replace config.json with non-JSON garbage.
malform_config() {
  local cfg="$1"
  printf 'not json\n' >"${cfg}/config.json"
}

# zero_epoch_length <config-dir>
#
# Rewrite the shelley-genesis.json so epochLength is zero (config-error
# rc=3 territory).
zero_epoch_length() {
  local cfg="$1"
  local genesis="${cfg}/shelley-genesis.json"
  jq '.epochLength = 0' "$genesis" >"${genesis}.tmp"
  mv "${genesis}.tmp" "$genesis"
}

# make_live_node_inputs <tmp-dir>
#
# Materialise a cardano-node 10.7.1-compatible copy of the vendored
# testnet_42 fixture. The checked-in fixture stays unchanged; this
# temporary copy adds the Dijkstra genesis pointer required by the
# official node 10.7.1 image.
#
#   * DijkstraGenesisFile, required by node 10.7.1
#   * P2P target peer counts, so one block producer can run alone
#
# This preserves the shape that matters for the bootstrap-producer
# contract: the producer reads a node-10.7.1 ChainDB while the official
# node has it open.
make_live_node_inputs() {
  local tmp="$1"

  mkdir -p "$tmp/state" "$tmp/ipc" "$tmp/bundle"
  cp -r "${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config/configs/configs" \
        "$tmp/config"
  cp -r "${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config/configs/keys" \
        "$tmp/keys"
  chmod -R u+w "$tmp"
  chmod -R go-rwx "$tmp/keys"

  jq \
    '.DijkstraGenesisFile = "dijkstra-genesis.json"
     | .EnableP2P = true
     | .PeerSharing = false
     | .TargetNumberOfRootPeers = 0
     | .TargetNumberOfKnownPeers = 0
     | .TargetNumberOfEstablishedPeers = 0
     | .TargetNumberOfActivePeers = 0
     | .TargetNumberOfKnownBigLedgerPeers = 0
     | .TargetNumberOfEstablishedBigLedgerPeers = 0
     | .TargetNumberOfActiveBigLedgerPeers = 0' \
    "$tmp/config/config.json" \
    >"$tmp/config/config.json.tmp"
  mv "$tmp/config/config.json.tmp" "$tmp/config/config.json"

  printf '{"localRoots":[],"publicRoots":[],"useLedgerAfterSlot":0}\n' \
    >"$tmp/config/topology.json"
}

# make_short_epoch_node_inputs <tmp-dir>
#
# Variant of make_live_node_inputs for issue #34's failure boundary:
# the cardano-node grows its own chain organically at the antithesis
# short-epoch params (epochLength=120, securityParam=8,
# activeSlotsCoeff=1.0). The chain is NOT pre-synthesized — the node
# mints blocks across wall-clock time, which is the exact path that
# blew up amaru consumption in lambdasistemi/amaru-bootstrap#34.
#
# Synthesized short-epoch coverage already exists in
# nix/checks.nix's antithesis-short-epoch-* checks; this helper is
# specifically the *non-synthesized* live-node path.
make_short_epoch_node_inputs() {
  local tmp="$1"

  make_live_node_inputs "$tmp"

  # Genesis start instant: a few seconds in the past, so when the
  # node opens its DB it is just past genesis and can begin minting
  # blocks immediately. The vendored fixture's systemStart is months
  # ago — that triggers cardano-node's "Too far from the chain tip"
  # warning and the node never mints. Rewrite both byron startTime
  # and shelley systemStart to the same instant.
  local start_epoch start_iso
  start_epoch="$(($(date -u +%s) - 5))"
  start_iso="$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)"

  # Byron's protocolConsts.k is the toplevel security parameter the
  # HFC uses to gate immutable-flush across all configured eras. The
  # vendored fixture sets it to 432, which means nothing ever moves
  # past the volatile DB on a fresh-grown short-epoch chain — header-
  # extractor then sees "tip is at genesis" forever. Match Byron's k
  # to shelley securityParam (8) so the immutable boundary tracks
  # the active short-epoch params.
  jq \
    --argjson start "$start_epoch" \
    '.startTime = $start | .protocolConsts.k = 8' \
    "$tmp/config/byron-genesis.json" \
    >"$tmp/config/byron-genesis.json.tmp"
  mv "$tmp/config/byron-genesis.json.tmp" \
    "$tmp/config/byron-genesis.json"

  jq \
    --arg start "$start_iso" \
    '
      .systemStart = $start
      | .epochLength = 120
      | .securityParam = 8
      | .activeSlotsCoeff = 1.0
    ' "$tmp/config/shelley-genesis.json" \
    >"$tmp/config/shelley-genesis.json.tmp"
  mv "$tmp/config/shelley-genesis.json.tmp" \
    "$tmp/config/shelley-genesis.json"
}

# synthesize_live_chain_db <tmp-dir> [slots]
#
# Seed the node state directory with an era-ready testnet_42 ChainDB
# using the same stock db-synthesizer path as the pure flake checks.
# This keeps Amaru's fixed testnet_42 epoch/network assumptions intact
# while still letting the live verifier run the official cardano-node
# image with the DB open concurrently.
synthesize_live_chain_db() {
  local tmp="$1"
  local slots="${2:-300000}"
  local bulk="$tmp/bulk-credentials.json"

  jq -n \
    --slurpfile opcert "$tmp/keys/opcert.cert" \
    --slurpfile vrf "$tmp/keys/vrf.skey" \
    --slurpfile kes "$tmp/keys/kes.skey" \
    '[[ $opcert[0], $vrf[0], $kes[0] ]]' \
    >"$bulk"

  db-synthesizer \
    --config "$tmp/config/config.json" \
    --bulk-credentials-file "$bulk" \
    -s "$slots" \
    --db "$tmp/state/db" \
    -f

  # db-synthesizer does not create the node DB marker, but
  # cardano-node 10.7.1 refuses to open a non-empty DB without it.
  jq -r '.networkMagic' "$tmp/config/shelley-genesis.json" \
    >"$tmp/state/db/protocolMagicId"

  # The synthesizer's ledger snapshot directory is useful to analyser
  # tools but is not a reliable on-disk LedgerDB seed for the official
  # cardano-node image. Let the node rebuild its own LedgerDB from the
  # immutable DB so the live verifier exercises the same hand-off a
  # running node would own.
  rm -rf "$tmp/state/db/ledger"
}

# wait_for_node_n2n_port <container> <retries>
#
# Poll `docker port "$container" 3001/tcp` until docker reports a
# published host port for the cardano-node N2N socket. On success,
# print the host port (e.g. "32789") on stdout and return 0. On
# failure (container not publishing within <retries> seconds), return
# 1 and emit a diagnostic line on stderr. Mirrors the polling shape
# of wait_for_node_socket.
#
# This is the bridge that lets a host-side amaru dial the live node
# container (005-amaru-run-live-test, R-1).
wait_for_node_n2n_port() {
  local name="$1"
  local retries="${2:-60}"
  local mapping host_port
  local i=0

  while [[ $i -lt $retries ]]; do
    mapping="$(docker port "$name" 3001/tcp 2>/dev/null || true)"
    if [[ -n "$mapping" ]]; then
      # docker port output: "0.0.0.0:32789" or "127.0.0.1:32789"; one
      # mapping per line for IPv4 + IPv6. Take the first IPv4 entry.
      host_port="$(printf '%s\n' "$mapping" \
        | awk -F: '/^([0-9]+\.){3}[0-9]+:/ {print $NF; exit}')"
      if [[ -n "$host_port" ]]; then
        printf '%s\n' "$host_port"
        return 0
      fi
    fi
    i=$((i + 1))
    sleep 1
  done

  printf 'wait_for_node_n2n_port: %s did not publish 3001/tcp within %ss\n' \
    "$name" "$retries" >&2
  return 1
}

# parse_hold_window_seconds
#
# Read BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS, default 60. Validate it is
# a positive integer and print it on stdout. On malformed input emit
# an error to stderr and return 1.
parse_hold_window_seconds() {
  local raw="${BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS:-60}"
  if [[ ! "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf 'parse_hold_window_seconds: invalid BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS=%q (want positive integer)\n' \
      "$raw" >&2
    return 1
  fi
  printf '%s\n' "$raw"
}

# start_amaru_run <bundle-dir> <peer-host-port> <log-path>
#
# Background the flake-pinned `amaru run` against the bootstrap bundle
# at <bundle-dir>, peering with 127.0.0.1:<peer-host-port>. Combined
# stdout+stderr go to <log-path>. Print the child PID on stdout. CLI
# shape mirrors nix/checks.nix's amaru-run-bootstrap (line 435), with
# the dummy peer replaced by the real published port.
start_amaru_run() {
  local bundle="$1"
  local peer_port="$2"
  local log="$3"

  local extra=()
  if [[ -f "$bundle/era-history.json" ]]; then
    extra+=(--era-history-file "$bundle/era-history.json")
  fi
  if [[ -f "$bundle/global-parameters.json" ]]; then
    extra+=(--global-parameters-file "$bundle/global-parameters.json")
  fi

  amaru --with-json-traces run \
    --network testnet_42 \
    --ledger-dir "$bundle/ledger.testnet_42.db" \
    --chain-dir "$bundle/chain.testnet_42.db" \
    --listen-address 127.0.0.1:0 \
    --peer-address "127.0.0.1:$peer_port" \
    "${extra[@]}" \
    >"$log" 2>&1 &
  printf '%s\n' "$!"
}

# assert_amaru_alive <pid>
#
# Return 0 if the process is alive, 1 otherwise. Thin wrapper around
# `kill -0` so callers can attach richer messaging without
# duplicating the probe.
assert_amaru_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

# scan_amaru_log_for_fatal <log-path>
#
# Grep -F the four fatal substrings from the failure-classes contract
# in declaration order. On the first match: print the class label on
# stdout, emit the labelled context block on stderr, return 0. No
# match: return 1.
#
# Class table (must stay in lockstep with
# specs/005-amaru-run-live-test/contracts/failure-classes.md):
#   "Invalid VRF proof"      -> vrf
#   "Consensus died"         -> consensus
#   "HeaderValidationError"  -> header
#   "ledger inconsistency"   -> rollback
scan_amaru_log_for_fatal() {
  local log="$1"
  [[ -f "$log" ]] || return 1

  local -a classes=(vrf consensus header rollback)
  local -a needles=(
    'Invalid VRF proof'
    'Consensus died'
    'HeaderValidationError'
    'ledger inconsistency'
  )

  local i
  for i in "${!classes[@]}"; do
    if grep -F -q -- "${needles[$i]}" "$log"; then
      printf '%s\n' "${classes[$i]}"
      {
        printf -- '--- amaru consume failure: %s ---\n' "${classes[$i]}"
        grep -F -n -B2 -A2 -- "${needles[$i]}" "$log" | head -n 50
        printf -- '--- end amaru consume failure ---\n'
      } >&2
      return 0
    fi
  done
  return 1
}

# report_amaru_exited_early <log-path> <elapsed> <hold>
#
# Emit the "exited-early" diagnostic block on stderr per
# contracts/failure-classes.md. Used when amaru's process is gone
# before the hold window elapses AND no fatal substring matched.
report_amaru_exited_early() {
  local log="$1"
  local elapsed="$2"
  local hold="$3"
  {
    printf -- '--- amaru consume failure: exited-early ---\n'
    printf 'amaru process exited before hold window (%ss of %ss)\n' \
      "$elapsed" "$hold"
    printf -- '--- amaru tail (last 50 lines) ---\n'
    if [[ -f "$log" ]]; then
      tail -n 50 "$log"
    else
      printf '(no log file at %s)\n' "$log"
    fi
    printf -- '--- end amaru consume failure ---\n'
  } >&2
}

# stop_amaru_run <pid>
#
# SIGTERM the amaru process and wait for it to exit. Tolerates an
# empty pid (defaulted from a never-set AMARU_PID) and a process that
# has already exited. Used by both the happy-path consume block and
# the test-level teardown reaper.
stop_amaru_run() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# docker_rm_worktree <tmp-dir> <image>
#
# cardano-node writes root-owned DB files when run from the official
# image. Remove them from a short-lived root container so local and CI
# test cleanup does not leave root-owned trash behind.
docker_rm_worktree() {
  local tmp="$1"
  local image="$2"
  docker run --rm --entrypoint sh -v "$tmp:/work" "$image" \
    -c 'rm -rf /work/*' >/dev/null 2>&1 || true
  rm -rf "$tmp" || true
}
