{- |
Module      : SnapshotEmitter
Description : Converts V2InMemory directory snapshots to legacy single-file CBOR
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Phase 1 bridge tool. Stub at this commit; the real implementation
lands in T009-T012.
-}
module SnapshotEmitter
    ( run
    ) where

import System.Exit (ExitCode (..))

-- | Stub entry point. T008-T012 replace this with the real conversion.
run :: IO ExitCode
run = pure (ExitFailure 99)
