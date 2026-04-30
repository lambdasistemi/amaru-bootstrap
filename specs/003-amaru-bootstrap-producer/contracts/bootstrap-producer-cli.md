# Contract: Bootstrap Producer CLI

The bootstrap-producer is delivered as a docker image. Inside, the entrypoint is [`scripts/bootstrap-producer.sh`](../../../scripts/bootstrap-producer.sh), which is also runnable on a developer workstation via `nix run .#bootstrap-producer -- <chain-db> <config-dir> <bundle-dir> <network>`.

## Invocation (image)

```yaml
services:
  bootstrap-producer:
    image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
    environment:
      AMARU_NETWORK: testnet_42
    volumes:
      - p1-state:/cardano/state
      - p1-configs:/cardano/config:ro
      - amaru-bundle:/srv/amaru
    depends_on:
      p1:
        condition: service_started
    restart: "no"
```

## Invocation (local)

```text
nix run .#bootstrap-producer -- <chain-db> <config-dir> <bundle-dir> <network>
```

## Arguments / environment

| Channel | Name | Required | Description |
|---------|------|----------|-------------|
| arg 1 / mount | chain-db | yes | cardano-node's chain DB. Mounted read-write inside the container at `/cardano/state` because the node-10.7.1 consensus ImmutableDB opener validates chunk files with write permissions. The producer logic still reads only immutable chunks. May not exist yet (cold-start) or may already be mature (mainnet operator) — both fine. |
| arg 2 / mount | config-dir | yes | node config.json + referenced genesis files. read-only at `/cardano/config`. `epochLength` is read from shelley-genesis; the era-history (Conway-fork slot in particular) is derived from the full genesis set. |
| arg 3 / mount | bundle-dir | yes | output volume. writable at `/srv/amaru` |
| arg 4 / env  | `AMARU_NETWORK` | yes | network name (e.g. `testnet_42`, `mainnet`, `preprod`); used to choose paths inside the bundle dir |
| env (optional) | `AMARU_WAIT_DEADLINE_SECONDS` | no | override the chain-not-era-ready deadline. Default `5400` (90 min). |
| env (optional) | `AMARU_CLUSTER_READY_DEADLINE_SECONDS` | no | override the cluster-not-ready deadline. Default `300` (5 min). |
| env (optional) | `AMARU_POLL_INTERVAL_SECONDS` | no | override the pre-flight poll interval. Default `10`. |

No optional positional flags. No interactive prompts.

## Exit codes

