# Repository Agent Guide

## What this repo is

`amaru-bootstrap` builds the
`ghcr.io/lambdasistemi/amaru-bootstrap-producer` Docker image and the
tools inside it, used to start relay-only
[Amaru](https://github.com/pragma-org/amaru) nodes on custom Cardano
testnets (primarily the Antithesis testnets in
`cardano-foundation/cardano-node-antithesis`). Amaru cannot sync such
testnets from genesis, so the `bootstrap-producer` orchestrator reads a
cardano-node ChainDB, drives `amaru create-snapshots` and
`amaru bootstrap`, and commits a bundle of ledger/chain stores that
`amaru run` opens. Everything is pinned to one cardano-node release at a
time (currently 10.7.1) because ledger-state CBOR drifts between
releases.

Read [`.specify/memory/constitution.md`](.specify/memory/constitution.md)
before making design decisions — it gates them (no forks of upstream
Cardano code, stock tools + custom orchestration, SHA pinning, Nix-first).

## How to work here

- Build/test everything CI builds: `just build-gate`
- Full local CI mirror (Build Gate + Phase 0 smoke verdict + Docker live
  verifier): `just ci`
- Phase 0 smoke test against the vendored fixture: `just smoke`
- One flake check: `nix build .#checks.x86_64-linux.<name>` (never
  `nix develop -c cabal test` in CI)
- Run a tool: `nix run .#bootstrap-producer`, `.#smoke-test`,
  `.#header-extractor`, `.#ledger-state-emitter`, `.#amaru`,
  `.#db-synthesizer`, `.#db-analyser`, `.#snapshot-converter`
- Shell lint: `just shellcheck`; scripts are bash with
  `set -euo pipefail`, shellcheck-clean
- Haskell: GHC 9.6, fourmolu (70-char limit, leading commas/arrows),
  Haddock on all exports, Hackage-ready (`cabal check` clean)
- Pinning discipline: cabal `source-repository-package` entries carry
  nix32 `--sha256` (not SRI); Docker images are tagged by commit SHA,
  never `:main`/`:latest`
- Workflow: every ticket runs through speckit
  (`specify` → `plan` → `tasks` → `implement`); specs live under
  `specs/`; linear history on `main` (rebase merge only); `Build Gate`
  is the required CI check
- CI runs on self-hosted `nixos` runners; the docs site deploys via
  `mkdocs gh-deploy` from `.github/workflows/deploy-docs.yml`

## Skills

Activatable procedures live under `skills/`. Load the one whose
description matches your task:

- [`skills/amaru-bootstrap-guide/`](skills/amaru-bootstrap-guide/SKILL.md)
  — repository map, build/test/run commands, code navigation, and how to
  use the bootstrap-producer image and its tools.
