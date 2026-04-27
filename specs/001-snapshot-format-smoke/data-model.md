# Data Model: Snapshot Format Smoke Test

The smoke test has four data entities plus one synthesised output (the verdict).

## Entities

### Input bundle

A directory containing the documents needed to bootstrap a custom Cardano testnet: a node configuration, the genesis files it references, and credentials for at least one block-producing pool.

```text
<bundle>/
├── configs/
│   ├── config.json
│   ├── byron-genesis.json
│   ├── shelley-genesis.json
│   ├── alonzo-genesis.json
│   ├── conway-genesis.json
│   ├── (optional) dijkstra-genesis.json
│   └── topology.json    (unused by smoke test, ignored if present)
└── keys/
    ├── opcert.cert      operational certificate
    ├── kes.skey         KES signing key
    ├── vrf.skey         VRF signing key
    └── cold.skey        cold signing key
```

**Validation**: smoke test verifies the directory exists and that `configs/config.json`, `configs/shelley-genesis.json`, and the four key files exist. Anything else is delegated to the tools' own validation (we surface tool errors, we don't pre-validate Cardano semantics).

**Source for Phase 0**: vendored fixture at `specs/001-snapshot-format-smoke/fixtures/p1-config/`. Exact source recorded in `fixtures/PROVENANCE.md`.

### Bulk credentials JSON

Internal artefact built by the smoke test from the input bundle's keys. JSON array of `[opcert, vrf.skey, kes.skey]` triples (one per pool). For Phase 0 with one pool, a one-element array.

```json
[[<opcert.cert object>, <vrf.skey object>, <kes.skey object>]]
```

Built by reading each key file (each is its own JSON document) and assembling the array. Fed to `db-synthesizer --bulk-credentials-file`.

### Synthesised chain database

On-disk Cardano `ChainDB` produced by `db-synthesizer` covering at least one full epoch. Layout is whatever the tool emits — the smoke test does not inspect it, only passes it onward.

```text
<out-dir>/chain-db/
├── immutable/       immutable DB chunks
├── volatile/        volatile DB
├── ledger/          ledger DB
└── ...
```

**Lifecycle**: created by the synthesise step, read by the dump step, retained on disk for diagnosis (FR-006). Never modified after the synthesise step.

### Ledger snapshot

A single on-disk file emitted by `db-analyser --store-ledger SLOT`. Format is whatever the tool produces — the smoke test does not parse it, only passes its path to `amaru convert-ledger-state`.

```text
<out-dir>/snapshots/<SLOT>
```

(Exact filename pattern is whatever the tool writes; smoke test discovers it after the dump step.)

**The compatibility hypothesis lives here**: this snapshot is the single load-bearing data entity of the entire feature. Either Amaru reads it and the project lives, or it doesn't and the project pivots.

### Verdict

The synthesised final output. A small structured record:

| Field | Type | Values |
|-------|------|--------|
| `outcome` | enum | `PASS`, `FAIL: format mismatch`, `FAIL: tool error: <step>`, `FAIL: configuration error: <reason>` |
| `report_path` | filesystem path | `<out-dir>/report.txt` |
| `chain_db_path` | filesystem path | `<out-dir>/chain-db/` |
| `snapshot_path` | filesystem path \| null | path to the dumped snapshot, or null if dump never ran |
| `converted_path` | filesystem path \| null | path to amaru's converter output, or null if convert failed or never ran |

Serialised on stdout as two lines:

```
report: <out-dir>/report.txt
<outcome>
```

The operator-facing contract is the *outcome* line — the last line of stdout. The `report:` line precedes it so a `tail -n 2 | head -n 1` pipeline gets the report path; `tail -n 1` gets the verdict.

## State Transitions

The smoke test is a linear pipeline. Failure at any step short-circuits to a verdict.

```
              ┌─────────────────────────────────┐
              │ PRE: <out-dir> empty or absent  │
              └────────────────┬────────────────┘
                               │
                  ╔════════════▼════════════╗
                  ║ 1. Validate bundle       ║─── miss ─→ FAIL: configuration error
                  ╚════════════┬═════════════╝
                               │
                  ╔════════════▼═════════════╗
                  ║ 2. Build bulk-creds.json ║─── error ─→ FAIL: tool error: prepare
                  ╚════════════┬═════════════╝
                               │
                  ╔════════════▼═════════════╗
                  ║ 3. db-synthesizer        ║─── exit≠0 ─→ FAIL: tool error: synthesise
                  ╚════════════┬═════════════╝
                               │
                  ╔════════════▼═════════════╗
                  ║ 4. db-analyser           ║─── exit≠0 ─→ FAIL: tool error: dump
                  ║    --store-ledger SLOT   ║                (or no snapshot file produced)
                  ╚════════════┬═════════════╝
                               │
                  ╔════════════▼═════════════╗
                  ║ 5. amaru                 ║─── exit≠0 ─→ FAIL: format mismatch
                  ║    convert-ledger-state  ║
                  ╚════════════┬═════════════╝
                               │
                               ▼
                            PASS
```

A single distinction: a non-zero exit from `amaru convert-ledger-state` is `FAIL: format mismatch` — that's the entire thesis of the test. Non-zero exits from any earlier step are `FAIL: tool error` because they don't actually exercise the hypothesis.

## Out of scope (Phase 1+)

- `nonces.json` composition
- Header extraction via `db-server`
- `amaru import-ledger-state` / `import-headers` / `import-nonces`
- Multi-pool credentials
- Multi-epoch synthesis
- Operator-supplied bundles (the orchestrator already supports this; only the fixture is Phase-0-specific)
