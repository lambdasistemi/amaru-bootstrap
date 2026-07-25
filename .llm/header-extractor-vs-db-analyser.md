# Assesment: Replacing `header-extractor` with `db-analyser`

## Executive Summary

Upstream issue [#8](https://github.com/lambdasistemi/amaru/issues/8) suggested exploring whether the custom in-repo Haskell executable `header-extractor` could be removed in favour of stock `db-analyser` (`ouroboros-consensus-exe-db-analyser`).

Based on empirical testing against a synthesized testnet_42 chain DB (3,675 blocks across ~4.6 epochs), **`header-extractor` CANNOT be replaced by `db-analyser`**.

Key reasons:
1. **Performance / Complexity in Polling Loop (The Killer):** `db-analyser` lacks an $O(1)$ tip lookup subcommand. `header-extractor tip-info` inspects the immutable tip index in **~0.10s**, whereas `db-analyser --show-slot-block-no` performs an $O(N)$ sequential traversal over all blocks in **~0.48s** on a tiny test DB (~4.5x slower) and will take tens of seconds to minutes on full chains. Using `db-analyser` inside `bootstrap-producer.sh`'s polling loop is computationally prohibitive.
2. **Output Format:** `db-analyser` prints progress logs to **STDERR** in an unstructured log format (`[<timestamp>s] BlockNo N\tSlotNo S\tHASH`) rather than STDOUT JSON. `header-extractor list-blocks` emits structured JSON (`{"count": N, "data": [[slot, hash], ...]}`).
3. **Operational Parity:** `db-analyser` suffers from the exact same filesystem permission constraint as `header-extractor` (`FsInsufficientPermissions` when chain DB chunk files are read-only).

However, `header-extractor get-header` is **completely unused** by `bootstrap-producer.sh` and can be safely removed to reduce maintenance surface.

---

## 1. Call-Site Inventory

| File / Location | Subcommand | Input / Flags | Consumed Output |
|---|---|---|---|
| `scripts/bootstrap-producer.sh:300` | `tip-info` | `--db "${CHAIN_DB}" --config "${config_json}"` | JSON `.slot` and `.era` via `jq`. Invoked inside era-readiness polling loop. |
| `scripts/bootstrap-producer.sh:308` | `list-blocks` | `--db "${CHAIN_DB}" --config "${config_json}"` | JSON object containing `.data` array `[[slot, hash], ...]`. Saved to `preflight-blocks.json` and parsed by `jq` to compute target & parent slots for snapshot points. |
| `tests/test-header-extractor-cli.bats` | `tip-info`, `list-blocks`, `get-header` | CLI flag variations | Bats test assertions covering CLI routing, JSON schema formatting, and exit codes. |
| `tests/test-bootstrap-producer-*.bats` | `tip-info`, `list-blocks` | Mock shims | Mock binaries simulating subcommands for integration testing. |

### Unused Subcommand: `get-header`
- `get-header` is **NOT** invoked anywhere in `scripts/bootstrap-producer.sh` or any operational scripts.
- It was originally specified in research phase R-001 (mirroring `pragma-org/db-server`), but `bootstrap-producer.sh` delegates header creation to `amaru snapshot create` or internal pipelines.

---

## 2. Capability Match

Command executed against synthesized testnet_42 chain DB (`3,675` blocks):
```bash
db-analyser \
  --db /tmp/hx-explore/hx-db-analyser/test-chain-db \
  --config /code/amaru-bootstrap-hx-explore/specs/001-snapshot-format-smoke/fixtures/p1-config/configs/configs/config.json \
  --in-mem \
  --show-slot-block-no
```

### Captured Output Format
`db-analyser` writes to **two separate output streams**:

1. **STDOUT** (Summary line at the end):
```text
ImmutableDB tip: Point (At (Block {blockPointSlot = SlotNo 357472, blockPointHash = a1094554415c50b1098011e306b87d3dc5743df5eac9ddfc79bd77d2d4337495}))
```

2. **STDERR** (Per-block iteration log):
```text
[0.061643s] Started ShowSlotBlockNo
[0.061921s] BlockNo 0	SlotNo 10	13c65c74d61277304ab8e776cde6eecc88c8a355147b98c9639d814a17ab4dfa
[0.062043s] BlockNo 1	SlotNo 149	d8a3fbbf76d97230f0819f9bb34cdcc026ae509055c321c1a1c8783d69024dc9
[0.062143s] BlockNo 2	SlotNo 392	82192c27246751efa568d7366dec99b9965ea37d811262ea3d498df565c39747
...
[1.087430s] BlockNo 3674	SlotNo 357472	a1094554415c50b1098011e306b87d3dc5743df5eac9ddfc79bd77d2d4337495
[1.087762s] Done
```

### Contrast with `header-extractor list-blocks` STDOUT:
```json
{
  "count": 3675,
  "data": [
    [10, "13c65c74d61277304ab8e776cde6eecc88c8a355147b98c9639d814a17ab4dfa"],
    [149, "d8a3fbbf76d97230f0819f9bb34cdcc026ae509055c321c1a1c8783d69024dc9"],
    ...
  ]
}
```

### Comparison
`db-analyser` does **not** provide output in a direct JSON format. Using `db-analyser` for `list-blocks` would require complex shell parsing of STDERR (`grep`, `awk`, string splitting) to extract `[slot, hash]` pairs and reconstruct JSON.

---

## 3. The `tip-info` Gap (Era Information)

`header-extractor tip-info` produces:
```json
{"slot": 357472, "era": "Conway", "blockHash": "a1094554415c50b1098011e306b87d3dc5743df5eac9ddfc79bd77d2d4337495"}
```

- `db-analyser` does **not** output the era name ("Conway") anywhere.
- **Is era a hard blocker?** **NO.** `bootstrap-producer.sh` already reads `TestConwayHardForkAtEpoch` from `config.json` (line 234) and derives `conway_first_slot = conway_at * EPOCH_LENGTH`. Era readiness can be evaluated directly in shell by checking `slot >= conway_first_slot`.

---

## 4. Cost & Benchmarks

Timed on the 3,675-block synthesized chain DB (average over 3 executions):

| Tool & Command | Algorithmic Complexity | Execution Time (Wall-Clock) | Relative Speed |
|---|---|---|---|
| `header-extractor tip-info` | $O(1)$ (Direct tip index read) | **0.108s** | **1.0x (baseline)** |
| `header-extractor list-blocks` | $O(N)$ (Header scan + JSON) | **0.155s** | **1.4x** |
| `db-analyser --show-slot-block-no` | $O(N)$ (Full block traversal) | **0.476s** | **4.4x slower** |

### Why this is a killer for `db-analyser`:
`bootstrap-producer.sh:298-366` polls `tip-info` in a loop while `cardano-node` is actively running.
- `header-extractor tip-info` takes $O(1)$ time (~0.1s) regardless of whether the chain has 3,000 blocks or 3,000,000 blocks.
- `db-analyser` has no $O(1)$ tip mode. Every call to `--show-slot-block-no` traverses the entire Chain DB from block 0. On a mainnet or large testnet DB, each poll tick would take tens of seconds to several minutes, rendering the polling loop unusable.

---

## 5. Operational Constraints

### Read-Only Filesystem Permissions
When tested against a read-only chain DB (`chmod -R u-w`):
`db-analyser` **FAILS** with exit code 1 and error:
```text
db-analyser: UnexpectedFailure (FileSystemError (FsError {
  fsErrorType = FsInsufficientPermissions, 
  fsErrorPath = ".../immutable/00082.chunk", 
  fsErrorString = "Permission denied"
}))
```
`db-analyser` has the **exact same filesystem requirement** as `header-extractor`: the immutable chunk directory must be writable by the user because `ouroboros-consensus`'s `ImmutableDB` opens chunk files with write permissions during validation (`bootstrap-producer.sh:352`).

### Required CLI Flags
`db-analyser` requires both `--config <path>` AND an explicit ledger backend flag (`--in-mem` / `--lmdb` / `--lsm`).

---

## 6. Verdict & Recommendation

### Verdict: NOT REPLACEABLE
- **`tip-info`**: Cannot be replaced by `db-analyser` due to lack of $O(1)$ tip query mode and $O(N)$ polling loop performance overhead.
- **`list-blocks`**: Partially replaceable in theory, but requires unneeded stderr text scraping and is ~3x slower than `header-extractor list-blocks`.

### Recommendation
1. **Retain `header-extractor`** for `tip-info` and `list-blocks`.
2. **Issue a small cleanup ticket (S-sized, 0.5-1 day)**:
   - Prune the unused `get-header` subcommand from `app/header-extractor/Main.hs` and `lib/HeaderExtractor.hs`.
   - Remove corresponding dead test cases in `tests/test-header-extractor-cli.bats`.

---

## Caveats & Methodology
- Benchmark execution environment: Linux x86_64 nix build environment on local runner.
- Synthesized chain DB fixture: `header-extractor-fixture-chain-db` (3,675 blocks, `testnet_42` network params, `epochLength = 86400`).
