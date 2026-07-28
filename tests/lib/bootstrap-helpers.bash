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

# derive_amaru_global_env <config-dir>
#
# Derive and export all seven AMARU_GLOBAL_* overrides from the same
# temporary genesis the source node runs on, using the arithmetic in
# scripts/bootstrap-producer.sh:202-215. The consumer must receive
# the identical parameter set the producer used at bundle-build time;
# a SYSTEM_START mismatch is the direct route to a self-inflicted
# roll-back-in-the-future.
derive_amaru_global_env() {
  local cfg="$1"
  local shelley="$cfg/shelley-genesis.json"
  local byron="$cfg/byron-genesis.json"

  local k active inverse epoch_len scale
  k="$(jq -r '.securityParam // empty' "$shelley")"
  active="$(jq -r '.activeSlotsCoeff // empty' "$shelley")"
  epoch_len="$(jq -r '.epochLength // empty' "$shelley")"

  if [[ ! "$k" =~ ^[0-9]+$ ]] || [[ -z "$active" ]] \
    || [[ ! "$epoch_len" =~ ^[0-9]+$ ]]; then
    printf 'derive_amaru_global_env: missing securityParam/activeSlotsCoeff/epochLength\n' >&2
    return 1
  fi

  inverse="$(jq -n --argjson f "$active" '(1 / $f) | round')"
  if [[ ! "$inverse" =~ ^[0-9]+$ ]] || (( inverse == 0 )) \
    || (( epoch_len % (k * inverse) != 0 )); then
    printf 'derive_amaru_global_env: epochLength %s not representable as (1/f)*scale*k (k=%s 1/f=%s)\n' \
      "$epoch_len" "$k" "$inverse" >&2
    return 1
  fi
  scale=$(( epoch_len / (k * inverse) ))

  export AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM="$k"
  export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE="$inverse"
  export AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR="$scale"

  local max_lovelace kes_period kes_evol system_start_sec
  max_lovelace="$(jq -r '.maxLovelaceSupply // empty' "$shelley")"
  kes_period="$(jq -r '.slotsPerKESPeriod // empty' "$shelley")"
  kes_evol="$(jq -r '.maxKESEvolutions // empty' "$shelley")"
  system_start_sec="$(jq -r '.startTime // 0' "$byron" 2>/dev/null || echo 0)"

  [[ -n "$max_lovelace" ]] && export AMARU_GLOBAL_MAX_LOVELACE_SUPPLY="$max_lovelace"
  [[ -n "$kes_period" ]]   && export AMARU_GLOBAL_SLOTS_PER_KES_PERIOD="$kes_period"
  [[ -n "$kes_evol" ]]     && export AMARU_GLOBAL_MAX_KES_EVOLUTION="$kes_evol"
  export AMARU_GLOBAL_SYSTEM_START="$(( system_start_sec * 1000 ))"
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

# start_amaru_consumer_container <name> <image> <bundle-dir> <node-container>
#
# Start the pinned Amaru from the producer image as a second Docker
# container sharing the source node's network namespace, peering with
# 127.0.0.1:3001. The bundle is mounted read-write because RocksDB
# rotates runtime files. AMARU_GLOBAL_* must already be exported
# (derive_amaru_global_env). Current `amaru --with-json-traces node
# run` interface, never legacy `amaru run`.
start_amaru_consumer_container() {
  local name="$1" image="$2" bundle="$3" node="$4"

  docker run -d --name "$name" \
    --network "container:$node" \
    --entrypoint amaru \
    -e AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM \
    -e AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE \
    -e AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR \
    -e AMARU_GLOBAL_MAX_LOVELACE_SUPPLY \
    -e AMARU_GLOBAL_SLOTS_PER_KES_PERIOD \
    -e AMARU_GLOBAL_MAX_KES_EVOLUTION \
    -e AMARU_GLOBAL_SYSTEM_START \
    -v "$bundle:/bundle:rw" \
    "$image" \
    --with-json-traces node run \
    --network testnet_42 \
    --era-history /bundle/era-history.json \
    --ledger-dir /bundle/ledger.testnet_42.db \
    --chain-dir /bundle/chain.testnet_42.db \
    --listen-address 127.0.0.1:0 \
    --peer-address 127.0.0.1:3001
}

# refresh_amaru_consumer_log <container> <log-path>
#
# Refresh the combined container stdout/stderr into <log-path>.
# Deterministic injection seam: when AMARU_TEST_SEED_FATAL is set,
# the needle is appended after docker logs so the poll's cleanliness
# and liveness steps exercise untouched real code (B-2).
refresh_amaru_consumer_log() {
  local container="$1" log="$2"
  docker logs "$container" > "$log" 2>&1
  if [[ -n "${AMARU_TEST_SEED_FATAL:-}" ]]; then
    printf '%s\n' "$AMARU_TEST_SEED_FATAL" >> "$log"
  fi
}

# assert_amaru_consumer_running <container>
#
# Return 0 if docker reports the container running, 1 otherwise.
assert_amaru_consumer_running() {
  local container="$1"
  local state
  state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
  [[ "$state" == "true" ]]
}

# poll_amaru_consumer_once <container> <log-path> <hold-seconds> <start-epoch>
#
# One live-poll iteration in the contract order:
#   1. refresh combined container log (seam carrier);
#   2. assert_amaru_log_clean — fatal wins over a coincident exit;
#   3. only if clean, check container liveness;
#   4. return 0 if clean and alive, nonzero otherwise.
#
# On a dead container with a clean log, emits the bounded
# exited-early diagnostic via report_amaru_exited_early.
poll_amaru_consumer_once() {
  local container="$1" log="$2" hold="$3" start="$4"
  refresh_amaru_consumer_log "$container" "$log"
  if ! assert_amaru_log_clean "$log"; then
    return 1
  fi
  if ! assert_amaru_consumer_running "$container"; then
    local elapsed
    elapsed=$(( $(date +%s) - start ))
    report_amaru_exited_early "$log" "$elapsed" "$hold"
    return 1
  fi
  return 0
}

# scan_amaru_log_for_fatal <log-path>
#
# Grep -F the five fatal substrings from the failure-classes contract
# in declaration order. On the first match: print the class label on
# stdout, emit the labelled context block on stderr, return 0. No
# match: return 1.
#
# Class table (must stay in lockstep with
# specs/057-fatal-amaru-detection/contracts/fatal-log-contract.md):
#   "Invalid VRF proof"      -> vrf
#   "Consensus died"         -> consensus
#   "HeaderValidationError"  -> header
#   "ledger inconsistency"   -> rollback
#   "roll back in the future" -> future-rollback
scan_amaru_log_for_fatal() {
  local log="$1"
  [[ -f "$log" ]] || return 1

  local -a classes=(vrf consensus header rollback future-rollback)
  local -a needles=(
    'Invalid VRF proof'
    'Consensus died'
    'HeaderValidationError'
    'ledger inconsistency'
    'roll back in the future'
  )

  local i
  for i in "${!classes[@]}"; do
    if grep -F -q -- "${needles[$i]}" "$log"; then
      printf '%s\n' "${classes[$i]}"
      {
        printf -- '--- amaru consume failure: %s ---\n' "${classes[$i]}"
        grep -F -n -m1 -B2 -A2 -- "${needles[$i]}" "$log"
        printf -- '--- end amaru consume failure ---\n'
      } >&2
      return 0
    fi
  done
  return 1
}

# assert_amaru_log_clean <log-path>
#
# Caller-facing cleanliness check with ordinary shell semantics:
#   0  — the log exists, is readable, and contains no fatal signature.
#   1  — the log is missing, unreadable, or contains a fatal signature.
#
# On a fatal match the labelled diagnostic block from
# scan_amaru_log_for_fatal appears on stderr. On a missing or
# unreadable log a short diagnostic naming the path appears on stderr.
assert_amaru_log_clean() {
  local log="$1"
  if [[ ! -f "$log" || ! -r "$log" ]]; then
    printf 'assert_amaru_log_clean: missing or unreadable log: %s\n' \
      "$log" >&2
    return 1
  fi
  if scan_amaru_log_for_fatal "$log"; then
    return 1
  fi
  return 0
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

# stop_amaru_consumer_container <container>
#
# Force-remove the Amaru consumer container. Tolerates a container
# that has already exited or was never created.
stop_amaru_consumer_container() {
  local container="${1:-}"
  [[ -n "$container" ]] || return 0
  docker rm -f "$container" >/dev/null 2>&1 || true
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
