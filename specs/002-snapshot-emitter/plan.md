# Implementation Plan: Snapshot Emitter

**Branch**: `002-snapshot-emitter` | **Date**: 2026-04-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/002-snapshot-emitter/spec.md`

## Summary

A standalone Haskell executable `snapshot-emitter` that takes a V2InMemory directory snapshot (`<slot>_db-analyser/` containing `meta`, `state`, `tables/tvar`) and writes a single legacy-format CBOR file. It uses `ouroboros-consensus-cardano` 0.27.0.0 as a Cabal **library** (no fork): reads the split `state` + `tables/tvar` files, reattaches the tables via `withLedgerTables` to reconstruct an `ExtLedgerState blk ValuesMK`, then emits the legacy snapshot via `Ouroboros.Consensus.Storage.LedgerDB.Snapshots.encodeL`. Composed into the Phase 0 smoke test as one new step between dump and convert; the verdict flips from `FAIL: format mismatch` to `PASS`.

## Technical Context

**Language/Version**: Haskell GHC 9.6.7 via haskell.nix (same toolchain as the Phase 0 marker library)
**Primary Dependencies**:
- `ouroboros-consensus-cardano` (already pinned in [`cabal.project`](../../../cabal.project) at `release-ouroboros-consensus-0.27.0.0`, SHA `8e3afe10`) — provides `Ouroboros.Consensus.Storage.LedgerDB.Snapshots.{encodeL, decodeL}` and `Ouroboros.Consensus.Ledger.Extended.{encodeExtLedgerState, decodeExtLedgerState}` in `exposed-modules`
- `cardano-binary` for raw CBOR decode/encode primitives
- `bytestring`, `directory`, `filepath` from base
- existing marker `amaru-bootstrap` library — Phase 1 adds an `executable` stanza alongside it

**Storage**: filesystem only — read 2 files in, write 1 file out; no database, no state
**Testing**: hspec for unit tests (codec round-trip on synthetic states); bats integration via the existing Phase 0 smoke test (verdict flips to `PASS`)
**Target Platform**: Linux x86_64 developer workstation (same as Phase 0)
**Project Type**: tooling/CLI (single binary added to the existing repo)
**Performance Goals**: SC-002 — adds <1 minute to the 5-minute smoke-test budget; vendored fixture's snapshot is ~10 KB (state) + small tables, fits in memory
**Constraints**: zero forks (Principle I); pure Cabal-library consumption of `ouroboros-consensus-cardano`; deterministic output (SC-005)
**Scale/Scope**: ~150 lines of Haskell, ~30 lines of Cabal stanza, ~5 lines of orchestrator change

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Evidence |
|-----------|---------|----------|
| I. No forks | PASS | research.md R-001 confirms `encodeL` and `encodeExtLedgerState` are in upstream's `exposed-modules` — no patches required |
| II. Stock tools, custom orchestration | PASS | the new tool IS custom orchestration; it does not extend any stock tool. `db-synthesizer`, `db-analyser`, `amaru` remain unchanged |
| III. Reproducibility by SHA | PASS | reuses the existing `cabal.project` SRP pin; flake.lock unchanged |
| IV. Nix-first, haskell.nix | PASS | builds via existing `nix/project.nix`; new `nix/snapshot-emitter.nix` exposes the exe; CI Build Gate gains one derivation |
| V. Smallest provable step | PASS | one binary, one format conversion, one observable outcome (Phase 0 verdict flip) |

Re-check after Phase 1 design: see end of plan.

## Project Structure

### Documentation (this feature)

```text
specs/002-snapshot-emitter/
├── plan.md                  # this file
├── spec.md                  # already in flight
├── research.md              # Phase 0 output
├── data-model.md            # Phase 1 output
├── quickstart.md            # Phase 1 output
├── contracts/
│   └── snapshot-emitter-cli.md
└── checklists/
    └── requirements.md      # already in flight
```

### Source Code (repository root)

```text
amaru-bootstrap/
├── amaru-bootstrap.cabal           # gains: executable snapshot-emitter
├── lib/AmaruBootstrap.hs           # unchanged (Phase 0 marker)
├── app/snapshot-emitter/
│   ├── Main.hs                     # arg parse + dispatch
│   └── SnapshotEmitter.hs          # the conversion (read split, encodeL)
├── test/
│   └── SnapshotEmitterSpec.hs      # hspec round-trip
├── nix/
│   ├── project.nix                 # unchanged
│   ├── snapshot-emitter.nix        # NEW: extracts hsPkgs.amaru-bootstrap.components.exes.snapshot-emitter
│   ├── checks.nix                  # gain snapshot-emitter + smoke-test-integration-with-emitter
│   ├── apps.nix                    # gain nix run .#snapshot-emitter
│   └── shell.nix                   # unchanged
├── scripts/smoke-test.sh           # one block changed: insert emitter call between dump and convert
└── tests/test-smoke-integration.bats  # unchanged — its assertion (last line == PASS) becomes truthful
```

**Structure Decision**: keep one cabal package (`amaru-bootstrap`) and add an executable stanza, rather than splitting library/executable into separate Cabal packages. Rationale: at ~150 lines of code there is no shared-library payoff; the marker library and the new executable can both build off the same `cabal.project`. Splitting can happen later if a second consumer emerges.

## Open Questions Resolved

See [`research.md`](./research.md):

- **R-001**: legacy single-file encoder is `Ouroboros.Consensus.Storage.LedgerDB.Snapshots.encodeL` wrapping `encodeExtLedgerState` from `Ouroboros.Consensus.Ledger.Extended`; format is `[version, tip, chainLength, ledgerState]`
- **R-002**: amaru decodes the full `ExtLedgerState blk` (HFC telescope + header state); not a subset. So the emitter must encode the full state, not a slice
- **R-003**: V2InMemory **splits** what the legacy format had inline. The emitter must read `state` (ledger state with `EmptyMK`) AND `tables/tvar` (`LedgerTables ValuesMK`), then `withLedgerTables` merge them into `ExtLedgerState blk ValuesMK` before encoding

## Complexity Tracking

> Constitution Check passed without violations; this section intentionally empty.

## Phase 1 re-check (post-design)

After writing `research.md`, `data-model.md`, `contracts/snapshot-emitter-cli.md`, `quickstart.md`:

| Principle | Verdict | Notes |
|-----------|---------|-------|
| I. No forks | PASS | data-model identifies `state` + `tables/tvar` as plain CBOR streams — read with stock decoders |
| II. Stock tools | PASS | contract maps each FR to one library call (decodeExtLedgerState, decode tables, withLedgerTables, encodeL) |
| III. Reproducibility | PASS | no new flake inputs; `cabal.project` unchanged; same SHA pin |
| IV. Nix-first | PASS | quickstart shows only `nix run` invocations |
| V. Smallest provable step | PASS | success is testable through one assertion in the existing smoke test |

No new violations introduced. Plan ready for `/speckit.tasks`.
