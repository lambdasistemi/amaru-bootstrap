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
#   2. ledger-state-emitter @ target_slot and the two prior epochs
#   3. amaru convert-ledger-state for all emitted snapshots
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
# (UNIQUE_TMP, ACTUAL_SLOT, LEGACY_SNAPSHOT_FILES) between phases as
# each one is computed.
TARGET_SLOT=0
EPOCH_LENGTH=0
UNIQUE_TMP=""
ACTUAL_SLOT=0
LEGACY_SNAPSHOT_FILES=()
SNAPSHOT_SLOTS=()

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

## ensure_era_history_input <out-path>
##
## Build a single-era Conway era_history JSON anchored at the
## genesis (epoch 0, slot 0, time 0) using the genesis epochLength.
## This is what amaru `convert-ledger-state --era-history-file` needs
## to compute correct epoch boundaries — without it the converter
## defaults to the network's mainnet/preprod era-history (epoch_size
## 86400) and treats every short-epoch slot as still-in-epoch-0,
## producing wrong active/candidate nonces in the snapshot's
## nonces.<slot>.<hash>.json. amaru run then verifies header VRFs
## against those wrong nonces and fails. See
## https://github.com/lambdasistemi/amaru-bootstrap/issues/37.
ensure_era_history_input() {
    local out="$1"
    cat >"${out}" <<JSON
{
  "stability_window": $(( 3 * EPOCH_LENGTH )),
  "eras": [
    {
      "start": {"time": 0, "slot": 0, "epoch": 0},
      "end": null,
      "params": {
        "epoch_size_slots": ${EPOCH_LENGTH},
        "slot_length": 1000,
        "era_name": "Conway"
      }
    }
  ]
}
JSON
}

