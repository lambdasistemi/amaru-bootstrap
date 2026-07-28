#!/usr/bin/env bats

# Verify the producer uses amaru main's CANONICAL native commands
# (snapshot create, node bootstrap) — not legacy aliases
# (create-snapshots, bootstrap) or dev-CLI subcommands.
# Per lambdasistemi/amaru-bootstrap#48 slice 2.
#
# Issue #52 slice 1: the producer's chain queries are served by a strict
# db-analyser double (tip on stdout, --show-slot-block-no rows on stderr).

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  make_valid_inputs "$TMP_DIR"

  # Override genesis to match the proven smoke-test values:
  # k=20, 1/f=5, epochLength=400 => scale_factor=4
  jq '.epochLength = 400 | .securityParam = 20 | .activeSlotsCoeff = 0.2' \
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

  # Trace spanning epochs 0-4 (epochLength=400, tip 1600 in epoch 4):
  # completed epochs 1/2/3 tail at 795/1195/1595 with parents
  # 790/1190/1590. Verbatim db-analyser --show-slot-block-no shape.
  {
    printf '[0.070592s] Started ShowSlotBlockNo\n'
    printf '[0.070947s] BlockNo 0\tSlotNo 390\t%s\n' "$(hexhash 390)"
    printf '[0.071080s] BlockNo 1\tSlotNo 395\t%s\n' "$(hexhash 395)"
    printf '[0.071200s] BlockNo 2\tSlotNo 790\t%s\n' "$(hexhash 790)"
    printf '[0.071300s] BlockNo 3\tSlotNo 795\t%s\n' "$(hexhash 795)"
    printf '[0.071400s] BlockNo 4\tSlotNo 1190\t%s\n' "$(hexhash 1190)"
    printf '[0.071500s] BlockNo 5\tSlotNo 1195\t%s\n' "$(hexhash 1195)"
    printf '[0.071600s] BlockNo 6\tSlotNo 1590\t%s\n' "$(hexhash 1590)"
    printf '[0.071700s] BlockNo 7\tSlotNo 1595\t%s\n' "$(hexhash 1595)"
    printf '[0.084724s] Done\n'
  } >"$TMP_DIR/trace.stderr"

  export DB_ANALYSER_TIP_STDOUT="ImmutableDB tip: Point (At (Block {blockPointSlot = SlotNo 1600, blockPointHash = $(hexhash 1600)}))"
  export DB_ANALYSER_TRACE_STDERR_FILE="$TMP_DIR/trace.stderr"
  export DB_ANALYSER_CALLS="$TMP_DIR/db-analyser-calls.log"
  : >"$DB_ANALYSER_CALLS"

  install_canonical_mocks

  export PATH="$MOCK_BIN:$PATH"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=2
  export AMARU_WAIT_DEADLINE_SECONDS=2
  export AMARU_POLL_INTERVAL_SECONDS=1
}

teardown() {
  rm -rf "$TMP_DIR"
}

