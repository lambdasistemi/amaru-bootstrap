{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : HeaderExtractor
Description : Library API for the in-repo chain-DB query tool
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per
[research.md R-001](../specs/003-amaru-bootstrap-producer/research.md#r-001-header-extraction-without-pragma-orgdb-server)
and
[R-009/R-010](../specs/003-amaru-bootstrap-producer/research.md#r-009-wait-strategy--poll-immutable-db-tip-info),
this module exposes the three pure-IO functions consumed by the
@header-extractor@ executable and the orchestrator's polling loop:

  * 'tipInfo' — open the immutable DB read-only and return the tip's
    slot, era and block hash.
  * 'listBlocks' — iterate the immutable DB chunks and return
    @(slot, hash)@ pairs in chain order.
  * 'getHeader' — fetch one header's CBOR bytes by @slot.hash@.

T005 (failing hspec) lands the public API; T007-T009 replace the stub
bodies with the real ouroboros-consensus implementations.
-}
module HeaderExtractor
    ( -- * Types
      TipInfo (..)
    , NodeConfig (..)

      -- * Library API (stubs replaced in T007-T009)
    , tipInfo
    , listBlocks
    , getHeader

      -- * Stale stub (kept until T010 rewires @app\/header-extractor\/Main.hs@)
    , placeholder
    ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString (ByteString)
import Data.Text (Text)
import GHC.Generics (Generic)

{- | Path bundle for the cardano-node config (@config.json@ plus the
referenced genesis files). The same value is shared across all three
queries and across the orchestrator's polling loop.
-}
newtype NodeConfig = NodeConfig {nodeConfigPath :: FilePath}
    deriving stock (Show, Eq)

{- | The chain DB's immutable tip, era-tagged. The JSON encoding is
the contract surfaced by @header-extractor tip-info@; see
[contracts/bootstrap-producer-cli.md](../specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md).
-}
data TipInfo = TipInfo
    { slot :: Integer
    , era :: Text
    , blockHash :: Text
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON TipInfo

instance FromJSON TipInfo

-- NOTE: stub for bisect-safety, real impl in T007.

-- | Open the immutable DB read-only and return the era-tagged tip.
tipInfo :: FilePath -> NodeConfig -> IO TipInfo
tipInfo _ _ =
    error "HeaderExtractor.tipInfo: stub - real implementation lands in T007"

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
placeholder = "header-extractor stub — real implementation in T007-T010"
