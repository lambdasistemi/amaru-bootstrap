# Tasks: Remove the Dead Ledger-State Emitter

**Input**: Design documents in `specs/050-remove-dead-emitter/`

**Organization**: Two ordered, bisect-safe slices implement the single P1
maintainer story. One reviewed commit lands per slice.

## Slice 1 - Remove the executable and live build/test surfaces

**Goal**: Remove the dead component from source, build outputs, checks, runtime
paths, image contents, and the canonical CLI fixture without changing producer
bundle semantics or deterministic bytes.

**Independent Test**: Flake/app/check absence, mock honesty, Docker layer
inspection, deterministic-equivalent synthesized bundle, the four semantic
bundle checks, and the full gate all pass.

- [X] T001 [US1] Record the failing live-surface, flake-output, and image-layer acceptance audits from `specs/050-remove-dead-emitter/quickstart.md`
- [X] T002 [US1] Delete `app/ledger-state-emitter/Main.hs` and `lib/LedgerStateEmitter.hs`
- [X] T003 [US1] Remove the module and executable declarations from `amaru-bootstrap.cabal`
- [X] T004 [US1] Remove only emitter attributes/runtime inputs/comments from `nix/apps.nix`, `nix/header-extractor.nix`, `nix/bootstrap-producer-image.nix`, and `nix/checks.nix`
- [X] T005 [US1] Remove only emitter package/image arguments from `flake.nix` and explicit check entries from `justfile` and `.github/workflows/ci.yml`
- [X] T006 [US1] Remove only the stale emitter comment from `scripts/bootstrap-producer.sh`
- [X] T007 [US1] Remove only the emitter mock block from `tests/test-bootstrap-producer-canonical-cli.bats` and verify `tests/lib/cli-mock-surface.bash` has no emitter declaration
- [X] T008 [US1] Prove mock honesty, flake absence, image absence, and deterministic equivalence of the synthesized bundle using `specs/050-remove-dead-emitter/quickstart.md`
- [X] T009 [US1] Run `./gate.sh` and commit Slice 1 as `chore: remove dead ledger-state emitter`

## Slice 2 - Align current-facing documentation

**Goal**: Stop current maintainer/operator material from advertising a removed
tool while leaving historical records unchanged.

**Independent Test**: The live-surface bucket has zero matches; every remaining
match belongs to an enumerated process/history exception; the full gate passes.

- [ ] T010 [US1] Record the failing current-facing reference audit in `README.md`, `AGENTS.md`, `docs/index.md`, `docs/architecture.md`, `docs/bootstrap-producer.md`, and `skills/amaru-bootstrap-guide/SKILL.md`
- [ ] T011 [US1] Remove or rewrite only stale emitter references in `README.md`, `AGENTS.md`, `docs/index.md`, `docs/architecture.md`, `docs/bootstrap-producer.md`, and `skills/amaru-bootstrap-guide/SKILL.md`
- [ ] T012 [US1] Run both grep buckets from `specs/050-remove-dead-emitter/quickstart.md` and confirm zero live matches with only approved exceptions remaining
- [ ] T013 [US1] Run `./gate.sh` and commit Slice 2 as `docs: retire dead emitter references`

## Dependencies and Execution Order

- Slice 1 is based on merged PR #56 and preserves its `cli-mock-honesty` check.
- Slice 2 depends on accepted and pushed Slice 1.
- Driver and navigator panes must both be cleared between slices.
- No task is parallelized because both slices use a single shared worktree and
  Slice 2 documents the verified result of Slice 1.

## Implementation Strategy

1. Establish RED with executable absence audits rather than adding a new
   behavior test for a deletion.
2. Remove the live executable and wiring in one buildable commit.
3. Independently verify the bundle path inventory, deterministic bytes,
   observed size variance, semantic checks, and image contents before push.
4. Align current-facing documentation in a second buildable commit.
5. Independently run the final two-bucket audit and gate before finalization.
