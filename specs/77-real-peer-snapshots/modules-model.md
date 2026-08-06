# Modules model — #77 (v3)

No Haskell/Rust modules change. Component responsibilities:

- M1 `flake.nix` — owns the `cardano-configurations` pin (rev string is the
  single source of truth); passes the input and its rev to M2.
- M2 `nix/amaru.nix` — owns staging + in-sandbox validation of peer
  snapshots; depends on M1's input; exposes `amaru` (real contents,
  default) and `amaru-placeholder-dev` (explicit dev fallback). Nothing
  else may select the placeholder path.
- M3 `scripts/resolve-peer-snapshots` — owns online re-derivation of the
  upstream rule at BUMP TIME and ownership of the M5 record's contents;
  reads `flake.lock` + the store input; never runs in CI; no dependency on
  M2 internals.
- M4 `docs/peer-snapshots.md` — owns the human/automation-facing rule,
  anchoring rationale, and bump procedure; references M1/M3/M5 by path.
- M5 `nix/peer-snapshots/resolution.json` — the anchored resolution record
  (D4); written only by M3 (or a human at bump review); read by M2's
  validation and by `checks.peer-snapshot-anchor`.

Dependency direction: M2 → (M1, M5); M3 → (M1(lock), M5-write);
M4 → (M1, M3, M5); anchor check → (M1, M5). No cycle.
