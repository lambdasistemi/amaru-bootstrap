# Tasks: Daily Validated Amaru Image Handoff

**Input**: design documents in `/specs/075-daily-amaru-handoff/`

**Prerequisites**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), [modules-model.md](modules-model.md),
[data-model.md](data-model.md), [functions-model.md](functions-model.md),
and [contracts/](contracts/)

**Tests**: TDD and invariant falsification are mandatory. Every control must be
shown able to fail on the unmodified base before its production code exists;
a control that merely exists is not accepted.

**Topology**: both slices run `OWNER` — one Grok commit owner per slice and a
fresh Claude auditor per submission, dispatched by the ticket owner. No task
below is performed by the ticket owner.

## Slice 1 — reconcile, validate, publish receipts, wire automation

### Phase 1: User Story 1 - Explicit daily outcome (P1)

**Goal**: one immutable daily `UNCHANGED` or `HANDOFF` result, never silence
and never a conflicting replacement.

**Independent Test**: equal source/pin plus an existing handoff emits one
canonical `UNCHANGED` result with zero pin or image mutation; an identical
retry is a no-op and different same-day bytes are rejected.

- [ ] T001 [US1] Write failing unchanged, identical-retry, and conflict tests in `tests/test-daily-amaru-handoff.bats` with deterministic fixtures under `tests/fixtures/daily-amaru-handoff/`
- [ ] T002 [US1] Implement strict daily observation/classification and canonical daily-result validation in `scripts/daily-amaru-handoff.sh`
- [ ] T003 [US1] Implement create-or-compare day-keyed result publication through the injected transport in `scripts/daily-amaru-handoff.sh`

### Phase 2: User Story 2 - Changed source to immutable handoff (P1)

**Goal**: bind the exact bare upstream SHA to protected integration, successful
final-main CI, immutable image digest, publication identity, and handoff v1.

**Independent Test**: a synthetic changed SHA is the only proposed Amaru pin
change; complete injected CI/publication evidence yields one strict handoff,
while an equal tuple yields `UNCHANGED` with no mutation.

- [ ] T004 [US2] Write failing changed-source, exact-pin, lock-isolation, strict-receipt, and idempotent-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [ ] T005 [US2] Implement fixed-origin resolution, the two-revision `propose_pin` contract, lock-isolation rejection, and protected integration transport operations in `scripts/daily-amaru-handoff.sh`
- [ ] T006 [US2] Implement strict image-publication/handoff schema validation including the additive `peer_snapshots` identity block, relational identity checks, canonical generation, and tuple-keyed create-or-compare publication in `scripts/daily-amaru-handoff.sh`
- [ ] T007 [US2] Emit exact registry digest and image-publication receipt evidence in `.github/workflows/publish-bootstrap-image.yml`
- [ ] T008 [US2] Register the focused Bats/shellcheck/schema/workflow-lint check in `nix/checks.nix`, the `justfile` `build-gate` list, and the `.github/workflows/ci.yml` Build Gate list (FR-025)

### Phase 3: User Story 3 - Fail closed and prove hosted wiring (P1)

**Goal**: make every incomplete or drifted boundary red before handoff, and
prove the scoped App reaches hosted required CI without weakening rules.

**Independent Test**: wrong origin/ref, missing CI/publication/digest, receipt
conflict, blocked peer-snapshot resolution, and temporary CLI drift all fail;
the restored path and one same-repository hosted App event produce verifiable
green evidence.

- [ ] T009 [US3] Write failing wrong-origin/ref, missing-CI, missing-publication, missing-digest, unknown-field, and no-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [ ] T010 [US3] Wire schedule, manual, pull-request fixture, and explicit label-gated App probe paths to the one state machine in `.github/workflows/daily-amaru-handoff.yml`
- [ ] T011 [US3] Document the public contracts, immutable keys, operator results, failure vocabulary, and manual trigger in `docs/daily-amaru-handoff.md` and add one navigation entry in `mkdocs.yml`

### Phase 3b: Peer-snapshot coupling (A-001 option C)

**Goal**: the changed path stays green against the required
`peer-snapshot-anchor` check without ever putting a live query on a build or
verify path.

**Independent Test**: an injected changed observation produces a proposal
carrying both rule-selected revisions and the regenerated record; a failing
resolution or anchor produces `BLOCKED-PEER-SNAPSHOT-RESOLUTION` and no
handoff; no local test performs a live query.

