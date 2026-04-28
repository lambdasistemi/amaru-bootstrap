#!/usr/bin/env bash
#
# Phase 2 bootstrap-producer orchestrator. Implements the contract
# at
# specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md
# and the 8-step state diagram at
# specs/003-amaru-bootstrap-producer/data-model.md.
#
# Pipeline (filled out in T018 + T019; this commit lands T017's
# skeleton with the 8 step functions wired but empty):
#
#   1. Pre-flight: existing-bundle short-circuit, config validation,
#      poll for chain DB, poll for era-readiness, tooling sanity.
#   2. db-analyser dump --v2-in-mem @ target_slot
#   3. snapshot-converter Mem -> Legacy
#   4. amaru convert-ledger-state
#   5. header-extractor list-blocks + get-header loop
#   6. compose nonces.json (jq tail rewrite)
#   7. amaru import-{ledger-state,headers,nonces}
#   8. mv -T <unique-tmp> <final> (atomic commit)
#
# Exit-code classes (data-model.md "Error class registry"):
#   0    success
#   1    cluster-not-ready
#   2    chain-not-era-ready
#   3    configuration-error
#   4    tool-error: dump
#   5    tool-error: emit
#   6    tool-error: convert
#   7    tool-error: extract
#   8    tool-error: nonces
#   9    tool-error: import
#   10   output-write-error
#   ≥64  internal-error (bash trap or unimplemented phase)
#
# Until T018+T019 land, the unimplemented phases exit rc=64
# (internal-error). That keeps every TDD-red spec in T012-T016
# failing with a distinguishable signal.

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

# Globals shared across phases. T018 sets them in phase_preflight;
# T019 reads them in the snapshot pipeline.
# shellcheck disable=SC2034  # consumed by phase_dump (T019).
TARGET_SLOT=0
EPOCH_LENGTH=0

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
# T018+T019 wrap every tool invocation through this so the operator
# can triage which step failed by tailing the matching .stderr file.
# shellcheck disable=SC2329  # consumed by phase functions added in T018+T019.
log_phase() {
    local phase="$1"
    shift
    local logdir="${BUNDLE_DIR}/.logs"
    mkdir -p "${logdir}"
    "$@" 2>"${logdir}/${phase}.stderr"
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

# Step 2: db-analyser dump --v2-in-mem @ target_slot. rc=4 on failure.
phase_dump() {
    : "T019"
}

# Step 3: snapshot-converter Mem -> Legacy. rc=5 on failure.
phase_emit() {
    : "T019"
}

# Step 4: amaru convert-ledger-state. rc=6 on failure.
phase_convert() {
    : "T019"
}

# Step 5: header-extractor list-blocks + get-header loop. rc=7.
phase_extract() {
    : "T019"
}

# Step 6: compose nonces.json from snapshot's nonces + tail rewrite. rc=8.
phase_nonces() {
    : "T019"
}

# Step 7: three chained `amaru import-*` calls. rc=9 on failure.
phase_import() {
    : "T019"
}

# Step 8: mv -T <unique-tmp> <final>. rc=10 on failure.
phase_commit() {
    : "T019"
}

# ─── Main orchestration (skeleton) ────────────────────────────────

main() {
    phase_preflight
    phase_dump
    phase_emit
    phase_convert
    phase_extract
    phase_nonces
    phase_import
    phase_commit
    # Until T018+T019 fill in the phases, signal "not yet implemented"
    # with rc=64 internal-error so the TDD-red bats specs surface the
    # gap loudly (their assertions on rc=0/1/2/3 fail distinctly).
    printf 'bootstrap-producer: T018+T019 not yet wired\n' >&2
    exit 64
}

main
