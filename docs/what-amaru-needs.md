# What Amaru needs to bootstrap

Reverse-engineered from
[`pragma-org/amaru/docker/testnet/amaru-loader.sh`](https://github.com/pragma-org/amaru/blob/main/docker/testnet/amaru-loader.sh)
(Arnaud Bailly).

## Bundle layout

```
<bundle>/
├── chain.db/                              # amaru's chain store, prepopulated
├── ledger.db/                             # amaru's ledger store, prepopulated
├── snapshots/<slot>.cbor                  # one per epoch boundary
├── nonces.json
└── headers/header.<slot>.<hash>.cbor      # at least 4 entries
```

## Pipeline as Arnaud built it

Steps in `amaru-loader.sh`:

1. **Convert ledger states** (one per epoch already dumped by db-synthesizer fork)

   ```
   amaru convert-ledger-state \
     --network testnet_42 \
     --snapshot <slot-dir> \
     --target-dir out/snapshots
   ```

2. **Compose `nonces.json`** by copying the last snapshot's nonces file and
   patching the `tail` field with the last header hash of the previous epoch.

3. **Extract headers** via `db-server query --query list-blocks` then
   `--query "get-header <slot>.<hash>"`. Two headers each for the last and
   second-to-last snapshot — needed because the active nonce of an epoch is
   computed from the parent hash of its tail.

4. **Import** into amaru's stores:

   ```
   amaru import-ledger-state --network testnet_42 \
     --ledger-dir out/ledger.db \
     --snapshot-dir out/snapshots/

   amaru import-headers --network testnet_42 \
     --chain-dir out/chain.db

   amaru import-nonces --network testnet_42 \
     --nonces-file out/nonces.json \
     --chain-dir out/chain.db
   ```

## Where the upstream/fork divergence lives

Step 1 pre-condition is "snapshots already exist on disk". Stock
`db-synthesizer` does not emit them. Arnaud's
[`abailly/snapshot-generator` branch](https://github.com/abailly/ouroboros-consensus/tree/abailly/snapshot-generator)
adds 4 commits to wire snapshot-at-epoch-boundary writing into
`db-synthesizer`'s main loop.

## The no-fork hypothesis

Replace step (1) pre-condition with a separate `db-analyser` invocation per
epoch boundary:

```
db-analyser --db <chain-db> --store-ledger <slot-of-epoch-boundary>
```

Then `amaru convert-ledger-state` consumes the resulting on-disk file.

**Open question — to verify in Phase 0 smoke test:**
Does `db-analyser --store-ledger SLOT` write a file in the same on-disk
format that `amaru convert-ledger-state --snapshot <file>` expects?

If yes: no fork.
If no: write a small standalone `snapshot-emitter` that depends on
`ouroboros-consensus-cardano` as a *library*, not a fork. Still no fork.