install_canonical_mocks() {
  # Strict db-analyser double reproducing the measured stream split.
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

  # amaru mock: ONLY canonical native commands.
  cat >"$MOCK_BIN/amaru" <<SHIM
#!${BASH_PATH}
set -euo pipefail
source "\$CLI_MOCK_SURFACE_LIB"
cli_mock_guard amaru "\$@"
cmd="\$1"
shift
case "\$cmd" in
  snapshot)
    sub="\$1"; shift
    case "\$sub" in
      create)
        # amaru snapshot create — parse args, create snapshot dirs
        snap_dir="" dist_dir="" network=""
        while [[ \$# -gt 0 ]]; do
          case "\$1" in
            --snapshot-dir) snap_dir="\$2"; shift 2 ;;
            --dist-dir) dist_dir="\$2"; shift 2 ;;
            --network) network="\$2"; shift 2 ;;
            --snapshot) shift 2 ;;
            --epoch) shift 2 ;;
            --cardano-node-config-dir) shift 2 ;;
            --cardano-node-db) shift 2 ;;
            *) shift ;;
          esac
        done
        [[ -n "\$snap_dir" ]] || { printf 'snapshot create: --snapshot-dir required\n' >&2; exit 1; }
        # Create 3 dummy snapshot dirs
        for slot in 8 129 248; do
          hash="\$(printf '%064x' "\$slot")"
          mkdir -p "\$snap_dir/\$slot.\$hash"
          printf '[]' >"\$snap_dir/\$slot.\$hash/bootstrap.headers.json"
          : >"\$snap_dir/\$slot.\$hash/state"
          mkdir -p "\$snap_dir/\$slot.\$hash/tables"
          : >"\$snap_dir/\$slot.\$hash/tables/tvar"
        done
        if [[ -n "\$dist_dir" ]]; then
          mkdir -p "\$dist_dir/epochs"
          for epoch in 0 1 2; do
            printf '{"epoch":%d}\n' "\$epoch" >"\$dist_dir/epochs/\$epoch.json"
          done
        fi
        ;;
      *) printf 'unexpected: snapshot %s\n' "\$sub" >&2; exit 1 ;;
    esac
    ;;
  node)
    sub="\$1"; shift
    case "\$sub" in
      bootstrap)
        # amaru node bootstrap — ASSERT consensus-critical global params are set
        # and the epoch_length identity holds (A-018).
        [[ -n "\${AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM:-}" ]] || { printf 'node bootstrap: AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM not set\n' >&2; exit 1; }
        [[ -n "\${AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE:-}" ]] || { printf 'node bootstrap: AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE not set\n' >&2; exit 1; }
        [[ -n "\${AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR:-}" ]] || { printf 'node bootstrap: AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR not set\n' >&2; exit 1; }
        # Verify epoch_length identity: (1/f) * scale * k == genesis epochLength
        k_val="\$AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM"
        inv_val="\$AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE"
        scale_val="\$AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR"
        computed_epoch_length=\$(( inv_val * scale_val * k_val ))
        # Read genesis epochLength for comparison
        genesis_epoch_length=\$(jq -r '.epochLength' "\${AMARU_BOOTSTRAP_CONFIG_DIR:-.}/../config/shelley-genesis.json" 2>/dev/null || echo 0)
        if [[ "\$genesis_epoch_length" -gt 0 ]] && (( computed_epoch_length != genesis_epoch_length )); then
          printf 'node bootstrap: epoch_length identity failed: (1/f)*scale*k = %s*%s*%s = %s != genesis %s\n' \
            "\$inv_val" "\$scale_val" "\$k_val" "\$computed_epoch_length" "\$genesis_epoch_length" >&2
          exit 1
        fi
        # Parse args, create DB dirs
        ledger="" chain="" network=""
        while [[ \$# -gt 0 ]]; do
          case "\$1" in
            --ledger-dir) ledger="\$2"; shift 2 ;;
            --chain-dir) chain="\$2"; shift 2 ;;
            --network) network="\$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ -n "\$ledger" ]]; then
          mkdir -p "\$ledger/live" "\$ledger/0" "\$ledger/1" "\$ledger/2"
        fi
        if [[ -n "\$chain" ]]; then
          mkdir -p "\$chain"
        fi
        ;;
      *) printf 'unexpected: node %s\n' "\$sub" >&2; exit 1 ;;
    esac
    ;;
  create-snapshots)
    printf 'REJECTED: legacy alias create-snapshots (use: amaru snapshot create)\n' >&2
    exit 1
    ;;
  bootstrap)
    printf 'REJECTED: legacy alias bootstrap (use: amaru node bootstrap)\n' >&2
    exit 1
    ;;
  dev)
    printf 'REJECTED: dev-CLI subcommand (use: amaru snapshot create / amaru node bootstrap)\n' >&2
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

@test "producer uses canonical snapshot create + node bootstrap (not legacy aliases)" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]

  # Bundle must have the canonical layout
  [ -d "$TMP_DIR/bundle/testnet_42/ledger.testnet_42.db" ]
  [ -d "$TMP_DIR/bundle/testnet_42/chain.testnet_42.db" ]

  # P05/P08: the run wrote the compact target records.
  [ -s "$TMP_DIR/bundle/.logs/targets.json" ]
}

