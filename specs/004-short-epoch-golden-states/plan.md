# Implementation Plan: Short-Epoch Golden Ledger States

**Branch**: `test/add-short-epoch-golden-tests-for-antithesis-bootst`  
**Spec**: `specs/004-short-epoch-golden-states/spec.md`  
**Issue**: #29

## Status

**Completed**:

- Created issue #29 and moved it to WIP.
- Reproduced the local import failure with generated short-epoch states:
  `unexpected type map at position 2: expected u32`.
- Fixed the reward-update projection mismatch by emitting a completed
  zero reward update when the node ledger state carries `SNothing`.
- Fixed the short-epoch era-history mismatch by rewriting converted
  current-era history sidecars from the node genesis `epochLength`.
- Local `just build-gate` passes with the short-epoch checks included.

**Current**:

- Push the passing PR and let GitHub CI re-run the same Build Gate.

**Blockers**:

- None known locally.

## Technical Context

The existing `bootstrap-producer-synthesized` proof uses the stock
`testnet_42` epoch length. It does not sample the short-epoch cold-start
state family that the Antithesis cluster reaches quickly.

The new corpus must remain generated from pinned node 10.7.1 tooling.
The repository should not grow committed ChainDB artifacts.

## Decisions

- Generate the corpus with `db-synthesizer` inside a flake check.
- Patch only the temporary genesis copy used by the corpus.
- Keep `epochLength = 120` to match the observed short-epoch window.
- Use `securityParam = 8` and `activeSlotsCoeff = 1.0` so the generated
  chain is dense enough to expose immutable blocks in a small CI budget.
- Sample slots `9`, `129`, and `249`, matching the observed early
  bootstrap emission points.
- Project empty reward-update state as `Complete emptyRewardUpdate`
  because Amaru's CLI imports snapshots with `has_rewards=true`.
- Correct the converted open-ended current era history sidecar to the
  Shelley genesis `epochLength`; Amaru's converter currently uses the
  network default there, which is wrong for 120-slot custom testnets.
- Split conversion and import:
  - `antithesis-short-epoch-samples` proves sample generation and
    conversion.
  - `antithesis-short-epoch-golden` proves Amaru import and is the
    regression gate for the fix.

## Verification

```bash
nix build .#checks.x86_64-linux.antithesis-short-epoch-samples
nix build .#checks.x86_64-linux.antithesis-short-epoch-golden
```

After the fix, both commands pass locally. `just build-gate` also passes
with both short-epoch checks included in the gate.
