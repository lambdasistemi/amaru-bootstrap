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

  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
case "$1" in
  tip-info)
    printf '{"slot":405,"era":"Conway"}\n'
    ;;
  list-blocks)
    printf '{"data":[[88,"h88"],[188,"h188"],[287,"h287"],[397,"h397"],[401,"h401"]]}\n'
    ;;
  get-header)
    printf 'header %s\n' "$2"
    ;;
  *)
    printf 'unexpected header-extractor command: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF
  } >"$TMP_DIR/bin/header-extractor"

  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
slot=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-slot) slot="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$slot" >>"$TMP_DIR/emitted-slots"
printf 'legacy snapshot %s\n' "$slot" >"$out"
EOF
  } >"$TMP_DIR/bin/ledger-state-emitter"

  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
cmd="$1"
shift
case "$cmd" in
  convert-ledger-state)
    snapshot=""
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --snapshot) snapshot="$2"; shift 2 ;;
        --target-dir) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    slot="$(basename "$snapshot" .cbor)"
    mkdir -p "$target"
    printf 'snapshot %s\n' "$slot" >"$target/$slot.hash$slot.cbor"
    printf '{"eras":[{"end":null,"params":{"epoch_size_slots":999}}]}\n' \
      >"$target/history.$slot.hash$slot.json"
    printf '{"tail":""}\n' >"$target/nonces.$slot.hash$slot.json"
    ;;
  import-ledger-state)
    ledger=""
    snapshots=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ledger-dir) ledger="$2"; shift 2 ;;
        --snapshot-dir) snapshots="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$ledger/live"
    : >"$ledger/live/CURRENT"
    for cbor in "$snapshots"/*.cbor; do
      slot="$(basename "$cbor" | cut -d. -f1)"
      epoch=$((slot / 100))
      mkdir -p "$ledger/$epoch"
      : >"$ledger/$epoch/CURRENT"
    done
    ;;
  import-headers)
    chain=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --chain-dir) chain="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$chain"
    : >"$chain/CURRENT"
    ;;
  import-nonces)
    ;;
  *)
    printf 'unexpected amaru command: %s\n' "$cmd" >&2
    exit 64
    ;;
esac
EOF
  } >"$TMP_DIR/bin/amaru"

  chmod +x "$TMP_DIR/bin/header-extractor" \
           "$TMP_DIR/bin/ledger-state-emitter" \
           "$TMP_DIR/bin/amaru"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "sparse epoch boundaries emit actual blocks from three distinct completed epochs" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_DIR/emitted-slots")" = $'188\n287\n397' ]
}
