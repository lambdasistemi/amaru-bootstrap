{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : HeaderExtractor
Description : Library API for the in-repo chain-DB query tool
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per [research.md
R-001](../specs/003-amaru-bootstrap-producer/research.md#r-001-header-extraction-without-pragma-orgdb-server)
and
[R-009/R-010](../specs/003-amaru-bootstrap-producer/research.md#r-009-wait-strategy--poll-immutable-db-tip-info),
this module exposes the three pure-IO functions consumed by the
@header-extractor@ executable and the orchestrator's polling loop:

  * 'tipInfo' — open only the immutable DB and return the tip's slot,
    era and block hash.
  * 'listBlocks' — iterate the immutable DB chunks and return
    @(slot, hash)@ pairs in chain order.
  * 'getHeader' — fetch one header's CBOR bytes by @slot.hash@.

T007 lands the real 'tipInfo' on top of db-analyser's open-and-bracket
recipe (see @Cardano.Tools.DBAnalyser.Run.analyse@); 'listBlocks' and
'getHeader' remain stubs until T008-T009.
-}
module HeaderExtractor
    ( -- * Types
      TipInfo (..)
    , NodeConfig (..)
    , PrevEpochTail (..)

      -- * Library API
    , tipInfo
    , listBlocks
    , getHeader
    , getHeaderByHash
    , prevEpochTailHeader
    ) where

import Cardano.Tools.DBAnalyser.Block.Cardano
    ( Args (CardanoBlockArgs, configFile, threshold)
    )
import Cardano.Tools.DBAnalyser.HasAnalysis
    ( HasProtocolInfo (mkProtocolInfo)
    )
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Control.ResourceRegistry
    ( ResourceRegistry
    , withRegistry
    )
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Ouroboros.Consensus.Block
    ( HeaderHash
    , Point (BlockPoint, GenesisPoint)
    , RealPoint (RealPoint)
    , unSlotNo
    )
import Ouroboros.Consensus.Storage.Common
    ( BlockComponent (GetBlock, GetHash, GetRawHeader, GetSlot)
    )
import Ouroboros.Consensus.Cardano.Block
    ( CardanoBlock
    , HardForkBlock
        ( BlockAllegra
        , BlockAlonzo
        , BlockBabbage
        , BlockByron
        , BlockConway
        , BlockMary
        , BlockShelley
        )
    , StandardCrypto
    )
import Ouroboros.Consensus.Config (configStorage)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (OneEraHash)
    )
import qualified Ouroboros.Consensus.Node as Node
import qualified Ouroboros.Consensus.Node.InitStorage as Node
import Ouroboros.Consensus.Node.ProtocolInfo
    ( ProtocolInfo (pInfoConfig, pInfoInitLedger)
    )
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import qualified Ouroboros.Consensus.Storage.ChainDB.Impl.Args as ChainDB
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmutableDB
import qualified Ouroboros.Consensus.Storage.LedgerDB as LedgerDB
import qualified Ouroboros.Consensus.Storage.LedgerDB.V2.Backend as V2Backend
import qualified Ouroboros.Consensus.Storage.LedgerDB.V2.InMemory as V2InMemory

-- | The path to the cardano-node @config.json@. Referenced genesis
-- files (byron / shelley / alonzo / conway) are resolved relative to
-- the file's directory by 'mkProtocolInfo'.
newtype NodeConfig = NodeConfig {nodeConfigPath :: FilePath}
    deriving stock (Show, Eq)

-- | The chain DB's immutable tip, era-tagged. The JSON encoding is
-- the contract surfaced by @header-extractor tip-info@ — see
-- [contracts/bootstrap-producer-cli.md](../specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md).
data TipInfo = TipInfo
    { slot :: Integer
    , era :: Text
    , blockHash :: Text
    }
    deriving stock (Show, Eq, Generic)

instance Aeson.ToJSON TipInfo

instance Aeson.FromJSON TipInfo

-- | Open only the immutable DB and return the era-tagged tip.
tipInfo :: FilePath -> NodeConfig -> IO TipInfo
tipInfo dbDir nc = withImmDB dbDir nc $ \_ immDB -> do
    tipPt <- atomically $ ImmutableDB.getTipPoint immDB
    case tipPt of
        GenesisPoint ->
            error "HeaderExtractor.tipInfo: chain DB tip is at genesis"
        BlockPoint s h -> do
            block <-
                ImmutableDB.getKnownBlockComponent
                    immDB
                    GetBlock
                    (RealPoint s h)
            pure
                TipInfo
                    { slot = fromIntegral (unSlotNo s)
                    , era = eraName block
                    , blockHash = renderHeaderHash h
                    }

-- | Iterate the immutable DB and return @(slot, hash)@ pairs in
-- chain order. Hashes are lower-case hex strings.
listBlocks :: FilePath -> NodeConfig -> IO [(Integer, Text)]
listBlocks dbDir nc = withImmDB dbDir nc $ \registry immDB -> do
    iter <-
        ImmutableDB.streamAll
            immDB
            registry
            ((,) <$> GetSlot <*> GetHash)
    pairs <- ImmutableDB.iteratorToList iter
    pure
        [ (fromIntegral (unSlotNo s), renderHeaderHash h)
        | (s, h) <- pairs
        ]

{- | Fetch a single header's CBOR bytes addressed by its
@(slot, hash)@ pair. The bytes returned are the on-disk header
exactly as @cardano-node@ wrote them — no re-encoding.
-}
getHeader :: FilePath -> NodeConfig -> Integer -> Text -> IO ByteString
getHeader dbDir nc s hHex = do
    sbs <- case B16.decode (TE.encodeUtf8 hHex) of
        Right bs -> pure (SBS.toShort bs)
        Left err ->
            error $
                "HeaderExtractor.getHeader: invalid hex hash "
                    <> show hHex
                    <> ": "
                    <> err
    withImmDB dbDir nc $ \_ immDB ->
        LBS.toStrict
            <$> ImmutableDB.getKnownBlockComponent
                immDB
                GetRawHeader
                (RealPoint (fromIntegral s) (OneEraHash sbs))

{- | Fetch a single header's CBOR bytes addressed by hash alone, by
scanning the immutable chain DB to resolve the slot. Used by
bootstrap-producer to materialise headers referenced by hash from a
ledger snapshot's nonce fields (e.g. @praosStateLabNonce@) without
the caller needing to know the slot upfront.

Errors out with a descriptive message when no immutable block
matches @hHex@.
-}
getHeaderByHash :: FilePath -> NodeConfig -> Text -> IO ByteString
getHeaderByHash dbDir nc hHex = do
    pairs <- listBlocks dbDir nc
    case lookup hHex [(h, s) | (s, h) <- pairs] of
        Just s -> getHeader dbDir nc s hHex
        Nothing ->
            error $
                "HeaderExtractor.getHeaderByHash: no immutable block with hash "
                    <> show hHex

{- | The boundary header that the orchestrator must ship in the
bundle so amaru's evolve_nonce can resolve @parent_nonces.tail@ at
the first post-bootstrap epoch transition.

@slot@ and @hash@ identify the block; @cbor@ is the on-disk header
CBOR (suitable for writing to a @header.<slot>.<hash>.cbor@ file
that @amaru import-headers@ can read).
-}
data PrevEpochTail = PrevEpochTail
    { tailSlot :: Integer
    , tailHash :: Text
    , tailCbor :: ByteString
    }

{- | Resolve the "previous-epoch tail" boundary block given a tip
slot and the chain's epoch length. Returns the highest-slot block
whose slot is strictly less than the current epoch's first slot
(@tip - tip mod epochLength@) — i.e. the actual last header of the
previous epoch, NOT the @lab@ value (which is its parent_hash).

Returns @Nothing@ when the tip is itself in epoch 0 (no previous
epoch boundary exists).

Used by bootstrap-producer's @phase_extract@ to set the bundle's
@nonces.tail@ to a value that amaru's @load_header@ can resolve at
the next epoch boundary, and to ensure the corresponding header is
in the bundle's @headers/@ directory.
-}
prevEpochTailHeader
    :: FilePath
    -> NodeConfig
    -> Integer
    -- ^ tip slot
    -> Integer
    -- ^ epoch length in slots
    -> IO (Maybe PrevEpochTail)
prevEpochTailHeader dbDir nc tipSlot epochLength
    | epochLength <= 0 = pure Nothing
    | otherwise = do
        let currentEpochStart = tipSlot - (tipSlot `mod` epochLength)
            maxSlot = currentEpochStart - 1
        if maxSlot < 0
            then pure Nothing
            else do
                pairs <- listBlocks dbDir nc
                case reverse (filter (\(s, _) -> s <= maxSlot) pairs) of
                    [] -> pure Nothing
                    (s, h) : _ -> do
                        bytes <- getHeader dbDir nc s h
                        pure
                            ( Just
                                PrevEpochTail
                                    { tailSlot = s
                                    , tailHash = h
                                    , tailCbor = bytes
                                    }
                            )

-- ─── Internals ───────────────────────────────────────────────────

-- | Bracket-open only the immutable DB. Reuses the ChainDB args path
-- (db-analyser's recipe) and projects out @cdbImmDbArgs@ — we never
-- touch the LedgerDB.
--
-- The access pattern is immutable-only, but node-10.7.1 consensus
-- validation opens chunk files through APIs that require a writable
-- filesystem. The Docker mount therefore must not be @:ro@.
withImmDB
    :: FilePath
    -> NodeConfig
    -> ( ResourceRegistry IO
         -> ImmutableDB.ImmutableDB IO (CardanoBlock StandardCrypto)
         -> IO a
       )
    -> IO a
withImmDB dbDir (NodeConfig configPath) action = do
    pInfo <-
        mkProtocolInfo
            CardanoBlockArgs
                { configFile = configPath
                , threshold = Nothing
                }
    let cfg = pInfoConfig pInfo
        genesisLedger = pInfoInitLedger pInfo
        shfs = Node.stdMkChainDbHasFS dbDir
        chunkInfo = Node.nodeImmutableDbChunkInfo (configStorage cfg)
        flavargs =
            LedgerDB.LedgerDbBackendArgsV2 $
                V2Backend.SomeBackendArgs V2InMemory.InMemArgs
    withRegistry $ \registry -> do
        let chainDbArgs =
                ChainDB.completeChainDbArgs
                    registry
                    cfg
                    genesisLedger
                    chunkInfo
                    (const True)
                    shfs
                    shfs
                    flavargs
                    ChainDB.defaultArgs
            immDbArgs = ChainDB.cdbImmDbArgs chainDbArgs
        bracket
            (ImmutableDB.openDBInternal immDbArgs)
            (ImmutableDB.closeDB . fst)
            (\(immDB, _internal) -> action registry immDB)

-- | Era label of a Cardano-block tip. Exhaustive — GHC verifies
-- coverage via the @{-# COMPLETE #-}@ pragma in
-- @Ouroboros.Consensus.Cardano.Block@.
eraName :: CardanoBlock StandardCrypto -> Text
eraName = \case
    BlockByron _ -> "Byron"
    BlockShelley _ -> "Shelley"
    BlockAllegra _ -> "Allegra"
    BlockMary _ -> "Mary"
    BlockAlonzo _ -> "Alonzo"
    BlockBabbage _ -> "Babbage"
    BlockConway _ -> "Conway"

-- | Render a @CardanoBlock@ header hash as a lower-case hex string
-- (the JSON contract for @blockHash@). The @HeaderHash@ for
-- @CardanoBlock@ is a @OneEraHash@ wrapping a @ShortByteString@.
renderHeaderHash :: HeaderHash (CardanoBlock StandardCrypto) -> Text
renderHeaderHash (OneEraHash sbs) =
    TE.decodeUtf8 (B16.encode (SBS.fromShort sbs))
