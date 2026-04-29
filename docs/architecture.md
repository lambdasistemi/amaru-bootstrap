# Architecture

The producer is intentionally a small orchestration layer around
release-pinned tools. The critical design boundary is that
`ledger-state-emitter` targets one cardano-node release at a time; the
current branch targets `cardano-node 10.7.1`.

## Runtime Components

```mermaid
flowchart LR
    node["cardano-node\nchain DB + config"] --> preflight["bootstrap-producer\npre-flight"]
    preflight --> emitter["ledger-state-emitter\nnode-10.7.1 projection"]
    emitter --> legacy["Legacy ExtLedgerState CBOR"]
    legacy --> convert["amaru convert-ledger-state"]
    convert --> snapshot["snapshot CBOR\nhistory JSON\nnonces JSON"]

    node --> headers["header-extractor\nlist-blocks/get-header"]
    headers --> headerFiles["header.*.cbor files"]

    snapshot --> compose["nonce tail rewrite"]
    headerFiles --> compose
    compose --> imports["amaru import-ledger-state\namaru import-headers\namaru import-nonces"]
    imports --> bundle["complete bundle\n<bundle>/<network>"]
```

The producer's exit code is the synchronization primitive for Docker
Compose. Downstream Amaru services depend on
`service_completed_successfully` and start only after the bundle exists.

## State Machine

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

    other["Future node release"] -. requires retargeting .-> Pinned
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

## Concurrency

```mermaid
sequenceDiagram
    participant A as Producer A
    participant B as Producer B
    participant T as Temp dirs
    participant F as Final bundle

    A->>T: write <network>.tmp.pid.random
    B->>T: write <network>.tmp.pid.random
    A->>F: mv -T temp final
    F-->>A: success
    B->>F: mv -T temp final
    F-->>B: exists
    B->>F: validate complete bundle
    B-->>B: exit 0
```

There is no shared temp directory. Concurrent producers cannot corrupt
each other's intermediate files; one wins the atomic rename and the
others accept the completed bundle.
