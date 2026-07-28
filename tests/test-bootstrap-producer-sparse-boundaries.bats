#!/usr/bin/env bats

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/bin" "$TMP_DIR/chain-db/immutable" \
           "$TMP_DIR/config" "$TMP_DIR/bundle"
  : >"$TMP_DIR/chain-db/immutable/00000.chunk"

  printf '{"TestConwayHardForkAtEpoch":0}\n' >"$TMP_DIR/config/config.json"
  printf '{"epochLength":100}\n' >"$TMP_DIR/config/shelley-genesis.json"

  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=1
  export AMARU_WAIT_DEADLINE_SECONDS=1
  export AMARU_POLL_INTERVAL_SECONDS=1
  export CLI_MOCK_SURFACE_LIB="$BATS_TEST_DIRNAME/lib/cli-mock-surface.bash"
  BASH_PATH="$(command -v bash)"

  # Sparse chain (epochLength 100, tip in epoch 4): the last block of
  # completed epochs 1/2/3 lands at slots 188/287/397, and each target's
  # immediate predecessor in chain order is 88/188/287 (the first of which
  # lies in the PREVIOUS epoch). Hashes are hex so the producer's
  # <slot>.<hash> snapshot-dir validation accepts them.
  hexhash() { printf '%064x' "$1"; }

  # The db-analyser --show-slot-block-no trace payload, verbatim shape of
  # the real pinned binary: bracketed by `Started ShowSlotBlockNo` / `Done`,
  # tab-delimited data rows `[<elapsed>s] BlockNo N\tSlotNo S\t<hash>` on
  # STDERR. The bracketing lines exercise the production parser's row anchor.
  {
    printf '[0.070592s] Started ShowSlotBlockNo\n'
    printf '[0.070947s] BlockNo 0\tSlotNo 88\t%s\n' "$(hexhash 88)"
    printf '[0.071080s] BlockNo 1\tSlotNo 188\t%s\n' "$(hexhash 188)"
    printf '[0.071200s] BlockNo 2\tSlotNo 287\t%s\n' "$(hexhash 287)"
    printf '[0.071300s] BlockNo 3\tSlotNo 397\t%s\n' "$(hexhash 397)"
    printf '[0.071400s] BlockNo 4\tSlotNo 401\t%s\n' "$(hexhash 401)"
    printf '[0.084724s] Done\n'
  } >"$TMP_DIR/trace.stderr"

  export DB_ANALYSER_TIP_STDOUT="ImmutableDB tip: Point (At (Block {blockPointSlot = SlotNo 405, blockPointHash = $(hexhash 405)}))"
  export DB_ANALYSER_TRACE_STDERR_FILE="$TMP_DIR/trace.stderr"
  export DB_ANALYSER_CALLS="$TMP_DIR/db-analyser-calls.log"
  : >"$DB_ANALYSER_CALLS"

  install_db_analyser_double
  install_amaru_double

  chmod +x "$TMP_DIR/bin/db-analyser" "$TMP_DIR/bin/amaru"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# Strict db-analyser double reproducing the measured stream split: the
# `ImmutableDB tip:` line on STDOUT, the --show-slot-block-no rows on
# STDERR. Rejects any argv outside the measured surface so an inexact
# producer invocation fails the run.
install_db_analyser_double() {
  printf '#!%s\n' "$BASH_PATH" >"$TMP_DIR/bin/db-analyser"
  cat >>"$TMP_DIR/bin/db-analyser" <<'SHIM'
set -euo pipefail
printf '%s\n' "$*" >> "${DB_ANALYSER_CALLS:-/dev/null}"
db="" cfg="" val="" inmem=0 trace=0
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    --db) db="${args[$((i+1))]}"; i=$((i+2)) ;;
    --config) cfg="${args[$((i+1))]}"; i=$((i+2)) ;;
    --db-validation) val="${args[$((i+1))]}"; i=$((i+2)) ;;
    --in-mem) inmem=1; i=$((i+1)) ;;
    --show-slot-block-no) trace=1; i=$((i+1)) ;;
    --analyse-from|--num-blocks-to-process|--count-blocks|--store-ledger|--analyse-only|--analyse-ledger)
      printf 'db-analyser double: forbidden analysis flag %s\n' "$a" >&2
      exit 2 ;;
    *)
      printf 'db-analyser double: unexpected arg %s\n' "$a" >&2
      exit 2 ;;
  esac
done
[ -n "$db" ] || { printf 'db-analyser double: --db required\n' >&2; exit 2; }
[ -n "$cfg" ] || { printf 'db-analyser double: --config required\n' >&2; exit 2; }
[ "$inmem" -eq 1 ] || { printf 'db-analyser double: --in-mem required\n' >&2; exit 2; }
[ "$val" = minimum-block-validation ] \
  || { printf 'db-analyser double: --db-validation must be minimum-block-validation\n' >&2; exit 2; }