- [ ] T017 [US3] Write failing tests for the two-revision proposal, `del(.nodes.amaru, .nodes."cardano-configurations")` lock isolation, `BLOCKED-PEER-SNAPSHOT-RESOLUTION`, and the assertion that no build/verify path invokes the resolver (FR-021..FR-024)
- [ ] T018 [US3] Implement `resolve_peer_snapshots` and the two-revision `propose_pin` as injected-transport operations delegating to the unmodified `scripts/resolve-peer-snapshots`, in `scripts/daily-amaru-handoff.sh`
- [ ] T019 [US3] Prove the new focused check is reachable and able to fail from the hosted Build Gate path, and that a temporary mock-only CLI command makes the exact Build Gate path red with byte-exact restoration afterwards

**Slice 1 commit**: `feat(ci): publish daily validated amaru handoff`
**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010, T011, T017, T018, T019`

## Slice 2 — real pin mutation through the accepted machinery

**Goal**: execute the real procedure once, produced by the automation path
itself and never by hand-editing (A-001 decision 3).

**Independent Test**: after the slice, `flake.nix`/`flake.lock` name exactly the
observed bare upstream SHA and the rule-selected configurations revision,
`peer-snapshot-anchor` is green offline, and a fresh reconciliation of the real
tuple is `UNCHANGED`.

- [ ] T012 Run the accepted updater against a freshly resolved bare upstream observation and record the observation identity
- [ ] T020 Commit the regenerated `nix/peer-snapshots/resolution.json` and the rule-selected `cardano-configurations` pin, and prove every other lock node is byte-identical
- [ ] T021 Prove `peer-snapshot-anchor` is red before regeneration and green offline after (SC-008), then pass full CI including reachable `cli-mock-honesty` on the new tuple
- [ ] T022 Amend the one `docs/peer-snapshots.md` sentence so it states honestly that the resolver is absent from every build/verify workflow and that automation-PR review is post-hoc audit, not a pre-merge gate

**Slice 2 commit**: `build(ci): bump amaru pin through the daily updater`
**Trailer**: `Tasks: T012, T020, T021, T022`

## Phase 4: Ticket acceptance and hosted evidence

- [ ] T013 Independently inspect each accepted candidate, rerun the immutable slice gate and `./gate.sh`, stamp its tasks into the accepted local commit, push, and refresh the draft PR
- [ ] T014 Enable the explicit same-repository App probe, verify its disposable event reaches hosted `Build Gate`, verify main rules still require pull requests and `Build Gate`, and prove exact probe PR/branch cleanup
- [ ] T015 Verify current-head hosted fixture workflow, `Build Gate`, `Live Bootstrap Producer`, and PR image-publication receipt/digest evidence, then update reviewer-facing PR evidence
- [ ] T016 Freshly run `just build-gate` and `just ci`, run the finalization audit and metadata/task checks, mark the PR ready, and publish the `handoff-v1` ticket release signal naming the additive `peer_snapshots` field, without merging

## Dependencies and Execution Order

- T001-T003 define the no-op and daily-result semantics before changed behavior.
- T004-T006 define the exact pin and strict handoff contract before production
  transport operations.
- T007-T008 make publication evidence and the focused check reachable; T008 is
  a precondition of T019, because a check absent from the hosted list cannot be
  shown able to fail there.
- T009 proves the failure vocabulary before T010 wires production triggers.
- T017-T018 must land before slice 2, because slice 2 executes exactly the path
  they prove.
- T011 documents only accepted behavior.
- Slice 2 starts only after slice 1 is accepted and pushed, so an upstream-caused
  red in T021 cannot cost the ticket its implementation.
- T014 is explicitly enabled only after local acceptance and blocks T015.
- T015 blocks T016 because current-head hosted evidence must exist before
  readiness is claimed.

## Implementation Strategy

1. RED the day-keyed unchanged/idempotence behavior.
2. RED the changed exact-pin and strict handoff behavior.
3. RED every incomplete-evidence, wrong-origin, and blocked-resolution path.
4. Implement the state machine behind an injected transport.
5. Wire image publication evidence, Nix checks, both Build Gate lists, and
   workflow triggers; prove the new check can go red from the hosted path.
6. Accept and push slice 1.
7. Run the accepted updater against the real upstream, prove anchor red-then-green
   and lock isolation, and pass full CI on the new tuple.
8. Obtain hosted App/rules/CI/publication evidence before ready-for-review handoff.
