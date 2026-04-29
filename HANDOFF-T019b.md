# Handoff: T019b — `ledger-state-emitter` design review

**Status**: scaffolding-stage. No code committed beyond [`cc82a8d`](https://github.com/lambdasistemi/amaru-bootstrap/commit/cc82a8d) (the spec patch). The previous session's exploratory `LedgerStateEmitter.hs` and `app/ledger-state-emitter/` were deleted; the cabal file was reverted. Stack tip is `T019b-spec`.

## What we're building

R-011's `ledger-state-emitter` replaces `db-analyser --store-ledger --v2-in-mem` + `snapshot-converter Mem -> Legacy` with a **single in-repo Haskell tool** that emits a Legacy `ExtLedgerState` envelope amaru's `import-ledger-state` accepts.

Why we need it (proven byte-by-byte in this session):

- `cardano-ledger-shelley-1.16.0.0/src/Cardano/Ledger/Shelley/LedgerState/Types.hs:267` deliberately encodes `UTxOState.utxosUtxo` via `encodeMap encodeMemPack encodeMemPack`, producing CBOR `bytes:bytes` pairs.
- amaru's `MemoizedTransactionOutput::decode` (`crates/amaru-kernel/src/cardano/memoized/transaction_output.rs:57`) only accepts `Type::Map` (`{0:addr, 1:value, ...}`) or `Type::Array` (legacy `[addr, value, ?datum]`). It rejects `Type::Bytes`.
- cardano-api's `encodeLedgerState` reuses `Shelley.encodeShelleyLedgerState` and produces the same MemPack form. The de-MemPacking on amaru's canonical pipeline happens inside ogmios's read path, not in any standalone consensus serialiser.

So we need to emit the Legacy envelope ourselves with a non-MemPack UTxO encoding.

## Critical discovery from this session (changes the design)

`DecShareCBOR` for both `TxIn` (`cardano-ledger-core-1.17.0.0/src/Cardano/Ledger/TxIn.hs:117-122`) and `BabbageTxOut`/`ConwayTxOut` (`cardano-ledger-babbage-1.12.0.0/src/Cardano/Ledger/Babbage/TxOut.hs:529-539`) is **dual-format**:

```haskell
-- TxIn
instance DecShareCBOR TxIn where
  decShareCBOR _ =
    peekTokenType >>= \case
      TypeBytes -> decodeMemPack
      TypeBytesIndef -> decodeMemPack
      _ -> decCBOR

-- BabbageTxOut (ConwayTxOut delegates here)
instance ... => DecShareCBOR (BabbageTxOut era) where
  decShareCBOR credsInterns = do
    txOut <- peekTokenType >>= \case
      TypeBytes -> decodeMemPack
      TypeBytesIndef -> decodeMemPack
      _ -> decCBOR
    pure $! internBabbageTxOut (interns credsInterns) txOut
```

**Implication**: cardano-ledger's decoders accept BOTH the MemPack form (current) AND the canonical form. So if we emit canonical bytes:

- amaru's reader (which only accepts canonical) → ✓
- any future cardano-ledger consumer using `DecShareCBOR` (queries, ogmios, db-analyser load) → ✓ (it already handles both formats)
- consensus's `decodeDiskExtLedgerState` (which delegates to `DecShareCBOR (UTxOState era)` → `DecShareCBOR (UTxO era)` → `decodeMap decNoShareCBOR (decShareCBOR credsInterns)`) → ✓

**This means our emitter does not need to be byte-identical to snapshot-converter's Legacy output. It needs to be a valid `ExtLedgerState` envelope where the UTxO map entries are canonical CBOR (TxIn/TxOut) instead of CBOR-bytes-of-MemPack.**

## Design choices to validate with reviewer

### Choice 1: Where does the emitter source the ledger state from?

**Option 1A — read the Mem snapshot produced by `db-analyser`** (mirrors what `snapshot-converter` does):
- Run `db-analyser --store-ledger SLOT --v2-in-mem` first (orchestrator phase 1)
- `ledger-state-emitter` then `V2.loadSnapshot rr ccfg fs ds` reads the Mem dir
- Get `(ExtLedgerState blk EmptyMK, LedgerTables ValuesMK)`, stow tables, encode

**Option 1B — drive the ledger DB ourselves** (replaces db-analyser entirely):
- Open ImmutableDB read-only (we already do this in `HeaderExtractor`)
- Use `LedgerDB.ledgerDbCheckpoints` or similar to fold from genesis to target slot
- Same encoding step

Trade-off:
- 1A is shorter (~50 lines): reuse upstream Mem-load. Still requires `db-analyser` in the runtime image.
- 1B drops `db-analyser` from runtime image (R-004 image-size win) but adds ~200 lines of LedgerDB orchestration code we'd own.

**Current bias**: 1A. R-011 already says "replaces db-analyser + snapshot-converter" but the orchestrator can keep db-analyser as the slot-locator and let the emitter take over from there. Image layout R-004 would shrink to "amaru + ledger-state-emitter + header-extractor + db-analyser + jq + bash"; snapshot-converter is dropped, db-analyser stays.

If reviewer prefers 1B, image drops to "amaru + ledger-state-emitter + header-extractor + jq + bash" — full R-011 vision.

### Choice 2: How do we override the inner `EncCBOR (UTxOState era)`?

The full encoding chain consensus → cardano-ledger:

1. `encodeDiskExtLedgerState ccfg :: ExtLedgerState blk EmptyMK -> Encoding`
2. → `encodeExtLedgerState (encodeDisk @blk cfg) ... :: ExtLedgerState blk mk -> Encoding`
3. → `EncodeDisk (HardForkBlock xs) (LedgerState (HardForkBlock xs) EmptyMK)` uses `encodeTelescope` + `hcmap pSHFC ...` over per-era `encodeDisk`
4. → for each Shelley-family era, per-era `EncodeDisk` is `encodeShelleyLedgerState`
5. → `encodeShelleyLedgerState` calls `toCBOR shelleyLedgerState :: NewEpochState era -> Encoding`
6. → `EncCBOR (NewEpochState era)` calls `encCBOR es :: EpochState era -> Encoding`
7. → `EncCBOR (EpochState era)` calls `encCBOR esLState :: LedgerState era -> Encoding`
8. → `EncCBOR (LedgerState era)` calls `encCBOR lsUTxOState :: UTxOState era -> Encoding`
9. → **HERE**: `EncCBOR (UTxOState era)` uses MemPack encoding

We need to swap step 9 with a canonical `!> To utxosUtxo` (which delegates to `EncCBOR (UTxO era)` = `deriving newtype EncCBOR (Map TxIn (TxOut era))` = canonical map).

**Option 2A — mirror the encoder chain (top-down)**:

Write top-level functions for each level (5-9), each ~10 lines, plus a custom typeclass `CanonicalEncodeLedgerStateDisk` to dispatch per-era through `hcmap`. Approx 100-150 lines total.

```haskell
class CanonicalEncodeLedgerStateDisk blk where
  encCanonicalLedgerStateDisk
    :: CodecConfig blk -> LedgerState blk EmptyMK -> Encoding

instance CanonicalEncodeLedgerStateDisk ByronBlock where
  encCanonicalLedgerStateDisk = encodeDisk

instance ShelleyCompatible proto era => CanonicalEncodeLedgerStateDisk (ShelleyBlock proto era) where
  encCanonicalLedgerStateDisk _ = encodeShelleyLedgerStateCanonical

encodeShelleyLedgerStateCanonical ShelleyLedgerState{..} =
  encodeVersion 2 $ mconcat
    [ encodeListLen 3
    , encodeWithOrigin encodeShelleyTip shelleyLedgerTip   -- copy (~15 lines)
    , encNewEpochStateCanonical shelleyLedgerState
    , encodeShelleyTransition shelleyLedgerTransition       -- copy (~5 lines)
    ]

encNewEpochStateCanonical (NewEpochState e bp bc es ru pd av) =
  encodeListLen 7 <> encCBOR e <> encCBOR bp <> encCBOR bc
                  <> encEpochStateCanonical es
                  <> encCBOR ru <> encCBOR pd <> encCBOR av

-- ... etc down to encUTxOStateCanonical
encUTxOStateCanonical UTxOState{..} =
  encodeListLen 6
    <> encCBOR utxosUtxo  -- canonical via deriving newtype Map encoder
    <> encCBOR utxosDeposited <> encCBOR utxosFees
    <> encCBOR utxosGovState <> encCBOR utxosInstantStake
    <> encCBOR utxosDonation
```

Risk: cardano-ledger version drift. Adding/reordering a field upstream silently produces wrong encoding here — and the discrepancy may not surface in any test.

**Option 2B — CBOR byte-transcode**:

Use upstream `encodeDiskExtLedgerState` to produce the standard byte-stream, then walk the CBOR token-stream looking for the `utxosUtxo` map. For each entry: `unpackByteString @TxIn` + `encCBOR txin` for the key, `unpackByteString @TxOut` + `encCBOR txout` for the value. Pass-through everything else.

Implementation:
- Use `cborg`'s `Codec.CBOR.Read.deserialiseFromBytes` + `Codec.CBOR.Decoding` token-by-token walk
- Maintain a small state machine tracking "depth" within the ExtLedgerState envelope to know when we're inside `UTxOState.utxosUtxo`
- Approx 100-200 lines, isolated to byte-walking code

Risk: outer envelope structure changes (new field added to ExtLedgerState / LedgerState / UTxOState). Less surface than 2A because we only navigate _down to_ utxosUtxo, not encode every field.

**Option 2C — round-trip via decode-then-custom-encode**:

Use upstream `decodeDiskExtLedgerState` to fully decode into Haskell types. Re-encode with our custom encoder (Option 2A's per-level functions). Combines 2A's risk (need full per-level mirroring on encode side) with the cost of decode.

**Current bias**: 2A. The chain is mechanical, each level is 5-10 lines, and the failure modes are loud (compile errors when fields change).

### Choice 3: What constraints does the era have to satisfy?

The orchestrator's pre-flight (R-010) blocks until `tip.era >= Conway`. So the ACTIVE era at snapshot time is always Conway. But the HardForkBlock telescope encoding still requires per-era encoders for ALL eras (Byron through Conway), even if they're never invoked at runtime (only the `Current` era's encoder runs; `Past` eras encode bounds only).

So the typeclass `CanonicalEncodeLedgerStateDisk` needs an instance for every era in `CardanoEras c`. Practical impact: minimal — every Shelley-family era uses the same `encodeShelleyLedgerStateCanonical`, parameterised by `proto`+`era`. Byron is unchanged from upstream.

## Concrete proposal for the reviewer to react to

1. **Source from Mem snapshot** (Option 1A) — keep `db-analyser` as a build-time component, drop `snapshot-converter`. Re-evaluate 1B once 1A works.
2. **Mirror the encoder chain** (Option 2A) — explicit per-level functions plus a `CanonicalEncodeLedgerStateDisk` class for telescope dispatch.
3. **Constrain to `era ~ ConwayEra StandardCrypto` in the active era only** — non-Conway eras get a stub encoder that errors at runtime (telescope only invokes the `Current` era's encoder, so non-Conway never runs, but compile-time we need a placeholder).

Counter-questions for the reviewer:

- Is mirroring 5 levels of cardano-ledger's `EncCBOR` instances acceptable, or should we lean on byte-transcode (2B) for upstream-drift safety?
- Should we drop `db-analyser` entirely (1B) and own the ledger-DB walk for full image-size win?
- Are there cardano-ledger consumers (queries, db-sync, kupo, ogmios) we know rely on the MemPack-bytes form? If yes, we might want emit a separate `--canonical` flag rather than always emitting canonical.

## What's in the repo right now

- `specs/003-amaru-bootstrap-producer/research.md#r-011` — full design rationale, alternatives considered
- `specs/003-amaru-bootstrap-producer/data-model.md` — state diagram updated, rc=4 marked reserved
- `specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md` — rc registry updated
- `specs/003-amaru-bootstrap-producer/tasks.md#T019b` — implementation contract
- `WIP.md` — original handoff (slightly stale on the dual-format decoder discovery; this doc supersedes its "Two viable implementation shapes" section)
- `scripts/bootstrap-producer.sh` — fully wired with `phase_dump` + `phase_emit` (both currently calling db-analyser/snapshot-converter); awaits collapse into a single `phase_emit` calling the new tool
- No `lib/LedgerStateEmitter.hs`, no `app/ledger-state-emitter/`, no cabal stanzas — clean slate for the implementation patch

## Key references for the reviewer

| File | What's in it |
|------|--------------|
| `cardano-ledger-shelley-1.16.0.0/src/Cardano/Ledger/Shelley/LedgerState/Types.hs:259-272` | The MemPack-encoder for `UTxOState` (the bug source) |
| `cardano-ledger-core-1.17.0.0/src/Cardano/Ledger/State/UTxO.hs:111` | `EncCBOR (UTxO era)` — canonical, via `deriving newtype` from `Map` |
| `cardano-ledger-core-1.17.0.0/src/Cardano/Ledger/TxIn.hs:117-122` | TxIn dual-format `DecShareCBOR` (proves canonical-encoder is round-trip safe) |
| `cardano-ledger-babbage-1.12.0.0/src/Cardano/Ledger/Babbage/TxOut.hs:529-539` | TxOut dual-format `DecShareCBOR` |
| `ouroboros-consensus-cardano/src/shelley/Ouroboros/Consensus/Shelley/Ledger/Ledger.hs:727-741` | `encodeShelleyLedgerState` — what we mirror |
| `ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/HardFork/Combinator/Serialisation/SerialiseDisk.hs:121-127` | HardForkBlock's per-era telescope dispatch |
| `ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/HardFork/Combinator/Serialisation/Common.hs:336-352` | `encodeTelescope` definition |
| `ouroboros-consensus-cardano/app/snapshot-converter.hs:162-237` | The `load` + `store` functions we'd reuse for Mem→Legacy in Option 1A |
| `crates/amaru-kernel/src/cardano/memoized/transaction_output.rs:57` (amaru repo) | What amaru expects on the read side |

The pinned consensus source tree (with all the above paths under it) is at `/nix/store/5rxbhk0apmhzfd1w4wwgn5d83h5z2d4k-ouroboros-consensus-8e3afe1` (cachable on this machine; SHA `8e3afe1` matches `cabal.project`).

## Diagnostic / fixture state

- `/tmp/t019-diag/chain-db` — synthesised testnet_42 chain DB at `-s 300000` (era-ready, tip ~285k slots)
- `/tmp/t019-diag/snapshots/259292.*.cbor` — the Legacy slice produced by snapshot-converter; 16397 bytes
- `/tmp/t019-diag/probe/` — Rust binary using minicbor + amaru-mirror types that decodes the slice byte-by-byte (regression smoke-check for slice-shape changes)
- `/tmp/shelley-src/`, `/tmp/core-src/`, `/tmp/babbage-src/`, `/tmp/conway-src/` — extracted cardano-ledger sources

Re-synthesising from scratch (if `/tmp` was wiped):
```bash
cd /code/amaru-bootstrap-003-spec
nix build .#checks.x86_64-linux.bootstrap-producer-bats   # produces both fixtures
```
