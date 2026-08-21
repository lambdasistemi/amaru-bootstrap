#!/usr/bin/env bats

# Regression coverage for custom testnet era-history sidecars.
# amaru `bootstrap` reads history.<slot>.<hash>.json next to each snapshot
# dir for custom testnets. The producer derives that sidecar from the node
# genesis epochLength, so a short-epoch testnet gets the correct epoch size
# rather than the network default (86400).

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"

  # Antithesis short-epoch params (same set as make_short_epoch_node_inputs).
  # k and activeSlotsCoeff must move with epochLength: the producer now
  # derives amaru's GlobalParameters from genesis and refuses a genesis
  # where epochLength != (1/f) * scale_factor * k. Here 1/f=1, k=8 =>
  # scale_factor = 15.
  jq '.epochLength = 120 | .securityParam = 8 | .activeSlotsCoeff = 1.0' \
    "$TMP_DIR/config/shelley-genesis.json" \
    >"$TMP_DIR/config/shelley-genesis.json.tmp"
  mv "$TMP_DIR/config/shelley-genesis.json.tmp" \
    "$TMP_DIR/config/shelley-genesis.json"

  mkdir -p "$TMP_DIR/chain-db/immutable"
  : >"$TMP_DIR/chain-db/immutable/00000.chunk"

  MOCK_BIN="$TMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  BASH_PATH="$(command -v bash)"
  export CLI_MOCK_SURFACE_LIB="$BATS_TEST_DIRNAME/lib/cli-mock-surface.bash"

  hexhash() { printf '%064x' "$1"; }

  # Short-epoch trace (epochLength 120, tip 370 in epoch 3): completed
  # epochs 0/1/2 tail at 9/129/249 with parents 8/120/248. Verbatim
  # db-analyser --show-slot-block-no shape (bracketed, tab-delimited, stderr).
  {
    printf '[0.070592s] Started ShowSlotBlockNo\n'
    printf '[0.070947s] BlockNo 0\tSlotNo 8\t%s\n' "$(hexhash 8)"
    printf '[0.071080s] BlockNo 1\tSlotNo 9\t%s\n' "$(hexhash 9)"
    printf '[0.071200s] BlockNo 2\tSlotNo 120\t%s\n' "$(hexhash 120)"
    printf '[0.071300s] BlockNo 3\tSlotNo 129\t%s\n' "$(hexhash 129)"
    printf '[0.071400s] BlockNo 4\tSlotNo 248\t%s\n' "$(hexhash 248)"
    printf '[0.071500s] BlockNo 5\tSlotNo 249\t%s\n' "$(hexhash 249)"
    printf '[0.071600s] BlockNo 6\tSlotNo 360\t%s\n' "$(hexhash 360)"
    printf '[0.071700s] BlockNo 7\tSlotNo 370\t%s\n' "$(hexhash 370)"
    printf '[0.084724s] Done\n'
  } >"$TMP_DIR/trace.stderr"

  export DB_ANALYSER_TIP_STDOUT="ImmutableDB tip: Point (At (Block {blockPointSlot = SlotNo 370, blockPointHash = $(hexhash 370)}))"
  export DB_ANALYSER_TRACE_STDERR_FILE="$TMP_DIR/trace.stderr"
  export DB_ANALYSER_CALLS="$TMP_DIR/db-analyser-calls.log"
  : >"$DB_ANALYSER_CALLS"

  install_short_epoch_mocks

  export PATH="$MOCK_BIN:$PATH"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=2
  export AMARU_WAIT_DEADLINE_SECONDS=2
  export AMARU_POLL_INTERVAL_SECONDS=1
}

teardown() {
  rm -rf "$TMP_DIR"
}

