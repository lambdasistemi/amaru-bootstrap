#!/usr/bin/env bats

# T021: live cardano-node verifier for the bootstrap-producer image.
#
# This test seeds an era-ready testnet_42 ChainDB with stock
# db-synthesizer, starts the official cardano-node 10.7.1 image on
# that DB, then points bootstrap-producer at the live DB while the node
# has it open. The checked-in genesis stays unmodified so Amaru's
# testnet_42 import assumptions still match the emitted snapshot.
#
# It is intentionally NOT a Nix flake check: it needs a Docker daemon.

load 'lib/bootstrap-helpers'

wait_for_container_running() {
  local name="$1"
  local state

  for _ in {1..30}; do
    state="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
    [[ "$state" == "true" ]] && return 0
    sleep 1
  done

  return 1
}

setup() {
  command -v docker >/dev/null 2>&1 || skip "docker unavailable"
  command -v db-synthesizer >/dev/null 2>&1 || skip "db-synthesizer unavailable"
  if [[ -z "${BOOTSTRAP_PRODUCER_IMAGE:-}" ]]; then
    skip "BOOTSTRAP_PRODUCER_IMAGE unset; load/build the image first"
  fi

  CARDANO_NODE_IMAGE="${CARDANO_NODE_IMAGE:-ghcr.io/intersectmbo/cardano-node:10.7.1-amd64}"
  TMP_PARENT="${BOOTSTRAP_LIVE_TMPDIR:-${RUNNER_TEMP:-}}"
  if [[ -n "$TMP_PARENT" ]]; then
    mkdir -p "$TMP_PARENT"
    TMP_DIR="$(mktemp -d "${TMP_PARENT%/}/amaru-live.XXXXXX")"
  else
    TMP_DIR="$(mktemp -d)"
  fi
  NODE_CONTAINER="amaru-live-node-${BATS_TEST_NUMBER}-$$"
  PRODUCER_CONTAINER="amaru-live-producer-${BATS_TEST_NUMBER}-$$"
  NODE_MONITOR_PID=""

  make_live_node_inputs "$TMP_DIR"
  synthesize_live_chain_db "$TMP_DIR" "${BOOTSTRAP_LIVE_SLOTS:-300000}"
}

teardown() {
  if [[ -n "${NODE_MONITOR_PID:-}" ]]; then
    kill "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
    wait "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
  fi
  docker rm -f "$PRODUCER_CONTAINER" "$NODE_CONTAINER" >/dev/null 2>&1 || true
  docker_rm_worktree "$TMP_DIR" "$CARDANO_NODE_IMAGE"
}

@test "producer reads a cardano-node 10.7.1 ChainDB while the node has it open" {
  docker run -d --name "$NODE_CONTAINER" \
    -e CARDANO_BLOCK_PRODUCER=true \
    -v "$TMP_DIR/config:/config:ro" \
    -v "$TMP_DIR/keys:/keys:ro" \
    -v "$TMP_DIR/state:/data" \
    -v "$TMP_DIR/ipc:/ipc" \
    "$CARDANO_NODE_IMAGE" \
    run \
    --config /config/config.json \
    --topology /config/topology.json \
    --database-path /data/db \
    --socket-path /ipc/node.socket \
    --shelley-kes-key /keys/kes.skey \
    --shelley-vrf-key /keys/vrf.skey \
    --shelley-operational-certificate /keys/opcert.cert

  if ! wait_for_container_running "$NODE_CONTAINER"; then
    echo "--- cardano-node logs ---"
    docker logs "$NODE_CONTAINER" || true
    false
  fi

  node_monitor_log="$TMP_DIR/node-monitor.log"
  (
    while true; do
      state="$(docker inspect -f '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || true)"
      if [[ "$state" != "true" ]]; then
        printf 'cardano-node stopped while producer was running; state=%s\n' \
          "${state:-missing}" >"$node_monitor_log"
        docker logs "$NODE_CONTAINER" >>"$node_monitor_log" 2>&1 || true
        exit 1
      fi
      sleep 1
    done
  ) &
  NODE_MONITOR_PID=$!

  run docker run --name "$PRODUCER_CONTAINER" \
    -e AMARU_NETWORK=testnet_42 \
    -e AMARU_CLUSTER_READY_DEADLINE_SECONDS=30 \
    -e AMARU_WAIT_DEADLINE_SECONDS=120 \
    -e AMARU_POLL_INTERVAL_SECONDS=1 \
    -v "$TMP_DIR/state/db:/cardano/state" \
    -v "$TMP_DIR/config:/cardano/config:ro" \
    -v "$TMP_DIR/bundle:/srv/amaru" \
    "$BOOTSTRAP_PRODUCER_IMAGE" \
    /cardano/state \
    /cardano/config \
    /srv/amaru \
    testnet_42

  node_monitor_status=0
  if kill -0 "$NODE_MONITOR_PID" >/dev/null 2>&1; then
    kill "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
    wait "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
  else
    wait "$NODE_MONITOR_PID" || node_monitor_status=$?
  fi
  NODE_MONITOR_PID=""

  if [[ "$status" -ne 0 ]]; then
    echo "$output"
    echo "--- cardano-node logs ---"
    docker logs "$NODE_CONTAINER" || true
  fi
  [ "$status" -eq 0 ]

  if [[ "$node_monitor_status" -ne 0 ]]; then
    cat "$node_monitor_log"
  fi
  [ "$node_monitor_status" -eq 0 ]

  [[ "$output" == *"+ era-readiness predicate satisfied"* ]]
  [[ "$output" == *"wrote /srv/amaru/testnet_42"* ]]

  final="$TMP_DIR/bundle/testnet_42"
  [ -d "$final/ledger.testnet_42.db" ]
  [ -d "$final/chain.testnet_42.db" ]
  [ -f "$final/nonces.json" ]
  [ -n "$(find "$final/snapshots" -name '*.cbor' -print -quit)" ]

  header_count="$(find "$final/headers" -name 'header.*.cbor' | wc -l)"
  [ "$header_count" -ge 4 ]
}
