# Tasks: Adopt the Amaru Consensus Fix

**Input**: [spec.md](spec.md), [research.md](research.md),
[plan.md](plan.md), and [quickstart.md](quickstart.md)

## Slice 1 - Pin and prove

- [ ] T001 [US1] Capture raw execution-time upstream main, require one full
  SHA, and prove it contains #1098 squash commit `437ff6c4`
- [ ] T002 [US1] Prove both old pin records fail equality with the target,
  seed a rejected accepted command, capture nonzero CLI honesty, freeze the
  complete RED diff, and obtain navigator approval
- [ ] T003 [US1] Explicitly restore the seed, update `flake.nix` and only
  `.nodes.amaru` in `flake.lock`, and prove exact identity, no moving ref,
  and zero unrelated lock movement
- [ ] T004 [US1] Prove `nix/amaru.nix` and the CLI declaration have no
  final diff and pass selected-source `cli-mock-honesty`
- [ ] T005 [US1] Capture zero-exit `just build-gate` and `./gate.sh`,
  including the at-least-60-second live consumer observation, after the
  final edit
- [ ] T006 [US1] Freeze final hashes and GREEN diff, obtain navigator
  approval, and create one commit `build: adopt amaru consensus fix` with
  trailer `Tasks: T001, T002, T003, T004, T005, T006`

## Slice 2 - Publish and request authorization

- [ ] T007 [US1] Push the reviewed implementation commit and require hosted
  `Build Gate` and `Live Bootstrap Producer` success on that exact SHA
- [ ] T008 [US1] Inspect the commit-qualified PR #74 image, record its
  registry digest in the PR, and retain raw registry evidence
- [ ] T009 [US1] Independently rerun the full gate and finalization audit,
  update PR evidence, and post a merge-authorization Q-file to the
  milestone desk without merging or closing issue #67

## Dependencies and Execution Order

- T001 fixes the immutable target and blocks all edits.
- T002 is the reviewed RED barrier.
- T003 follows literal RED approval.
- T004 and T005 prove the restored selected-source state.
- T006 is the reviewed one-commit barrier.
- T007 and T008 require the pushed implementation SHA.
- T009 requires all local, hosted, and registry evidence.
- No task is parallelized because every proof shares one source identity.
