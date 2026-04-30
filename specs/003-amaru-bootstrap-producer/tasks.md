# Tasks: Amaru Bootstrap Producer

**Input**: Design documents from `/specs/003-amaru-bootstrap-producer/`
**Prerequisites**: [`plan.md`](./plan.md), [`spec.md`](./spec.md), [`research.md`](./research.md), [`data-model.md`](./data-model.md), [`contracts/`](./contracts/), [`quickstart.md`](./quickstart.md)

**Tests**: Test tasks are included. Strict TDD per the project's RPI overlay — tests are written and FAILING before the implementation that makes them pass.

**Organization**: One P1 user story (operator brings up Amaru next to a cardano-node — works for both antithesis cold-start and mainnet-mature scenarios from the same code path). Setup + Foundational are reused across all FRs; US1 is the deliverable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: User story label (US1 for the single P1 story)
- File paths are absolute against the repo root

## Path Conventions

Single Haskell project at repo root. New paths:
- `lib/HeaderExtractor.hs` (Haskell library module)
- `app/header-extractor/Main.hs` (Haskell executable main)
- `test/HeaderExtractorSpec.hs` (hspec test)
- `nix/header-extractor.nix`, `nix/bootstrap-producer-image.nix`
- `scripts/bootstrap-producer.sh` (orchestrator entrypoint)
- `tests/test-bootstrap-producer-*.bats` (bats coverage)
- `.github/workflows/publish-bootstrap-image.yml`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Cabal + Nix scaffolding so subsequent test+impl tasks can compile and run.

