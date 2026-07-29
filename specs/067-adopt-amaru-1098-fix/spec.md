# Feature Specification: Adopt the Amaru Consensus Fix

**Feature Branch**: `chore/67-adopt-amaru-1098-fix`
**Created**: 2026-07-29
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#67`](https://github.com/lambdasistemi/amaru-bootstrap/issues/67)

## User Scenarios & Testing

### User Story 1 - Publish the fixed upstream Amaru (Priority: P1)

As an Antithesis testnet operator, I can consume a bootstrap-producer image
built from stock upstream Amaru main containing the #1098 consensus fix,
with evidence that its command surface and live bootstrap boundary still
work.

**Independent Test**: Freeze upstream main, prove it contains merge commit
`437ff6c4fb506e1347eee9e619271a5ccb55a401`, prove the old pin differs,
select it in both dependency records, and require the real CLI check, full
local gate, hosted checks, and immutable PR image inspection to succeed.

**Acceptance Scenarios**:

1. **Given** the repository is pinned before the fix, **when** upstream
   main is frozen, **then** the selected exact SHA contains the #1098 squash
   merge and remains bare `pragma-org/amaru`.
2. **Given** the new source revision, **when** compatibility is tested,
   **then** the real binary accepts the declared command surface and the
   complete Docker live verifier holds for at least 60 seconds.
3. **Given** hosted checks succeed, **when** the PR image is inspected,
   **then** its immutable tag and registry digest are recorded for the
   downstream Antithesis adoption.
4. **Given** the supplier image is published, **when** this PR is reported,
   **then** no claim is made that the separate fault-injection acceptance
   run has already proved zero consensus deaths.

### Edge Cases

- Upstream main may advance during execution. The driver freezes one SHA
  immediately before editing and proves it is at or after `437ff6c4`.
- A squash merge does not have the tested preview head as an ancestor.
  The main-tree source must therefore be rebuilt and gated independently.
- Updating the input may rewrite unrelated lock entries. Removing
  `.nodes.amaru` from before/after JSON must produce an empty diff.
- A green package build cannot prove the live cardano-node-to-Amaru seam;
  the Docker verifier remains mandatory.
- A PR image can exist under a mutable-looking PR label. The reported
  reference must include the exact repository commit and resolved digest.

## Requirements

### Functional Requirements

- **FR-001**: The driver MUST capture execution-time
  `pragma-org/amaru` `refs/heads/main` as raw evidence immediately before
  editing.
- **FR-002**: The captured target MUST contain
  `437ff6c4fb506e1347eee9e619271a5ccb55a401`.
- **FR-003**: `flake.nix` and `.nodes.amaru` in `flake.lock` MUST name the
  same captured full SHA.
- **FR-004**: The source MUST remain bare stock `pragma-org/amaru` with no
  fork, patch, branch pin, moving tag, or vendored source.
- **FR-005**: Every lock node unrelated to Amaru MUST remain unchanged.
- **FR-006**: A seeded rejected command MUST prove
  `cli-mock-honesty` can fail, and the restored declared surface MUST pass
  against the selected real binary.
- **FR-007**: Existing offline peer-snapshot staging MUST remain unchanged
  unless the selected source produces a new, evidenced build failure; any
  adaptation requires a Q-file and plan amendment before editing.
- **FR-008**: `just build-gate` and `./gate.sh` MUST exit zero after the
  final edit, including the live consumer observation of at least 60
  seconds.
- **FR-009**: Exactly one reviewed, bisect-safe implementation commit MUST
  contain the source and lock pin.
- **FR-010**: Hosted checks `Build Gate` and
  `Live Bootstrap Producer` MUST succeed on that implementation commit.
- **FR-011**: The PR image MUST be published as
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-<PR>-<commit-sha>` and
  its registry digest MUST be recorded.
- **FR-012**: The PR MUST stay draft until the milestone desk answers the
  merge-authorization question.
- **FR-013**: Issue #67 MUST remain open through the downstream Antithesis
  run, which is not claimed by this supplier PR.

## Success Criteria

- **SC-001**: One frozen upstream-main SHA at or after `437ff6c4` appears
  in both Amaru dependency records.
- **SC-002**: The unrelated-lock comparison is empty.
- **SC-003**: Seeded CLI RED is nonzero; restored CLI, Build Gate, and full
  live gate are zero.
- **SC-004**: Both required hosted checks succeed at the reviewed commit.
- **SC-005**: Registry inspection returns the expected PR tag and a
  content digest.
- **SC-006**: No source fork, patch, unrelated code change, weakened
  assertion, or premature downstream success claim appears in the diff.

## Assumptions

- At planning time, upstream main is
  `437ff6c4fb506e1347eee9e619271a5ccb55a401`.
- The existing peer-snapshot workaround from #68 is expected to support
  the selected source, but the actual selected-source build is authoritative.
- The milestone desk, not this implementation pair, decides merge
  authorization and commissions the downstream Antithesis run.
