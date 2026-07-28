{-# LANGUAGE DerivingStrategies #-}

{- |
Module      : AmaruBootstrap
Description : Marker module and retained types for the bootstrap producer package
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module exists so the project's @cabal.project@ has a local
package, which lets @haskell.nix@ resolve the cardano-node
10.7.1-aligned @ouroboros-consensus@ source-repository-package and
expose its @db-synthesizer@, @db-analyser@, and @snapshot-converter@
executables.

The project's actual deliverable is the bootstrap producer. This
module exports the retained 'NodeConfig' type used by the producer
orchestration.
-}
module AmaruBootstrap
    ( -- * Types
      NodeConfig (..)
    ) where

-- | The path to the cardano-node @config.json@. Referenced genesis
-- files (byron / shelley / alonzo / conway) are resolved relative to
-- the file's directory by the node's protocol-info initialisation.
newtype NodeConfig = NodeConfig {nodeConfigPath :: FilePath}
    deriving stock (Show, Eq)
