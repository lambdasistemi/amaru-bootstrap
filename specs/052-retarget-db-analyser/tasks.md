# Tasks: Retarget Producer at db-analyser

**Input**: Design documents in `specs/052-retarget-db-analyser/`

**Prerequisites**: [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [plan.md](./plan.md), and
[quickstart.md](./quickstart.md)

**Tests**: RED-GREEN is mandatory. Every driver freezes raw combined output,
UTC timestamps, real exit codes, and sequential post-edit hashes under its
runtime `handoffs/` directory. One reviewed commit lands per slice.

## Slice 1 - Derive and prove targets with db-analyser

**Goal**: Replace the custom readiness/listing calls with the measured upstream
tip and single-pass target extraction while preserving the bundle contract.

**Independent Test**: Origin and malformed traces remain not ready; the real
synthesized-chain check asserts all six exact points and proves its empty-array
negative control; producer semantic checks and the live gate pass.

- [x] T001 [US1] Add failing concrete-tip, `Point Origin`, malformed-trace, exact-argument, and sparse-parent assertions in `tests/test-bootstrap-producer-canonical-cli.bats`, `tests/test-bootstrap-producer-chain.bats`, `tests/test-bootstrap-producer-history.bats`, and `tests/test-bootstrap-producer-sparse-boundaries.bats`, then freeze raw RED output
- [x] T002 [US1] Replace only the three producer-test `header-extractor` doubles with strict tip/trace `db-analyser` doubles in `tests/test-bootstrap-producer-canonical-cli.bats`, `tests/test-bootstrap-producer-history.bats`, and `tests/test-bootstrap-producer-sparse-boundaries.bats`
- [x] T003 [US1] Implement the no-analysis minimum-validation concrete-tip poll, explicit origin handling, single forward trace parser, and configured Conway-slot readiness guard in `scripts/bootstrap-producer.sh`
- [x] T004 [US1] Make `.logs/targets.json`, staging `targets.json`, snapshot arguments, and era-history sidecars share the three compact target records and remove every `preflight-blocks.json` reader from `scripts/bootstrap-producer.sh`
- [x] T005 [US1] Replace the obsolete CLI check with `db-analyser-points` and its empty-array negative control in `nix/checks.nix`, add `db-analyser` to the local producer runtime in `nix/apps.nix`, and update only the matching entries in `justfile` and `.github/workflows/ci.yml`
- [x] T006 [US1] Run the exact-point, shellcheck, producer bats, synthesized producer, Amaru startup, short-epoch, deterministic bundle, and image-build proofs from `specs/052-retarget-db-analyser/quickstart.md`, freezing sequential GREEN evidence
- [x] T007 [US1] Obtain navigator RED/GREEN approval, run `./gate.sh`, and commit Slice 1 as `refactor: derive snapshot targets with db-analyser` with trailer `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Slice 2 - Remove the header-extractor build and image surface

**Goal**: Delete the redundant Haskell executable and every live build, test,
mock, CI, application, and image surface while retaining `NodeConfig`.

**Independent Test**: Exact live build/config/test audit, flake output, and
image layers contain no retired executable; the deterministic and semantic
bundle proofs remain green.

- [x] T008 [US2] Run and freeze failing live build/config/test, flake-output, and image-layer audits from `specs/052-retarget-db-analyser/quickstart.md`
- [x] T009 [US2] Move `NodeConfig` into `lib/AmaruBootstrap.hs`, delete `lib/HeaderExtractor.hs`, `app/header-extractor/Main.hs`, `test/HeaderExtractorSpec.hs`, `test/Spec.hs`, and `tests/test-header-extractor-cli.bats`, and reduce `amaru-bootstrap.cabal` to the retained library surface
- [x] T010 [US2] Delete `nix/header-extractor.nix` and remove only retired package/app/check/runtime/image wiring from `flake.nix`, `nix/apps.nix`, `nix/bootstrap-producer-image.nix`, and `nix/checks.nix`
- [x] T011 [US2] Remove only retired mock declarations and checks from `tests/test-bootstrap-producer-canonical-cli.bats`, `tests/check-cli-mock-honesty.sh`, and `tests/lib/cli-mock-surface.bash`, plus only the retired spec-check entries from `justfile` and `.github/workflows/ci.yml`
- [x] T012 [US2] Run the exact live build/config/test audit, flake absence, CLI mock honesty, image-layer absence, deterministic bundle comparison, and semantic checks from `specs/052-retarget-db-analyser/quickstart.md`, freezing sequential GREEN evidence
- [x] T013 [US2] Obtain navigator RED/GREEN approval, run `./gate.sh`, and commit Slice 2 as `refactor: remove header extractor build surface` with trailer `Tasks: T008, T009, T010, T011, T012, T013`

## Slice 3 - Align current-facing documentation

**Goal**: Describe the stock-tool producer flow everywhere current users and
agents look without rewriting historical evidence or generated output.

**Independent Test**: The current-facing audit has zero stale tool references,
the historical/process bucket remains intact, strict MkDocs build passes, and
the full gate remains green.

- [x] T014 [US2] Run and freeze the failing current-facing reference audit over `README.md`, `AGENTS.md`, `docs/index.md`, `docs/architecture.md`, `docs/bootstrap-producer.md`, and `skills/amaru-bootstrap-guide/SKILL.md`
- [x] T015 [US2] Rewrite only retired-tool claims in `README.md`, `AGENTS.md`, `docs/index.md`, `docs/architecture.md`, `docs/bootstrap-producer.md`, and `skills/amaru-bootstrap-guide/SKILL.md` to describe the measured stock `db-analyser` tip/target flow
- [x] T016 [US2] Run the live/history audits, strict MkDocs build outside `site/**`, and `./gate.sh`; obtain navigator RED/GREEN approval and commit Slice 3 as `docs: describe stock db-analyser producer flow` with trailer `Tasks: T014, T015, T016`

## Slice 4 - Publish review evidence (orchestrator-owned)

**Goal**: Make the delivered behavior, deletion, decisions, and verification
legible to reviewers and complete ticket-level accounting.

- [ ] T017 [US1] Refresh pull request #63 with plain-language landed chapters and a linked technical appendix covering the exact six points, Decision 1, bundle equivalence, image absence, and live boundary evidence
- [ ] T018 [US1] Check `/tmp/epic-55/amaru-bootstrap-52/inbox/`, independently inspect every branch change, rerun `./gate.sh`, and audit every commit/task mapping against `specs/052-retarget-db-analyser/tasks.md`
- [ ] T019 [US1] Mark the orchestrator-owned evidence slice complete in `specs/052-retarget-db-analyser/tasks.md` and commit it as `docs: finalize db-analyser retarget evidence` with trailer `Tasks: T017, T018, T019`

## Dependencies and Execution Order

- Slice 1 starts from merged issues #50 and #51 and must land first because it
  consumes the executable before deletion.
- Slice 2 depends on accepted and pushed Slice 1.
- Slice 3 depends on accepted and pushed Slice 2 so documentation describes
  verified final behavior.
- Slice 4 starts only after all three implementation commits are accepted and
  pushed.
- Driver and navigator panes must both be cleared between Slices 1-3.
- No task is parallelized: the slices share one worktree and each later slice
  depends on the frozen prior commit.

## Implementation Strategy

1. Prove failure states and the six-point assertion before production edits.
2. Land the stock-tool behavior while the old executable remains available.
3. Delete the now-unused Haskell/build/image surface in a separate buildable
   commit.
4. Align current-facing documentation without touching historical or generated
   output.
5. Independently verify each slice, stamp its tasks into that same commit, and
   push only after navigator approval.
6. Publish the final evidence chapter, run the finalization audit, drop
   `gate.sh`, and mark PR #63 ready without merging or closing issue #52.
