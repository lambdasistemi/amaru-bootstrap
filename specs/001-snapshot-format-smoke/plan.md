# Implementation Plan: Snapshot Format Smoke Test

**Branch**: `001-snapshot-format-smoke` | **Date**: 2026-04-27 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/001-snapshot-format-smoke/spec.md`

## Status (2026-04-27)

**Phases 1–3 complete (T001–T024).** All 24 tasks have landed on branch `001-snapshot-format-smoke` in [PR #8](https://github.com/lambdasistemi/amaru-bootstrap/pull/8).

- Phase 1: flake foundation (`flake.nix` + 6 `nix/*` modules) + vendored fixture; `nix flake show` resolves `amaru-0.1.2`, `db-synthesizer-0.25.1.0`, `db-analyser-0.25.1.0`
- Phase 2: `scripts/smoke-test.sh` implements the data-model state transitions; 15/15 bats tests green in the Nix sandbox; flake exposes `nix run .#smoke-test` and three flake checks (`shellcheck`, `smoke-test-bats`, `smoke-test-integration`)
- Phase 3: real `Build Gate` workflow + `Smoke Test (Phase 0 verdict)` job replacing the stub; verdict + report path emitted to `$GITHUB_STEP_SUMMARY`, `smoke-out/` uploaded as a 30-day artefact
- Phase 4 (T024): `justfile` mirroring CI

**Current**: T025 (manual quickstart wall-clock validation against [SC-005](./spec.md#measurable-outcomes)) and T026 (close issue [#1](https://github.com/lambdasistemi/amaru-bootstrap/issues/1)) — both gated on the GitHub `Smoke Test` job recording the verdict.

**Blockers**: none. Verdict will materialise on the next CI run after PR #8's first push containing the real workflow.

## Summary

Build a single-command smoke test (`nix run .#smoke-test -- <input-bundle> <out-dir>`) that synthesises one epoch of Cardano chain history with stock `db-synthesizer`, dumps a ledger snapshot at the epoch boundary with stock `db-analyser --store-ledger`, feeds the snapshot to `amaru convert-ledger-state`, and emits one of four verdicts. The deliverable is the verdict; the deliverable validates whether the rest of the project rests on a viable foundation.

## Technical Context

**Language/Version**: Bash 5.x (orchestrator); Haskell GHC 9.6.x via haskell.nix (IOG tools); Rust 1.97 via crane (Amaru)
**Primary Dependencies**:
- [`IntersectMBO/ouroboros-consensus`](https://github.com/IntersectMBO/ouroboros-consensus) — `db-synthesizer`, `db-analyser` (built via haskell.nix + CHaP, pinned by SHA in `cabal.project` SRP entries with nix32 `--sha256`)
- [`pragma-org/amaru`](https://github.com/pragma-org/amaru) — `amaru` binary (consumed as non-flake input, built via crane)
- [`input-output-hk/haskell.nix`](https://github.com/input-output-hk/haskell.nix) + IOG cache (`hydra.iohk.io`)
- [`ipetkov/crane`](https://github.com/ipetkov/crane) for the Rust workspace
- nixpkgs (follows haskellNix's nixpkgs-unstable)

**Storage**: filesystem only — chain DB and ledger snapshots are on-disk artefacts under `<out-dir>`; no database
**Testing**: smoke test IS the test; flake `checks` run shellcheck on the orchestrator and verify Nix builds for every binary the orchestrator invokes
**Target Platform**: Linux x86_64 developer workstation (Phase 0); macOS aarch64 a non-goal at this stage
**Project Type**: tooling/CLI (single repo, single deliverable command)
**Performance Goals**: PASS run under five minutes wall-clock on a developer workstation (SC-005)
**Constraints**: zero forks of any IOG repo (Principle I); every dependency pinned by SHA, not tag (Principle III)
**Scale/Scope**: ~200-line bash orchestrator, ~150-line `nix/` directory, one fixture bundle (~1 MB)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Evidence |
|-----------|---------|----------|
| I. No forks of upstream Cardano code | PASS | Plan consumes `IntersectMBO/ouroboros-consensus` exclusively as a `source-repository-package` of upstream releases (no patches in `cabal.project`); `pragma-org/amaru` consumed as a non-flake input at SHA, no patches |
| II. Stock tools, custom orchestration | PASS | Orchestrator (bash) wraps three stock binaries (`db-synthesizer`, `db-analyser`, `amaru`); no extension of any tool |
| III. Reproducibility by SHA | PASS | All `flake.lock` entries SHA-pinned; `cabal.project` uses `index-state` with timestamp + `--sha256` (nix32) on every SRP; fixture bundle records source SHA in `PROVENANCE.md` |
| IV. Nix-first, haskell.nix for Haskell | PASS | `flake.nix` thin; real wiring in `nix/{project,iog-tools,amaru,checks,apps,shell}.nix`; CI uses `nix build .#checks.<system>.<name>` and `nix run .#smoke-test`, never `nix develop -c` |
| V. Smallest provable step | PASS | One hypothesis (snapshot format compatibility), one user story, one verdict; everything else explicitly out of scope |

Re-check after Phase 1 design: see end of plan.

## Project Structure

### Documentation (this feature)

```text
specs/001-snapshot-format-smoke/
├── plan.md                          # this file
├── spec.md                          # already merged
├── research.md                      # Phase 0 output
├── data-model.md                    # Phase 1 output
├── quickstart.md                    # Phase 1 output
├── contracts/
│   └── smoke-test-cli.md            # CLI contract for the orchestrator
├── checklists/
│   └── requirements.md              # already merged
└── fixtures/
    ├── PROVENANCE.md                # source SHA + license note for the bundle
    └── p1-config/                   # vendored from pragma-org/amaru@<SHA>/docker/testnet/p1-config
        ├── configs/configs/*.json
        └── configs/keys/*           # devnet-only test keys, magic 42
```

### Source Code (repository root)

```text
amaru-bootstrap/
├── flake.nix                        # thin entry point only
├── flake.lock
├── cabal.project                    # consumes IntersectMBO/ouroboros-consensus via SRP
├── nix/
│   ├── project.nix                  # haskell.nix cabalProject'
│   ├── iog-tools.nix                # exports db-synthesizer + db-analyser executables
│   ├── amaru.nix                    # crane wrapper for amaru
│   ├── checks.nix                   # flake checks (binary builds + shellcheck on smoke-test.sh)
│   ├── apps.nix                     # `smoke-test`, `amaru`, `db-synthesizer`, `db-analyser`
│   └── shell.nix                    # dev shell exposing all of the above + just/jq
├── scripts/
│   └── smoke-test.sh                # the orchestrator
├── specs/                           # speckit artefacts
└── docs/                            # what-amaru-needs.md (already merged)
```

**Structure Decision**: single-repo "tool composition" layout. The orchestrator is bash, not Haskell or Rust, because the logic is sequential subprocess calls plus verdict emission — adding a compiled language for that is overhead with no payoff at Phase 0. If Phase 1 needs richer logic (epoch-boundary detection from genesis arithmetic, parallelism, structured failure typing) we revisit; that revisit is Phase 1's problem.

## Open Question Resolved

**Where does the smoke test get its input bundle?**

**Decision**: vendor a minimal bundle into `specs/001-snapshot-format-smoke/fixtures/p1-config/` (option (a) from the plan request). Sourced from [`pragma-org/amaru/docker/testnet/p1-config`](https://github.com/pragma-org/amaru/tree/main/docker/testnet/p1-config) at a recorded SHA in `fixtures/PROVENANCE.md`.

**Rationale**: SC-005 requires PASS in under five minutes on a developer workstation; SC-001 requires the operator to learn the verdict by running one command. An external dependency (option (b)) breaks both: the operator must hunt down or generate keys before running, and "less than five minutes" includes that hunt. The keys are devnet-only (magic 42) and already public on GitHub, so no credential exposure. Mirrors the same pattern Arnaud uses in `pragma-org/amaru` itself.

**Alternative rejected**: option (b) (operator-supplied bundle) is preserved for Phase 1, where the orchestrator generalises and accepts arbitrary bundles. Phase 0 wants zero friction.

## Complexity Tracking

> Constitution Check passed without violations; this section intentionally empty.

## Phase 1 re-check (post-design)

After writing `research.md`, `data-model.md`, `contracts/smoke-test-cli.md`, `quickstart.md`:

| Principle | Verdict | Notes |
|-----------|---------|-------|
| I. No forks | PASS | research confirms `db-analyser --store-ledger` exists upstream — no need to even consider patching |
| II. Stock tools | PASS | contract maps each FR to one stock binary |
| III. Reproducibility | PASS | data-model treats fixture bundle as data, not as state — provenance file makes the source SHA discoverable |
| IV. Nix-first | PASS | quickstart shows only `nix run` invocations, no manual cabal/cargo commands |
| V. Smallest provable step | PASS | data-model has four entities and one verdict — minimum to express the contract |

No new violations introduced by design phase. Plan ready for `/speckit.tasks`.