@test "readiness argv is exactly the measured no-analysis surface" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  # P01: the readiness invocation carries --db, --config, --in-mem and
  # --db-validation minimum-block-validation, and NO analysis flag.
  readiness="$(grep -v -- '--show-slot-block-no' "$DB_ANALYSER_CALLS" | head -1)"
  [ "$readiness" = "--db $TMP_DIR/chain-db --config $TMP_DIR/config/config.json --in-mem --db-validation minimum-block-validation" ]
  ! grep -qE -- '--analyse-from|--num-blocks-to-process|--count-blocks|--store-ledger' "$DB_ANALYSER_CALLS"
}

@test "exactly one forward trace pass, never invoked by readiness ticks" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  # P03/P18: one --show-slot-block-no pass with the pinned argv.
  trace_count=$(grep -c -- '--show-slot-block-no$' "$DB_ANALYSER_CALLS")
  [ "$trace_count" -eq 1 ]
  trace="$(grep -- '--show-slot-block-no$' "$DB_ANALYSER_CALLS" | head -1)"
  [ "$trace" = "--db $TMP_DIR/chain-db --config $TMP_DIR/config/config.json --in-mem --db-validation minimum-block-validation --show-slot-block-no" ]
}

@test "Point Origin at exit 0 stays not-ready (rc=2)" {
  export DB_ANALYSER_TIP_STDOUT="ImmutableDB tip: Point Origin"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  # P02: Origin yields no slot; the poll loop times out at rc=2.
  [ "$status" -eq 2 ]
  # The db-analyser readiness path was actually exercised.
  [ -s "$DB_ANALYSER_CALLS" ]
  # No trace pass is attempted while the tip is not concrete.
  ! grep -q -- '--show-slot-block-no' "$DB_ANALYSER_CALLS"
}

@test "unparseable successful tip output stays not-ready (rc=2)" {
  export DB_ANALYSER_TIP_STDOUT="ImmutableDB tip: garbage that is not a point"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 2 ]
  [ -s "$DB_ANALYSER_CALLS" ]
  ! grep -q -- '--show-slot-block-no' "$DB_ANALYSER_CALLS"
}

@test "malformed trace rows stay not-ready (rc=2)" {
  {
    printf '[0.070592s] Started ShowSlotBlockNo\n'
    printf 'this row has no tab-delimited BlockNo/SlotNo/hash shape\n'
    printf '[0.084724s] Done\n'
  } >"$TMP_DIR/malformed.stderr"
  export DB_ANALYSER_TRACE_STDERR_FILE="$TMP_DIR/malformed.stderr"
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  # P02/P14: a concrete tip but fewer than three valid trace records is
  # WAIT, never a target record with an empty/zero slot or hash.
  [ "$status" -eq 2 ]
  grep -q -- '--show-slot-block-no' "$DB_ANALYSER_CALLS"

  # P14 second half: the WAIT path must not write any placeholder record.
  # If targets.json exists at all, every record needs a positive numeric
  # slot, a non-empty hash, and a <slot>.<hash> parent_point.
  if [ -s "$TMP_DIR/bundle/.logs/targets.json" ]; then
    bad=$(jq '[ .[] | select(
          ((.slot | type) != "number") or (.slot <= 0)
          or ((.hash | type) != "string") or (.hash == "")
          or ((.parent_point | type) != "string")
          or (.parent_point | test("^[0-9]+\\.[0-9a-f]+$") | not)
        ) ] | length' "$TMP_DIR/bundle/.logs/targets.json")
    [ "$bad" -eq 0 ]
  fi
}

@test "permission-denied readiness exits 7 with the diagnostic" {
  printf 'db-analyser: FsInsufficientPermissions: openFile: permission denied\n' \
    >"$TMP_DIR/perm.stderr"
  export DB_ANALYSER_STDERR_FILE="$TMP_DIR/perm.stderr"
  export DB_ANALYSER_EXIT=1
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  # P02/P17: classified read-only access exits 7.
  [ "$status" -eq 7 ]
  [[ "$output" == *"read-write"* ]]
}
