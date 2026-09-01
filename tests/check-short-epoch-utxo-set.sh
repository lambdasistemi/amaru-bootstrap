#!/usr/bin/env bash
# After each snapshot import, the persisted UTxO key set must equal
# the definite source map's TxIn set. --drop-last-store-key must fail.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 BUNDLE_DIR" >&2
  exit 2
fi

bundle=$1
era=$bundle/era-history.json
ledger=$bundle/ledger.testnet_42.db
snaps=$bundle/snapshots/testnet_42
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/lib
compare=$lib/compare_tvar_store.py
ldb=${LDB:-ldb}

if [[ ! -f $era || ! -d $ledger || ! -d $snaps ]]; then
  echo "utxo-set: missing era-history, ledger, or snapshots under $bundle" >&2
  exit 1
fi
if [[ ! -f $compare ]]; then
  echo "utxo-set: missing comparator $compare" >&2
  exit 1
fi

epoch_size=$(jq -er '.eras[0].params.epoch_size_slots' "$era")
if ! [[ $epoch_size =~ ^[0-9]+$ ]] || ((epoch_size <= 0)); then
  echo "utxo-set: epoch_size_slots is not a positive integer" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
export PYTHONPATH=$lib

shopt -s nullglob
archives=("$snaps"/*.tar.zst)
shopt -u nullglob
if ((${#archives[@]} < 3)); then
  echo "utxo-set: expected >=3 snapshot archives, found ${#archives[@]}" >&2
  exit 1
fi

compare_store() {
  local label=$1
  local tvar=$2
  local store=$3
  local scan=$workdir/${label}.scan

  if [[ ! -d $store ]]; then
    echo "utxo-set: missing store $store for $label" >&2
    exit 1
  fi
  "$ldb" --db="$store" --hex scan >"$scan" 2>/dev/null

  echo "utxo-set: $label"
  python3 "$compare" "$tvar" "$scan"

  set +e
  python3 "$compare" --drop-last-store-key "$tvar" "$scan" \
    >"$workdir/${label}.drop.log"
  local drop_rc=$?
  set -e
  if [[ $drop_rc -eq 0 ]]; then
    echo "utxo-set: NEGATIVE CONTROL FAILED - drop-last-store-key accepted for $label" >&2
    cat "$workdir/${label}.drop.log" >&2
    exit 1
  fi
  echo "utxo-set: $label drop-last-store-key rejected (rc=$drop_rc)"
}

compared=0
latest_slot=-1
latest_tvar=

for archive in "${archives[@]}"; do
  base=$(basename "$archive" .tar.zst)
  slot=${base%%.*}
  if ! [[ $slot =~ ^[0-9]+$ ]]; then
    echo "utxo-set: cannot parse slot from $base" >&2
    exit 1
  fi
  epoch=$((slot / epoch_size))
  extract=$workdir/extract-$slot
  mkdir -p "$extract"
  zstd -d -c "$archive" | tar -x -C "$extract"
  tvar=$extract/$base/tables/tvar
  if [[ ! -f $tvar ]]; then
    echo "utxo-set: archive $base has no tables/tvar" >&2
    exit 1
  fi
  compare_store "epoch-$epoch-slot-$slot" "$tvar" "$ledger/$epoch"
  compared=$((compared + 1))
  if ((slot > latest_slot)); then
    latest_slot=$slot
    latest_tvar=$tvar
  fi
done

if [[ -z $latest_tvar ]]; then
  echo "utxo-set: no snapshot tvar retained for live comparison" >&2
  exit 1
fi
compare_store "live-slot-$latest_slot" "$latest_tvar" "$ledger/live"

echo "utxo-set: $compared snapshot/store pairs plus live matched; drop-last-store-key rejected each"
