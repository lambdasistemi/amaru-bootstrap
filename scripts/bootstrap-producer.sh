#!/usr/bin/env bash
#
# Phase 2 bootstrap-producer orchestrator. Implements the contract
# at
# specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md
# and the state diagram at
# specs/003-amaru-bootstrap-producer/data-model.md.
#
# Pipeline (data-model.md state diagram, post-R-011 collapsed emit):
#
#   1. Pre-flight: existing-bundle short-circuit, config validation,
#      poll for chain DB, poll for era-readiness, tooling sanity.
#   2. ledger-state-emitter @ target_slot
#   3. amaru convert-ledger-state
#   4. header-extractor list-blocks + get-header loop
#   5. compose nonces.json (jq tail rewrite)
#   6. amaru import-{ledger-state,headers,nonces}
#   7. mv -T <unique-tmp> <final> (atomic commit)
#
# Exit-code classes (data-model.md "Error class registry"):
#   0    success
#   1    cluster-not-ready
#   2    chain-not-era-ready
#   3    configuration-error
#   4    reserved
#   5    tool-error: emit
#   6    tool-error: convert
#   7    tool-error: extract
#   8    tool-error: nonces
#   9    tool-error: import
#   10   output-write-error
#   >=64 internal-error (bash trap)

set -euo pipefail

# ─── Argument parsing ─────────────────────────────────────────────

