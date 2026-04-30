# Tutorial: Use the Bootstrap Producer

This tutorial is for operators and downstream integrators who already
have a cardano-node chain database and want to start Amaru from a
produced bootstrap bundle.

The producer is a one-shot worker. It waits until the node ChainDB is
usable, produces the bundle, imports it into Amaru stores, exits 0, and
lets downstream Amaru services start through normal Compose dependency
semantics.

## Prerequisites

- A Linux x86_64 host or CI runner.
- A cardano-node 10.7.1 ChainDB and matching node config directory.
- A writable bundle volume shared between `bootstrap-producer` and
  Amaru.
- A published producer image pinned by full commit SHA:
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>`.

Do not use a moving tag as the integration contract. Pick the commit SHA
that passed this repository's CI and pin that exact image in the
downstream stack. The matching `Publish bootstrap-producer image`
workflow run pushes the GHCR tag after `main` CI succeeds.

The same image tarball is also exposed as the flake package
`.#packages.x86_64-linux.bootstrap-producer-image` and uploaded by CI as
the `bootstrap-producer-image-<github-sha>` artifact. The artifact file
inside the CI run is named
`amaru-bootstrap-producer-<github-sha>.tar.gz`.

## Step 1: Wire the Producer into Compose

The image entrypoint is `bootstrap-producer`, and it requires four
arguments:

```text
bootstrap-producer <chain-db> <config-dir> <bundle-dir> <network>
```

Example service:

```yaml
services:
  cardano-node:
    image: ghcr.io/intersectmbo/cardano-node:10.7.1-amd64
    volumes:
      - node-state:/state
      - node-configs:/config:ro
    restart: always

  bootstrap-producer:
    image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
    command:
      - /cardano/state/db
      - /cardano/config
      - /srv/amaru
      - testnet_42
    environment:
      AMARU_NETWORK: testnet_42
    volumes:
      - node-state:/cardano/state
      - node-configs:/cardano/config:ro
      - amaru-bundle:/srv/amaru
    depends_on:
      cardano-node:
        condition: service_started
    restart: "no"

  amaru:
    image: ghcr.io/pragma-org/amaru/amaru:<sha>
    command:
      - run
      - --network
      - testnet_42
      - --ledger-dir
      - /srv/amaru/testnet_42/ledger.testnet_42.db
      - --chain-dir
      - /srv/amaru/testnet_42/chain.testnet_42.db
      - --peer-address
      - cardano-node:3001
    volumes:
      - amaru-bundle:/srv/amaru
    depends_on:
      bootstrap-producer:
        condition: service_completed_successfully
    restart: always

volumes:
  node-state:
  node-configs:
  amaru-bundle:
```

The first producer argument must be the actual ChainDB path inside the
container. In the example the node stores its database at `/state/db`,
the producer mounts the same volume at `/cardano/state`, and therefore
the producer receives `/cardano/state/db`.

## Step 2: Start the Stack

```bash
docker compose up -d
docker compose logs -f bootstrap-producer
```

On a mature chain, the producer should quickly report that the
era-readiness predicate is satisfied, then run the snapshot/import
pipeline:

```text
+ era-readiness predicate satisfied - target_slot=259018 era=Conway
+ ledger-state-emitter @ 86218
+ ledger-state-emitter @ 172618
+ ledger-state-emitter @ 259018
+ amaru convert-ledger-state @ 86218
+ amaru convert-ledger-state @ 172618
+ amaru convert-ledger-state @ 259018
+ header-extractor list-blocks
+ amaru import-ledger-state
+ amaru import-headers
+ amaru import-nonces
wrote /srv/amaru/testnet_42
```

On a fresh Conway testnet, the producer stays in pre-flight until the
immutable tip has at least two complete Conway epochs behind it. Amaru
services remain in `Created` state until the producer exits 0.

## Step 3: Check the Bundle

A complete bundle is written under `<bundle-dir>/<network>`:

```text
/srv/amaru/testnet_42/
|-- chain.testnet_42.db/
|-- ledger.testnet_42.db/
|-- snapshots/
|-- nonces.json
`-- headers/
```

The ledger store must include `live/` and at least three numeric
historical snapshots. The latest converted snapshot must also have an
exact matching header in `headers/header.<slot>.<hash>.cbor`; Amaru
uses that header to align the chain store to the ledger tip at startup.

## Step 4: Run Locally Without Docker

From a checkout:

```bash
nix run .#bootstrap-producer -- \
  /path/to/cardano-node/db \
  /path/to/cardano-node/config \
  /tmp/amaru-bundle \
  testnet_42
```

The local app uses the same script and tools as the Docker image.

## Failure Diagnosis

The process exit code is the first diagnostic signal:

| Code | Class | What to check |
|------|-------|---------------|
| `1` | cluster-not-ready | The ChainDB never appeared or has no immutable chunks. Check the node service and volume path. |
| `2` | chain-not-era-ready | The chain did not reach the required Conway history before the wait deadline. Check node progress. |
| `3` | configuration-error | `config.json`, genesis files, or `epochLength` are missing or invalid. |
| `5` | tool-error: emit | `ledger-state-emitter` could not replay or write the snapshot projection. |
| `6` | tool-error: convert | `amaru convert-ledger-state` rejected an emitted snapshot. |
| `7` | tool-error: extract | Header extraction failed. If the ChainDB mount is read-only, make it read-write. |
| `8` | tool-error: nonces | `nonces.json` composition failed. |
| `9` | tool-error: import | One of the Amaru imports failed. |
| `10` | output-write-error | The final atomic bundle commit failed. |

Per-phase stderr is preserved at `<bundle-dir>/.logs/*.stderr`.

## What CI Proves

The Build Gate includes `amaru-run-bootstrap`. That check produces a
bundle, copies it into a writable directory, starts `amaru run` without
a useful live peer, and requires Amaru to reach ledger startup before
the expected timeout.

This proves the produced stores are self-consistent enough for Amaru to
open its ledger and chain state. It does not prove live peer
synchronisation, nor does the synthesized fixture cover every mainnet
transaction, UTxO, script, stake, governance, or reward shape.
