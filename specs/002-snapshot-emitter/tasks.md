---
description: "Task list for 002-snapshot-emitter"
---

# Tasks: Snapshot Emitter

**Input**: Design documents from [`specs/002-snapshot-emitter/`](.)
**Prerequisites**: [`spec.md`](./spec.md), [`plan.md`](./plan.md), [`research.md`](./research.md), [`data-model.md`](./data-model.md), [`contracts/snapshot-emitter-cli.md`](./contracts/snapshot-emitter-cli.md), [`quickstart.md`](./quickstart.md)

**Tests**: Tests are IN scope (TDD per the speckit RPI overlay; bats unit tests for failure paths + bats integration via the existing Phase 0 smoke test).

**ARCHITECTURE PIVOT (recorded 2026-04-28, after T001-T004 + T014)**: Research while implementing surfaced that upstream `ouroboros-consensus-cardano` already ships a `snapshot-converter` exe doing exactly what we need (`Mem` -> `Legacy` format conversion). The plan pivoted to exposing it directly via `nix/iog-tools.nix`, which makes T005-T013 (the custom-Haskell tasks) **superseded** — we ship zero custom Haskell, satisfy Principle II more strongly, and got a `PASS` verdict locally on the bridged smoke test. Tasks are renumbered below to reflect what actually landed.

**Organization**: One user story (US1) — same single-story collapse as Phase 0. Phase 1 is shared infrastructure (Cabal stanza + Nix wiring). Phase 2 is the orchestrator + tests. Phase 3 is CI verdict update. Phase 4 is polish.

## Format

```text
- [ ] [TaskID] [P?] [Story?] Description with file path
```

- **[P]**: parallelisable (different files, no incomplete-task dependencies)
- **[US1]**: belongs to User Story 1 (the only story)

---

## Phase 1: Setup (Cabal + Nix wiring)

**Purpose**: tell the build system about the new executable. After this phase, `nix flake show` lists `snapshot-emitter` as a package and `nix run .#snapshot-emitter -- --help`-style invocations resolve (even if the binary itself is just a stub).

