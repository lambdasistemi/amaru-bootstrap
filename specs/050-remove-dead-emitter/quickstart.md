# Verification Quickstart: Remove the Dead Ledger-State Emitter

Run from the issue worktree.

## 1. Live-surface audit

```bash
rg -n 'ledger-state-emitter|LedgerStateEmitter' \
  app lib scripts nix tests flake.nix justfile .github \
  amaru-bootstrap.cabal README.md AGENTS.md skills docs \
  --glob '!docs/history/**'
```

Expected after Slice 2: no output and exit 1 (no matches).

## 2. Process/history exception audit

```bash
rg -n 'ledger-state-emitter|LedgerStateEmitter' \
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

## 5. Synthesized bundle byte identity

```bash
check_drv=$(nix eval --raw \
  .#checks.x86_64-linux.bootstrap-producer-synthesized.drvPath)
bundle_drv=$(nix derivation show "$check_drv" |
  jq -r '.[].inputDrvs | keys[]' |
  rg 'bootstrap-producer-synthesized-bundle[.]drv$')
nix-store -r "$bundle_drv"
bundle_out=$(nix-store -q --outputs "$bundle_drv")/testnet_42
nix hash path "$bundle_out"
find "$bundle_out" -type f | wc -l
du -sb "$bundle_out"
```

Expected:

- hash `sha256-hIvI4FyFRdDcd6WJjuhjNjryLGens90TRENhz2eCL90=`;
- 49 regular files;
- 194,485 apparent bytes.
