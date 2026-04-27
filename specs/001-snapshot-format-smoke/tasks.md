---
description: "Task list for 001-snapshot-format-smoke"
---

# Tasks: Snapshot Format Smoke Test

**Input**: Design documents from [`specs/001-snapshot-format-smoke/`](.)
**Prerequisites**: [`spec.md`](./spec.md), [`plan.md`](./plan.md), [`research.md`](./research.md), [`data-model.md`](./data-model.md), [`contracts/smoke-test-cli.md`](./contracts/smoke-test-cli.md), [`quickstart.md`](./quickstart.md)

**Tests**: Tests are requested and IN scope (bats unit tests for failure paths + an end-to-end integration test against the vendored fixture).

**Organization**: One user story (US1). Phase 1 is shared infrastructure (Nix flake + fixture); Phase 2 is the US1 orchestrator and its tests; Phase 3 is CI wiring; Polish is justfile + manual quickstart validation. There is no Phase "Foundational" distinct from Setup because the flake outputs ARE the foundation.

## Format

```text
- [ ] [TaskID] [P?] [Story?] Description with file path
```

- **[P]**: parallelizable (different files, no incomplete-task dependencies)
- **[US1]**: belongs to User Story 1 (the only story)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Nix flake + fixture bundle. Everything Phase 2 will consume.

