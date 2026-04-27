# Shared bash helpers for the smoke-test bats suites.
# Source from each .bats file's setup() with:
#   load 'lib/fixture-helpers'

# Path to the orchestrator under test, relative to the repo root.
SMOKE_TEST_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/smoke-test.sh"

# REPO_ROOT is the absolute path to the repo containing this test file.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# make_valid_bundle <dir>
#
# Materialise a structurally valid input bundle at <dir>: every file
# the orchestrator's pre-flight validation requires per
# contracts/smoke-test-cli.md "Pre-flight validation". Content is
# whatever the vendored fixture already contains — we copy not
# regenerate.
#
# When this helper is invoked from inside a Nix build sandbox, the
# fixture lives in the read-only /nix/store. chmod +w makes the
# *copy* writable so subsequent break_bundle calls work.
make_valid_bundle() {
  local target="$1"
  cp -r "${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config" "$target"
  chmod -R u+w "$target"
}

# break_bundle <dir> <relpath>
#
# Make an otherwise-valid bundle invalid by removing one required
# file. <relpath> is a path relative to the bundle root, e.g.
# 'configs/config.json' or 'keys/kes.skey'.
break_bundle() {
  local bundle="$1"
  local relpath="$2"
  rm -f "${bundle}/configs/${relpath}"
}

# last_line <captured-output>
#
# Per contracts/smoke-test-cli.md "Stdout shape", the verdict is the
# final line of stdout. bats provides $output (joined) and $lines
# (array). Use this for clarity in assertions.
last_line() {
  printf '%s\n' "$1" | tail -n 1
}

# penultimate_line <captured-output>
#
# Per contracts/smoke-test-cli.md, the line before the verdict is
# `report: <abs-path>`.
penultimate_line() {
  printf '%s\n' "$1" | tail -n 2 | head -n 1
}
