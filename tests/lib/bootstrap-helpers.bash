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
