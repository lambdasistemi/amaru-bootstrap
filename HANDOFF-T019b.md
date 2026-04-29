# Handoff: T019b - `ledger-state-emitter`

**Status**: implemented on branch `003-amaru-bootstrap-producer`.

T019b is no longer a design-only item. The PR now contains the
`ledger-state-emitter` library and executable, the real
`bootstrap-producer` app/image wiring, and flake checks for both the
full synthesized pipeline and the concurrent producer race.

## What changed

`ledger-state-emitter` replaces the runtime
`db-analyser --store-ledger` + `snapshot-converter` pair. It opens the
cardano-node chain DB, replays to the immutable target slot selected by
`header-extractor tip-info`, and writes a single Legacy
`ExtLedgerState` CBOR file for `amaru convert-ledger-state`.

The emitter targets the repository's pinned `cardano-node 10.7.1`
dependency set. This matters: Cardano ledger state CBOR drifts laterally
between node releases, so a successful compile against arbitrary ledger
packages is not enough to prove compatibility.

## Amaru projection

The emitted CBOR is intentionally not raw node-10.7.1 ledger CBOR. It is
the Amaru bootstrap projection of that state:

- UTxO entries are encoded canonically through `EncCBOR` for `TxIn` and
  `TxOut`, not through the consensus ledger-table `MemPack` shortcut.
- The Shelley ledger wrapper omits the node-10.7.1 Peras certificate
  field because Amaru's converter still walks the pre-Peras wrapper
  shape.
- Conway/Dijkstra `PState` is projected to the three fields Amaru
  imports: current pool params, future pool params, retirements. The
  node-side VRF-key index is omitted.
- Conway/Dijkstra `DState` is projected into Amaru's legacy delegation
  state wrapper. Balance, deposit, stake-pool delegation, and DRep
  delegation are preserved; pointer indexes and the deposits accumulator
  are placeholders because Amaru skips them during bootstrap.

## Verification

Relevant checks:

```bash
nix build .#checks.x86_64-linux.ledger-state-emitter
nix build .#checks.x86_64-linux.bootstrap-producer-synthesized
nix build .#checks.x86_64-linux.bootstrap-producer-bats
just build-gate
```

`bootstrap-producer-synthesized` runs the real producer pipeline against
the synthesized Conway-ready `testnet_42` chain DB and asserts that
`amaru convert-ledger-state`, `amaru import-ledger-state`,
`amaru import-headers`, and `amaru import-nonces` all succeed.

`bootstrap-producer-bats` now includes T016: two real producer processes
race against the same era-ready chain DB and must both exit 0 with a
single complete final bundle and no surviving temp directories.

## Specs

The contract is documented in:

- `specs/003-amaru-bootstrap-producer/research.md#r-011`
- `specs/003-amaru-bootstrap-producer/data-model.md`
- `specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md`
- `specs/003-amaru-bootstrap-producer/tasks.md`
