{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : HeaderExtractorSpec
Description : T005 — failing hspec for the HeaderExtractor library API
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

T005 from
[tasks.md Phase 2](../specs/003-amaru-bootstrap-producer/tasks.md#tdd-tests-first).

These specs are FAILING by design: 'tipInfo', 'listBlocks' and
'getHeader' are stubs that 'error' out (T007-T009 replace them).
Each spec here is the regression test for the corresponding
implementation task.

Inputs: a synthesised chain DB whose path is in
@HEADER_EXTRACTOR_TEST_CHAIN_DB@ and a path to the cardano-node
@config.json@ in @HEADER_EXTRACTOR_TEST_CONFIG@ (referenced genesis
files are resolved relative to that file's directory). The Nix check
@.\#checks.x86_64-linux.header-extractor-spec@ wires both — see
@nix\/checks.nix@. Outside the Nix check the suite is a no-op
because the env vars are unset.

Backed by:
[R-001](../specs/003-amaru-bootstrap-producer/research.md#r-001-header-extraction-without-pragma-orgdb-server),
[R-009](../specs/003-amaru-bootstrap-producer/research.md#r-009-wait-strategy--poll-immutable-db-tip-info),
[R-010](../specs/003-amaru-bootstrap-producer/research.md#r-010-era-readiness-predicate-and-snapshot-point-selection).
-}
module HeaderExtractorSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isHexDigit)
import qualified Data.Text as T
import HeaderExtractor
    ( NodeConfig (..)
    , TipInfo (..)
    , getHeader
    , listBlocks
    , tipInfo
    )
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , runIO
    , shouldBe
    , shouldSatisfy
    )

-- | Required-env wrapper: when either env var is missing the suite
-- is marked pending instead of erroring out, so a developer running
-- @cabal test@ outside the Nix check sees a clear "needs fixture"
-- signal rather than a confusing failure.
data TestInputs = TestInputs
    { chainDb :: FilePath
    , nodeConfig :: NodeConfig
    }

loadInputs :: IO (Maybe TestInputs)
loadInputs = do
    mDb <- lookupEnv "HEADER_EXTRACTOR_TEST_CHAIN_DB"
    mCfg <- lookupEnv "HEADER_EXTRACTOR_TEST_CONFIG"
    case (mDb, mCfg) of
        (Just db, Just cfg) -> do
            dbExists <- doesDirectoryExist db
            cfgExists <- doesFileExist cfg
            if dbExists && cfgExists
                then
                    pure $
                        Just
                            TestInputs
                                { chainDb = db
                                , nodeConfig = NodeConfig cfg
                                }
                else pure Nothing
        _ -> pure Nothing

spec :: Spec
spec = do
    inputs <- runIO loadInputs

    describe "HeaderExtractor.tipInfo (T007)" $ do
        it "returns Conway era + positive slot for the testnet_42 fixture" $ do
            case inputs of
                Nothing ->
                    pendingWith
                        "HEADER_EXTRACTOR_TEST_CHAIN_DB / _CONFIG unset"
                Just TestInputs{chainDb, nodeConfig} -> do
                    info <- tipInfo chainDb nodeConfig
                    era info `shouldBe` "Conway"
                    slot info `shouldSatisfy` (> 0)
                    blockHash info `shouldSatisfy` isHexNonEmpty

    describe "HeaderExtractor.listBlocks (T008)" $ do
        it "returns at least one (slot, hash) pair for the first immutable chunk" $ do
            case inputs of
                Nothing ->
                    pendingWith
                        "HEADER_EXTRACTOR_TEST_CHAIN_DB / _CONFIG unset"
                Just TestInputs{chainDb, nodeConfig} -> do
                    pairs <- listBlocks chainDb nodeConfig
                    pairs `shouldSatisfy` (not . null)
                    let (s, h) = head pairs
                    s `shouldSatisfy` (>= 0)
                    h `shouldSatisfy` isHexNonEmpty

    describe "HeaderExtractor.getHeader (T009)" $ do
        it "returns non-empty CBOR bytes for the first listed block" $ do
            case inputs of
                Nothing ->
                    pendingWith
                        "HEADER_EXTRACTOR_TEST_CHAIN_DB / _CONFIG unset"
                Just TestInputs{chainDb, nodeConfig} -> do
                    pairs <- listBlocks chainDb nodeConfig
                    case pairs of
                        [] -> error "listBlocks returned empty list"
                        ((s, h) : _) -> do
                            bytes <- getHeader chainDb nodeConfig s h
                            BS.length bytes `shouldSatisfy` (> 0)

isHexNonEmpty :: T.Text -> Bool
isHexNonEmpty t = not (T.null t) && T.all isHexDigit t
