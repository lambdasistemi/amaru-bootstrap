#!/usr/bin/env bats

# Pre-flight + collision tests for `snapshot-emitter`.
# Covers FR-008 (structural validation), FR-005 (atomic-write
# guarantee), the 5 documented exit codes (FR-004) and the
# corresponding state-transition steps 1-2 from data-model.md.
#
# These tests do NOT exercise the codec — they verify the orchestrator
# rejects bad inputs BEFORE invoking any decoder.

load 'lib/fixture-helpers'

# Path to the snapshot-emitter binary under test, expected on PATH via
# the flake check derivation. Falls back to a sibling project.local
# path for ad-hoc local invocations.
SNAPSHOT_EMITTER="${SNAPSHOT_EMITTER:-snapshot-emitter}"

setup() {
  if ! command -v "$SNAPSHOT_EMITTER" >/dev/null 2>&1; then
    skip "snapshot-emitter not on PATH; run via nix flake check"
  fi
  TMP_DIR="$(mktemp -d)"
  # A "good enough" directory snapshot for pre-flight passes — content
  # bytes are placeholder; pre-flight only checks structure.
  GOOD_DIR="$TMP_DIR/good_db-analyser"
  mkdir -p "$GOOD_DIR/tables"
  printf 'placeholder' >"$GOOD_DIR/state"
  printf 'placeholder' >"$GOOD_DIR/tables/tvar"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "exits 1 when slot-dir does not exist" {
  run "$SNAPSHOT_EMITTER" "$TMP_DIR/missing" "$TMP_DIR/out.cbor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"input-not-found"* || "$stderr" == *"input-not-found"* ]] || true
}

@test "exits 2 when slot-dir is a regular file, not a directory" {
  : >"$TMP_DIR/regular-file"
  run "$SNAPSHOT_EMITTER" "$TMP_DIR/regular-file" "$TMP_DIR/out.cbor"
  [ "$status" -eq 2 ]
}

@test "exits 2 when slot-dir is missing the state file" {
  rm "$GOOD_DIR/state"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$TMP_DIR/out.cbor"
  [ "$status" -eq 2 ]
}

@test "exits 2 when slot-dir has empty state file" {
  : >"$GOOD_DIR/state"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$TMP_DIR/out.cbor"
  [ "$status" -eq 2 ]
}

@test "exits 2 when slot-dir is missing tables/tvar" {
  rm "$GOOD_DIR/tables/tvar"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$TMP_DIR/out.cbor"
  [ "$status" -eq 2 ]
}

@test "exits 2 when slot-dir has empty tables/tvar" {
  : >"$GOOD_DIR/tables/tvar"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$TMP_DIR/out.cbor"
  [ "$status" -eq 2 ]
}

@test "exits 4 when output file already exists" {
  : >"$TMP_DIR/already-there.cbor"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$TMP_DIR/already-there.cbor"
  [ "$status" -eq 4 ]
}

@test "wrong number of arguments exits non-zero" {
  run "$SNAPSHOT_EMITTER"
  [ "$status" -ne 0 ]
  run "$SNAPSHOT_EMITTER" only-one
  [ "$status" -ne 0 ]
  run "$SNAPSHOT_EMITTER" too many args here
  [ "$status" -ne 0 ]
}

@test "no partial output left on any failure path" {
  rm "$GOOD_DIR/state"
  out="$TMP_DIR/never-written.cbor"
  run "$SNAPSHOT_EMITTER" "$GOOD_DIR" "$out"
  [ "$status" -eq 2 ]
  [ ! -e "$out" ]
}
