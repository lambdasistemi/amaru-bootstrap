#!/usr/bin/env bash
#
# Phase 0 smoke test — implements the contract at
# specs/001-snapshot-format-smoke/contracts/smoke-test-cli.md and the
# state diagram at specs/001-snapshot-format-smoke/data-model.md.
#
# Pipeline:
#   1. Validate bundle and out-dir
#   2. Build bulk-credentials.json from the bundle's keys
#   3. Synthesize a chain DB covering >= 1 epoch
#   4. Compute the epoch-boundary slot from the Shelley genesis
#   5. Dump a ledger snapshot at that slot
#   6. Feed the snapshot to amaru convert-ledger-state
#   7. Emit report.txt and the verdict
#
# Exit codes:
#   0  PASS
#   1  FAIL: format mismatch
#   2  FAIL: tool error: <step>
#   3  FAIL: configuration error: <reason>
#   64+ FAIL: internal error (bash trap)

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: smoke-test <bundle> <out-dir>" >&2
    exit 3
fi

BUNDLE="$1"
OUT="$2"

CONFIGS_DIR="${BUNDLE}/configs/configs"
KEYS_DIR="${BUNDLE}/configs/keys"
NETWORK="testnet_42"

# Verdict helpers ──────────────────────────────────────────────────

emit_verdict() {
    local outcome="$1"
    if [[ -f "${OUT}/report.txt" ]]; then
        printf 'report: %s\n' "$(realpath "${OUT}/report.txt")"
    fi
    printf '%s\n' "${outcome}"
}

fail_config() {
    local reason="$1"
    emit_verdict "FAIL: configuration error: ${reason}"
    exit 3
}

fail_tool() {
    local step="$1"
    write_report "FAIL: tool error: ${step}"
    emit_verdict "FAIL: tool error: ${step}"
    exit 2
}

fail_format() {
    write_report "FAIL: format mismatch"
    emit_verdict "FAIL: format mismatch"
    exit 1
}

pass() {
    write_report "PASS"
    emit_verdict "PASS"
    exit 0
}

# Internal-error guard. Any unexpected non-zero exit lands here.
# shellcheck disable=SC2329  # invoked indirectly via `trap ... ERR` below.
on_error() {
    local rc=$?
    if [[ -d "${OUT}" ]]; then
        write_report "FAIL: internal error: rc=${rc}"
    fi
    printf '%s\n' "FAIL: internal error: rc=${rc}"
    exit $((64 + rc))
}
trap on_error ERR

# Step 1: pre-flight validation ────────────────────────────────────

[[ -d "${BUNDLE}" ]] \
    || fail_config "bundle not found: ${BUNDLE}"

for required in \
    "configs/configs/config.json" \
    "configs/configs/shelley-genesis.json" \
    "configs/keys/opcert.cert" \
    "configs/keys/kes.skey" \
    "configs/keys/vrf.skey" \
    "configs/keys/cold.skey"
do
    [[ -f "${BUNDLE}/${required}" ]] \
        || fail_config "missing ${required}"
done

if [[ -e "${OUT}" ]]; then
    if [[ -d "${OUT}" ]] && [[ -n "$(ls -A "${OUT}" 2>/dev/null || true)" ]]; then
        fail_config "out-dir not empty: ${OUT}"
    elif [[ ! -d "${OUT}" ]]; then
        fail_config "out-dir exists and is not a directory: ${OUT}"
    fi
else
    mkdir -p "${OUT}"
fi

# Pre-create stderr log files so callers can rely on their existence
# regardless of which step ultimately runs.
: >"${OUT}/synthesise.stderr.log"
: >"${OUT}/dump.stderr.log"
: >"${OUT}/convert.stderr.log"

# Report writer ────────────────────────────────────────────────────

REPORT="${OUT}/report.txt"
SYNTH_RC=""
DUMP_RC=""
CONVERT_RC=""
SNAPSHOT_PATH=""
CONVERTED_PATH=""

