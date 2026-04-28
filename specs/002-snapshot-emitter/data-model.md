# Data Model: Snapshot Emitter

Three data entities plus the verdict pivot.

## Entities

### Directory snapshot (input)

A directory on disk produced by `db-analyser --store-ledger SLOT --v2-in-mem`.

```text
<slot>_db-analyser/
├── meta              JSON: backend tag + checksum (we read it for
│                     validation, not for decoding)
├── state             CBOR-encoded `ExtLedgerState CardanoBlock EmptyMK`
│                     via the consensus encoder; the table marker is
│                     EmptyMK because tables live separately
└── tables/
    └── tvar          CBOR-encoded `LedgerTables (LedgerState
                      CardanoBlock) ValuesMK` — the UTxO map and
                      friends, separated out by V2InMemory
```

**Validation rules** (per FR-008, before any decode):
- the supplied path must exist and be a directory
- `state` must exist and be a regular non-empty file
- `tables/tvar` must exist and be a regular non-empty file
- `meta` MAY exist (purely informational; we don't enforce)

**Source**: produced by stock `db-analyser` from the pinned consensus
release. Not constructed by this feature.

### Node configuration (input)

The node `config.json` that was passed to `db-synthesizer` and
`db-analyser` when the directory snapshot was produced. Read by
`Cardano.Tools.DBAnalyser.Block.Cardano.mkProtocolInfo` to build the
`CodecConfig (CardanoBlock StandardCrypto)` that decodes/encodes the
ledger state. Resolves the era-specific genesis files
(Byron/Shelley/Alonzo/Conway/Dijkstra) by relative path.

**Validation rules**:
- the supplied path must exist and be a regular file
- the node config loader's own validation reports any structural
  problem (missing genesis pointers, malformed JSON, &c.) as a
  decode-error to the operator

**Source**: same `config.json` the rest of the pipeline already uses;
in the smoke test, it lives at
`<bundle>/configs/configs/config.json`.

### Reattached extended ledger state (intermediate)

A typed in-memory value: `ExtLedgerState CardanoBlock ValuesMK`. Built by:

```
state' :: ExtLedgerState CardanoBlock EmptyMK   <- decode <state-bytes>
tables :: LedgerTables (LedgerState CardanoBlock) ValuesMK
                                                <- decode <tables-bytes>
state  :: ExtLedgerState CardanoBlock ValuesMK
                                                <- state' `withLedgerTables` tables
```

This entity exists only in memory; it is never written to disk on its
own. It is the input to the legacy encoder.

### File snapshot (output)

A single file at the operator-supplied output path. Format per
[`encodeL`](https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus-cardano/src/unstable-consensus-storage/Ouroboros/Consensus/Storage/LedgerDB/Snapshots.hs):

```
CBOR array:
[ snapshotEncodingVersion1   -- Word16 = 1
, tip                        -- WithOrigin (RealPoint blk)
, chainLength                -- Word64
, encodeExtLedgerState <s>   -- the reattached state from above
]
```

Tip and chain length are read from the `state` file's header (already
encoded inside the `ExtLedgerState`'s embedded `HeaderState`); the
emitter reconstructs them from `extLedgerHeaderState` before re-encoding.

**Lifecycle**: written atomically. The emitter writes
`<out-file>.tmp.<pid>`, fsyncs, then `renameFile`s it to `<out-file>`
(R-005). If any step fails the temp file is removed by `bracket`.

### Verdict pivot (test-side property)

Not a data entity; a property of the existing Phase 0 smoke test
([`scripts/smoke-test.sh`](../../../scripts/smoke-test.sh)).

Before this feature: smoke test produces `FAIL: format mismatch`.
After this feature: smoke test produces `PASS`.

Observable through CI: the `Smoke Test (Phase 0 verdict)` job's
`$GITHUB_STEP_SUMMARY` records `PASS` instead of `FAIL: format mismatch`.

## State Transitions

The emitter is a linear pipeline; failure at any step short-circuits.

```
                 ┌───────────────────────────────┐
                 │ PRE: <out-file> absent or its │
                 │      parent dir writable      │
                 └───────────────┬───────────────┘
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 1. Pre-flight validation   ║─── miss   ─→ rc=2 input-structurally-invalid
                  ║    (FR-008)                ║─── nodir  ─→ rc=1 input-not-found
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 2. Output collision check  ║─── exists ─→ rc=4 output-collision
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 3. Build CodecConfig from  ║─── error  ─→ rc=3 decode-error
                  ║    <config-path>           ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 4. Decode state            ║─── error  ─→ rc=3 decode-error
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 5. Decode tables/tvar      ║─── error  ─→ rc=3 decode-error
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 6. withLedgerTables merge  ║  pure, no failure path
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 7. encodeL +               ║  pure
                  ║    encodeExtLedgerState    ║
                  ╚══════════════┬══════════════╝
                                 │
                  ╔══════════════▼══════════════╗
                  ║ 8. Atomic write            ║─── ioerr  ─→ rc=5 output-write-error
                  ║    (writeFile + rename)    ║
                  ╚══════════════┬══════════════╝
                                 │
                                 ▼
                              rc=0 success
```

## Error class registry

| rc | class | when |
|----|-------|------|
| 0 | success | output file written, conformant |
| 1 | input-not-found | input directory does not exist |
| 2 | input-structurally-invalid | input is not a dir; or required file (`state`, `tables/tvar`) is missing or empty |
| 3 | decode-error | upstream library rejects either CBOR file |
| 4 | output-collision | output path already exists and is not a directory |
| 5 | output-write-error | I/O failure during temp write or rename |

## Out of scope (Phase 2+)

- Streaming variant for snapshots that don't fit in memory
- Multi-snapshot batching
- Header CBOR + nonces JSON emission (separate tickets)
- Era selection at runtime (always `CardanoBlock`)
- `--force` flag for output overwrite
