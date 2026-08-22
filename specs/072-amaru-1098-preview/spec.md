# Feature Specification: Preview the Amaru #1098 Fix Head

**Feature Branch**: `chore/72-preview-amaru-1098`  
**Created**: 2026-07-29  
**Status**: Draft preview  
**Input**: Issue #72 and the milestone preview brief

## User Scenarios & Testing

### User Story 1 - Pre-validate the upstream fix (Priority: P1)

As the milestone operator, I want an immutable bootstrap-producer image
built from the open Amaru #1098 fix head so that the real upstream-main
adoption in #67 is de-risked before the fix merges.

**Why this priority**: This is the entire purpose of the preview. A
consumer build and live bootstrap proof can reveal integration breakage
before the downstream Antithesis experiment spends a run on it.

**Independent Test**: Starting from the current bare-upstream-main
consumer, select the recorded #1098 head, prove the old selection differs,
then require the complete build, command-surface, and live bootstrap
checks to pass and publish an immutable pull-request image.

**Acceptance Scenarios**:

1. **Given** the #1098 branch still resolves to the recorded head, **When**
   the preview dependency is selected, **Then** both consumer dependency
   records identify that exact immutable revision and unrelated
   dependencies remain unchanged.
2. **Given** the consumer already stages the peer-snapshot inputs required
   by Amaru, **When** the selected source is built offline, **Then** those
   inputs still suffice or any necessary consumer adaptation is documented
   and proven without patching upstream.
3. **Given** the preview source builds, **When** the repository's complete
   local gate runs, **Then** the real command-surface check, all build-gate
   checks, and the live bootstrap boundary all pass.
4. **Given** both hosted pull-request checks pass, **When** the existing
   publishing workflow completes, **Then** immutable commit and PR image
   tags exist and resolve to a reported registry digest.
5. **Given** the preview evidence is complete, **When** the ticket is
   handed back, **Then** the draft PR remains open, prominently marked
   PREVIEW / DO NOT MERGE.

### Edge Cases

- The upstream branch force-pushes after planning but before the pin edit.
- The upstream branch moves after the pin commit but before evidence is
  finalized.
- The preview revision is not a descendant of the currently selected
  upstream-main revision.
- The selected source changes its build inputs or command surface.
- Local gates pass but one hosted check fails or runs on another commit.
- Hosted checks pass but the PR-image workflow does not publish.
- A tag exists but its registry digest cannot be resolved.

## Requirements

### Functional Requirements

- **FR-001**: The preview MUST select the exact execution-time head of
  `pragma-org/amaru#1098`, initially expected to be
  `b077d1dd38ed207c701283743b6e9379f7186ab0`.
- **FR-002**: The selected head MUST be rechecked immediately before the
  dependency edit; a moved head MUST be re-pinned and recorded.
- **FR-003**: Only the preview branch and draft PR may select the non-main
  upstream revision. Repository `main` MUST remain on a bare
  `pragma-org/amaru` origin-main revision.
- **FR-004**: The dependency declaration and lock record MUST agree on the
  exact full revision, and every unrelated lock node MUST remain unchanged.
- **FR-005**: The work MUST verify whether the peer-snapshot staging already
  present on `main` still suffices for the selected source.
- **FR-006**: Any consumer-side adaptation MUST be the smallest
  reproducible orchestration change supported by raw failure evidence; it
  MUST NOT fork, patch, or vendor upstream Amaru.
- **FR-007**: The real-binary command-surface honesty check MUST be proven
  able to fail before its passing result is accepted.
- **FR-008**: The repository's full local CI mirror MUST pass on the final
  preview pin, including the build gate and Docker live bootstrap verifier.
- **FR-009**: Hosted checks named `Build Gate` and
  `Live Bootstrap Producer` MUST pass on the exact published preview commit.
- **FR-010**: The existing pull-request image workflow MUST publish an
  immutable preview image. No new publishing infrastructure may be invented
  without a milestone-desk ruling.
- **FR-011**: The image tag and registry digest MUST be mechanically
  resolved, recorded in the PR evidence, and reported through the milestone
  runtime protocol.
- **FR-012**: A failure traceable to the #1098 source MUST be preserved as a
  finding with raw evidence rather than weakened or bypassed.
- **FR-013**: The draft PR MUST remain open and MUST NOT be marked ready,
  merged, or used to change repository `main`.
- **FR-014**: The downstream Antithesis preview run MUST remain out of scope
  and be commissioned by the milestone desk after image publication.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Both preview dependency records equal one recorded 40-character
  upstream head, while a structural comparison reports zero unrelated lock
  changes.
- **SC-002**: The command-surface negative control exits nonzero and the
  restored real-binary check exits zero.
- **SC-003**: The complete local gate exits zero with one successful live
  consumer observation held for at least 60 seconds.
- **SC-004**: Both required hosted checks conclude success on the exact
  preview commit.
- **SC-005**: At least one immutable PR-number image tag is published and
  resolves to one reported content digest.
- **SC-006**: The PR remains draft, open, and visibly marked
  PREVIEW / DO NOT MERGE at handoff.

## Assumptions

- The repository's existing PR-image workflow applies to same-repository
  draft pull requests.
- The initial #1098 head is
  `b077d1dd38ed207c701283743b6e9379f7186ab0`; execution-time identity is
  authoritative.
- The selected head is intentionally allowed to diverge from current Amaru
  main because this branch is disposable preview evidence and cannot merge.
- The milestone desk will consume the reported tag and digest to commission
  the downstream Antithesis run.

## Out of Scope

- Merging or marking the preview PR ready.
- Adopting a non-main Amaru revision on repository `main`.
- Fixing Amaru consensus in this repository.
- Modifying cardano-node-antithesis or launching its Antithesis run.
