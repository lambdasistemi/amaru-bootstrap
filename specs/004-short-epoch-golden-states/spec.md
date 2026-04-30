# Feature Specification: Short-Epoch Golden Ledger States

**Feature Branch**: `test/add-short-epoch-golden-tests-for-antithesis-bootst`  
**Created**: 2026-04-30  
**Status**: Draft  
**Input**: GitHub issue #29: add deterministic golden coverage for the
Antithesis short-epoch bootstrap ledger-state family.

## User Scenarios & Testing

### User Story 1 - Reproduce the Antithesis Import Boundary (Priority: P1)

An operator or maintainer can run one local/CI check that regenerates the
short-epoch ChainDB family, emits the sampled ledger states, converts
them, and proves Amaru can import them.

**Why this priority**: Antithesis should not be used as the first place
we discover that a release-pinned ledger projection cannot be imported.

**Independent Test**: Build the short-epoch golden flake check. It must
fail before the projection/import mismatch is fixed and pass afterwards.

**Acceptance Scenarios**:

1. **Given** the pinned node 10.7.1 toolchain, **When** the sample check
   runs, **Then** it generates the short-epoch ChainDB and converted
   snapshots without committed database blobs.
2. **Given** those converted snapshots, **When** the golden check runs,
   **Then** `amaru import-ledger-state` succeeds and produces a live
   ledger store.

### Edge Cases

- The fixture must use a short epoch length but still create enough
  immutable blocks for `header-extractor` and `ledger-state-emitter`.
- A check that only proves conversion is insufficient; the import step is
  the failing boundary.
- Converted testnet history sidecars must agree with the node genesis
  epoch length; otherwise Amaru maps slot 129 to epoch 0 while the
  ledger snapshot declares epoch 1.
- The corpus must remain pinned to the node 10.7.1 dependency set.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST generate the short-epoch ChainDB
  deterministically during the Nix build.
- **FR-002**: The system MUST sample the observed early bootstrap slots
  `9`, `129`, and `249`.
- **FR-003**: The system MUST convert each sampled ledger state through
  `amaru convert-ledger-state`.
- **FR-004**: The system MUST import the converted snapshots through
  `amaru import-ledger-state`.
- **FR-005**: The repository MUST document the generated corpus profile
  and explain why the database is not committed.
- **FR-006**: The converted current-era history sidecars MUST use the
  Shelley genesis `epochLength` before Amaru import on custom testnets.

### Key Entities

- **Short-epoch ChainDB corpus**: Generated Cardano ChainDB configured to
  exercise the early Conway-from-genesis bootstrap state family.
- **Golden snapshots**: Converted Amaru snapshots derived from the
  sampled ledger states, with history sidecars corrected to the sampled
  genesis epoch length.
- **Import gate**: CI check that requires Amaru to consume the snapshots.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `nix build .#checks.x86_64-linux.antithesis-short-epoch-samples`
  produces exactly three converted snapshots.
- **SC-002**: `nix build .#checks.x86_64-linux.antithesis-short-epoch-golden`
  fails on the current mismatch and passes once the projection/import
  contract is corrected.
- **SC-003**: CI includes the golden import gate before the image is
  considered safe for Antithesis.

## Assumptions

- Stock `db-synthesizer` is the corpus generator; no binary ChainDB is
  committed.
- The exact Antithesis k/f tuple is too sparse for this small generated
  corpus, so the fixture keeps the observed 120-slot epoch and slot
  samples while increasing density enough for immutable-DB tooling.
