#!/usr/bin/env bash
# Boot the local cluster, let amaru run for ~60s, dump tracing.
set -euo pipefail
cd /code/amaru-bootstrap-relay-entrypoint
export BATS_TEST_DIRNAME="$PWD/tests"
source tests/lib/bootstrap-helpers.bash

TMP_DIR=$(mktemp -d -p /tmp amaru-runlog.XXXXXX)
NET=runlog-net
NODE=runlog-node
RELAY=runlog-amaru
trap "docker rm -f $RELAY $NODE >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; rm -rf $TMP_DIR 2>/dev/null || sudo rm -rf $TMP_DIR || true" EXIT

docker network create $NET >/dev/null 2>&1 || true
make_short_epoch_node_inputs $TMP_DIR
mkdir -p "$TMP_DIR/srv-amaru" "$TMP_DIR/startup"
cp -r /code/cardano-node-antithesis-amaru-marker-fix/testnets/cardano_amaru_epoch240/amaru-runtime "$TMP_DIR/amaru-runtime"

docker run -d --name "$NODE" --network "$NET" \
  -e CARDANO_BLOCK_PRODUCER=true \
  -v "$TMP_DIR/config:/config:ro" -v "$TMP_DIR/keys:/keys:ro" \
  -v "$TMP_DIR/state:/data" -v "$TMP_DIR/ipc:/ipc" \
  ghcr.io/intersectmbo/cardano-node:10.7.1-amd64 \
  run --config /config/config.json --topology /config/topology.json \
      --database-path /data/db --socket-path /ipc/node.socket \
      --shelley-kes-key /keys/kes.skey --shelley-vrf-key /keys/vrf.skey \
      --shelley-operational-certificate /keys/opcert.cert >/dev/null
for _ in {1..60}; do
  [[ -S "$TMP_DIR/ipc/node.socket" ]] && break
  sleep 1
done
echo "+ growing chain 300s"; sleep 300

docker run -d --name "$RELAY" --network "$NET" \
  -e RELAY_NAME=amaru-relay-1 -e AMARU_PEER="$NODE:3001" -e AMARU_LOG=info \
  -e AMARU_NETWORK=testnet_42 -e AMARU_BOOTSTRAP_RETRY_SECONDS=5 \
  -v "$TMP_DIR/state/db:/live:ro" -v "$TMP_DIR/config:/cardano/config/configs:ro" \
  -v "$TMP_DIR/srv-amaru:/srv/amaru" -v "$TMP_DIR/startup:/startup" \
  -v "$TMP_DIR/amaru-runtime:/amaru-runtime:ro" \
  --entrypoint amaru-relay-bootstrap amaru-bootstrap-producer:dev >/dev/null

echo "+ waiting for amaru exec"
for _ in {1..60}; do
  docker logs "$RELAY" 2>&1 | grep -q "exec.ing amaru" && break
  sleep 5
done

echo "+ amaru running; capturing 60s of tracing"
sleep 60

echo
echo "=== last 50 lines of amaru tracing ==="
docker logs --tail 50 "$RELAY" 2>&1 | grep -vE "^\[amaru-relay-1" | tail -50

echo
echo "=== chain-follow signal counts ==="
for needle in "roll_forward" "roll_backward" "header_validation" "ChainSync" \
              "BlockFetch" "Connection refused" "extended" "applied" "ledger" \
              "amaru_consensus" "amaru_protocols" "downloaded"; do
  c=$(docker logs "$RELAY" 2>&1 | grep -c "$needle" || true)
  printf "  %-25s %s\n" "$needle" "$c"
done
