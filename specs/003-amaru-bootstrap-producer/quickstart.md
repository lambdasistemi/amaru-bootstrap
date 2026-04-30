# Quickstart: Amaru Bootstrap Producer

> **You are here**: Phase 2. Phase 0 + 1 validated the format pipeline as a CI smoke test against a precomputed chain DB. Phase 2 packages the same pipeline as a docker image that **follows any cardano-node's chain DB** — antithesis cluster forging from genesis, mainnet relay caught up to current tip, anything in between — and snapshots once the chain is mature enough for amaru to consume (i.e. two epochs of Conway are on chain). On a mature node the wait is a no-op; on a fresh cluster it's a few wall-minutes.

## Prerequisites

- Linux x86_64
- docker / docker-compose
- A running cardano-node container (mainnet, preprod, preview, or the antithesis testnet's producer node — any of these)
- The image at `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>` is reachable (public registry)

No nix, no cabal, no per-host Cardano toolchain.

## Scenario A — mainnet operator: bootstrap Amaru next to an existing cardano-node

You already run a cardano-node on a host. It has been syncing or running for a while; the chain tip is current. You want Amaru next to it.

```yaml
services:
  cardano-node:                   # your existing service, unchanged
    image: ghcr.io/intersectmbo/cardano-node:10.7.1
    volumes: [node-state:/state, node-configs:/configs]
    restart: always

  bootstrap-producer:
    image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
    command:
      - /cardano/state/db
      - /cardano/config
      - /srv/amaru
      - mainnet
    environment:
      AMARU_NETWORK: mainnet
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
    volumes: [amaru-bundle:/srv/amaru]
    environment:
      AMARU_NETWORK: mainnet
    command: run
    depends_on:
      bootstrap-producer:
        condition: service_completed_successfully
    restart: always
```

`docker compose up -d`. The bootstrap-producer's stdout shows:

```
+ pre-flight: detected immutable tip slot=156784921 era=Conway
+ era-readiness predicate satisfied — target_slot=156784921 era=Conway
+ ledger-state-emitter @ 156784921
+ amaru convert-ledger-state
+ header-extractor list-blocks
+ rewriting nonces.tail = <previous-epoch-header-hash>
+ amaru import-ledger-state
+ amaru import-headers
+ amaru import-nonces
wrote /srv/amaru/mainnet
```

No wait phase. Total wall-clock: ~3-5 minutes (the snapshot pipeline). Amaru starts as soon as the bootstrap-producer exits 0.

## Scenario B — antithesis cluster: bootstrap Amaru into a freshly-launched testnet

The antithesis testnet starts the producer node from a Conway-genesis configuration. The chain begins at slot 0. Amaru cannot consume the bundle until two epochs of Conway are forged.

The compose shape is identical to Scenario A; only `AMARU_NETWORK`, the
fourth producer command argument, and the input genesis differ. The
bootstrap-producer's stdout shows:

```
+ pre-flight: chain DB not yet present
+ waiting for chain DB to appear (elapsed=8s)
+ waiting for chain tip era-readiness — slot=312 era=Conway conway_first=0 (elapsed=42s)
+ waiting for chain tip era-readiness — slot=2871 era=Conway conway_first=0 (elapsed=10m12s)
+ era-readiness predicate satisfied — target_slot=172864 era=Conway
+ ledger-state-emitter @ 172864
…
wrote /srv/amaru/testnet_42
```

Wall-clock: ~10-20 wait-minutes (under the simulator's 100×-150× speedup) + ~3-5 min snapshot pipeline. Total under 30 min. Amaru starts at the end.

## Local development run (no compose, no docker)

The repo's [`scripts/bootstrap-producer.sh`](../../../scripts/bootstrap-producer.sh) is also runnable as a flake app, pointing at any cardano-node's chain DB:

```bash
git clone https://github.com/lambdasistemi/amaru-bootstrap.git
cd amaru-bootstrap
nix run .#bootstrap-producer -- \
  /path/to/cardano-node/chain-db \
  /path/to/cardano-node/config-dir \
  /tmp/amaru-bundle \
  mainnet
```

The pre-flight semantics are the same: zero wait on a mature DB, polling wait on a fresh one.

The chain DB mount is intentionally read-write. The producer only
queries immutable chunks, but node-10.7.1's consensus ImmutableDB opener
validates chunk files through APIs that fail on a read-only filesystem.

## What if it fails?

The bootstrap-producer's exit code tells you the failure class:

| Exit | Class | Diagnosis |
|------|-------|-----------|
| 1 | cluster-not-ready | cardano-node never created its chain DB. Did `cardano-node` start? Is the volume mount correct? |
| 2 | chain-not-era-ready | era-readiness predicate never became true within `AMARU_WAIT_DEADLINE_SECONDS`. On antithesis: cluster stalled before forging two Conway epochs. On mainnet: shouldn't happen — if it does, your cardano-node is *behind* Conway and probably resyncing. |
| 3 | configuration-error | config.json or genesis malformed. Fix the config volume mount. |
| 4 | reserved | unused after the emitter collapsed the dump/emit front of the pipeline |
| 5 | `ledger-state-emitter` failed | chain DB/config read, replay, or serialization failed |
| 6 | `amaru convert-ledger-state` failed | |
| 7 | `header-extractor` failed | If this happens during pre-flight, check that the chain DB volume is not mounted read-only. node-10.7.1 validates immutable chunks through APIs that require write permissions. |
| 8 | nonces composition failed | |
| 9 | `amaru import-*` failed | |
| 10 | filesystem error during atomic commit | |

Per-phase stderr is preserved at `<bundle>/.logs/<phase>.stderr` for diagnosis even after the container has exited.

## Tuning the wait deadlines

The defaults are sized for the antithesis simulator's typical 100×-150× wall-clock speedup. Adjust via env vars on the bootstrap-producer service:

| Env | Default | When to override |
|-----|---------|------------------|
| `AMARU_CLUSTER_READY_DEADLINE_SECONDS` | 300 (5 min) | A slow-cold-start cardano-node image, or cold-cache nix on the runner |
| `AMARU_WAIT_DEADLINE_SECONDS` | 5400 (90 min) | A network with realistic 20-second-per-block timing — antithesis under fault injection might need a higher budget |
| `AMARU_POLL_INTERVAL_SECONDS` | 10 | High-fault-injection runs where polling I/O contends with the cardano-node's writes |

Mainnet operators don't need to touch any of these — the wait phase exits on the first poll.

## Image pinning

The producer image is published after `main` CI succeeds:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
```

Use the full commit-SHA tag in downstream compose files. Do not consume
moving tags as the integration contract; the tested SHA is what matters.
To pick up a fix:

```yaml
services:
  bootstrap-producer:
-   image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:8e42d41ad8a3a507ba82e98bdaa520c2278ae046
+   image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:29167cb38ebda74e960a15d7263202d6f7b69c6c
```

Then `docker compose pull bootstrap-producer && docker compose up -d`.

## What this tool does NOT do

- Antithesis SDK assertions — Phase 3
- Multi-snapshot batching, streaming for huge snapshots — Phase 4
- Era support beyond Conway — when amaru's main moves to a successor era, the predicate's `ERA_AMARU_CONSUMES` constant updates; not a redesign
- Bootstrap a *first-time* cardano-node still in initial sync — let the node finish its initial sync first, then run the bootstrap-producer
