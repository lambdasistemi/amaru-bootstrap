# Historical Rationale: What Amaru Needed To Bootstrap

This page records the original bundle-shape investigation. It is useful
background, but it is not the current Antithesis runtime recipe.

The current runtime path is:

```text
cardano-node ChainDB
  -> ledger-state-emitter
  -> amaru convert-ledger-state
  -> header-extractor
  -> amaru import-*
  -> amaru run
```

`db-synthesizer` now belongs to fixtures and CI checks only.

## Original Bundle Layout

The original investigation reverse-engineered Arnaud Bailly's
[`pragma-org/amaru/docker/testnet/amaru-loader.sh`](https://github.com/pragma-org/amaru/blob/main/docker/testnet/amaru-loader.sh).
That loader expected a bundle shaped like:

```text
<bundle>/<network>/
|-- chain.<network>.db/                    # amaru chain store, prepopulated
|-- ledger.<network>.db/                   # amaru ledger store, prepopulated
|-- snapshots/<slot>.<hash>.cbor           # target plus two prior epoch boundaries
|-- snapshots/history.<slot>.<hash>.json   # testnet era history sidecar
|-- nonces.json                            # tail points to previous-epoch header hash
`-- headers/header.<slot>.<hash>.cbor      # includes the latest snapshot header
```

The latest snapshot's `<slot>.<hash>` needed an exact matching header
file. Amaru used that header to align the chain store to the ledger tip
when `amaru run` opened the produced stores.

## Pipeline As Arnaud Built It

The loader script did four things:

1. Converted ledger states that had already been dumped by the forked
   `db-synthesizer`.

   ```bash
   amaru convert-ledger-state \
     --network testnet_42 \
     --snapshot <slot-dir> \
     --target-dir out/snapshots
   ```

   For startup, Amaru needed the target epoch snapshot and the two prior
   epoch snapshots. The live ledger opened from
   `ledger.<network>.db/live`, then historical stores supplied rewards
   and leader-schedule stake distributions.

2. Composed `nonces.json` by copying the last snapshot's nonces file and
   patching `tail` with the last header hash of the previous epoch.

3. Extracted headers through `db-server query --query list-blocks` and
   `--query "get-header <slot>.<hash>"`. The header set needed the exact
   `<slot>.<hash>` named by the latest snapshot.

4. Imported into Amaru stores:

   ```bash
   amaru import-ledger-state --network testnet_42 \
     --ledger-dir out/ledger.db \
     --snapshot-dir out/snapshots/

   amaru import-headers --network testnet_42 \
     --chain-dir out/chain.db

   amaru import-nonces --network testnet_42 \
     --nonces-file out/nonces.json \
     --chain-dir out/chain.db
   ```

## Where The Fork Was

The first precondition was "snapshots already exist on disk." Stock
`db-synthesizer` did not emit them. Arnaud's
[`abailly/snapshot-generator` branch](https://github.com/abailly/ouroboros-consensus/tree/abailly/snapshot-generator)
added local changes that wrote snapshots at epoch boundaries from inside
`db-synthesizer`.

That fork was the original maintenance problem: it lagged far behind
upstream consensus and mixed fixture generation with bootstrap snapshot
extraction.

## The No-Fork Replacement

This repository replaced the forked snapshot writer with in-repo tools
that consume the stock node libraries:

```bash
ledger-state-emitter \
  --db <chain-db> \
  --config <config.json> \
  --target-slot <slot> \
  --out <legacy-ext-ledger-state.cbor>

header-extractor tip-info|list-blocks|get-header ...
```

`ledger-state-emitter` targets this repository's pinned cardano-node
10.7.1 dependency set and emits the Amaru bootstrap projection documented
in `specs/003-amaru-bootstrap-producer/research.md#r-011`.

The producer calls it three times: `target_slot`,
`target_slot - epochLength`, and `target_slot - 2 * epochLength`.
`amaru convert-ledger-state` still owns the final snapshot slicing,
history JSON, and nonce JSON formats.

For custom testnets, the producer corrects converted
`history.<slot>.<hash>.json` files before import: the open-ended current
era's `epoch_size_slots` is set to the mounted Shelley genesis
`epochLength`. That keeps short-epoch networks consistent with the
ledger snapshot epoch number that Amaru checks during import.
