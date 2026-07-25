# Assessment: replacing `header-extractor` with `db-analyser`

Upstream issue [lambdasistemi/amaru#8](https://github.com/lambdasistemi/amaru/issues/8)
asked whether the in-repo Haskell executable `header-extractor` can be dropped
in favour of stock `db-analyser`
(`ouroboros-consensus-exe-db-analyser`, already vendored as `iogTools.db-analyser`).

**Exploratory only — nothing here is implemented.**

> This file replaces the first-pass assessment committed as `6e2ebab`, which
> reached the opposite verdict on a claim that does not survive testing, and was
> then re-scoped to the amaru-facing surface only. See
> [Revision history](#11-revision-history).

**Scope, as of the third pass:** the question is *not* whether `db-analyser`
can reproduce `header-extractor`'s API. It is whether `db-analyser` can supply
what **amaru** needs. §8 establishes that surface and answers the question
against it; §1 gives the verdict under that scoping. §3–§7 are retained because
they are still the evidence base, but several §7 residue items turn out to be
artifacts of preserving an API nothing requires — each is marked.

---

## 1. Verdict

**Replaceable.** Everything amaru consumes from the chain DB is obtainable from
`db-analyser`, and the producer-internal scaffolding around it is free to be
redesigned rather than reproduced.

| what | needed by amaru? | obtainable from `db-analyser`? | evidence |
|---|---|---|---|
| 3 epoch-boundary blocks + their 3 parents — 6 `(slot, hash)` pairs | **yes, this is the whole surface** | **yes** — reproduces `targets.json` exactly | §8.1, §8.2 |
| tip slot (readiness gate) | no — producer-internal | yes, faster than `tip-info` | §4, §5.1 |
| tip era (readiness gate) | **no** — never reaches amaru | n/a — gap dissolves | §8.3 |
| whole-chain block list | **no** — an artifact of how the gate was built | n/a — descoped | §8.1 |
| `get-header` | no — unused by anything | n/a | §3 |

Two claims from earlier passes are now settled and do not change:

- The first pass's blocking argument — *"`db-analyser` has no O(1) tip mode, so
  each poll tick would take tens of seconds to minutes"* — is **false**. There
  is a `db-analyser` invocation that prints the tip and does no other work, and
  it is measurably as fast as or faster than `header-extractor tip-info` at
  every DB size tested (§4, §5).
- **Neither tool has an O(1) tip query.** Both pay the same ImmutableDB-open
  cost, growing linearly in the number of chunk *files*, because they run
  literally the same open code path (§4.3, §5.2).

What it costs (§8.2, measured): the readiness-gate tick gets *cheaper*
(0.087 s vs 0.115 s). The one-shot point extraction gets dearer — 1.842 s vs
0.349 s on an 11,743-block DB — but that is still around one ledger-replay step
of the `amaru snapshot create` work that immediately follows on the same chain
DB (1.576 s measured). The extraction is not, and does not become, the
bottleneck.

Recommendation and re-sized ticket: §10.

---

## 2. Provenance of every claim below

- **[parent]** — independently reproduced by the supervising agent; inherited.
- **[measured]** — measured in this pass; command and fixture named.
- **[source]** — read out of the pinned `ouroboros-consensus` source in the
  Nix store or out of this repo; file and line given.
- **[inference]** — reasoned, not measured. Called out every time.

Binaries (both from the repo's own pin):

- `db-analyser` — `/nix/store/p18mpng3jyps2k912ys8lqhwzi7mkm3j-ouroboros-consensus-exe-db-analyser-3.0.1.0/bin/db-analyser`
- `header-extractor` — `/nix/store/xa4dw3a91n589n6jrhnygvprigw6nya1-amaru-bootstrap-exe-header-extractor-0.1.0.0/bin/header-extractor`
- consensus source — `/nix/store/vzq42n5x0kbi66smlnq2m0f6aaf2q766-ouroboros-consensus-c87aa76`

Fixtures (all under `/tmp/hx-explore/hx-db-analyser/`, all synthesized from
`specs/001-snapshot-format-smoke/fixtures/p1-config` with the same
`db-synthesizer` recipe `nix/checks.nix:59` uses):

| fixture | blocks | chunk files | how |
|---|---|---|---|
| `db-b250` … `db-b2000` | 251 / 501 / 1001 / 2001 | 6 / 11 / 23 / 45 | `db-truncater --truncate-after-block` on `db-400k` |
| `db-400k` | 3675 | 83 | `db-synthesizer -s 400000` (reproduces the repo fixture exactly) |
| `db-big` | 11743 | 262 | `db-synthesizer -s 4000000`, interrupted; partial DB reopened cleanly |
| `pad-1000/5000/20000` | 3675 (constant) | 1000 / 5000 / 20000 | `db-400k` + hard-linked filler chunk files (§5.2) |

Measurement caveat: the machine is shared and carried a load average of ~13
throughout. Timings are **medians of 7 runs after one warm-up** in §5, medians
of 5 in §8; treat differences under ~30 ms as noise. Scripts: `bench.sh`,
`synth.sh`, `shim.sh`, `points.sh` in the runtime root.

Third-pass note: the scratch fixtures were archived between the second and third
passes and `db-400k` was rebuilt from the cached nix fixture
`/nix/store/w9kh11qr…-header-extractor-fixture-chain-db` — it reproduces at
3,675 blocks / 83 chunks / tip slot 357472, identical to the second pass's. The
`pad-*` and `db-big` fixtures were restored intact, so §5.2 rests on the same
data the reviewer independently reproduced.

---

## 3. Call-site inventory

Unchanged from the first pass and confirmed **[parent]** **[measured]**.

| location | subcommand | consumed output |
|---|---|---|
| `scripts/bootstrap-producer.sh:300` | `tip-info` | `.slot` and `.era` via `jq`, inside the era-readiness polling loop |
| `scripts/bootstrap-producer.sh:308` | `list-blocks` | `.data` → `[[slot, hash], …]`, saved to `preflight-blocks.json`, `jq`-reduced to the three snapshot slots |
| `tests/test-header-extractor-cli.bats` | all three | CLI routing, JSON shape, exit codes |
| `tests/test-bootstrap-producer-*.bats` | `tip-info`, `list-blocks` | mock shims only |

`get-header` has no caller in `scripts/`, in the producer, or in
`scripts/amaru-relay-bootstrap.sh` **[measured]** — it exists only because
research R-001 mirrored `pragma-org/db-server`'s surface. It is dead weight
under either verdict.

### 3.1 Correction to the first pass — the `list-blocks` JSON shape

The first pass reported `{"count": N, "data": [...]}`. **There is no `count`
field.** The real envelope is **[parent]** **[measured]**:

```json
{"tag":"Found","data":[[10,"13c65c…"],[149,"d8a3fb…"], …]}
```

`app/header-extractor/Main.hs:96-105` builds it, and the module header
(`app/header-extractor/Main.hs:22-24`) says why: it is *"a db-server-portable
envelope so Arnaud's amaru-loader.sh pipeline ports unchanged"* **[source]**.
The `tag: "Found"` is an interop shape, not decoration. **[DESCOPED — §8.1]**
it was shaped for a `db-server`-style consumer, and no such consumer is in this
pipeline: the only reader of `list-blocks` output is the producer's own `jq`,
four lines of it, all of which reduce to 6 pairs. A replacement does not have to
emit this envelope; it has to emit those pairs.

---

## 4. How `db-analyser` prints the tip — mechanism

This is where both the first pass and its reviewer were wrong, in opposite
directions.

### 4.1 The tip line is printed *after* the analysis, not on DB open

`Cardano/Tools/DBAnalyser/Run.hs:199-230` **[source]**:

```haskell
withImmutableDB immutableDbArgs $ \(immutableDB, internal) -> do
  …
  result <- ana AnalysisEnv{…}                              -- the analysis body
  tipPoint <- atomically $ ImmutableDB.getTipPoint immutableDB
  putStrLn $ "ImmutableDB tip: " ++ show tipPoint           -- then the tip
  pure result
```

So the reviewer's stated mechanism — *"printed on DB open, therefore available
from any analysis"* — is **refuted**. Confirmed empirically: give the run a
parameter that fails before the analysis body and **no tip is printed**
**[measured]**:

```
$ db-analyser --db test-chain-db --config … --in-mem --count-blocks --analyse-from 999999
db-analyser: user error (No block with given slot in the ImmutableDB: SlotNo 999999)
; exit 1, stdout empty
```

### 4.2 …but the reviewer's *conclusion* is right, for a better reason

The tip does not come from the analysis. It comes from
`ImmutableDB.getTipPoint`, an STM read of state the DB already holds after
open. So any analysis that **completes** yields the tip, and the cost of the
tip query is the cost of *whichever analysis you pick*.

That makes the question "what is the cheapest analysis?" — and the answer is
**the default one, which does nothing at all**:

- `DBAnalyser/Parsers.hs:151` — `parseAnalysis` ends with `pure OnlyValidation`,
  so *omitting every analysis flag* selects `OnlyValidation` **[source]**.
- `DBAnalyser/Analysis.hs:117` — `go OnlyValidation = mkAnalysis @StartFromPoint $ \_ -> pure Nothing`.
  A literal no-op **[source]**.
- Because it is `StartFromPoint`, `Run.hs:209-216` never calls `openLedgerDB`
  — the `--in-mem` / `--lmdb` / `--lsm` flag is required by the parser but the
  ledger backend is never touched **[source]**.

### 4.3 The one trap: the default validation policy is *not* the cheap one

`Run.hs:260-264` **[source]**:

```haskell
maybeValidateAll = case (analysis, validation) of
  (_, Just ValidateAllBlocks)        -> ChainDB.ensureValidateAll
  (_, Just MinimumBlockValidation)   -> id
  (OnlyValidation, _)                -> ChainDB.ensureValidateAll   -- ← default!
  _                                  -> id
```

Picking `OnlyValidation` *implicitly* also flips the ImmutableDB from
`ValidateMostRecentChunk` (`ImmutableDB/Impl.hs:179`) to `ValidateAllChunks`
(`ChainDB/Impl/Args.hs:156-161`), which re-parses **every chunk on disk**
**[source]**. Measured cost of getting this wrong **[measured]**:

| DB | default validation | `--db-validation minimum-block-validation` |
|---|---|---|
| `db-400k` (3675 blocks) | 0.249 s | 0.141 s |
| `db-big` (11743 blocks) | 0.458 s | 0.085 s |

**So the cheap tip query is exactly:**

```sh
db-analyser --db "$DB" --config "$CFG" --in-mem \
            --db-validation minimum-block-validation
```

No analysis flag, and `minimum-block-validation` is not optional. This is also
strictly cheaper than the `--count-blocks` the reviewer proposed, which still
walks the whole secondary index (§5.1).

---

## 5. Cost — measured

### 5.1 Cost vs chain length (real synthesized DBs)

Medians of 7, seconds **[measured]**:

| command | 251 blk | 501 blk | 1001 blk | 2001 blk | 3675 blk | 11743 blk | marginal µs/block |
|---|---|---|---|---|---|---|---|
| `he tip-info` | 0.136 | 0.135 | 0.126 | 0.105 | 0.147 | 0.146 | ≈ 0 |
| **`dba` no-op + min-validation** | **0.118** | **0.095** | **0.087** | **0.096** | **0.117** | **0.096** | **≈ 0** |
| `dba --count-blocks` | 0.137 | 0.095 | 0.086 | 0.137 | 0.146 | 0.165 | ≈ 2.4 |
| `dba --count-blocks --num-blocks-to-process 0` | 0.108 | 0.106 | 0.078 | 0.106 | 0.127 | 0.115 | ≈ 0 |
| `he list-blocks` | 0.157 | 0.126 | 0.137 | 0.115 | 0.210 | 0.208 | ≈ 4.4 |
| `dba --show-slot-block-no` | 0.128 | 0.146 | 0.175 | 0.449 | 0.517 | **1.737** | ≈ 140 |

Readings:

- The cheap `db-analyser` tip query is **flat and at or below
  `header-extractor tip-info`** across a 47× block range. The polling loop is
  not a problem. *This is the finding that overturns `6e2ebab`.*
- `--count-blocks` is *not* free — it walks every secondary-index entry
  (`Analysis.hs:494-497`, `processAll … (GetPure ())` **[source]**), ≈2.4 µs
  per block. Harmless here, but the no-op analysis is strictly better and
  should be what a ticket uses.
- `--show-slot-block-no` really is the expensive one, ≈140 µs/block — about
  **32× `he list-blocks`'s 4.4 µs/block**. The gap is per-line `Show`
  formatting plus an `hFlush stderr` on every single line
  (`Run.hs:250-258` **[source]**).

### 5.2 Cost vs chain length, isolating the DB-open term

One 3,675-block DB cannot distinguish O(1) from O(N) — the first pass's real
methodological error. To isolate the term that actually grows with chain
length, `db-400k` was copied with filler chunk files hard-linked in up to
1000 / 5000 / 20000 chunks. This is a fair probe of the open path:
`ValidateMostRecentChunk` documents that *"prior chunk and index files are
ignored, even their presence will not be checked"*
(`ImmutableDB/Impl/Types.hs:66-78` **[source]**), so only the directory listing
in `Impl/Validation.hs:153-155` sees them. Block count is held constant at
3,675 throughout.

Medians of 7, seconds **[measured]**:

| command | 83 chunks | 1000 | 5000 | 20000 | µs per chunk file |
|---|---|---|---|---|---|
| `he tip-info` | 0.136 | 0.187 | 0.346 | **1.078** | ≈ 47 |
| `dba` no-op + min-validation | 0.160 | 0.127 | 0.448 | **1.089** | ≈ 47 |

The two curves are **indistinguishable**, which is exactly what the source
predicts: `lib/HeaderExtractor.hs:188-226`'s `withImmDB` is a copy of
`DBAnalyser.Run.analyse`'s open recipe, and the module header says so outright
— *"T007 lands the real `tipInfo` on top of db-analyser's open-and-bracket
recipe (see `Cardano.Tools.DBAnalyser.Run.analyse`)"*
(`lib/HeaderExtractor.hs:30-32` **[source]**). `header-extractor` was derived
from `db-analyser`; there is no cost asymmetry to exploit in either direction.

**Corrected complexity claims:**

- `header-extractor tip-info` is **not O(1) in chain length**. It is
  O(#chunk files) — `listDirectory` over `immutable/` — plus O(one chunk) of
  validation, plus an O(1) `getTipPoint` and one block read for the era. The
  first pass's *"O(1) regardless of whether the chain has 3,000 or 3,000,000
  blocks"* is measurably wrong: same 3,675 blocks, 0.136 s → 1.078 s when the
  chunk count goes 83 → 20,000.
- The cheap `db-analyser` tip query has the **same** complexity, because it is
  the same code.
- **[inference]** At mainnet scale (~4–5k chunk files) both would land around
  0.3–0.5 s per tip query. Not measured on a real mainnet DB; extrapolated from
  the 5000-chunk row.
- **[not measured]** Behaviour past 20,000 chunk files, and behaviour on a cold
  page cache. Every fixture here was warm.

---

## 6. `list-blocks` is exactly reproducible from `db-analyser` — **[DESCOPED — §8.2]**

> Retained as evidence that no *capability* is missing. But reproducing
> `list-blocks` is not what a ticket should do: §8.2 replaces this with a
> single-pass extractor that emits `targets.json` directly and never
> materialises the whole-chain list at all.

`shim.sh` in the runtime root reimplements both call sites over `db-analyser`
alone. The `list-blocks` half is:

```sh
db-analyser --db "$db" --config "$CFG" --in-mem --show-slot-block-no 2>&1 >/dev/null \
  | sed -n 's/^\[[0-9.]*s\] BlockNo [0-9]*\tSlotNo \([0-9]*\)\t\([0-9a-f]*\)$/\1 \2/p' \
  | jq -R -s -c 'split("\n")
                 | map(select(length > 0) | split(" ") | [(.[0]|tonumber), .[1]])
                 | {tag: "Found", data: .}'
```

Against `db-400k`, this and `header-extractor list-blocks` produce
**identical JSON** after `jq -S` normalisation — same 3,675 pairs, same order,
same hashes **[measured]**. The stream split is as the first pass described:
per-block lines on **stderr**, the `ImmutableDB tip:` line on **stdout**.

So `list-blocks` is not a capability gap. It is a ~10-line shell tax plus the
32× per-block cost from §5.1 — and §8.2 shows that per-block cost never binds,
because the extraction is bounded by the ledger replay `amaru snapshot create`
runs on the same chain DB immediately afterwards.

---

## 7. Residue, under the original API-equivalence framing

> **Read §8 first.** This section was written to answer *"what breaks if we
> reproduce `header-extractor`'s API with `db-analyser`?"* Under the amaru-only
> scoping the question changed, and several items below stop being residue
> because nothing requires the API they protect. Each is tagged
> **[DESCOPED — §8.x]** where §8 supersedes it. The untagged items still hold
> and still belong in a ticket. The measurements are unaffected.

Everything here is `[measured]` or `[source]` unless marked.

### 7.1 Era is genuinely lost — **[DESCOPED — §8.3]**

`db-analyser` prints no era anywhere. The producer's predicate
(`scripts/bootstrap-producer.sh:306`) is `era == "Conway" && tip_epoch >= 3`.

The first pass said this is "NO, not a blocker" because the producer already
derives `conway_first_slot` from `TestConwayHardForkAtEpoch`
(`bootstrap-producer.sh:234-238`) and already asserts
`snapshot_slots[0] >= conway_first_slot` (`:336`). That is *half* right, and
the report should have said which half:

- For test-style configs (the testnet_42 fixture, the Antithesis short-epoch
  corpus) the config carries `TestConwayHardForkAtEpoch`, the shell derivation
  is exact, and the era string is redundant. ✅
- For a config **without** that key, `conway_first_slot` defaults to `0`
  (`:235`), so the existing shell guard degrades to vacuously true and the era
  string is the *only* remaining signal. The in-repo comment argues this is
  fine because Conway has long been live on mainnet/preprod/preview — a
  correct-today argument, not an invariant. **[inference]** dropping the era
  check is safe for every chain this repo currently targets, and is a real
  loosening of the guard for any pre-Conway chain.

### 7.2 Output is two `Show` instances, not a CLI contract

Both lines a shim would parse are derived/hand-written `Show` output of
internal debug types, printed through a tracer:

- `ImmutableDB tip: Point (At (Block {blockPointSlot = SlotNo …, blockPointHash = …}))`
  — `show tipPoint` at `Run.hs:229` **[source]**.
- `[0.061643s] BlockNo 0\tSlotNo 10\t<hash>` — `Analysis.hs:244-252`'s
  `instance Show (TraceEvent blk)`, wrapped by the `printf "[%.6fs] %s"` tracer
  at `Run.hs:250-255` **[source]**.

Neither carries any stability promise; either can change in any consensus
release with no deprecation. **Mitigating**: `nix/iog-tools.nix` takes
`db-analyser` from the *same* `ouroboros-consensus` pin the library builds
against, so a drift can only arrive with a deliberate pin bump — and would be
caught by CI **if** the ticket ships a check that runs the shim against a real
synthesized DB. That check is not optional.

### 7.3 Exit codes and error classes

| situation | `header-extractor` | `db-analyser` |
|---|---|---|
| happy path | 0 | 0 |
| chain DB path does not exist | **7**, `chain DB tip is at genesis` | **0**, prints `ImmutableDB tip: Point Origin` |
| chain DB exists but is empty (node still starting) | **7** | **0**, `Point Origin` |
| unparseable `--config` | **7** | **1** |
| read-only chain DB | 7 | 1, `FsInsufficientPermissions` |

Two things follow.

- `rc=7` is a documented contract —
  `specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md:59`
  defines rc=7 as *tool-error: extract*, and
  `tests/test-header-extractor-cli.bats:110-123` asserts it. A shim must map
  `db-analyser`'s rc into that class itself.
- **The genesis case is the sharp edge.** `db-analyser` treats "no blocks yet"
  as success. The producer's polling loop is specifically waiting for a chain
  DB that does not have a tip yet, so a naive shim would silently succeed with
  an empty tip. `shim.sh` handles it (the `sed`/`grep .` pipeline returns 7 on
  `Point Origin`) but only because it was written after seeing the failure. A
  ticket must state this explicitly. Both tools, incidentally, *create*
  `<db>/immutable/00000.{chunk,primary,secondary}` when pointed at a
  nonexistent path — that is shared behaviour, not a regression.

### 7.4 Non-differences (do not put these in the ticket)

- **Read-only filesystems**: `db-analyser` hits the identical
  `FsInsufficientPermissions` on `immutable/*.chunk` **[parent]**, and its
  message still matches the producer's grep at
  `bootstrap-producer.sh:351` **[measured]**. Operational parity.
- **`--config` requirement**: both require it. Not a differentiator; the first
  pass listed it as one.
- **`--in-mem` / `--lmdb` / `--lsm`**: required by the parser, but on the cheap
  path the ledger backend is never opened (§4.2). Cosmetic.
- **Mutating the operator's chain DB**: neither the cheap `db-analyser` path
  nor `he tip-info` changes the file list of a writable chain DB **[measured]**.
- **Image size**: `db-analyser` (69 MB) is **already** in the producer image —
  `nix/bootstrap-producer-image.nix:34` lists `iogTools.db-analyser` in
  `runtimeInputs`, because `amaru create-snapshots` drives it. Removing
  `header-extractor` (63 MB) is a **net shrink**, not a swap.

### 7.5 What actually gets deleted, and what cannot

Deleted: `app/header-extractor/Main.hs` (188 L),
`test/HeaderExtractorSpec.hs` (127 L), `test/Spec.hs` (17 L),
`tests/test-header-extractor-cli.bats` (123 L), `nix/header-extractor.nix`
(22 L), the `header-extractor` executable and `header-extractor-spec`
test-suite stanzas in `amaru-bootstrap.cabal`, the `header-extractor-spec` and
`header-extractor-cli-bats` checks (`nix/checks.nix:291-343`), and the two
matching CI jobs (`.github/workflows/ci.yml:39-40`) — 477 lines of whole files
plus the cabal and nix stanzas.

Gutted, not deleted: `lib/HeaderExtractor.hs` (246 L). `tipInfo`, `listBlocks`,
`getHeader`, `withImmDB`, `eraName` and `renderHeaderHash` all go; what is left
is `NodeConfig` and its Haddock, roughly 10 lines. Call it **≈700 lines
removed** overall.

**Cannot** be deleted: `NodeConfig`. `lib/LedgerStateEmitter.hs:95` and
`app/ledger-state-emitter/Main.hs:19` both import it from `HeaderExtractor`, so
the module has to survive (trimmed) or `NodeConfig` has to move. And there is
**no dependency-set reduction** — `LedgerStateEmitter` already pulls
`ouroboros-consensus:unstable-cardano-tools`, `ImmutableDB`, `ChainDB.Impl.Args`
and the rest on its own **[measured]**.

### 7.6 One capability `db-analyser` has — **[superseded by §8.2, which measured it]**

`--analyse-from SLOT` and `--num-blocks-to-process N` let a caller bound the
listing; `header-extractor list-blocks` always dumps the whole chain. That
would let the producer's preflight ask only for the epoch window it needs.
Caveat: `--analyse-from` resolves via `getHashForSlot` and **fails** unless a
block sits at exactly that slot (`Run.hs:206-208` **[source]**), so it needs a
known slot, not an arbitrary lower bound. §8.2 measured what that caveat costs;
the short answer is that it kills the idea.

---

## 8. Re-scope: only the amaru-facing surface

The producer touches the chain DB to feed `amaru snapshot create`. Everything
else is producer-internal scaffolding a rewrite may redesign or delete, not a
contract to preserve. This section evaluates against that narrower target.

### 8.1 The required surface is exactly 6 `(slot, hash)` pairs — confirmed

The chain DB is touched at four points in `scripts/bootstrap-producer.sh`
**[measured]**, and only one of them produces data that reaches amaru:

| line | what | reaches amaru? |
|---|---|---|
| `:246` `chain_db_alive` | `find` for any `*.chunk` — no tool at all | no |
| `:301` `header-extractor tip-info` | readiness gate | no |
| `:309` `header-extractor list-blocks` | → `preflight-blocks.json` | **yes, indirectly** |
| `:498` `ln -sfn "${CHAIN_DB}/immutable"` | handed to amaru, which runs `db-analyser` itself | n/a |

`preflight-blocks.json` has exactly four readers **[measured]**: `:330`
(per-epoch `max_by(.[0])` → the three `SNAPSHOT_SLOTS`), `:450` (hash for a
snapshot slot), `:456` (`max_by` over blocks with `slot < s` → the parent), and
`:549` (hash for the sidecar filename). Everything they produce is:

- 3 boundary blocks — for each of three consecutive completed epochs, the last
  block, i.e. `max{ block : slot < (E+1) × EPOCH_LENGTH }`
- their 3 parents — for each, the immediately preceding block in chain order

which is **6 `(slot, hash)` pairs.** Confirmed: the operator's claim is exact.

Checking the two artifacts named in the question:

- **`snapshots.json`** (`:470-472`) carries `{epoch, point: "<slot>.<hash>",
  parent_point, url: ""}` — `epoch` is `slot / EPOCH_LENGTH` arithmetic, `url`
  is empty. No new chain data.
- **`history.<slot>.<hash>.json`** — only the *filename* is chain-derived, from
  3 of the 6 pairs. The **content** is built entirely from genesis by
  `ensure_era_history_input` (`:119-142`): `stability_window` = `3 ×
  EPOCH_LENGTH`, `epoch_size_slots` = `EPOCH_LENGTH`, `slot_length` from
  `shelley-genesis.json`, `era_name` a **string literal** `"Conway"`
  (`:136`) **[source]**. No new chain data.

Nothing else derived from `header-extractor` output reaches amaru. The
whole-chain block list is incidental to how the gate was built.

### 8.2 Can `db-analyser` produce just those 6 pairs, bounded?

**Mechanically yes; usefully no — and it does not matter.**

*The bounded primitives work.* Verified on `db-400k` **[measured]**:
`--analyse-from 172731` (a real block) streams **strictly after** the anchor —
first line emitted is slot 172837, the anchor itself is excluded — and
`--num-blocks-to-process 5` truncates it to five lines.

*But they cannot be aimed at an epoch boundary.* `--analyse-from` resolves via
`getHashForSlot`, documented as *"the hash of the block in the given slot"*
(`ImmutableDB/Impl.hs:219-221` **[source]**) — an exact lookup, `Nothing` if
the slot is empty. Epoch boundaries are essentially never occupied: on
`db-400k`, **0 of 4** boundary slots hold a block, and the block-slot gap
distribution is mean 97, median 68, p90 223, max 760 slots **[measured]**. So
an anchor has to be found by descending probe, one `db-analyser` process per
slot tried, at 0.074–0.086 s each **[measured]**.

Costed on `db-big` (11,743 blocks, tip epoch 13, wanting epochs 10–12)
**[measured]**:

- probing down to each of the 6 pairs directly: 3 + 52 + 176 + 138 + 17 + 212 =
  **598 probes ≈ 51 s**
- the cheaper hybrid — probe once for an anchor before epoch 10 (24 probes),
  then one bounded 3-epoch forward scan: **2.517 s**
- one unbounded forward pass that yields all 6 pairs: **1.842 s**

**The bounded hybrid is slower than the full scan.** Break-even **[inference]**:
an anchor costs mean-gap × probe ≈ 97 × 0.075 ≈ 7.3 s, and skipping blocks saves
≈140 µs each, so probing only pays once it skips **≳50,000 blocks**. `db-big`
skips ~9,000. It would pay on a much longer chain; it does not here, and it
makes the cost depend on chain density, which is not a property a producer
should be sensitive to.

*The residue dissolves anyway, for a better reason.* The 140 µs/block figure
never binds, because the extraction is not the expensive thing the producer does
to this chain DB. Measured on the same fixtures **[measured]**:

| | `db-400k` (3,675 blk) | `db-big` (11,743 blk) |
|---|---|---|
| current: `he list-blocks` + the producer's own `jq` | 0.230 s | 0.349 s |
| new: one `db-analyser` pass → `targets.json` | 0.620 s | 1.842 s |
| `db-analyser --store-ledger` to the newest snapshot point | 0.585 s | 1.576 s |

That last row is a proxy for the ledger replay `amaru snapshot create`
immediately performs against the same chain DB (`bootstrap-producer.sh:481-517`
drives it with `--cardano-node-db`). The extraction goes from roughly 22% of one
replay step to roughly 117% of it — it grows, but it stays the same order as
work the pipeline already does and never becomes the bottleneck. **[inference]**
on a chain with real transaction load the replay term grows much faster than the
index scan, so the ratio only improves; the fixtures here carry empty blocks,
which is the *least* favourable case for this argument.

*The extraction itself.* One `db-analyser` pass, no whole-chain JSON
intermediate, reproducing `targets.json` **exactly** — verified byte-identical
against the producer's own `jq` derivation on `db-400k` **[measured]**
(`points.sh` in the runtime root):

```sh
db-analyser --db "$db" --config "$CFG" --in-mem \
            --db-validation minimum-block-validation --show-slot-block-no 2>&1 >/dev/null \
  | sed -n 's/^\[[0-9.]*s\] BlockNo [0-9]*\tSlotNo \([0-9]*\)\t\([0-9a-f]*\)$/\1 \2/p' \
  | awk -v L="$L" -v first="$first" '
      { e = int($1 / L)
        if (e >= first && e <= first+2) { slot[e]=$1; hash[e]=$2; pslot[e]=ps; phash[e]=ph }
        ps=$1; ph=$2 }
      END { for (e = first; e <= first+2; e++)
              printf "%d %d %s %d %s\n", e, slot[e], hash[e], pslot[e], phash[e] }'
```

Note what this removes as a side effect: the parent lookup stops being a
`max_by` over a whole-chain array and becomes the previous line of a stream, and
`preflight-blocks.json` — a multi-megabyte intermediate on any real chain —
stops existing. **§6's `list-blocks` reconstruction is therefore descoped**: it
was solving for an API, not for amaru.

### 8.3 The era gap evaporates

**Nothing is lost.** The era string never reaches amaru. What amaru is told
about the era is the `"era_name": "Conway"` **string literal** the producer
writes into every `history.<slot>.<hash>.json` sidecar and into
`era-history.json` (`bootstrap-producer.sh:136` **[source]**) — unconditionally,
regardless of what `tip-info` reported.

So `tip-info`'s `era` field feeds exactly one thing: the readiness gate at
`:306`. And as a gate it is arguably the *wrong* check already — it tests the
era of the **tip**, while what has to be Conway is the three **snapshot
blocks**, three epochs further back. Those can differ. The producer's other
guard, `snapshot_slots[0] >= conway_first_slot` (`:336`), tests the right thing.

**What the gate becomes**, using only the cheap `db-analyser` tip query:

```
tip_slot   ← db-analyser cheap tip query          (§4.3; 0.087 s, faster than tip-info)
tip_epoch  = tip_slot / EPOCH_LENGTH
gate       = tip_epoch >= 3
             AND the three boundary blocks exist in epochs [tip_epoch-3 .. tip_epoch-1]
             AND boundary_slot[0] >= conway_first_slot     (already config-derived, :234-238)
```

The one honest caveat, unchanged from §7.1: for a config carrying no
`Test*HardForkAtEpoch` key, `conway_first_slot` defaults to `0` (`:235`) and
that clause is vacuous. **[inference]** that is a real loosening for a
hypothetical pre-Conway chain, and irrelevant for every network this repo
targets — the fixture sets `TestConwayHardForkAtEpoch: 0` **[measured]**, and
mainnet/preprod/preview have been Conway for years. If the maintainer wants the
guard back, the honest form is to check the era of a *snapshot* block, which
neither tool offers today and which the config arithmetic already approximates
better than the tip-era string does.

### 8.4 Re-derived residue, amaru-scoped

Everything that survives the re-scoping, and nothing that does not:

1. **Output is two `Show` instances, not a CLI contract** — §7.2 stands
   unchanged, and is now the *only* substantive risk. The point extraction
   parses `Analysis.hs:244-252`'s `Show (TraceEvent blk)`; the gate parses
   `show tipPoint` at `Run.hs:229`. Neither carries a stability promise.
   Mitigated by the shared `ouroboros-consensus` pin, but only if CI proves it.
2. **`Point Origin` must map to "not ready", not "success"** — §7.3's sharp
   edge stands. `db-analyser` exits **0** on an absent or empty chain DB, which
   is exactly the state the polling loop waits through.
3. **`--db-validation minimum-block-validation` is mandatory** — §4.3. Omitting
   it silently selects `ValidateAllChunks` and re-parses the whole DB every
   poll tick.
4. **`NodeConfig` cannot be deleted** — §7.5. `LedgerStateEmitter` imports it.

Dropped from the ticket by the re-scoping: the era gap (§8.3), the
`{"tag":"Found","data":…}` envelope and the whole-chain list reconstruction
(§8.1/§8.2 — the envelope was a `db-server` interop shape, and no
`db-server`-shaped consumer is in this pipeline), and the `rc=7` CLI contract as
an *external* contract (`contracts/bootstrap-producer-cli.md:59` classifies
producer exit codes, and the producer keeps exiting 7 — it just stops needing a
separate binary to do it).

---

## 9. Governance: the constitution leans toward removal

`.specify/memory/constitution.md` Principle II permits mode (b) in-repo
library-consumers such as `header-extractor`, but constrains them:

> Such tools must be trivially replaceable by an upstream binary if and when
> one appears.

and forbids

> Long-lived in-repo replacements for tools that already exist upstream
> (mode (b) is for *missing* features, not *NIH*).

`header-extractor` was introduced (amendment 1.1.0) because
`pragma-org/db-server` pinned an incompatible consensus. That rationale is
about `db-server`, not about `db-analyser`, and §4–§6 show `db-analyser` can
answer both live queries at parity cost. Under a strict reading, the
"replaceable upstream binary" has been shown to exist and Principle II points
at removal.

The counter-argument was: what is missing upstream is not the *data* but a
**stable machine-readable query interface** over the immutable DB, and mode (b)
is precisely "for missing features". **The re-scoping weakens this
considerably.** A JSON contract with defined exit codes is a missing feature
only if something consumes it — and §8.1 establishes that nothing does. What
amaru consumes is 6 pairs; the JSON envelope was shaped for a `db-server`-style
consumer (`app/header-extractor/Main.hs:22-24`) that is not in this pipeline. On
the amaru-only framing, `header-extractor` is closer to the "long-lived in-repo
replacement for a tool that already exists upstream" that Principle II forbids
than to the missing-feature case that permits it.

---

## 10. Recommended next step

Re-sized against the amaru surface. The target is **"produce 6 points + a
readiness gate"**, not "reimplement `list-blocks` and `tip-info` in shell", and
the ticket shrinks accordingly: from six scope items to four, and from
reproducing two JSON contracts to reproducing none.

**Ticket A (S, ~half a day) — prune `get-header`.** Unused under every verdict
and every scoping (§3). Drops the `getHeader` function, its `Main.hs` branch,
its bats case and its hspec case. No behavioural risk, no dependency on
Ticket B. Bank it regardless.

**Ticket B (S–M, ~1 day) — retarget the producer at `db-analyser`.**
Scope, in order:

1. Replace the polling-loop body with the cheap tip query — **no analysis flag**
   plus `--db-validation minimum-block-validation` (§4.3) — and rebuild the gate
   as §8.3 specifies: tip slot only, plus the `conway_first_slot` arithmetic the
   producer already computes at `:234-238`. The `era == "Conway"` clause goes;
   record in a comment that the guard now rests on config arithmetic and why
   that is the more correct check (§8.3).
2. Map `Point Origin` → "not ready" explicitly. `db-analyser` exits **0** on an
   absent or empty chain DB, which is precisely the state the loop waits
   through (§8.4 item 2). This is the failure a naive port gets wrong.
3. Replace `list-blocks` + the four `jq` readers with the single-pass extractor
   in §8.2, emitting `targets.json` directly. `preflight-blocks.json` stops
   existing — the parent lookup becomes the previous line of a stream instead of
   a `max_by` over a whole-chain array.
4. **Ship a nix check that runs the new helper against a real synthesized chain
   DB and asserts the extracted points**, replacing `header-extractor-cli-bats`.
   Still load-bearing, and the re-scoping does not soften it — a bounded or
   single-pass query has the same silent-breakage mode on a consensus pin bump,
   because it parses the same two `Show` instances (§8.4 item 1). Assert the
   6 pairs, not just the exit code; a format drift that yields *zero* parsed
   lines must fail the check.
5. Only then delete the exe, the spec suite, the two checks, the two CI jobs
   and the library functions — keeping `NodeConfig` (§7.5).

**What you get:** ≈700 fewer lines to maintain, one fewer Haskell executable,
two fewer CI jobs, a ~63 MB smaller runtime image, a faster readiness tick
(0.087 s vs 0.115 s), one fewer multi-megabyte intermediate file, and
Principle II satisfied on a reading the re-scoping strengthens (§9).

**What you pay:** ~12 lines of shell parsing two upstream `Show` instances, and
a one-shot extraction that costs 1.842 s instead of 0.349 s on an 11,743-block
DB — against a ledger-replay step of 1.576 s that the pipeline runs immediately
afterwards on the same chain DB (§8.2). Not free; not the bottleneck.

**Sequencing, and the reason to keep Ticket B small.** Upstream
[lambdasistemi/amaru#8](https://github.com/lambdasistemi/amaru/issues/8) proposes
amaru derive these points from `--cardano-node-db` itself. If that lands, the
producer stops needing *any* of this — not `header-extractor`, not the
`db-analyser` shim, not `targets.json`. That is out of scope here, but it argues
for the cheap version of Ticket B rather than an elaborate one: do not build a
polished shell query layer for something that may be deleted wholesale. Ticket A
is safe under either future.

**If you would rather not:** the honest framing is *"replaceable, and the win is
maintenance surface rather than capability or speed, at the cost of parsing
upstream debug output."* Still a defensible "no" — but the two reasons earlier
passes gave for it (the polling-loop cost, and the era gap) are both gone.

---

## 11. Revision history

**First pass — `6e2ebab`, verdict NOT REPLACEABLE.** Its evidence gathering was
sound and reproduces exactly; its reasoning did not. Three defects:

1. **The blocking claim was an unsupported inference presented as fact.** It
   said *"`db-analyser` has no O(1) tip mode. Every call to
   `--show-slot-block-no` traverses the entire Chain DB … each poll tick would
   take tens of seconds to several minutes."* The second sentence is true of
   `--show-slot-block-no` specifically; the first does not follow from it. The
   pass measured one analysis mode and generalised to the tool. The default
   (no-flag) analysis is a literal no-op that still prints the tip, at 0.085–0.118 s
   — at or below `tip-info` — at every size tested (§4, §5.1).
2. **Complexity claims were asserted, not measured.** *"O(1) regardless of
   whether the chain has 3,000 blocks or 3,000,000"* and *"tens of seconds to
   several minutes on full chains"* both rest on a single 3,675-block DB where
   every candidate is dominated by process startup. Holding block count fixed
   and varying chunk count shows `tip-info` is O(#chunk files), not O(1), and
   that `db-analyser`'s cheap path has the identical curve because it is the
   identical code (§5.2).
3. **A factual error in the output contract.** It documented a `count` field in
   `list-blocks` JSON. There is none; the keys are `data` and `tag` (§3.1). An
   implementer would have coded against a field that does not exist.

**Reviewer note NOTE-001** correctly overturned defect 1 and caught defects 2
and 3, but proposed a mechanism that is also wrong: it said the tip line is
*"printed on DB open, and is therefore available from ANY analysis."* It is
printed **after** the analysis body returns (`Run.hs:218-229`), so a run that
fails prints no tip at all (§4.1) — which is exactly why the `Point Origin` /
genesis case in §7.3 needs handling. The note also proposed `--count-blocks`,
which works but still walks the whole secondary index; the no-flag default is
strictly cheaper (§4.3, §5.1).

**Second pass — `de51973`, verdict PARTIALLY REPLACEABLE.** Accepted and
independently reproduced by the reviewer (padded-chunk result confirmed at
≈50 µs/chunk against the ≈47 measured here). Its limitation was not an error but
a framing: it answered *"can `db-analyser` reproduce `header-extractor`'s API?"*
That is the wrong question, because the API has no external consumer.

**Third pass — this revision, verdict REPLACEABLE, amaru-scoped (NOTE-002).**
Re-scoped by the operator to what amaru actually consumes. What changed:

- The required surface is **6 `(slot, hash)` pairs**, confirmed exhaustively
  (§8.1). The whole-chain block list, the `{"tag":"Found"}` envelope and the
  `list-blocks` reconstruction of §6 were all solving for an API nothing
  requires.
- **The era gap dissolved** (§8.3). The second pass called it "genuinely lost".
  It is not lost, because it never arrived: the producer already writes
  `"era_name": "Conway"` as a string literal into the sidecar amaru reads. The
  tip-era string feeds only a producer-internal gate, and as a gate it tests the
  wrong block.
- **The bounded-query hypothesis was tested and failed** (§8.2) — `--analyse-from`
  needs an exact block slot, epoch boundaries are never occupied (0/4 measured,
  mean gap 97 slots), and the probing required makes the bounded path *slower*
  than the full scan (2.517 s vs 1.842 s). The residue it was meant to dissolve
  dissolves anyway, because the extraction is bounded by the ledger replay that
  follows it on the same chain DB.
- The ticket shrank from M to S–M, from six scope items to four.

Two patterns worth keeping. First, from passes one and two: *"tool X cannot do
Y"* is a claim about a tool's whole option surface, and measuring one mode does
not establish it — read the dispatch table before concluding a mode does not
exist. Second, from this pass: **an equivalence assessment inherits the scope of
whatever interface it starts from.** Two passes treated `header-extractor`'s
three subcommands as the specification and asked what it would cost to
reproduce them. The specification was six numbers. Asking *who consumes this*
before asking *can we reproduce this* would have reached the answer sooner and
with a smaller ticket.