if [[ $# -lt 4 ]]; then
    echo "usage: bootstrap-producer <chain-db> <config-dir> <bundle-dir> <network>" >&2
    exit 3
fi

CHAIN_DB="$1"
CONFIG_DIR="$2"
BUNDLE_DIR="$3"
NETWORK="${AMARU_NETWORK:-$4}"

# Env knobs (defaults sized for the antithesis simulator's measured
# ~150x speedup; mainnet-mature operators set AMARU_WAIT_DEADLINE_SECONDS=0
# to force fail-fast on a misconfigured era-history).
AMARU_WAIT_DEADLINE_SECONDS="${AMARU_WAIT_DEADLINE_SECONDS:-5400}"
AMARU_CLUSTER_READY_DEADLINE_SECONDS="${AMARU_CLUSTER_READY_DEADLINE_SECONDS:-300}"
AMARU_POLL_INTERVAL_SECONDS="${AMARU_POLL_INTERVAL_SECONDS:-10}"

# Globals shared across phases. phase_preflight sets TARGET_SLOT and
# EPOCH_LENGTH; the snapshot pipeline below threads further globals
# (UNIQUE_TMP, ACTUAL_SLOT, LEGACY_SNAPSHOT_FILE) between phases as
# each one is computed.
TARGET_SLOT=0
EPOCH_LENGTH=0
UNIQUE_TMP=""
ACTUAL_SLOT=0
LEGACY_SNAPSHOT_FILE=""

# ─── Internal-error trap ──────────────────────────────────────────

# shellcheck disable=SC2329  # invoked indirectly via `trap ... ERR` below.
on_error() {
    local rc=$?
    printf 'bootstrap-producer: internal error rc=%d\n' "$rc" >&2
    exit $((64 + rc))
}
trap on_error ERR

# ─── Per-phase log redirect helper ────────────────────────────────

# log_phase <phase-name> <command...>
# Runs <command...> with stderr redirected to <bundle>/.logs/<phase>.stderr.
# Every tool invocation goes through this so an operator can triage a
# non-zero exit by tailing the matching .stderr file. The .logs dir
# lives at the bundle root (not inside <bundle>/<network>) so logs
# survive the atomic rename in phase_commit.
log_phase() {
    local phase="$1"
    shift
    local logdir="${BUNDLE_DIR}/.logs"
    mkdir -p "${logdir}"
    "$@" 2>"${logdir}/${phase}.stderr"
}

# tail_phase_log <phase-name>
# Emit the last 50 lines of <bundle>/.logs/<phase>.stderr to our
# stderr, prefixed for readability. Per the CLI contract the
# orchestrator surfaces the failing phase's tail on its own stderr so
# the operator does not have to fish around in the bundle volume.
tail_phase_log() {
    local phase="$1"
    local f="${BUNDLE_DIR}/.logs/${phase}.stderr"
    [[ -s "${f}" ]] || return 0
    printf -- '--- last 50 lines of %s ---\n' "${f}" >&2
    tail -n 50 "${f}" >&2 || true
    printf -- '--- end %s ---\n' "${f}" >&2
}

# ─── 8-step state diagram (functions stubbed, T018+T019 fill them) ─

# Step 1: pre-flight (wait + validate + era-readiness predicate).
# Five sub-steps per R-006 + data-model.md state diagram step 1:
#   1.A existing-bundle short-circuit (FR-008 idempotency)
#   1.B config + genesis + epochLength validation
#   1.C Conway-fork-slot derivation (era-readiness predicate input)
#   1.D poll for chain DB to appear  (rc=1 cluster-not-ready)
#   1.E poll for era-readiness predicate (rc=2 chain-not-era-ready)
# The two polls share AMARU_POLL_INTERVAL_SECONDS; their wall-clock
# deadlines are independent (cluster-ready 5min default, era-ready
# 90min default).
phase_preflight() {
    # 1.A existing-bundle short-circuit ----------------------------
    local final_bundle="${BUNDLE_DIR}/${NETWORK}"
    if bundle_complete "${final_bundle}"; then
        printf '+ existing complete bundle at %s - exiting 0 (FR-008)\n' \
               "${final_bundle}"
        exit 0
    fi

    # 1.B config + genesis + epochLength ---------------------------
    [[ -d "${CONFIG_DIR}" ]] \
        || { printf 'config-dir not found: %s\n' "${CONFIG_DIR}" >&2; exit 3; }
    local config_json="${CONFIG_DIR}/config.json"
    local shelley="${CONFIG_DIR}/shelley-genesis.json"
    [[ -f "${config_json}" ]] \
        || { printf 'missing %s\n' "${config_json}" >&2; exit 3; }
    [[ -f "${shelley}" ]] \
        || { printf 'missing %s\n' "${shelley}" >&2; exit 3; }
    jq -e . "${config_json}" >/dev/null 2>&1 \
        || { printf 'config.json unparseable: %s\n' "${config_json}" >&2; exit 3; }
    jq -e . "${shelley}" >/dev/null 2>&1 \
        || { printf 'shelley-genesis.json unparseable: %s\n' "${shelley}" >&2; exit 3; }

    EPOCH_LENGTH=$(jq -r '.epochLength' "${shelley}" 2>/dev/null || true)
    if ! [[ "${EPOCH_LENGTH}" =~ ^[0-9]+$ ]] || (( EPOCH_LENGTH <= 0 )); then
        printf 'epochLength is not a positive integer: %s\n' "${EPOCH_LENGTH}" >&2
        exit 3
    fi

    # 1.C Conway-fork-slot derivation ------------------------------
    # For test-style configs (testnet_42 fixture, antithesis), the
    # node config carries TestConwayHardForkAtEpoch; for mainnet/
    # preprod/preview the era boundaries are negotiated by the
    # protocol and Conway has been live for a long time so the
    # second predicate clause is trivially satisfied. When neither
    # signal is available we conservatively default to 0 (Conway
    # from genesis), matching the testnet_42 fixture.
    local conway_at
    conway_at=$(jq -r '.TestConwayHardForkAtEpoch // empty' "${config_json}")
    local conway_first_slot=0
    if [[ "${conway_at}" =~ ^[0-9]+$ ]]; then
        conway_first_slot=$((conway_at * EPOCH_LENGTH))
    fi

    # 1.D poll for chain DB ----------------------------------------
    local cluster_deadline
    cluster_deadline=$(( $(date +%s) + AMARU_CLUSTER_READY_DEADLINE_SECONDS ))
    local poll_start
    poll_start=$(date +%s)
    while :; do
        if chain_db_alive "${CHAIN_DB}"; then
            break
        fi
        if (( $(date +%s) >= cluster_deadline )); then
            printf '+ cluster-not-ready: chain DB never appeared within %ss\n' \
                   "${AMARU_CLUSTER_READY_DEADLINE_SECONDS}" >&2
            exit 1
        fi
        printf '+ waiting for chain DB to appear (elapsed=%ds)\n' \
               $(( $(date +%s) - poll_start ))
        sleep "${AMARU_POLL_INTERVAL_SECONDS}"
    done

    # 1.E poll for era-readiness predicate -------------------------
    # Predicate (R-010):
    #   tip.era >= Conway
    # AND
    #   tip.slot - 2 * epochLength >= conway_first_slot
    local era_deadline
    era_deadline=$(( $(date +%s) + AMARU_WAIT_DEADLINE_SECONDS ))
    poll_start=$(date +%s)
    local info slot era
    while :; do
        info=""
        if info=$(header-extractor tip-info \
                      --db "${CHAIN_DB}" \
                      --config "${config_json}" 2>/dev/null); then
            slot=$(jq -r '.slot' <<<"${info}")
            era=$(jq -r '.era' <<<"${info}")
            if [[ "${era}" == "Conway" ]] \
                && (( slot - 2 * EPOCH_LENGTH >= conway_first_slot )); then
                printf '+ era-readiness predicate satisfied - target_slot=%d era=%s\n' \
                       "${slot}" "${era}"
                TARGET_SLOT="${slot}"
                return 0
            fi
            printf '+ waiting for chain tip era-readiness - slot=%d era=%s conway_first=%d (elapsed=%ds)\n' \
                   "${slot}" "${era}" "${conway_first_slot}" \
                   $(( $(date +%s) - poll_start ))
        else
            printf '+ waiting for chain DB tip (header-extractor pending, elapsed=%ds)\n' \
                   $(( $(date +%s) - poll_start ))
        fi
        if (( $(date +%s) >= era_deadline )); then
            printf '+ chain-not-era-ready: predicate never held within %ss\n' \
                   "${AMARU_WAIT_DEADLINE_SECONDS}" >&2
            exit 2
        fi
        sleep "${AMARU_POLL_INTERVAL_SECONDS}"
    done
}

# bundle_complete <dir>
# Returns 0 iff <dir> contains every artefact amaru's import-* needs
# (per R-005). Used by phase_preflight's FR-008 short-circuit and
# also by the concurrent-runner loser path in phase_commit (T019).
# shellcheck disable=SC2329  # invoked by phase_preflight + phase_commit.
bundle_complete() {
    local b="$1"
    [[ -d "${b}" ]] || return 1
    [[ -d "${b}/ledger.${NETWORK}.db" ]] || return 1
    [[ -d "${b}/chain.${NETWORK}.db" ]] || return 1
    [[ -f "${b}/nonces.json" ]] || return 1
    [[ -d "${b}/headers" ]] || return 1
    [[ -n "$(find "${b}/headers" -name 'header.*.cbor' -print -quit 2>/dev/null)" ]] || return 1
    return 0
}

# chain_db_alive <chain-db-path>
# Returns 0 iff the cardano-node has begun forging into the
# immutable DB (per R-006 step 3 / data-model.md cluster chain DB
# validation rules).
# shellcheck disable=SC2329  # invoked by phase_preflight.
chain_db_alive() {
    local db="$1"
    [[ -d "${db}/immutable" ]] || return 1
    [[ -n "$(find "${db}/immutable" -name '*.chunk' -print -quit 2>/dev/null)" ]] || return 1
    return 0
}

# Allocate the unique-suffixed staging dir into which the bundle is
# assembled. Per Obs#4 / R-007 the suffix combines $$ + $RANDOM so two
# concurrent producers never share a staging path; the FIRST one to
# `mv -T` into <final> wins, the loser short-circuits via FR-008.
phase_stage_init() {
    local final_bundle="${BUNDLE_DIR}/${NETWORK}"
    UNIQUE_TMP="${final_bundle}.tmp.$$.${RANDOM}"
    rm -rf "${UNIQUE_TMP}"
    mkdir -p "${UNIQUE_TMP}/snapshots" "${UNIQUE_TMP}/headers"
    printf '+ staging at %s\n' "${UNIQUE_TMP}"
}

# Step 2: ledger-state-emitter writes a Legacy ExtLedgerState CBOR file
# with canonical UTxO entries. rc=5 on failure.
phase_emit() {
    local cfg="${CONFIG_DIR}/config.json"
    local legacy_dir="${UNIQUE_TMP}/legacy-in"
    mkdir -p "${legacy_dir}"
    LEGACY_SNAPSHOT_FILE="${legacy_dir}/${TARGET_SLOT}.cbor"
    printf '+ ledger-state-emitter @ %d\n' "${TARGET_SLOT}"
    local rc=0
    log_phase emit ledger-state-emitter \
        --db "${CHAIN_DB}" \
        --config "${cfg}" \
        --target-slot "${TARGET_SLOT}" \
        --out "${LEGACY_SNAPSHOT_FILE}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'ledger-state-emitter failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/emit.stderr" >&2
        tail_phase_log emit
        exit 5
    fi
    if [[ ! -f "${LEGACY_SNAPSHOT_FILE}" ]]; then
        printf 'ledger-state-emitter produced no output at %s\n' \
               "${LEGACY_SNAPSHOT_FILE}" >&2
        exit 5
    fi
}

# Step 3: amaru convert-ledger-state. rc=6 on failure.
# Writes <slot>.<hash>.cbor + nonces.<slot>.<hash>.json + history.<slot>.<hash>.json
# into <staging>/snapshots/. amaru's import-ledger-state requires the
# era-history file to live alongside the snapshot for testnet variants.
phase_convert() {
    printf '+ amaru convert-ledger-state\n'
    local rc=0
    log_phase convert amaru convert-ledger-state \
        --network "${NETWORK}" \
        --snapshot "${LEGACY_SNAPSHOT_FILE}" \
        --target-dir "${UNIQUE_TMP}/snapshots" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'amaru convert-ledger-state failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/convert.stderr" >&2
        tail_phase_log convert
        exit 6
    fi
    local cbor_count
    cbor_count=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name '*.cbor' 2>/dev/null | wc -l)
    if (( cbor_count == 0 )); then
        printf 'amaru convert-ledger-state produced no .cbor in %s\n' \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 6
    fi
    local snapshot_file snapshot_base
    snapshot_file=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name '*.cbor' 2>/dev/null | sort | tail -n 1)
    snapshot_base=$(basename "${snapshot_file}")
    ACTUAL_SLOT="${snapshot_base%%.*}"
    if ! [[ "${ACTUAL_SLOT}" =~ ^[0-9]+$ ]]; then
        printf 'converted snapshot filename lacks numeric slot prefix: %s\n' \
               "${snapshot_base}" >&2
        exit 6
    fi
}

