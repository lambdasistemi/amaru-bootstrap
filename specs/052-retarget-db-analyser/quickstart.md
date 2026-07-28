# Verification Quickstart: Retarget Producer at db-analyser

Run from the issue worktree.

## 1. Exact six-point check

```bash
nix build .#checks.x86_64-linux.db-analyser-points
```

Expected: exit zero after the production-generated target records match all
three target points and all three parent points from `research.md`. The check's
empty-array negative control must report that the assertion rejected zero
points.

## 2. Focused producer checks

```bash
nix build \
  .#checks.x86_64-linux.shellcheck \
  .#checks.x86_64-linux.cli-mock-honesty \
  .#checks.x86_64-linux.bootstrap-producer-bats \
  .#checks.x86_64-linux.bootstrap-producer-synthesized \
  .#checks.x86_64-linux.amaru-run-bootstrap \
  .#checks.x86_64-linux.antithesis-short-epoch-samples \
  .#checks.x86_64-linux.antithesis-short-epoch-golden
```

Expected: every derivation exits zero. The bats suite includes concrete tip,
origin, sparse-boundary, and malformed point-stream cases.

## 3. Live-surface audit

```bash
rg -n \
  'header-extractor|HeaderExtractor|headerExtractor|preflight-blocks[.]json|list-blocks|get-header' \
  app lib test tests scripts nix flake.nix justfile .github \
  amaru-bootstrap.cabal README.md AGENTS.md skills docs \
  --glob '!docs/history/**'
```

Expected after Slice 3: no output and exit 1. Process records under
`specs/`, historical `docs/history/**`, the constitution, and generated
`site/**` are intentionally outside this live audit.

## 4. Flake and image absence

```bash
nix flake show
image=$(nix build --no-link --print-out-paths \
  .#packages.x86_64-linux.bootstrap-producer-image)
image_tmp=$(mktemp -d /tmp/amaru52-image.XXXXXX)
tar -xf "$image" -C "$image_tmp"
for layer in "$image_tmp"/*/layer.tar; do
  [ -f "$layer" ] || continue
  tar -tf "$layer"
done | rg '(^|/)bin/header-extractor$'
```

Expected: no package, app, check, or image path named `header-extractor`; the
final `rg` exits 1. Remove the validated temporary directory afterward.

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
  diff -u specs/050-remove-dead-emitter/baseline-bundle-files.txt -

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
```

Expected: both diffs are empty, all 31 deterministic hashes pass, and all 49
files belong to either the deterministic set or the 18 explicitly named
RocksDB physical-file exclusions.

## 6. Documentation

```bash
nix develop github:paolino/dev-assets?dir=mkdocs --quiet \
  -c mkdocs build --strict
```

Expected: exit zero. Do not commit or hand-edit generated `site/**`.

## 7. Full local CI mirror

```bash
./gate.sh
```

Expected: `nix flake check` and the Docker live cardano-node verifier both exit
zero.
