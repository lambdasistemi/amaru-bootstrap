#!/usr/bin/env bats

# T012: failing bats for the rc=3 configuration-error class.
# Per
# specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md
# (exit-code table) and
# specs/003-amaru-bootstrap-producer/data-model.md (Era-readiness
# predicate validation).
#
# Until T017+T018 land, the orchestrator script doesn't exist - every
# test below fails because `bash <missing-script>` returns rc=127.
# Those are the TDD-red signals.

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"
  export AMARU_NETWORK=testnet_42
  # Fast deadlines so the wait-loop tests don't hang the suite.
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=2
  export AMARU_WAIT_DEADLINE_SECONDS=2
  export AMARU_POLL_INTERVAL_SECONDS=1
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "rc=3 when config dir is missing" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/does-not-exist" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 3 ]
}

@test "rc=3 when config.json is missing" {
  break_config "$TMP_DIR/config" "config.json"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 3 ]
}

@test "rc=3 when config.json is unparseable" {
  malform_config "$TMP_DIR/config"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 3 ]
}

@test "rc=3 when shelley-genesis epochLength is zero" {
  zero_epoch_length "$TMP_DIR/config"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 3 ]
}

@test "rc=3 when shelley-genesis is missing" {
  break_config "$TMP_DIR/config" "shelley-genesis.json"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 3 ]
}
