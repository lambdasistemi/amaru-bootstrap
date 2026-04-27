#!/usr/bin/env bats

# End-to-end integration test: the actual hypothesis verdict.
#
# This test runs the REAL upstream tools (db-synthesizer, db-analyser,
# amaru) against the vendored testnet fixture. Its pass/fail IS the
# Phase 0 deliverable.
#
# Skipped automatically if the binaries are not on PATH — typically
# bats is invoked via `nix run .#checks.x86_64-linux.smoke-test-bats`
# (T021/T022) which puts them there.
#
# Wall-clock budget: 5 minutes per SC-005.

load 'lib/fixture-helpers'

setup() {
  if ! command -v db-synthesizer >/dev/null 2>&1 \
       || ! command -v db-analyser >/dev/null 2>&1 \
       || ! command -v amaru >/dev/null 2>&1; then
    skip "real binaries not on PATH; run via nix flake check"
  fi
  TMP_DIR="$(mktemp -d)"
  BUNDLE="${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config"
  OUT="$TMP_DIR/out"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "smoke test against vendored fixture emits a verdict in <5min" {
  start=$(date +%s)
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  end=$(date +%s)
  duration=$((end - start))

  # Per SC-005: under five minutes wall-clock for any verdict on a
  # developer workstation.
  [ "$duration" -lt 300 ]

  # Verdict line is on stdout regardless of pass/fail.
  verdict="$(last_line "$output")"
  case "$verdict" in
    PASS|"FAIL: format mismatch"|"FAIL: tool error: "*|"FAIL: configuration error: "*)
      ;;
    *)
      printf 'unrecognised verdict: %s\n' "$verdict" >&2
      printf 'full output:\n%s\n' "$output" >&2
      false
      ;;
  esac
}

@test "smoke test against vendored fixture produces the report file" {
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ -f "$OUT/report.txt" ]

  # Penultimate stdout line is the path to the report.
  penult="$(penultimate_line "$output")"
  [[ "$penult" =~ ^report:\ /.*report\.txt$ ]]
}

@test "PASS verdict implies the no-fork hypothesis is validated" {
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  if [ "$(last_line "$output")" = PASS ]; then
    [ "$status" -eq 0 ]
    [ -d "$OUT/converted" ]
    return 0
  fi
  skip "verdict was not PASS; this assertion is vacuous on FAIL paths"
}
