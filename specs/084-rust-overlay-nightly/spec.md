# Feature specification: rust-overlay nightly availability

Issue: #84
Artifact ceiling: 2 KiB

## Observable outcome

The pinned `rust-overlay` input exposes Rust nightly 2026-08-03 while
the repository's Amaru pin and bootstrap behavior remain unchanged.

## Requirements

- **R84-01**: Replace the `rust-overlay` lock revision with a current,
  immutable upstream revision that exposes nightly 2026-08-03.
- **R84-02**: Leave every other flake input identity unchanged,
  including `amaru` and `cardano-configurations`.
- **R84-03**: Leave peer-snapshot, producer, relay, and runtime
  behavior untouched.
- **R84-04**: Record the two incident evidence links in the PR body.
- **R84-05**: Obtain all required repository CI contexts on the exact
  PR head.

## Invariants

- **I84-01 — requested nightly resolves**: evaluation of the overlay's
  nightly 2026-08-03 toolchain fails at the issue base and succeeds at
  the candidate revision.
- **I84-02 — single-input movement**: the only changed flake lock node
  is `rust-overlay`; the root input mapping and all other locked nodes
  are byte-equivalent as structured values.
- **I84-03 — downstream identities fixed**: the `amaru` and
  `cardano-configurations` locked revisions are unchanged from
  `889e5cb`.
- **I84-04 — behavior fence**: no path under `nix/peer-snapshots/`,
  `scripts/`, `lib/`, or `tests/` changes.
- **I84-05 — repository acceptance**: the PR head passes every required
  Build Gate and live-verifier context.

## Rejection behavior

Reject a candidate if the requested nightly is absent, any unrelated
lock node moves, any forbidden behavior path changes, or required CI is
not green on the exact head.
