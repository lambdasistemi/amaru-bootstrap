# Research: Snapshot Emitter

Notes for [`plan.md`](./plan.md). Each entry: **Decision** / **Rationale** / **Alternatives considered**.

## R-001: Legacy snapshot encoder lives in upstream's exposed API

**Decision**: encode using
[`Ouroboros.Consensus.Storage.LedgerDB.Snapshots.encodeL`](https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus-cardano/src/unstable-consensus-storage/Ouroboros/Consensus/Storage/LedgerDB/Snapshots.hs)
wrapping
[`Ouroboros.Consensus.Ledger.Extended.encodeExtLedgerState`](https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/Ledger/Extended.hs).

`encodeL :: (l -> Encoding) -> l -> Encoding` writes the legacy single-file
format `[version, tip, chainLength, ledgerState]` with
`snapshotEncodingVersion1` as the version tag.

**Rationale**: both modules are listed in `exposed-modules` of upstream's
public library — confirmed by inspecting the cabal file at the pinned tag.
That means we consume them via plain Cabal `build-depends:
ouroboros-consensus-cardano` with no internal-module access tricks, which
satisfies constitution Principle I.

**Alternatives considered**:
- Hand-roll a CBOR encoder matching the file format reverse-engineered
  from amaru's reader — rejected: reproduces what upstream already
  exports, doubles the maintenance surface, and any encoder drift would
  regress silently.
- Use `Cardano.Tools.DBAnalyser` itself as a library — rejected: that
  module is for analysing chain DBs, not for re-emitting snapshots.

## R-002: amaru reads the full `ExtLedgerState`, not a subset

**Decision**: emit the full extended ledger state. The emitter does NOT
strip header state, AnnTip, or the HardForkCombinator era telescope.

