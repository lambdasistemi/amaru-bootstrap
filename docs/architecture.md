# Architecture

The repository has two layers:

- `amaru-relay-bootstrap`: the long-lived Antithesis relay entrypoint.
- `bootstrap-producer`: the one-shot producer primitive called by the
  relay wrapper and by local checks.

The critical code boundary is still release-pinned ledger projection:
`ledger-state-emitter` targets one cardano-node release at a time. This
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
    producer --> produced["scratch bundle\n<scratch-out>/<network>"]
    produced --> promote["promote complete bundle"]
    promote --> stores["/srv/amaru\nledger.*.db\nchain.*.db\nnonces.json"]
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
    mount["ChainDB snapshot\nconfig"] --> preflight["pre-flight\nconfig + era readiness"]
    preflight --> emitter["ledger-state-emitter x3\nnode-10.7.1 projection"]
    emitter --> legacy["Legacy ExtLedgerState CBOR\nlatest + two prior epochs"]
    legacy --> convert["amaru convert-ledger-state x3"]
    convert --> snapshots["snapshot CBOR\nhistory JSON\nnonces JSON"]

    mount --> headers["header-extractor\nlist-blocks/get-header"]
    headers --> headerFiles["header.*.cbor files"]

    snapshots --> compose["nonce tail rewrite"]
    headerFiles --> compose
    compose --> imports["amaru import-ledger-state\namaru import-headers\namaru import-nonces"]
    imports --> bundle["complete bundle\n<bundle>/<network>"]
```

In standalone mode the producer writes `<bundle>/<network>`. In relay
mode it writes to scratch, and the wrapper promotes the contents of
`<scratch-out>/<network>` into `/srv/amaru` so `amaru run` can open:

```text
/srv/amaru/
|-- chain.<network>.db/
|-- ledger.<network>.db/
|-- snapshots/
|-- nonces.json
`-- headers/
```

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
immutable-only: readiness comes from immutable chunks, and the ledger
replay uses an in-memory LedgerDB backend rather than flushing into the
node-owned LedgerDB.

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
    Preflight --> Success: existing complete bundle
    Preflight --> ClusterNotReady: chain DB timeout
    Preflight --> ChainNotReady: era-readiness timeout
    Preflight --> Emit: ready immutable tip

    Emit --> Convert: Legacy CBOR written
    Emit --> EmitError: emitter failed

    Convert --> ExtractHeaders: snapshot converted
    Convert --> ConvertError: amaru convert failed

    ExtractHeaders --> ComposeNonces: headers written
    ExtractHeaders --> ExtractError: header extraction failed

    ComposeNonces --> Import: nonces.json written
    ComposeNonces --> NonceError: nonce rewrite failed

    Import --> Commit: Amaru stores populated
    Import --> ImportError: amaru import failed

    Commit --> Success: mv -T temp final
    Commit --> Success: another producer won race
    Commit --> CommitError: final bundle incomplete
```

## Runtime Parameters

The relay passes deployment-provided runtime JSON to `amaru run`:

```text
--era-history /amaru-runtime/era-history.json
# global-parameters.json is exported as AMARU_GLOBAL_* (amaru run --help-global-parameters)
```

These files must match the custom testnet genesis/config used by the
paired cardano-node. They are separate from the snapshot sidecar history
files that `amaru convert-ledger-state` writes next to each converted
snapshot.

## Node-Release Boundary

```mermaid
flowchart TB
    subgraph Pinned["Pinned cardano-node 10.7.1 dependency set"]
        chap["CHaP index state"]
        consensus["ouroboros-consensus\nrelease-3.0.1.0"]
        ledger["cardano-ledger-* versions"]
    end

    Pinned --> emitter["ledger-state-emitter"]
    emitter --> projection["Amaru bootstrap projection"]
    projection --> amaru["Amaru importer"]

    other["Future node release"] -. "requires retargeting" .-> Pinned
```

Retargeting to another node release is an explicit project task. It is
not just a Cabal compile check: the emitted ledger-state shape has to
match what Amaru imports for that release.

## Ledger-State Projection

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

## CI Startup Proof

```mermaid
sequenceDiagram
    participant Check as amaru-run-bootstrap
    participant Producer as bootstrap-producer
    participant Bundle as Bundle
    participant Amaru as amaru run

    Check->>Producer: synthesize chain DB, produce bundle
    Producer->>Bundle: import ledger, headers, nonces
    Check->>Bundle: copy to writable test directory
    Check->>Amaru: run with ledger-dir and chain-dir
    Amaru-->>Check: build_ledger trace
    Check-->>Check: timeout is expected, early bootstrap failure is not
```

The CI proof is deliberately peer-free: it does not prove live chain
synchronisation. It proves the produced stores are sufficient for Amaru
to open its ledger and chain state and enter node startup.
