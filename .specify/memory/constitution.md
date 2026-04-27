# amaru-bootstrap Constitution

## Core Principles

### I. No Forks of Upstream Cardano Code

This project exists because Amaru's existing testnet bootstrapping
([`pragma-org/amaru/docker/testnet`](https://github.com/pragma-org/amaru/tree/main/docker/testnet))
depends on a personal fork of `ouroboros-consensus`
([`abailly/snapshot-generator`](https://github.com/abailly/ouroboros-consensus/tree/abailly/snapshot-generator),
1300+ commits behind upstream). That fork is the failure mode this
project replaces.

Rule: every Cardano-ecosystem dependency is consumed via stock IOG
releases (CHaP for Haskell, GitHub releases or tagged commits for
Rust). If a needed feature does not exist upstream, the response is
either (a) upstream a small standalone tool that depends on
`ouroboros-consensus-cardano` as a *library*, or (b) submit the
feature to IOG. Forking is not an option.

### II. Stock Tools, Custom Orchestration

Every step of the bootstrap pipeline must use a stock IOG (or pragma)
binary:

- `db-synthesizer` (upstream `ouroboros-consensus`) — chain DB synthesis
- `db-analyser --store-ledger` (upstream `ouroboros-consensus`) — ledger snapshots
- `db-server` ([`pragma-org/db-server`](https://github.com/pragma-org/db-server)) — header extraction
- `amaru` ([`pragma-org/amaru`](https://github.com/pragma-org/amaru)) — convert / import / run

This repo's job is to **orchestrate** these tools, not extend them.

### III. Reproducibility By Pinning, Not By Tags

Rule: every dependency is pinned to a commit SHA, never a moving tag.

- Haskell tools: pinned via `cabal.project` `index-state` and
  `source-repository-package` SHAs (with nix32 `--sha256`)
- Rust amaru: pinned via `flake.lock` SHA on the `pragma-org/amaru`
  flake input
- Docker images we publish: tagged with the consumer's commit SHA, not
  `:main` or `:latest`

A `:main` tag in any production-facing artifact is a bug.

### IV. Nix-First, haskell.nix For Haskell

Rule: this is a Nix-first repo with haskell.nix as the Haskell layer.

- `flake.nix` thin, real config under `nix/{project,checks,apps}.nix`
- IOG cache (`hydra.iohk.io`) and CHaP for Cardano dependencies
- `crane` only for the Rust amaru wrapper, kept in a separate module
- `runs-on: nixos` for all CI jobs (lambdasistemi self-hosted runner)
- Build Gate first, downstream jobs gated on it
- Never `nix develop -c cabal test` in CI; always `nix build .#checks.*`

### V. Smallest Provable Step

Rule: prove an assumption with a smoke test before scaffolding around
it. The Phase 0 hypothesis (`db-analyser --store-ledger` output is
consumable by `amaru convert-ledger-state`) gates everything that
follows. If it fails, the whole project pivots — we do not want to
discover that after building infrastructure.

## Code Quality Gates

- All Haskell code Hackage-ready: `cabal check` clean, `-Werror`,
  Haddock on all exports, fourmolu (70-char limit, leading commas/arrows),
  hlint clean
- All shell scripts shellcheck clean, `set -euo pipefail`
- `just ci` mirrors the GitHub CI workflow; runs locally before every push
- Conventional Commits for release-please version inference

## Development Workflow

- Every ticket runs through speckit: `specify` -> `plan` -> `tasks` ->
  `implement`. No implementation without a spec.
- One worktree per branch; main repo stays on `main`.
- Linear history on `main` (rebase merge only).
- PR descriptions are living documents - updated with every push.
- All PRs labeled (`feat`/`fix`/`chore`/...) and assigned.
- Big deletions need explicit user approval before execution.
- Branch protection: `Build Gate` required, admin bypass only.

## Out of Scope

- Replacing or extending Amaru itself - this repo only produces the
  bootstrap bundle Amaru consumes
- Maintaining a fork of `ouroboros-consensus`, `cardano-node`, or any
  IOG repo
- Custom testnet generation - pre-generated configs are inputs

## Governance

This constitution supersedes all other practices in this repo.
Amendments require a PR, a rationale in the PR description, and the
`Last Amended` date below to be bumped.

All PRs must verify compliance with these principles. When the
constitution and a convenience are in conflict, the constitution wins.

**Version**: 1.0.0 | **Ratified**: 2026-04-27 | **Last Amended**: 2026-04-27
