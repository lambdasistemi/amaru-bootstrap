# Architecture

The repository has two layers:

- `amaru-relay-bootstrap`: the long-lived Antithesis relay entrypoint.
- `bootstrap-producer`: the one-shot producer primitive called by the
  relay wrapper and by local checks.

The critical code boundary is still the release-pinned ledger-state
format: the whole toolset (`header-extractor`, the `db-analyser` engine
that `amaru create-snapshots` drives, and the standalone
`ledger-state-emitter`) targets one cardano-node release at a time. This
branch targets `cardano-node 10.7.1`.

## Relay Runtime

```mermaid
flowchart LR
    node["paired cardano-node\n/live + config"] --> relay["amaru-relay-bootstrap"]
    runtime["/amaru-runtime\nera-history.json\nglobal-parameters.json"] --> relay
    relay --> marker["/startup/$RELAY_NAME.started"]
    marker --> sidecar["Antithesis sidecar\nsetup-complete"]

    relay --> scratch["private scratch\n/srv/amaru/.work"]
    scratch --> producer["bootstrap-producer\nretry attempts"]
    producer --> produced["scratch bundle\n&lt;scratch-out&gt;/&lt;network&gt;"]
    produced --> promote["promote complete bundle"]
    promote --> stores["/srv/amaru\nledger.*.db\nchain.*.db\nera-history.json"]
    stores --> amaru["exec amaru run"]
    runtime --> amaru
    amaru --> peer["peer cardano-node\n$AMARU_PEER"]
```

The relay writes the startup marker before bootstrap work. That lets the
Antithesis setup phase complete while the bootstrap itself continues in
the test phase. The marker is not an Amaru-sync proof; it is a container
startup contract.

There is no downstream Compose service waiting on
`service_completed_successfully` in relay mode. The relay container does
not stop after bootstrap; it `exec`s `amaru run`.

## Bootstrap Producer Pipeline

```mermaid
flowchart LR
    mount["ChainDB snapshot\nconfig"] --> preflight["pre-flight\nconfig + era readiness\nheader-extractor tip-info"]
    preflight --> blocks["preflight block list\nheader-extractor list-blocks"]
    blocks --> targets["targets.json\nsnapshots.json\nlast block of each of the\n3 completed epochs"]
    targets --> snaps["amaru create-snapshots\ndb-analyser engine\n--targets-file + --cardano-db-dir"]
    snaps --> snapdirs["snapshots/&lt;net&gt;/&lt;slot&gt;.&lt;hash&gt;/\nwith packaged bootstrap headers"]
    snapdirs --> sidecars["era-history sidecars\nhistory.&lt;slot&gt;.&lt;hash&gt;.json\n+ bundle era-history.json"]
    sidecars --> boot["amaru bootstrap\nderives nonces\nimports packaged headers"]
    boot --> stores["ledger.&lt;net&gt;.db\nchain.&lt;net&gt;.db"]
    stores --> commit["mv -T staging final\natomic commit"]
    commit --> bundle["complete bundle\n&lt;bundle&gt;/&lt;network&gt;"]
```

In standalone mode the producer writes `<bundle>/<network>`. In relay
mode it writes to scratch, and the wrapper promotes the contents of
`<scratch-out>/<network>` into `/srv/amaru` so `amaru run` can open:

```text
/srv/amaru/
|-- chain.<network>.db/
|-- ledger.<network>.db/
|-- snapshots/
`-- era-history.json
```

Nonces and bootstrap headers are baked into `chain.<network>.db` by
`amaru bootstrap`; they are no longer separate bundle artefacts. The
`snapshots/<network>/` directory keeps the materialized epoch snapshots
and their era-history sidecars for re-bootstrap; `era-history.json` at
the bundle root is the consume-time override for
`amaru run --era-history-file`.

## Live ChainDB Contract

```mermaid
flowchart LR
    writer["cardano-node\nlive writer"] --> state["state volume\nChainDB"]
    state --> imm["immutable chunks\nread by tools"]
    state --> ledger["ledger DB\ncopied but not mutated"]
    state --> vol["volatile DB\ncopied for ChainDB shape"]
    imm --> tip["header-extractor tip-info"]
    imm --> headers["header-extractor headers"]
    state -. "mounted read-only in relay\ncopied to writable scratch" .-> relay["amaru-relay-bootstrap"]
    relay --> scratch["scratch ChainDB\nopened read-write by producer tools"]
```

The one-shot `bootstrap-producer` still needs a writable ChainDB path
because node-10.7.1's consensus ImmutableDB validation path opens chunk
files through APIs that reject a read-only filesystem. The relay wrapper
therefore copies the paired cardano-node `/live` state into private
writable scratch before invoking the producer. The producer behavior is
immutable-only: readiness comes from immutable chunks, and
`amaru create-snapshots` is given an isolated `--cardano-db-dir` view in
which the immutable chunks are symlinked from the source ChainDB while
the ledger snapshots its `db-analyser` engine materializes land in
producer-owned writable directories. The producer never mutates the
source ChainDB, so concurrent producers can run against the same chain.

## Relay State Machine

```mermaid
stateDiagram-v2
    [*] --> ValidateInputs
    ValidateInputs --> MarkerWritten: RELAY_NAME + AMARU_PEER valid
    MarkerWritten --> CheckBundle
    CheckBundle --> ExecAmaru: bundle complete
    CheckBundle --> RefreshSnapshot: bundle missing
    RefreshSnapshot --> ProducerAttempt: /live copied
    RefreshSnapshot --> Sleep: /live not usable
    ProducerAttempt --> Promote: rc=0
    ProducerAttempt --> Sleep: transient rc=1/2/5/6/7/8
    ProducerAttempt --> Fatal: other rc
    Promote --> CheckBundle: committed bundle
    Promote --> Sleep: promote failed
    Sleep --> CheckBundle
    ExecAmaru --> [*]
    Fatal --> [*]
