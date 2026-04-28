{- |
Module      : Main
Description : Entry point for the snapshot-emitter executable
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin wrapper over "SnapshotEmitter".'SnapshotEmitter.run'. The
behavioural contract lives entirely in the library so the test suite
can import the same code paths without spawning a subprocess.
-}
module Main (main) where

import qualified SnapshotEmitter
import System.Exit (exitWith)

main :: IO ()
main = SnapshotEmitter.run >>= exitWith
