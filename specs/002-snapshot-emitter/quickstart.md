# Quickstart: Snapshot Emitter

> **You are here**: Phase 1. The Phase 0 smoke test established that
> stock `db-analyser` writes a directory snapshot but `amaru
> convert-ledger-state` wants a file. This tool is the bridge.

## Prerequisites

Same as Phase 0:

- Linux x86_64
- Nix with flakes enabled
- The `paolino` Cachix substituter configured (recommended)
- ~500 MB free disk under the working directory

## Run the bridged smoke test

The Phase 0 smoke test now includes the new emitter step (FR-009 — one
line of orchestrator change). Re-run it as before:

```bash
git clone https://github.com/lambdasistemi/amaru-bootstrap.git
cd amaru-bootstrap
nix run .#smoke-test -- specs/001-snapshot-format-smoke/fixtures/p1-config /tmp/smoke-out
```

After ~3 minutes, the last line of stdout should be `PASS` rather than
`FAIL: format mismatch`. The Phase 1 hypothesis (Cabal-library
consumption of consensus is sufficient to bridge the format gap) is
validated by that one-word change.

| Last line | Meaning | Next |
|-----------|---------|------|
| `PASS` | bridge works; Phase 1 done | proceed to Phase 2 (header extraction, nonces, …) |
| `FAIL: format mismatch` | the bridge is incomplete | inspect `/tmp/smoke-out/convert.stderr.log` for amaru's specific complaint and revise the encoder choice |
| `FAIL: tool error: emit` | the emitter itself crashed | inspect `/tmp/smoke-out/emit.stderr.log`; structural validation or decode failure is most likely |

## Run the emitter standalone

The emitter is also a first-class flake app; you can run it on any
directory snapshot you have lying around (for example, one produced
manually by a fresh `db-analyser` invocation):

```bash
nix run .#snapshot-emitter -- /path/to/<slot>_db-analyser /tmp/snapshot.cbor
```

A successful invocation prints exactly:

```text
wrote /tmp/snapshot.cbor
```

## Check the verdict on disk

```bash
cat /tmp/smoke-out/report.txt
ls -la /tmp/smoke-out/snapshot.cbor      # the new file the emitter wrote
ls -la /tmp/smoke-out/converted/         # amaru's output, populated only on PASS
```

## Cleanup

```bash
rm -rf /tmp/smoke-out
```

The smoke test refuses to run with a non-empty out-dir, so cleanup is
the operator's responsibility.

## What this tool does NOT do

- Header extraction (Phase 2)
- `nonces.json` composition (Phase 2)
- Multi-epoch / multi-snapshot batching
- Era support beyond `CardanoBlock` (Cardano testnets only; out of scope
  for any non-Cardano chain)

If `amaru convert-ledger-state` accepts the bridged file, Phase 1 is
`PASS` even if subsequent amaru bootstrapping (import-ledger-state,
import-headers, import-nonces) fails. Those failures belong to Phase 2.
