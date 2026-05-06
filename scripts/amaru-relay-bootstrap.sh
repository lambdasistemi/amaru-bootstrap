#!/usr/bin/env bash
#
# amaru-relay-bootstrap.sh
#
# Container entrypoint for an Antithesis amaru-relay-N container.
# Replaces the giant inline bash that used to live in
# cardano-node-antithesis testnets/cardano_amaru_epoch3600/
# docker-compose.yaml so observability lives with the image, not the
# compose file.
#
# Behaviour:
#
#   1. Write the Antithesis startup marker (`/startup/$RELAY_NAME.started`)
#      immediately, before any bootstrap work. The sidecar gates the
#      SDK "setup complete" event on this marker — it must land inside
#      Antithesis's ~7-minute setup window. Bootstrap finishes during
#      the test phase per spec 080.
#
#   2. Loop bootstrap-producer until the bundle is complete. Every
#      attempt's stdout+stderr is mirrored to the container's stdout
#      via `tee` rather than redirected to a file (so Antithesis's log
#      indexer sees the producer's progress).
#
#   3. exec amaru run with the produced bundle, peering with the
#      paired cardano-node. AMARU_LOG defaults to `info` so the
#      indexer captures sync events; override via env if you want
#      quieter or louder.
#
# Inputs (environment variables):
#
#   RELAY_NAME                amaru-relay-1 | amaru-relay-2 | ...     (required)
#   AMARU_PEER                upstream cardano-node host:port         (required)
#   AMARU_NETWORK             network name passed to amaru/producer   (default: testnet_42)
#   AMARU_BOOTSTRAP_RETRY_SECONDS   pause between attempts            (default: 20)
#   AMARU_LOG                 amaru tracing EnvFilter                 (default: info)
#   AMARU_RELAY_FINAL_DIR     bundle target dir                       (default: /srv/amaru)
#   AMARU_RELAY_LIVE_DIR      paired cardano-node /live mount         (default: /live)
#   AMARU_RELAY_CONFIG_DIR    paired cardano-node config dir          (default: /cardano/config/configs)
#   AMARU_RELAY_RUNTIME_DIR   amaru-runtime dir (era-history.json,
#                             global-parameters.json)                 (default: /amaru-runtime)
#   AMARU_RELAY_STARTUP_DIR   sidecar startup-marker dir              (default: /startup)
#
# All inputs may also come from the script's first two positional
# args: $1=relay name, $2=peer host:port. Env always wins.
#
# Output:
#
#   - Every line written by this script, by bootstrap-producer, and by
#     amaru itself goes to the container's stdout/stderr unmodified.
#   - Lines from this script are prefixed with `[$RELAY_NAME]` so they
#     are easy to grep for in Antithesis Logs Explorer.

set -euo pipefail

RELAY_NAME="${RELAY_NAME:-${1:-}}"
AMARU_PEER="${AMARU_PEER:-${2:-}}"

if [[ -z "$RELAY_NAME" ]]; then
  printf "amaru-relay-bootstrap: RELAY_NAME is required (env or \$1)\n" >&2
  exit 64
fi
if [[ -z "$AMARU_PEER" ]]; then
  printf "amaru-relay-bootstrap: AMARU_PEER is required (env or \$2)\n" >&2
  exit 64
fi

AMARU_NETWORK="${AMARU_NETWORK:-testnet_42}"
AMARU_BOOTSTRAP_RETRY_SECONDS="${AMARU_BOOTSTRAP_RETRY_SECONDS:-20}"
AMARU_LOG="${AMARU_LOG:-info}"
# bootstrap-producer has its own internal long-poll for chain DB
# readiness; default 90-minute deadlines cause each attempt to sit on
# a frozen scratch instead of yielding back to this loop. Keep both
# tight (30 s) so refresh_snapshot picks up fresher chain state on
# each iteration. The OUTER loop is the right place to wait for the
# chain to mature, not the producer's per-invocation deadline.
export AMARU_WAIT_DEADLINE_SECONDS="${AMARU_WAIT_DEADLINE_SECONDS:-30}"
export AMARU_CLUSTER_READY_DEADLINE_SECONDS="${AMARU_CLUSTER_READY_DEADLINE_SECONDS:-30}"
export AMARU_POLL_INTERVAL_SECONDS="${AMARU_POLL_INTERVAL_SECONDS:-5}"
BOOTSTRAP_PRODUCER_BIN="${BOOTSTRAP_PRODUCER_BIN:-/bin/bootstrap-producer}"
AMARU_BIN="${AMARU_BIN:-/bin/amaru}"
final="${AMARU_RELAY_FINAL_DIR:-/srv/amaru}"
live="${AMARU_RELAY_LIVE_DIR:-/live}"
config="${AMARU_RELAY_CONFIG_DIR:-/cardano/config/configs}"
runtime="${AMARU_RELAY_RUNTIME_DIR:-/amaru-runtime}"
startup="${AMARU_RELAY_STARTUP_DIR:-/startup}"

work="$final/.work"
scratch_state="$work/cardano-state"
scratch_out="$work/out"
marker="$startup/$RELAY_NAME.started"
sentinel="$final/.bootstrap-complete"

log() { printf '[%s] %s\n' "$RELAY_NAME" "$*"; }
err() { printf '[%s] %s\n' "$RELAY_NAME" "$*" >&2; }

