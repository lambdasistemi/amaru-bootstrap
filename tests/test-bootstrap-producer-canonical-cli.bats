#!/usr/bin/env bats

# Verify the producer uses amaru main's CANONICAL native commands
# (snapshot create, node bootstrap) — not legacy aliases
# (create-snapshots, bootstrap) or dev-CLI subcommands.
# Per lambdasistemi/amaru-bootstrap#48 slice 2.

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

# Mock amaru that ONLY accepts canonical native commands:
#   amaru snapshot create ...
#   amaru node bootstrap ...
# Rejects legacy aliases (create-snapshots, bootstrap) and dev-CLI.
install_canonical_mocks() {
  cat >"$MOCK_BIN/header-extractor" <<SHIM
#!${BASH_PATH}
set -euo pipefail
cmd="\$1"
shift
case "\$cmd" in
  tip-info)
    printf '{"slot":1600,"era":"Conway"}\n'
    ;;
  list-blocks)
    # Blocks spanning epochs 0-4 (epochLength=400):
    # epoch 0: slots 0-399, epoch 1: 400-799, epoch 2: 800-1199
    # epoch 3: 1200-1599, epoch 4: 1600+
    h390="\$(printf '%064x' 390)"
    h395="\$(printf '%064x' 395)"
    h790="\$(printf '%064x' 790)"
    h795="\$(printf '%064x' 795)"
    h1190="\$(printf '%064x' 1190)"
    h1195="\$(printf '%064x' 1195)"
    h1590="\$(printf '%064x' 1590)"
    h1595="\$(printf '%064x' 1595)"
    printf '{"data":[[390,"%s"],[395,"%s"],[790,"%s"],[795,"%s"],[1190,"%s"],[1195,"%s"],[1590,"%s"],[1595,"%s"]]}\n' \
      "\$h390" "\$h395" "\$h790" "\$h795" "\$h1190" "\$h1195" "\$h1590" "\$h1595"
    ;;
  get-header)
    printf 'header'
    ;;
  prev-epoch-tail)
    out=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --out) out="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "\$out" ]] || exit 1
    mkdir -p "\$(dirname "\$out")"
    printf 'header' >"\$out"
    h120="\$(printf '%064x' 120)"
    printf '{"slot":120,"hash":"%s","out":"%s"}\n' "\$h120" "\$out"
    ;;
  *)
    printf 'unexpected header-extractor command: %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$MOCK_BIN/header-extractor"

  cat >"$MOCK_BIN/ledger-state-emitter" <<SHIM
#!${BASH_PATH}
set -euo pipefail
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --out) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$out" ]] || exit 1
mkdir -p "\$(dirname "\$out")"
printf 'legacy' >"\$out"
SHIM
  chmod +x "$MOCK_BIN/ledger-state-emitter"

  # amaru mock: ONLY canonical native commands.
  cat >"$MOCK_BIN/amaru" <<SHIM
#!${BASH_PATH}
set -euo pipefail
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
}
