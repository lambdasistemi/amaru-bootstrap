# Tasks: Bump Amaru to Upstream Main

**Input**: Design documents in
`specs/068-bump-amaru-upstream/`

**Prerequisites**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), and [quickstart.md](quickstart.md)

**Tests**: RED-GREEN is mandatory. The dependency RED is the old pin
failing the freshly frozen exact-target assertion. The CLI instrument is
also seeded with a rejected accepted command and must demonstrably fail
before the selected real binary is accepted.

## Slice 1 - Repin Amaru and prove the real surface

**Goal**: Select the execution-time stock upstream commit without moving
another dependency, and prove the declared CLI plus live producer/consumer
boundary remain honest.

**Independent Test**: Both dependency records equal the frozen upstream
SHA; the unrelated-lock comparison is empty; seeded CLI drift exits
nonzero; the restored real surface, Build Gate, and Docker live verifier
exit zero.

- [ ] T001 [US1] Capture raw execution-time upstream main and
  `pragma-org/amaru#1098` state under the driver runtime
  `handoffs/`, stopping with a Q-file if the expected-red premise changed
- [ ] T002 [US1] Prove the current revisions in `flake.nix` and
  `flake.lock` fail the exact-target assertion, seed one rejected command
  in `tests/lib/cli-mock-surface.bash`, and freeze the raw nonzero
  `cli-mock-honesty` result plus complete RED diff
- [ ] T003 [US1] Restore only the temporary CLI seed, update the Amaru SHA
  in `flake.nix`, refresh only `.nodes.amaru` in `flake.lock`, and prove
  structurally that every unrelated lock node is unchanged
- [ ] T004 [US1] Run the real-binary CLI honesty check and, only if its raw
  output proves upstream command drift, reconcile the declared surface in
  `tests/lib/cli-mock-surface.bash`, `tests/check-cli-mock-honesty.sh`,
  `tests/test-bootstrap-producer-canonical-cli.bats`,
  `tests/test-bootstrap-producer-history.bats`,
  `tests/test-bootstrap-producer-sparse-boundaries.bats`,
  `tests/test-amaru-relay-bootstrap.bats`, and
  `tests/test-relay-entrypoint.bats` without weakening fail-closed behavior
- [ ] T005 [US1] Require the exact-pin assertion and
  `nix build .#checks.x86_64-linux.cli-mock-honesty` to exit zero, then
  freeze post-edit hashes and a complete GREEN diff under the driver
  runtime `handoffs/`
- [ ] T006 [US1] Capture raw zero-exit `just build-gate` and `./gate.sh`
  runs, including the live producer/consumer observation, after the final
  edit
- [ ] T007 [US1] Obtain navigator RED and GREEN approvals, run the
  handoff-completeness gate, and commit the reviewed slice as
  `build: bump amaru to upstream main` with trailer
  `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Slice 2 - Publish review evidence (orchestrator-owned)

**Goal**: Make the selected source, expected-red boundary, compatibility
result, and verification legible to a reviewer, then close task accounting
without merging.

- [ ] T008 [US1] Refresh pull request #69 from
  `/tmp/ms-1/amaru-bootstrap-68/pr-body.md` with a plain-language landed
  chapter and technical evidence for the selected upstream SHA, unchanged
  lock nodes, CLI honesty result, live boundary, and expected downstream red
- [ ] T009 [US1] Verify hosted checks named `Build Gate` and
  `Live Bootstrap Producer` both conclude success on the reviewed
  implementation commit and retain the mechanically queried result under
  `/tmp/ms-1/amaru-bootstrap-68/logs/`
- [ ] T010 [US1] Independently rerun `./gate.sh`, audit every branch commit
  and task mapping, mark the orchestrator-owned tasks complete in
  `specs/068-bump-amaru-upstream/tasks.md`, and commit
  `docs: finalize upstream amaru bump evidence` with trailer
  `Tasks: T008, T009, T010`

## Dependencies and Execution Order

- T001 is the immutable source identity and premise gate; no edit starts
  before it succeeds.
- T002 proves both the ticket RED and the CLI instrument's negative control.
- T003 depends on navigator approval of the frozen RED.
- T004 is evidence-conditional and may complete with zero test-file edits
  when the real binary accepts the existing declared surface.
- T005 and T006 run only after the final edit.
- T007 is a synchronization barrier: the driver must read literal
  navigator approvals before gate and commit.
- T008 starts after the accepted implementation commit is pushed.
- T009 blocks T010 because final evidence cannot claim hosted checks before
  both named checks conclude success on that commit.
- No task is parallelized because every step shares one source identity and
  one worktree.

## Implementation Strategy

1. Freeze the upstream fact and stop if the issue premise changed.
2. Prove the old pin is wrong and the CLI invariant can fail.
3. Repin one input and prove all other lock nodes stayed still.
4. Let the real binary—not a guessed compatibility story—decide whether
   any declared test surface must move.
5. Freeze post-edit evidence sequentially, pass the full live gate, and
   land one reviewed bisect-safe commit.
6. The ticket orchestrator stamps T001-T007 into that same commit, refreshes
   PR #69, waits for both hosted checks, lands the evidence task update,
   finalizes, and hands the ready PR to the operator without merging.
