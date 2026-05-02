# Implementation Plan: Run Amaru Against the Produced Bundle in Live Test

**Branch**: `005-amaru-run-live-test` | **Date**: 2026-05-02 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from
`/code/amaru-bootstrap-005-spec/specs/005-amaru-run-live-test/spec.md`

## Summary

Extend the existing live cardano-node verifier
(`tests/test-bootstrap-producer-live.bats`) so that, after the producer
emits a bundle, the same test harness peers the **flake-pinned** amaru
binary with the *same* live cardano-node 10.7.1 container that produced
the bundle, holds the connection open for a configurable window
(default 60 s), and fails if amaru's logs contain any of the four
fatal classes called out in
[issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34):
`Invalid VRF proof`, `Consensus died`, `HeaderValidationError`,
`ledger inconsistency`. Bats output names the failure class and quotes
the matching log lines so a maintainer reading CI alone can triage.

Approach: extend the existing `@test` (one cardano-node + one producer
+ one amaru per run, per FR-007), publish the node's N2N port
`127.0.0.1::3001` so a host-side amaru can dial it, factor the
hold-and-watch logic into a new helper in
`tests/lib/bootstrap-helpers.bash`, and extend the
`live-bootstrap-producer` justfile recipe to add `amaru` to the
`nix shell` so the test environment provides the pinned binary
(FR-002).

## Technical Context

**Language/Version**: Bash 5.x (test orchestration); bats-core (existing test runner).
**Primary Dependencies**: docker-client, cardano-node 10.7.1 image, db-synthesizer (haskell.nix), `amaru` (crane via `nix/amaru.nix`), bats, jq, gnugrep, coreutils.
**Storage**: Filesystem only — `$TMP_DIR` per bats test as today; no DB.
**Testing**: bats, invoked via `just live-bootstrap-producer`. NOT a flake check (Docker-dependent — same constraint as the existing live test).
**Target Platform**: Linux + Docker daemon. Same skip predicates as today (`command -v docker / db-synthesizer / $BOOTSTRAP_PRODUCER_IMAGE`).
**Project Type**: CLI / orchestrator repo — existing single-project layout.
**Performance Goals**: Hold-open default 60 s; total wall-clock for the extended test should land under ~10 min (existing test ≈ 5–7 min on a workstation; +60 s for amaru hold).
**Constraints**: No forks of upstream amaru / cardano-node (Principle I); no host-installed amaru (FR-002); reuse existing live scaffolding (FR-007); test inherits skip semantics (FR-008).
**Scale/Scope**: One amaru ↔ one cardano-node peer pairing. Multi-peer is out of scope.

## Constitution Check

*GATE: Pass before Phase 0 research; re-checked after Phase 1 design.*

| Principle | Status | Note |
|-----------|--------|------|
| I — No forks of upstream Cardano code | PASS | Test consumes the flake-pinned `amaru` binary as-is; no patch / vendor / fork. The test detects whether the *bundle* is consumable; it does not modify amaru. |
| II — Stock tools, custom orchestration | PASS | New code is shell + bats wiring only. No new in-repo binary. The amaru runtime is the same `nix/amaru.nix` already used by `amaru-run-bootstrap`. |
| III — Reproducibility by pinning, not tags | PASS | amaru pinned via `flake.lock`; cardano-node image SHA already pinned in the existing live test (`ghcr.io/intersectmbo/cardano-node:10.7.1-amd64`). The producer image under test is whatever the operator builds / passes via `BOOTSTRAP_PRODUCER_IMAGE` (already the contract today). |
| IV — Nix-first, haskell.nix for Haskell | PASS | The test invokes binaries through `nix shell .#…` (justfile recipe). No `cabal install`, no `cargo install`, no host installs. Stays out of `Build Gate` because it needs Docker — identical posture to today's live test. |
| V — Smallest provable step | PASS | Smallest possible step that closes the issue #34 gap: one new helper, one extra hold-open block in the existing `@test`, one justfile tweak. No new fixture, no new Haskell tool, no new flake check. |

**Gates: PASS — proceed to Phase 0.** No `Complexity Tracking` entries.

## Project Structure

### Documentation (this feature)

```text
specs/005-amaru-run-live-test/
├── plan.md              # this file
├── research.md          # Phase 0: amaru run CLI shape, port publish vs. shared docker network, fatal log substrings
├── data-model.md        # Phase 1: test artefacts — bundle, log, hold-window
├── quickstart.md        # Phase 1: how to repro issue #34 locally with the extended test
├── contracts/
│   └── failure-classes.md   # Phase 1: exact log-substring contract + class labels (FR-004, FR-006)
└── tasks.md             # Phase 2: produced by /speckit.tasks
```

### Source Code (repository root)

```text
tests/
├── test-bootstrap-producer-live.bats    # extended: new @test or extra block in existing one
└── lib/
    └── bootstrap-helpers.bash           # new helpers: amaru_run_against / wait_for_node_port / scan_amaru_log

justfile                                  # recipe `live-bootstrap-producer`: add `.#…amaru` to `nix shell`

# (no nix/ changes; nix/amaru.nix already exposes the pinned binary)
```

**Structure Decision**: The change is a surgical extension of the existing live-test scaffolding. No new top-level directories, no new flake outputs, no new in-repo binaries. All edits land in `tests/`, `tests/lib/`, and the `justfile`.

## Complexity Tracking

> Not applicable — Constitution Check passes with no violations.
