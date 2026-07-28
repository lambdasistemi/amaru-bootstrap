# Tasks: Execute CLI Mock Honesty in the Build Gate

**Input**: Design documents in
`specs/070-cli-mock-honesty-ci-wiring/`

**Prerequisites**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), and [quickstart.md](quickstart.md)

**Tests**: RED-GREEN is mandatory. The entry-point RED is a runtime-only
assertion that both explicit lists name the check and their exact requested
closure reaches its output. The invariant negative control is a temporary
rejected accepted-command declaration that must fail and then be restored
without a committed test diff.

## Slice 1 - Wire and falsify the explicit Build Gate

**Goal**: Make both explicit Build Gate consumers request the existing check,
while proving the check and the reachability instrument can both fail in the
directions acceptance depends on.

**Independent Test**: The same runtime assertion fails before the wiring and
passes afterward; seeded CLI drift fails; restoration, the local Build Gate,
the full live gate, and the complete owned-file diff pass review.

- [ ] T001 [US1] Write the runtime-only structural and exact-closure assertion under `/tmp/epic-55/amaru-bootstrap-70/wire-cli-honesty-driver/handoffs/`, then capture its nonzero baseline result against `.github/workflows/ci.yml` and `justfile`
- [ ] T002 [US1] Capture a positive control where `nix path-info -r` finds the directly requested `cli-mock-honesty` output and a negative baseline where the exact explicit Build Gate closure omits it under `/tmp/epic-55/amaru-bootstrap-70/wire-cli-honesty-driver/handoffs/`
- [ ] T003 [US1] Temporarily add the known rejected `convert-ledger-state` command to `CLI_MOCK_ACCEPTED_AMARU` in `tests/lib/cli-mock-surface.bash`, require the standalone check to fail and name it, then inverse-patch and hash-prove exact restoration before any implementation edit
- [ ] T004 [US1] Freeze sequential RED evidence in `/tmp/epic-55/amaru-bootstrap-70/wire-cli-honesty-driver/handoffs/red.diff`, pass the handoff-completeness gate, and obtain literal navigator `REVIEW-APPROVED red`
- [ ] T005 [US1] Add exactly one `.#checks.x86_64-linux.cli-mock-honesty` request to `.github/workflows/ci.yml` and exactly one matching request to `justfile`, changing no other behavior
- [ ] T006 [US1] Run the same runtime assertion to GREEN, prove the evaluated CLI mock honesty output is in the final exact requested closure, and capture sequential hashes and the complete owned-file diff
- [ ] T007 [US1] Require the restored standalone check, `just build-gate`, and `./gate.sh` to exit zero, retaining raw outputs including the live producer observation under `/tmp/epic-55/amaru-bootstrap-70/logs/`
- [ ] T008 [US1] Pass the GREEN handoff-completeness and navigator barriers, then commit exactly `.github/workflows/ci.yml` and `justfile` as `fix(ci): execute CLI mock honesty in Build Gate` with trailer `Tasks: T001, T002, T003, T004, T005, T006, T007, T008`

## Slice 2 - Publish review evidence (orchestrator-owned)

**Goal**: Make the wiring, both falsification controls, local/live results, and
hosted execution legible to a reviewer, then close task accounting without
merging.

- [ ] T009 [US1] Refresh pull request #71 from `/tmp/epic-55/amaru-bootstrap-70/pr-body.md` with a plain-language landed chapter and a technical evidence appendix covering baseline absence, final closure reachability, seeded failure, restoration, and local/live gate results
- [ ] T010 [US1] Capture successful hosted `Build Gate` and `Live Bootstrap Producer` conclusions plus the hosted Build Gate log line requesting `.#checks.x86_64-linux.cli-mock-honesty` under `/tmp/epic-55/amaru-bootstrap-70/logs/`
- [ ] T011 [US1] Independently rerun the final local gate, audit every branch commit and task mapping, mark the orchestrator-owned tasks complete in `specs/070-cli-mock-honesty-ci-wiring/tasks.md`, and commit `docs: finalize Build Gate CLI honesty evidence` with trailer `Tasks: T009, T010, T011`

## Dependencies and Execution Order

- T001 defines the single runtime assertion used on both sides of the change.
- T002 proves the closure instrument before its absence result is trusted.
- T003 proves the existing CLI invariant can fail and must restore the tracked
  test surface before T004.
- T004 is a synchronization barrier. No owned-file implementation edit starts
  before literal navigator RED approval.
- T005 is the complete implementation and changes only the two owned files.
- T006 reruns the identical assertion and exact closure identity after T005.
- T007 runs only after the last implementation write and exact test-surface
  restoration.
- T008 requires literal navigator GREEN approval before commit.
- T009 starts after the orchestrator independently accepts and pushes T008.
- T010 blocks T011 because final review metadata cannot claim hosted execution
  before the checks and logs exist.
- No task is parallelized because the evidence is sequential and both owned
  files represent one mirrored command contract.

## Implementation Strategy

1. Prove the current entry points are unreachable and the closure probe is
   capable of finding the target.
2. Prove the existing CLI invariant rejects realistic mock drift, then restore
   the tree exactly.
3. Add one mirrored target line to the two explicit consumers.
4. Reuse the same assertion to prove reachability, then run focused, local,
   full live, and hosted gates.
5. Land one navigator-reviewed implementation commit, publish evidence, remove
   the lifecycle gate, wait for final hosted checks, and hand back READY without
   merging.
