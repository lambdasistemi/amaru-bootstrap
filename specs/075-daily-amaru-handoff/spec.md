# Feature Specification: Daily Validated Amaru Image Handoff

**Feature Branch**: `ci/75-daily-amaru-handoff`
**Created**: 2026-07-31
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#75`](https://github.com/lambdasistemi/amaru-bootstrap/issues/75)

## User Scenarios & Testing

### User Story 1 - Observe one explicit daily result (Priority: P1)

As an operator, I receive one durable result for each UTC observation day
that names the exact upstream and pinned revisions. When upstream has not
changed and a validated handoff already exists, the result says `UNCHANGED`
and no source pin or producer image is changed.

**Why this priority**: Silence is ambiguous. The downstream automation and
the operator must distinguish a healthy no-op from a workflow that never ran.

**Independent Test**: Reconcile equal observed and pinned revisions with an
existing valid handoff, then verify that the durable daily result is
`UNCHANGED`, names both revisions, and leaves the pin and image identities
byte-for-byte unchanged.

**Acceptance Scenarios**:

1. **Given** equal observed and pinned revisions plus a valid handoff for the
   source tuple, **when** daily reconciliation runs, **then** it publishes one
   immutable `UNCHANGED` daily result naming both revisions.
2. **Given** the same day and identical inputs are reconciled again, **when**
   the result already exists, **then** the run succeeds idempotently without
   replacing or duplicating it.
3. **Given** an existing same-day result differs from the newly computed
   result, **when** reconciliation runs, **then** it fails loudly and preserves
   the existing result.

---

### User Story 2 - Validate and hand off a changed upstream (Priority: P1)

As a downstream testnet maintainer, I can consume a public immutable handoff
that links the exact bare upstream revision to the exact validated bootstrap
revision, immutable image digest, successful required CI, image publication,
and CLI-honesty evidence.

**Why this priority**: An image tag alone cannot prove which upstream source
was selected, whether required checks ran, or whether the registry content is
the artifact that downstream automation should pin.

**Independent Test**: Supply a synthetic changed upstream revision, follow
the exact-SHA path through protected integration and publication fixtures,
then validate a handoff whose linked identities all agree. Restore the real
source tuple and prove the real equal-revision path is an `UNCHANGED` no-op.

**Acceptance Scenarios**:

1. **Given** the exact SHA observed from bare `pragma-org/amaru` main differs
   from the repository pin, **when** reconciliation runs, **then** only that
   exact SHA is proposed and no owner, repository, ref, fork, tag, or patch
   semantics change.
2. **Given** the exact-pin proposal exists, **when** required CI has not
   succeeded for it, **then** integration, image success, and handoff success
   cannot be reported.
3. **Given** required CI succeeded and protected integration produced a final
   bootstrap revision, **when** its SHA-tagged image is successfully published
   and resolved to a digest, **then** one strict public handoff links all source,
   build, image, CI, publication, and CLI-honesty identities.
4. **Given** the same source tuple already has an identical handoff, **when**
   publication is retried, **then** the existing immutable handoff is reused;
   different bytes for the same tuple are rejected.

---

### User Story 3 - Fail closed at every incomplete boundary (Priority: P1)

As an operator, I see a loud failed daily run whenever source resolution,
origin validation, pin mutation, required CI, publication, digest resolution,
or receipt validation is incomplete. No success handoff is emitted from a
partial state.

**Why this priority**: A partial or fabricated handoff can silently feed the
wrong image to cross-organization consumers.

**Independent Test**: Inject wrong-origin, CLI-drift, missing-CI,
missing-publication, and missing-digest states one at a time and verify each
is red before any handoff publication operation is reached.

**Acceptance Scenarios**:

1. **Given** any source other than bare `pragma-org/amaru`
   `refs/heads/main`, **when** the source gate runs, **then** it fails before
   pin mutation.
2. **Given** a temporary mock-only CLI command, **when** the exact Build Gate
   path runs, **then** it fails before integration or publication; restoring
   the declaration exactly restores the green path.
3. **Given** CI, publication, digest, or CLI-honesty evidence is absent or
   inconsistent, **when** handoff generation runs, **then** no handoff exists.
