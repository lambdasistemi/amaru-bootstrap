# Tasks: CLI Mock Honesty

**Input**: Design documents from
`/specs/051-cli-mock-honesty/`  
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md),
[research.md](research.md)

**Tests**: RED-GREEN is mandatory because the ticket removes false-positive
test behavior and adds its recurrence check.

## Slice 1 - Guard and verify mocked CLI surfaces

**Goal**: Every success-capable mocked command path for a flake-built
binary is fail-closed and verified against that real binary.

**Independent Test**: A rejected path added to the shared accepted surface
makes `cli-mock-honesty` fail; all audited real paths and existing bats
suites pass.

- [ ] T001 [US1] Add RED assertions for the invalid
  `header-extractor prev-epoch-tail` response in
  `tests/test-bootstrap-producer-canonical-cli.bats` and the permissive
  default Amaru shim in `tests/test-tool-error.bats`
- [ ] T002 [US1] Define the declared surfaces and fail-closed runtime guard
  in `tests/lib/cli-mock-surface.bash`
- [ ] T003 [US1] Apply the guard to all audited success-capable Amaru and
  header-extractor mocks in the six owned bats files
- [ ] T004 [US1] Add real-binary surface and guard-coverage verification in
  `tests/check-cli-mock-honesty.sh`
- [ ] T005 [US1] Add the localized `cli-mock-honesty` flake check in
  `nix/checks.nix`
- [ ] T006 [US1] Run the focused checks and `./gate.sh`, then commit with
  subject `test: keep mocked CLI surfaces honest` and trailer
  `Tasks: T001, T002, T003, T004, T005, T006`

## Slice 2 - Publish the audit evidence (orchestrator-owned)

**Goal**: Make the audit and proof legible to a reviewer, close task
accounting, and satisfy the final ticket gate.

- [ ] T007 [US1] Update pull request #56 with every test-double audit
  finding, the hidden-command nuance, and the landed behavior by slice
- [ ] T008 [US1] Check the parent inbox, inspect the complete branch diff,
  run `./gate.sh`, and run the finalization audit
- [ ] T009 [US1] Mark this orchestrator-owned slice complete in
  `specs/051-cli-mock-honesty/tasks.md` and commit it with subject
  `docs: finalize CLI mock audit evidence`

## Dependencies & Execution Order

- T001 is RED and must be reviewed before implementation.
- T002 enables T003 and T004.
- T003 and T004 must both complete before T005 can prove the end-to-end
  contract.
- T006 closes the slice only after navigator approval of GREEN.
- T007-T009 are orchestrator-owned and start only after Slice 1 is pushed.

## Implementation Strategy

One driver+navigator pair executes this single test-only vertical slice.
The driver stops after the reviewed commit and never pushes; the ticket
orchestrator independently reviews, gates, stamps the Slice 1 tasks, and
pushes. The orchestrator then completes the PR-evidence slice without
delegating repository behavior changes.
