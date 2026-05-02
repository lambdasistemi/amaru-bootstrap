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
- `005-amaru-run-live-test` — extends the live cardano-node verifier to run amaru against the produced bundle (closes [issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34)). See [`specs/005-amaru-run-live-test/`](./specs/005-amaru-run-live-test/).

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->

## Active Technologies
- Bash 5.x (orchestrator script); Haskell GHC 9.6.x (existing tools, plus the small header-extractor tool from R-001) (003-amaru-bootstrap-producer)
- filesystem only — read cluster's chain DB, write the bundle to a docker volume. No database, no state. (003-amaru-bootstrap-producer)
- Bash 5.x (test orchestration); bats-core (existing test runner). + docker-client, cardano-node 10.7.1 image, db-synthesizer (haskell.nix), `amaru` (crane via `nix/amaru.nix`), bats, jq, gnugrep, coreutils. (005-amaru-run-live-test)
- Filesystem only — `$TMP_DIR` per bats test as today; no DB. (005-amaru-run-live-test)

## Recent Changes
- 003-amaru-bootstrap-producer: Added Bash 5.x (orchestrator script); Haskell GHC 9.6.x (existing tools, plus the small header-extractor tool from R-001)