4. **Given** a same-repository pull request, **when** the explicit App event
   probe is authorized, **then** a short-lived scoped App identity creates a
   disposable pull-request event that reaches `Build Gate` while the active
   main ruleset continues to require pull requests and `Build Gate`.

### Edge Cases

- Upstream may advance after observation. Every changed path stays bound to
  the one observed SHA and never silently re-resolves during pin mutation.
- The pin may already equal upstream while the validated handoff is missing
  because an earlier publication failed. That state resumes validation and
  publication; it is not `UNCHANGED`.
- A successful PR check does not identify the final integrated revision.
  Handoff CI and image evidence must name the final bootstrap revision.
- A tag can exist without the expected public receipt asset, or point to the
  wrong bootstrap revision. Both states are conflicts, never idempotent
  success.
- A registry tag may resolve to no digest or an unexpected digest. The
  handoff remains absent.
- Two retries can race for the same day or source tuple. Identical canonical
  bytes converge; different bytes fail without replacement.
- A pull request from a fork cannot receive App credentials and must execute
  only the no-mutation fixture path.

## Requirements

### Functional Requirements

- **FR-001**: Reconciliation MUST resolve exactly
  `https://github.com/pragma-org/amaru` `refs/heads/main` and retain the full
  observed SHA.
- **FR-002**: The repository pin MUST remain an exact full SHA for bare
  `pragma-org/amaru`; forks, patches, vendoring, moving refs, and tags are
  rejected before mutation.
- **FR-003**: One scheduled entry point and one manual entry point MUST drive
  the same reconciliation implementation, while pull requests exercise its
  injected no-production transport.
- **FR-004**: Equal observed and pinned SHAs MUST produce `UNCHANGED` only
  when a strict successful handoff already exists for that source tuple.
- **FR-005**: Every UTC day MUST produce one durable immutable daily result
  or one loud failed run; silence is never success.
- **FR-006**: A changed observation MUST update only to the observed SHA and
  MUST change only the Amaru lock node plus the `cardano-configurations` lock
  node selected by the recorded peer-snapshot resolution rule; every other lock
  node MUST be byte-identical and the gate MUST prove it. (Amended by A-001
  after `origin/main` anchored peer snapshots to the Amaru revision.)
- **FR-007**: Changed-source integration MUST use a short-lived token scoped
  to this repository, create a pull request, require the current `Build Gate`,
  and leave the active main ruleset in force.
- **FR-008**: No changed-source success may be emitted until required CI for
  the exact integrated bootstrap SHA succeeds.
