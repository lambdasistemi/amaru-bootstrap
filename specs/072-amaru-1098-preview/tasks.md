# Tasks: Preview the Amaru #1098 Fix Head

**Input**: Design documents in
`specs/072-amaru-1098-preview/`

**Prerequisites**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), and [quickstart.md](quickstart.md)

**Tests**: RED-GREEN is mandatory. The dependency RED is the old pin
failing the exact-target assertion. The CLI-honesty comparator must also
reject a temporary false accepted command before its green result is
trusted.

## Slice 1 - Pin and prove the preview source

**Goal**: Select the immutable open-PR head without moving another
dependency, prove main's peer-snapshot staging remains sufficient, and
cross the real CLI and live bootstrap boundaries.

**Independent Test**: Both dependency records equal the frozen #1098 head;
the unrelated-lock comparison is empty; seeded CLI drift exits nonzero;
the restored real surface, Build Gate, and Docker live verifier exit zero;
`nix/amaru.nix` has no final diff.

- [ ] T001 [US1] Capture the execution-time #1098 branch head and require
  it to equal the planned target in
  `/tmp/ms-1/amaru-bootstrap-1098-preview/pin-driver/handoffs/upstream-head.raw.log`
- [ ] T002 [US1] Prove the current revisions in `flake.nix` and
  `flake.lock` fail the exact-target assertion and record the nonzero result
  in `/tmp/ms-1/amaru-bootstrap-1098-preview/pin-driver/handoffs/pin-red.raw.log`
- [ ] T003 [US1] Temporarily seed one invalid accepted command in
  `tests/lib/cli-mock-surface.bash`, prove
  `nix build .#checks.x86_64-linux.cli-mock-honesty` exits nonzero, freeze
  the complete RED handoff, obtain navigator approval, and restore only the
  seed
- [ ] T004 [US1] Update the exact Amaru SHA in `flake.nix`, refresh only
  `.nodes.amaru` in `flake.lock`, and prove all unrelated lock nodes are
  structurally unchanged
- [ ] T005 [US1] Require the selected-source
  `cli-mock-honesty` check to exit zero and prove `nix/amaru.nix` is
  unchanged, stopping with a Q-file and raw build evidence if the existing
  peer-snapshot staging does not suffice
- [ ] T006 [US1] Capture zero-exit `just build-gate` and `./gate.sh` runs
  under
  `/tmp/ms-1/amaru-bootstrap-1098-preview/pin-driver/handoffs/`, including
  the live producer-consumer observation, then recheck the upstream branch
  head
- [ ] T007 [US1] Freeze sequential post-edit hashes and the complete GREEN
  diff for `flake.nix`, `flake.lock`, and
  `tests/lib/cli-mock-surface.bash`; obtain navigator approval; and commit
  as `build: pin amaru to #1098 preview head` with trailer
  `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Slice 2 - Publish and park evidence (orchestrator-owned)

**Goal**: Make the exact source, compatibility result, gates, and published
preview artifact legible to reviewers and the milestone desk without
finalizing or merging the draft PR.

- [ ] T008 [US1] Independently review the accepted implementation commit,
  stamp T001-T007 into this `tasks.md`, amend the same commit, and push
  `chore/72-preview-amaru-1098`
- [ ] T009 [US1] Refresh pull request #73 with a plain-language landed
  chapter and technical evidence for the selected source, unchanged lock
  nodes, peer-snapshot sufficiency, negative control, and local gate
- [ ] T010 [US1] Mechanically verify hosted checks `Build Gate` and
  `Live Bootstrap Producer` conclude success on the exact pushed
  implementation SHA and save their URLs under
  `/tmp/ms-1/amaru-bootstrap-1098-preview/logs/`
- [ ] T011 [US1] Verify the existing PR-image workflow publishes
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-73-<sha>`, resolve its
  registry digest, and record tag plus digest in pull request #73
- [ ] T012 [US1] Mark T008-T012 complete in this `tasks.md`, commit the
  final evidence accounting as `docs: record amaru 1098 preview evidence`
  with trailer `Tasks: T008, T009, T010, T011, T012`, report tag, digest,
  and evidence in
  `/tmp/ms-1/amaru-bootstrap-1098-preview/STATUS.md`, and verify pull
  request #73 remains open and draft

## Dependencies and Execution Order

- T001 freezes the source identity; no edit begins before it succeeds.
- T002 and T003 establish the dependency and instrument RED states.
- T004 begins only after navigator approval of the frozen RED handoff.
- T005 is the consumer compatibility decision. A failure cannot widen the
  owned-file fence without a Q-file and amended plan.
- T006 runs only after the final implementation edit.
- T007 is a literal synchronization barrier: the driver cannot gate or
  commit before reading the navigator's GREEN approval.
- T008 starts after both `COMMIT <sha>` and
  `NAVIGATOR-VERIFIED <sha>` exist.
- T009 follows the first push so the PR body describes landed bytes.
- T010 blocks T011 because the image publisher is downstream of successful
  PR CI.
- T012 closes evidence accounting but deliberately does not drop
  `gate.sh`, mark the PR ready, or merge it.
- No task is parallelized because every proof belongs to one source
  identity and one ordered publication chain.

## Implementation Strategy

1. Freeze the force-pushable upstream head and prove the old pin is RED.
2. Prove the CLI-honesty instrument rejects a false declaration.
3. Repin one input and prove all other lock nodes stayed fixed.
4. Let the real selected-source build determine whether existing
   peer-snapshot staging suffices.
5. Cross the full local build and live boundaries, then freeze evidence
   sequentially.
6. Accept one navigator-approved, bisect-safe implementation commit.
7. Push, verify hosted CI and publication, report the immutable tag/digest,
   and park the draft PR open.
