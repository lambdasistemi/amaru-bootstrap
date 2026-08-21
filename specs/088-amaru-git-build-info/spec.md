# Specification: deterministic Amaru git build information

Issue: `lambdasistemi/amaru-bootstrap#88`

Artifact ceiling: 120 lines.

## Outcome

The Nix-built `amaru` binary reports git identity derived from the exact
locked Amaru revision without requiring an upstream Git checkout.

## User story

As the bootstrap image operator, I want every pinned Amaru build to embed its
source revision deterministically so clean Nix source archives build and the
running binary remains attributable to the source selected by `flake.lock`.

## Requirements

- **R-088-01 — locked identity:** Every `amaru` package variant MUST derive
  its full and short git commit identities from `amaruRev`, the revision of
  the locked non-flake input.
- **R-088-02 — clean identity:** The embedded identity MUST describe a clean
  source. It MUST NOT depend on an ambient checkout, `.git`, clock, network,
  or mutable ref.
- **R-088-03 — upstream-shape compatibility:** The package boundary MUST
  satisfy both the stock pin's `built`-crate git inputs and the direct Git
  command shape present at Amaru `ba992f651d3b5e2b49f12d461b86ab8f7a55f994`.
- **R-088-04 — observable proof:** The `checks.x86_64-linux.amaru` derivation
  MUST execute the built binary's version surface and reject output that does
  not contain the expected short locked revision or that reports `dirty`.
- **R-088-05 — confinement:** The change MUST NOT alter the Amaru pin,
  peer-snapshot inputs or anchors, producer/runtime behavior, or CLI surface.
- **R-088-06 — hosted proof:** Hosted CI MUST be green once at the stock pin
  and once on a fixture branch containing exactly PR #87's two-file pin and
  resolution-record delta in addition to this fix.

## Invariants

- **I-088-LOCK:** Changing the locked Amaru revision changes the embedded full
  and short identities together; the short identity is the first eight
  hexadecimal characters of the full revision.
- **I-088-CLEAN:** A Nix source archive with no `.git` still builds and reports
  the locked short identity without a dirty suffix.
- **I-088-CHECK:** Replacing the expected short identity in the check with a
  non-matching value makes the check fail after executing `amaru --version`.
- **I-088-FENCE:** `flake.lock`, `nix/peer-snapshots/resolution.json`, anchor
  logic, and upstream source bytes are unchanged on the issue branch.

## Acceptance evidence

- Static frozen gate and its pre-change RED receipt.
- Fresh commit-owner RED/GREEN receipt for I-088-LOCK through I-088-FENCE.
- Fresh independent audit of the exact candidate commit.
- Green hosted CI on the issue PR at the stock pin.
- Green hosted CI on the isolated PR #87-shape fixture branch.
