# Tasks: Short-Epoch Golden Ledger States

**Input**: `spec.md`, `plan.md`, GitHub issue #29

## Phase 1 - Corpus

- [X] T001 Create issue #29 and add it to the Planning board.
- [X] T002 Reproduce the short-epoch import failure locally with sampled
  slots `9`, `129`, and `249`.
- [X] T003 Add a generated short-epoch ChainDB corpus derivation.
- [X] T004 Add `antithesis-short-epoch-samples` to emit and convert the
  sampled ledger states.

## Phase 2 - Golden Gate

- [X] T005 Add `antithesis-short-epoch-golden` to import the converted
  snapshots through Amaru.
- [X] T006 Wire the golden check into CI Build Gate.
- [X] T007 Document the corpus and verification commands.

## Phase 3 - Make It Pass

- [ ] T008 Fix the ledger-state projection/import contract mismatch.
- [ ] T009 Re-run the sample and golden checks and update this status.
- [ ] T010 Re-run the full Build Gate before sending the image back to
  Antithesis.
