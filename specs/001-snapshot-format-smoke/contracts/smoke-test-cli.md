# Contract: Smoke Test CLI

The smoke test is exposed as `nix run .#smoke-test -- <bundle> <out-dir>`. This document is the contract between the orchestrator and its caller.

## Invocation

```text
nix run .#smoke-test -- <bundle-path> <out-dir>
```

Or equivalently, after `nix develop`:

```text
smoke-test <bundle-path> <out-dir>
```

## Arguments

| Position | Name | Required | Description |
|----------|------|----------|-------------|
| 1 | `<bundle-path>` | yes | Absolute or relative path to an [Input Bundle](../data-model.md#input-bundle) directory |
| 2 | `<out-dir>` | yes | Path where the smoke test will write all artefacts (chain DB, snapshot, report). MUST be empty or absent |

No flags. No optional arguments. No environment variables. No interactive prompts.

## Exit codes

| Code | Meaning | Stdout last line |
|------|---------|-------------------|
| `0` | hypothesis validated | `PASS` |
| `1` | hypothesis falsified at amaru's converter | `FAIL: format mismatch` |
| `2` | upstream tool failed before reaching the converter | `FAIL: tool error: <step>` |
| `3` | invalid bundle, dirty out-dir, or other pre-flight error | `FAIL: configuration error: <reason>` |
| `≥64` | unexpected internal error (bash trap) | `FAIL: internal error: <message>` |

## Stdout shape

Every run, regardless of verdict, emits exactly:

```text
report: <abs-path-to-report.txt>
<outcome-line>
```

…as the *final two lines* of stdout. Earlier stdout lines may include progress chatter (`+ db-synthesizer ...`, `+ amaru convert-ledger-state ...`). A consumer who wants only the verdict can `tail -n 1`; a consumer who wants the report path can `tail -n 2 | head -n 1`.

## Stderr shape

Stderr captures the orchestrator's own progress (one line per step start) plus any direct-printed errors. The full stderr of every invoked tool is *also* captured to `<out-dir>/<step>.stderr.log` and referenced from the report.

## On-disk artefacts

After every run, regardless of verdict, the following exist under `<out-dir>`:

```text
<out-dir>/
├── report.txt                    Human-readable summary
├── bulk-credentials.json         Built from the bundle (always)
├── chain-db/                     If synthesise ran (PASS or any later FAIL)
├── snapshots/                    If dump ran
│   └── <SLOT>                    The dumped snapshot file (if dump succeeded)
├── converted/                    If amaru convert-ledger-state ran
├── synthesise.stderr.log         Always (zero-byte if step did not run)
├── dump.stderr.log               Always
└── convert.stderr.log            Always
```

`report.txt` contains, in order: bundle path, out-dir path, the verdict, exit codes of each step, paths to each step's stderr log, and the timestamp of the run.

## Pre-flight validation

Before invoking any tool, the orchestrator MUST:

1. Verify `<bundle-path>` is a directory containing `configs/config.json`, `configs/shelley-genesis.json`, `keys/opcert.cert`, `keys/kes.skey`, `keys/vrf.skey`, `keys/cold.skey`. Missing → `FAIL: configuration error: missing <file>`.
2. Verify `<out-dir>` is empty or absent. If absent, create it. If non-empty → `FAIL: configuration error: out-dir not empty`.
3. Read `epochLength` from `<bundle-path>/configs/shelley-genesis.json`. Compute the snapshot slot as `epochLength` (start of epoch 1).

## Idempotency

Two invocations on the same bundle and the same tool versions MUST produce the same verdict (SC-004). The on-disk *content* of the chain DB and snapshot need not be byte-identical — synthesised chain content can vary based on tool internals — but the verdict is invariant.

## Versioning

This contract is versioned implicitly via the orchestrator's git SHA. No `--version` flag in Phase 0; if the contract changes between Phase 0 and Phase 1 the orchestrator will gain `--version` and a stable contract document.
