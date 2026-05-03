{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Main
Description : Entry point for the header-extractor CLI
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per [contracts/bootstrap-producer-cli.md](../../specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md)
and [research.md
R-001/R-009/R-010](../../specs/003-amaru-bootstrap-producer/research.md),
this binary exposes three subcommands invoked by
@scripts\/bootstrap-producer.sh@:

  * @header-extractor tip-info --db \<path\> --config \<file\>@ -
    JSON @{slot, era, blockHash}@ on stdout.
  * @header-extractor list-blocks --db \<path\> --config \<file\>@ -
    JSON @{"tag":"Found","data":[[slot,"hash"],...]}@ on stdout
    (db-server-portable envelope so Arnaud's amaru-loader.sh
    pipeline ports unchanged).
  * @header-extractor get-header SLOT.HASH --db \<path\> --config \<file\>@
    - raw CBOR bytes on stdout.

Any failure of a query maps to rc=7 (tool-error: extract) per the
exit-code contract; usage errors from optparse-applicative exit
with rc=1 (its own convention - the bats specs accept any non-zero
exit on missing-flag paths).
-}
module Main where

import Control.Exception (SomeException, displayException, handle)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import HeaderExtractor
    ( NodeConfig (NodeConfig)
    , PrevEpochTail (PrevEpochTail, tailCbor, tailHash, tailSlot)
    , TipInfo
    , getHeader
    , getHeaderByHash
    , listBlocks
    , prevEpochTailHeader
    , tipInfo
    )
import Options.Applicative
    ( Parser
    , ParserInfo
    , argument
    , auto
    , command
    , execParser
    , fullDesc
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , progDesc
    , str
    , strOption
    , subparser
    , (<**>)
    )
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr, stdout)

-- | Common flags shared by every subcommand.
data Common = Common
    { db :: FilePath
    , config :: FilePath
    }

-- | Top-level dispatch: which subcommand the user invoked.
data Cmd
    = CmdTipInfo Common
    | CmdListBlocks Common
    | CmdGetHeader String Common
    | CmdGetHeaderByHash String Common
    | CmdPrevEpochTail Integer Integer FilePath Common

main :: IO ()
main = handle topLevelHandler $ do
    cmd <- execParser opts
    case cmd of
        CmdTipInfo c -> runTipInfo c
        CmdListBlocks c -> runListBlocks c
        CmdGetHeader slotDotHash c -> runGetHeader slotDotHash c
        CmdGetHeaderByHash hHex c -> runGetHeaderByHash hHex c
        CmdPrevEpochTail tipS el out c -> runPrevEpochTail tipS el out c

-- ─── Handlers ────────────────────────────────────────────────────

