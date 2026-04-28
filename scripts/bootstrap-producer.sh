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

# Hide unused-warning shellcheck — phases T018+T019 read these.
: "${CHAIN_DB}" "${CONFIG_DIR}" "${BUNDLE_DIR}" "${NETWORK}"
: "${AMARU_WAIT_DEADLINE_SECONDS}" "${AMARU_CLUSTER_READY_DEADLINE_SECONDS}" "${AMARU_POLL_INTERVAL_SECONDS}"

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
# T018: existing-bundle short-circuit, config validation +
# epochLength extraction + era-history derivation, the two polling
# loops (cluster-ready, era-readiness predicate per R-010), tooling
# sanity.
phase_preflight() {
    : "T018"
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
