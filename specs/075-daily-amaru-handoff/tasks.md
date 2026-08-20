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

- [x] T001 [US1] Write failing unchanged, identical-retry, and conflict tests in `tests/test-daily-amaru-handoff.bats` with deterministic fixtures under `tests/fixtures/daily-amaru-handoff/`
- [x] T002 [US1] Implement strict daily observation/classification and canonical daily-result validation in `scripts/daily-amaru-handoff.sh`
- [x] T003 [US1] Implement create-or-compare day-keyed result publication through the injected transport in `scripts/daily-amaru-handoff.sh`

### Phase 2: User Story 2 - Changed source to immutable handoff (P1)

**Goal**: bind the exact bare upstream SHA to protected integration, successful
final-main CI, immutable image digest, publication identity, and handoff v1.

**Independent Test**: a synthetic changed SHA is the only proposed Amaru pin
change; complete injected CI/publication evidence yields one strict handoff,
while an equal tuple yields `UNCHANGED` with no mutation.

- [x] T004 [US2] Write failing changed-source, exact-pin, lock-isolation, strict-receipt, and idempotent-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [x] T005 [US2] Implement fixed-origin resolution, the two-revision `propose_pin` contract, lock-isolation rejection, and protected integration transport operations in `scripts/daily-amaru-handoff.sh`
- [x] T006 [US2] Implement strict image-publication/handoff schema validation including the additive `peer_snapshots` identity block, relational identity checks, canonical generation, and tuple-keyed create-or-compare publication in `scripts/daily-amaru-handoff.sh`
- [x] T007 [US2] Emit exact registry digest and image-publication receipt evidence in `.github/workflows/publish-bootstrap-image.yml`
- [x] T008 [US2] Register the focused Bats/shellcheck/schema/workflow-lint check in `nix/checks.nix`, the `justfile` `build-gate` list, and the `.github/workflows/ci.yml` Build Gate list (FR-025)

### Phase 3: User Story 3 - Fail closed and prove hosted wiring (P1)

**Goal**: make every incomplete or drifted boundary red before handoff, and
prove the scoped App reaches hosted required CI without weakening rules.

**Independent Test**: wrong origin/ref, missing CI/publication/digest, receipt
conflict, blocked peer-snapshot resolution, and temporary CLI drift all fail;
the restored path and one same-repository hosted App event produce verifiable
green evidence.

- [x] T009 [US3] Write failing wrong-origin/ref, missing-CI, missing-publication, missing-digest, unknown-field, and no-handoff tests in `tests/test-daily-amaru-handoff.bats`
- [x] T010 [US3] Wire schedule, manual, pull-request fixture, and explicit label-gated App probe paths to the one state machine in `.github/workflows/daily-amaru-handoff.yml`
- [x] T011 [US3] Document the public contracts, immutable keys, operator results, failure vocabulary, and manual trigger in `docs/daily-amaru-handoff.md` and add one navigation entry in `mkdocs.yml`

### Phase 3b: Peer-snapshot coupling (A-001 option C)

**Goal**: the changed path stays green against the required
`peer-snapshot-anchor` check without ever putting a live query on a build or
verify path.

**Independent Test**: an injected changed observation produces a proposal
carrying both rule-selected revisions and the regenerated record; a failing
resolution or anchor produces `BLOCKED-PEER-SNAPSHOT-RESOLUTION` and no
handoff; no local test performs a live query.

- [x] T017 [US3] Write failing tests for the two-revision proposal, `del(.nodes.amaru, .nodes."cardano-configurations")` lock isolation, `BLOCKED-PEER-SNAPSHOT-RESOLUTION`, and the assertion that no build/verify path invokes the resolver (FR-021..FR-024)
- [x] T018 [US3] Implement `resolve_peer_snapshots` and the two-revision `propose_pin` as injected-transport operations delegating to the unmodified `scripts/resolve-peer-snapshots`, in `scripts/daily-amaru-handoff.sh`
- [x] T019 [US3] Prove the focused check derivation is able to fail from the exact `just build-gate` path, and that a temporary mock-only CLI command makes that path red with byte-exact restoration afterwards

