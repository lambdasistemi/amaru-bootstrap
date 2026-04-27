# Research: Snapshot Format Smoke Test

Notes for [`plan.md`](./plan.md). Each entry: **Decision** / **Rationale** / **Alternatives considered**.

## R-001: `db-analyser --store-ledger` is upstream and unmodified

**Decision**: rely on stock `db-analyser` from `IntersectMBO/ouroboros-consensus`. The `--store-ledger SLOT` flag exists in [`DBAnalyser/Parsers.hs`](https://github.com/IntersectMBO/ouroboros-consensus/blob/main/ouroboros-consensus-cardano/app/DBAnalyser/Parsers.hs) and dumps a ledger snapshot at the named slot.

**Rationale**: Arnaud's [`abailly/snapshot-generator`](https://github.com/abailly/ouroboros-consensus/tree/abailly/snapshot-generator) fork wires snapshot emission *into* `db-synthesizer` so snapshots fall out of the same run. Equivalent outcome falls out of two stock commands (synthesize then analyse) — no fork required. This is the central premise the smoke test validates; if the format check passes, no fork is ever needed.

**Alternatives considered**:
- Adopt Arnaud's fork: rejected by constitution Principle I; also 1300+ commits behind upstream and unmaintained.
- Write our own snapshot-emitter as a standalone tool: deferred to a fallback if R-005 fails. Would still depend on `ouroboros-consensus-cardano` *as a library*, not as a fork.

## R-002: Build IOG tools via haskell.nix + CHaP

**Decision**: `nix/project.nix` declares a `haskell-nix.cabalProject'` with `cabal.project` containing a single `source-repository-package` for `IntersectMBO/ouroboros-consensus` pinned to a SHA, with `--sha256` in nix32 format. The flake exposes `iog-tools.nix` which extracts `hsPkgs.ouroboros-consensus-cardano.components.exes.db-synthesizer` and `.db-analyser`.

**Rationale**: matches the pattern used in [`haskell-csmt`](https://github.com/paolino/haskell-csmt) and [`cardano-utxo-csmt`](https://github.com/cardano-foundation/cardano-utxo-csmt) — proven, IOG-cache-warmed, deterministic. Avoids the two-hour first-build hit that crane-on-Haskell would impose.

**Alternatives considered**:
- Pull pre-built `cardano-node` Docker image and exec the binaries: rejected — `db-synthesizer` and `db-analyser` are not in the standard `cardano-node` image; we'd have to build anyway.
- Use `Cabal install` from the dev shell: rejected — `nix develop -c cabal install` violates Principle IV (CI must use `nix build .#checks.*`).
- nixpkgs's `haskellPackages.ouroboros-consensus-cardano`: not packaged at the right version for our needs and uses a different overlay system.

## R-003: Build amaru via crane

**Decision**: `pragma-org/amaru` is consumed as `inputs.amaru = { url = "github:pragma-org/amaru"; flake = false; };`. `nix/amaru.nix` invokes `craneLib.buildPackage` against the workspace at `inputs.amaru.outPath`, building the `amaru` binary with `--release`.

**Rationale**: amaru exposes no flake (verified — no `flake.nix` at repo root). Crane is the established Rust-on-Nix wrapper. Pinning happens via `flake.lock` on the `amaru` input, no separate SHA management.

**Alternatives considered**:
- naersk: less actively maintained; no advantage over crane for this use case.
- Pre-built amaru binary from GitHub Releases: amaru does not yet publish release binaries; `:main` Docker tag is moving (Principle III violation).
- Submit a flake.nix upstream to `pragma-org/amaru`: would be ideal but is out-of-scope upstream contribution; revisit later.

## R-004: Bash, not Haskell, for the orchestrator

**Decision**: `scripts/smoke-test.sh` is a single bash script with `set -euo pipefail`, shellcheck clean, ~200 lines.

**Rationale**: the logic is six steps in sequence — clean output dir, synthesize, locate epoch boundary slot, dump snapshot, run `amaru convert-ledger-state`, emit verdict. Compiled-language overhead has no payoff. If Phase 1 needs richer logic (parallelism, typed failure modes, integration with cardano-node-antithesis dispatch), the orchestrator gets rewritten in Haskell — that's a Phase 1 cost, not now.

**Alternatives considered**:
- Haskell exe: deferred. Adds ~30 minutes of build time per CI run for ~20 lines of dispatch logic.
- Just-recipe-only: rejected — recipes don't compose verdict emission and structured stderr capture cleanly.
- Python: extra runtime dependency; bash is already in the dev shell.

## R-005: Detecting the epoch boundary slot

**Decision**: read `epochLength` from the Shelley genesis JSON inside the input bundle (key `"epochLength"`), then dump the snapshot at slot `epochLength` (the first slot of epoch 1, equivalently the last slot of epoch 0 + 1). For testnet magic 42 with the vendored bundle, `epochLength = 86400`, so we dump at slot 86400.

**Rationale**: the spec only requires *one* epoch boundary to validate the format hypothesis. No need to walk the chain DB or query `db-analyser` for boundaries — the genesis arithmetic is deterministic and trivially computable from the input bundle.

**Alternatives considered**:
- Use `db-analyser --analyse-block-numbers` and parse output: more flexible but adds tool-call latency and a parsing surface area for Phase 0.
- Hardcode slot 86400: rejected — couples the orchestrator to one specific genesis. Reading from genesis JSON keeps the orchestrator generic for Phase 1.

## R-006: Fixture bundle vendoring strategy

**Decision**: copy `pragma-org/amaru/docker/testnet/p1-config/configs/{configs,keys}` into `specs/001-snapshot-format-smoke/fixtures/p1-config/`, record source SHA + license in `fixtures/PROVENANCE.md`. Do not vendor `p2..p5` — Phase 0 needs only one block-producing pool.

**Rationale**: minimum viable bundle. ~1 MB. Magic 42 is a public devnet — keys are not credentials.

**Alternatives considered**:
- Vendor all five pools: 5x the bytes for no Phase 0 benefit.
- Generate keys at smoke-test time: out-of-scope (the project's spec explicitly says we don't generate testnets).
- Reference the pragma-org repo directly via git submodule: introduces a submodule lifecycle for one directory of files we won't change. Vendor is simpler.

## R-007: Verdict emission contract

**Decision**: the orchestrator's last line on stdout is exactly one of:
- `PASS`
- `FAIL: format mismatch`
- `FAIL: tool error: <step>`
- `FAIL: configuration error: <reason>`

…where `<step>` is one of `synthesise|dump|convert` and `<reason>` is human-readable. Detail (paths, exit codes, stderr) goes to a `<out-dir>/report.txt` referenced from a penultimate stdout line: `report: <path>`.

**Rationale**: SC-001 (operator reads the verdict from one line); SC-003 (artefacts retained); FR-005 (machine-readable verdict). One-line verdict + report-path line matches Unix-pipeable conventions.

**Alternatives considered**:
- JSON verdict: more structured but harder for a human reading terminal output. Phase 0 is human-facing.
- Exit code only: too coarse — can't distinguish format mismatch from tool error.

## R-008: Where the input bundle lives at smoke-test runtime

**Decision**: smoke-test takes the input bundle path as `$1` and out-dir as `$2`. The vendored fixture is reachable as `specs/001-snapshot-format-smoke/fixtures/p1-config`, not hardcoded into the script. CI runs the smoke test with that path; an operator can point at any compatible bundle.

**Rationale**: keeps the orchestrator generalisable for Phase 1 (where bundles will be operator-supplied) while delivering Phase 0's "zero friction" property via a known-good vendored bundle.

**Alternatives considered**:
- Default `$1` to the fixture: rejected — implicit defaults bite later.
- Make the fixture path mandatory via `--bundle`: same outcome with more typing.
