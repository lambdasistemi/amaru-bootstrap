# Phase 0: Snapshot Format Experiment

## Finding (2026-04-28)

The Phase 0 experiment tested whether Amaru could directly consume the
ledger state emitted by `db-analyser --store-ledger`. The orchestrator
ran `db-synthesizer` to fabricate a chain DB, dumped the ledger state
with `db-analyser`, and attempted conversion via
`amaru convert-ledger-state`.

The experiment legitimately reported:

```text
FAIL: format mismatch
```

This falsified the hypothesis that `db-analyser --store-ledger` output
could be consumed directly by Amaru and drove the no-fork pivot to a
standalone snapshot emitter: `amaru create-snapshots` followed by
`amaru bootstrap`, which produce stores Amaru can open natively.

## Retirement (2026-07-28)

[Issue #61](https://github.com/lambdasistemi/amaru-bootstrap/issues/61)
found that the retained CI rerun had become invalid: the pinned Amaru
binary removed the `convert-ledger-state` subcommand, so the orchestrator
exited with an unrecognized-command error that the script mapped to the
historical `FAIL: format mismatch` verdict. CI accepted that verdict as
success, producing a false green signal for a command that no longer
exists.

The obsolete script, flake app, flake checks, CI job, Just recipes,
dedicated tests, and tracked generated output were retired. The
legitimate 2026-04-28 conclusion is preserved here and in the immutable
primary record.

## Primary record

- [Phase 0 specification](https://github.com/lambdasistemi/amaru-bootstrap/tree/main/specs/001-snapshot-format-smoke)
- [Issue #61](https://github.com/lambdasistemi/amaru-bootstrap/issues/61)
- [Measured CI job](https://github.com/lambdasistemi/amaru-bootstrap/actions/runs/30356417382/job/90265660051)

## Current producer coverage

The bootstrap producer path is covered by:

- synthesized bootstrap-producer checks
  (`bootstrap-producer-synthesized`, `bootstrap-producer-bats`)
- `amaru-run-bootstrap` (Amaru startup from a produced bundle)
- short-epoch goldens (`antithesis-short-epoch-samples`,
  `antithesis-short-epoch-golden`)
- the Docker live verifier (`live-bootstrap-producer`)
