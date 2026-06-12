# Tutorial: Run an Amaru Relay Bootstrap Container

This tutorial shows the current Antithesis-style integration: run the
published image as a long-lived `amaru-relay-N` service. The relay
container bootstraps itself from a paired cardano-node, then replaces the
shell wrapper with `amaru run`.

For the lower-level one-shot producer CLI, see
[Bootstrap producer](bootstrap-producer.md).

## Prerequisites

- A Compose testnet with cardano-node producers already configured.
- One state volume per cardano-node producer.
- One config volume per cardano-node producer.
- One private `/srv/amaru` state volume per Amaru relay.
- A shared startup-marker volume for the Antithesis sidecar.
- An `amaru-runtime/` directory containing `era-history.json` and
  `global-parameters.json`.
- A published image pinned by full commit SHA:
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>`.

Do not use a moving tag as the integration contract. Pick the commit SHA
that passed this repository's CI and pin that exact tag in the
downstream stack. Same-repository PRs also publish immutable preview tags
of the form:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-<pr-number>-<full-pr-head-sha>
```

## Step 1: Add Runtime Parameters

Place the custom testnet runtime files next to the Compose file:

```text
testnets/cardano_amaru_epoch360/
|-- amaru-runtime/
|   |-- era-history.json
|   `-- global-parameters.json
`-- docker-compose.yaml
```

The relay entrypoint passes these files to `amaru run` with:

```text
--era-history-file /amaru-runtime/era-history.json
--global-parameters-file /amaru-runtime/global-parameters.json
```

Keep them aligned with the genesis/config emitted by the cardano-node
configurator. For short-epoch generated networks, stale runtime files can
make Amaru compute epoch boundaries or Praos parameters differently from
cardano-node.

## Step 2: Define the Relay Service

The image default entrypoint is `bootstrap-producer`, so relay services
must override it:

```yaml
x-amaru: &amaru
  image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
  entrypoint: amaru-relay-bootstrap
  environment:
    AMARU_LOG: info
    AMARU_COLOR: never
    AMARU_NETWORK: testnet_42
    AMARU_BOOTSTRAP_RETRY_SECONDS: "5"
  restart: always

services:
  p1:
    image: ghcr.io/intersectmbo/cardano-node@sha256:<digest>
    # normal cardano-node service omitted
    volumes:
      - p1-configs:/configs:ro
      - p1-state:/state

  amaru-relay-1:
    <<: *amaru
    container_name: amaru-relay-1
    hostname: amaru-relay-1.example
    depends_on:
      p1:
        condition: service_started
    environment:
      AMARU_LOG: info
      AMARU_COLOR: never
      AMARU_NETWORK: testnet_42
      AMARU_BOOTSTRAP_RETRY_SECONDS: "5"
      RELAY_NAME: amaru-relay-1
      AMARU_PEER: p1.example:3001
    volumes:
      - p1-state:/live:ro
      - p1-configs:/cardano/config:ro
      - ./amaru-runtime:/amaru-runtime:ro
      - amaru-startup:/startup
      - a1-state:/srv/amaru

volumes:
  p1-configs:
  p1-state:
  amaru-startup:
  a1-state:
```

Repeat the relay service for each paired producer, changing
`RELAY_NAME`, `AMARU_PEER`, and the mounted state/config volumes.

## Step 3: Gate Antithesis Setup On Relay Markers

The relay writes:

```text
/startup/$RELAY_NAME.started
```

It writes that file immediately, before the bootstrap loop. The sidecar
can gate setup-complete on these markers:

```yaml
sidecar:
  image: ghcr.io/cardano-foundation/cardano-node-antithesis/sidecar:<tag>
  entrypoint: /bin/bash
  command:
    - -ec
    - |
      for relay in amaru-relay-1 amaru-relay-2; do
        while [ ! -f "/amaru-startup/$${relay}.started" ]; do
          sleep 1
        done
      done
      exec /bin/sidecar
  volumes:
    - amaru-startup:/amaru-startup:ro
```

