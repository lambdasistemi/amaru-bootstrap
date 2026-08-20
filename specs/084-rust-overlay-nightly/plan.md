# Implementation plan: rust-overlay nightly availability

Artifact ceiling: 2 KiB

## Strategy

Use one dependency-only slice. Update exactly the `rust-overlay` flake
lock node from its current upstream source, then evaluate the overlay's
nightly 2026-08-03 derivation without realizing the Rust toolchain.

The evaluation witness is the cheapest honest proof because the defect
is toolchain availability during flake evaluation. A full local Amaru
realization would prove more than this input-only change requires and is
constrained by the host's Nix-store reserve. Full repository coverage is
instead required from CI on the exact PR head.

## Constraints

- Preserve the Amaru and cardano-configurations pins.
- Preserve all peer-snapshot and bootstrap/runtime surfaces.
- Use the existing locked GitHub source form; do not introduce a
  ref-resolving shorthand.
- Stop before any large cold realization and report its dry-run size.
- Do not publish or contact repositories outside the designated working
  set.

## Slice S84-01

Deliver R84-01 through R84-05 as one bisect-safe dependency update.
The frozen gate proves I84-01 through I84-04 locally. A fresh auditor
checks the consolidated candidate, and hosted required contexts prove
I84-05 after the exact accepted commit is pushed.

## Verification

- Focused pre-change negative control and post-change evaluation of
  nightly 2026-08-03.
- Structured lock-node comparison against `889e5cb`.
- Changed-path fence against behavior and peer-snapshot surfaces.
- `nix build .#checks.x86_64-linux.amaru` only when its dry run shows
  no unsafe cold realization.
- Required GitHub checks on the exact PR head.
