# Tasks: Daily Validated Amaru Image Handoff

**Input**: Design documents from
`/specs/075-daily-amaru-handoff/`

**Prerequisites**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), [data-model.md](data-model.md), and
[contracts/](contracts/)

**Tests**: TDD and invariant falsification are mandatory. Tests must drive the
same state machine through an injected transport before production workflow
wiring is accepted.

## Phase 1: User Story 1 - Explicit daily outcome (Priority: P1)

**Goal**: Produce one immutable daily `UNCHANGED` or `HANDOFF` result, never
silence or conflicting replacement.

**Independent Test**: Equal real source/pin plus an existing handoff emits
one canonical `UNCHANGED` result with zero pin/image mutation; identical retry
is a no-op and different same-day bytes are rejected.

- [ ] T001 [US1] Write failing unchanged, identical-retry, and conflict tests in `tests/test-daily-amaru-handoff.bats` with deterministic fixtures under `tests/fixtures/daily-amaru-handoff/`
- [ ] T002 [US1] Implement strict daily observation/classification and canonical daily-result validation in `scripts/daily-amaru-handoff.sh`
- [ ] T003 [US1] Implement create-or-compare day-keyed result publication through the injected transport in `scripts/daily-amaru-handoff.sh`

## Phase 2: User Story 2 - Changed source to immutable handoff (Priority: P1)

**Goal**: Bind the exact bare upstream SHA to protected integration, successful
final-main CI, immutable image digest, publication identity, and public
handoff v1.

**Independent Test**: A synthetic changed SHA is the only proposed pin change;
complete injected CI/publication evidence yields one strict handoff, while
restoring the freshly updated real pin yields `UNCHANGED` with no mutation.

- [ ] T004 [US2] Write failing changed-source, exact-pin, non-Amaru-lock-isolation, strict-receipt, and idempotent-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [ ] T005 [US2] Implement fixed-origin resolution, exact Amaru pin update, unrelated-lock rejection, and protected integration transport operations in `scripts/daily-amaru-handoff.sh`
- [ ] T006 [US2] Implement strict image-publication/handoff schema validation, relational identity checks, canonical generation, and tuple-keyed create-or-compare publication in `scripts/daily-amaru-handoff.sh`
- [ ] T007 [US2] Emit exact registry digest and image-publication receipt evidence in `.github/workflows/publish-bootstrap-image.yml`
- [ ] T008 [US2] Register the focused Bats, shellcheck, schema, and workflow-lint path in `nix/checks.nix` and expose its local entry point in `justfile`

## Phase 3: User Story 3 - Fail closed and prove hosted wiring (Priority: P1)

**Goal**: Make every incomplete or drifted boundary red before handoff and
prove the scoped App reaches hosted required CI without weakening rules.

**Independent Test**: Wrong origin/ref, missing CI/publication/digest, receipt
conflict, and temporary CLI drift all fail; the restored fixture path and an
explicit same-repository hosted App event produce verifiable green evidence.

- [ ] T009 [US3] Write failing wrong-origin/ref, missing-CI, missing-publication, missing-digest, unknown-field, and no-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [ ] T010 [US3] Wire schedule, manual, pull-request fixture, and explicit label-gated App probe paths to the one state machine in `.github/workflows/daily-amaru-handoff.yml`
- [ ] T011 [US3] Document the public contracts, immutable keys, operator results, failure states, and manual trigger in `docs/daily-amaru-handoff.md` and add one navigation entry in `mkdocs.yml`
- [ ] T012 [US3] Freshly resolve bare upstream, run the exact updater on `flake.nix` and `flake.lock`, prove every other lock node unchanged, prove CLI-drift RED then byte restoration, pass focused/full gates, obtain navigator RED/GREEN/commit verification, and commit the reviewed slice

## Phase 4: Ticket acceptance and hosted evidence

**Purpose**: Ticket-owner acceptance, PR proof, and ready-for-review handoff.

- [ ] T013 Independently inspect the complete implementation commit, rerun the immutable slice gate and `./gate.sh`, stamp T001-T012 into the accepted local commit, push, and refresh the draft PR
- [ ] T014 Enable the explicit same-repository App probe, verify its disposable event reaches hosted `Build Gate`, verify main rules still require pull requests and `Build Gate`, and prove exact probe PR/branch cleanup
- [ ] T015 Verify current-head hosted fixture workflow, `Build Gate`, `Live Bootstrap Producer`, and PR image-publication receipt/digest evidence, then update reviewer-facing PR evidence
- [ ] T016 Freshly run `just build-gate` and `just ci`, run the finalization audit and metadata/task checks, mark the PR ready, and publish the `handoff-v1` ticket release signal without merging

## Dependencies and Execution Order

- T001-T003 define the no-op/daily-result semantics before changed behavior.
- T004-T006 define the exact pin and strict handoff contract before workflow
  production operations.
- T007-T008 make publication evidence and focused checks reachable.
- T009 proves the failure vocabulary before T010 wires production triggers.
- T011 documents only the accepted contract; T012 is the PAIR synchronization,
  proof, and commit barrier.
- T013 starts only after matching driver `COMMIT` and navigator
  `NAVIGATOR-VERIFIED` events.
- T014 is explicitly enabled only after local acceptance and blocks T015.
- T015 blocks final T016 because current-head hosted evidence must exist before
  readiness is claimed.
- Implementation is one PAIR slice because source, authentication, protected
  integration, publication, and receipt identities are one relational state
  machine; splitting them would permit a non-bisect-safe partial contract.

## Implementation Strategy

1. RED the day-keyed unchanged/idempotence behavior.
2. RED the changed exact-pin and strict handoff behavior.
3. RED every incomplete-evidence and wrong-origin path.
4. Implement the state machine behind an injected transport.
5. Wire image publication evidence, Nix checks, and workflow triggers.
6. Run the updater against the fresh real upstream SHA, restore the real
   unchanged path, and prove the exact Build Gate can fail on CLI drift.
7. Freeze the complete PAIR handoff, pass local/full gates, then obtain hosted
   App/rules/CI/publication evidence before ready-for-review handoff.
