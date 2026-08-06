# Modules model — #77

No Haskell/Rust modules change. Component responsibilities:

- M1 `flake.nix` — owns the `cardano-configurations` pin (rev string is the
  single source of truth); passes the input and its rev to M2.
- M2 `nix/amaru.nix` — owns staging + in-sandbox validation of peer
  snapshots; depends on M1's input; exposes `amaru` (real contents,
  default) and `amaru-placeholder-dev` (explicit dev fallback). Nothing
  else may select the placeholder path.
- M3 `scripts/verify-peer-snapshot-resolution` — owns online re-derivation
  of the upstream rule; reads only `flake.lock` + the store input; no
  dependency on M2 internals.
- M4 `docs/peer-snapshots.md` — owns the human/automation-facing rule and
  bump procedure; references M1/M3 by path.

Dependency direction: M2 → M1; M3 → M1(lock); M4 → (M1, M3). No cycle.
