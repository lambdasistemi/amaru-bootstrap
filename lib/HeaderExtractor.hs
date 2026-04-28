{- |
Module      : HeaderExtractor
Description : Stub for the small ouroboros-consensus chain-DB query tool
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per
[research.md R-001](../specs/003-amaru-bootstrap-producer/research.md#r-001-header-extraction-without-pragma-orgdb-server)
and
[R-009/R-010](../specs/003-amaru-bootstrap-producer/research.md#r-009-wait-strategy--poll-immutable-db-tip-info),
this module will expose three pure functions consumed by the
@header-extractor@ executable:

  * @tipInfo@ — open the immutable DB read-only and return the tip's
    slot, era and block hash.
  * @listBlocks@ — iterate the immutable DB chunks and return
    @(slot, hash)@ pairs in the db-server-portable JSON envelope.
  * @getHeader@ — fetch one header's CBOR bytes by @slot.hash@.

This is a stub for bisect-safety while T007-T010 land. Replaced by
the real implementation; see
[tasks.md Phase 2](../specs/003-amaru-bootstrap-producer/tasks.md#phase-2-foundational-blocking-prerequisites).
-}
module HeaderExtractor
  ( placeholder
  ) where

-- NOTE: stub for bisect-safety, removed in T007.
placeholder :: String
placeholder = "header-extractor stub — real implementation in T007-T010"
