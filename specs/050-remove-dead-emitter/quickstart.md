# Verification Quickstart: Remove the Dead Ledger-State Emitter

Run from the issue worktree.

## 1. Live-surface audit

```bash
rg -n 'ledger-state-emitter|LedgerStateEmitter|ledgerStateEmitter' \
  app lib scripts nix tests flake.nix justfile .github \
  amaru-bootstrap.cabal README.md AGENTS.md skills docs \
  --glob '!docs/history/**'
```

Expected after Slice 2: no output and exit 1 (no matches).

## 2. Process/history exception audit

```bash
rg -n 'ledger-state-emitter|LedgerStateEmitter|ledgerStateEmitter' \
  specs/001-snapshot-format-smoke \
  specs/003-* \
  specs/004-* \
  specs/050-remove-dead-emitter \
  docs/history \
  .specify/memory/constitution.md
```

Expected: matches remain and every path belongs to one of the approved
exception classes.

## 3. Flake and explicit Build Gate

```bash
nix flake check --no-update-lock-file
just build-gate
nix build .#checks.x86_64-linux.cli-mock-honesty
```

Expected: all commands exit 0 and flake output contains no removed executable
package, app, or check.

## 4. Producer image contents

```bash
image=$(nix build --no-link --print-out-paths \
  .#packages.x86_64-linux.bootstrap-producer-image)
image_tmp=$(mktemp -d /tmp/amaru50-image.XXXXXX)
tar -xf "$image" -C "$image_tmp"
for layer in "$image_tmp"/*/layer.tar; do
  [ -f "$layer" ] || continue
  tar -tf "$layer"
done | rg '(^|/)bin/ledger-state-emitter$'
```

Expected: the final `rg` exits 1 with no output. Remove the validated temporary
directory afterward.

## 5. Synthesized bundle deterministic equivalence

```bash
check_drv=$(nix eval --raw \
  .#checks.x86_64-linux.bootstrap-producer-synthesized.drvPath)
bundle_drv=$(nix derivation show "$check_drv" |
  jq -r '.[].inputDrvs | keys[]' |
  rg 'bootstrap-producer-synthesized-bundle[.]drv$')
nix-store -r "$bundle_drv"
bundle_out=$(nix-store -q --outputs "$bundle_drv")/testnet_42
repo_root=$PWD

find "$bundle_out" -type f -printf '%P\n' | sort |
  diff -u \
    specs/050-remove-dead-emitter/baseline-bundle-files.txt -

(
  cd "$bundle_out"
  sha256sum -c \
    "$repo_root/specs/050-remove-dead-emitter/baseline-bundle-deterministic.sha256"
)

cat \
  specs/050-remove-dead-emitter/baseline-bundle-rocksdb-exclusions.txt \
  <(sed -E 's/^[0-9a-f]{64}  //' \
    specs/050-remove-dead-emitter/baseline-bundle-deterministic.sha256) |
  sort |
  diff -u specs/050-remove-dead-emitter/baseline-bundle-files.txt -

nix hash path "$bundle_out"
find "$bundle_out" -type f | wc -l
du -sb "$bundle_out"
```

Expected:

- the path-set diff and exclusion-partition diff are empty;
- all 31 deterministic-file checksums pass;
- 49 regular files;
- the post-change sample recorded for this ticket is 202,240 apparent bytes,
  between two samples from the identical pre-change derivation: 194,485 bytes
  (`sha256-hIvI4FyFRdDcd6WJjuhjNjryLGens90TRENhz2eCL90=`) and 212,933 bytes
  (`sha256-p9zj76WMds5SJiB1sv+yxYs3UZ6M4cHczeNnPYlsE3c=`).

The 18 exact permitted RocksDB physical-file paths are listed in
`baseline-bundle-rocksdb-exclusions.txt`; no unlisted file may differ.

## 6. Semantic bundle checks

```bash
nix build \
  .#checks.x86_64-linux.bootstrap-producer-synthesized \
  .#checks.x86_64-linux.amaru-run-bootstrap \
  .#checks.x86_64-linux.antithesis-short-epoch-samples \
  .#checks.x86_64-linux.antithesis-short-epoch-golden
```

Expected: all four checks exit 0.
