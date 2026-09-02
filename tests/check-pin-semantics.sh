#!/usr/bin/env bash
# Custom Testnet has no built-in era history, so --era-history is used.
# applyPatches does not see a semantic change outside every hunk.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 UNPATCHED_SRC PATCHED_SRC CARRIED_PATCH MUTANT_PATCH" >&2
  exit 2
fi

unpatched=$1
patched=$2
carried=$3
mutant=$4

era_history_is_none() {
  awk '
    /pub fn as_era_history/ { in_fn=1 }
    in_fn && /NetworkName::Testnet\(_\) => None,/ { found=1 }
    in_fn && /pub fn as_global_parameters/ { exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

network_unpatched=$unpatched/crates/amaru-kernel/src/cardano/network_name.rs
network_patched=$patched/crates/amaru-kernel/src/cardano/network_name.rs
bootstrap_cli=$patched/crates/amaru/src/bin/amaru/cmd/node/bootstrap.rs

for path in "$network_unpatched" "$network_patched" "$bootstrap_cli" "$carried" "$mutant"; do
  if [[ ! -e $path ]]; then
    echo "pin-semantics: missing $path" >&2
    exit 1
  fi
done

if ! era_history_is_none "$network_unpatched"; then
  echo "pin-semantics: unpatched as_era_history no longer returns None for Testnet" >&2
  exit 1
fi
if ! era_history_is_none "$network_patched"; then
  echo "pin-semantics: patched as_era_history no longer returns None for Testnet" >&2
  exit 1
fi
grep -F 'network.as_era_history()' "$bootstrap_cli" >/dev/null
grep -F 'EraHistory::load(path)' "$bootstrap_cli" >/dev/null
echo "pin-semantics: Testnet has no built-in era history; CLI loads --era-history"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -a "$unpatched"/. "$scratch/"
chmod -R u+w "$scratch"

if era_history_is_none "$scratch/crates/amaru-kernel/src/cardano/network_name.rs"; then
  echo "pin-semantics: scratch copy still has Testnet => None before mutant"
else
  echo "pin-semantics: scratch copy already missing Testnet => None" >&2
  exit 1
fi

patch --silent -d "$scratch" -p1 <"$mutant"
grep -F 'NetworkName::Testnet(_) => Some(&PREPROD_ERA_HISTORY),' \
  "$scratch/crates/amaru-kernel/src/cardano/network_name.rs" >/dev/null

if era_history_is_none "$scratch/crates/amaru-kernel/src/cardano/network_name.rs"; then
  echo "pin-semantics: NEGATIVE CONTROL FAILED - mutant still looks like Testnet => None" >&2
  exit 1
fi
echo "pin-semantics: mutant Testnet => Some(PREPROD) makes the None assertion fail"

patch --silent --dry-run -d "$scratch" -p1 <"$carried"
echo "pin-semantics: carried patch still applies cleanly on the semantic mutant"
echo "pin-semantics: applyPatches does not guard custom-testnet era-history behaviour"