# Step 1 — write the startup marker first so the sidecar can emit
# "setup complete" inside Antithesis's setup window. Bootstrap then
# happens during the test phase per spec 080.
mkdir -p "$startup"
printf '%s\n' "${HOSTNAME:-$RELAY_NAME}" >"$marker"
log "startup marker written: $marker"
log "config: network=$AMARU_NETWORK peer=$AMARU_PEER amaru_log=$AMARU_LOG"
log "paths: final=$final live=$live config=$config runtime=$runtime"

bundle_complete() {
  local snapshots=()
  local d base latest

  test -f "$sentinel" || return 1
  test -f "$final/chain.$AMARU_NETWORK.db/CURRENT" || return 1
  test -f "$final/nonces.json" || return 1
  # Amaru opens ledger.<network>.db/live, then loads the two epochs
  # before the most recent historical snapshot. Snapshot directory
  # names are epochs observed by Amaru, not guaranteed to start at 0.
  test -f "$final/ledger.$AMARU_NETWORK.db/live/CURRENT" || return 1
  for d in "$final/ledger.$AMARU_NETWORK.db"/*; do
    test -d "$d" || continue
    base="$(basename "$d")"
    if [[ "$base" =~ ^[0-9]+$ ]] && test -f "$d/CURRENT"; then
      snapshots+=("$base")
    fi
  done
  test "${#snapshots[@]}" -ge 3 || return 1
  mapfile -t snapshots < <(printf '%s\n' "${snapshots[@]}" | sort -n)
  latest="${snapshots[$(( ${#snapshots[@]} - 1 ))]}"
  test "$latest" -ge 2 || return 1
  test -f "$final/ledger.$AMARU_NETWORK.db/$((latest - 2))/CURRENT" || return 1
  test -f "$final/ledger.$AMARU_NETWORK.db/$((latest - 1))/CURRENT" || return 1
  test -f "$final/ledger.$AMARU_NETWORK.db/$latest/CURRENT" || return 1
}

refresh_snapshot() {
  test -d "$live/immutable" || return 1
  test -d "$live/ledger" || return 1
  test -d "$live/volatile" || return 1
  test -f "$live/protocolMagicId" || return 1
  test -e "$live/lock" || return 1

  mkdir -p "$work"
  rm -rf "${scratch_state}.tmp" "$scratch_state"
  mkdir -p "${scratch_state}.tmp"
  if cp -a "$live/immutable" "$live/ledger" "$live/volatile" \
        "$live/protocolMagicId" "$live/lock" \
        "${scratch_state}.tmp/"; then
    mv "${scratch_state}.tmp" "$scratch_state"
    return 0
  fi
  rm -rf "${scratch_state}.tmp"
  return 1
}

promote() {
  local stage="$final/.staged"
  rm -f "$sentinel"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -rL "$scratch_out/$AMARU_NETWORK/." "$stage/" || return 1

  # Sweep stale top-level entries except our scratch + stage.
  find "$final" -mindepth 1 -maxdepth 1 \
      ! -path "$work" \
      ! -path "$stage" \
      -exec rm -rf {} +

  for entry in "$stage"/*; do
    mv "$entry" "$final/"
  done
  rmdir "$stage"
  : >"$sentinel"
  rm -rf "$work"
}

# Step 2 — bootstrap loop. Every attempt's output is teed straight to
# stdout so the Antithesis indexer captures the producer's progress.
attempt=0
while :; do
  if bundle_complete; then
    log "bundle already complete at $final, skipping bootstrap loop"
    break
  fi

  attempt=$((attempt + 1))
  log "bootstrap attempt #$attempt: refreshing snapshot from $live"
  if refresh_snapshot; then
    mkdir -p "$scratch_out"
    log "bootstrap attempt #$attempt: invoking bootstrap-producer"
    rc=0
    "$BOOTSTRAP_PRODUCER_BIN" "$scratch_state" "$config" "$scratch_out" \
        "$AMARU_NETWORK" 2>&1 | sed -u "s/^/[$RELAY_NAME bootstrap-producer] /" \
        || rc=${PIPESTATUS[0]}
    case "$rc" in
      0)
        if promote; then
          log "bootstrap attempt #$attempt: committed bundle to $final"
          continue
        fi
        err "bootstrap attempt #$attempt: promote failed, retrying"
        ;;
      1|2|5|6|7|8)
        # Transient under Antithesis faults or a snapshot copied
        # before enough immutable history was available. Loop.
        err "bootstrap attempt #$attempt: transient rc=$rc, retrying"
        ;;
      *)
        err "bootstrap attempt #$attempt: fatal rc=$rc"
        exit "$rc"
        ;;
    esac
  else
    log "bootstrap attempt #$attempt: cardano-node /live not yet usable"
  fi

  log "sleeping ${AMARU_BOOTSTRAP_RETRY_SECONDS}s before next attempt"
  sleep "$AMARU_BOOTSTRAP_RETRY_SECONDS"
done

# Step 3 — hand off to amaru. Its tracing output goes to the
# container's stdout via the standard tracing-subscriber writer, so
# the indexer sees it directly with no further wrapping.
log "bundle ready at $final, exec'ing amaru run"
export AMARU_LOG
exec "$AMARU_BIN" run \
  --network "$AMARU_NETWORK" \
  --ledger-dir "$final/ledger.$AMARU_NETWORK.db" \
  --chain-dir "$final/chain.$AMARU_NETWORK.db" \
  --era-history-file "$runtime/era-history.json" \
  --global-parameters-file "$runtime/global-parameters.json" \
  --peer-address "$AMARU_PEER"
