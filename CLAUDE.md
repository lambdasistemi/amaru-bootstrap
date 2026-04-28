# amaru-bootstrap

Project-specific guidance for AI agents. **Read [`.specify/memory/constitution.md`](./.specify/memory/constitution.md) first** — it gates all design decisions.

## Workflow

- Every ticket runs through speckit: `speckit-specify` -> `speckit-plan` -> `speckit-tasks` -> `speckit-implement`. No implementation without a spec on disk.
- One worktree per branch. Main repo (`/code/amaru-bootstrap`) stays on `main`; feature work happens in `/code/amaru-bootstrap-<short>`.
- Linear history on `main` (rebase merge only).
- Branch protection: `Build Gate` required, admin bypass.

## Tooling

- **Nix-first**: every binary built and run via the flake. Never `pip install`, `cargo install`, `cabal install`, `curl | sh`.
- **Haskell tools** (`db-synthesizer`, `db-analyser`): haskell.nix + CHaP, declared in `cabal.project`, exposed via `nix/iog-tools.nix`.
- **Rust tool** (`amaru`): crane wrapping `pragma-org/amaru` flake input, exposed via `nix/amaru.nix`.
- **Orchestrator** (`scripts/smoke-test.sh`): bash, shellcheck-clean, `set -euo pipefail`.
- **CI**: `runs-on: nixos`. Build Gate first; downstream jobs gated. Never `nix develop -c cabal test` in CI — always `nix build .#checks.<system>.<name>`.

## Pinning discipline (constitution Principle III)

- All Haskell SRPs in `cabal.project` carry `--sha256:` in **nix32** format (NOT SRI). Use `nix flake prefetch` then `nix hash convert --to nix32`.
- All Docker images in any production-facing context tagged by commit SHA. `:main` is a bug.

## Speckit phase budgets

- `plan.md` <= 200 lines. Push detail into `research.md`, `data-model.md`, `contracts/`, `quickstart.md`.
- After each `speckit-implement` phase, compact a Status block back into `plan.md`.

## Active feature

- `001-snapshot-format-smoke` — Phase 0 hypothesis-validation smoke test. See [`specs/001-snapshot-format-smoke/`](./specs/001-snapshot-format-smoke/).

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->

## Active Technologies
- Haskell GHC 9.6.7 via haskell.nix (same toolchain as the Phase 0 marker library) (002-snapshot-emitter)
- filesystem only — read 2 files in, write 1 file out; no database, no state (002-snapshot-emitter)

## Recent Changes
- 002-snapshot-emitter: Added Haskell GHC 9.6.7 via haskell.nix (same toolchain as the Phase 0 marker library)
