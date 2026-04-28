{- |
Module      : Main
Description : Hspec round-trip for SnapshotEmitter
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Stub at this commit; the real round-trip lands in T006.
-}
module Main (main) where

import Test.Hspec (hspec, describe, it, pendingWith)

main :: IO ()
main = hspec $ do
    describe "SnapshotEmitter" $ do
        it "round-trips an ExtLedgerState (T006)" $
            pendingWith "real round-trip lands in T006"
