# Contract: Snapshot Emitter CLI

The snapshot-emitter is exposed as `nix run .#snapshot-emitter -- <slot-dir> <out-file>`.

## Invocation

```text
nix run .#snapshot-emitter -- <slot-dir> <out-file>
```

Or equivalently after `nix develop`:

```text
snapshot-emitter <slot-dir> <out-file>
```

## Arguments

| Position | Name | Required | Description |
|----------|------|----------|-------------|
| 1 | `<slot-dir>` | yes | Path to a directory snapshot produced by `db-analyser --store-ledger SLOT --v2-in-mem` (a `<slot>_db-analyser/` directory containing `meta`, `state`, `tables/tvar`) |
| 2 | `<out-file>` | yes | Path where the single-file legacy snapshot will be written. MUST NOT exist |

No flags. No optional arguments. No environment variables. No interactive prompts.

## Exit codes

| Code | Class | Meaning |
|------|-------|---------|
| `0` | success | output file is conformant |
| `1` | input-not-found | `<slot-dir>` does not exist |
| `2` | input-structurally-invalid | `<slot-dir>` is not a directory, or required component file (`state` / `tables/tvar`) is missing or empty |
| `3` | decode-error | the upstream consensus library rejected one of the input files |
| `4` | output-collision | `<out-file>` already exists |
| `5` | output-write-error | I/O failure while writing the temp file or renaming it into place |
| `≥64` | internal-error | unexpected exception (programmer error) |

## Stdout / stderr

- **stdout**: a single line on success: `wrote <abs-path-to-out-file>`. Empty on every failure path.
- **stderr**: one or more error lines on failure, conforming to FR-010 / SC-004:
  ```
  snapshot-emitter: <error-class>: <specific component or filesystem path>
  snapshot-emitter: <verbatim upstream library message, if applicable>
  ```
- No progress chatter; the emitter is fast (≤1 second on the vendored fixture). For longer inputs we'd add progress later.

## On-disk artefacts

After every run, regardless of verdict:

| Path | Existence after success | Existence after any failure |
|------|------------------------|----------------------------|
| `<out-file>` | exists, conformant | does not exist (atomic-write guarantee) |
| `<out-file>.tmp.<pid>` | does not exist (renamed) | does not exist (cleaned by `bracket`) |
| `<slot-dir>/...` | unchanged | unchanged (never written) |

## Atomic-write guarantee

Per FR-005 and SC-003: the only file the emitter writes is `<out-file>`,
and that write is atomic via `<out-file>.tmp.<pid>` + `renameFile`.

If the emitter is killed (SIGKILL) between temp-write and rename, the
temp file remains; SIGTERM and any other unwind path triggers the
`bracket` cleanup.

## Determinism

Per SC-005: two consecutive runs against the same `<slot-dir>` produce
byte-identical `<out-file>` outputs. The emitter introduces no
timestamps, no random IDs, no path-dependent encoding.

## Composition with the Phase 0 smoke test

Per FR-009, the smoke-test orchestrator change is a single new step:

```diff
   # Step 5: dump
   db-analyser ... --store-ledger SLOT --v2-in-mem ... ;# unchanged
   SNAPSHOT_DIR="$(find ... -type d -name '*_db-analyser' ... )"

+  # Step 5.5: emitter (Phase 1)
+  snapshot-emitter "$SNAPSHOT_DIR" "$OUT/snapshot.cbor"
+  SNAPSHOT_FILE="$OUT/snapshot.cbor"
+
   # Step 6: convert (now reads the file, not the directory)
-  amaru convert-ledger-state ... --snapshot "$SNAPSHOT_DIR" ...
+  amaru convert-ledger-state ... --snapshot "$SNAPSHOT_FILE" ...
```

No other change. The smoke test's verdict-emission contract is
untouched.

## Versioning

Versioned implicitly via the orchestrator's git SHA (same convention as
the Phase 0 smoke test). No `--version` flag in Phase 1; if the contract
changes between Phase 1 and Phase 2 the binary will gain `--version` and
a stable contract document.