**Slice 1 commit**: `feat(ci): publish daily validated amaru handoff`
**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010, T011, T017, T018, T019`

## Slice 2 — real pin mutation through the accepted machinery (re-cut as #79)

Re-cut of #75's second slice with a fresh mandate, campaign ledger, and evidence
budget after #75 exhausted its contracted two-raise ceiling. Same branch, same
PR #76, one bisect-safe history. Integration boundary and residual per A-004
option B; see [plan.md](plan.md).

**Goal**: execute the real procedure once, produced by the automation path
itself and never by hand-editing (A-001 decision 3).

**Independent Test**: after the slice, `flake.nix`/`flake.lock` name exactly the
observed bare upstream SHA and the rule-selected configurations revision,
`peer-snapshot-anchor` is green offline, and a fresh reconciliation of the real
tuple is `UNCHANGED`.

- [ ] T012 Run the accepted updater against a freshly resolved bare upstream observation and record the observation identity
- [ ] T020 Commit the regenerated `nix/peer-snapshots/resolution.json` and the rule-selected `cardano-configurations` pin, and prove every other lock node is byte-identical
- [ ] T021 Prove `peer-snapshot-anchor` is red before regeneration and green offline after (SC-008), then pass full CI including reachable `cli-mock-honesty` on the new tuple
- [ ] T023 Let the automation open its real PR against `main` through the scoped App token, let required checks run, freeze PR number, head SHA, check conclusions and close timestamp, then close it unlanded and delete its branch, stating plainly that it is a proof run closed by design
- [ ] T024 After the bump, run a fresh real reconciliation and show it emits `UNCHANGED` with no pin or image mutation
- [ ] T022 Amend the one `docs/peer-snapshots.md` sentence so it states honestly that the resolver is absent from every build/verify workflow and that automation-PR review is post-hoc audit, not a pre-merge gate

**Slice 2 commit**: `build(ci): bump amaru pin through the daily updater`
**Trailer**: `Tasks: T012, T020, T021, T022`

## Phase 4: Ticket acceptance and hosted evidence

- [ ] T013 Independently inspect each accepted candidate, rerun the immutable slice gate and `./gate.sh`, stamp its tasks into the accepted local commit, push, and refresh the draft PR
- [ ] T014 Enable the explicit same-repository App probe, verify its disposable event reaches hosted `Build Gate`, verify main rules still require pull requests and `Build Gate`, and prove exact probe PR/branch cleanup
- [ ] T015 Verify current-head hosted fixture workflow, `Build Gate`, `Live Bootstrap Producer`, and PR image-publication receipt/digest evidence, then update reviewer-facing PR evidence. Includes the hosted half of check reachability: that the hosted `Build Gate` job actually invokes the focused check, which a local `just build-gate` mirror cannot establish
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

## Forward follow-ups (not in this ticket)

Raised by audit, no blocking finding, carried forward rather than re-cutting a
passing ticket. Each is named and owned; none is silence.

- **auditor-s1-R-1** — `INV-75-SINGLE-MACHINE` residual (ADVISORY). Nothing
  asserts the pull-request job keeps invoking the focused check. Honest limit:
  the green establishes all three trigger paths reach `reconcile` today as read
  from YAML, not that later workflow edits preserve it.
- **CAND-75-CHECK-MEMBERSHIP** — proposed BLOCKING, *not ratified into this
  ticket*. List **parity** now ships (bats 25), but **membership** does not:
  dropping a check from *both* Build Gate lists leaves the suite green, and
  bats 25 lives inside the very check it would need to protect, so its guard is
  unreachable in exactly that case. Today the assertion exists only in the
  ticket owner's untracked `slice-01-v6.sh`, which retires with the ticket. Not
  ratified here because closing it needs a shipped property and this ticket has
  spent both audited submissions; ratifying it now would force a re-cut of a
  passing candidate. It is a pre-existing repo-wide gap, demonstrated on
  `cli-mock-honesty` which predates this ticket.
- **CAND-75-TESTTREE-COMPLETE** — proposed BLOCKING, *not ratified into this
  ticket*. The `dailyHandoffTestTree` linkFarm still enumerates workflows
  explicitly, so a fifth workflow invoking the live resolver would be caught by
  a local `bats` run and invisible to the check CI builds. The list is complete
  today, so the invariant holds over the real set; a directory-level entry
  closes it.
- **auditor-s2-D-1** — repo-wide check reachability: the membership gap applies
  to all sixteen entries of the two Build Gate lists; demonstrated for two.
- **auditor-s1-D-1** — the dev shell lacks `check-jsonschema`, so
  `nix develop -c bats tests/test-daily-amaru-handoff.bats` fails 12/23 on a
  green candidate. Environment gap in `flake.nix`, outside this slice's fence.
- **auditor-s1-D-2** — `find_daily_result` is implemented in both transports
  and satisfies the operation-set check, but has no call site.

## Residual carried to epic altitude

- **CNA205-AB79-INTEGRATION-CALL-FIXTURE-ONLY** — the final integration call in
  `production_integrated_sha` never executes against a real PR in this campaign.
  It stays proven by injected-transport controls plus the T014 probe. Owner:
  epic owner `e-auto`, with a watch duty on the first real production
  changed-day after activation, whose same-day verification must confirm the
  integration step and not only the launch. Honest limit: everything up to and
  including required checks on a real scoped-App PR is proven live; the act of
  landing it is not.
- **Landing PR #76** activates the `17 4 * * *` schedule and therefore
  unattended main-integrating automation. Owner: epic owner, precondition: an
  explicit desk ruling. No seat in this lane lands it.

## Slice 3 — `propose` entrypoint (campaign 2 inside #79)

Ruled by A-006 option B after desk ruling A-EPIC-001 required the hosted probe
to execute the same entrypoint as the daily bump path. Slice 1's audit closed at
set-point **before** that requirement existed, so this is a new requirement, not
a finding slice 1 missed.

The straight-line coupling makes the requirement unsatisfiable today:
`reconcile`'s changed path runs `open_pull_request` and then `integrated_sha` —
the landing step — back to back, so any probe sharing that entrypoint would land
on `main`, which A-004 forbids.

**Independent Test**: the probe job invokes `scripts/daily-amaru-handoff.sh`,
its PR carries the real bump commit rather than an empty one, and no path from
`propose` reaches the landing step.

- [ ] T025 Write failing tests for a `propose` entrypoint that runs resolve → propose_pin → open_pull_request and halts, and for the absence of any landing call on that path
- [ ] T026 Implement `propose` and recompose `reconcile`'s changed path as `propose` plus the landing step
- [ ] T027 Prove the recomposed `reconcile` is behaviourally identical to the previous straight-line version on the same inputs, through the injected transport
- [ ] T028 Rewrite the App-event probe to call `propose`, carrying A-004's cleanup contract verbatim: receipts frozen before deletion, PR closed unlanded, close-by-design wording
- [ ] T029 Ship the observation property the shipped probe lacked — an observation step must give the observed system a chance to report and must distinguish *not-yet-reported* from *absent* — with a negative control exercising the not-yet-reported case

**Why T029 exists**: the shipped probe fired accidentally on 2026-08-19 and
concluded `failure` because it polled for checks ~4 s after creating the PR and
got `no checks reported`. `Build Gate` then passed on that PR after the probe had
closed it. Its ruleset assertion sits after the failing line and never executed,
so the probe proves protection only when it does not race. Evidence, with its
limits stated, is frozen at the ticket-owner runtime root under
`evidence/t014-probe/receipt.md`.

**Out of scope**: handoff v1, receipt semantics, any #77-owned surface, every
pin, and the live bump itself — which resumes on a fresh seat once this lands.

## Slice 3 re-cut — campaign 3 (`gh`-shim seam)

Campaign 2 closed at its two-submission cap with two BLOCKING rows open. Four of
six rows were killed and the repair's gains are real; this is a re-cut with the
test seam moved, not a restart.

**Root cause, one property.** The suite stubbed the production transport
*functions* and fed `await_observation` literal strings, so every classifier
inside those functions was unconstrained by construction. Three mutations of the
classifier survived — including one that reinstated the original defect verbatim
(a 5xx, rate limit or expired token classified as a reported check failure) and
one where an empty check list terminated the observation. Five mutations of the
branch chain survived, including removal of the `--force-with-lease` that the
receipt described as an atomic lease and that nothing asserted.

**The fix**: move the seam from stubbed production functions to a `gh` shim on
`PATH` returning representative payloads, so the classifiers and the
remote-carrying mechanisms actually execute.

- [ ] T030 Replace the production-function stubs with a `PATH` shim for `gh`, exercising representative outcomes: empty array, pending bucket, fail bucket, non-JSON/5xx body, and non-zero exit with a valid body
- [ ] T031 Prove `INV-79-PROBE-BRANCH-DISJOINT` end to end — the `--branch-ref` value reaches the remote push, the lease is asserted, the ownership receipt is written, and cleanup refuses a ref it did not create
- [ ] T032 Preserve campaign 2's accepted gains under the new seam: unbounded production observation with only a reported failure terminal, transport errors retried, and the three comparison-based invariants still killed

**Severity correction (epic altitude, A-007)**: `INV-79-OBSERVE-NOT-YET` is
**ADVISORY**, not BLOCKING. The spec's own definition of BLOCKING is "publishes a
wrong or unverifiable artifact to an external consumer under an immutable key",
and this row's failure mode is a fail-closed spurious `BLOCKED-REQUIRED-CI` that
publishes nothing. It was miscategorised against its own definition at spec time.
It cannot block the slice; it is still wanted, and the `gh` shim is expected to
kill it cheaply. If it is still open when the slice closes it ships as residual
`CNA205-AB79-OBSERVE-CLASSIFIER-01` with a watch duty: any future spurious
`BLOCKED-REQUIRED-CI` day is triaged against this residual first.

**Terminal guard**: if campaign 3 also closes with `INV-79-PROBE-BRANCH-DISJOINT`
open, the slice's architecture is wrong. Stop, do not open a fourth campaign, and
escalate with the auditor's evidence.

**Inheritance**: `refs/evidence/slice03-rejected-submission2` (`19d3d32`) is
read-only reference. Campaign 3's base is `3e8ebdf` so that everything reused
from it is re-audited inside the new candidate rather than inherited unaudited.

## Slice 4 — the proof mechanism changes (A-008)

The A-007 guard fired correctly and the epic owner adopted the escalation's
hypothesis: the recurring defect is a property of writing proofs in bash+bats,
not of this slice's production design. The `!`-prefix/`set -e` family has now
produced **three** assertions that could not fail, each invisible to six
personally falsified gate versions and caught only by mutation. So slice 4
changes the **proof mechanism**. It is a different architecture, not a fourth
campaign on the old one.

**Base**: `35ae5f4` (campaign 3's candidate) plus this mandate commit. That base
is designated read-only inheritance by A-008 — its production behaviour and its
43-of-46 caught mutation rows are assets — but it **carries the two open
findings slice 4 exists to close**, so the auditor verifies them in the
candidate rather than assuming the base is clean, and re-runs the inherited
mutants as a regression check.

- [ ] T033 Add a lint over the bats suites forbidding a `!`-prefixed pipeline anywhere but a test's final statement, wired so it runs on every proof execution; falsify it against **both** historical instances — slice-1 F-1's negated loop and AF-1's inert pipeline — which must both go RED, plus a compliant final-statement positive control
- [ ] T034 Rewrite AF-1's inert assertion into a form that can fail (final statement, or explicit rc capture and assert), proven by the exact receipt-before-leased-push mutant that survived all 39 tests
- [ ] T035 Fix AF-2 as the **production** defect it is: an absent ownership receipt must fail CLOSED — no receipt means not ours means touch nothing — and add the test that violates only the file-existence conjunct

T033 is the one that closes the class. T034 and T035 close the two instances.
`INV-79-PROBE-BRANCH-DISJOINT` remains **BLOCKING**; the epic owner confirmed
the ratification.

**If slice 4 also closes with that row open**, it is no longer an architecture
question: park the lane and escalate for a desk-level decision on whether the
probe should exist at all.

**Host constraints surviving the pause** (machine RELEASE 2026-08-20): no cold
realization while `/nix/store` is below the one-lane bar — warm incremental
only — and every realization holds `/tmp/machine/BUILD-TOKEN`, reporting
`available_bytes` at acquire **and** release. No new Claude-family authoritative
seat before 2026-08-21T09:00Z, which defers slice 4's auditor but not its
implementation.
