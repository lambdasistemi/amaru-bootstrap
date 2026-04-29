# Bootstrap Producer

`bootstrap-producer` is the Phase 2 runtime deliverable. It is exposed
both as a Docker image and as a local flake app:

```bash
nix run .#bootstrap-producer -- \
  <chain-db> \
  <config-dir> \
  <bundle-dir> \
  <network>
```

## Pipeline

The producer runs once and exits. Its exit code is the synchronization
signal for downstream Amaru services.

1. Check whether `<bundle-dir>/<network>` is already complete. If so,
   exit 0.
2. Validate the node config and wait for the chain DB to appear.
3. Poll `header-extractor tip-info` until the immutable tip is in
   Conway and at least two Conway epochs are available.
4. Run `ledger-state-emitter` at the selected target slot.
5. Run `amaru convert-ledger-state`.
6. Run `header-extractor list-blocks` and `get-header` to collect the
   headers Amaru needs.
7. Rewrite `nonces.json` so `tail` points at the previous-epoch header
   hash.
8. Run `amaru import-ledger-state`, `amaru import-headers`, and
   `amaru import-nonces`.
9. Atomically rename the unique temp directory into the final bundle
   path.

The final layout is:

```text
<bundle-dir>/<network>/
├── chain.<network>.db/
├── ledger.<network>.db/
├── snapshots/
├── nonces.json
└── headers/
```

## Node-Release Target

This implementation targets `cardano-node 10.7.1`. The repository pins
that release through `cabal.project`, CHaP index states, the
`ouroboros-consensus` source-repository-package, and `flake.lock`.

This matters because Cardano ledger-state CBOR drifts between node
releases. The producer should be retargeted deliberately for each node
release instead of treated as a generic ledger-state serializer.

## Ledger-State Projection

`ledger-state-emitter` writes the Amaru bootstrap projection of the
node-10.7.1 ledger state:

- UTxO entries are canonical `EncCBOR` entries, not consensus
  ledger-table `MemPack` bytes.
- The Shelley ledger wrapper is written in the pre-Peras shape that
  Amaru's converter walks.
- Conway/Dijkstra pool state is projected to the current pool params,
  future pool params, and retirements that Amaru imports.
- Conway/Dijkstra account state is projected into Amaru's legacy
  delegation-state wrapper while preserving rewards, deposits,
  stake-pool delegation, and DRep delegation.

The detailed contract is in
`specs/003-amaru-bootstrap-producer/research.md#r-011`.

## Verification

Local CI:

```bash
just ci
```

Producer-specific checks:

```bash
nix build .#checks.x86_64-linux.bootstrap-producer-synthesized
nix build .#checks.x86_64-linux.bootstrap-producer-bats
nix build .#checks.x86_64-linux.bootstrap-producer-image
```

`bootstrap-producer-synthesized` runs the real producer pipeline against
a synthesized Conway-ready `testnet_42` chain DB and verifies that Amaru
accepts the resulting ledger state, headers, and nonces.
