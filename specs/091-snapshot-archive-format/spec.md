# Specification: snapshot archive format compatibility

Issue: `lambdasistemi/amaru-bootstrap#91`

Artifact ceiling: 100 lines.

## Outcome

The bootstrap producer accepts the snapshot artifact form emitted by its
SHA-pinned Amaru revision, including the `.tar.zst` per-target archives at
upstream `ba992f651d3b5e2b49f12d461b86ab8f7a55f994`, without weakening its
fail-closed target count or the resulting bootstrap bundle.

## Requirements

- **R-091-01 — accepted artifact forms:** A snapshot target is recognized only
  as `<slot>.<lowercase-hex-hash>/` or
  `<slot>.<lowercase-hex-hash>.tar.zst`. Directory compatibility MUST remain
  because the stock pin emits that form; archive compatibility MUST work
  because the candidate pin emits that form.
- **R-091-02 — fail-closed count:** Snapshot creation MUST exit with producer
  code 6 and a named diagnostic when fewer than three recognized target
  artifacts exist. Unrelated files, sidecars, and malformed names MUST NOT
  satisfy the count.
- **R-091-03 — bundle equivalence:** Both accepted forms MUST reach the same
  producer success boundary: three historical ledger snapshots, a chain
  store, and the era-history input required by `amaru run`.
- **R-091-04 — consumer checks:** Every flake check that inspects the snapshot
  artifact layout MUST recognize the same two forms and retain a non-zero,
  at-least-three assertion.
- **R-091-05 — mock honesty:** `cli-mock-honesty` MUST remain reachable from
  the Build Gate and unchanged in its declared-vs-observed CLI meaning.
- **R-091-06 — confinement:** The change MUST NOT alter dependency pins,
  `nix/peer-snapshots/*`, publication/image identity, handoff schema, runtime
  parameters, or fenced PRs #76/#81/#82/#83/#86/#87/#90.
- **R-091-07 — hosted proof:** The full Build Gate MUST pass on the stock pin
  and on an isolated fixture branch containing PR #90's exact two-file delta
  at Amaru `ba992f65`. All required contexts MUST be green on the issue head.

## Invariants

- **I-091-FORMS (BLOCKING):** Each real target contributes exactly one count
  when represented by either accepted form; other filesystem entries
  contribute zero.
- **I-091-FAIL-CLOSED (BLOCKING):** A drift-shaped producer that emits neither
  accepted form exits 6 with the named snapshot-artifact diagnostic.
- **I-091-BUNDLE (BLOCKING):** Stock-directory and candidate-archive runs both
  produce the complete ledger/chain bundle consumed by `amaru run`.
- **I-091-CONSUMERS (BLOCKING):** Layout-inspecting producer and short-epoch
  checks enforce the same recognized-form and minimum-count contract.
- **I-091-MOCK (ADVISORY):** The real-CLI reconciliation check remains
  present, executing, and semantically unchanged.
- **I-091-FENCE (ADVISORY):** Forbidden pins, peer-snapshot, publication,
  handoff, and fenced-PR surfaces remain byte-identical on the issue branch.

## Acceptance evidence

- Frozen static/focused gate with an observed pre-change RED.
- Commit-owner RED/GREEN receipt and clean candidate.
- One fresh independent audit pass unless a blocking finding requires repair.
- Green hosted Build Gate on the issue branch at the stock pin.
- Green hosted Build Gate on a new isolated PR #90-shape fixture branch.
- Exact-head required-context and PR metadata verification.
