#!/usr/bin/env bats

# T016: failing bats for Obs#4 concurrency safety.
# Two bootstrap-producer processes started concurrently against the
# same input + same output volume must NOT corrupt each other's
# `<bundle>/<network>.tmp/` working directories. The implementation
# expectation (T019): each process writes to a unique-suffixed temp
# dir `<bundle>/<network>.tmp.<pid>.<random>/` and the FIRST one
# finishes wins via `mv -T <unique-tmp> <final>`; the loser detects
# the now-complete bundle on the second pre-flight pass and short-
# circuits with rc=0.
#
# Per [spec.md edge-case "Concurrent compose-up calls"](../specs/003-amaru-bootstrap-producer/spec.md#edge-cases)
# and [R-007](../specs/003-amaru-bootstrap-producer/research.md#r-007-atomic-bundle-commit).
#
# Backed by env BOOTSTRAP_PRODUCER_CHAIN_DB pointing to a chain DB
# that satisfies era-readiness (the Nix check synthesises one large
# enough). Skips when the env var is unset.

load 'lib/bootstrap-helpers'

setup() {
  if [[ -z "${BOOTSTRAP_PRODUCER_CHAIN_DB:-}" ]]; then
    skip "BOOTSTRAP_PRODUCER_CHAIN_DB unset; run via nix flake check"
  fi
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"
  rm -rf "$TMP_DIR/chain-db"
  cp -rL "$BOOTSTRAP_PRODUCER_CHAIN_DB" "$TMP_DIR/chain-db"
  chmod -R u+w "$TMP_DIR/chain-db"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=10
  export AMARU_WAIT_DEADLINE_SECONDS=10
  export AMARU_POLL_INTERVAL_SECONDS=1
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "two concurrent producers both exit 0; bundle complete; no temp dir survives" {
  "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42 \
      &
  pid_a=$!
  "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42 \
      &
  pid_b=$!

  rc_a=0
  rc_b=0
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?

  # Both must succeed: one wins the rename race, the other re-runs
  # pre-flight, sees a complete bundle, and short-circuits.
  [ "$rc_a" -eq 0 ]
  [ "$rc_b" -eq 0 ]

  # Final bundle exists.
  [ -d "$TMP_DIR/bundle/testnet_42" ]

  # No leftover unique-suffixed temp dirs (R-007 atomicity).
  shopt -s nullglob
  leftovers=("$TMP_DIR"/bundle/testnet_42.tmp.*)
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ]
}