- [x] T001 Write [`cabal.project`](../../../cabal.project) with `index-state` (timestamps for hackage and CHaP) and one `source-repository-package` for `IntersectMBO/ouroboros-consensus` pinned by SHA, with `--sha256:` in **nix32** format per [research.md R-002](./research.md#r-002-build-iog-tools-via-haskellnix--chap) and constitution Principle III
- [x] T002 Rewrite [`flake.nix`](../../../flake.nix) to a thin entry point: inputs (`nixpkgs`, `flake-utils`, `haskellNix`, `CHaP`, `crane`, `amaru` as non-flake input), `nixConfig` with IOG cache, perSystem outputs delegating to `nix/*` modules per [plan.md "Source Code"](./plan.md#source-code-repository-root). Replace the current crane-only placeholder
- [x] T003 [P] Create [`nix/project.nix`](../../../nix/project.nix): `haskell-nix.cabalProject'` consuming `cabal.project`, IOG-cache-friendly, exposes `hsPkgs`. References [research.md R-002](./research.md#r-002-build-iog-tools-via-haskellnix--chap)
- [x] T004 [P] Create [`nix/amaru.nix`](../../../nix/amaru.nix): `craneLib.buildPackage` consuming `inputs.amaru.outPath`, builds the `amaru` binary with `--release`. References [research.md R-003](./research.md#r-003-build-amaru-via-crane)
- [x] T005 Create [`nix/iog-tools.nix`](../../../nix/iog-tools.nix): extracts `hsPkgs.ouroboros-consensus-cardano.components.exes.db-synthesizer` and `.db-analyser` from `nix/project.nix` outputs. Depends on T003
- [x] T006 Create [`nix/checks.nix`](../../../nix/checks.nix): re-exports `amaru` (T004), `db-synthesizer` and `db-analyser` (T005), plus a `shellcheck` derivation that lints `scripts/smoke-test.sh`. Depends on T004, T005
- [x] T007 Create [`nix/apps.nix`](../../../nix/apps.nix): exposes `nix run .#smoke-test`, `.#amaru`, `.#db-synthesizer`, `.#db-analyser` per [contracts/smoke-test-cli.md "Invocation"](./contracts/smoke-test-cli.md#invocation). Depends on T006
- [x] T008 [P] Create [`nix/shell.nix`](../../../nix/shell.nix): dev shell exposing the three binaries above plus `just`, `jq`, `shellcheck`, `bats`. Depends on T004, T005
- [x] T009 [P] Vendor fixture bundle: copy [`pragma-org/amaru/docker/testnet/p1-config`](https://github.com/pragma-org/amaru/tree/main/docker/testnet/p1-config) at a recorded SHA into [`specs/001-snapshot-format-smoke/fixtures/p1-config/`](./fixtures/p1-config/), plus [`specs/001-snapshot-format-smoke/fixtures/PROVENANCE.md`](./fixtures/PROVENANCE.md) recording source SHA + license note per [research.md R-006](./research.md#r-006-fixture-bundle-vendoring-strategy). Independent of all flake tasks

**Checkpoint**: `nix flake check` succeeds locally; `nix run .#amaru -- --help`, `nix run .#db-synthesizer --help`, `nix run .#db-analyser --help` all return zero. Fixture bundle accessible at the recorded path.

---

## Phase 2: User Story 1 - Operator validates the no-fork hypothesis (Priority: P1) 🎯 MVP

**Goal**: An operator runs one command and gets a `PASS` / `FAIL: ...` verdict in under five minutes.

**Independent Test**: `nix run .#smoke-test -- specs/001-snapshot-format-smoke/fixtures/p1-config /tmp/smoke-out` exits 0 and prints `PASS` as its last stdout line, OR exits non-zero with one of the documented `FAIL: ...` outcomes. Either way the verdict is the deliverable per [spec.md SC-001/SC-002](./spec.md#measurable-outcomes).

### Tests for User Story 1

> **Write these tests FIRST and ensure they FAIL before implementation. Tests use [bats](https://github.com/bats-core/bats-core) (in dev shell via T008).**

- [ ] T010 [P] [US1] Pre-flight validation tests in [`tests/test-config-error.bats`](../../../tests/test-config-error.bats): missing config.json → exit 3 + `FAIL: configuration error: missing configs/config.json`; non-empty out-dir → exit 3 + `FAIL: configuration error: out-dir not empty`; missing kes.skey → exit 3 + matching message. Covers [contracts/smoke-test-cli.md "Pre-flight validation"](./contracts/smoke-test-cli.md#pre-flight-validation) and [spec.md FR-007](./spec.md#functional-requirements)
- [ ] T011 [P] [US1] Tool-error path tests in [`tests/test-tool-error.bats`](../../../tests/test-tool-error.bats): mock `db-synthesizer` to exit 1 → smoke-test exits 2 + `FAIL: tool error: synthesise`, with `synthesise.stderr.log` non-empty. Same for `db-analyser` and `amaru`. Covers [data-model.md "State Transitions"](./data-model.md#state-transitions) and [spec.md FR-005, FR-006, FR-010](./spec.md#functional-requirements)
- [ ] T012 [P] [US1] End-to-end integration test in [`tests/test-smoke-integration.bats`](../../../tests/test-smoke-integration.bats): runs the real `nix run .#smoke-test` against the vendored fixture, asserts the run completes within five minutes (SC-005), the last stdout line is `PASS`, the penultimate stdout line is `report: <path>`, and `report.txt` exists at that path. This test produces the actual hypothesis verdict

### Implementation for User Story 1

- [ ] T013 [US1] Create [`scripts/smoke-test.sh`](../../../scripts/smoke-test.sh) skeleton: shebang, `set -euo pipefail`, argument parsing (`<bundle>` `<out-dir>`), pre-flight validation per [contracts/smoke-test-cli.md "Pre-flight validation"](./contracts/smoke-test-cli.md#pre-flight-validation). Verdict-line emission helper. Makes T010 pass. Implements [spec.md FR-001, FR-007, FR-008](./spec.md#functional-requirements)
- [ ] T014 [US1] Add bulk-credentials assembly to `scripts/smoke-test.sh`: read each key file, emit `<out-dir>/bulk-credentials.json` per [data-model.md "Bulk credentials JSON"](./data-model.md#bulk-credentials-json)
- [ ] T015 [US1] Add `db-synthesizer` step to `scripts/smoke-test.sh`: invoke with `--config`, `--bulk-credentials-file`, `-s <slots-for-1-epoch>`, `--db <out-dir>/chain-db`. Capture stderr to `<out-dir>/synthesise.stderr.log`. On non-zero exit: emit `FAIL: tool error: synthesise` and exit 2 per [data-model.md "State Transitions"](./data-model.md#state-transitions). Implements [spec.md FR-002](./spec.md#functional-requirements)
- [ ] T016 [US1] Add epoch-boundary slot calculation to `scripts/smoke-test.sh`: read `epochLength` from `<bundle>/configs/shelley-genesis.json` via `jq`; snapshot slot = `epochLength` per [research.md R-005](./research.md#r-005-detecting-the-epoch-boundary-slot)
- [ ] T017 [US1] Add `db-analyser --store-ledger SLOT` step to `scripts/smoke-test.sh`: capture stderr; on non-zero exit OR no snapshot file produced → `FAIL: tool error: dump`, exit 2. Implements [spec.md FR-003](./spec.md#functional-requirements)
- [ ] T018 [US1] Add `amaru convert-ledger-state` step to `scripts/smoke-test.sh`: capture stderr; on non-zero exit → `FAIL: format mismatch`, exit 1; surface amaru's full stderr in `report.txt` per [spec.md FR-004, FR-010](./spec.md#functional-requirements)
- [ ] T019 [US1] Add `report.txt` emission to `scripts/smoke-test.sh`: bundle path, out-dir path, verdict, per-step exit codes, stderr log paths, run timestamp per [contracts/smoke-test-cli.md "On-disk artefacts"](./contracts/smoke-test-cli.md#on-disk-artefacts). Stdout protocol: `report: <path>\n<verdict>` per [contracts/smoke-test-cli.md "Stdout shape"](./contracts/smoke-test-cli.md#stdout-shape). Makes T011 pass. Implements [spec.md FR-005, FR-006](./spec.md#functional-requirements)
- [ ] T020 [US1] shellcheck cleanup of `scripts/smoke-test.sh`: zero warnings under `shellcheck -s bash -e SC1091`. Constitution Code Quality Gate
- [ ] T021 [US1] Wire `scripts/smoke-test.sh` into [`nix/apps.nix`](../../../nix/apps.nix) as `apps.${system}.smoke-test`. Wire bats tests T010, T011, T012 into [`nix/checks.nix`](../../../nix/checks.nix). Makes T012 pass

**Checkpoint**: All three test tasks pass. `nix flake check` is green. The smoke-test verdict against the vendored fixture is recorded — that verdict IS the Phase 0 deliverable.

---

## Phase 3: CI Wiring

**Purpose**: Replace the stub workflow with a real Build Gate that exercises the flake checks and runs the smoke test.

- [ ] T022 Replace stub [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) with a real workflow per [`new-repository` skill "Build Gate Pattern"](https://github.com/paolino/llm-settings/blob/main/shared/skills/new-repository/SKILL.md): `runs-on: nixos`, cachix-action with `paolino` cache + `CACHIX_AUTH_TOKEN`, `Build Gate` job runs `nix build --quiet .#checks.x86_64-linux.amaru .#checks.x86_64-linux.iog-tools .#checks.x86_64-linux.shellcheck .#checks.x86_64-linux.smoke-test-bats`. Constitution Principle IV
- [ ] T023 Add `smoke-test` job to `.github/workflows/ci.yml` (depends on Build Gate): `nix run .#smoke-test -- specs/001-snapshot-format-smoke/fixtures/p1-config "$RUNNER_TEMP/smoke-out"` and assert exit 0 + last line is `PASS`. This job's pass/fail IS the Phase 0 verdict published to GitHub

**Checkpoint**: A CI run on `main` records the verdict. Issue #1 closes when this job is green.

---

## Phase 4: Polish & Cross-Cutting Concerns

- [ ] T024 [P] Create [`justfile`](../../../justfile) with: `just smoke <bundle> <out-dir>` → wraps `nix run .#smoke-test`; `just shellcheck` → wraps `nix build .#checks.<sys>.shellcheck`; `just ci` → mirrors the GitHub workflow
- [ ] T025 Manual quickstart validation: follow [`quickstart.md`](./quickstart.md) end-to-end on a clean checkout (no `.direnv/`, no `result/`), record the wall-clock time, append the result + the verdict to the PR description. Validates [spec.md SC-005](./spec.md#measurable-outcomes)
- [ ] T026 Update [issue #1](https://github.com/lambdasistemi/amaru-bootstrap/issues/1) with the verdict and a link to the green CI run that recorded it. Close issue if `PASS`

---

## Dependencies & Execution Order

### Bucket dependencies

| Bucket | Depends on |
|--------|-----------|
| Phase 1 (Setup) | nothing |
| Phase 2 (US1) | Phase 1 complete |
| Phase 3 (CI) | Phase 2 complete |
| Phase 4 (Polish) | Phase 2 complete (Polish T024 independent of T025/T026) |

### Within Phase 1

- T001 sequential (cabal.project before flake imports it)
- T002 after T001 (flake.nix references cabal.project via project.nix)
- T003 [P], T004 [P] parallel after T002
- T005 after T003; T006 after T004 + T005; T007 after T006; T008 [P] after T003 + T004
- T009 [P] independent of all flake tasks — vendoring is filesystem copy + a markdown doc

### Within Phase 2

- T010, T011, T012 [P] all parallel — different test files
- Tests SHOULD be written and FAIL before T013-T021
- T013 → T014 → T015 → T016 → T017 → T018 → T019 (sequential — same file, layered logic)
- T020 after T019
- T021 after T020 + T010-T012 (wires tests into checks)

### Parallel opportunities

```bash
# Phase 1 parallel batch (after T002):
Task: nix/project.nix [T003]
Task: nix/amaru.nix [T004]
Task: vendor fixture [T009]   # independent of flake tasks

# Phase 2 test batch (parallel):
Task: tests/test-config-error.bats [T010]
Task: tests/test-tool-error.bats [T011]
Task: tests/test-smoke-integration.bats [T012]
```

---

## Implementation Strategy

This feature has **one user story**, so the standard "MVP first / incremental delivery" template collapses:

1. Phase 1: build the flake + fixture (foundation)
2. Phase 2: write failing tests, then implement the orchestrator step by step
3. Phase 3: CI records the verdict on GitHub
4. Phase 4: polish (justfile) and validation (manual quickstart, issue closure)

Each step is committed individually per the constitution's "Code Quality Gates" / "Development Workflow" sections (small focused commits, conventional commits, every commit compiles, `just ci` runs locally before push).

The verdict — `PASS` or `FAIL: format mismatch` — is the deliverable. Either outcome is success for Phase 0; only `FAIL: tool error` or `FAIL: configuration error` are bugs that block closure.

---

## Notes

- `[P]` tasks = different files, no incomplete-task dependencies
- The data-model state diagram (data-model.md) is the source of truth for verdict transitions; T015, T017, T018, T019 must collectively realise it
- Constitution Principle V (smallest provable step) is the guiding principle: every task on this list must reduce uncertainty about the no-fork hypothesis or directly publish the resulting verdict
- Out of scope (do NOT add tasks for): Phase 1+ orchestrator generalisation, docker images, header extraction, nonces composition, integration with `cardano-foundation/cardano-node-antithesis`, MkDocs site