- [x] T001 Add `executable snapshot-emitter` stanza to [`amaru-bootstrap.cabal`](../../../amaru-bootstrap.cabal): `main-is: Main.hs`, `hs-source-dirs: app/snapshot-emitter`, `other-modules: SnapshotEmitter`, `build-depends: base, bytestring, cardano-binary, directory, filepath, ouroboros-consensus, ouroboros-consensus-cardano, amaru-bootstrap`. Hackage-ready per constitution Code Quality Gates (cabal check clean, `-Werror`)
- [x] T002 [P] Create [`nix/snapshot-emitter.nix`](../../../nix/snapshot-emitter.nix): `project.hsPkgs.amaru-bootstrap.components.exes.snapshot-emitter`. References [research.md R-001](./research.md#r-001-legacy-snapshot-encoder-lives-in-upstreams-exposed-api)
- [x] T003 Wire `snapshotEmitterPkg` through [`flake.nix`](../../../flake.nix) into the perSystem outputs (alongside existing `amaruPkg`, `iogTools`). Depends on T002
- [x] T004 Update [`nix/checks.nix`](../../../nix/checks.nix) to expose `snapshot-emitter` as a flake check (just the exe build), and update [`nix/apps.nix`](../../../nix/apps.nix) to add `nix run .#snapshot-emitter` mapping per [contracts/snapshot-emitter-cli.md "Invocation"](./contracts/snapshot-emitter-cli.md#invocation). Depends on T003

**Checkpoint**: `nix flake show` lists `apps.x86_64-linux.snapshot-emitter` and `checks.x86_64-linux.snapshot-emitter`. The binary may still be a one-line stub at this point.

---

## Phase 2: User Story 1 - Operator closes the format gap (Priority: P1) 🎯 MVP

**Goal**: An operator runs the existing Phase 0 smoke test with the new emitter inserted, and the verdict flips from `FAIL: format mismatch` to `PASS`.

**Independent Test**: `nix run .#smoke-test -- specs/001-snapshot-format-smoke/fixtures/p1-config /tmp/smoke-out` exits 0 and prints `PASS` as its last stdout line. Per [spec.md SC-002](./spec.md#measurable-outcomes).

### Tests for User Story 1

> **Write these tests FIRST and ensure they FAIL before implementation.** Bats tests + hspec round-trip.

- [SUPERSEDED] T005 [P] [US1] Pre-flight + collision tests in [`tests/test-emitter-config-error.bats`](../../../tests/test-emitter-config-error.bats): missing slot-dir → exit 1; slot-dir is a regular file → exit 2; missing `state` → exit 2; missing `tables/tvar` → exit 2; output collision (file already exists) → exit 4. Covers [contracts/snapshot-emitter-cli.md "Exit codes"](./contracts/snapshot-emitter-cli.md#exit-codes) + [spec.md FR-004, FR-005, FR-008](./spec.md#functional-requirements) + [data-model.md state-transitions steps 1-2](./data-model.md#state-transitions)
- [SUPERSEDED] T006 [P] [US1] Codec round-trip in [`test/SnapshotEmitterSpec.hs`](../../../test/SnapshotEmitterSpec.hs): synthesise a small `ExtLedgerState CardanoBlock ValuesMK` (or use a trivial era stub if a full Cardano value is too heavy to construct), encode via `SnapshotEmitter.encode`, decode with the matching `decodeL`/`decodeExtLedgerState` from upstream, assert the round-trip is the identity. Covers [data-model.md state-transitions steps 5-6](./data-model.md#state-transitions) + [spec.md SC-005](./spec.md#measurable-outcomes) (determinism). Wire as a `test-suite` stanza in `amaru-bootstrap.cabal` if not already present
- [x] T007 [P] [US1] End-to-end PASS-verdict assertion in [`tests/test-smoke-pass.bats`](../../../tests/test-smoke-pass.bats): runs the bridged `nix run .#smoke-test` against the vendored fixture, asserts last stdout line is exactly `PASS` and `<out-dir>/snapshot.cbor` exists and is non-empty and `<out-dir>/converted/` exists. Per [spec.md SC-002](./spec.md#measurable-outcomes). This test will replace the "FAIL: format mismatch is acceptable" assertion in the existing `test-smoke-integration.bats`

### Implementation for User Story 1

- [SUPERSEDED] T008 [US1] Create [`app/snapshot-emitter/Main.hs`](../../../app/snapshot-emitter/Main.hs): argument parser (no flags, two positional args per [contracts "Arguments"](./contracts/snapshot-emitter-cli.md#arguments)), error formatter writing `snapshot-emitter: <class>: <detail>` lines to stderr per [contracts "Stderr"](./contracts/snapshot-emitter-cli.md#stdout--stderr), exit-code mapping per [contracts "Exit codes"](./contracts/snapshot-emitter-cli.md#exit-codes). `main = SnapshotEmitter.run >>= exitWith`
- [SUPERSEDED] T009 [US1] Create [`app/snapshot-emitter/SnapshotEmitter.hs`](../../../app/snapshot-emitter/SnapshotEmitter.hs) with `data Error` (the 5 classes from [data-model.md "Error class registry"](./data-model.md#error-class-registry)) and `preflight :: FilePath -> FilePath -> IO (Either Error ())` covering [data-model.md state-transitions steps 1-2](./data-model.md#state-transitions). Makes T005 pass for cases 1, 2, 3, 4, 5. Implements [spec.md FR-008](./spec.md#functional-requirements)
- [SUPERSEDED] T010 [US1] Add `loadDirectory :: FilePath -> IO (Either Error (ExtLedgerState CardanoBlock ValuesMK))` to `SnapshotEmitter.hs`: open `<slot-dir>/state` and `<slot-dir>/tables/tvar`, decode with `decodeL` + `decodeExtLedgerState` and the consensus tables decoder, then `withLedgerTables` merge per [research.md R-003](./research.md#r-003-v2inmemory-splits-what-the-legacy-format-had-inline-emitter-must-merge) + [data-model.md steps 3-5](./data-model.md#state-transitions). Implements [spec.md FR-002](./spec.md#functional-requirements)
- [SUPERSEDED] T011 [US1] Add `encodeAndWriteAtomic :: FilePath -> ExtLedgerState CardanoBlock ValuesMK -> IO (Either Error ())` to `SnapshotEmitter.hs`: encode via `encodeL ... encodeExtLedgerState` per [research.md R-001](./research.md#r-001-legacy-snapshot-encoder-lives-in-upstreams-exposed-api), write to `<out>.tmp.<pid>` inside a `bracket` that removes the temp on exception, then `renameFile` on success per [research.md R-005](./research.md#r-005-atomic-write-via-temp-then-rename) + [data-model.md steps 6-7](./data-model.md#state-transitions). Implements [spec.md FR-003, FR-005](./spec.md#functional-requirements)
- [SUPERSEDED] T012 [US1] Wire `run :: IO ExitCode` in `SnapshotEmitter.hs` composing `preflight >>= loadDirectory >>= encodeAndWriteAtomic`, mapping each `Error` to its rc per [data-model.md "Error class registry"](./data-model.md#error-class-registry); print `wrote <abs-path>` on success per [contracts "Stdout"](./contracts/snapshot-emitter-cli.md#stdout--stderr). Makes T005, T006 pass. Implements [spec.md FR-004, FR-006, FR-010](./spec.md#functional-requirements)
- [SUPERSEDED] T013 [US1] `cabal check` clean + fourmolu + hlint + `-Werror` build pass on `amaru-bootstrap.cabal`. Constitution Code Quality Gates

### Orchestrator change

- [x] T014 [US1] Update [`scripts/smoke-test.sh`](../../../scripts/smoke-test.sh) per [contracts "Composition with the Phase 0 smoke test"](./contracts/snapshot-emitter-cli.md#composition-with-the-phase-0-smoke-test): insert one new step between dump (current step 5) and convert (current step 6); call `snapshot-emitter "$SNAPSHOT_PATH" "$OUT/snapshot.cbor"`; capture stderr to `$OUT/emit.stderr.log`; pass `$OUT/snapshot.cbor` to `amaru convert-ledger-state --snapshot`. Update [`tests/test-tool-error.bats`](../../../tests/test-tool-error.bats) `install_passing_mock` to mock `snapshot-emitter` as a passing shim that touches `$2`. Implements [spec.md FR-009](./spec.md#functional-requirements). Makes T007 pass

**Checkpoint**: T005, T006, T007 all pass. `nix flake check` is green. Verdict on the vendored fixture is `PASS`.

---

## Phase 3: CI verdict update

**Purpose**: Phase 1 commits to `PASS`. The CI workflow's "FAIL: format mismatch is also valid" branch becomes incorrect — the smoke-test job should now fail if the verdict is anything other than `PASS`.

- [x] T015 Update [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml): `Build Gate` adds `.#checks.x86_64-linux.snapshot-emitter`. The `Smoke Test (Phase 0 verdict)` step renames to `Smoke Test (Phase 1 verdict)` and the case statement only accepts `PASS` (any `FAIL: ...` exits 1). The verdict-line `::notice::` becomes "Phase 1 PASS — bridge tool closes the format gap". Per [spec.md SC-002](./spec.md#measurable-outcomes)

**Checkpoint**: A CI run on `main` records `PASS` after this PR merges. Issue [#9](https://github.com/lambdasistemi/amaru-bootstrap/issues/9) closes when this job is green on `main`.

---

## Phase 4: Polish & Cross-Cutting Concerns

- [x] T016 [P] Add a `just emit <slot-dir> <out-file>` recipe to [`justfile`](../../../justfile) wrapping `nix run .#snapshot-emitter --`. Mirror the existing `just smoke` ergonomics
- [x] T017 Manual quickstart validation per [`quickstart.md`](./quickstart.md) on a clean checkout: record wall-clock time of the bridged smoke test against [spec.md SC-002](./spec.md#measurable-outcomes) (5-min budget) + paste verdict into the PR description
- [ ] T018 Update [`specs/001-snapshot-format-smoke/plan.md`](../../../specs/001-snapshot-format-smoke/plan.md) Status block to note Phase 1 supersedes the Phase 0 verdict (link the merged Phase 1 PR + the new `PASS` CI run). Comment on issue [#9](https://github.com/lambdasistemi/amaru-bootstrap/issues/9) with the verdict and the green CI run URL; close the issue if the CI run on main is `PASS`

---

## Dependencies & Execution Order

### Bucket dependencies

| Phase | Depends on |
|-------|-----------|
| Phase 1 (Setup) | nothing |
| Phase 2 tests (T005-T007) | nothing (parallel with Phase 1) |
| Phase 2 implementation (T008-T013) | Phase 1 complete + tests in T005-T007 written and red |
| Phase 2 orchestrator (T014) | T012 done (binary works) |
| Phase 3 (T015) | Phase 2 complete + local PASS verdict observed |
| Phase 4 (T016, T018) | Phase 3 complete |

### Within Phase 1

- T001 sequential (the cabal stanza is the foundation everything else imports)
- T002 [P] after T001
- T003 after T002 (flake.nix imports nix/snapshot-emitter.nix)
- T004 after T003

### Within Phase 2

- T005, T006, T007 [P] all parallel — different test files
- Tests SHOULD be written and FAIL before T008-T013
- T008 → T009 → T010 → T011 → T012 (sequential — same file, layered logic)
- T013 after T012
- T014 after T013

### Parallel opportunities

```bash
# Phase 1 batch (parallel with Phase 2 tests):
Task: amaru-bootstrap.cabal stanza [T001]
Task: tests/test-emitter-config-error.bats [T005]
Task: tests/test-smoke-pass.bats [T007]
Task: test/SnapshotEmitterSpec.hs [T006]

# Phase 4 batch (parallel after Phase 3):
Task: justfile recipe [T016]
Task: phase 0 plan.md status update [T018 first half]
```

---

## Implementation Strategy

This feature has **one user story** so MVP/incremental sequencing collapses:

1. **Phase 1**: build the cabal+nix scaffold (foundation)
2. **Phase 2**: write the three failing tests, then implement the orchestrator step by step matching the data-model state diagram, then change the smoke test to call the emitter
3. **Phase 3**: CI workflow records `PASS` on main
4. **Phase 4**: polish + close issue

Per the speckit RPI overlay: every commit small and focused; tests precede implementation; commit after each task or logical group; mark `[X]` in this file as you finish.

---

## Notes

- `[P]` tasks = different files, no incomplete-task dependencies
- The data-model state diagram (data-model.md) is the source of truth for the `preflight → loadDirectory → encodeAndWriteAtomic` decomposition; T009, T010, T011 must collectively realise it
- Constitution Principle V (smallest provable step) is the guiding principle: every task on this list must move us closer to a `PASS` verdict on the existing Phase 0 smoke test (SC-002), or directly publish that verdict
- Out of scope (do NOT add tasks for): header extraction, nonces composition, docker images, integration with `cardano-foundation/cardano-node-antithesis`, multi-snapshot batching, streaming variant, `--force` flag