# Step 4: header-extractor list-blocks + get-header loop. rc=7.
# Per amaru-loader.sh's pipeline: extract two header pairs, one near
# the snapshot slot and one near the previous-epoch boundary, so amaru
# has the parent hashes it needs to compute the epoch's active nonce.
# Our list-blocks returns chain-order ascending, so we take the LAST
# two blocks of each filtered window (amaru-loader uses .[0:2] against
# db-server which yields the same blocks under its descending order).
phase_extract() {
    local cfg="${CONFIG_DIR}/config.json"
    local list_json="${UNIQUE_TMP}/blocks.json"
    printf '+ header-extractor list-blocks\n'
    local rc=0
    log_phase extract-list bash -c "header-extractor list-blocks --db \"\$1\" --config \"\$2\" >\"\$3\"" \
        _ "${CHAIN_DB}" "${cfg}" "${list_json}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'header-extractor list-blocks failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/extract-list.stderr" >&2
        exit 7
    fi
    local prev_boundary=$(( ACTUAL_SLOT - EPOCH_LENGTH ))
    if (( prev_boundary < 0 )); then
        prev_boundary=0
    fi
    local headers_csv="${UNIQUE_TMP}/headers.csv"
    : >"${headers_csv}"
    if ! jq -rc \
        --argjson last "${ACTUAL_SLOT}" \
        --argjson prev "${prev_boundary}" \
        '
          (.data | map(select(.[0] <= $last))  | .[-2:] | .[]),
          (.data | map(select(.[0] <= $prev))  | .[-2:] | .[])
          | @csv
        ' \
        "${list_json}" >"${headers_csv}" 2>"${BUNDLE_DIR}/.logs/extract-filter.stderr"
    then
        printf 'header filter pipeline failed; see %s\n' \
               "${BUNDLE_DIR}/.logs/extract-filter.stderr" >&2
        exit 7
    fi
    if [[ ! -s "${headers_csv}" ]]; then
        printf 'no headers selected for slots <=%d / <=%d\n' \
               "${ACTUAL_SLOT}" "${prev_boundary}" >&2
        exit 7
    fi
    while IFS=, read -ra hdr; do
        [[ ${#hdr[@]} -eq 2 ]] || continue
        local slot=${hdr[0]//\"/}
        local hash=${hdr[1]//\"/}
        [[ -n "${slot}" && -n "${hash}" ]] || continue
        local out="${UNIQUE_TMP}/headers/header.${slot}.${hash}.cbor"
        printf '+ header-extractor get-header %s.%s\n' "${slot}" "${hash}"
        rc=0
        log_phase "extract-${slot}" bash -c "header-extractor get-header \"\$1\" --db \"\$2\" --config \"\$3\" >\"\$4\"" \
            _ "${slot}.${hash}" "${CHAIN_DB}" "${cfg}" "${out}" \
            || rc=$?
        if (( rc != 0 )); then
            printf 'header-extractor get-header %s.%s failed (rc=%d)\n' \
                   "${slot}" "${hash}" "${rc}" >&2
            exit 7
        fi
    done <"${headers_csv}"
}

# Step 5: compose nonces.json from snapshot's nonces + tail rewrite. rc=8.
# amaru convert-ledger-state writes nonces.<slot>.<hash>.json with a
# zero-byte `tail`. We rewrite that field to the parent hash from the
# previous-epoch header batch (the LAST hash with slot <= prev_boundary)
# so amaru's epoch-transition nonce computation has a real anchor.
phase_nonces() {
    local nonces_src
    nonces_src=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name 'nonces.*.json' 2>/dev/null | sort | tail -n 1)
    if [[ -z "${nonces_src}" ]]; then
        printf 'no nonces.*.json under %s\n' \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 8
    fi
    cp "${nonces_src}" "${UNIQUE_TMP}/nonces.json"
    local prev_hash=""
    local headers_csv="${UNIQUE_TMP}/headers.csv"
    if [[ -s "${headers_csv}" ]]; then
        prev_hash=$(awk -F, 'NR==3 {gsub(/"/,"",$2); print $2}' \
                    "${headers_csv}" 2>/dev/null || true)
        if [[ -z "${prev_hash}" ]]; then
            prev_hash=$(awk -F, 'END {gsub(/"/,"",$2); print $2}' \
                        "${headers_csv}" 2>/dev/null || true)
        fi
    fi
    if [[ -z "${prev_hash}" ]]; then
        printf 'no previous-epoch hash to anchor nonces.tail\n' >&2
        exit 8
    fi
    printf '+ rewriting nonces.tail = %s\n' "${prev_hash}"
    local tmp_json="${UNIQUE_TMP}/nonces.json.tmp"
    if ! jq --arg t "${prev_hash}" '.tail = $t' \
        "${UNIQUE_TMP}/nonces.json" \
        >"${tmp_json}" 2>"${BUNDLE_DIR}/.logs/nonces.stderr"
    then
        printf 'nonces tail rewrite failed; see %s\n' \
               "${BUNDLE_DIR}/.logs/nonces.stderr" >&2
        exit 8
    fi
    mv "${tmp_json}" "${UNIQUE_TMP}/nonces.json"
}

# Step 6: three chained `amaru import-*` calls. rc=9 on failure.
# Paths follow R-005 / Obs#3: ledger.<network>.db, chain.<network>.db,
# headers/* all at the staging root so the final `mv -T` lands them in
# the canonical bundle layout.
phase_import() {
    local ledger_dir="${UNIQUE_TMP}/ledger.${NETWORK}.db"
    local chain_dir="${UNIQUE_TMP}/chain.${NETWORK}.db"
    local snapshots_dir="${UNIQUE_TMP}/snapshots"
    mkdir -p "${ledger_dir}" "${chain_dir}"

    printf '+ amaru import-ledger-state\n'
    local rc=0
    log_phase import-ledger-state amaru import-ledger-state \
        --network "${NETWORK}" \
        --ledger-dir "${ledger_dir}" \
        --snapshot-dir "${snapshots_dir}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'amaru import-ledger-state failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/import-ledger-state.stderr" >&2
        tail_phase_log import-ledger-state
        exit 9
    fi

    printf '+ amaru import-headers\n'
    local hdr_args=()
    while IFS= read -r -d '' f; do
        hdr_args+=(--header-file "${f}")
    done < <(find "${UNIQUE_TMP}/headers" -name 'header.*.cbor' -print0 \
                  | sort -z)
    rc=0
    log_phase import-headers amaru import-headers \
        --network "${NETWORK}" \
        --chain-dir "${chain_dir}" \
        "${hdr_args[@]}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'amaru import-headers failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/import-headers.stderr" >&2
        tail_phase_log import-headers
        exit 9
    fi

    printf '+ amaru import-nonces\n'
    rc=0
    log_phase import-nonces amaru import-nonces \
        --network "${NETWORK}" \
        --nonces-file "${UNIQUE_TMP}/nonces.json" \
        --chain-dir "${chain_dir}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'amaru import-nonces failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/import-nonces.stderr" >&2
        tail_phase_log import-nonces
        exit 9
    fi
}

# Step 7: mv -T <unique-tmp> <final>. rc=10 on failure.
# `mv -T` invokes renameat2(NOREPLACE) on Linux and is the atomic
# commit per R-007. On EEXIST another producer won the race; fall back
# to bundle_complete which short-circuits with rc=0 (FR-008).
phase_commit() {
    local final_bundle="${BUNDLE_DIR}/${NETWORK}"
    rm -rf "${UNIQUE_TMP}/legacy-in" \
           "${UNIQUE_TMP}/blocks.json" \
           "${UNIQUE_TMP}/headers.csv"
    if mv -T "${UNIQUE_TMP}" "${final_bundle}" 2>"${BUNDLE_DIR}/.logs/commit.stderr"
    then
        printf 'wrote %s\n' "${final_bundle}"
        return 0
    fi
    if bundle_complete "${final_bundle}"; then
        printf '+ lost atomic-commit race - existing complete bundle wins (rc=0)\n'
        rm -rf "${UNIQUE_TMP}"
        exit 0
    fi
    printf 'rename to %s failed; see %s\n' \
           "${final_bundle}" "${BUNDLE_DIR}/.logs/commit.stderr" >&2
    exit 10
}

# ─── Main orchestration (skeleton) ────────────────────────────────

main() {
    phase_preflight
    phase_stage_init
    phase_emit
    phase_convert
    phase_extract
    phase_nonces
    phase_import
    phase_commit
}

main
