#!/usr/bin/env bats

# End-to-end PASS-verdict assertion for the bridged Phase 0 + Phase 1
# smoke test. This test asserts the SC-002 success criterion: with the
# snapshot-emitter inserted between dump and convert, the smoke-test
# verdict on the vendored fixture is `PASS`.
#
# Replaces test-smoke-integration.bats's "any documented verdict is
# acceptable" check (T015 will retire that check).
#
# Skipped if the real binaries are not on PATH — typically bats is
# invoked via `nix run .#checks.x86_64-linux.smoke-test-integration`
# which puts everything (amaru, db-synthesizer, db-analyser,
# snapshot-emitter) there.

load 'lib/fixture-helpers'

setup() {
  for tool in db-synthesizer db-analyser amaru snapshot-converter; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      skip "real binaries not on PATH (missing: $tool); run via nix flake check"
    fi
  done
  TMP_DIR="$(mktemp -d)"
  BUNDLE="${REPO_ROOT}/specs/001-snapshot-format-smoke/fixtures/p1-config"
  OUT="$TMP_DIR/out"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "bridged smoke test produces PASS verdict on the vendored fixture" {
  start=$(date +%s)
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  end=$(date +%s)
  duration=$((end - start))

  # Per SC-002 + Phase 0 SC-005: still under the 5-minute budget.
  [ "$duration" -lt 300 ]

  verdict="$(last_line "$output")"
  if [ "$verdict" != PASS ]; then
    printf 'unexpected verdict: %s\n' "$verdict" >&2
    printf 'full output:\n%s\n' "$output" >&2
    if [ -d "$OUT" ]; then
      printf '\nfiles in out-dir:\n' >&2
      ls -la "$OUT" >&2
      for log in synthesise.stderr.log dump.stderr.log emit.stderr.log convert.stderr.log; do
        if [ -s "$OUT/$log" ]; then
          printf '\n%s:\n' "$log" >&2
          cat "$OUT/$log" >&2
        fi
      done
    fi
  fi
  [ "$verdict" = PASS ]
  [ "$status" -eq 0 ]
}

@test "bridged smoke test produces snapshot.cbor before convert" {
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$(last_line "$output")" = PASS ]
  [ -s "$OUT/snapshot.cbor" ]
}

@test "bridged smoke test populates amaru's converted output dir" {
  run timeout 300 "$SMOKE_TEST_SCRIPT" "$BUNDLE" "$OUT"
  [ "$(last_line "$output")" = PASS ]
  [ -d "$OUT/converted" ]
  # converted/ must contain something — amaru's output structure is
  # opaque to this project but the dir cannot be empty after PASS.
  [ -n "$(ls -A "$OUT/converted" 2>/dev/null || true)" ]
}
