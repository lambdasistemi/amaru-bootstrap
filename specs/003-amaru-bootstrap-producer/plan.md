# Implementation Plan: Amaru Bootstrap Producer

**Branch**: `003-amaru-bootstrap-producer` | **Date**: 2026-04-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/003-amaru-bootstrap-producer/spec.md`

## Summary

A docker image (`ghcr.io/lambdasistemi/amaru-bootstrap-producer:<sha>`) that **follows any cardano-node's chain DB** (mainnet operator, antithesis cluster, anything in between), waits until the *immutable tip is era-ready for amaru's consumer* (Conway, with at least two preceding Conway epochs), then runs the full bootstrap pipeline as a one-shot container: pre-flight (era-readiness predicate evaluation, polling if the chain isn't yet ready), `ledger-state-emitter` snapshot emission for the pinned cardano-node 10.7.1 ledger set, `amaru convert-ledger-state`, header extraction, nonces composition, three `amaru import-*` invocations, exit 0. On a mainnet-mature cardano-node the wait is a no-op; on an antithesis fresh cluster it's ~10-20 wall-minutes under simulator speedup. Its exit code is the synchronisation primitive — Amaru services in the same compose stack `depends_on` it via `condition: service_completed_successfully`. The bootstrap-producer itself `depends_on` the cardano-node only with `condition: service_started`. No marker file, no out-of-band signalling. Built with `nix dockerTools`, published to ghcr.io tagged by commit SHA via a new GitHub Actions workflow.

## Technical Context

**Language/Version**: Bash 5.x (orchestrator script); Haskell GHC 9.6.x (header-extractor plus ledger-state-emitter)
**Primary Dependencies**:
- Existing: `amaru` (already in [`nix/amaru.nix`](../../../nix/amaru.nix)); `db-analyser` and `snapshot-converter` remain available only for Phase 0 checks, not the producer runtime
- New: `header-extractor` — see [research.md R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server) for the design choice (writing our own tool against consensus, NOT using `pragma-org/db-server` which pins an incompatible consensus revision)
- New: `ledger-state-emitter` — see [research.md R-011](./research.md#r-011-ledger-snapshot-emitter-replaces-db-analyser--snapshot-converter) for the node-10.7.1 Amaru projection
- New: `pkgs.dockerTools.buildLayeredImage` for the container image
- New: `skopeo` or `docker push` for ghcr.io distribution

**Storage**: filesystem only — read cardano-node's chain DB, write the bundle to a docker volume. No database, no state.
**Testing**: bats integration tests covering each exit-code class (per [data-model.md error registry](./data-model.md#error-class-registry)) plus a Docker-level live node-10.7.1 ChainDB verifier. Each test is a self-contained bats file under `tests/test-bootstrap-producer-*.bats`; no dependency on artefacts from prior phases that aren't yet on `main`.
**Target Platform**: Linux x86_64; the container runs in any docker-compose environment.
**Project Type**: tooling/CLI + container image (single binary's worth of orchestration delivered as a docker image).
**Performance Goals**: End-to-end wall-clock from `docker compose up` to amaru-1 reaching running phase:
- **Mainnet / mature chain**: under 10 minutes, dominated by the snapshot pipeline (3-5 min); wait phase is a no-op (predicate satisfied at first poll)
- **Antithesis fresh cluster** (Conway-genesis): under 30 minutes under the simulator's typical 100×-150× speedup; budget dominated by the wait for two Conway epochs (~10-20 wall-min) plus the snapshot pipeline.
**Constraints**: zero forks (Principle I); pure Cabal-library / flake-input consumption; image tag = commit SHA, never `:main` (Principle III); built via Nix, never `docker build` (Principle IV).
**Scale/Scope**: bash orchestrator (incl. era-aware wait loop), Haskell header-extractor (`list-blocks`, `get-header`, `tip-info`), Haskell ledger-state-emitter, Cabal/Nix wiring, one new GitHub Actions workflow.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Evidence |
|-----------|---------|----------|
| I. No forks | PASS | Header extraction does NOT use a forked tool. We write a small consumer of `ouroboros-consensus-cardano:unstable-cardano-tools` (already pulled in for Phase 1). `db-server` from `pragma-org/db-server` was considered and rejected — it pins consensus 0.21, incompatible with our 0.27 chain-DB format. See [research.md R-001](./research.md#r-001-header-extraction-without-pragma-orgdb-server) |
| II. Stock tools, custom orchestration | PASS | Container image bundles unmodified `amaru` plus our orchestrator script and in-repo Haskell consumers of `ouroboros-consensus`/`cardano-ledger` (`header-extractor`, `ledger-state-emitter`) purely as libraries (mode (b), explicitly permitted by [constitution v1.1.0](../../.specify/memory/constitution.md)). No upstream source extended |
| III. Reproducibility by SHA | PASS | Image tag = commit SHA on every main merge; FR-010 makes this user-visible. `cabal.project` and `flake.lock` already SHA-pin everything else |
| IV. Nix-first, haskell.nix | PASS | Image built via `pkgs.dockerTools.buildLayeredImage`, never `docker build`. Header-extractor and ledger-state-emitter are executable stanzas in existing `amaru-bootstrap.cabal`. CI: `runs-on: nixos`, Build Gate adds the image-build check |
| V. Smallest provable step | PASS | Observable through one assertion: `docker compose up` on a stripped-down test stack lets the Amaru service reach its running phase |

Re-check after Phase 1 design: see end of plan.

## Project Structure

### Documentation (this feature)

```text
specs/003-amaru-bootstrap-producer/
├── plan.md                              # this file
├── spec.md                              # already in flight
├── research.md                          # Phase 0 output
├── data-model.md                        # Phase 1 output
├── quickstart.md                        # Phase 1 output
├── contracts/
│   ├── bootstrap-producer-cli.md        # the orchestrator's CLI contract
│   └── docker-compose-integration.md    # the depends_on integration contract
└── checklists/
    └── requirements.md                  # already in flight