install_short_epoch_mocks() {
  printf '#!%s\n' "$BASH_PATH" >"$MOCK_BIN/db-analyser"
  cat >>"$MOCK_BIN/db-analyser" <<'SHIM'
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
  chmod +x "$MOCK_BIN/db-analyser"

  cat >"$MOCK_BIN/amaru" <<SHIM
#!${BASH_PATH}
set -euo pipefail
source "\$CLI_MOCK_SURFACE_LIB"
cli_mock_guard amaru "\$@"
cmd="\$1"
shift
case "\$cmd" in
  snapshot)
    sub="\$1"
    shift
    [[ "\$sub" == create ]] || {
      printf 'unexpected amaru command: snapshot %s\n' "\$sub" >&2
      exit 1
    }
    snapdir=""
    points=()
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --snapshot) points+=("\$2"); shift 2 ;;
        --snapshot-dir) snapdir="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "\$snapdir"
    mode="\${SNAPSHOT_EMIT_MODE:-directories}"
    case "\$mode" in
      malformed)
        : >"\$snapdir/not-a-target.tar.zst"
        : >"\$snapdir/9.NOT-LOWERCASE-HEX.tar.zst"
        ;;
      none) ;;
      *)
        n=0
        for p in "\${points[@]}"; do
          n=\$((n + 1))
          point="\${p%%::*}"
          case "\$mode" in
            directories)
              d="\$snapdir/\$point"
              mkdir -p "\$d/tables"
              : >"\$d/state"
              : >"\$d/tables/tvar"
              printf '[]\n' >"\$d/bootstrap.headers.json"
              ;;
            archives)
              : >"\$snapdir/\$point.tar.zst"
              ;;
            duplicate-two-targets)
              [ "\$n" -le 2 ] || break
              mkdir -p "\$snapdir/\$point"
              : >"\$snapdir/\$point.tar.zst"
              ;;
            mixed-three)
              if [ "\$n" -eq 1 ]; then
                mkdir -p "\$snapdir/\$point"
              else
                : >"\$snapdir/\$point.tar.zst"
              fi
              ;;
            *)
              printf 'unknown SNAPSHOT_EMIT_MODE=%s\n' "\$mode" >&2
              exit 64
              ;;
          esac
        done
        ;;
    esac
    ;;
  node)
    sub="\$1"
    shift
    [[ "\$sub" == bootstrap ]] || {
      printf 'unexpected amaru command: node %s\n' "\$sub" >&2
      exit 1
    }
    ledger=""
    chain=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --ledger-dir) ledger="\$2"; shift 2 ;;
        --chain-dir) chain="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "\$ledger/live" "\$ledger/0" "\$ledger/1" "\$ledger/2" "\$chain"
    ;;
  create-snapshots|bootstrap)
    printf 'legacy alias rejected: amaru %s (use the canonical native CLI)\n' \
           "\$cmd" >&2
    exit 1
    ;;
  *)
    printf 'unexpected amaru command: %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$MOCK_BIN/amaru"
}

@test "era-history sidecars use the genesis epochLength" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]

  shopt -s nullglob
  found=0
  for history in "$TMP_DIR"/bundle/testnet_42/snapshots/testnet_42/history.*.json; do
    found=1
    epoch_size="$(
      jq -r '.eras[] | select(.end == null) | .params.epoch_size_slots' \
        "$history"
    )"
    [ "$epoch_size" -eq 120 ]
  done
  [ "$found" -eq 1 ]
}

@test "short-epoch targets derive from the db-analyser trace, not a second read" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  # P08/P16: the sidecar filenames and .logs/targets.json share the same
  # compact records {epoch,slot,hash,parent_point}.
  slots="$(jq -r '.[].slot' "$TMP_DIR/bundle/.logs/targets.json" | tr '\n' ' ')"
  [ "$slots" = "9 129 249 " ]
  shopt -s nullglob
  sidecars=0
  for history in "$TMP_DIR"/bundle/testnet_42/snapshots/testnet_42/history.*.json; do
    sidecars=$((sidecars + 1))
  done
  [ "$sidecars" -eq 3 ]
}

assert_complete_mock_bundle() {
  local root="$TMP_DIR/bundle/testnet_42"
  [ -d "$root/ledger.testnet_42.db/live" ]
  [ -d "$root/chain.testnet_42.db" ]
  [ -f "$root/era-history.json" ]
  local n=0 d
  for d in "$root/ledger.testnet_42.db"/*; do
    if [ -d "$d" ] && [[ "$(basename "$d")" =~ ^[0-9]+$ ]]; then
      n=$((n + 1))
    fi
  done
  [ "$n" -ge 3 ]
}

@test "archive snapshot artifacts complete the mock bundle" {
  export SNAPSHOT_EMIT_MODE=archives
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  assert_complete_mock_bundle
}

@test "no snapshot artifacts exits 6 with named diagnostic" {
  export SNAPSHOT_EMIT_MODE=none
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 6 ]
  [[ "$output" == *"snapshot artifacts"* ]]
}

@test "malformed snapshot names do not satisfy the minimum" {
  export SNAPSHOT_EMIT_MODE=malformed
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 6 ]
  [[ "$output" == *"snapshot artifacts"* ]]
}

@test "duplicate forms of only two targets do not satisfy the minimum" {
  export SNAPSHOT_EMIT_MODE=duplicate-two-targets
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 6 ]
  [[ "$output" == *"snapshot artifacts"* ]]
}

@test "mixed directory and archive forms count distinct targets" {
  export SNAPSHOT_EMIT_MODE=mixed-three
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  assert_complete_mock_bundle
}
