# Tasks: Retire Obsolete Phase-0 Smoke

**Input**: Design documents from
`/specs/061-retire-phase0-smoke/`  
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md)

**Tests**: RED-GREEN is mandatory. Because this is a removal-only slice, the
same external structural audit fails before edits and passes after retirement;
no permanent ceremonial absence check is added to the repository.

## Slice 1 - Retire the false signal and preserve its verdict

**Goal**: Remove every executable/test/generated Phase-0 smoke surface while
making the legitimate historical verdict navigable and retaining current
producer coverage.

**Independent Test**: The external retirement audit is RED before edits and
GREEN after them; `cli-mock-honesty`, the documentation build, `nix flake
check`, and the live cardano-node verifier all pass.

- [ ] T001 [US1] Write
  `/tmp/epic-55/amaru-bootstrap-61/retire-phase0-driver/handoffs/retirement-audit.sh`,
  run it before repository edits, and freeze raw output proving RED on the
  active smoke surfaces
- [ ] T002 [US1] Remove the Phase-0 job/check invocation from
  `.github/workflows/ci.yml` and the smoke recipes/stage from `justfile`
- [ ] T003 [US1] Remove the `smoke-test` flake app from `nix/apps.nix` and the
  localized smoke source/tree/check definitions from `nix/checks.nix` while
  preserving the general shellcheck and current producer checks
- [ ] T004 [US1] Delete `scripts/smoke-test.sh`,
  `tests/test-config-error.bats`, `tests/test-smoke-integration.bats`,
  `tests/test-tool-error.bats`, and `tests/lib/fixture-helpers.bash`
- [ ] T005 [US1] Delete every tracked file under `tmp/smoke-out/` and add
  `tmp/` to `.gitignore`
- [ ] T006 [US1] Add the dated verdict and pivot to
  `docs/history/phase-0-snapshot-format.md` and link it from `mkdocs.yml`
- [ ] T007 [US1] Remove only retired-capability claims from `README.md`,
  `docs/bootstrap-producer.md`, `AGENTS.md`,
  `skills/amaru-bootstrap-guide/SKILL.md`, and the Haddock claim in
  `lib/AmaruBootstrap.hs`
- [ ] T008 [US1] Run the identical structural audit GREEN, build
  `cli-mock-honesty`, build the documentation into an external directory, and
  run `./gate.sh`, recording raw evidence under
  `/tmp/epic-55/amaru-bootstrap-61/retire-phase0-driver/handoffs/` with UTC
  timestamps and real exit codes
- [ ] T009 [US1] Freeze sequential RED/GREEN evidence, obtain navigator
  approval through the two
  `/tmp/epic-55/amaru-bootstrap-61/retire-phase0-*/STATUS.md` files, and commit
  with subject
  `fix: retire obsolete Phase-0 smoke signal` and trailer
  `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009`

## Slice 2 - Publish review evidence (orchestrator-owned)

**Goal**: Make the retirement and retained coverage legible to reviewers and
complete ticket-level verification.

- [ ] T010 [US1] Update pull request #62 from
  `/tmp/epic-55/amaru-bootstrap-61/pr-body.md` with the measured conversion
  exit, emitted verdict, successful CI job URL, landed retirement chapter, and
  retained producer coverage
- [ ] T011 [US1] Check the parent inbox, inspect every branch change, rerun the
  full `./gate.sh`, and run the commit/finalization audit against
  `specs/061-retire-phase0-smoke/tasks.md`
- [ ] T012 [US1] Mark the orchestrator-owned evidence slice complete in this
  `specs/061-retire-phase0-smoke/tasks.md` file and commit it with subject
  `docs: finalize Phase-0 retirement evidence`

## Dependencies & Execution Order

- T001 is the observed RED barrier and completes before any repository edit.
- T002-T007 implement one vertical retirement and may not be committed
  separately.
- T008 runs only after the last edit and must use fresh sequential evidence.
- T009 requires literal navigator approval of both RED and GREEN.
- T010-T012 start only after the implementation commit is independently
  reviewed, task-stamped, pushed, and frozen.

## Implementation Strategy

One qwen driver and one Claude navigator execute Slice 1 in the existing ticket
worktree. The driver never pushes; the ticket orchestrator diff-polices every
working period, independently reruns the focused proof and gate, stamps T001-
T009 into the reviewed commit, and pushes. The orchestrator completes Slice 2
without delegating repository behavior changes.
