#!/usr/bin/env bash
# After each snapshot import, the persisted UTxO key set must equal
# the definite source map's TxIn set. Each negative control must fail
# for the comparator's own mismatch verdict, never for a tool error:
# dropping a key must produce contract exit 1 with missing=1 naming the
# deleted key, and injecting a key must produce contract exit 1 with
# extra=1 naming the injected key. A nonzero exit that is not the
# verdict, any stderr output, or a summary that drifts beyond the
# asserted direction is an inconclusive control and fails the check.
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

comparator_field() {
  # First stdout line of the comparator is
  #   declared=N parsed=N stored=N missing=N extra=N empty_values=N
  # Print one field's value; exit 1 if the field is absent.
  awk -v key="$2" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) { print kv[2]; found = 1; exit }
      }
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

field_or_die() {
  local label=$1 mode=$2 out=$3 field=$4
  local value
  value=$(comparator_field "$out" "$field") || {
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - comparator summary for $label ($mode) has no $field field" >&2
    exit 1
  }
  printf '%s' "$value"
}

run_comparator() {
  # Run the comparator in mode $1 ("" = exact baseline), capturing
  # stdout and stderr apart; print the exit status.
  local mode=$1 out=$2 err=$3
  local args=()
  [[ -n $mode ]] && args+=("$mode")
  set +e
  python3 "$compare" ${args[@]+"${args[@]}"} "$tvar" "$scan" >"$out" 2>"$err"
  local rc=$?
  set -e
  echo "$rc"
}

expected_dropped_key() {
  # The comparator deletes the lexically-last persisted key, which is
  # the last utxo-prefixed key of the hex scan (hex order == byte
  # order). ldb emits uppercase hex; the comparator prints lowercase.
  awk 'tolower($1) ~ /^0x7574786f/ { print tolower(substr($1, 3)) }' "$1" | sort | tail -1
}

expect_mismatch_verdict() {
  # $1 label, $2 mode, $3 log, $4 want_missing, $5 want_extra,
  # $6 want_stored, $7 want_declared, $8 want_parsed, $9 want_keys_line.
  # The verdict contract: summary differing from the exact baseline only
  # in the asserted direction, and a keys line naming the mutated key.
  local label=$1 mode=$2 out=$3
  local want_missing=$4 want_extra=$5 want_stored=$6
  local want_declared=$7 want_parsed=$8 want_keys_line=$9
  local declared parsed stored missing extra empty
  declared=$(field_or_die "$label" "$mode" "$out" declared)
  parsed=$(field_or_die "$label" "$mode" "$out" parsed)
  stored=$(field_or_die "$label" "$mode" "$out" stored)
  missing=$(field_or_die "$label" "$mode" "$out" missing)
  extra=$(field_or_die "$label" "$mode" "$out" extra)
  empty=$(field_or_die "$label" "$mode" "$out" empty_values)
  if [[ $missing != "$want_missing" || $extra != "$want_extra" || $empty -ne 0 ]] ||
    [[ $declared != "$want_declared" || $parsed != "$want_parsed" || $stored != "$want_stored" ]]; then
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - $mode summary for $label drifted:" \
      "wanted declared=$want_declared parsed=$want_parsed stored=$want_stored missing=$want_missing extra=$want_extra empty_values=0," \
      "got declared=$declared parsed=$parsed stored=$stored missing=$missing extra=$extra empty_values=$empty" >&2
    cat "$out" >&2
    exit 1
  fi
  if ! grep -Fx "$want_keys_line" "$out" >/dev/null; then
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - $mode did not name the mutated key for $label: wanted [$want_keys_line]" >&2
    cat "$out" >&2
    exit 1
  fi
}

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

  # Positive control: the untouched pair must be exact, so the negative
  # controls below are proven to reject the one thing each changes.
  local base=$workdir/${label}.base.log base_err=$workdir/${label}.base.err base_rc
  base_rc=$(run_comparator "" "$base" "$base_err")
  if [[ $base_rc -ne 0 || -s $base_err ]]; then
    echo "utxo-set: comparator did not report the untouched pair exact for $label (rc=$base_rc)" >&2
    cat "$base_err" "$base" >&2
    exit 1
  fi
  cat "$base"
  local declared parsed stored missing extra empty
  declared=$(field_or_die "$label" base "$base" declared)
  parsed=$(field_or_die "$label" base "$base" parsed)
  stored=$(field_or_die "$label" base "$base" stored)
  missing=$(field_or_die "$label" base "$base" missing)
  extra=$(field_or_die "$label" base "$base" extra)
  empty=$(field_or_die "$label" base "$base" empty_values)
  if [[ $missing -ne 0 || $extra -ne 0 || $empty -ne 0 ]]; then
    echo "utxo-set: exact-set property violated for $label: missing=$missing extra=$extra empty_values=$empty" >&2
    exit 1
  fi

  # Negative control 1: deleting the lexically-last persisted key must
  # yield the missing-key verdict naming exactly that key.
  local dropped
  dropped=$(expected_dropped_key "$scan")
  local drop=$workdir/${label}.drop.log drop_err=$workdir/${label}.drop.err drop_rc
  drop_rc=$(run_comparator --drop-last-store-key "$drop" "$drop_err")
  if [[ $drop_rc -eq 0 ]]; then
    echo "utxo-set: NEGATIVE CONTROL FAILED - drop-last-store-key accepted for $label" >&2
    cat "$drop" >&2
    exit 1
  fi
  if [[ $drop_rc -ne 1 || -s $drop_err ]]; then
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - drop-last-store-key failed as a tool, not as a verdict, for $label (rc=$drop_rc)" >&2
    cat "$drop_err" "$drop" >&2
    exit 1
  fi
  expect_mismatch_verdict "$label" drop "$drop" 1 0 "$((stored - 1))" "$declared" "$parsed" \
    "missing_keys=$dropped"
  echo "utxo-set: $label drop-last-store-key rejected (missing $dropped)"

  # Negative control 2: injecting a foreign, non-empty store key must
  # yield the extra-key verdict naming exactly that key.
  local injected_hex
  injected_hex="7574786f825820$(printf 'f%.0s' {1..64})19ffff"
  if grep -qF "0x$injected_hex " "$scan"; then
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - injected key already present in the scan for $label" >&2
    exit 1
  fi
  local inject=$workdir/${label}.inject.log inject_err=$workdir/${label}.inject.err inject_rc
  inject_rc=$(run_comparator --inject-extra-store-key "$inject" "$inject_err")
  if [[ $inject_rc -eq 0 ]]; then
    echo "utxo-set: NEGATIVE CONTROL FAILED - inject-extra-store-key accepted for $label" >&2
    cat "$inject" >&2
    exit 1
  fi
  if [[ $inject_rc -ne 1 || -s $inject_err ]]; then
    echo "utxo-set: NEGATIVE CONTROL INCONCLUSIVE - inject-extra-store-key failed as a tool, not as a verdict, for $label (rc=$inject_rc)" >&2
    cat "$inject_err" "$inject" >&2
    exit 1
  fi
  expect_mismatch_verdict "$label" inject "$inject" 0 1 "$((stored + 1))" "$declared" "$parsed" \
    "extra_keys=$injected_hex"
  echo "utxo-set: $label inject-extra-store-key rejected (extra $injected_hex)"
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

echo "utxo-set: $compared snapshot/store pairs plus live matched; drop/inject controls rejected each"
