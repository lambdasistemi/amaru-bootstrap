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

  jq '.epochLength = 120' \
    "$TMP_DIR/config/shelley-genesis.json" \
    >"$TMP_DIR/config/shelley-genesis.json.tmp"
  mv "$TMP_DIR/config/shelley-genesis.json.tmp" \
    "$TMP_DIR/config/shelley-genesis.json"

  mkdir -p "$TMP_DIR/chain-db/immutable"
  : >"$TMP_DIR/chain-db/immutable/00000.chunk"

  MOCK_BIN="$TMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  BASH_PATH="$(command -v bash)"
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
  cat >"$MOCK_BIN/header-extractor" <<SHIM
#!${BASH_PATH}
set -euo pipefail
cmd="\$1"
shift
case "\$cmd" in
  tip-info)
    printf '{"slot":370,"era":"Conway"}\n'
    ;;
  list-blocks)
    h8="\$(printf '%064x' 8)"
    h9="\$(printf '%064x' 9)"
    h120="\$(printf '%064x' 120)"
    h129="\$(printf '%064x' 129)"
    h248="\$(printf '%064x' 248)"
    h249="\$(printf '%064x' 249)"
    h360="\$(printf '%064x' 360)"
    h370="\$(printf '%064x' 370)"
    printf '{"data":[[8,"%s"],[9,"%s"],[120,"%s"],[129,"%s"],[248,"%s"],[249,"%s"],[360,"%s"],[370,"%s"]]}\n' \
      "\$h8" "\$h9" "\$h120" "\$h129" "\$h248" "\$h249" "\$h360" "\$h370"
    ;;
  *)
    printf 'unexpected header-extractor command: %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$MOCK_BIN/header-extractor"

  cat >"$MOCK_BIN/amaru" <<SHIM
#!${BASH_PATH}
set -euo pipefail
cmd="\$1"
shift
case "\$cmd" in
  create-snapshots)
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
    for p in "\${points[@]}"; do
      point="\${p%%::*}"
      d="\$snapdir/\$point"
      mkdir -p "\$d/tables"
      : >"\$d/state"
      : >"\$d/tables/tvar"
      printf '[]\n' >"\$d/bootstrap.headers.json"
    done
    ;;
  bootstrap)
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
