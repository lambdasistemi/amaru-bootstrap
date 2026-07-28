#!/usr/bin/env bats

# T014: failing bats for the rc=2 chain-not-era-ready class.
# The chain DB exists and is non-empty but the era-readiness
# predicate never holds within AMARU_WAIT_DEADLINE_SECONDS.
#
# Driven by env var BOOTSTRAP_PRODUCER_CHAIN_DB which the surrounding
# Nix check sets to a synthesised chain DB whose tip is too short
# to satisfy `tip.slot - 2 * epochLength >= Conway.firstSlot`. With
# the testnet_42 fixture's epochLength=86400 and Conway.firstSlot=0,
# any chain DB shorter than 172800 slots fails the predicate; the
# Nix check synthesises only ~1000 slots.
#
# Per [R-006](../specs/003-amaru-bootstrap-producer/research.md#r-006-wait-and-validate-pre-flight-order)
# + [R-009](../specs/003-amaru-bootstrap-producer/research.md#r-009-wait-strategy--poll-immutable-db-tip-info)
# + [R-010](../specs/003-amaru-bootstrap-producer/research.md#r-010-era-readiness-predicate-and-snapshot-point-selection).

load 'lib/bootstrap-helpers'

setup() {
  if [[ -z "${BOOTSTRAP_PRODUCER_CHAIN_DB:-}" ]]; then
    skip "BOOTSTRAP_PRODUCER_CHAIN_DB unset; run via nix flake check"
  fi
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"
  # Wire the prebuilt-too-short chain DB.
  rm -rf "$TMP_DIR/chain-db"
  cp -rL "$BOOTSTRAP_PRODUCER_CHAIN_DB" "$TMP_DIR/chain-db"
  chmod -R u+w "$TMP_DIR/chain-db"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=10
  export AMARU_WAIT_DEADLINE_SECONDS=10
  export AMARU_POLL_INTERVAL_SECONDS=2
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "rc=2 when chain tip never reaches era-readiness" {
  start=$(date +%s)
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  end=$(date +%s)
  duration=$((end - start))

  [ "$status" -eq 2 ]
  # Must enter the wait loop (≥ deadline-2s).
  [ "$duration" -ge 8 ]

  # P17: the real db-analyser readiness path parsed a concrete tip slot
  # from the REAL binary (the short chain's tip is concrete but its
  # tip_epoch < 3, so the predicate never holds). This is the only place
  # the bats suite exercises the real db-analyser tip format.
  tip_slot=$(printf '%s\n' "$output" \
    | grep -oE 'tip_slot=[0-9]+' | head -1 | cut -d= -f2)
  [ -n "$tip_slot" ]
  [ "$tip_slot" -gt 0 ]
  # The readiness diagnostic carries the real db-analyser only-validation
  # markers (stderr, per the measured stream split), proving db-analyser -
  # not the retired header-extractor - served the poll.
  grep -q 'Started OnlyValidation' "$TMP_DIR/bundle/.logs/tip-info.stderr"
}
