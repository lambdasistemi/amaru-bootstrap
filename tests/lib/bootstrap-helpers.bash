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
