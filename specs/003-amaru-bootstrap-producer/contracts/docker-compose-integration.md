# Contract: docker-compose integration

How an operator wires the bootstrap-producer into an existing compose stack. The bootstrap-producer is a *follower* of a long-running producer node — there is no precomputed-chain step in this design.

## Minimal example

```yaml
services:
  p1:
    image: ghcr.io/intersectmbo/cardano-node:10.5.3
    volumes: [p1-state:/state, p1-configs:/configs]
    restart: always
    # the producer node forges blocks continuously; no pre-loading step

  bootstrap-producer:
    image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<sha>
    environment:
      AMARU_NETWORK: testnet_42
    volumes:
      - p1-state:/cardano/state:ro
      - p1-configs:/cardano/config:ro
      - amaru-bundle:/srv/amaru
    depends_on:
      p1:
        condition: service_started
    restart: "no"

  amaru-1:
    image: ghcr.io/pragma-org/amaru/amaru:<sha>
    volumes:
      - amaru-bundle:/srv/amaru
    environment:
      AMARU_NETWORK: testnet_42
      AMARU_PEER_ADDRESS: p1.example:3001
      AMARU_LEDGER_DIR: /srv/amaru/testnet_42/ledger.testnet_42.db
      AMARU_CHAIN_DIR:  /srv/amaru/testnet_42/chain.testnet_42.db
    command: run
    depends_on:
      bootstrap-producer:
        condition: service_completed_successfully
    restart: always
```

## The contract

1. **`bootstrap-producer.depends_on.p1.condition: service_started`** — the bootstrap-producer container can start as soon as the producer node *container* is up. The producer's chain DB does not need to exist yet (the producer creates it on its own startup); the bootstrap-producer's pre-flight loop polls for it to appear, then polls for the chain to mature.
2. **`amaru-1.depends_on.bootstrap-producer.condition: service_completed_successfully`** — Amaru does not start until the bundle is complete on the shared volume. The bootstrap-producer's exit IS the signal; there is no marker file.
3. **`bootstrap-producer.restart: "no"`** — the producer runs once per compose-up. It exits on completion or failure and does not respawn. This is what makes the `service_completed_successfully` semantic work.
4. **`bootstrap-producer.volumes`**: read-only mounts for the cluster's state and config (the producer is concurrently writing to `/cardano/state`, but the bootstrap-producer only reads the immutable, append-only portion); read-write for the bundle volume. The bundle volume is shared with all consuming amaru services.
5. **Bundle volume name** (`amaru-bundle` in the example) is the operator's choice — must match between producer and consumers.
6. **`p1.restart: always`** — the producer node is long-running. It does NOT exit. The bootstrap-producer is a *concurrent reader* of its chain DB.

## Behaviour matrix

| Scenario | Outcome |
|----------|---------|
| **Antithesis cold start** — first `docker compose up` against a Conway-genesis testnet | p1 starts forging; bootstrap-producer starts immediately, sits in pre-flight polling for ~10-20 wall-minutes until era-readiness predicate becomes true (two Conway epochs on chain), then runs the snapshot pipeline (~3-5 min), exits 0. amaru-1 starts. Total wall-clock to amaru-1 running: under 30 min under typical simulator speedup. |
| **Mainnet operator** — first `docker compose up` against a long-running cardano-node already deep into Conway | bootstrap-producer's pre-flight evaluates the era-readiness predicate against the immutable tip on its first poll, finds it already true, proceeds straight to the snapshot pipeline (~3-5 min), exits 0. amaru-1 starts. Total wall-clock to amaru-1 running: under 10 min, dominated by the snapshot pipeline. No wait phase. |
| Second `docker compose up` (bundle preserved) | bootstrap-producer's pre-flight detects existing complete bundle and exits 0 in under a second (idempotent), amaru-1 starts. Sub-second startup. |
| `docker compose restart amaru-1` (bundle exists) | bootstrap-producer is NOT re-evaluated by docker-compose (`depends_on` is first-time only). amaru-1 restarts using existing bundle. |
| Antithesis kills `amaru-1` mid-run | docker daemon respawns it (per `restart: always`). bootstrap-producer is NOT re-run. amaru-1 reads the existing bundle and rejoins. |
| Antithesis kills `bootstrap-producer` mid-pipeline | producer exits non-zero, partial `.tmp/` directory left for inspection, no `<bundle>/` is committed, amaru-1 (waiting on producer's success) never starts. Operator inspects bootstrap-producer's stderr / artefact logs. |
| Antithesis kills `bootstrap-producer` during pre-flight wait | producer exits non-zero (rc=≥64 if SIGTERM, no `.tmp/` artefacts). On compose retry, it re-enters pre-flight; if the chain is now era-ready, it proceeds. |
| Cluster never reaches Conway era-readiness (slot leader misconfigured, `p1` keeps crashing, network stuck pre-Conway) | bootstrap-producer's wait deadline fires (default 90 min wall-clock), exits with rc=2 chain-not-era-ready. amaru-1 never starts. Operator inspects the cluster, not the bootstrap-producer. |
| Two amaru consumers (`amaru-1`, `amaru-2`) | Both `depends_on: bootstrap-producer`. Single producer run, both start in parallel after the bootstrap-producer exits 0. |

## Failure observability

The operator's primary signal is `docker compose ps`:

- `bootstrap-producer  exited (0)` and `amaru-1  Up` → success
- `bootstrap-producer  Up (waiting)` and `amaru-1  Created (not started)` for >5 min → still in pre-flight; check `docker logs bootstrap-producer` for the polling output (`+ waiting for chain tip era-readiness — slot=N era=Babbage conway_first=...`). Mainnet operator should never see this state for more than a second.
- `bootstrap-producer  exited (2)` → chain-not-era-ready: cluster's chain never satisfied the era-readiness predicate; investigate `p1`'s logs, not the bootstrap-producer's
- `bootstrap-producer  exited (4)` and `amaru-1  Created (not started)` → tool-error: dump (per [exit-code table](./bootstrap-producer-cli.md#exit-codes))
- `bootstrap-producer  Up` (still running, log shows snapshot pipeline phase) → producer in flight; either succeeds or eventually fails

Inside the bundle volume, `<bundle>/.logs/*.stderr` preserves each phase's stderr for triage.

## Antithesis-specific notes

- **`condition: service_completed_successfully` is supported** by the Antithesis platform per Arnaud's existing testnet at `pragma-org/amaru/docker/testnet`. No healthcheck workaround needed.
- **`condition: service_started` is supported** — it's the default in compose v3, used widely.
- **`restart: "no"` is supported** — Antithesis schedules container starts respecting compose policies.
- **Wall-clock to two Conway epochs in Antithesis**: empirically measured at ~150× wall-clock speedup on the existing cardano-node-antithesis cluster (3-hour run produces ~398k chain-extension events). The antithesis testnet uses a Conway-genesis configuration (Conway from slot 0), so two epochs of cluster time fit comfortably in 10-20 wall-minutes; the 90-min budget gives a 4×-9× margin under fault injection.
- **Fault injection on the bootstrap-producer**: any kill of the producer leaves it in `exited (non-zero)` state; the consumer chain (amaru-*) never starts. The Antithesis test composer can use this as a positive-failure signal for "did the producer survive faults?". A separate Phase 3 ticket adds explicit SDK assertions.
