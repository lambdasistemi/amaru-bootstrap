# amaru-bootstrap

Bootstrap data pipeline for [Amaru](https://github.com/pragma-org/amaru) on
custom Cardano testnets.

## Why this repo exists

Amaru cannot synchronise from genesis. To run on a custom (non-`mainnet` /
non-`preprod` / non-`preview`) testnet it needs a *bootstrap bundle*:

- ledger-state snapshots at epoch boundaries (CBOR)
- nonces JSON with a `tail` field
- a handful of header CBORs

[`pragma-org/amaru/docker/testnet`](https://github.com/pragma-org/amaru/tree/main/docker/testnet)
produces this bundle today, but it depends on a personal fork of
`ouroboros-consensus` (`abailly/snapshot-generator`) that is 1300+ commits
behind upstream. That fork is unsustainable.

This repo's hypothesis: **the same bundle can be produced from stock IOG tools**:

1. [`db-synthesizer`](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano/app)
   (upstream) — fabricate a chain DB
2. [`db-analyser --store-ledger SLOT`](https://github.com/IntersectMBO/ouroboros-consensus/blob/main/ouroboros-consensus-cardano/app/DBAnalyser/Parsers.hs)
   (upstream) — dump a ledger snapshot at each epoch boundary
3. [`db-server`](https://github.com/pragma-org/db-server) — extract headers
4. `amaru convert-ledger-state` / `import-*` — load the bundle

If that hypothesis holds, no fork of `ouroboros-consensus` is needed.

## Status

Phase 0 — investigation. Smoke-testing whether
`db-analyser --store-ledger` produces snapshots in the format
`amaru convert-ledger-state` consumes.

## Inputs / outputs (target contract)

**Inputs**

- a node `config.json` plus genesis files (Byron / Shelley / Alonzo / Conway)
- pool credentials (KES / VRF / cold) or a bulk-credentials file
- an epoch count

**Outputs**

```
out/
├── chain.db/                              # populated
├── ledger.db/                             # populated
├── snapshots/<slot>.cbor                  # one per epoch boundary
├── nonces.json                            # with `tail = <last-header-hash-of-prev-epoch>`
└── headers/header.<slot>.<hash>.cbor      # a few entries
```

## Consumers

- [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis)
  testnets/cardano_amaru — replaces the vendored loader image once this
  pipeline lands

## License

TBD — likely Apache-2.0 to match Amaru.
