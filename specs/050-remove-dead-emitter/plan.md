# Implementation Plan: Remove the Dead Ledger-State Emitter

**Branch**: `chore/50-remove-ledger-state-emitter` | **Date**: 2026-07-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Delete the unused Haskell module and executable, remove every live Cabal/Nix/
flake/CI/test/image reference, then align current-facing documentation. The
work lands as two vertical commits: first the executable and live build/test
surfaces, then current documentation. Both commits remain buildable; the first
also proves deterministic equivalence of the synthesized fixture bundle and
that the image no longer contains the binary.

## Technical Context

**Language/Version**: Cabal 3.0 metadata for GHC 9.6; Nix; Bash; Markdown

**Primary Dependencies**: haskell.nix project outputs, Docker tools,
`rg`, `jq`, `tar`, the existing Amaru and IOG tool pins

**Storage**: Generated RocksDB-backed ledger and chain stores in a Nix build
sandbox; no persistent schema change

**Testing**: `nix flake check`, `just build-gate`, focused
`cli-mock-honesty`, live-reference audit, Docker layer inspection, and
path/content-manifest comparison of the synthesized fixture bundle

**Target Platform**: `x86_64-linux`

**Project Type**: Nix-first Haskell/Bash tool and container image

**Performance Goals**: No runtime change; one fewer executable and its closure
in the producer image

**Constraints**: No dependency repins; no `header-extractor` changes; no
historical rewrites; exact surgical edits in `flake.nix` and `nix/checks.nix`;
identical `testnet_42` path inventory and deterministic file subset

**Scale/Scope**: One dead executable, 18 live files at baseline, two reviewed
commits

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | No dependency or upstream source changes |
| II. Stock tools, custom orchestration | PASS | Removes an unused custom tool; supported producer continues using stock Amaru and IOG tools |
| III. Reproducibility by SHA pinning | PASS | `flake.lock` and the Amaru pin remain untouched |
| IV. Nix-first, haskell.nix | PASS | Flake evaluation, checks, apps, package exports, and image contents are the primary proof surfaces |
| V. Smallest provable step | PASS | Two focused commits; the generated bundle inventory, deterministic bytes, and semantic checks gate the removal |

Post-design check: PASS. The design deletes surface without adding an
alternative implementation, dependency, or architectural layer.

## Project Structure

### Documentation for this ticket

```text
specs/050-remove-dead-emitter/
├── baseline-bundle-deterministic.sha256
├── baseline-bundle-files.txt
├── baseline-bundle-rocksdb-exclusions.txt
├── checklists/requirements.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
```

No data model or external interface contract is introduced, so
`data-model.md` and `contracts/` are intentionally omitted.

### Live source and configuration

```text
amaru-bootstrap.cabal
app/ledger-state-emitter/                 # delete
lib/LedgerStateEmitter.hs                 # delete
flake.nix
justfile
.github/workflows/ci.yml
nix/
├── apps.nix
├── bootstrap-producer-image.nix
├── checks.nix
└── header-extractor.nix
scripts/bootstrap-producer.sh             # stale comment only
tests/test-bootstrap-producer-canonical-cli.bats
```

### Current-facing documentation

```text
README.md
AGENTS.md
docs/
├── architecture.md
├── bootstrap-producer.md
└── index.md
skills/amaru-bootstrap-guide/SKILL.md
```

## Slice 1 - Remove the executable and live build/test surfaces

**Risk tier**: specified deletion with high blast radius. Driver effort:
medium. Navigator effort: xhigh.

**Owned files**:

- `amaru-bootstrap.cabal`
- `app/ledger-state-emitter/Main.hs` (delete directory)
- `lib/LedgerStateEmitter.hs` (delete)
- `nix/apps.nix`
- `nix/header-extractor.nix`
- `nix/bootstrap-producer-image.nix`
- only emitter-named lines/comments in `nix/checks.nix`
- only emitter-named lines in `flake.nix`
- only the emitter check list entry in `justfile`
- only the emitter check list entry in `.github/workflows/ci.yml`
- only the obsolete two-line emitter comment in
  `scripts/bootstrap-producer.sh`
- only the emitter mock block in
  `tests/test-bootstrap-producer-canonical-cli.bats`
- `specs/050-remove-dead-emitter/tasks.md` for checkbox stamping by the
  orchestrator after acceptance

**Forbidden scope**: all dependency hashes/pins, `flake.lock`, other
`flake.nix` structure, sibling `header-extractor` source, surrounding
`nix/checks.nix` structure, mock-surface guard logic and arrays, historical
records, current-facing docs (Slice 2), and every other worktree.

**RED**: The live audit reports 45 lines across 18 files; flake evaluation
exposes the package/app/check; Docker layer inspection finds two binary paths.
This deletion task adds no new runtime behavior, so these executable acceptance
commands are the test-first failure.

**GREEN**:

- live audit over Slice 1 source/config/test paths returns zero;
- `nix flake show` exposes no emitter package, app, or check;
- `nix build .#checks.x86_64-linux.cli-mock-honesty` passes;
- the built image has no matching binary path;
- the new synthesized bundle matches the frozen 49-path inventory and all 31
  deterministic-file hashes;
- its only permitted byte differences are the 18 explicitly named RocksDB
  physical files, and the measured size is accounted against the pre-change
  control pair;
- `bootstrap-producer-synthesized`, `amaru-run-bootstrap`,
  `antithesis-short-epoch-samples`, and `antithesis-short-epoch-golden` pass;
- `./gate.sh` passes.

**Commit**: `chore: remove dead ledger-state emitter`

**Trailer**:
`Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009`

## Slice 2 - Align current-facing documentation

**Risk tier**: mechanical documentation alignment. Driver effort: low.
Navigator effort: xhigh.

**Owned files**:

- `README.md`
- `AGENTS.md`
- `docs/index.md`
- `docs/architecture.md`
- `docs/bootstrap-producer.md`
- `skills/amaru-bootstrap-guide/SKILL.md`
- `specs/050-remove-dead-emitter/tasks.md` for checkbox stamping by the
  orchestrator after acceptance

**Forbidden scope**: every source/config/test file from Slice 1; all historical
specifications, `docs/history/`, the constitution, and unrelated documentation.

**RED**: The current-facing docs/guide audit contains emitter references.

**GREEN**: Current-facing references are zero, the full live-surface audit is
zero, expected process/history exceptions are enumerated, and `./gate.sh`
passes.

**Commit**: `docs: retire dead emitter references`

**Trailer**: `Tasks: T010, T011, T012, T013`

## Dependency and Integration Order

1. Slice 1 consumes merged PR #56 and removes executable/build/test surface.
2. The ticket orchestrator independently verifies bundle deterministic
   equivalence, the four semantic bundle checks, image contents, full gate,
   commit shape, and sibling check preservation before pushing.
3. Both worker panes are cleared.
4. Slice 2 aligns current-facing documentation with the now-verified live
   product surface.
5. The ticket orchestrator reruns the two-bucket audit and final gate, refreshes
   the PR body, drops `gate.sh`, and marks the PR ready. It does not merge.

## Complexity Tracking

No constitution violations or justified complexity exceptions.
