# Architecture

The producer is intentionally a small orchestration layer around
release-pinned tools. The critical design boundary is that
`ledger-state-emitter` targets one cardano-node release at a time; the
current branch targets `cardano-node 10.7.1`.

## Runtime Components

```mermaid
flowchart LR
    node["cardano-node\nchain DB + config"] --> mount["state mount rw\nconfig mount ro"]
    mount --> preflight["bootstrap-producer\npre-flight"]
    preflight --> emitter["ledger-state-emitter x3\nnode-10.7.1 projection"]
    emitter --> legacy["Legacy ExtLedgerState CBOR\nlatest + two prior epochs"]
    legacy --> convert["amaru convert-ledger-state x3"]
    convert --> snapshot["snapshot CBOR\nhistory JSON\nnonces JSON"]

    mount --> headers["header-extractor\nlist-blocks/get-header"]
    headers --> headerFiles["header.*.cbor files"]

    snapshot --> compose["nonce tail rewrite"]
    headerFiles --> compose
    compose --> imports["amaru import-ledger-state\namaru import-headers\namaru import-nonces"]
    imports --> bundle["complete bundle\n<bundle>/<network>"]
```

The producer's exit code is the synchronization primitive for Docker
Compose. Downstream Amaru services depend on
`service_completed_successfully` and start only after the bundle exists.

## Live ChainDB Contract

```mermaid
flowchart LR
    writer["cardano-node\nlive writer"] --> state["state volume\nChainDB"]
    state --> imm["immutable chunks\nappend-only"]
    state --> vol["volatile DB\nignored"]
    imm --> tip["header-extractor tip-info"]
    imm --> headers["header-extractor headers"]
    state -. "mounted read-write\nfor consensus validation" .-> tip
```

The bootstrap-producer's semantic contract is immutable-only access:
readiness is derived from the immutable tip and header extraction walks
immutable chunks. The Docker mount is still read-write because
node-10.7.1's consensus ImmutableDB validation path opens chunk files
through APIs that reject a read-only filesystem. The producer does not
use volatile DB state as a readiness source.

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
    Check-->>Check: timeout is expected; early bootstrap failure is not
```

The CI proof is deliberately peerless: it does not prove live chain
synchronisation. It proves the produced stores are sufficient for Amaru
to open its ledger and chain state and enter node startup.
