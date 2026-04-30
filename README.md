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

This repo now produces the same kind of bundle without carrying a fork of
`ouroboros-consensus`:

1. [`db-synthesizer`](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano/app)
   (upstream) — fabricate test chain DBs for fixtures and checks
2. `ledger-state-emitter` (in this repo) — read a cardano-node 10.7.1
   chain DB and emit the Amaru bootstrap projection of the ledger state
3. `header-extractor` (in this repo) — extract the headers Amaru needs
4. `amaru convert-ledger-state` / `import-*` — load the bundle

## Status

The current `main` branch builds the producer image and verifies the
full bootstrap path. CI runs a synthesized Conway-ready chain DB through
emit, convert, header extraction, nonce composition, Amaru imports, and
an `amaru run` startup proof from the produced bundle. A Docker-level
verifier also runs the image against a `testnet_42` ChainDB held open by
the official `ghcr.io/intersectmbo/cardano-node:10.7.1-amd64` image on
the x86_64 runner.

After CI succeeds on `main`, GitHub Actions publishes the producer image
as:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
```

Downstream compose files should pin that full commit-SHA tag. The
project does not publish moving runtime tags as the integration
contract.

To select a runtime image, use the full commit SHA from the successful
`main` CI run you want to consume. The matching publish workflow pushes
that same SHA as the GHCR tag, and the Build Gate uploads
`bootstrap-producer-image-<github-sha>` for the same commit.

## Build artifacts

The producer image is intentionally available in four places:

| Surface | Name | Use |
|---------|------|-----|
| Flake package | `.#packages.x86_64-linux.bootstrap-producer-image` | Build the Docker image tarball locally. |
| Flake check | `.#checks.x86_64-linux.bootstrap-producer-image` | Prove the image still builds in CI's Build Gate. |
| GitHub Actions artifact | `bootstrap-producer-image-<github-sha>` | Download the CI-built tarball from a PR or `main` CI run. |
| GHCR image | `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>` | Runtime image for downstream Compose stacks after `main` CI passes. |

Local build:

```bash
nix build .#packages.x86_64-linux.bootstrap-producer-image \
  -o result-bootstrap-producer-image
docker load -i result-bootstrap-producer-image
```

In GitHub Actions, the uploaded artifact contains:

```text
amaru-bootstrap-producer-<github-sha>.tar.gz
```

## What this provides

- `bootstrap-producer`: a one-shot container/local app that waits until a
  cardano-node chain DB is mature enough for Amaru, writes a complete
  bootstrap bundle, then exits 0.
- `header-extractor`: an in-repo Haskell executable for `tip-info`,
  `list-blocks`, and `get-header` against a node ChainDB.
- `ledger-state-emitter`: an in-repo Haskell executable that emits the
  Amaru bootstrap projection of a node ledger state.
- Nix checks for the full synthesized producer path and the concurrent
  producer race.
- A CI-gated `amaru-run-bootstrap` proof that Amaru can open the
  produced ledger/chain stores and reach ledger startup.

The architecture, state machine, release boundary, and concurrency model
are documented with diagrams in `docs/architecture.md`.

## Tutorial

The operator tutorial is in [`docs/tutorial.md`](docs/tutorial.md). It
covers:

- using the published Docker image from Compose
- the required four producer arguments
- read-write ChainDB mount requirements
- local runs with `nix run .#bootstrap-producer`
- failure diagnosis and CI evidence

The image entrypoint is `bootstrap-producer`; it does not infer paths
from environment alone. A Compose service must pass:

```yaml
command:
  - /cardano/state/db
  - /cardano/config
  - /srv/amaru
  - testnet_42
```

## Compatibility target

This repository currently targets `cardano-node 10.7.1`. That is
deliberate: Cardano ledger-state CBOR changes across node releases, so
compiling against a random ledger package set is not enough. Retargeting
this producer to a new node release means updating `cabal.project`,
`flake.lock`, and the documented projection in
`specs/003-amaru-bootstrap-producer/research.md#r-011`.

`ledger-state-emitter` does not write raw node ledger CBOR. It writes
the Amaru bootstrap projection of the node-10.7.1 state:

- canonical UTxO entries instead of consensus `MemPack` ledger-table
  entries
- pre-Peras Shelley ledger wrapper shape for Amaru's converter
- Conway/Dijkstra pool state projected to the fields Amaru imports
- Conway/Dijkstra account state projected to Amaru's legacy delegation
  wrapper

## Inputs / outputs

**Inputs**

- a live or mature cardano-node chain DB, mounted read-write into the
  producer container
- a node config directory containing `config.json` and the genesis files
- a target network name, for example `testnet_42` or `mainnet`

The read-write ChainDB mount is an API requirement of node 10.7.1's
consensus ImmutableDB validation path. The bootstrap-producer still
consults only immutable chunks; it does not use volatile DB state as a
readiness source. `ledger-state-emitter` replays with an in-memory
LedgerDB backend and deliberately does not flush into the node-owned
LedgerDB, so it does not prune or mutate snapshots while cardano-node is
running.

**Outputs**

```
<bundle>/<network>/
├── chain.<network>.db/                    # populated by amaru import-headers/import-nonces
├── ledger.<network>.db/                   # populated by amaru import-ledger-state
├── snapshots/<slot>.<hash>.cbor           # target plus two prior epoch snapshots
├── nonces.json                            # tail rewritten to previous-epoch header hash
└── headers/header.<slot>.<hash>.cbor      # headers needed by Amaru
```

The latest snapshot's `<slot>.<hash>` must have a matching
`headers/header.<slot>.<hash>.cbor`; Amaru uses that exact header when
aligning its chain store to the ledger tip at startup.

## Local verification

```bash
just ci
```

`just ci` mirrors the GitHub workflow: it runs the Build Gate, runs the
Phase 0 smoke verdict and accepts either `PASS` or the expected
`FAIL: format mismatch` verdict, then runs the Docker-level live
bootstrap-producer verifier. The pure producer-specific end-to-end check
is `.#checks.x86_64-linux.bootstrap-producer-synthesized`; the startup
proof is `.#checks.x86_64-linux.amaru-run-bootstrap`.

These checks prove bundle production, Amaru import, and Amaru startup
alignment. They are not a full mainnet ledger-content coverage suite for
every possible transaction, UTxO, script, stake, governance, or reward
shape.

To run the producer locally against a ChainDB:

```bash
nix run .#bootstrap-producer -- \
  /path/to/cardano-node/chain-db \
  /path/to/cardano-node/config-dir \
  /tmp/amaru-bundle \
  testnet_42
```

To run the Docker-level live verifier against the official node 10.7.1
amd64 image:

```bash
just live-bootstrap-producer
```

## Consumers

- [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis)
  testnets/cardano_amaru — consumes the commit-SHA-tagged producer image
  in the follow-up integration ticket

## License

Apache-2.0. See [`LICENSE`](LICENSE).
