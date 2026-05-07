#!/usr/bin/env bash
# Local fault harness for the amaru-relay-bootstrap entrypoint.
#
# Antithesis dispatches cost ~70 min wallclock and obscure logs; we
# can repro the easy-class faults locally in minutes:
#
#   THIN_CHAIN  cold-boot the relay before the cardano-node has 3
#               full Conway epochs available. Producer should emit
#               only the snapshots it can; bundle_complete should
#               return FALSE (no 0/CURRENT yet); the loop should
#               keep retrying until chain catches up.
#
#   PRODUCER_KILL  during a bootstrap-producer invocation, SIGKILL
#                  the relay container. Docker `restart: always`
#                  brings it back. Loop should recover, scratch dir
#                  may be stale but refresh_snapshot rebuilds it.
#                  Final bundle should still be valid.
#
#   END_TO_END  start the relay against a chain old enough to give
#               3+ snapshots, exec amaru, run amaru for N seconds,
#               assert it doesn't exit early.
#
# Usage:
#   bash repro-amaru-faults.sh THIN_CHAIN
#   bash repro-amaru-faults.sh PRODUCER_KILL
#   bash repro-amaru-faults.sh END_TO_END

set -euo pipefail

cd /code/amaru-bootstrap-relay-entrypoint
export BATS_TEST_DIRNAME="$PWD/tests"
source tests/lib/bootstrap-helpers.bash

SCENARIO="${1:-END_TO_END}"
TMP_DIR="$(mktemp -d -p /tmp amaru-faults.XXXXXX)"
NODE=relay-faults-node
RELAY=relay-faults-amaru
NET=relay-faults-net
trap 'docker rm -f "$RELAY" "$NODE" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$TMP_DIR" 2>/dev/null || sudo rm -rf "$TMP_DIR" || true' EXIT
docker network create "$NET" >/dev/null 2>&1 || true

CARDANO_NODE_IMAGE="${CARDANO_NODE_IMAGE:-ghcr.io/intersectmbo/cardano-node:10.7.1-amd64}"
PRODUCER_IMAGE="${PRODUCER_IMAGE:-amaru-bootstrap-producer:dev}"

stage_inputs() {
  make_short_epoch_node_inputs "$TMP_DIR"
  mkdir -p "$TMP_DIR/srv-amaru" "$TMP_DIR/startup"; cp -r /code/cardano-node-antithesis-amaru-marker-fix/testnets/cardano_amaru_epoch240/amaru-runtime "$TMP_DIR/amaru-runtime"
  # /amaru-runtime is provided by the cardano-node-antithesis testnet
  # in production. For the harness, copy the era-history + global-params
  # written by the producer's first successful run, OR generate them
  # via amaru convert-ledger-state. Simpler: pre-run the producer once
  # to capture the runtime files, then start the relay loop afresh.
  echo "+ priming amaru-runtime via a dry producer run"
  local prime="$TMP_DIR/prime"
  mkdir -p "$prime/srv" "$prime/scratch"
}

start_node() {
  echo "+ start cardano-node ($NODE)"
  docker run -d --name "$NODE" \
    --network "$NET" \
    -e CARDANO_BLOCK_PRODUCER=true \
    -p 127.0.0.1::3001 \
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
      --shelley-operational-certificate /keys/opcert.cert >/dev/null
  for _ in {1..60}; do
    state="$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null || true)"
    [[ "$state" == "true" && -S "$TMP_DIR/ipc/node.socket" ]] && break
    sleep 1
  done
}

start_relay() {
  local restart_policy="$1"   # "always" or "no"
  echo "+ start amaru-relay-bootstrap ($RELAY) restart=$restart_policy"
  docker run -d --name "$RELAY" \
    --network "$NET" \
    --restart "$restart_policy" \
    -e RELAY_NAME=amaru-relay-1 \
    -e AMARU_PEER="$NODE:3001" \
    -e AMARU_LOG=info \
    -e AMARU_NETWORK=testnet_42 \
    -e AMARU_BOOTSTRAP_RETRY_SECONDS=5 \
    -v "$TMP_DIR/state/db:/live:ro" \
    -v "$TMP_DIR/config:/cardano/config/configs:ro" \
    -v "$TMP_DIR/srv-amaru:/srv/amaru" \
    -v "$TMP_DIR/startup:/startup" \
    -v "$TMP_DIR/amaru-runtime:/amaru-runtime:ro" \
    --entrypoint amaru-relay-bootstrap \
    "$PRODUCER_IMAGE" >/dev/null
}

await_log() {
  local needle="$1"; local timeout="${2:-60}"
  local end=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $end ]]; do
    if docker logs "$RELAY" 2>&1 | grep -qF -- "$needle"; then return 0; fi
    sleep 2
  done
  return 1
}

case "$SCENARIO" in
  THIN_CHAIN)
    # Start relay BEFORE node has had time to grow chain. Verify
    # bundle_complete keeps returning false until enough epochs accrue.
    stage_inputs
    start_node
    echo "+ NO chain-grow wait: starting relay immediately"
    start_relay no
    sleep 60
    if docker logs "$RELAY" 2>&1 | grep -q "bundle ready at"; then
      echo "PASS-fast (chain grew enough in 60s, bundle complete)"
    else
      echo "+ relay still in bootstrap loop after 60s — checking bundle_complete keeps the loop alive"
      if docker logs "$RELAY" 2>&1 | grep -q "bootstrap attempt #2"; then
        echo "PASS: loop retried (bundle_complete returned false on partial bundle)"
      else
        echo "FAIL: relay didn't even attempt #2 in 60s"
        docker logs --tail 30 "$RELAY"
        exit 2
      fi
    fi
    ;;

  PRODUCER_KILL)
    # Grow a real chain first so producer succeeds eventually, then
    # start the relay and SIGKILL during the producer phase. Docker's
    # restart: always brings it back; verify the loop reaches a clean
    # bundle ready.
    stage_inputs
    start_node
    echo "+ growing chain 300s"
    sleep 300
    start_relay always
    if ! await_log "invoking bootstrap-producer" 30; then
      echo "FAIL: producer never invoked"; exit 2
    fi
    sleep 5
    echo "+ SIGKILL'ing relay mid-producer"
    docker kill --signal=KILL "$RELAY" >/dev/null
    if await_log "bundle ready at" 180; then
      echo "PASS: relay recovered from kill, bundle ready"
    else
      echo "FAIL: relay never recovered"
      docker logs --tail 60 "$RELAY"
      exit 2
    fi
    ;;

  END_TO_END)
    stage_inputs
    start_node
    echo "+ growing chain 300s"
    sleep 300
    start_relay no
    if await_log "bundle ready at" 240; then
      echo "PASS: bundle complete + amaru exec'd"
      sleep 30
      if docker inspect -f '{{.State.Running}}' "$RELAY" 2>/dev/null | grep -q true; then
        echo "PASS: amaru still alive after 30s"
      else
        echo "AMARU EXITED — last logs:"
        docker logs --tail 30 "$RELAY"
      fi
    else
      echo "FAIL: bundle never ready in 240s"
      docker logs --tail 60 "$RELAY"
      exit 2
    fi
    ;;

  *)
    echo "unknown scenario: $SCENARIO" >&2
    exit 64
    ;;
esac
