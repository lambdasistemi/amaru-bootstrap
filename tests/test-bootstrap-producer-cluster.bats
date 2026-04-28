#!/usr/bin/env bats

# T013: failing bats for the rc=1 cluster-not-ready class.
# The chain DB never appears within
# AMARU_CLUSTER_READY_DEADLINE_SECONDS - the orchestrator's first
# poll loop times out.
#
# Per [data-model.md state diagram step
# 1](../specs/003-amaru-bootstrap-producer/data-model.md#bootstrap-step-the-worker)
# and
# [R-006](../specs/003-amaru-bootstrap-producer/research.md#r-006-wait-and-validate-pre-flight-order).
#
# Backed by FR-001 + FR-011 (chain DB validation rules).

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"
  # Empty mount: chain-db dir exists but immutable/ never appears.
  rm -rf "$TMP_DIR/chain-db"
  mkdir "$TMP_DIR/chain-db"
  export AMARU_NETWORK=testnet_42
  # 5-second cluster-ready deadline - quick enough for CI but long
  # enough to confirm the loop entered.
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=5
  export AMARU_POLL_INTERVAL_SECONDS=1
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "rc=1 when chain DB never appears within deadline" {
  start=$(date +%s)
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  end=$(date +%s)
  duration=$((end - start))

  [ "$status" -eq 1 ]
  # The loop must have actually waited the deadline (allow 2s slack).
  [ "$duration" -ge 4 ]
}

@test "rc=1 when chain-db path does not exist at all" {
  rm -rf "$TMP_DIR/chain-db"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 1 ]
}

@test "rc=1 when immutable/ subdirectory exists but is empty" {
  mkdir -p "$TMP_DIR/chain-db/immutable"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42
  [ "$status" -eq 1 ]
}
