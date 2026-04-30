# amaru-bootstrap

Bootstrap data pipeline for [Amaru](https://github.com/pragma-org/amaru) on custom Cardano testnets.

## What this project is

Amaru cannot synchronise from genesis. To run on a custom (non-`mainnet` / non-`preprod` / non-`preview`) testnet it needs a *bootstrap bundle*:

- ledger-state snapshots at epoch boundaries (CBOR)
- a `nonces.json` file with a `tail` field
- a handful of header CBORs

[`pragma-org/amaru/docker/testnet`](https://github.com/pragma-org/amaru/tree/main/docker/testnet) produces this bundle today, but it depends on a personal fork of `ouroboros-consensus` (`abailly/snapshot-generator`) that is 1300+ commits behind upstream. **That fork is the failure mode this project replaces.**

This repo now produces the same kind of bundle without carrying a fork of `ouroboros-consensus`:

1. [`db-synthesizer`](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano/app) (upstream) — fabricate test chain DBs for fixtures and checks
2. `ledger-state-emitter` (in this repo) — read a cardano-node 10.7.1 chain DB and emit the Amaru bootstrap projection of the ledger state
3. `header-extractor` (in this repo) — extract the headers Amaru needs
4. `amaru convert-ledger-state` / `import-*` — load the bundle

## Status

The current `main` branch contains the bootstrap-producer
implementation. The active spec is
[`specs/003-amaru-bootstrap-producer/`](https://github.com/lambdasistemi/amaru-bootstrap/tree/main/specs/003-amaru-bootstrap-producer);
the flake checks build the producer image and run a synthesized
Conway-ready chain DB through emit, convert, header extraction, nonce
composition, Amaru imports, and an `amaru run` startup proof. CI also
runs a Docker-level live verifier against a `testnet_42` ChainDB held
open by `ghcr.io/intersectmbo/cardano-node:10.7.1-amd64`.

## Current implementation

The producer is a one-shot container and local flake app. It waits until
the immutable tip is in Conway with enough history for Amaru, emits a
node-10.7.1-compatible three-snapshot ledger window, converts it with
Amaru, extracts headers, rewrites `nonces.json`, imports all three
artifact classes into Amaru stores, and atomically commits the completed
bundle.

The current compatibility target is `cardano-node 10.7.1`. The
`ledger-state-emitter` output is a release-specific Amaru bootstrap
projection, not arbitrary raw node ledger CBOR.

The producer's ChainDB access is immutable-only by behavior, but the
node-10.7.1 consensus ImmutableDB opener requires a writable filesystem
while validating chunk files. Compose integrations therefore mount the
node state volume read-write and keep the config volume read-only. The
ledger replay uses an in-memory LedgerDB backend and does not flush into
the node-owned LedgerDB.

## How to read this site

- **[Tutorial](tutorial.md)** - start here if you want to wire the
  producer into a Compose stack or run it locally against a ChainDB.
- **[What Amaru needs](what-amaru-needs.md)** — reverse-engineered contract for the bootstrap bundle, drawn from Arnaud Bailly's loader scripts. Read this first if you want to understand *what* the project produces.
- **[Architecture](architecture.md)** — diagrams for the runtime data flow, state machine, node-release boundary, ledger projection, and concurrency model.
- **[Bootstrap producer](bootstrap-producer.md)** — current producer pipeline, node-release target, and verification commands.
- **[Constitution](constitution.md)** — the five core principles that gate every design decision in this repo. Read this if you want to understand *why* the project is shaped the way it is.

## Consumers

- [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis) `testnets/cardano_amaru/` - the downstream docker-compose stack tracked by the follow-up integration issue.
