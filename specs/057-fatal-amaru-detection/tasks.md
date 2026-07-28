# Tasks: Fatal Amaru Detection

**Input**: Design documents from
`/specs/057-fatal-amaru-detection/`  
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md),
[research.md](research.md),
[fatal-log-contract.md](contracts/fatal-log-contract.md)

**Tests**: RED-GREEN and direct fatal/clean evidence are mandatory because the
ticket repairs a test path that was dead on arrival.

## Slice 1 - Freeze and prove fatal-log cleanliness

**Goal**: One shared check fails on all five fatal Amaru signatures and passes
only on readable, clean logs.

**Independent Test**: Invoke the final cleanliness check directly on a seeded
real `Consensus died` log and a clean log; observe nonzero/`consensus` and zero,
respectively.

- [X] T001 [US1] Add RED cases for the future-rollback signature, direct fatal
  cleanliness result, clean result, and missing-log result in
  `tests/test-bootstrap-helpers.bats`
- [X] T002 [US1] Add the `future-rollback` class and caller-facing cleanliness
  contract in `tests/lib/bootstrap-helpers.bash`
- [X] T003 [US1] Cover every existing fatal class and bounded diagnostic shape
  in `tests/test-bootstrap-helpers.bats`
- [X] T004 [US1] Wire `tests/test-bootstrap-helpers.bats` into the existing
  `bootstrap-producer-bats` derivation in `nix/checks.nix`
- [X] T005 [US1] Capture the direct fatal/clean command outputs sequentially,
  run `nix build .#checks.x86_64-linux.bootstrap-producer-bats` and
  `./gate.sh`, then commit as `test: fail on fatal Amaru log events` with
  trailer `Tasks: T001, T002, T003, T004, T005`

## Slice 2 - Build the peered live consume boundary

**Goal**: The Docker live verifier runs pinned Amaru against its live source
node and fails on fatal output or early exit during the hold window.

**Independent Test**: `just live-bootstrap-producer` observes Amaru alive and
fatal-free for the configured hold duration; a seeded fatal seam fails without
requiring container exit.

- [X] T006 [US2] Add RED live-boundary assertions and cleanup expectations in
  `tests/test-bootstrap-producer-live.bats`
- [X] T007 [US2] Adapt the Amaru lifecycle helpers for a consumer container
  sharing the live node network and current `amaru node run` contract in
  `tests/lib/bootstrap-helpers.bash`
- [X] T008 [US2] Add continuous log-cleanliness and container-liveness polling,
  bounded early-exit diagnostics, and teardown cleanup in
  `tests/test-bootstrap-producer-live.bats`
- [X] T009 [US2] Demonstrate the live check path rejects a seeded fatal line
  while the consumer remains alive in `tests/test-bootstrap-producer-live.bats`
- [X] T010 [US2] Run `just live-bootstrap-producer` and `./gate.sh`, preserve
  any real upstream #1095 failure without suppression, then commit as
  `test: restore live Amaru bundle consumption` with trailer
  `Tasks: T006, T007, T008, T009, T010`

## Slice 3 - Extend `cli-mock-honesty` with helper reachability

**Goal**: The existing CI-built `cli-mock-honesty` audit rejects helpers under
`tests/lib/` that have no caller and no explicit exemption.

**Independent Test**: An uncalled fixture fails and names its helper; reachable
and explicitly exempt fixtures plus the repository helper tree pass.

- [X] T011 [US3] Add RED uncalled and GREEN reachable/exempt fixture controls
  to the existing `tests/check-cli-mock-honesty.sh`
- [X] T012 [US3] Implement declaration, call-site, and explicit-exemption
  handling inside `tests/check-cli-mock-honesty.sh`, with reviewable
  exemptions declared in `tests/lib/cli-mock-surface.bash`
- [X] T013 [US3] Audit the real `tests/lib/` helper set through the existing
  `cli-mock-honesty` flake output, adjusting only that check's runtime inputs
  in `nix/checks.nix` if required
- [X] T014 [US3] Run
  `nix build .#checks.x86_64-linux.cli-mock-honesty` and `./gate.sh`, then
  commit as `test: reject unreachable test helpers` with trailer
  `Tasks: T011, T012, T013, T014`

## Slice 4 - Publish evidence (orchestrator-owned)

**Goal**: Make the corrected cause, slice outcomes, direct evidence, and
remaining downstream work clear to a reviewer.

- [ ] T015 [US1] Update pull request #59 after every implementation push with
  a plain-language slice chapter and the direct fatal/clean evidence in the
  technical appendix
- [ ] T016 [US2] Check the parent inbox, inspect the complete owned-file diff,
  run `just ci`, and run the final commit/task audit
- [ ] T017 [US3] Mark the orchestrator-owned tasks complete in
  `specs/057-fatal-amaru-detection/tasks.md`, commit the final evidence update,
  remove `gate.sh`, and mark pull request #59 ready

## Dependencies & Execution Order

- T001 is reviewed RED before T002-T004 begin.
- T002 defines the contract used by T003 and the later live slice.
- T005 closes and freezes Slice 1 before Slice 2 starts.
- T006 is reviewed RED before T007-T009 begin.
- T010 closes and freezes Slice 2 before Slice 3 starts.
- Sibling issue #51 / PR #56 has merged; T011-T014 extend its
  `cli-mock-honesty` mechanism in place, per ruling A-001.
- T011 is reviewed RED before T012-T013 begin.
- T014 closes and freezes Slice 3 before orchestrator-owned finalization.
- T015 is refreshed throughout; T016-T017 run only after all worker slices are
  accepted and pushed.

## Implementation Strategy

One persistent driver/navigator pair executes the three behavior-changing
slices in order, with both panes cleared between slices. Each slice uses
RED/GREEN handoff files, one reviewed commit, no push by workers, and an
independent orchestrator gate before the branch is pushed. The orchestrator
owns only the specifications, task stamping, gate lifecycle, and PR metadata.
