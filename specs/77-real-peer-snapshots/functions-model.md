# Functions model — #77 (v3)

No Haskell/Rust functions change. Executable surfaces:

- F1 `scripts/resolve-peer-snapshots` — BUMP-TIME tool (I3b), never CI.
  - args: `--write` to update `nix/peer-snapshots/resolution.json`;
    default is check-only (print proposed record + diff vs committed one).
  - env: `GITHUB_TOKEN`/`GH_TOKEN` (optional), `FLAKE_LOCK` (optional
    path override, default `./flake.lock`).
  - effects: network reads (api.github.com, raw.githubusercontent.com);
    writes only the record file (with `--write`) and a temp dir.
  - result: exit 0 iff rule-resolved rev == pinned configs rev AND
    fetched bytes == flake-input bytes AND (check-only) proposed record
    == committed record; non-zero otherwise, printing pinned vs resolved
    and per-network hash comparison.
- F2 nix attr `packages.<sys>.amaru` — default, real pinned contents;
  in-sandbox validation extended with the D4 anchor assertions.
- F3 nix attr `packages.<sys>.amaru-placeholder-dev` — explicit dev
  fallback only; never referenced by checks, images, or CI.
- F4 just recipe `resolve-peer-snapshots` — wraps F1 with nix-provided
  curl/jq/coreutils/diffutils.
- F5 nix attr `checks.<sys>.peer-snapshot-anchor` — offline runCommand:
  asserts D4⇔flake.lock rev agreement and D4⇔input per-network sha256;
  in `just build-gate` and the ci.yml Build Gate list.
