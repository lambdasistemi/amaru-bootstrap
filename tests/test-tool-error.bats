#!/usr/bin/env bats

# Tool-error path tests for scripts/smoke-test.sh.
# Each test mocks one of the three upstream tools (db-synthesizer,
# db-analyser, amaru) to fail with exit 1, then asserts the
# orchestrator emits the right verdict and retains the right
# diagnostic artefacts.
#
# Mocking strategy: prepend a directory of shim scripts to PATH so the
# orchestrator picks them up instead of the real tools (which are
# multi-minute Nix builds). The real binaries' behaviour is exercised
# by the integration test in test-smoke-integration.bats.
#
# Covers data-model.md "State Transitions" plus FR-005, FR-006, FR-010.

load 'lib/fixture-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  MOCK_BIN="$TMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  # Shim every tool to a passing no-op by default; individual tests
  # override one shim to a failing variant.
  install_passing_mock db-synthesizer
  install_passing_mock db-analyser
  install_passing_mock amaru
  BUNDLE="$TMP_DIR/bundle"
  make_valid_bundle "$BUNDLE"
  OUT="$TMP_DIR/out"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# install_passing_mock <toolname>: a do-nothing shim that exits 0.
install_passing_mock() {
  local tool="$1"
  cat >"$MOCK_BIN/$tool" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  chmod +x "$MOCK_BIN/$tool"
}

# install_failing_mock <toolname> <message>: a shim that prints
# <message> to stderr and exits 1.
install_failing_mock() {
  local tool="$1"
  local message="$2"
  cat >"$MOCK_BIN/$tool" <<SHIM
#!/usr/bin/env bash
echo "$message" >&2
exit 1
SHIM
  chmod +x "$MOCK_BIN/$tool"
}

@test "db-synthesizer failure -> FAIL: tool error: synthesise, exit 2" {
  install_failing_mock db-synthesizer "synthesizer crashed"

  PATH="$MOCK_BIN:$PATH" run "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$status" -eq 2 ]
  [[ "$(last_line "$output")" == "FAIL: tool error: synthesise" ]]
  # Stderr from the tool MUST be retained per FR-006.
  [ -s "$OUT/synthesise.stderr.log" ]
  grep -q "synthesizer crashed" "$OUT/synthesise.stderr.log"
}

@test "db-analyser failure -> FAIL: tool error: dump, exit 2" {
  install_failing_mock db-analyser "analyser crashed"

  PATH="$MOCK_BIN:$PATH" run "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$status" -eq 2 ]
  [[ "$(last_line "$output")" == "FAIL: tool error: dump" ]]
  [ -s "$OUT/dump.stderr.log" ]
  grep -q "analyser crashed" "$OUT/dump.stderr.log"
}

@test "amaru convert-ledger-state failure -> FAIL: format mismatch, exit 1" {
  install_failing_mock amaru "amaru rejected the snapshot: unexpected CBOR"

  PATH="$MOCK_BIN:$PATH" run "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$status" -eq 1 ]
  [[ "$(last_line "$output")" == "FAIL: format mismatch" ]]
  [ -s "$OUT/convert.stderr.log" ]
  # Per FR-010, amaru's error must be surfaced verbatim somewhere
  # discoverable.
  grep -q "amaru rejected the snapshot" "$OUT/convert.stderr.log"
}

@test "report.txt exists alongside the verdict on tool error" {
  install_failing_mock db-synthesizer "synthesizer crashed"

  PATH="$MOCK_BIN:$PATH" run "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$status" -eq 2 ]
  # Penultimate stdout line must be `report: <path>` per the contract.
  penult="$(penultimate_line "$output")"
  [[ "$penult" =~ ^report:\ /.*report\.txt$ ]]
  report_path="${penult#report: }"
  [ -f "$report_path" ]
}

@test "stderr logs exist as zero-byte files for steps that did not run" {
  install_failing_mock db-synthesizer "synthesizer crashed"

  PATH="$MOCK_BIN:$PATH" run "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$status" -eq 2 ]
  # Per the contract, stderr.log files for unrun steps still exist
  # (zero-byte). dump and convert never ran in this scenario.
  [ -e "$OUT/dump.stderr.log" ]
  [ -e "$OUT/convert.stderr.log" ]
  [ ! -s "$OUT/dump.stderr.log" ]
  [ ! -s "$OUT/convert.stderr.log" ]
}
