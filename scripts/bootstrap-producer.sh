#!/usr/bin/env bash
#
# Phase 2 bootstrap-producer orchestrator. Implements the contract
# at
# specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md
# and the state diagram at
# specs/003-amaru-bootstrap-producer/data-model.md.
#
# Pipeline (upstream-bootstrap projection):
#
#   1. Pre-flight: existing-bundle short-circuit, config validation,
#      poll for chain DB, poll for era-readiness, derive the three
#      consecutive snapshot slots.
#   2. Compose targets.json (epoch/slot/hash/parent_point) + snapshots.json
#      from the chain's own block list.
#   3. amaru create-snapshots (db-analyser engine, Koios/Mithril bypassed via
#      --targets-file + --cardano-db-dir) -> per-epoch snapshot dirs with
#      packaged bootstrap headers.
#   4. Write per-snapshot era-history sidecars + bundle era-history.json.
#   5. amaru bootstrap -> ledger.<net>.db + chain.<net>.db (derives nonces
#      from the snapshot, imports the packaged headers).
#   6. mv -T <unique-tmp> <final> (atomic commit)
#
# Exit-code classes (data-model.md "Error class registry"):
#   0    success
#   1    cluster-not-ready
#   2    chain-not-era-ready
#   3    configuration-error
#   4    reserved
#   5    tool-error: targets
#   6    tool-error: create-snapshots
#   7    reserved
#   8    reserved
#   9    tool-error: bootstrap
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
NET_LC="${NETWORK,,}"

# Env knobs (defaults sized for the antithesis simulator's measured
# ~150x speedup; mainnet-mature operators set AMARU_WAIT_DEADLINE_SECONDS=0
# to force fail-fast on a misconfigured era-history).
AMARU_WAIT_DEADLINE_SECONDS="${AMARU_WAIT_DEADLINE_SECONDS:-5400}"
AMARU_CLUSTER_READY_DEADLINE_SECONDS="${AMARU_CLUSTER_READY_DEADLINE_SECONDS:-300}"
AMARU_POLL_INTERVAL_SECONDS="${AMARU_POLL_INTERVAL_SECONDS:-10}"

# Globals shared across phases. phase_preflight sets EPOCH_LENGTH and the
# three SNAPSHOT_SLOTS; the snapshot pipeline below threads UNIQUE_TMP
# between phases as it is computed.
EPOCH_LENGTH=0
UNIQUE_TMP=""
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
## amaru `bootstrap` consumes this per-snapshot sidecar for custom
## testnets (make_era_history reads history.<slot>.<hash>.json next to
## the snapshot dir); the same document is shipped at the bundle root
## as era-history.json so `amaru run --era-history-file` can override
## the network default at consume time. Without it amaru defaults to
## the built-in testnet era-history (epoch_size 86400) and treats every
## short-epoch slot as still-in-epoch-0, producing wrong nonces. See
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

