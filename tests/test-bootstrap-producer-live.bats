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

wait_for_node_socket() {
  local name="$1"
  local socket="$2"
  local state

  for _ in {1..60}; do
    state="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
    [[ "$state" == "true" ]] || return 1
    [[ -S "$socket" ]] && return 0
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
  AMARU_CONSUMER_CONTAINER="amaru-live-consumer-${BATS_TEST_NUMBER}-$$"
  NODE_MONITOR_PID=""

  make_live_node_inputs "$TMP_DIR"
  synthesize_live_chain_db "$TMP_DIR" "${BOOTSTRAP_LIVE_SLOTS:-400000}"
}

teardown() {
  if [[ -n "${NODE_MONITOR_PID:-}" ]]; then
    kill "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
    wait "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
  fi
  stop_amaru_consumer_container "$AMARU_CONSUMER_CONTAINER"
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
    --shelley-operational-certificate /keys/opcert.cert \
    --host-addr 0.0.0.0 \
    --port 3001

  if ! wait_for_container_running "$NODE_CONTAINER" \
    || ! wait_for_node_socket "$NODE_CONTAINER" "$TMP_DIR/ipc/node.socket"; then
    echo "--- cardano-node logs ---"
    docker logs "$NODE_CONTAINER" || true
    false
  fi

  # The node monitor runs through the entire consume hold so the
  # source node's liveness is proven for the whole observation window.
  node_monitor_log="$TMP_DIR/node-monitor.log"
  (
    while true; do
      state="$(docker inspect -f '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || true)"
      if [[ "$state" != "true" ]]; then
        printf 'cardano-node stopped while test was running; state=%s\n' \
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

  if [[ "$status" -ne 0 ]]; then
    echo "$output"
    echo "--- cardano-node logs ---"
    docker logs "$NODE_CONTAINER" || true
  fi
  [ "$status" -eq 0 ]

  [[ "$output" == *"+ era-readiness predicate satisfied"* ]]
  [[ "$output" == *"wrote /srv/amaru/testnet_42"* ]]

  final="$TMP_DIR/bundle/testnet_42"
  [ -d "$final/ledger.testnet_42.db" ]
  [ -d "$final/chain.testnet_42.db" ]
  # nonces + bootstrap headers are baked into chain.<net>.db by `amaru
  # bootstrap`; the bundle ships the era-history override for `amaru run`.
  [ -f "$final/era-history.json" ]
  [ -d "$final/ledger.testnet_42.db/live" ]

  snapshot_count=0
  for d in "$final"/ledger.testnet_42.db/*; do
    if [ -d "$d" ] && [[ "$(basename "$d")" =~ ^[0-9]+$ ]]; then
      snapshot_count=$(( snapshot_count + 1 ))
    fi
  done
  [ "$snapshot_count" -ge 3 ]

  # ── T006 consume phase ──────────────────────────────────────────
  # Prove the node listens on 3001 inside the shared namespace (P-4).
  docker run --rm --network "container:$NODE_CONTAINER" \
    --entrypoint bash "$BOOTSTRAP_PRODUCER_IMAGE" \
    -c 'exec 3<>/dev/tcp/127.0.0.1/3001'

  # Derive and export all seven AMARU_GLOBAL_* from the same genesis
  # the node runs on (P-10, G-1). The consumer must receive the
  # identical parameter set the producer used at bundle-build time.
  derive_amaru_global_env "$TMP_DIR/config"
  # Fixture-change tripwire: (1/f) * scale * k must equal epochLength.
  local epoch_len
  epoch_len="$(jq -r '.epochLength' "$TMP_DIR/config/shelley-genesis.json")"
  [ $(( AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE * AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR * AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM )) -eq "$epoch_len" ]

  # Start the consumer container (T007).
  start_amaru_consumer_container "$AMARU_CONSUMER_CONTAINER" \
    "$BOOTSTRAP_PRODUCER_IMAGE" "$TMP_DIR/bundle/testnet_42" "$NODE_CONTAINER"

  # ── A-1 consume contract ───────────────────────────────────────

  # 1. First observation goes through the poll so a startup fatal is
  # refreshed, classified, and printed before anything else (G-2).
  consumer_log="$TMP_DIR/consumer.log"
  local hold_seconds start_epoch elapsed
  hold_seconds="$(parse_hold_window_seconds)"
  start_epoch="$(date +%s)"
  poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
    "$hold_seconds" "$start_epoch"

  # Consumer container is running (P-1).
  run docker inspect -f '{{.State.Running}}' "$AMARU_CONSUMER_CONTAINER"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # All seven AMARU_GLOBAL_* arrived in the container environment
  # (P-10, G-1).
  run docker inspect --format '{{json .Config.Env}}' "$AMARU_CONSUMER_CONTAINER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM=${AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=${AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR=${AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_MAX_LOVELACE_SUPPLY=${AMARU_GLOBAL_MAX_LOVELACE_SUPPLY}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_SLOTS_PER_KES_PERIOD=${AMARU_GLOBAL_SLOTS_PER_KES_PERIOD}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_MAX_KES_EVOLUTION=${AMARU_GLOBAL_MAX_KES_EVOLUTION}"* ]]
  [[ "$output" == *"AMARU_GLOBAL_SYSTEM_START=${AMARU_GLOBAL_SYSTEM_START}"* ]]

  # 2+3. Bounded wait for startup and peering markers (P-2, P-3),
  # applying fatal-before-liveness on every iteration. A single
  # immediate grep is race-prone; the poll entry point refreshes the
  # log and checks cleanliness before liveness each cycle.
  local marker_deadline=$(( start_epoch + 120 ))
  while true; do
    poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
      "$hold_seconds" "$start_epoch"
    if grep -qF -e 'build_ledger' -e 'build.ledger_opened' "$consumer_log" \
      && grep 'connection established' "$consumer_log" \
        | grep -q '"peer":"127.0.0.1:3001"'; then
      break
    fi
    [ "$(date +%s)" -ge "$marker_deadline" ] && {
      echo "timed out waiting for build.ledger_opened (or legacy build_ledger) + connection established" >&2
      false
    }
    sleep 2
  done

  # 4. Consumer log is clean after startup (P-5).
  assert_amaru_log_clean "$consumer_log"

  # 5. B-2 seeded fatal proof: the live poll path rejects a seeded
  #    real fatal line while the consumer container is still alive.
  #    The seam lives inside poll_amaru_consumer_once's refresh step:
  #    when AMARU_TEST_SEED_FATAL is set, the needle is appended after
  #    docker logs, so cleanliness and liveness are untouched real code.
  AMARU_TEST_SEED_FATAL="Consensus died, this should not happen!"
  export AMARU_TEST_SEED_FATAL
  run poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
    "$hold_seconds" "$start_epoch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--- amaru consume failure: consensus ---"* ]]
  # Consumer is still running at the moment of the fatal verdict.
  run docker inspect -f '{{.State.Running}}' "$AMARU_CONSUMER_CONTAINER"
  [ "$output" = "true" ]
  # Disarm: the next refresh must not inherit the seed.
  unset AMARU_TEST_SEED_FATAL
  poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
    "$hold_seconds" "$start_epoch"
  assert_amaru_log_clean "$consumer_log"

  # 6. Positive hold window; observed duration reported (P-7).
  start_epoch="$(date +%s)"
  while true; do
    poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
      "$hold_seconds" "$start_epoch"
    elapsed=$(( $(date +%s) - start_epoch ))
    [ "$elapsed" -ge "$hold_seconds" ] && break
    sleep 2
  done
  echo "consumer observed for ${elapsed}s (hold=${hold_seconds}s)"
  echo "# consumer observed for ${elapsed}s (hold=${hold_seconds}s)" >&3
  [ "$elapsed" -ge "$hold_seconds" ]

  # 7. A-3 early-exit proof: stop the consumer (keep docker logs
  #    working), then one more poll iteration through the same entry
  #    point must fail with the exited-early diagnostic and a bounded
  #    tail (P-6). Clean log + dead container classifies exited-early.
  docker stop "$AMARU_CONSUMER_CONTAINER" >/dev/null 2>&1
  run poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
    "$hold_seconds" "$start_epoch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--- amaru consume failure: exited-early ---"* ]]
  [[ "$output" == *"--- amaru tail (last 50 lines) ---"* ]]
  [[ "$output" == *"--- end amaru consume failure ---"* ]]

  # F-2: fatal beats a coincident exit. The container is already
  # stopped; re-arm the seam and prove the poll reports consensus,
  # not exited-early, when both a fatal line and a dead container
  # are present. This pins the cleanliness-before-liveness order.
  AMARU_TEST_SEED_FATAL="Consensus died, this should not happen!"
  export AMARU_TEST_SEED_FATAL
  run poll_amaru_consumer_once "$AMARU_CONSUMER_CONTAINER" "$consumer_log" \
    "$hold_seconds" "$start_epoch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--- amaru consume failure: consensus ---"* ]]
  [[ "$output" != *"exited-early"* ]]
  unset AMARU_TEST_SEED_FATAL

  # ── Node monitor: prove the source node survived the whole test ──
  node_monitor_status=0
  if kill -0 "$NODE_MONITOR_PID" >/dev/null 2>&1; then
    kill "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
    wait "$NODE_MONITOR_PID" >/dev/null 2>&1 || true
  else
    wait "$NODE_MONITOR_PID" || node_monitor_status=$?
  fi
  NODE_MONITOR_PID=""

  if [[ "$node_monitor_status" -ne 0 ]]; then
    cat "$node_monitor_log"
  fi
  [ "$node_monitor_status" -eq 0 ]
}
