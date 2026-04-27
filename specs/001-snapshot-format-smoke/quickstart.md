# Quickstart: Snapshot Format Smoke Test

> **You are here**: phase-0 hypothesis validation. This document tells you how to run the smoke test against the vendored fixture and read the verdict.

## Prerequisites

- Linux x86_64
- Nix with flakes enabled
- The lambdasistemi Cachix substituter configured (recommended; not required — first build will be ~1 hour without it)
- ~500 MB free disk under the working directory

No Cabal, no Cargo, no GHC, no Rust toolchain — Nix provides everything.

## One-shot run against the vendored fixture

```bash
git clone https://github.com/lambdasistemi/amaru-bootstrap.git
cd amaru-bootstrap
nix run .#smoke-test -- specs/001-snapshot-format-smoke/fixtures/p1-config /tmp/smoke-out
```

After ~3-5 minutes, the last line of stdout is the verdict:

| Last line | Meaning | Next step |
|-----------|---------|-----------|
| `PASS` | the no-fork hypothesis is validated | proceed to Phase 1: full bootstrap orchestrator |
| `FAIL: format mismatch` | upstream snapshot format is NOT what amaru's converter expects | escalate: design a small standalone snapshot-emitter that depends on `ouroboros-consensus-cardano` as a *library* (still no fork) |
| `FAIL: tool error: <step>` | one of the upstream tools failed before we exercised the hypothesis | inspect `/tmp/smoke-out/<step>.stderr.log`; likely a Phase 0 environmental issue, not a project pivot |
| `FAIL: configuration error: <reason>` | the bundle was invalid or the out-dir was dirty | fix the inputs and rerun |

## Recovering more detail

```bash
cat /tmp/smoke-out/report.txt
ls -la /tmp/smoke-out/
```

`report.txt` is the durable record. Keep it if you want to share findings without re-running the test.

## Running against your own bundle

The orchestrator takes any [conformant bundle](./data-model.md#input-bundle):

```bash
nix run .#smoke-test -- /path/to/your/bundle /tmp/your-out
```

The vendored fixture exists for Phase 0's "zero friction" requirement. Phase 1 will exercise the orchestrator against arbitrary bundles.

## Cleanup

```bash
rm -rf /tmp/smoke-out
```

Note: the smoke test refuses to run with a non-empty out-dir, so cleanup is the operator's responsibility.

## What the smoke test does NOT do

- It does NOT run a full `import-ledger-state` / `import-headers` / `import-nonces` cycle into amaru's stores. Those are Phase 1.
- It does NOT validate that amaru can subsequently *boot* from the converted snapshot. The hypothesis under test is purely format compatibility at the `convert-ledger-state` boundary.
- It does NOT extract headers or compose `nonces.json`. Phase 1.

If `convert-ledger-state` accepts the snapshot and returns success, Phase 0 is `PASS` even if amaru would later fail to boot. That's by design — a Phase 0 PASS unlocks Phase 1, which has its own validation gates.
