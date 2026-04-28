{- |
Module      : Main
Description : Stub entrypoint for the header-extractor CLI
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per
[contracts/bootstrap-producer-cli.md](../../specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md)
and
[research.md R-001/R-009/R-010](../../specs/003-amaru-bootstrap-producer/research.md#r-001-header-extraction-without-pragma-orgdb-server),
this binary exposes three subcommands invoked by
@scripts/bootstrap-producer.sh@:

  * @header-extractor tip-info --db <path> --config <cfg>@
  * @header-extractor list-blocks --db <path> --config <cfg>@
  * @header-extractor get-header SLOT.HASH --db <path> --config <cfg>@

Real CLI lands in T010 (optparse-applicative subcommand dispatch).
-}
module Main where

import qualified HeaderExtractor
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- NOTE: stub for bisect-safety, removed in T010.
main :: IO ()
main = do
  hPutStrLn stderr ("header-extractor stub: " <> HeaderExtractor.placeholder)
  hPutStrLn stderr "real CLI lands in T010"
  exitFailure
