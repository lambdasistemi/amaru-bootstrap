---
name: amaru-bootstrap-guide
description: Working guide for the lambdasistemi/amaru-bootstrap repository, which builds the ghcr.io/lambdasistemi/amaru-bootstrap-producer Docker image and tools for bootstrapping relay-only Amaru nodes on custom Cardano testnets. Load when working on or asking about bootstrap-producer, amaru-relay-bootstrap, header-extractor, ledger-state-emitter, amaru create-snapshots, amaru bootstrap, amaru run, the testnet_42 fixture, era-history.json or global-parameters.json runtime files, bundle layout (ledger.<network>.db, chain.<network>.db), the era-readiness predicate, producer exit codes (cluster-not-ready, chain-not-era-ready), Antithesis amaru-relay-N containers and startup markers, scripts/bootstrap-producer.sh, scripts/amaru-relay-bootstrap.sh, scripts/smoke-test.sh, nix flake checks like bootstrap-producer-synthesized or antithesis-short-epoch-golden, the cardano-node 10.7.1 pin, or the just recipes (just ci, just smoke, just build-gate, just live-bootstrap-producer).
---

# amaru-bootstrap guide

## Repository map

- `scripts/bootstrap-producer.sh` — the one-shot producer orchestrator
  (preflight → targets → `amaru create-snapshots` → era-history
  sidecars → `amaru bootstrap` → atomic commit). The production
  deliverable.
- `scripts/amaru-relay-bootstrap.sh` — Antithesis relay container
  entrypoint: startup marker, producer retry loop, bundle promotion,
  final `exec amaru run`.
- `scripts/smoke-test.sh` — Phase 0 format-compatibility smoke test
  (db-synthesizer → db-analyser `--store-ledger` →
  `amaru convert-ledger-state`).
- `lib/` — Haskell library: `HeaderExtractor` (tip-info, list-blocks,
  get-header over the immutable ChainDB), `LedgerStateEmitter`
  (node-10.7.1 → Amaru legacy `ExtLedgerState` projection),
  `AmaruBootstrap` (marker module so haskell.nix resolves the pinned
  consensus packages).
- `app/header-extractor/`, `app/ledger-state-emitter/` — CLI wrappers
  over the library (optparse-applicative; failures exit 7).
- `nix/` — `project.nix` (haskell.nix), `amaru.nix` (crane build of the
  pinned Amaru), `iog-tools.nix` (db-synthesizer, db-analyser,
  snapshot-converter from the pinned consensus), `apps.nix` (flake
  apps), `checks.nix` (all flake checks),
  `bootstrap-producer-image.nix` (layered Docker image).
- `tests/` — bats suites for the producer, relay, and smoke scripts;
  `test/` — hspec suite for `HeaderExtractor`.
- `specs/` — speckit feature specs; `specs/003-amaru-bootstrap-producer/`
  holds the producer contract, research (R-001…R-011), and data model.
- `docs/` + `mkdocs.yml` — MkDocs Material site;
  `.specify/memory/constitution.md` — project principles (symlinked at
  `docs/constitution.md`).
- `.github/workflows/` — `ci.yml` (Build Gate + smoke verdict + live
  verifier), `publish-bootstrap-image.yml` (GHCR push, SHA tags),
  `deploy-docs.yml` (mkdocs gh-deploy).

## Build, test, run

- `just build-gate` — build every flake check CI's Build Gate builds.
- `just ci` — full local CI mirror (Build Gate, Phase 0 smoke verdict,
  Docker-level live verifier; needs a Docker daemon for the last step).
- `just smoke` — smoke test against the vendored fixture
  (`specs/001-snapshot-format-smoke/fixtures/p1-config`).
- `just live-bootstrap-producer` — Docker-level verifier against a real
  `cardano-node:10.7.1` container.
- Single check: `nix build .#checks.x86_64-linux.<name>` — names:
  `amaru`, `db-synthesizer`, `db-analyser`, `ledger-state-emitter`,
  `shellcheck`, `smoke-test-bats`, `header-extractor-spec`,
  `header-extractor-cli-bats`, `bootstrap-producer-bats`,
  `bootstrap-producer-synthesized`, `amaru-run-bootstrap`,
  `antithesis-short-epoch-samples`, `antithesis-short-epoch-golden`,
  `bootstrap-producer-image`.
- Run the producer locally:
  `nix run .#bootstrap-producer -- <chain-db> <config-dir> <bundle-dir> <network>`.