write_report() {
    local outcome="$1"
    {
        printf 'amaru-bootstrap smoke test\n'
        printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'bundle:    %s\n' "${BUNDLE}"
        printf 'out-dir:   %s\n' "${OUT}"
        printf 'verdict:   %s\n' "${outcome}"
        printf '\n'
        printf 'step exit codes:\n'
        printf '  synthesise: %s\n' "${SYNTH_RC:-not run}"
        printf '  dump:       %s\n' "${DUMP_RC:-not run}"
        printf '  convert:    %s\n' "${CONVERT_RC:-not run}"
        printf '\n'
        printf 'stderr logs:\n'
        printf '  %s\n' "${OUT}/synthesise.stderr.log"
        printf '  %s\n' "${OUT}/dump.stderr.log"
        printf '  %s\n' "${OUT}/convert.stderr.log"
        if [[ -n "${SNAPSHOT_PATH}" ]]; then
            printf '\nsnapshot: %s\n' "${SNAPSHOT_PATH}"
        fi
        if [[ -n "${CONVERTED_PATH}" ]]; then
            printf 'converted: %s\n' "${CONVERTED_PATH}"
        fi
    } >"${REPORT}"
}

# Step 2: build bulk-credentials.json ──────────────────────────────

BULK_CREDS="${OUT}/bulk-credentials.json"
jq -n \
    --slurpfile opcert "${KEYS_DIR}/opcert.cert" \
    --slurpfile vrf    "${KEYS_DIR}/vrf.skey" \
    --slurpfile kes    "${KEYS_DIR}/kes.skey" \
    '[[ $opcert[0], $vrf[0], $kes[0] ]]' \
    >"${BULK_CREDS}"

# Step 3: synthesise the chain DB ──────────────────────────────────

EPOCH_LENGTH="$(jq -r '.epochLength' "${CONFIGS_DIR}/shelley-genesis.json")"
if [[ -z "${EPOCH_LENGTH}" || "${EPOCH_LENGTH}" == "null" ]]; then
    fail_config "could not read .epochLength from shelley-genesis.json"
fi

# Synthesize 2 epochs to comfortably cover the first epoch boundary
# regardless of slot-zero conventions.
SLOTS_TO_SYNTH=$((EPOCH_LENGTH * 2))

SYNTH_RC=0
db-synthesizer \
    --config "${CONFIGS_DIR}/config.json" \
    --bulk-credentials-file "${BULK_CREDS}" \
    -s "${SLOTS_TO_SYNTH}" \
    --db "${OUT}/chain-db" \
    -f \
    2>"${OUT}/synthesise.stderr.log" \
    || SYNTH_RC=$?

if [[ "${SYNTH_RC}" -ne 0 ]]; then
    fail_tool "synthesise"
fi

# Step 4: identify the epoch boundary slot ─────────────────────────

# The first slot of epoch 1 is `epochLength`. That is the
# epoch-boundary point at which we dump the snapshot.
SNAPSHOT_SLOT="${EPOCH_LENGTH}"

# Step 5: dump the ledger snapshot ─────────────────────────────────

DUMP_RC=0
db-analyser \
    --db "${OUT}/chain-db" \
    --store-ledger "${SNAPSHOT_SLOT}" \
    cardano \
    --config "${CONFIGS_DIR}/config.json" \
    2>"${OUT}/dump.stderr.log" \
    || DUMP_RC=$?

if [[ "${DUMP_RC}" -ne 0 ]]; then
    fail_tool "dump"
fi

# db-analyser writes the snapshot under <chain-db>/<chain-db basename>
# /ledger/ with a slot-named filename. Locate any file whose basename
# starts with the snapshot slot — that's our snapshot.
SNAPSHOT_PATH="$(find "${OUT}/chain-db" -type f -name "${SNAPSHOT_SLOT}*" 2>/dev/null | head -n 1)"
if [[ -z "${SNAPSHOT_PATH}" ]]; then
    # Fallback: search any directory tree under OUT for a slot-named
    # file (db-analyser write location varies between versions).
    SNAPSHOT_PATH="$(find "${OUT}" -type f -name "${SNAPSHOT_SLOT}*" 2>/dev/null | head -n 1)"
fi
if [[ -z "${SNAPSHOT_PATH}" ]]; then
    fail_tool "dump"
fi

# Step 6: feed the snapshot to amaru ───────────────────────────────

CONVERTED_PATH="${OUT}/converted"
mkdir -p "${CONVERTED_PATH}"

CONVERT_RC=0
amaru convert-ledger-state \
    --network "${NETWORK}" \
    --snapshot "${SNAPSHOT_PATH}" \
    --target-dir "${CONVERTED_PATH}" \
    2>"${OUT}/convert.stderr.log" \
    || CONVERT_RC=$?

if [[ "${CONVERT_RC}" -ne 0 ]]; then
    fail_format
fi

# Step 7: PASS ──────────────────────────────────────────────────────

pass
