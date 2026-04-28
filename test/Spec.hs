{- |
Module      : Main
Description : hspec entry point for the header-extractor test-suite
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single-spec runner — keeps the cabal stanza free of a
@build-tool-depends: hspec-discover@ and the dev-shell free of an
extra binary. Adding more spec files means importing them here.
-}
module Main where

import qualified HeaderExtractorSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec HeaderExtractorSpec.spec
