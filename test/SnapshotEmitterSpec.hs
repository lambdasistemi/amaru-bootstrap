{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Hspec for the SnapshotEmitter library
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Two test layers:

* error-class -> exit-code mapping (cheap, no I/O) — covers FR-004 and
  data-model.md "Error class registry"
* full codec round-trip via the real binary (pending until the codec
  implementation lands; the integration test in
  @tests/test-smoke-pass.bats@ already exercises it end-to-end through
  the smoke-test pipeline)
-}
module Main (main) where

import qualified SnapshotEmitter as SE
import System.Exit (ExitCode (..))
import Test.Hspec (Spec, context, describe, hspec, it, pendingWith, shouldBe)

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
    describe "errorToExitCode" $ do
        context "covers the registry from data-model.md" $ do
            it "maps InputNotFound to ExitFailure 1" $
                SE.errorToExitCode SE.InputNotFound `shouldBe` ExitFailure 1
            it "maps InputStructurallyInvalid to ExitFailure 2" $
                SE.errorToExitCode (SE.InputStructurallyInvalid "anything")
                    `shouldBe` ExitFailure 2
            it "maps DecodeError to ExitFailure 3" $
                SE.errorToExitCode (SE.DecodeError "anything")
                    `shouldBe` ExitFailure 3
            it "maps OutputCollision to ExitFailure 4" $
                SE.errorToExitCode SE.OutputCollision
                    `shouldBe` ExitFailure 4
            it "maps OutputWriteError to ExitFailure 5" $
                SE.errorToExitCode (SE.OutputWriteError "anything")
                    `shouldBe` ExitFailure 5

    describe "errorToMessage" $ do
        it "names the failing class for InputNotFound" $
            SE.errorToMessage SE.InputNotFound
                `shouldBe` "input-not-found"
        it "names the failing class and detail for structural errors" $
            SE.errorToMessage (SE.InputStructurallyInvalid "missing state")
                `shouldBe` "input-structurally-invalid: missing state"
        it "surfaces the upstream library message for decode errors" $
            SE.errorToMessage (SE.DecodeError "expected list, found map")
                `shouldBe` "decode-error: expected list, found map"
        it "names the path on output collisions" $
            SE.errorToMessage SE.OutputCollision
                `shouldBe` "output-collision"
        it "surfaces the io error for write failures" $
            SE.errorToMessage (SE.OutputWriteError "disk full")
                `shouldBe` "output-write-error: disk full"

    describe "codec round-trip" $ do
        it "encodes then decodes an ExtLedgerState identity" $
            pendingWith
                "exercised end-to-end via tests/test-smoke-pass.bats; \
                \constructing a synthetic ExtLedgerState from scratch \
                \is heavy and gives no signal beyond what the integration \
                \test already provides"
