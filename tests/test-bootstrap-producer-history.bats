#!/usr/bin/env bats

# Regression coverage for custom testnet era-history sidecars.
# `amaru convert-ledger-state` writes the open-ended current era with
# the network default epoch size. The producer knows the node genesis
# epochLength and must correct the sidecar before `import-ledger-state`
# consumes it.

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
    printf '{"slot":249,"era":"Conway"}\n'
    ;;
  list-blocks)
    h8="\$(printf '%064x' 8)"
    h9="\$(printf '%064x' 9)"
    h120="\$(printf '%064x' 120)"
    h129="\$(printf '%064x' 129)"
    h248="\$(printf '%064x' 248)"
    h249="\$(printf '%064x' 249)"
    printf '{"data":[[8,"%s"],[9,"%s"],[120,"%s"],[129,"%s"],[248,"%s"],[249,"%s"]]}\n' \
      "\$h8" "\$h9" "\$h120" "\$h129" "\$h248" "\$h249"
    ;;
  get-header)
    printf 'header'
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

  cat >"$MOCK_BIN/amaru" <<SHIM
#!${BASH_PATH}
set -euo pipefail
cmd="\$1"
shift
case "\$cmd" in
  convert-ledger-state)
    snapshot=""
    target=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --snapshot) snapshot="\$2"; shift 2 ;;
        --target-dir) target="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    slot="\$(basename "\$snapshot" .cbor)"
    hash="\$(printf '%064x' "\$slot")"
    mkdir -p "\$target"
    : >"\$target/\$slot.\$hash.cbor"
    printf '{"tail":"00"}\n' >"\$target/nonces.\$slot.\$hash.json"
    cat >"\$target/history.\$slot.\$hash.json" <<JSON
{"eras":[{"start":{"time":0,"slot":0,"epoch":0},"end":null,"params":{"epoch_size_slots":86400,"slot_length":1000,"era_name":"Conway"}}]}
JSON
    ;;
  import-ledger-state)
    ledger=""
    snapshots=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --ledger-dir) ledger="\$2"; shift 2 ;;
        --snapshot-dir) snapshots="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    for history in "\$snapshots"/history.*.json; do
      jq -e 'all(.eras[] | select(.end == null); .params.epoch_size_slots == 120)' \
        "\$history" >/dev/null
    done
    mkdir -p "\$ledger/live" "\$ledger/0" "\$ledger/1" "\$ledger/2"
    ;;
  import-headers)
    chain=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --chain-dir) chain="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "\$chain"
    ;;
  import-nonces)
    ;;
  *)
    printf 'unexpected amaru command: %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$MOCK_BIN/amaru"
}

@test "converted current-era history uses the genesis epochLength" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]

  for history in "$TMP_DIR"/bundle/testnet_42/snapshots/history.*.json; do
    epoch_size="$(
      jq -r '.eras[] | select(.end == null) | .params.epoch_size_slots' \
        "$history"
    )"
    [ "$epoch_size" -eq 120 ]
  done
}