```

### Source Code (repository root)

```text
amaru-bootstrap/
├── amaru-bootstrap.cabal                # gains: executable header-extractor
├── lib/
│   ├── AmaruBootstrap.hs                # unchanged
│   └── HeaderExtractor.hs               # NEW: ~80 lines, consensus 0.27 consumer
├── app/
│   └── header-extractor/Main.hs         # NEW: thin wrapper over HeaderExtractor.run
├── scripts/
│   ├── smoke-test.sh                    # unchanged (Phase 0 + 1 smoke)
│   └── bootstrap-producer.sh            # NEW: the container's entrypoint
├── nix/
│   ├── project.nix                      # adds header-extractor exposed module
│   ├── iog-tools.nix                    # Phase 0 tools (db-analyser, snapshot-converter, db-synthesizer)
│   ├── amaru.nix                        # unchanged
│   ├── header-extractor.nix             # NEW: extracts the new exe
│   ├── bootstrap-producer-image.nix     # NEW: dockerTools.buildLayeredImage
│   ├── checks.nix                       # gains image-build check + bats producer-pass check
│   ├── apps.nix                         # gains nix run .#bootstrap-producer (local)
│   └── shell.nix                        # unchanged
├── tests/
│   ├── test-config-error.bats                  # unchanged (Phase 0)
│   ├── test-tool-error.bats                    # unchanged
│   ├── test-smoke-integration.bats             # unchanged
│   ├── test-bootstrap-producer-config.bats     # NEW: rc=3 configuration-error
│   ├── test-bootstrap-producer-cluster.bats    # NEW: rc=1 cluster-not-ready
│   ├── test-bootstrap-producer-chain.bats      # NEW: rc=2 chain-not-era-ready
│   ├── test-bootstrap-producer-idempotent.bats # NEW: FR-008 short-circuit
│   ├── test-bootstrap-producer-concurrent.bats # NEW: Obs#4 race
│   ├── test-bootstrap-producer-live.bats       # NEW: SC-002 antithesis branch verifier
│   └── test-header-extractor-cli.bats          # NEW: CLI surface tests
└── .github/workflows/
    ├── ci.yml                           # unchanged
    └── publish-bootstrap-image.yml      # NEW: build + push image to ghcr.io
