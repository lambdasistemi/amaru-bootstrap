# Data Model: Amaru Bootstrap Producer

Eight entities. Same data-model discipline as Phase 0 + 1.

## Entities

### Cluster chain database (live input)

A directory on the docker volume `<producer-name>-state`, owned by the cluster's *producer node* — a long-running cardano-node container that forges blocks continuously. The bootstrap-producer container mounts this volume read-only and reads from it *while the producer continues to write*.

```
<chain-db>/
├── immutable/        chain immutable DB (append-only — safe to read concurrently)
├── volatile/         chain volatile DB (currently-being-written — bootstrap-producer does NOT touch this)
├── ledger/           ledger snapshots written by cardano-node (read by db-analyser via point-in-time copy)
└── …
```

**Validation rules** (per FR-001 + FR-011 + R-006):
- Directory exists and is readable. May not yet exist when the bootstrap-producer container starts (the producer node creates it on its own startup); pre-flight waits for it.
- `immutable/` subdirectory contains at least one chunk file (a *living* signal that the producer has started forging).
- The chain's tip slot, computed by reading the immutable DB's metadata via `header-extractor tip-slot`, is at least `2 × epochLength` (read from shelley-genesis).

**Source**: the cluster's producer node (cardano-node, long-running, `restart: always`). The bootstrap-producer mounts this volume read-only via the operator's compose configuration. There is no separate `cardano-loader` step in this design — the chain is forged organically.

### Node configuration (input)

The cluster's node `config.json` and the genesis files it references. Same shape as Phase 1.

```
<config-dir>/
├── config.json
├── byron-genesis.json
├── shelley-genesis.json
├── alonzo-genesis.json
├── conway-genesis.json
└── (optional) dijkstra-genesis.json
```

Mounted read-only from the cardano-node's compose-defined volume. Used by `db-analyser`, `snapshot-converter`, `header-extractor` for codec selection. `shelley-genesis.json` provides `epochLength`; the era-history (transitions to Allegra, Mary, Alonzo, Babbage, Conway) is derivable from the genesis files for known networks. Both feed the era-readiness predicate (below).

### Era-readiness predicate (derived)

The condition under which the bootstrap-producer is allowed to snapshot. Per [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection):

```
ready(tip) ≜ tip.era ≥ ERA_AMARU_CONSUMES
           ∧ tip.slot − 2 × epochLength ≥ ERA_AMARU_CONSUMES.firstSlot
```

`ERA_AMARU_CONSUMES = Conway` for the SHA pinned in `flake.lock`. `ERA_AMARU_CONSUMES.firstSlot` is a constant derivable from the genesis files for each known network (mainnet, preprod, preview, antithesis testnet_42).

The predicate has two operationally distinct truth-trajectories:
- **Already-true at first poll** (mainnet operator with a long-running cardano-node, mature preprod, late-life testnet) — orchestrator does not enter the wait loop; bootstrap proceeds immediately.
- **Becomes true over time** (antithesis cold start from a Conway-genesis testnet, freshly-installed mainnet relay still in initial sync) — orchestrator polls the immutable tip via `header-extractor tip-info`, exits when the predicate becomes true.

Not a stored artefact; computed at pre-flight from the configuration and re-evaluated each poll iteration. Once true, the orchestrator binds:

### Snapshot point (derived)

```
target_slot = tip.slot   (at the moment the era-readiness predicate first holds)
```