Composer checks should still assert later Amaru progress. The startup
marker only proves that the relay container entered its contract.

## Step 4: Start The Stack

```bash
INTERNAL_NETWORK=false docker compose -f testnets/cardano_amaru_epoch360/docker-compose.yaml config
docker compose -f testnets/cardano_amaru_epoch360/docker-compose.yaml up -d
docker compose -f testnets/cardano_amaru_epoch360/docker-compose.yaml logs -f amaru-relay-1
```

Expected relay log shape:

```text
[amaru-relay-1] startup marker written: /startup/amaru-relay-1.started
[amaru-relay-1] bootstrap attempt #1: refreshing snapshot from /live
[amaru-relay-1] bootstrap attempt #1: invoking bootstrap-producer
[amaru-relay-1 bootstrap-producer] + era-readiness predicate satisfied - target_slot=...
[amaru-relay-1 bootstrap-producer] + wrote targets.json (3 epochs) + snapshots.json
[amaru-relay-1 bootstrap-producer] + amaru create-snapshots (epoch N + 2)
[amaru-relay-1 bootstrap-producer] + amaru bootstrap
[amaru-relay-1] bootstrap attempt #1: committed bundle to /srv/amaru
[amaru-relay-1] bundle already complete at /srv/amaru, skipping bootstrap loop
[amaru-relay-1] bundle ready at /srv/amaru, exec'ing amaru run
```

Transient producer exits are normal while the paired cardano-node is
still growing enough immutable history. The relay refreshes `/live` and
tries again after `AMARU_BOOTSTRAP_RETRY_SECONDS`.

## Step 5: Inspect The Relay State

After promotion, the relay's private `/srv/amaru` volume contains:

```text
/srv/amaru/
|-- .bootstrap-complete
|-- chain.testnet_42.db/
|-- ledger.testnet_42.db/
|-- snapshots/
`-- era-history.json
```

`amaru run` opens the stores directly from that directory:

```text
--ledger-dir /srv/amaru/ledger.testnet_42.db
--chain-dir /srv/amaru/chain.testnet_42.db
```

The ledger store must include `live/` and at least three numeric
historical snapshots. Nonces and the bootstrap headers (including the
header for the latest ledger snapshot) are baked into
`chain.testnet_42.db` by `amaru bootstrap`.

## Failure Diagnosis

Relay failures are usually visible in the wrapper prefix:

| Symptom | What to check |
|---------|---------------|
| `RELAY_NAME is required` | Set `RELAY_NAME` or pass it as the first positional argument. |
| `AMARU_PEER is required` | Set `AMARU_PEER` or pass it as the second positional argument. |
| `cardano-node /live not yet usable` | Check the paired state volume and whether cardano-node created `immutable`, `ledger`, `volatile`, `protocolMagicId`, and `lock`. |
| repeated `transient rc=1` | ChainDB is not ready or the snapshot copy is too early. |
| repeated `transient rc=2` | The chain has not reached the producer's era-readiness window. |
| `fatal rc=3` | Config/genesis files are missing or invalid. |
| repeated `transient rc=6` | `amaru create-snapshots` failed. Check the prefixed producer output. |
| `fatal rc=9` | `amaru bootstrap` failed. Check the prefixed producer output. |
| Amaru starts then fails VRF/nonce checks | Check `amaru-runtime/era-history.json` and `global-parameters.json` against the generated testnet. |

In relay mode, avoid `depends_on: service_completed_successfully` for
Amaru. The relay container is expected to keep running as `amaru run`;
waiting for it to complete creates a deadlock.

## Local One-Shot Producer

For development, the lower-level producer is still available:

```bash
nix run .#bootstrap-producer -- \
  /path/to/cardano-node/db \
  /path/to/cardano-node/config \
  /tmp/amaru-bundle \
  testnet_42
```

That command writes `/tmp/amaru-bundle/testnet_42` and exits. It is the
primitive used by the relay wrapper, not the recommended Antithesis
Compose shape.