**Rationale**: amaru's
[`crates/amaru/src/cmd/convert_ledger_state.rs`](https://github.com/pragma-org/amaru/blob/d44d84cd9c7a25651c399be96525fe6389e86447/crates/amaru/src/cmd/convert_ledger_state.rs)
decodes the outer CBOR array into `ExtLedgerState`, branches on the HFC
era telescope to handle Byron…Conway, and extracts era history + nonces
from the embedded `ChainDepState`. A trimmed encoding (e.g. only
`LedgerState` or only `NewEpochState`) would fail amaru's decoder before
the era branching even ran.

**Alternatives considered**:
- Encode only `NewEpochState` with a synthetic header state stub —
  rejected: amaru reconstructs nonces from `ChainDepState`, which lives
  in the *header* part of `ExtLedgerState`, not the ledger part.
- Patch amaru to accept the V2InMemory directory directly — rejected by
  constitution Principle II (no extending stock tools) and the project's
  founding rationale (we orchestrate, we don't fork).

## R-003: V2InMemory splits what the legacy format had inline; emitter must merge

**Decision**: read both `state` (the encoded ledger state with `EmptyMK`
table marker) and `tables/tvar` (the encoded `LedgerTables ValuesMK`),
then reconstruct `ExtLedgerState blk ValuesMK` via `withLedgerTables`
before calling `encodeL`.

**Rationale**: V2InMemory's on-disk layout (per [`InMemory.hs`](https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/Storage/LedgerDB/V2/InMemory.hs))
splits the state from the tables to enable separate management of large
UTxO structures (UTxO-HD). The legacy format pre-dates that split and
encodes everything inline. Therefore the emitter must reattach the
tables before it can call the legacy encoder.

The fixture's directory layout confirms the split:

```
86354_db-analyser/
├── meta              (46 bytes — backend tag + checksum, JSON)
├── state             (10229 bytes — encoded ExtLedgerState blk EmptyMK)
└── tables/tvar       (encoded LedgerTables ValuesMK)
```

**Alternatives considered**:
- Encode with `EmptyMK` and let amaru reject it — would produce a
  "format mismatch" verdict still, just slightly different. Defeats the
  Phase 1 purpose.
- Hand-roll the merge with raw CBOR bytestring concatenation — rejected:
  the upstream `withLedgerTables` combinator handles the type-level
  bookkeeping; dropping below it invites future-version-drift bugs.

## R-004: Era selection at runtime

**Decision**: build the emitter against the same `CardanoBlock`
type-instantiation that the chain DB was synthesised from. For our
fixture, that's the standard `CardanoBlock StandardCrypto` from
`ouroboros-consensus-cardano`. The emitter is era-poly only at the type
level; the binary is monomorphised against `CardanoBlock`.

**Rationale**: the directory snapshot's `state` CBOR bytes are typed —
they were produced by `db-analyser` running against `CardanoBlock`. To
decode them we must specialise to the same type. Era branching inside
that type happens via the HFC telescope, not at the emitter level.

**Alternatives considered**:
- Make the emitter read a `--block-type` flag to support non-Cardano
  chains — rejected: out of scope for Phase 1 (FR-001 says no flags).
  Other chain types can be a Phase 2 ticket.

## R-005: Atomic write via temp-then-rename

**Decision**: write encoded bytes to `<out>.tmp` via `BS.writeFile`, then
`renameFile <out>.tmp <out>`.

**Rationale**: SC-003 requires that a failed run leaves the output path
unchanged. `renameFile` is atomic on POSIX (and on macOS/Linux which is
the supported target). Any error path (decode failure, I/O failure)
unwinds before reaching the rename, leaving only the temp file behind
which we clean up via `bracket`.

**Alternatives considered**:
- Lock-and-truncate-and-rewrite — non-atomic; an interrupted run leaves
  a partial file at the canonical path.
- Write to stdout, let the operator redirect — rejected: SC-003 requires
  the tool to manage the output path itself, not delegate to shell
  redirection (which would not be atomic against an existing target).

## R-006: Pre-flight validation order

**Decision**: validate the input directory's structure (FR-008) before
opening any decoder. Specifically: check that the path is a directory,
that `state` exists and is non-empty, that `tables/tvar` exists and is
non-empty. Exit with `input-structurally-invalid` (rc=2) before any
ouroboros-consensus library call.

**Rationale**: FR-008 says decode-time errors should not subsume
structural errors — operators need to see "missing file X" before they
see "decoder failed because state is empty". This is also defensive
against future V2InMemory layout changes (R-001 in spec edge cases).

**Alternatives considered**:
- Lazy validation as part of the decode — rejected: gives ambiguous
  error messages that conflate structural and semantic problems.

## R-007: Output collision handling

**Decision**: refuse with `output-collision` (rc=4) if `<out-file>`
exists and is not a directory. No `--force` flag in Phase 1.

**Rationale**: FR-001 mandates exactly two positional arguments and no
flags; the simplest safe behaviour is refusal. The smoke test's
orchestrator already calls `rm -rf` on its out-dir before invocation, so
this constraint never bites the canonical pipeline.

**Alternatives considered**:
- Silently overwrite — rejected: surprises operators running ad-hoc
  conversions outside the smoke-test pipeline.
- Add `--force` flag — rejected: violates FR-001's no-flags rule.
  Revisit in a Phase 2 ticket if needed.

## R-009: Config loading via `unstable-cardano-tools`, not `cardano-node`

**Decision**: read `config.json` and build `ProtocolInfo (CardanoBlock
StandardCrypto)` via `Cardano.Tools.DBAnalyser.Block.Cardano.mkProtocolInfo`
from the `unstable-cardano-tools` sublibrary of
`ouroboros-consensus-cardano`. From there, `pInfoConfig :: TopLevelConfig`
yields the codec via `configCodec`.

**Rationale**: `db-analyser` itself uses this exact entry point. The
sublibrary is in upstream's `exposed-modules` and depends only on
consensus + ledger + crypto — NOT on `cardano-node`. This means the
emitter pulls in zero extra forks and respects the project's "no
cardano-api" memory rule. The function handles all 5 era genesis
files (Byron / Shelley / Alonzo / Conway / Dijkstra) automatically by
following relative paths in the JSON config.

**Trade-off**: this expands FR-001 from two positional args to three —
the config path is now an explicit input. Updated spec.md, contracts,
and data-model accordingly. The smoke-test orchestrator already has
the config path as a free variable (it passes the same file to
`db-synthesizer` and `db-analyser`), so the orchestrator change is
still a one-line insertion.

**Alternatives considered**:
- Use `cardano-node`'s `parseNodeConfigurationFP` — heavier
  dependency tree, transitively pulls in `cardano-api` which the
  constitution memory specifically advises against
  (`feedback_no_cardano_api.md`). Rejected.
- Hand-roll a JSON parser for the config file — feasible but
  reproduces upstream's logic, drifts on every consensus version
  bump. Rejected as Principle II violation in spirit (we'd be
  duplicating stock-tool behaviour).
- Hard-code testnet params at compile time — single-purpose binary,
  unusable for any other testnet. Rejected: the project's pivot
  goal is a reusable bridge tool, not a one-shot.

## R-008: Determinism

**Decision**: rely on `encodeL` and `encodeExtLedgerState` being
deterministic functions of their inputs. No timestamps, no random nonces,
no path-dependent fields injected by the emitter.

**Rationale**: `encodeL` is pure; `encodeExtLedgerState` is pure; the
emitter's only addition is reading 2 files and writing 1 file, none of
which introduces non-determinism. SC-005 holds by composition.

**Alternatives considered**:
- Add a creation-timestamp header — rejected: breaks SC-005 and adds no
  value for the Phase 1 hypothesis.
