#!/usr/bin/env bats

# Pre-flight validation tests for scripts/smoke-test.sh.
# Covers every configuration-error path documented in
# contracts/smoke-test-cli.md "Pre-flight validation" and FR-007.
#
# These tests do NOT exercise the upstream tools — they verify the
# orchestrator rejects bad inputs BEFORE invoking anything.

load 'lib/fixture-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "exits 3 when bundle directory does not exist" {
  run "$SMOKE_TEST_SCRIPT" "$TMP_DIR/missing-bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == FAIL:\ configuration\ error:* ]]
}

@test "exits 3 when configs/config.json is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "configs/config.json"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"configs/config.json"* ]]
}

@test "exits 3 when configs/shelley-genesis.json is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "configs/shelley-genesis.json"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"shelley-genesis.json"* ]]
}

@test "exits 3 when keys/kes.skey is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "keys/kes.skey"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"kes.skey"* ]]
}

@test "exits 3 when keys/vrf.skey is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "keys/vrf.skey"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"vrf.skey"* ]]
}

@test "exits 3 when keys/cold.skey is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "keys/cold.skey"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"cold.skey"* ]]
}

@test "exits 3 when keys/opcert.cert is missing" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "keys/opcert.cert"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"opcert.cert"* ]]
}

@test "exits 3 when out-dir is non-empty" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  out="$TMP_DIR/out"
  mkdir -p "$out"
  : >"$out/leftover.log"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$out"
  [ "$status" -eq 3 ]
  [[ "$(last_line "$output")" == *"not empty"* ]]
}

@test "creates out-dir when it is absent" {
  # Pre-flight should accept an absent out-dir and create it; downstream
  # tool failure is fine — we only assert that we got past pre-flight.
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/fresh-out"
  [ "$status" -ne 3 ]
  [ -d "$TMP_DIR/fresh-out" ]
}

@test "verdict is the last line of stdout on configuration error" {
  bundle="$TMP_DIR/bundle"
  make_valid_bundle "$bundle"
  break_bundle "$bundle" "configs/config.json"

  run "$SMOKE_TEST_SCRIPT" "$bundle" "$TMP_DIR/out"
  [ "$status" -eq 3 ]
  # The last stdout line must START with FAIL:.
  [[ "$(last_line "$output")" =~ ^FAIL: ]]
}