- Everything is x86_64-linux only.

## Navigating the code

- The producer's behavior contract (arguments, exit codes, state
  machine) is documented at the top of `scripts/bootstrap-producer.sh`
  and in `specs/003-amaru-bootstrap-producer/contracts/` and
  `data-model.md`.
- The era-readiness predicate (tip in Conway, tip epoch >= 3, a block
  in each of the three most recent completed epochs) lives in
  `phase_preflight` in `scripts/bootstrap-producer.sh`, with the
  rationale in the long comment above the polling loop.
- The bundle-completeness predicate (`bundle_complete`) exists twice:
  in `scripts/bootstrap-producer.sh` (standalone) and
  `scripts/amaru-relay-bootstrap.sh` (relay, additionally requires
  RocksDB `CURRENT` files and the `.bootstrap-complete` sentinel).
  Keep them consistent when changing the bundle shape.
- The ledger projection rules (UTxO canonical CBOR, pre-Peras wrapper,
  PState/DState projection, completed zero reward update) are in the
  module haddock of `lib/LedgerStateEmitter.hs` and in
  `specs/003-amaru-bootstrap-producer/research.md` R-011.
- The pinned dependency set is in `cabal.project` (CHaP index states,
  consensus 3.0.1.0 source-repository-package with nix32 `--sha256`)
  and `flake.nix` inputs (Amaru pinned to
  `lambdasistemi/amaru/feat/testnet-bootstrap` via `flake.lock`).
- CI check definitions are all in `nix/checks.nix`; the synthesized
  fixtures (`mkSynthesizedChainDb`, the short-epoch corpus) are defined
  at the top of that file.

## Using the bootstrap-producer image

- Published tags:
  `ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>`
  (after CI on `main`) plus `:<pr-head-sha>` and
  `:pr-<number>-<pr-head-sha>` for same-repo PRs. Never use a moving
  tag.
- Default entrypoint is `bootstrap-producer` taking
  `<chain-db> <config-dir> <bundle-dir> <network>`; Antithesis relay
  services override `entrypoint: amaru-relay-bootstrap` and configure
  via `RELAY_NAME`, `AMARU_PEER`, `AMARU_NETWORK`,
  `AMARU_BOOTSTRAP_RETRY_SECONDS` (see `docs/antithesis.md` for the
  full env table).
- The chain DB must be mounted read-write even though the producer only
  reads immutable chunks (node-10.7.1 consensus opens chunk files with
  write permissions); the relay copies `/live` to scratch for this.
- Producer exit codes: 0 success/already-complete, 1 cluster-not-ready,
  2 chain-not-era-ready, 3 configuration error, 5 targets error,
  6 create-snapshots error, 7 header-extractor error, 9 bootstrap
  error, 10 commit error, >=64 internal. The relay retries 1/2/5/6/7/8.
- The bundle that `amaru run` consumes: `ledger.<network>.db/` (live +
  >=3 numeric epoch snapshots), `chain.<network>.db/` (nonces and
  headers baked in), `snapshots/<network>/`, `era-history.json`.
  `amaru run` additionally needs deployment-provided
  `era-history.json` and `global-parameters.json` (mounted at
  `/amaru-runtime` in relay mode).

## Answering questions

- "What does this repo do / how does bootstrap work?" — README
  *What is this* + *Architecture*; the full pipeline is in
  `docs/architecture.md`, and `scripts/bootstrap-producer.sh` is the
  source of truth.
- "How do I wire it into a Compose testnet?" — `docs/tutorial.md`
  (relay shape) and `docs/antithesis.md` (env contract, startup
  markers, runtime parameter files).
- "Why doesn't Amaru start / wrong nonces / epoch boundaries?" — check
  the era-history story: sidecars and bundle-root `era-history.json` in
  `docs/bootstrap-producer.md`, runtime files in `docs/antithesis.md`.
- "Why is everything pinned to cardano-node 10.7.1?" — README
  *Compatibility target*, `docs/architecture.md` *Node-Release
  Boundary*, `cabal.project` comments.
- "Why no fork of consensus / why these tools?" — the constitution
  (`.specify/memory/constitution.md`) and
  `docs/history/what-amaru-needs.md` for how the pipeline evolved
  (emit/convert/import → create-snapshots/bootstrap).
- "What proves this works?" — the Verification section of
  `docs/bootstrap-producer.md` maps each flake check to what it
  asserts.