# ─── State diagram ────────────────────────────────────────────────

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
# Returns 0 iff <dir> contains every artefact amaru `run` needs from a
# bootstrapped bundle (per the upstream-bootstrap projection): a ledger
# DB with a live view and at least three historical epoch snapshots, and
# a chain DB. nonces and bootstrap headers are baked into the chain DB by
# `amaru bootstrap`, so they are no longer separate bundle artefacts.
# Used by phase_preflight's FR-008 short-circuit and the concurrent-runner
# loser path in phase_commit.
# shellcheck disable=SC2329  # invoked by phase_preflight + phase_commit.
bundle_complete() {
    local b="$1"
    [[ -d "${b}" ]] || return 1
    [[ -d "${b}/ledger.${NET_LC}.db" ]] || return 1
    [[ -d "${b}/ledger.${NET_LC}.db/live" ]] || return 1
    [[ -d "${b}/chain.${NET_LC}.db" ]] || return 1
    local snapshots=()
    local d base
    for d in "${b}/ledger.${NET_LC}.db"/*; do
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
    [[ -d "${b}/ledger.${NET_LC}.db/$(( latest - 2 ))" ]] || return 1
    [[ -d "${b}/ledger.${NET_LC}.db/$(( latest - 1 ))" ]] || return 1
    [[ -d "${b}/ledger.${NET_LC}.db/${latest}" ]] || return 1
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
# The staging dir doubles as amaru's working directory: create-snapshots
# and bootstrap resolve snapshots/<net> + data/<net> relative to it.
phase_stage_init() {
    local final_bundle="${BUNDLE_DIR}/${NETWORK}"
    UNIQUE_TMP="${final_bundle}.tmp.$$.${RANDOM}"
    rm -rf "${UNIQUE_TMP}"
    mkdir -p "${UNIQUE_TMP}/snapshots/${NET_LC}" \
             "${UNIQUE_TMP}/data/${NET_LC}/epoch-snapshots" \
             "${UNIQUE_TMP}/bootstrap-config/${NET_LC}"
    printf '+ staging at %s\n' "${UNIQUE_TMP}"
}

# Step 2: compose targets.json + snapshots.json. rc=5 on failure.
# create-snapshots needs, per snapshot epoch, the last block's
# (epoch, slot, hash, parent_point) — the same shape Koios resolution
# yields on public networks. We read it straight from the chain's own
# block list (preflight-blocks.json), bypassing Koios entirely.
phase_targets() {
    local list_json="${BUNDLE_DIR}/.logs/preflight-blocks.json"
    [[ -s "${list_json}" ]] \
        || { printf 'missing preflight block list %s\n' "${list_json}" >&2; exit 5; }
    if (( ${#SNAPSHOT_SLOTS[@]} != 3 )); then
        printf 'expected 3 snapshot slots, got %d\n' "${#SNAPSHOT_SLOTS[@]}" >&2
        exit 5
    fi

    local targets="[]"
    local snapshots_meta="[]"
    local slot hash parent epoch parent_point
    for slot in "${SNAPSHOT_SLOTS[@]}"; do
        hash=$(jq -r --argjson s "${slot}" \
            '.data | map(select(.[0] == $s)) | (.[0][1] // empty)' "${list_json}")
        if [[ -z "${hash}" ]]; then
            printf 'no block hash for snapshot slot %s in %s\n' "${slot}" "${list_json}" >&2
            exit 5
        fi
        parent=$(jq -c --argjson s "${slot}" \
            '.data | map(select(.[0] < $s)) | (max_by(.[0]) // empty)' "${list_json}")
        if [[ -n "${parent}" && "${parent}" != "null" ]]; then
            parent_point="$(jq -r '.[0]' <<<"${parent}").$(jq -r '.[1]' <<<"${parent}")"
        else
            printf 'no parent block for snapshot slot %s (chain too short?)\n' "${slot}" >&2
            exit 5
        fi
        epoch=$(( slot / EPOCH_LENGTH ))
        targets=$(jq \
            --argjson e "${epoch}" --argjson s "${slot}" \
            --arg h "${hash}" --arg p "${parent_point}" \
            '. + [{epoch: $e, slot: $s, hash: $h, parent_point: $p}]' \
            <<<"${targets}")
        snapshots_meta=$(jq \
            --argjson e "${epoch}" --arg pt "${slot}.${hash}" --arg pp "${parent_point}" \
            '. + [{epoch: $e, point: $pt, parent_point: $pp, url: ""}]' \
            <<<"${snapshots_meta}")
    done

    printf '%s\n' "${targets}" >"${UNIQUE_TMP}/targets.json"
    printf '%s\n' "${snapshots_meta}" >"${UNIQUE_TMP}/bootstrap-config/${NET_LC}/snapshots.json"
    printf '+ wrote targets.json (%d epochs) + snapshots.json\n' "${#SNAPSHOT_SLOTS[@]}"
}

# Step 3: amaru create-snapshots. rc=6 on failure.
# Drives the db-analyser engine against the local chain DB
# (--cardano-node-db, so Mithril is skipped) using the explicit snapshot
# points (--snapshot, so Koios is skipped). Materializes one snapshot dir
# per epoch under snapshots/<net>/<slot>.<hash>/ with packaged bootstrap
# headers, plus epoch metadata under data/<net>/epoch-snapshots/epochs/.
phase_create_snapshots() {
    local snap_root="${UNIQUE_TMP}/snapshots/${NET_LC}"
    local dist_dir="${UNIQUE_TMP}/data/${NET_LC}/epoch-snapshots"
    local first_epoch=$(( SNAPSHOT_SLOTS[0] / EPOCH_LENGTH ))

    # Give db-analyser an isolated cardano-db view: the immutable chunks
    # are symlinked from the live chain DB (read-only), while the ledger
    # snapshots db-analyser materializes land in our own writable dir.
    # This keeps the producer from mutating the operator's chain DB and
    # lets concurrent producers run against the same chain DB safely.
    local cardano_db="${UNIQUE_TMP}/cardano-db"
    mkdir -p "${cardano_db}"
    ln -sfn "${CHAIN_DB}/immutable" "${cardano_db}/immutable"

    local rc=0
    # amaru >= 4de2db13 replaced --targets-file with a repeated
    # --snapshot "<point>::<parent_point>" option (Point = "<slot>.<hash>"); three
    # snapshot points, derived from the targets already computed above.
    local -a snapshot_args=()
    while IFS= read -r _snap; do snapshot_args+=("${_snap}"); done < <(
        jq -r '.[] | "--snapshot", "\(.slot).\(.hash)::\(.parent_point)"' "${UNIQUE_TMP}/targets.json"
    )
    # amaru >= 4de2db13 treats --epoch as the TARGET epoch (Amaru's start point),
    # expanding to the 3 prior snapshots (T-3,T-2,T-1). Our snapshots are the 3
    # latest completed epochs [first_epoch .. first_epoch+2], so target = first_epoch+3.
    local target_epoch=$(( first_epoch + 3 ))
    printf '+ amaru create-snapshots (target epoch %d, snapshots %d..%d)\n' "${target_epoch}" "${first_epoch}" "$(( first_epoch + 2 ))"
    log_phase create-snapshots amaru create-snapshots \
        --network "${NETWORK}" \
        --epoch "${target_epoch}" \
        --cardano-node-config-dir "${CONFIG_DIR}" \
        --cardano-node-db "${cardano_db}" \
        "${snapshot_args[@]}" \
        --snapshot-dir "${snap_root}" \
        --dist-dir "${dist_dir}" \
        || rc=$?
    if (( rc != 0 )); then
        printf 'amaru create-snapshots failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/create-snapshots.stderr" >&2
        tail_phase_log create-snapshots
        exit 6
    fi

    local dir_count
    dir_count=$(find "${snap_root}" -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[0-9]+\.[0-9a-f]+' 2>/dev/null | wc -l)
    if (( dir_count < 3 )); then
        printf 'create-snapshots produced %d snapshot dirs in %s, need at least 3\n' \
               "${dir_count}" "${snap_root}" >&2
        exit 6
    fi
}

# Step 4: era-history sidecars + bundle era-history.json. rc=6 on failure.
# amaru `bootstrap` reads history.<slot>.<hash>.json alongside each
# snapshot dir for custom testnets (make_era_history); `amaru run` later
# reads era-history.json from the bundle root via --era-history-file.
phase_era_sidecars() {
    local snap_root="${UNIQUE_TMP}/snapshots/${NET_LC}"
    local slot hash count=0
    for slot in "${SNAPSHOT_SLOTS[@]}"; do
        hash=$(jq -r --argjson s "${slot}" \
            '.data | map(select(.[0] == $s)) | (.[0][1] // empty)' \
            "${BUNDLE_DIR}/.logs/preflight-blocks.json")
        [[ -n "${hash}" ]] || { printf 'no hash for sidecar slot %s\n' "${slot}" >&2; exit 6; }
        ensure_era_history_input "${snap_root}/history.${slot}.${hash}.json"
        count=$(( count + 1 ))
    done
    if (( count == 0 )); then
        printf 'no era-history sidecars written\n' >&2
        exit 6
    fi
    # Bundle-level copy for `amaru run --era-history-file` at consume time.
    ensure_era_history_input "${UNIQUE_TMP}/era-history.json"
}

# Step 5: amaru bootstrap. rc=9 on failure.
# Runs with CWD = staging so default_snapshots_dir (snapshots/<net>) and
# default_data_dir (data/<net>) resolve to the freshly materialized
# snapshots, and AMARU_BOOTSTRAP_CONFIG_DIR pointing at our local
# snapshots.json. Produces ledger.<net>.db + chain.<net>.db, deriving
# nonces from the latest snapshot and importing the packaged headers.
phase_bootstrap() {
    local first_epoch=$(( SNAPSHOT_SLOTS[0] / EPOCH_LENGTH ))
    local ledger_dir="${UNIQUE_TMP}/ledger.${NET_LC}.db"
    local chain_dir="${UNIQUE_TMP}/chain.${NET_LC}.db"
    local logdir="${BUNDLE_DIR}/.logs"
    mkdir -p "${logdir}"
    local rc=0
    printf '+ amaru bootstrap\n'
    # Run with CWD = staging so amaru resolves snapshots/<net> + data/<net>
    # relative to the freshly materialized snapshots; AMARU_BOOTSTRAP_CONFIG_DIR
    # points at our local snapshots.json.
    (
        cd "${UNIQUE_TMP}" || exit 9
        AMARU_BOOTSTRAP_CONFIG_DIR="${UNIQUE_TMP}/bootstrap-config" \
            amaru bootstrap \
                --network "${NETWORK}" \
                --epoch "$(( first_epoch + 3 ))" \
                --ledger-dir "${ledger_dir}" \
                --chain-dir "${chain_dir}"
    ) 2>"${logdir}/bootstrap.stderr" || rc=$?
    if (( rc != 0 )); then
        printf 'amaru bootstrap failed (rc=%d); see %s\n' \
               "${rc}" "${BUNDLE_DIR}/.logs/bootstrap.stderr" >&2
        tail_phase_log bootstrap
        exit 9
    fi
    if [[ ! -d "${ledger_dir}/live" ]]; then
        printf 'amaru bootstrap did not produce a live ledger view at %s\n' \
               "${ledger_dir}/live" >&2
        tail_phase_log bootstrap
        exit 9
    fi
}

# Step 6: mv -T <unique-tmp> <final>. rc=10 on failure.
# `mv -T` invokes renameat2(NOREPLACE) on Linux and is the atomic
# commit per R-007. On EEXIST another producer won the race; fall back
# to bundle_complete which short-circuits with rc=0 (FR-008). The
# create-snapshots work dirs (data/, bootstrap-config/, targets.json)
# are intermediates and are dropped before the commit; the era-history
# snapshot sidecars stay under snapshots/<net> for re-bootstrap.
phase_commit() {
    local final_bundle="${BUNDLE_DIR}/${NETWORK}"
    rm -rf "${UNIQUE_TMP}/data" \
           "${UNIQUE_TMP}/bootstrap-config" \
           "${UNIQUE_TMP}/cardano-db" \
           "${UNIQUE_TMP}/targets.json"
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

# ─── Main orchestration ───────────────────────────────────────────

main() {
    phase_preflight
    phase_stage_init
    phase_targets
    phase_create_snapshots
    phase_era_sidecars
    phase_bootstrap
    phase_commit
}

main