```

The retry loop belongs in the relay entrypoint, not in Compose
dependency semantics. This matters under Antithesis faults: a short,
failed producer attempt should refresh from a newer `/live` snapshot
instead of blocking the whole setup behind a one-shot service.

## Producer State Machine

```mermaid
stateDiagram-v2
    [*] --> Preflight
    Preflight --> Success: existing complete bundle (rc 0)
    Preflight --> ClusterNotReady: chain DB timeout (rc 1)
    Preflight --> ChainNotReady: era-readiness timeout (rc 2)
    Preflight --> ConfigError: config or genesis invalid (rc 3)
    Preflight --> ExtractError: chain DB unreadable (rc 7)
    Preflight --> Targets: era-readiness predicate holds

    Targets --> CreateSnapshots: targets.json + snapshots.json written
    Targets --> TargetsError: block list incomplete (rc 5)

    CreateSnapshots --> EraSidecars: 3 snapshot dirs materialized
    CreateSnapshots --> SnapshotsError: amaru create-snapshots failed (rc 6)

    EraSidecars --> Bootstrap: history sidecars + era-history.json
    EraSidecars --> SnapshotsError: sidecar write failed (rc 6)

    Bootstrap --> Commit: ledger + chain stores populated
    Bootstrap --> BootstrapError: amaru bootstrap failed (rc 9)

    Commit --> Success: mv -T staging final
    Commit --> Success: another producer won race
    Commit --> CommitError: rename failed (rc 10)
```

Any other uncaught failure exits with `64 + rc` via the internal-error
trap. The relay wrapper treats exit codes 1, 2, 5, 6, 7, and 8 as
transient and retries; 0 promotes; anything else is fatal.

## Runtime Parameters

The relay passes deployment-provided runtime JSON to `amaru run`:

```text
--era-history-file /amaru-runtime/era-history.json
--global-parameters-file /amaru-runtime/global-parameters.json
```

These files must match the custom testnet genesis/config used by the
paired cardano-node. They are separate from the
`history.<slot>.<hash>.json` sidecars the producer writes next to each
snapshot directory (consumed by `amaru bootstrap`) and from the
`era-history.json` it writes at the bundle root (the consume-time
override for `amaru run --era-history-file`). All three documents are
built from the same genesis `epochLength`.

## Node-Release Boundary

```mermaid
flowchart TB
    subgraph Pinned["Pinned cardano-node 10.7.1 dependency set"]
        chap["CHaP index state"]
        consensus["ouroboros-consensus\nrelease-3.0.1.0"]
        ledger["cardano-ledger-* versions"]
    end

    Pinned --> tools["in-repo tools\nheader-extractor\nledger-state-emitter"]
    Pinned --> analyser["db-analyser\ncreate-snapshots engine"]
    analyser --> amaru["amaru create-snapshots\n+ amaru bootstrap"]
    tools --> amaru

    other["Future node release"] -. "requires retargeting" .-> Pinned
```

Retargeting to another node release is an explicit project task. It is
not just a Cabal compile check: the ledger-state CBOR that the pinned
tools read and that Amaru imports has to match for that release.

## Ledger-State Projection (standalone emitter)

```mermaid
flowchart LR
    raw["node 10.7.1 ledger state"] --> utxo["UTxOState\ncanonical TxIn/TxOut"]
    raw --> wrapper["Shelley wrapper\npre-Peras shape"]
    raw --> pstate["Conway/Dijkstra PState\ncurrent/future/retiring pools"]
    raw --> dstate["Conway/Dijkstra DState\nlegacy delegation wrapper"]

    utxo --> out["Legacy ExtLedgerState\nfor Amaru"]
    wrapper --> out
    pstate --> out
    dstate --> out
```

The projection preserves the fields Amaru imports and omits node-side
acceleration or wrapper fields that Amaru does not consume during
bootstrap.

`ledger-state-emitter` implements this projection as an in-repo
executable. Since the producer migrated to upstream
`amaru create-snapshots` + `amaru bootstrap`, the emitter is no longer
part of the producer pipeline; it remains in the image and as the flake
app `nix run .#ledger-state-emitter` for standalone snapshot emission
and debugging against the pinned node release.

## CI Startup Proof

```mermaid
sequenceDiagram
    participant Check as amaru-run-bootstrap
    participant Producer as bootstrap-producer
    participant Bundle as Bundle
    participant Amaru as amaru run

    Check->>Producer: synthesize chain DB, produce bundle
    Producer->>Bundle: create-snapshots + bootstrap stores
    Check->>Bundle: copy to writable test directory
    Check->>Amaru: run with ledger-dir and chain-dir
    Amaru-->>Check: build_ledger trace
    Check-->>Check: timeout is expected, early bootstrap failure is not
```

The CI proof is deliberately peer-free: it does not prove live chain
synchronisation. It proves the produced stores are sufficient for Amaru
to open its ledger and chain state and enter node startup.
