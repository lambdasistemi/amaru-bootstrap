#!/usr/bin/env bats

# T015: failing bats for FR-008 idempotency / R-006 short-circuit.
# An existing complete bundle for the same network must short-circuit
# pre-flight to rc=0 in well under a second, with no wait loop entered.
#
# Per [FR-008](../specs/003-amaru-bootstrap-producer/spec.md#functional-requirements)
# and [R-006 short-circuit](../specs/003-amaru-bootstrap-producer/research.md#r-006-wait-and-validate-pre-flight-order).

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"
  # Pre-populate a complete bundle for testnet_42. The orchestrator
  # checks for `<bundle>/<network>/{ledger.<network>.db, chain.<network>.db,
  # nonces.json, headers}` before entering any wait state.
  mkdir -p "$TMP_DIR/bundle/testnet_42/ledger.testnet_42.db"
  mkdir -p "$TMP_DIR/bundle/testnet_42/chain.testnet_42.db"
  mkdir -p "$TMP_DIR/bundle/testnet_42/headers"
  : >"$TMP_DIR/bundle/testnet_42/nonces.json"
  # Write at least one header file so the headers/* check passes.
  : >"$TMP_DIR/bundle/testnet_42/headers/header.0.000000.cbor"
  # Cluster mount intentionally empty - the test is that we never
  # poll for it.
  rm -rf "$TMP_DIR/chain-db"
  mkdir "$TMP_DIR/chain-db"
  export AMARU_NETWORK=testnet_42
  # If the orchestrator entered the wait loop, this 60s deadline would
  # surface as a slow test. The assertion below guards <1s wall-clock.
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=60
  export AMARU_WAIT_DEADLINE_SECONDS=60
  export AMARU_POLL_INTERVAL_SECONDS=10
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "rc=0 with an existing complete bundle (no wait loop)" {
  start=$(date +%s%N)
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  end=$(date +%s%N)
  elapsed_ms=$(( (end - start) / 1000000 ))

  [ "$status" -eq 0 ]
  # Hard upper bound: short-circuit must complete in well under 1s.
  [ "$elapsed_ms" -lt 1000 ]
}

@test "wait loop is NOT entered when bundle is already complete" {
  # If the orchestrator entered the wait loop, the empty chain DB
  # would push it to rc=1 (cluster-not-ready). rc=0 proves it short-
  # circuited.
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 0 ]
}