```

**Structure Decision**: extend the existing single-cabal-package layout with executable stanzas for `header-extractor` and `ledger-state-emitter`, NOT separate cabal packages. Same justification as Phase 1: these are small tools tied to the producer contract. The bootstrap-producer container image is its own Nix module; its entrypoint is a bash orchestrator (matching the smoke-test pattern) that calls into the runtime tools.

## Open Questions Resolved

See [`research.md`](./research.md):

- **R-001**: NOT use `pragma-org/db-server` — it's pinned to consensus 0.21, incompatible with chain DBs produced by our 0.27 db-synthesizer. Write our own `header-extractor` that consumes `Cardano.Tools.DBAnalyser.Block.Cardano.mkProtocolInfo` (same entry point as Phase 1's `snapshot-converter` discovery) plus a few `Ouroboros.Consensus.Storage.ChainDB` reads. CLI compatible with Arnaud's `db-server query --query list-blocks` and `--query "get-header SLOT.HASH"` so the orchestrator script is portable.
- **R-002**: `amaru import-*` flags confirmed verbatim from Arnaud's `amaru-loader.sh` against the SHA we already have in `flake.lock`. No surprises.
- **R-003**: ghcr.io push from `runs-on: nixos` uses default `GITHUB_TOKEN` with `permissions: packages: write`. No separate secret needed. Pattern: `nix build .#bootstrap-producer-image` produces a tarball; `docker load -i ./result; docker push ghcr.io/lambdasistemi/amaru-bootstrap-producer:${{ github.sha }}`. Same pattern `cardano-foundation/cardano-node-antithesis` already uses.
- **R-006 (revised)**: pre-flight is *wait-and-validate*, not a static structural check. The cardano-node may be a concurrent writer; the bootstrap-producer's pre-flight polls for the chain DB to appear, polls until the *era-readiness predicate* (R-010) becomes true against the immutable tip, and only then invokes the snapshot pipeline. Bounded by `AMARU_CLUSTER_READY_DEADLINE_SECONDS` (default 5 min) and `AMARU_WAIT_DEADLINE_SECONDS` (default 90 min). On a mainnet-mature cardano-node the predicate is true on the first iteration.
- **R-009**: wait strategy is *poll the immutable DB tip-info*. The header-extractor gains a `tip-info` subcommand returning JSON `{slot, era, blockHash}`. The orchestrator loops, evaluating the era-readiness predicate at each iteration. Reading the immutable DB while another process writes the volatile DB is safe — the immutable portion is append-only.
- **R-010 (new)**: the era-readiness predicate is `tip.era ≥ Conway ∧ tip.slot − 2 × epochLength ≥ Conway.firstSlot`. `target_slot = tip.slot` once the predicate first holds; no safety margin needed because the immutable tip is already past the volatility horizon. This same predicate handles antithesis cold-start, mainnet operator, mid-life testnets, and any future Conway-fresh testnet from the same code path.

## Complexity Tracking

> Constitution Check passed without violations; this section intentionally empty.

## Phase 1 re-check (post-design)

After writing `research.md`, `data-model.md`, `contracts/bootstrap-producer-cli.md`, `contracts/docker-compose-integration.md`, `quickstart.md`:

| Principle | Verdict | Notes |
|-----------|---------|-------|
| I. No forks | PASS | Header extractor consumes upstream as a library; no patches |
| II. Stock tools | PASS | Three pipeline steps use unmodified upstream binaries (mode (a)); the `header-extractor` step is a small library-consumer (mode (b)); the orchestrator is custom. All paths permitted by [constitution v1.1.0](../../.specify/memory/constitution.md) |
| III. Reproducibility | PASS | Image tag = commit SHA; `flake.lock` + `cabal.project` SHA-pin everything else |
| IV. Nix-first | PASS | `dockerTools.buildLayeredImage` + Nix-driven CI; no `docker build` |
| V. Smallest provable step | PASS | One assertion (Amaru service reaches running phase in compose stack) |

No new violations. Plan ready for `/speckit.tasks`.

## Status

- **Phase 1-3 (T001-T021) — landed on this branch**:
  - cabal: `library` exposes `HeaderExtractor`, `AmaruBootstrap`, and `LedgerStateEmitter`; executable stanzas expose `header-extractor` and `ledger-state-emitter`.
  - nix: `nix/header-extractor.nix` extracts both in-repo executables; `nix/bootstrap-producer-image.nix` builds a runtime image with `ledger-state-emitter`, `header-extractor`, `amaru`, bash/coreutils/findutils/gawk/jq, and the producer wrapper. `db-analyser` and `snapshot-converter` remain only for Phase 0 checks.
  - flake: checks include the producer image, unit bats, header-extractor integration, `bootstrap-producer-bats` with the T016 concurrent race, and `bootstrap-producer-synthesized` for the full real Amaru import path.
  - live verifier: `tests/test-bootstrap-producer-live.bats` seeds a stock `testnet_42` ChainDB with `db-synthesizer`, adds the node-10.7.1 DB marker, runs `ghcr.io/intersectmbo/cardano-node:10.7.1` against that DB, and runs the bootstrap-producer image while the official node has the DB open.
  - design correction from T021: the ChainDB mount is read-write, not `:ro`. The producer still consults only immutable chunks; the write permission is required because node-10.7.1 consensus validation opens immutable chunk files through APIs that reject a read-only filesystem.
  - validated locally: `nix build .#checks.x86_64-linux.ledger-state-emitter .#checks.x86_64-linux.bootstrap-producer-synthesized`, `nix build .#checks.x86_64-linux.shellcheck`, `mkdocs build --strict`, the Docker-level live verifier, and `just ci`.
  - `just ci` reached the Phase 0 smoke verdict `FAIL: format mismatch`; this is an accepted hypothesis outcome for that legacy smoke job, not a producer failure. The producer-specific Build Gate checks and live node-10.7.1 verifier passed.