- **FR-009**: The exact integrated bootstrap SHA MUST publish
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<bootstrap-sha>` and the
  registry MUST resolve it to `sha256:<64 lowercase hex>`.
- **FR-010**: Image publication MUST emit a strict receipt naming its run,
  job, source SHA, tag, digest, and immutable image reference.
- **FR-011**: Handoff v1 MUST include UTC observation day, upstream SHA,
  bootstrap SHA, immutable image reference, successful CI run/job identity,
  successful publication run/job identity, and exact CLI-honesty reachability
  evidence.
- **FR-012**: Handoff v1 MUST be public and machine-consumable across
  organizations without a cross-organization long-lived credential.
- **FR-013**: Daily results and handoffs MUST be canonical, immutable, and
  idempotent for their keys; an existing different result is a conflict.
- **FR-014**: Wrong origin/ref, synthetic changed, restored unchanged,
  CLI-drift, missing-CI, missing-publication, and missing-digest controls MUST
  be executable in local tests through an injected transport.
- **FR-015**: The pull-request fixture path MUST prove that the scoped App can
  create a disposable event reaching required CI without printing or
  persisting the token.
- **FR-016**: Any resolution, mutation, CI, integration, publication, digest,
  validation, or immutable-publication failure MUST exit nonzero and MUST NOT
  publish a success handoff.
- **FR-017**: The existing `cli-mock-honesty` implementation and accepted
  surface MUST remain unchanged in the committed result and reachable from
  the exact Build Gate path.
- **FR-018**: Production schedule activation MUST occur only through merging
  a pull request whose fixture and App-event probe paths have passed.
- **FR-019**: No token or secret value may be printed, committed, stored in a
  receipt, or persisted after its workflow job.
- **FR-020**: Cardano pins other than the `cardano-configurations` pin governed
  by FR-022, producer/runtime behavior, bootstrap bundle semantics, downstream
  repositories, and Antithesis execution MUST remain unchanged.
- **FR-021**: The live peer-snapshot resolution query MUST run only in the
  daily reconciliation/bump job, never in any build or verify workflow.
  `peer-snapshot-anchor` MUST stay in the required Build Gate, offline and
  unmodified, and MUST be re-enforced against the proposed commit.
- **FR-022**: The `cardano-configurations` pin MUST move only to the revision
  the recorded, independently re-runnable resolution rule selects. A
  hand-chosen, latest-by-default, or rule-changing move is rejected.
- **FR-023**: `scripts/resolve-peer-snapshots` MUST be consumed unmodified;
  the resolution rule itself is owned by issue #77 and is out of scope.
- **FR-024**: Resolution or offline-anchor failure on a changed day MUST fail
  closed as `BLOCKED-PEER-SNAPSHOT-RESOLUTION` with no handoff and no retry.
- **FR-025**: A focused check MUST be registered in `nix/checks.nix`, the
  `justfile` `build-gate` list, AND the `.github/workflows/ci.yml` Build Gate
  list, and MUST be shown able to fail from the hosted path. The hosted list is
  duplicated rather than derived, so a check absent from it never runs.

### Key Entities

- **Observation**: UTC day, exact upstream repository/ref/SHA, exact pinned
  SHA, and the resulting state transition.
- **Image publication receipt**: Exact bootstrap SHA, immutable image tag and
  digest, plus the successful publication workflow/run/job identity.
- **Handoff v1**: Immutable cross-organization contract linking upstream,
  bootstrap, image, CI, publication, and CLI-honesty evidence.
- **Daily result v1**: One immutable day-keyed `UNCHANGED` or `HANDOFF` result
  naming the observation and, for changed completion, the handoff identity.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Every successful UTC observation produces exactly one canonical
  day-keyed result; an identical retry adds zero new result bytes.
- **SC-002**: All seven injected failure classes exit nonzero before handoff
  publication, while changed and unchanged positive fixtures exit zero.
- **SC-003**: A final handoff contains one mutually consistent upstream SHA,
  bootstrap SHA, SHA tag, registry digest, CI identity, publication identity,
  and CLI-honesty evidence identity, with zero unknown fields.
- **SC-004**: A temporary mock-only command makes the exact Build Gate path
  red; after byte restoration the same path and full local CI are green.
- **SC-005**: A scoped App event produces a hosted `Build Gate` check while
  the main rules endpoint still reports both pull-request and required-check
  enforcement.
- **SC-006**: The final branch passes `just build-gate`, `just ci`, focused
  local workflow fixtures, and current-head hosted checks.
- **SC-007**: The committed diff contains zero producer/runtime changes, zero
  new long-lived credentials, zero moving image tags, zero downstream
  repository edits, and zero dependency-pin changes other than the Amaru pin
  and the rule-selected `cardano-configurations` pin.
- **SC-008**: Bumping the Amaru pin without regenerating
  `nix/peer-snapshots/resolution.json` makes `peer-snapshot-anchor` red, and
  the regenerated record makes it green offline — both shown, not assumed.

## Assumptions

- GitHub Releases provide the public immutable-key publication surface:
  tuple-keyed handoffs and day-keyed results use unique non-moving tags and
  canonical JSON assets; publication code never replaces an existing asset.
- The existing repository ruleset named `main` remains the source of truth
  for pull-request and `Build Gate` enforcement.
- `lambdasistemi-ci` remains installed org-wide with scoped contents,
  pull-request, and administration permissions; no new App permission is
  expected.
- Seat topology follows NOTE-025 minimize-Codex and is derived mechanically,
  not copied: ticket owner Claude, commit owner Grok `grok-4.6`, and a fresh
  Claude auditor per submission. Qwen is draft-only; `agy` is revoked; a Codex
  seat requires both Claude and Grok to be unavailable, disclosed first.
- The live resolution query is never run unauthenticated on the development
  host: local proofs use injected transports and fixtures, and only hosted CI
  and the production bump job perform the real query (NOTE-018 API budget).