Per [R-010](./research.md#r-010-era-readiness-predicate-and-snapshot-point-selection): no safety margin is subtracted because `tip.slot` is *the immutable tip slot*, by construction past the chain's volatility horizon. The snapshot pipeline runs against this slot; `db-analyser dump --slot=$target_slot` produces a snapshot that amaru's import commands then consume.

**Validation rules**: `epochLength` must be a positive integer. Any other value is a configuration-error (rc=3). The era-history derivable from genesis must contain a Conway entry; if it doesn't (operator pointed the bootstrap step at a pre-Conway-aware config), that's also rc=3.

### Amaru bootstrap bundle (output)

Per [R-005](./research.md#r-005-bundle-path-layout-carrier-between-producer-and-amaru), under `/srv/amaru/<network>/`:

```
/srv/amaru/<network>/
├── chain.<network>.db/                  amaru chain store (populated by amaru import-headers/-nonces)
├── ledger.<network>.db/                 amaru ledger store (populated by amaru import-ledger-state)
├── nonces.json                          composed by orchestrator (snapshot's nonces, tail rewritten)
├── snapshots/<slot>.cbor                amaru convert-ledger-state output (intermediate)
├── snapshots/nonces.<slot>.json         intermediate; source for nonces.json
└── headers/header.<slot>.<hash>.cbor    multiple files; minimum 4 (per Arnaud's amaru-loader.sh — 2 for last snapshot, 2 for second-to-last for epoch-transition nonce computation)
```

**Lifecycle**: written via temp-and-rename ([R-007](./research.md#r-007-atomic-bundle-commit)). Either the entire bundle is on disk and consumable by amaru, or it isn't. No half-states.

**The success contract**: bundle complete ⇔ producer exits 0. The orchestrator's `mv -T` is the atomic commit; the exit code is the visible signal.

### Bootstrap step (the worker)

The container running [`scripts/bootstrap-producer.sh`](../../../scripts/bootstrap-producer.sh). Lifecycle:

```
                ┌──────────────────────────────────┐
                │ START                            │
                │ - input volumes mounted          │
                │ - output volume present          │
                │ - cardano-node may not yet have  │
                │   created the chain DB (race ok) │
                │ - or chain DB may be already     │
                │   mature (mainnet) — both fine   │
                └────────────────┬─────────────────┘
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 1. Pre-flight (wait+check) ║──── existing complete bundle? ─→ rc=0 (FR-008)
                  ║    - resolve config        ║──── config malformed   ─→ rc=3 configuration-error
                  ║    - poll chain DB         ║──── DB never appears   ─→ rc=1 cluster-not-ready
                  ║    - poll era-readiness    ║──── predicate never    ─→ rc=2 chain-not-era-ready
                  ║      predicate (R-010)     ║      becomes true
                  ║    - tooling on PATH       ║──── binary missing     ─→ rc=≥64 internal-error
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 2. db-analyser dump        ║──── error  ─→ rc=4 dump
                  ║    (V2InMemory @ tip)      ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 3. snapshot-converter      ║──── error  ─→ rc=5 emit
                  ║    (Mem -> Legacy)         ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 4. amaru convert-          ║──── error  ─→ rc=6 convert
                  ║      ledger-state          ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 5. header-extractor        ║──── error  ─→ rc=7 extract
                  ║    (list + get-header)     ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 6. compose nonces.json     ║──── error  ─→ rc=8 nonces
                  ║    (jq tail rewrite)       ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 7. amaru import-*          ║──── error  ─→ rc=9 import-{ledger,headers,nonces}
                  ║    (three calls chained)   ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 8. mv -T <tmp> <final>     ║──── ioerr  ─→ rc=10 commit
                  ╚══════════════┬══════════════╝
                                 │
                                 ▼
                              rc=0 success → docker-compose unblocks consumers
```

The pre-flight (step 1) is *blocking by design*: it can sit in the polling loop for tens of minutes of wall-clock time while the cluster forges enough blocks. From the orchestrator's perspective the bootstrap-producer stays in `Up` (the `service_completed_successfully` condition isn't met yet) and Amaru consumers continue to wait.

### Service dependency (orchestration)

A relationship in the operator's `docker-compose.yaml`, not a runtime entity:

```yaml
amaru-1:
  depends_on:
    bootstrap-producer:
      condition: service_completed_successfully
```

The bootstrap-producer itself depends on the *producer node* being **started**, not completed (the producer is long-running):

```yaml
bootstrap-producer:
  depends_on:
    p1:
      condition: service_started
```

The orchestrator (docker-compose / podman-compose) enforces both. The amaru container has no waiting logic. Per [Phase 0 memory](../../../.specify/memory/constitution.md), Antithesis supports both `service_completed_successfully` and `service_started` (it's what Arnaud's testnet uses).

### Container image (the deliverable)

A single docker image at `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<commit-sha>`. Layered ([R-004](./research.md#r-004-image-layout)). Self-contained: every binary, the orchestrator script, jq, bash, coreutils.

**Identity**: image tag is the commit SHA of the source revision that built it. No `:main`, no `:latest`. This is FR-010 made concrete.

**Lifecycle**: built on every push to main; pushed to ghcr.io. Old SHAs remain accessible until ghcr.io's retention policy eventually prunes them; the operator is expected to pin a specific SHA in their compose file.

## Error class registry

| rc | class | when |
|----|-------|------|
| 0 | success | bundle complete on the volume |
| 1 | cluster-not-ready | cardano-node's chain DB never appeared within wait budget |
| 2 | chain-not-era-ready | era-readiness predicate (R-010) never became true within wait budget |
| 3 | configuration-error | config.json or genesis file missing / unparseable / `epochLength` invalid / no Conway entry in era-history |
| 4 | tool-error: dump | db-analyser failed |
| 5 | tool-error: emit | snapshot-converter failed |
| 6 | tool-error: convert | amaru convert-ledger-state failed |
| 7 | tool-error: extract | header-extractor failed (including `tip-slot`) |
| 8 | tool-error: nonces | jq nonces composition failed |
| 9 | tool-error: import | amaru import-* failed (sub-class in stderr indicates which) |
| 10 | output-write-error | rename to final path failed |
| ≥64 | internal-error | bash trap (programmer error) |

## Out of scope (Phase 3+)

- Antithesis SDK assertions wired into the producer's stderr — Phase 3
- Multi-snapshot batching (one bundle covering multiple slot-points) — Phase 4
- Streaming variant for large mainnet snapshots — Phase 4
- Era support beyond CardanoBlock — Phase 4
- Live network bootstrap from a *first-time* cardano-node still in initial sync (the bootstrap step starts before the node has caught up) — out of scope; operator should let the node finish initial sync first
