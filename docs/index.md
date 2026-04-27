# amaru-bootstrap

Bootstrap data pipeline for [Amaru](https://github.com/pragma-org/amaru) on custom Cardano testnets.

## What this project is

Amaru cannot synchronise from genesis. To run on a custom (non-`mainnet` / non-`preprod` / non-`preview`) testnet it needs a *bootstrap bundle*:

- ledger-state snapshots at epoch boundaries (CBOR)
- a `nonces.json` file with a `tail` field
- a handful of header CBORs

[`pragma-org/amaru/docker/testnet`](https://github.com/pragma-org/amaru/tree/main/docker/testnet) produces this bundle today, but it depends on a personal fork of `ouroboros-consensus` (`abailly/snapshot-generator`) that is 1300+ commits behind upstream. **That fork is the failure mode this project replaces.**

This repo's hypothesis: **the same bundle can be produced from stock IOG tools**:

1. [`db-synthesizer`](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano/app) (upstream) — fabricate a chain DB
2. [`db-analyser --store-ledger SLOT`](https://github.com/IntersectMBO/ouroboros-consensus/blob/main/ouroboros-consensus-cardano/app/DBAnalyser/Parsers.hs) (upstream) — dump a ledger snapshot
3. [`db-server`](https://github.com/pragma-org/db-server) — extract headers
4. `amaru convert-ledger-state` / `import-*` — load the bundle

If that hypothesis holds, no fork of `ouroboros-consensus` is ever needed.

## Status

Phase 0 — investigation. Smoke-testing whether `db-analyser --store-ledger` produces snapshots in the format `amaru convert-ledger-state` consumes. See the active feature spec at [`specs/001-snapshot-format-smoke/`](https://github.com/lambdasistemi/amaru-bootstrap/tree/main/specs/001-snapshot-format-smoke).

## How to read this site

- **[What Amaru needs](what-amaru-needs.md)** — reverse-engineered contract for the bootstrap bundle, drawn from Arnaud Bailly's loader scripts. Read this first if you want to understand *what* the project produces.
- **[Constitution](constitution.md)** — the five core principles that gate every design decision in this repo. Read this if you want to understand *why* the project is shaped the way it is.

## Consumers

- [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis) `testnets/cardano_amaru/` — the docker-compose stack that will consume the loader image this project produces, replacing the vendored copy of Arnaud's setup.
