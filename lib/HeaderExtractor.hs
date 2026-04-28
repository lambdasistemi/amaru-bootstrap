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

  * 'tipInfo' — open the immutable DB read-only and return the tip's
    slot, era and block hash.
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

      -- * Library API
    , tipInfo
    , listBlocks
    , getHeader

      -- * Stale stub (kept until T010 rewires @app\/header-extractor\/Main.hs@)
    , placeholder
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
    ( runWithTempRegistry
    , withRegistry
    )
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16
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
import Ouroboros.Consensus.Storage.Common (BlockComponent (GetBlock))
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
import qualified Ouroboros.Consensus.Storage.LedgerDB.V2 as LedgerDB.V2
import qualified Ouroboros.Consensus.Storage.LedgerDB.V2.Args as LedgerDB.V2

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

-- | Open the immutable DB read-only and return the era-tagged tip.
tipInfo :: FilePath -> NodeConfig -> IO TipInfo
tipInfo dbDir nc = withImmDB dbDir nc $ \(immDB, _internal) -> do
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

-- NOTE: stub for bisect-safety, real impl in T008.

-- | Iterate the immutable DB and return @(slot, hash)@ pairs in
-- chain order. Hashes are lower-case hex strings.
listBlocks :: FilePath -> NodeConfig -> IO [(Integer, Text)]
listBlocks _ _ =
    error "HeaderExtractor.listBlocks: stub - real implementation lands in T008"

-- NOTE: stub for bisect-safety, real impl in T009.

{- | Fetch a single header's CBOR bytes addressed by its
@(slot, hash)@ pair.
-}
getHeader :: FilePath -> NodeConfig -> Integer -> Text -> IO ByteString
getHeader _ _ _ _ =
    error "HeaderExtractor.getHeader: stub - real implementation lands in T009"

-- NOTE: stub for bisect-safety, removed in T010.

-- | Legacy placeholder consumed by the current Main.hs stub. Removed
-- once T010 rewires the CLI to dispatch over the real subcommands.
placeholder :: String
placeholder = "header-extractor stub - real implementation in T007-T010"

-- ─── Internals ───────────────────────────────────────────────────

-- | Bracket-open the immutable DB read-only. Reuses the ChainDB
-- args path (db-analyser's recipe) and projects out @cdbImmDbArgs@ —
-- we never touch the LedgerDB.
withImmDB
    :: FilePath
    -> NodeConfig
    -> ( ( ImmutableDB.ImmutableDB IO (CardanoBlock StandardCrypto)
         , ImmutableDB.Internal IO (CardanoBlock StandardCrypto)
         )
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
            LedgerDB.LedgerDbFlavorArgsV2
                (LedgerDB.V2.V2Args LedgerDB.V2.InMemoryHandleArgs)
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
            (ImmutableDB.openDBInternal immDbArgs runWithTempRegistry)
            (ImmutableDB.closeDB . fst)
            action

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