patch_converted_era_history() {
    local history tmp count=0

    for history in "${UNIQUE_TMP}/snapshots"/history.*.json; do
        [[ -e "${history}" ]] || continue
        count=$(( count + 1 ))
        tmp="${history}.tmp"
        if ! jq --argjson epochLength "${EPOCH_LENGTH}" \
            '(.eras[] | select(.end == null) | .params.epoch_size_slots) = $epochLength' \
            "${history}" >"${tmp}" 2>"${BUNDLE_DIR}/.logs/history.stderr"
        then
            printf 'era-history patch failed for %s; see %s\n' \
                   "${history}" "${BUNDLE_DIR}/.logs/history.stderr" >&2
            rm -f "${tmp}"
            exit 6
        fi
        mv "${tmp}" "${history}"
    done

    if (( count == 0 )); then
        printf 'amaru convert-ledger-state produced no history.*.json files in %s\n' \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 6
    fi
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
    #   chain has crossed the boundary into epoch >= 3
    # AND
    #   the chain has at least one immutable block in completed epoch
    #   (tip_epoch - 1).
    #
    # Rationale: amaru's bootstrap invariant
    # (initial_stake_distributions in crates/amaru-ledger/src/state.rs,
    #  comment "the most recent snapshot we have is necessarily `e`,
    #  since `e + 1` designates the ongoing epoch") requires the
    #  bundle's latest snapshot tier to represent the just-completed
    #  epoch K-1. The chain follower's first applied slot must then
    #  fall in epoch K so that compute_rewards in epoch K uses
    #  for_epoch(K-1) (which exists) and the K-1->K transition creates
    #  tier K-1 *fresh* (no-op, same data) before compute_rewards in
    #  epoch K+1 needs for_epoch(K).
    #
    # That requires anchoring at the LAST IMMUTABLE BLOCK in K-1 — any
    # earlier slot in K-1 leaves blocks of K-1 in the chain follower's
    # path, and compute_rewards (which fires when relative_slot >=
    # stability_window, often early on short-epoch testnets) advances
    # the deque before the K-1->K boundary, breaking the rotation.
    #
    # ledger-state-emitter takes the FIRST immutable block at-or-after
    # the requested slot (lib/LedgerStateEmitter.hs:410), so a fixed
    # offset (e.g. K*L-1) can overshoot into epoch K on sparse chains.
    # Pre-query the immutable block list and pick the actual highest
    # slot < K*L: the resulting bundle is guaranteed to anchor in K-1.
    local era_deadline
    era_deadline=$(( $(date +%s) + AMARU_WAIT_DEADLINE_SECONDS ))
    poll_start=$(date +%s)
    local info slot era tip_err tip_epoch target_slot
    local list_json
    tip_err="${BUNDLE_DIR}/.logs/tip-info.stderr"
    list_json="${BUNDLE_DIR}/.logs/preflight-blocks.json"
    mkdir -p "${BUNDLE_DIR}/.logs"
    while :; do
        info=""
        if info=$(header-extractor tip-info \
                      --db "${CHAIN_DB}" \
                      --config "${config_json}" 2>"${tip_err}"); then
            slot=$(jq -r '.slot' <<<"${info}")
            era=$(jq -r '.era' <<<"${info}")
            tip_epoch=$(( slot / EPOCH_LENGTH ))
            if [[ "${era}" == "Conway" ]] \
                && (( tip_epoch >= 3 )); then
                if ! header-extractor list-blocks \
                        --db "${CHAIN_DB}" \
                        --config "${config_json}" \
                        >"${list_json}" 2>"${BUNDLE_DIR}/.logs/preflight-list-blocks.stderr"
                then
                    printf '+ preflight list-blocks failed; will retry\n'
                else
                    local completed_epoch=$(( tip_epoch - 1 ))
                    local first_epoch=$(( completed_epoch - 2 ))
                    local snapshot_slots=()
                    local snapshot_epoch snapshot_start snapshot_end snapshot_slot
                    if (( first_epoch >= 0 )); then
                        for snapshot_epoch in "${first_epoch}" "$(( first_epoch + 1 ))" "${completed_epoch}"; do
                            snapshot_start=$(( snapshot_epoch * EPOCH_LENGTH ))
                            snapshot_end=$(( (snapshot_epoch + 1) * EPOCH_LENGTH ))
                            snapshot_slot=$(jq -r \
                                --argjson start "${snapshot_start}" \
                                --argjson end "${snapshot_end}" \
                                '.data
                                 | map(select(.[0] >= $start and .[0] < $end))
                                 | (max_by(.[0]) // empty)
                                 | .[0]' \
                                "${list_json}")
                            [[ "${snapshot_slot}" =~ ^[0-9]+$ ]] || break
                            snapshot_slots+=("${snapshot_slot}")
                        done
                    fi
                    if (( ${#snapshot_slots[@]} == 3 )) \
                        && (( snapshot_slots[0] >= conway_first_slot )); then
                        target_slot="${snapshot_slots[2]}"
                        printf '+ era-readiness predicate satisfied - target_slot=%d (last block of completed epoch %d) snapshot_slots=%s,%s,%s tip_slot=%d era=%s\n' \
                               "${target_slot}" "${completed_epoch}" \
                               "${snapshot_slots[0]}" "${snapshot_slots[1]}" "${snapshot_slots[2]}" \
                               "${slot}" "${era}"
                        TARGET_SLOT="${target_slot}"
                        SNAPSHOT_SLOTS=("${snapshot_slots[@]}")
                        return 0
                    fi
                fi
            fi
            printf '+ waiting for chain to cross 3rd-epoch boundary - tip_slot=%d tip_epoch=%d (need >=3) era=%s (elapsed=%ds)\n' \
                   "${slot}" "${tip_epoch}" "${era}" \
                   $(( $(date +%s) - poll_start ))
        else
            if grep -qiE 'FsInsufficientPermissions|Read-only file system|permission denied' "${tip_err}" 2>/dev/null; then
                printf 'header-extractor tip-info cannot open chain DB; mount the cardano-node chain DB read-write (the producer only reads immutable chunks, but consensus validation opens chunk files with write permissions). See %s\n' \
                       "${tip_err}" >&2
                tail_phase_log tip-info
                exit 7
            fi
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
    [[ -d "${b}/ledger.${NETWORK}.db/live" ]] || return 1
    [[ -d "${b}/chain.${NETWORK}.db" ]] || return 1
    [[ -f "${b}/nonces.json" ]] || return 1
    [[ -d "${b}/snapshots" ]] || return 1
    [[ -d "${b}/headers" ]] || return 1
    local header_count
    header_count=$(find "${b}/headers" -name 'header.*.cbor' 2>/dev/null | wc -l)
    (( header_count >= 4 )) || return 1
    local snapshot_name snapshot_base snapshot_slot snapshot_hash
    snapshot_name=$(find "${b}/snapshots" -maxdepth 1 \
        -name '*.cbor' -printf '%f\n' 2>/dev/null \
        | awk -F. '$1 ~ /^[0-9]+$/ { print $1 "\t" $0 }' \
        | sort -n -k1,1 \
        | tail -n 1 \
        | cut -f2-)
    [[ -n "${snapshot_name}" ]] || return 1
    snapshot_base="${snapshot_name%.cbor}"
    snapshot_slot="${snapshot_base%%.*}"
    snapshot_hash="${snapshot_base#*.}"
    [[ "${snapshot_slot}" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${snapshot_hash}" && "${snapshot_hash}" != "${snapshot_base}" ]] || return 1
    [[ -f "${b}/headers/header.${snapshot_slot}.${snapshot_hash}.cbor" ]] || return 1
    local snapshots=()
    local d base
    for d in "${b}/ledger.${NETWORK}.db"/*; do
        [[ -d "${d}" ]] || continue
        base=$(basename "${d}")
        if [[ "${base}" =~ ^[0-9]+$ ]]; then
            snapshots+=("${base}")
        fi
    done
    (( ${#snapshots[@]} >= 3 )) || return 1
    mapfile -t snapshots < <(printf '%s\n' "${snapshots[@]}" | sort -n)
    local latest="${snapshots[$(( ${#snapshots[@]} - 1 ))]}"
    (( latest >= 2 )) || return 1
    [[ -d "${b}/ledger.${NETWORK}.db/$(( latest - 2 ))" ]] || return 1
    [[ -d "${b}/ledger.${NETWORK}.db/$(( latest - 1 ))" ]] || return 1
    [[ -d "${b}/ledger.${NETWORK}.db/${latest}" ]] || return 1
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

# Step 2: ledger-state-emitter writes Legacy ExtLedgerState CBOR
# files with canonical UTxO entries. Amaru run needs the live ledger
# plus three historical epoch snapshots: the target epoch and the two
# prior epochs used for rewards and leader-schedule stake distribution.
# rc=5 on failure.
phase_emit() {
    local cfg="${CONFIG_DIR}/config.json"
    local legacy_dir="${UNIQUE_TMP}/legacy-in"
    mkdir -p "${legacy_dir}"
    LEGACY_SNAPSHOT_FILES=()

    local slots=("${SNAPSHOT_SLOTS[@]}")
    if (( ${#slots[@]} == 0 )); then
        slots=(
            $(( TARGET_SLOT - (2 * EPOCH_LENGTH) ))
            $(( TARGET_SLOT - EPOCH_LENGTH ))
            "${TARGET_SLOT}"
        )
    fi
    local slot out rc
    for slot in "${slots[@]}"; do
        if (( slot < 0 )); then
            printf 'internal error: negative snapshot slot %d\n' "${slot}" >&2
            exit 5
        fi
        out="${legacy_dir}/${slot}.cbor"
        printf '+ ledger-state-emitter @ %d\n' "${slot}"
        rc=0
        log_phase "emit-${slot}" ledger-state-emitter \
            --db "${CHAIN_DB}" \
            --config "${cfg}" \
            --target-slot "${slot}" \
            --out "${out}" \
            || rc=$?
        if (( rc != 0 )); then
            printf 'ledger-state-emitter failed at slot %d (rc=%d); see %s\n' \
                   "${slot}" "${rc}" "${BUNDLE_DIR}/.logs/emit-${slot}.stderr" >&2
            tail_phase_log "emit-${slot}"
            exit 5
        fi
        if [[ ! -f "${out}" ]]; then
            printf 'ledger-state-emitter produced no output at %s\n' \
                   "${out}" >&2
            exit 5
        fi
        LEGACY_SNAPSHOT_FILES+=("${out}")
    done
}

# Step 3: amaru convert-ledger-state. rc=6 on failure.
# Writes <slot>.<hash>.cbor + nonces.<slot>.<hash>.json + history.<slot>.<hash>.json
# into <staging>/snapshots/. amaru's import-ledger-state requires the
# era-history file to live alongside the snapshot for testnet variants.
# Amaru's converter currently fills the open-ended current era with the
# network default epoch size; for custom short-epoch testnets the
# producer corrects that sidecar from the node genesis before import.
phase_convert() {
    local snapshot slot rc
    local era_history_input="${UNIQUE_TMP}/era-history.input.json"
    ensure_era_history_input "${era_history_input}"
    for snapshot in "${LEGACY_SNAPSHOT_FILES[@]}"; do
        slot=$(basename "${snapshot}" .cbor)
        printf '+ amaru convert-ledger-state @ %s\n' "${slot}"
        rc=0
        log_phase "convert-${slot}" amaru convert-ledger-state \
            --network "${NETWORK}" \
            --snapshot "${snapshot}" \
            --target-dir "${UNIQUE_TMP}/snapshots" \
            --era-history-file "${era_history_input}" \
            || rc=$?
        if (( rc != 0 )); then
            printf 'amaru convert-ledger-state failed at slot %s (rc=%d); see %s\n' \
                   "${slot}" "${rc}" "${BUNDLE_DIR}/.logs/convert-${slot}.stderr" >&2
            tail_phase_log "convert-${slot}"
            exit 6
        fi
    done

    patch_converted_era_history

    local cbor_count
    cbor_count=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name '*.cbor' 2>/dev/null | wc -l)
    if (( cbor_count < 3 )); then
        printf 'amaru convert-ledger-state produced %d .cbor files in %s, need at least 3\n' \
               "${cbor_count}" \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 6
    fi
    local snapshot_name snapshot_file snapshot_base
    snapshot_name=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name '*.cbor' -printf '%f\n' 2>/dev/null \
        | awk -F. '$1 ~ /^[0-9]+$/ { print $1 "\t" $0 }' \
        | sort -n -k1,1 \
        | tail -n 1 \
        | cut -f2-)
    if [[ -z "${snapshot_name}" ]]; then
        printf 'no numerically-prefixed converted snapshot under %s\n' \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 6
    fi
    snapshot_file="${UNIQUE_TMP}/snapshots/${snapshot_name}"
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
    # The "previous epoch boundary" we want is the LAST SLOT of the
    # epoch BEFORE the snapshot's epoch — not "one epoch back from the
    # snapshot slot". For ACTUAL_SLOT in epoch K, that is
    #   prev_boundary = K * EPOCH_LENGTH - 1
    # which is the last slot of epoch K-1. The previous code used
    # `ACTUAL_SLOT - EPOCH_LENGTH`, which is just the slot at the same
    # in-epoch offset one epoch earlier (e.g. slot 179 for ACTUAL_SLOT
    # 299). The block selected from there is mid-prev-epoch, so the
    # `tail` rewritten below pointed at the wrong header. amaru then
    # mixed the wrong tail at each downstream epoch boundary,
    # producing a different active nonce than cardano-node, which made
    # VRF verification fail at every epoch boundary past the anchor.
    local current_epoch=$(( ACTUAL_SLOT / EPOCH_LENGTH ))
    local prev_boundary=$(( current_epoch * EPOCH_LENGTH - 1 ))
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
    local nonces_name
    nonces_name=$(find "${UNIQUE_TMP}/snapshots" -maxdepth 1 \
        -name 'nonces.*.json' -printf '%f\n' 2>/dev/null \
        | awk -F. '$2 ~ /^[0-9]+$/ { print $2 "\t" $0 }' \
        | sort -n -k1,1 \
        | tail -n 1 \
        | cut -f2-)
    if [[ -z "${nonces_name}" ]]; then
        printf 'no nonces.*.json under %s\n' \
               "${UNIQUE_TMP}/snapshots" >&2
        exit 8
    fi
    nonces_src="${UNIQUE_TMP}/snapshots/${nonces_name}"
    cp "${nonces_src}" "${UNIQUE_TMP}/nonces.json"
    # nonces.tail must be the hash of the LAST block of the previous
    # epoch (= the slot the cardano-node Praos rule would have stored
    # as `praosStateLabNonce` AT that boundary, which becomes
    # `praosStateLastEpochBlockNonce` for the active-nonce mix when
    # the next boundary fires). amaru `evolve_nonce` later does:
    #
    #   load_header(parent.tail).parent()
    #
    # to recover that lab value, so the imported tail must point to
    # the LAST header of the previous epoch — `load_header(hash_N).parent()`
    # then yields `hash_{N-1}`, exactly the lab value cardano stored.
    #
    # phase_extract emits headers.csv with current-epoch headers first
    # (last two of the snapshot's epoch) and prev-epoch headers second
    # (last two of the previous epoch). The LAST line of the file is
    # therefore the last block of the previous epoch — which is what
    # we want.
    local prev_hash=""
    local headers_csv="${UNIQUE_TMP}/headers.csv"
    if [[ -s "${headers_csv}" ]]; then
        prev_hash=$(awk -F, 'END {gsub(/"/,"",$2); print $2}' \
                    "${headers_csv}" 2>/dev/null || true)
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
    # --era-history-file is mandatory for short-epoch testnets:
    # without it, import-nonces falls back to the network default
    # (preprod's 86400 slots/epoch) and stores the wrong `epoch` for
    # the imported snapshot point. amaru run then sees a fake
    # epoch-boundary crossing on the FIRST roll-forward (parent.epoch=0
    # vs current_epoch=N from the correct era-history at run time)
    # and recomputes a new active nonce that no longer matches what
    # cardano-node actually used to sign the block, producing
    # `Invalid VRF proof: VerificationFailed`. See
    # https://github.com/lambdasistemi/amaru-bootstrap/issues/34.
    log_phase import-nonces amaru import-nonces \
        --network "${NETWORK}" \
        --nonces-file "${UNIQUE_TMP}/nonces.json" \
        --era-history-file "${UNIQUE_TMP}/era-history.input.json" \
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
