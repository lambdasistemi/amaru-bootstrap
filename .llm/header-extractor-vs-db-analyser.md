# Assessment: replacing `header-extractor` with `db-analyser`

Upstream issue [lambdasistemi/amaru#8](https://github.com/lambdasistemi/amaru/issues/8)
asked whether the in-repo Haskell executable `header-extractor` can be dropped
in favour of stock `db-analyser`
(`ouroboros-consensus-exe-db-analyser`, already vendored as `iogTools.db-analyser`).

**Exploratory only — nothing here is implemented.**

> This file replaces the first-pass assessment committed as `6e2ebab`, which
> reached the opposite verdict on a claim that does not survive testing. See
> [Revision history](#revision-history).

---

## 1. Verdict

**Partially replaceable — replaceable in capability and in cost, with a small
but real ergonomic residue.**

| query | replaceable by `db-analyser`? | evidence |
|---|---|---|
| `tip-info` slot + hash | **yes, at cost parity** | §4, §5 |
| `tip-info` era | **no** — `db-analyser` never prints an era | §7.1 |
| `list-blocks` | **yes, byte-identical JSON** via ~10 lines of shell | §6 |
| `get-header` | not needed — unused by the producer | §3 |

The first pass's blocking argument — *"`db-analyser` has no O(1) tip mode, so
each poll tick would take tens of seconds to minutes"* — is **false**. There is
a `db-analyser` invocation that prints the tip and does no other work, and it
is measurably **as fast as or faster than** `header-extractor tip-info` at every
DB size tested (§5).

The honest complexity picture is also not what either the first pass or its
reviewer assumed: **neither tool has an O(1) tip query.** Both pay the same
ImmutableDB-open cost, which grows linearly in the number of chunk *files* on
disk, because they run literally the same open code path (§4.3, §5.2).

Recommendation: §9. Short version — it is a legitimate cleanup that the
constitution actively favours, worth about an M-sized ticket, but it is a
maintenance-surface trade (≈700 lines of Haskell + bats deleted) rather than a
performance or capability win, and it converts a typed Haskell contract into
shell that scrapes two `Show` instances.

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
throughout. All timings are **medians of 7 runs after one warm-up**; treat
differences under ~30 ms as noise. Scripts: `bench.sh`, `synth.sh`, `shim.sh`
in the runtime root.

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
The `tag: "Found"` is therefore an interop shape, not decoration — anything
replacing it has to keep emitting it.

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

## 6. `list-blocks` is exactly reproducible from `db-analyser`

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
32× per-block cost from §5.1.

---

## 7. The real residue

What a removal ticket would actually have to solve. Everything here is
`[measured]` or `[source]` unless marked.

### 7.1 Era is genuinely lost

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

### 7.6 One capability `db-analyser` has and `header-extractor` does not

`--analyse-from SLOT` and `--num-blocks-to-process N` let a caller bound the
listing; `header-extractor list-blocks` always dumps the whole chain. That
would let the producer's preflight ask only for the epoch window it needs.
Caveat: `--analyse-from` resolves via `getHashForSlot` and **fails** unless a
block sits at exactly that slot (`Run.hs:206-208` **[source]**), so it needs a
known slot, not an arbitrary lower bound.

---

## 8. Governance: the constitution leans toward removal

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

The counter-argument, also legitimate: what is missing upstream is not the
*data* but a **stable machine-readable query interface** over the immutable DB.
`db-analyser` exposes debug traces. Mode (b) is precisely "for missing
features", and a JSON contract with defined exit codes is arguably one. This
is a judgement call for the maintainer, not something this assessment can
settle from evidence.

---

## 9. Recommended next step

**Do the removal, as one M-sized ticket — but bank the S-sized part first.**

**Ticket A (S, ~half a day) — prune `get-header`.** Unused under every verdict
(§3). Drops the `getHeader` function, its Main.hs branch, its bats case and its
hspec case. No behavioural risk. Do this regardless of what happens to Ticket B.

**Ticket B (M, ~1–2 days) — replace both call sites with `db-analyser`.**
Scope, in order:

1. Add a `chain_db_query` helper in `scripts/bootstrap-producer.sh` wrapping
   the two invocations from `shim.sh`.
   Tip: **no analysis flag** plus `--db-validation minimum-block-validation`
   (§4.3 — getting this wrong silently reintroduces an O(N) full validation).
2. Map `Point Origin` → rc=7 explicitly (§7.3). This is the failure the tests
   must cover; it is the one a naive port gets wrong.
3. Replace the `era == "Conway"` clause with the existing
   `conway_first_slot` derivation, and add an explicit comment recording that
   this is a loosening for configs lacking `TestConwayHardForkAtEpoch` (§7.1).
4. Keep the `{"tag":"Found","data":…}` envelope byte-for-byte — it is the
   db-server-portable interop shape (§3.1).
5. **Ship a nix check that runs the new helper against a real synthesized
   chain DB and asserts the parsed output**, replacing `header-extractor-cli-bats`.
   Without it, a consensus pin bump silently breaks the producer at runtime
   (§7.2). This is the load-bearing part of the ticket; everything else is
   deletion.
6. Only then delete the exe, the spec suite, the two checks, the two CI jobs
   and the three library functions — keeping `NodeConfig` (§7.5).

**What you get:** ≈700 fewer lines to maintain, one fewer Haskell executable,
two fewer CI jobs, a ~63 MB smaller runtime image, and Principle II satisfied.

**What you pay:** ~15 lines of shell parsing two upstream `Show` instances, a
weaker era guard, and `list-blocks` at ~140 µs/block instead of ~4.4 µs/block
(§5.1). At this repo's working scale — testnet_42 fixtures at 3,675 blocks, the
Antithesis short-epoch corpus at ~3,000 slots — that is 0.5 s versus 0.2 s and
does not matter. **[inference]** it would matter on a chain of ≥10⁶ blocks
(≈140 s versus ≈4.4 s), which this producer does not currently target.

**If you would rather not:** the honest framing is *"replaceable, but the win
is maintenance surface rather than capability or speed, and it trades a typed
Haskell contract for shell over unstable debug output."* That is a defensible
"no". What is **not** defensible is the first pass's reason for saying no.

---

## 10. Revision history

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

The pattern worth keeping from all three passes: *"tool X cannot do Y"* is a
claim about a tool's whole option surface, and measuring one mode does not
establish it. Read the dispatch table before concluding a mode does not exist.