if [ -n "${DB_ANALYSER_STDERR_FILE:-}" ]; then
  cat "$DB_ANALYSER_STDERR_FILE" >&2
  exit "${DB_ANALYSER_EXIT:-1}"
fi
printf '%s\n' "${DB_ANALYSER_TIP_STDOUT}"
if [ "$trace" -eq 1 ]; then
  cat "${DB_ANALYSER_TRACE_STDERR_FILE}" >&2
else
  printf '[0.077619s] Started OnlyValidation\n[0.077736s] Done\n' >&2
fi
SHIM
}

# amaru stub, canonical bare-main CLI: `snapshot create` materializes
# one node-snapshot dir per --snapshot point (Koios/Mithril/db-analyser
# all bypassed via the flags); `node bootstrap` produces the ledger +
# chain DBs. The legacy aliases are rejected so this suite keeps
# guarding the native-CLI migration.
install_amaru_double() {
  printf '#!%s\n' "$BASH_PATH" >"$TMP_DIR/bin/amaru"
  cat >>"$TMP_DIR/bin/amaru" <<'SHIM'
set -euo pipefail
source "$CLI_MOCK_SURFACE_LIB"
cli_mock_guard amaru "$@"
cmd="$1"; shift
case "$cmd" in
  snapshot)
    sub="$1"; shift
    [ "$sub" = create ] || {
      printf 'unexpected amaru command: snapshot %s\n' "$sub" >&2
      exit 64
    }
    snapdir=""; points=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --snapshot) points+=("$2"); shift 2 ;;
        --snapshot-dir) snapdir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$snapdir"
    for p in "${points[@]}"; do
      point="${p%%::*}"
      d="$snapdir/$point"
      mkdir -p "$d/tables"
      : >"$d/state"
      : >"$d/tables/tvar"
      printf '[]\n' >"$d/bootstrap.headers.json"
    done
    ;;
  node)
    sub="$1"; shift
    [ "$sub" = bootstrap ] || {
      printf 'unexpected amaru command: node %s\n' "$sub" >&2
      exit 64
    }
    ledger=""; chain=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ledger-dir) ledger="$2"; shift 2 ;;
        --chain-dir) chain="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$ledger/live" "$ledger/1" "$ledger/2" "$ledger/3" "$chain"
    ;;
  create-snapshots|bootstrap)
    printf 'legacy alias rejected: amaru %s (use the canonical native CLI)\n' \
           "$cmd" >&2
    exit 64
    ;;
  *)
    printf 'unexpected amaru command: %s\n' "$cmd" >&2
    exit 64
    ;;
esac
SHIM
}

@test "sparse epoch boundaries select actual blocks from three distinct completed epochs" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  slots="$(
    find "$TMP_DIR/bundle/testnet_42/snapshots/testnet_42" \
      -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | cut -d. -f1 | sort -n | tr '\n' ' '
  )"
  [ "$slots" = "188 287 397 " ]
}

@test "sparse immediate parents are the predecessor blocks in chain order" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  # P04: parents 88/188/287 - the parent of epoch-1 tail 188 is 88, which
  # lies in the PREVIOUS epoch (epoch 0).
  parents="$(
    jq -r '.[].parent_point | split(".")[0]' \
      "$TMP_DIR/bundle/.logs/targets.json" | tr '\n' ' '
  )"
  [ "$parents" = "88 188 287 " ]
}

@test "readiness and trace argv are exactly the measured db-analyser surface" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  # P01/P18: full-argv equality (same form as canonical-cli). The readiness
  # invocation carries no analysis flag; exactly one --show-slot-block-no
  # pass follows it; neither carries a forbidden analysis selector.
  readiness="$(grep -v -- '--show-slot-block-no' "$DB_ANALYSER_CALLS" | head -1)"
  [ "$readiness" = "--db $TMP_DIR/chain-db --config $TMP_DIR/config/config.json --in-mem --db-validation minimum-block-validation" ]
  trace_count=$(grep -c -- '--show-slot-block-no$' "$DB_ANALYSER_CALLS")
  [ "$trace_count" -eq 1 ]
  trace="$(grep -- '--show-slot-block-no$' "$DB_ANALYSER_CALLS" | head -1)"
  [ "$trace" = "--db $TMP_DIR/chain-db --config $TMP_DIR/config/config.json --in-mem --db-validation minimum-block-validation --show-slot-block-no" ]
  ! grep -qE -- '--analyse-from|--num-blocks-to-process|--count-blocks|--store-ledger' "$DB_ANALYSER_CALLS"
}
