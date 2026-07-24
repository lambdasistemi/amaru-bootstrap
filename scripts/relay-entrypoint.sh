#!/usr/bin/env bash
#
# Amaru relay entrypoint for the cardano_amaru testnet.
#
# Expects the bootstrap-producer to have already run `amaru node bootstrap`
# and produced a bundle at /bundle/<network>/ containing:
#   - ledger.<network>.db/
#   - chain.<network>.db/
#   - era-history.json
#
# The relay copies the bundle to a local state directory and runs
# `amaru node run` with the correct flags and AMARU_GLOBAL_* env vars.
#
# AMARU_GLOBAL_* env vars must be set by the caller (docker-compose
# environment or orchestrator). The 3 consensus-critical params are:
#   AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM (k)
#   AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE (1/f)
#   AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR (scale)
# where epoch_length = (1/f) * scale * k must equal genesis epochLength.
#
# Usage: relay-entrypoint <network> <bundle-dir> <state-dir> <listen-addr> <peer-addr>

set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo "usage: relay-entrypoint <network> <bundle-dir> <state-dir> <listen-addr> <peer-addr>" >&2
    exit 3
fi

NETWORK="$1"
BUNDLE_DIR="$2"
STATE_DIR="$3"
LISTEN_ADDR="$4"
PEER_ADDR="$5"
NET_LC="${NETWORK,,}"

BUNDLE_PATH="${BUNDLE_DIR}/${NETWORK}"
LEDGER_DIR="${STATE_DIR}/ledger.${NET_LC}.db"
CHAIN_DIR="${STATE_DIR}/chain.${NET_LC}.db"
ERA_HISTORY="${STATE_DIR}/era-history.json"

# ─── Wait for bundle ──────────────────────────────────────────────

echo "+ relay-entrypoint: waiting for bundle at ${BUNDLE_PATH}"
until [[ -d "${BUNDLE_PATH}/ledger.${NET_LC}.db" ]] \
   && [[ -d "${BUNDLE_PATH}/chain.${NET_LC}.db" ]]; do
    sleep 10
done

# ─── Copy bundle to local state ───────────────────────────────────

if [[ ! -d "${LEDGER_DIR}" ]] || [[ ! -d "${CHAIN_DIR}" ]]; then
    echo "+ relay-entrypoint: copying bundle to ${STATE_DIR}"
    find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    cp -rL "${BUNDLE_PATH}/." "${STATE_DIR}/"
fi

# ─── Validate consensus params ────────────────────────────────────

: "${AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM:?AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM must be set}"
: "${AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE:?AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE must be set}"
: "${AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR:?AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR must be set}"

echo "+ relay-entrypoint: k=${AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM} 1/f=${AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE} scale=${AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR}"

# ─── Run ──────────────────────────────────────────────────────────

echo "+ relay-entrypoint: exec amaru node run --network ${NETWORK}"
exec amaru node run \
    --network "${NETWORK}" \
    --ledger-dir "${LEDGER_DIR}" \
    --chain-dir "${CHAIN_DIR}" \
    --era-history "${ERA_HISTORY}" \
    --listen-address "${LISTEN_ADDR}" \
    --peer-address "${PEER_ADDR}"