runTipInfo :: Common -> IO ()
runTipInfo Common{db, config} = do
    info' <- tipInfo db (NodeConfig config)
    LBS.hPut stdout (Aeson.encode (info' :: TipInfo))
    LBS.hPut stdout "\n"

runListBlocks :: Common -> IO ()
runListBlocks Common{db, config} = do
    pairs <- listBlocks db (NodeConfig config)
    let envelope =
            Aeson.object
                [ "tag" Aeson..= ("Found" :: T.Text)
                , "data"
                    Aeson..= [Aeson.toJSON (s, h) | (s, h) <- pairs]
                ]
    LBS.hPut stdout (Aeson.encode envelope)
    LBS.hPut stdout "\n"

runGetHeader :: String -> Common -> IO ()
runGetHeader slotDotHash Common{db, config} = do
    (s, h) <- case break (== '.') slotDotHash of
        (sStr, '.' : hStr)
            | not (null sStr) && not (null hStr) ->
                case reads sStr of
                    [(n, "")] -> pure (n, T.pack hStr)
                    _ ->
                        fail
                            ("get-header: slot is not an integer: " <> sStr)
        _ ->
            fail
                ( "get-header: argument must be SLOT.HASH, got: "
                    <> slotDotHash
                )
    bytes <- getHeader db (NodeConfig config) s h
    BS.hPut stdout bytes

runGetHeaderByHash :: String -> Common -> IO ()
runGetHeaderByHash hHex Common{db, config} = do
    bytes <- getHeaderByHash db (NodeConfig config) (T.pack hHex)
    BS.hPut stdout bytes

runPrevEpochTail :: Integer -> Integer -> FilePath -> Common -> IO ()
runPrevEpochTail tipS el out Common{db, config} = do
    res <- prevEpochTailHeader db (NodeConfig config) tipS el
    case res of
        Nothing -> exitWith (ExitFailure 7)
        Just PrevEpochTail{tailSlot, tailHash, tailCbor} -> do
            BS.writeFile out tailCbor
            LBS.hPut stdout
                ( Aeson.encode
                    ( Aeson.object
                        [ "slot" Aeson..= tailSlot
                        , "hash" Aeson..= tailHash
                        , "out" Aeson..= out
                        ]
                    )
                )
            LBS.hPut stdout "\n"

-- ─── Error mapping ───────────────────────────────────────────────

-- | rc=7 for any uncaught failure of the tool itself, per the
-- 'tool-error: extract' class in
-- [contracts/bootstrap-producer-cli.md](../../specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md).
-- optparse-applicative's own ExitFailure (usage errors) bypasses
-- this handler and surfaces with its own rc - bats accepts any
-- non-zero on missing-flag paths.
topLevelHandler :: SomeException -> IO a
topLevelHandler e = do
    hPutStrLn stderr ("header-extractor: " <> displayException e)
    exitWith (ExitFailure 7)

-- ─── optparse-applicative wiring ─────────────────────────────────

opts :: ParserInfo Cmd
opts =
    info
        (cmdParser <**> helper)
        ( fullDesc
            <> progDesc
                "Immutable chain-DB queries used by the bootstrap-producer orchestrator"
        )

cmdParser :: Parser Cmd
cmdParser =
    subparser
        ( command
            "tip-info"
            ( info
                (CmdTipInfo <$> commonParser <**> helper)
                (progDesc "Print the immutable DB's tip slot, era and hash as JSON")
            )
            <> command
                "list-blocks"
                ( info
                    (CmdListBlocks <$> commonParser <**> helper)
                    (progDesc "Print every immutable block's (slot, hash) pair as JSON")
                )
            <> command
                "get-header"
                ( info
                    ( CmdGetHeader
                        <$> argument str (metavar "SLOT.HASH")
                        <*> commonParser
                        <**> helper
                    )
                    (progDesc "Print one header's raw CBOR bytes")
                )
            <> command
                "get-header-by-hash"
                ( info
                    ( CmdGetHeaderByHash
                        <$> argument str (metavar "HASH")
                        <*> commonParser
                        <**> helper
                    )
                    ( progDesc
                        "Print one header's raw CBOR bytes, addressed by hash alone (slot resolved internally)"
                    )
                )
            <> command
                "prev-epoch-tail"
                ( info
                    ( CmdPrevEpochTail
                        <$> option
                            auto
                            ( long "tip-slot"
                                <> metavar "SLOT"
                                <> help "Snapshot tip slot"
                            )
                        <*> option
                            auto
                            ( long "epoch-length"
                                <> metavar "SLOTS"
                                <> help "Epoch length in slots"
                            )
                        <*> strOption
                            ( long "out"
                                <> metavar "FILE"
                                <> help "Where to write the boundary header CBOR"
                            )
                        <*> commonParser
                        <**> helper
                    )
                    ( progDesc
                        "Resolve and emit the previous-epoch tail boundary header for a snapshot"
                    )
                )
        )

commonParser :: Parser Common
commonParser =
    Common
        <$> strOption
            ( long "db"
                <> metavar "PATH"
                <> help "Path to the chain DB (the cardano-node state directory)"
            )
        <*> strOption
            ( long "config"
                <> metavar "FILE"
                <> help "Path to config.json (genesis files resolved relative to it)"
            )
