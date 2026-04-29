{- |
Module      : AmaruBootstrap
Description : Marker module for the bootstrap producer package
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module exists so the project's @cabal.project@ has a local
package, which lets @haskell.nix@ resolve the cardano-node
10.7.1-aligned @ouroboros-consensus@ source-repository-package and
expose its @db-synthesizer@, @db-analyser@, and @snapshot-converter@
executables.

The project's actual deliverable is @scripts\/smoke-test.sh@ — this
module has no runtime role and exports nothing.
-}
module AmaruBootstrap () where