| Code | Class | Meaning |
|------|-------|---------|
| `0` | success | bundle complete and committed atomically |
| `1` | cluster-not-ready | cardano-node's chain DB never appeared (or never had a non-empty `immutable/`) within `AMARU_CLUSTER_READY_DEADLINE_SECONDS` |
| `2` | chain-not-era-ready | era-readiness predicate ([R-010](../research.md#r-010-era-readiness-predicate-and-snapshot-point-selection)) never became true within `AMARU_WAIT_DEADLINE_SECONDS` (chain hasn't reached two preceding epochs of the era amaru consumes) |
| `3` | configuration-error | config.json or referenced genesis missing/unparseable, `epochLength` not a positive integer, or no Conway entry in era-history |
| `4` | (reserved) | unused after [R-011](../research.md#r-011-ledger-snapshot-emitter-replaces-db-analyser--snapshot-converter) collapsed the snapshot-pipeline front into one step; preserved for registry stability |
| `5` | tool-error: emit | `ledger-state-emitter` failed |
| `6` | tool-error: convert | `amaru convert-ledger-state` failed |
| `7` | tool-error: extract | `header-extractor` failed (including `tip-info` failures during the polling loop after the chain DB has appeared) |
| `8` | tool-error: nonces | `jq` nonces composition failed |
| `9` | tool-error: import | one of three `amaru import-*` calls failed; sub-class in stderr |
| `10` | output-write-error | rename to final bundle path failed |
| `≥64` | internal-error | unexpected bash exception, signal-induced exit |

## Stdout / stderr

- **stdout during pre-flight**: progress lines, one per poll tick, e.g. `+ waiting for chain DB to appear (elapsed=12s)` then `+ waiting for chain tip era-readiness — slot=4567 era=Babbage conway_first=210000 (elapsed=4m32s)`. Cadence = `AMARU_POLL_INTERVAL_SECONDS`. On a mainnet-mature node the line `+ era-readiness predicate satisfied — target_slot=156784921 era=Conway` appears once and the orchestrator proceeds to the snapshot pipeline.
- **stdout during snapshot pipeline**: progress lines, one per phase (`+ ledger-state-emitter …`, `+ amaru convert-ledger-state`, `+ header-extractor …`, `+ rewriting nonces.tail …`, `+ amaru import-*`).
- **stdout final line on success**: `wrote /srv/amaru/<network>` (the bundle's absolute path).
- **stderr**: each invoked tool's stderr is captured to a per-phase log file at `<bundle>/.logs/<phase>.stderr`. The phase name + path is also echoed to stderr for operator triage. On any non-zero exit, the orchestrator surfaces the failing phase's tail (last 50 lines) on stderr.

## On-disk artefacts after every run

| Path | After success | After failure |
|------|--------------|---------------|
| `<bundle>/<network>/` | exists, complete | does not exist |
| `<bundle>/<network>.tmp/` | does not exist (renamed) | may exist with partial content |
| `<bundle>/.logs/*.stderr` | preserved (operator can inspect) | preserved (including pre-flight `wait.stderr` if a polling phase timed out) |

## Idempotency

Per [R-006](../research.md#r-006-wait-and-validate-pre-flight-order), pre-flight detects an existing complete bundle for the same `<network>` *before* entering any waiting state and exits 0 immediately. Re-running the bootstrap-producer in the same compose stack is a no-op even while the producer node is mid-startup. This is what makes `depends_on: condition: service_completed_successfully` work cleanly across docker-compose restarts.

## Wait semantics

Per [R-009](../research.md#r-009-wait-strategy--poll-immutable-db-tip-info) + [R-010](../research.md#r-010-era-readiness-predicate-and-snapshot-point-selection), the bootstrap-producer's pre-flight is blocking by design *when the chain is not yet era-ready*. On a mainnet-mature node the wait is observed-and-skipped within milliseconds and the container appears as `Up` only for the few minutes of the snapshot pipeline. On an antithesis cold-start the container appears as `Up` for the whole wait window (~10-20 wall-min under simulator speedup) plus the snapshot pipeline. The `service_completed_successfully` condition is signalled only when the bootstrap-producer's process exits 0 after the snapshot pipeline. Amaru consumers (`depends_on: condition: service_completed_successfully`) remain in `Created` state for the duration.

This is intentional — the bootstrap-producer is the *single waitable signal* for downstream consumers. Splitting it into "wait" + "snapshot" services would split the success criterion across two `depends_on` edges and complicate failure attribution.

## Determinism

Per Phase 0 SC-005, inherited via composition: same input chain-db state at the same target slot + same network -> bundle Amaru accepts identically. Internal storage details may differ, but Amaru's bootstrap behaviour is invariant.

The snapshot-point selection (R-010) is `target_slot = immutable_tip.slot at the moment era-readiness first holds`. On mainnet, where the cardano-node has been running for any non-trivial time, this is a function of the operator's local node — different operators will pick different `target_slot` values, but all of them are immutable-tips, and all of them are equally valid bootstrap points for amaru. Re-running the bootstrap step against the *same* cardano-node DB on the same machine at a later wall-clock time picks a *later* `target_slot` — that's expected, the chain has grown. Determinism in the SC-005 sense applies for runs against an unchanging input, not for runs against a chain that is still growing.

## Versioning

Image tag = the full commit SHA of the source revision. Operators in
production-facing manifests pin that exact SHA. This contract document
is versioned implicitly via git history; if the contract changes between
Phase 2 and Phase 3, the image gains a `--version` flag and a stable
migration document.