- [X] T001 Add `executable header-extractor` stanza to `amaru-bootstrap.cabal` with `main-is: Main.hs`, `hs-source-dirs: app/header-extractor`, build-depends including the existing `amaru-bootstrap` library plus `optparse-applicative` and `aeson`. Also extend the existing `library` stanza to expose `HeaderExtractor` (under `exposed-modules`) with build-depends on `ouroboros-consensus`, `ouroboros-consensus-cardano`, `ouroboros-consensus-diffusion`, `cardano-binary`, `aeson`. (Both stanzas updated — the library hosts the module, the exe imports it. Per Obs#2.) Backed by [plan.md Source Code structure](./plan.md#source-code-repository-root) and [R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server).
- [X] T002 [P] Create `nix/header-extractor.nix` extracting `hsPkgs.amaru-bootstrap.components.exes.header-extractor` (mirrors `nix/iog-tools.nix` pattern). Backed by [plan.md Source Code structure](./plan.md#source-code-repository-root).
- [X] T003 [P] Create `nix/bootstrap-producer-image.nix` skeleton wiring `pkgs.dockerTools.buildLayeredImage` with the 5 layers from [R-004](./research.md#r-004-image-layout). Empty entrypoint script reference for now (script lands in T015).
- [X] T004 Wire flake outputs in `flake.nix`: `packages.x86_64-linux.bootstrap-producer-image`, `apps.x86_64-linux.bootstrap-producer` (local nix-run wrapper), and add `header-extractor` + `bootstrap-producer-image` to `nix/checks.nix`. Backed by [R-003](./research.md#r-003-ghcrio-push-from-a-runs-on-nixos-self-hosted-runner) + [R-004](./research.md#r-004-image-layout).

**Checkpoint**: `nix flake show` lists the new packages/apps/checks. `nix build .#checks.x86_64-linux.header-extractor` may fail (no source yet) — that's expected; we are wired but not implemented.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `header-extractor` binary. US1's orchestrator depends on its three subcommands (`tip-info`, `list-blocks`, `get-header`); without it the era-aware wait loop and snapshot pipeline cannot run.

**⚠️ CRITICAL**: No US1 work can begin until this phase is complete

### TDD: tests first

- [X] T005 [P] Write FAILING hspec test in `test/HeaderExtractorSpec.hs`: `tipInfo` against a synthesized chain DB returns the expected `{slot, era, blockHash}` JSON (Conway era for the testnet_42 fixture); `listBlocks` returns the (slot, hash) pairs covering ≥ first immutable chunk; `getHeader SLOT.HASH` returns CBOR bytes equal to db-analyser's `--show-header` view of the same block. Use [Phase 0 fixture](../001-snapshot-format-smoke/fixtures/p1-config) as input. Backed by [R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server) + [R-009](./research.md#r-009-wait-strategy--poll-immutable-db-tip-info) + [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection).
- [X] T006 [P] Write FAILING bats test in `tests/test-header-extractor-cli.bats`: subcommand routing (`tip-info`, `list-blocks`, `get-header`); flag parsing (`--db`, `--config`); JSON output shape for `tip-info` (`{"slot": <int>, "era": "<EraName>", "blockHash": "<hex>"}`); exit-code mapping per [contracts/bootstrap-producer-cli.md exit codes](./contracts/bootstrap-producer-cli.md#exit-codes) (rc=7 tool-error: extract on malformed input). Backed by [contracts/bootstrap-producer-cli.md](./contracts/bootstrap-producer-cli.md) + [R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server).

### Implementation

- [X] T007 Create `lib/HeaderExtractor.hs` with `tipInfo :: FilePath -> NodeConfig -> IO TipInfo` (where `data TipInfo = TipInfo { slot :: SlotNo, era :: EraName, blockHash :: ByteString }`) opening only the immutable DB via `Ouroboros.Consensus.Storage.ImmutableDB` and pattern-matching the tip's era via the HardFork combinator. Backed by [R-009](./research.md#r-009-wait-strategy--poll-immutable-db-tip-info) + [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection) + [data-model.md Cluster chain database validation rules](./data-model.md#cluster-chain-database-live-input).
- [X] T008 Extend `lib/HeaderExtractor.hs` with `listBlocks :: FilePath -> NodeConfig -> IO [(SlotNo, HeaderHash)]` iterating the immutable DB chunks via `Ouroboros.Consensus.Storage.ChainDB.iterate`. Output JSON shape `{"tag": "Found", "data": [...]}` per Arnaud's db-server portability requirement. Backed by [R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server).
- [X] T009 Extend `lib/HeaderExtractor.hs` with `getHeader :: FilePath -> NodeConfig -> SlotNo -> HeaderHash -> IO ByteString` fetching one header via `ChainDB.getBlockComponent BlockHeader` and encoding to CBOR via `cardano-binary`. Backed by [R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server) + [data-model.md Amaru bootstrap bundle headers/](./data-model.md#amaru-bootstrap-bundle-output).
- [X] T010 Create `app/header-extractor/Main.hs` with `optparse-applicative` subcommand dispatch (`tip-info`, `list-blocks`, `get-header`); each subcommand calls into the lib and prints the documented JSON / CBOR / integer to stdout; exits with rc=7 on tool errors per the CLI contract.
- [X] T011 Run T005 + T006 — both must transition from FAIL to PASS. `nix build .#checks.x86_64-linux.header-extractor` green.

**Checkpoint**: `header-extractor` is a working binary the orchestrator can shell out to. Green baseline.

---

## Phase 3: User Story 1 — Operator brings up Amaru next to a cardano-node (Priority: P1) 🎯 MVP

**Goal**: A docker image that, dropped into a compose stack alongside *any* running cardano-node (mainnet, antithesis testnet, preprod, etc.), produces the Amaru bootstrap bundle and exits 0 once the chain is era-ready for amaru's consumer. On a mainnet-mature node the wait phase is a no-op; on an antithesis cold-start it polls until two Conway epochs are on chain.

**Independent Test**: Per [spec.md User Story 1 Independent Test](./spec.md#user-story-1--an-operator-brings-up-amaru-next-to-an-existing-cardano-node-priority-p1) — a stripped-down compose file with one cardano-node + the bootstrap-producer + an Amaru service lets Amaru reach its running phase. The bats coverage in T012-T016 + T021 verifies this end-to-end against the vendored fixture.

### TDD: bats tests first ⚠️

> Each bats test exercises one exit-code class from the [11-class registry](./data-model.md#error-class-registry).

- [X] T012 [P] [US1] Write FAILING bats test in `tests/test-bootstrap-producer-config.bats`: rc=3 configuration-error coverage (missing `config.json`, malformed JSON, `epochLength` non-positive integer, no Conway entry in derivable era-history). Backed by [contracts/bootstrap-producer-cli.md exit codes](./contracts/bootstrap-producer-cli.md#exit-codes) + [data-model.md Era-readiness predicate validation](./data-model.md#era-readiness-predicate-derived).
- [X] T013 [P] [US1] Write FAILING bats test in `tests/test-bootstrap-producer-cluster.bats`: rc=1 cluster-not-ready (chain DB never appears within `AMARU_CLUSTER_READY_DEADLINE_SECONDS`). Use a 5-second deadline override + an empty mount. Backed by [R-006](./research.md#r-006-wait-and-validate-pre-flight-order) + [data-model.md state diagram step 1](./data-model.md#bootstrap-step-the-worker).
- [X] T014 [P] [US1] Write FAILING bats test in `tests/test-bootstrap-producer-chain.bats`: rc=2 chain-not-era-ready (chain DB exists but era-readiness predicate never holds within `AMARU_WAIT_DEADLINE_SECONDS`). Use a small synthesized chain DB whose tip is in a pre-Conway era + a 30-second deadline override. Backed by [R-006](./research.md#r-006-wait-and-validate-pre-flight-order) + [R-009](./research.md#r-009-wait-strategy--poll-immutable-db-tip-info) + [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection).
- [X] T015 [P] [US1] Write FAILING bats test in `tests/test-bootstrap-producer-idempotent.bats`: pre-flight detects existing complete bundle for the same network and exits 0 in under 1 second, with no wait loop entered. Backed by [FR-008](./spec.md#functional-requirements) + [R-006 short-circuit](./research.md#r-006-wait-and-validate-pre-flight-order).
- [X] T016 [P] [US1] Write FAILING bats test in `tests/test-bootstrap-producer-concurrent.bats` (Obs#4): two bootstrap-producer processes started concurrently against the same input + same output volume must NOT corrupt each other's `<bundle>.tmp/`. Implementation expectation (T019): each instance writes to a unique-suffixed temp dir (`<bundle>.tmp.<pid>.<random>/`) and the FIRST one to finish wins via `mv -T`; the others detect the now-complete bundle on their final pre-flight pass and short-circuit. Backed by [spec.md edge-case "Concurrent compose-up calls"](./spec.md#edge-cases) + [R-007](./research.md#r-007-atomic-bundle-commit).

### Orchestrator implementation

- [X] T017 [US1] Create `scripts/bootstrap-producer.sh` skeleton with the 8-step state diagram from [data-model.md](./data-model.md#bootstrap-step-the-worker). Begin with `#!/usr/bin/env bash` + `set -euo pipefail`, env-knob defaults (`AMARU_WAIT_DEADLINE_SECONDS=5400`, `AMARU_CLUSTER_READY_DEADLINE_SECONDS=300`, `AMARU_POLL_INTERVAL_SECONDS=10`), exit-code class enum, log-redirect helper writing `<bundle>/.logs/<phase>.stderr`. Wires the 8 steps as empty function calls. Make the file executable (`chmod +x`).
- [X] T018 [US1] Implement step 1 (pre-flight wait-and-validate, era-aware) in `scripts/bootstrap-producer.sh`: existing-bundle short-circuit, config validation + `epochLength` extraction + Conway-fork-slot derivation, two polling loops (cluster-ready, era-readiness predicate per [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection)) calling `header-extractor tip-info` and parsing JSON via `jq`, tooling sanity. Emit the documented `+ waiting for chain DB to appear` and `+ waiting for chain tip era-readiness — slot=N era=X conway_first=Y` lines and the satisfaction line `+ era-readiness predicate satisfied — target_slot=…`. Backed by [R-006](./research.md#r-006-wait-and-validate-pre-flight-order) + [R-009](./research.md#r-009-wait-strategy--poll-immutable-db-tip-info) + [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection) + [contracts/bootstrap-producer-cli.md stdout/stderr](./contracts/bootstrap-producer-cli.md#stdout--stderr). Run T013 + T014 + T015 — must pass.
- [X] T019 [US1] Implement steps 2-8 (snapshot pipeline + concurrency-safe commit) in `scripts/bootstrap-producer.sh`: snapshot pipeline phases, `header-extractor list-blocks + get-header` loop (rc=7), `jq` nonces composition (rc=8), three `amaru import-*` writing to *the bundle's canonical paths* `<bundle>/<network>/ledger.<network>.db/` and `<bundle>/<network>/chain.<network>.db/` per [R-005](./research.md#r-005-bundle-path-layout-carrier-between-producer-and-amaru) (Obs#3 — single canonical path everywhere), unique-suffixed temp dir (`<bundle>/<network>.tmp.$$.${RANDOM}/`) per Obs#4, atomic `mv -T <unique-tmp> <final>` (rc=10). On `mv` losing the race against another concurrent winner, *re-run pre-flight* — if the now-existing complete bundle is detected, exit 0; otherwise rc=10. Backed by [R-002](./research.md#r-002-amaru-import-flags) + [R-005](./research.md#r-005-bundle-path-layout-carrier-between-producer-and-amaru) + [R-007](./research.md#r-007-atomic-bundle-commit) + [data-model.md state diagram steps 2-8](./data-model.md#bootstrap-step-the-worker). Run T012 + T015 — pass; T014 passes against the synthesised short chain DB. The concurrent full-pipeline path is covered by T019b.
- [X] T019b [US1] Add `ledger-state-emitter` Haskell exe (sibling to `header-extractor` in `amaru-bootstrap.cabal`). Library + exe expose `emitLedgerSnapshot :: FilePath -> NodeConfig -> SlotNo -> FilePath -> IO ()`: open the chain DB, replay the ledger state at the target slot, and write a Legacy `ExtLedgerState` CBOR file using the node-10.7.1 Amaru bootstrap projection documented in [R-011](./research.md#r-011-ledger-snapshot-emitter-replaces-db-analyser--snapshot-converter). CLI: `ledger-state-emitter --db <chain-db> --config <config.json> --target-slot <SLOT> --out <file>`. `scripts/bootstrap-producer.sh` now has `phase_emit` call the new tool for the target slot and the two prior epoch slots; `db-analyser` and `snapshot-converter` are no longer runtime layers. The `bootstrap-producer-synthesized` flake check runs the synthesized chain DB through emit, convert, header extraction, nonce rewrite, and all three Amaru imports. The `bootstrap-producer-bats` flake check wires T016 and proves two concurrent real producers converge on one complete bundle. Backed by [R-011](./research.md#r-011-ledger-snapshot-emitter-replaces-db-analyser--snapshot-converter).

### Image module implementation

- [X] T020 [US1] Fill out `nix/bootstrap-producer-image.nix` to produce a runnable image: post-R-011 runtime carries `ledger-state-emitter`, `header-extractor`, `amaru`, bash/coreutils/findutils/gawk/jq, and a Nix wrapper that invokes `scripts/bootstrap-producer.sh` with Nix's bash. `db-analyser` and `snapshot-converter` are NOT in the runtime image. `nix build .#packages.x86_64-linux.bootstrap-producer-image` produces a tarball. Backed by [R-004](./research.md#r-004-image-layout).

### End-to-end live-cluster test

- [X] T021 [US1] Write `tests/test-bootstrap-producer-live.bats`: seed an era-ready `testnet_42` ChainDB with stock `db-synthesizer`, run the official `ghcr.io/intersectmbo/cardano-node:10.7.1` image against that DB, point the bootstrap-producer at the node-held ChainDB via volume mount, assert exit 0 within `AMARU_WAIT_DEADLINE_SECONDS`, assert bundle is complete on the output volume (chain.db, ledger.db, nonces.json, headers/* — minimum 4 header files per R-005). Run it — must pass. This verifies the live node-10.7.1 ChainDB mount/open contract without altering `testnet_42` genesis parameters that Amaru's importer treats as fixed. Backed by [SC-002](./spec.md#measurable-outcomes) + [Acceptance Scenario 1](./spec.md#user-scenarios--testing-mandatory).

> Note: the mainnet-mature branch of SC-002 is verified by T024 (manual quickstart) — it requires a real synced cardano-node which is impractical in CI.

**Checkpoint**: US1 fully functional. The bootstrap-producer image, given a cardano-node neighbour (live or mature), evaluates era-readiness, optionally waits, snapshots, exits 0; bats coverage exercises every exit-code class.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Image distribution, developer ergonomics, post-merge validation.

- [X] T022 Add `.github/workflows/publish-bootstrap-image.yml` per [R-008](./research.md#r-008-ci-workflow-for-image-publishing): `runs-on: nixos`, `permissions: { contents: read, packages: write }`, waits for successful CI on `main`, builds via `nix build .#packages.x86_64-linux.bootstrap-producer-image`, `docker load`, tags as `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>`, pushes. Backed by [FR-010](./spec.md#functional-requirements) + [R-003](./research.md#r-003-ghcrio-push-from-a-runs-on-nixos-self-hosted-runner) + [R-008](./research.md#r-008-ci-workflow-for-image-publishing).
- [ ] T023 [P] Add `just bootstrap <chain-db> <config-dir> <bundle-dir> <network>` recipe to `justfile` mirroring the local-mode invocation from [contracts/bootstrap-producer-cli.md](./contracts/bootstrap-producer-cli.md#invocation-local). Mirror the existing `just smoke` pattern.
- [ ] T024 [P] Run [`quickstart.md`](./quickstart.md) Scenario A (mainnet — point at any synced cardano-node) AND Scenario B (antithesis cold-start — vendored fixture) end-to-end manually, record each wall-clock total in a PR comment, verify they fall under the [SC-002 budgets](./spec.md#measurable-outcomes) (10 min mainnet, 30 min antithesis).
- [ ] T025 Compact a Status block back into `plan.md` summarising T001-T024 outcomes (per [CLAUDE.md speckit phase budgets](../../CLAUDE.md)).
- [ ] T026 Close [issue #11](https://github.com/lambdasistemi/amaru-bootstrap/issues/11) once the PR merges to main (manual, post-merge action).
- [X] T027 Add `amaru-run-bootstrap` to the Build Gate: produce the synthesized bootstrap bundle, copy it to a writable test directory, start `amaru run` with the bundle's ledger and chain stores, require the `build_ledger` startup trace, and fail on early bootstrap errors. This is the CI proof that the bundle is usable as Amaru startup state before Antithesis consumes the image.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 completion — BLOCKS US1
- **US1 (Phase 3)**: Depends on Phase 2 completion (header-extractor must work)
- **Polish (Phase 4)**: T022 depends on T021 (don't publish a broken image); T023-T025 can run after T021; T026 is post-merge.

### Within US1

- T012-T016 (failing bats tests) before T017-T019 (orchestrator) — TDD
- T018 (pre-flight era-aware wait) before T013 + T014 + T015 transition to PASS
- T019 (pipeline + concurrency-safe commit) before T012 + T015 transition to PASS; T014 transitions on T019
- T019b (ledger-state-emitter, R-011) replaces db-analyser + snapshot-converter in the runtime pipeline and wires T016 into the flake checks
- T020 (image) before T021 (live-cluster test exercises the built image)
- T021 last — gates the green PR

### Parallel Opportunities

- **Phase 1**: T002 + T003 in parallel after T001
- **Phase 2 TDD**: T005 + T006 in parallel
- **Phase 3 TDD**: T012 + T013 + T014 + T015 + T016 all in parallel (different bats files, different exit-code classes)
- **Phase 4**: T023 + T024 in parallel after T021

---

## Parallel Example: US1 TDD bats tests

```bash
# Launch the five exit-code-class bats tests in parallel:
Task: "Write tests/test-bootstrap-producer-config.bats (rc=3 configuration-error)"
Task: "Write tests/test-bootstrap-producer-cluster.bats (rc=1 cluster-not-ready)"
Task: "Write tests/test-bootstrap-producer-chain.bats (rc=2 chain-not-era-ready)"
Task: "Write tests/test-bootstrap-producer-idempotent.bats (FR-008 short-circuit)"
Task: "Write tests/test-bootstrap-producer-concurrent.bats (Obs#4 race)"
```

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 1 (Setup, T001-T004) — wiring lands in one PR commit
2. Phase 2 (Foundational, T005-T011) — header-extractor with TDD
3. Phase 3 (US1, T012-T021) — orchestrator + image + live-cluster green
4. **STOP and VALIDATE**: T021 against the fixture must be green
5. Phase 4 — publishing pipeline + ergonomics + close ticket

### Why this ordering

- Phase 2 is small but blocking — without `header-extractor`, the orchestrator's era-aware wait loop has nothing to call. It is a clean foundational unit testable in isolation.
- T020 (image module) sits inside US1 because it is the deliverable, but it has no source-level dependency on the orchestrator beyond "copy this file in"; in practice the script and the image module are jointly tested in T021.
- T022 (image publishing CI) is in Polish because publishing a broken image is worse than not publishing one — it must follow T021 going green.

---

## Notes

- Each task references the FR / contract / research-section / data-model-step it satisfies. Do not re-state design.
- Out of scope (no tasks): Antithesis SDK assertions (Phase 3); multi-snapshot batching, streaming for huge snapshots (Phase 4); compose-file landing in `cardano-foundation/cardano-node-antithesis` (separate downstream ticket on that repo, depending on this image being published); bootstrap from a *first-time* cardano-node still in initial sync (operator should let initial sync finish first).
- Commit after each task or coherent group; mark `[X]` in this file as tasks complete; keep PR description in sync.
- Local gate: this PR is docs-only-plus-implementation; the implementation pieces land in T001-T021. Run `just shellcheck` + `just bats` + `just build-gate` per task; the verdict-line `just smoke` covers the Phase 0 + 1 pipeline against the fixture and is independent of this PR's changes.
