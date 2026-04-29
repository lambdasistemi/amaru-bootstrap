{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Entry point for the ledger-state-emitter CLI
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The CLI emits one Legacy @ExtLedgerState@ CBOR file for Amaru's
@convert-ledger-state@ command. All tool failures map to rc=7 so the
bootstrap-producer orchestrator can classify them as snapshot-emission
failures.
-}
module Main where

import Cardano.Slotting.Slot (SlotNo (SlotNo))
import Control.Exception (SomeException, displayException, handle)
import HeaderExtractor (NodeConfig (NodeConfig))
import LedgerStateEmitter (emitLedgerSnapshot)
import Options.Applicative
    ( Parser
    , ParserInfo
    , auto
    , execParser
    , fullDesc
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , progDesc
    , strOption
    , value
    , (<**>)
    )
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

data Options = Options
    { db :: FilePath
    , config :: FilePath
    , targetSlot :: Word
    , out :: FilePath
    }

main :: IO ()
main = handle topLevelHandler $ do
    Options{db, config, targetSlot, out} <- execParser opts
    emitLedgerSnapshot db (NodeConfig config) (SlotNo $ fromIntegral targetSlot) out

topLevelHandler :: SomeException -> IO a
topLevelHandler e = do
    hPutStrLn stderr ("ledger-state-emitter: " <> displayException e)
    exitWith (ExitFailure 7)

opts :: ParserInfo Options
opts =
    info
        (optionsParser <**> helper)
        ( fullDesc
            <> progDesc
                "Emit an Amaru-compatible Legacy ledger-state snapshot"
        )

optionsParser :: Parser Options
optionsParser =
    Options
        <$> strOption
            ( long "db"
                <> metavar "PATH"
                <> help "Path to the chain DB"
            )
        <*> strOption
            ( long "config"
                <> metavar "FILE"
                <> help "Path to cardano-node config.json"
            )
        <*> option
            auto
            ( long "target-slot"
                <> metavar "SLOT"
                <> help "Target slot; emits the first block at or after SLOT"
            )
        <*> strOption
            ( long "out"
                <> metavar "FILE"
                <> help "Output CBOR snapshot path"
            )
