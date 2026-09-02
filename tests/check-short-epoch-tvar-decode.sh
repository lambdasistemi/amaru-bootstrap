#!/usr/bin/env bash
# Truncated definite maps fail as end-of-input; a malformed non-EOF key
# after a non-empty batch keeps its original decode class.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 BUNDLE_DIR" >&2
  exit 2
fi

bundle=$1
snaps=$bundle/snapshots/testnet_42
era=$bundle/era-history.json
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/lib
make_tvar=$lib/make_truncated_tvar.py

if [[ ! -d $snaps || ! -f $era || ! -f $make_tvar ]]; then
  echo "tvar-decode: missing snapshots, era-history, or $make_tvar" >&2
  exit 1
fi
if ! command -v amaru >/dev/null; then
  echo "tvar-decode: amaru not on PATH" >&2
  exit 1
fi

: "${AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM:?}"
: "${AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE:?}"
: "${AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR:?}"
: "${SSL_CERT_FILE:?}"

export PYTHONPATH=$lib
epoch_size=$(jq -er '.eras[0].params.epoch_size_slots' "$era")
if ! [[ $epoch_size =~ ^[0-9]+$ ]] || ((epoch_size <= 0)); then
  echo "tvar-decode: epoch_size_slots is not a positive integer" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

shopt -s nullglob
mapfile -t archives < <(printf '%s\n' "$snaps"/*.tar.zst | sort -n)
shopt -u nullglob
if ((${#archives[@]} < 3)); then
  echo "tvar-decode: expected >=3 snapshot archives" >&2
  exit 1
fi

first=${archives[0]}
point=$(basename "$first" .tar.zst)
slot=${point%%.*}
first_epoch=$((slot / epoch_size))
target_epoch=$((first_epoch + 3))

extract=$workdir/orig
mkdir -p "$extract"
zstd -d -c "$first" | tar -x -C "$extract"
orig_tvar=$extract/$point/tables/tvar
if [[ ! -f $orig_tvar ]]; then
  echo "tvar-decode: $point has no tables/tvar" >&2
  exit 1
fi

python3 "$make_tvar" "$orig_tvar" "$workdir/tvar.truncated" --after 9
python3 "$make_tvar" "$orig_tvar" "$workdir/tvar.malformed" --after 9 --append-hex 00

stage_bundle() {
  local dest=$1
  mkdir -p "$dest/snapshots/testnet_42"
  cp -a "$snaps"/. "$dest/snapshots/testnet_42/"
  cp "$era" "$dest/era-history.json"
  chmod -R u+w "$dest"
}

repack_first() {
  local dest=$1
  local tvar=$2
  local unpack=$dest/unpack
  rm -rf "$unpack"
  mkdir -p "$unpack"
  local archive=$dest/snapshots/testnet_42/${point}.tar.zst
  local list=$dest/members.txt
  zstd -d -c "$archive" | tar -t >"$list"
  zstd -d -c "$archive" | tar -x -C "$unpack"
  cp "$tvar" "$unpack/$point/tables/tvar"
  # Preserve member order: Amaru rejects tables/tvar appearing before state.
  (cd "$unpack" && tar --format=ustar --no-recursion -cf - --files-from="$list") \
    | zstd -c >"$archive.tmp"
  mv "$archive.tmp" "$archive"
}

run_bootstrap() {
  local dest=$1
  local log=$2
  local rc=0
  (
    cd "$dest"
    timeout 60s amaru node bootstrap \
      --network testnet_42 \
      --epoch "$target_epoch" \
      --ledger-dir "$dest/ledger.testnet_42.db" \
      --chain-dir "$dest/chain.testnet_42.db" \
      --era-history "$dest/era-history.json"
  ) >"$log" 2>&1 || rc=$?
  echo "$rc"
}

assert_failed_with() {
  local name=$1
  local log=$2
  local rc=$3
  local needle=$4
  if [[ $rc -eq 0 ]]; then
    echo "tvar-decode: $name bootstrap succeeded; wanted failure" >&2
    cat "$log" >&2
    exit 1
  fi
  if ! grep -F "$needle" "$log" >/dev/null; then
    echo "tvar-decode: $name missing diagnostic '$needle' (rc=$rc)" >&2
    cat "$log" >&2
    exit 1
  fi
}

trunc=$workdir/trunc
stage_bundle "$trunc"
repack_first "$trunc" "$workdir/tvar.truncated"
trunc_log=$workdir/trunc.log
trunc_rc=$(run_bootstrap "$trunc" "$trunc_log")
assert_failed_with truncated "$trunc_log" "$trunc_rc" "end of input"
if grep -F "unexpected type" "$trunc_log" >/dev/null; then
  echo "tvar-decode: truncated map reported a type error; diagnostics are not distinct" >&2
  cat "$trunc_log" >&2
  exit 1
fi
echo "tvar-decode: truncated map failed as end-of-input (rc=$trunc_rc)"

mal=$workdir/malformed
stage_bundle "$mal"
repack_first "$mal" "$workdir/tvar.malformed"
mal_log=$workdir/malformed.log
mal_rc=$(run_bootstrap "$mal" "$mal_log")
assert_failed_with malformed "$mal_log" "$mal_rc" "unexpected type u8"
echo "tvar-decode: malformed key preserved unexpected type u8 (rc=$mal_rc)"
