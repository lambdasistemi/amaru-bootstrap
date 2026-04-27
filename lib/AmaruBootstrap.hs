{- |
Module      : AmaruBootstrap
Description : Marker module pulling in ouroboros-consensus-cardano
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module exists so the project's @cabal.project@ has a local
package, which lets @haskell.nix@ resolve the
@ouroboros-consensus-cardano@ source-repository-package and expose
its @db-synthesizer@ and @db-analyser@ executables.

The project's actual deliverable is @scripts\/smoke-test.sh@ — this
module has no runtime role and exports nothing.
-}
module AmaruBootstrap () where
