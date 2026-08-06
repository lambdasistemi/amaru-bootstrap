# Functions model — #77

No Haskell/Rust functions change. New executable surfaces:

- F1 `scripts/verify-peer-snapshot-resolution`
  - args: none required; env `GITHUB_TOKEN` (optional, raises rate limit),
    `FLAKE_LOCK` (optional path override, default `./flake.lock`).
  - effects: network reads (api.github.com, raw.githubusercontent.com);
    no writes outside a temp dir.
  - result: exit 0 iff pinned configs rev == rule-resolved rev AND all
    per-network fetched bytes == flake-input bytes; non-zero otherwise,
    printing pinned vs resolved rev and per-network hash comparison.
- F2 nix attr `packages.<sys>.amaru` — default, real pinned contents.
- F3 nix attr `packages.<sys>.amaru-placeholder-dev` — explicit dev
  fallback only; never referenced by checks, images, or CI.
- F4 just recipe `verify-peer-snapshots` — wraps F1 with nix-provided
  curl/jq.
