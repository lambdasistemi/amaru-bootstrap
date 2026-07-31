# Implementation Plan: Daily Validated Amaru Image Handoff

**Branch**: `ci/75-daily-amaru-handoff` | **Date**: 2026-07-31 |
**Spec**: [spec.md](spec.md)
**Input**: Feature specification from
`/specs/075-daily-amaru-handoff/spec.md`

## Summary

Add one fail-closed daily reconciliation state machine with an injected test
transport and a production GitHub transport. It observes bare upstream main,
updates only the exact Amaru SHA through a protected pull request when needed,
waits for final-main CI and SHA-tagged image publication, and emits strict
public release receipts. The same implementation drives schedule and manual
triggers; pull requests run deterministic fixtures and an explicitly enabled
scoped-App event probe before production schedule activation.

## Technical Context

**Language/Version**: Bash 5 with `set -euo pipefail`; GitHub Actions YAML;
JSON Schema draft 2020-12

**Primary Dependencies**: Nix, `git`, `gh`, `jq`, Docker/registry inspection,
`actions/create-github-app-token`, existing CI and image publication workflows

**Storage**: Canonical public JSON assets on uniquely tagged GitHub Releases;
ephemeral workflow artifacts for image-publication transport evidence

**Testing**: Bats with injected transport, JSON/schema and cross-field
validation, shellcheck, actionlint, exact Build Gate reachability,
`just build-gate`, `just ci`, same-repository hosted PR fixtures and App probe

**Target Platform**: x86_64 Linux on self-hosted NixOS runners; public GitHub
and GHCR boundaries

**Project Type**: Nix-first supplier image and CI automation repository

**Performance Goals**: one UTC reconciliation per day; bounded API polling;
identical retries publish zero replacement bytes

**Constraints**: exact upstream SHA; no fork/tag/patch; no direct protected-main
push; no long-lived credential; no moving image tag; no partial handoff; no
producer/runtime or downstream changes

**Scale/Scope**: one upstream input, one protected automation PR at a time,
one handoff per source tuple, one daily result per UTC day

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | Resolver and pin gate accept only bare `pragma-org/amaru` main and one full SHA |
| II. Stock tools, custom orchestration | PASS | Stock Git/GitHub/Nix/registry tools are orchestrated; no upstream code is patched |
| III. Reproducibility by SHA | PASS | Source, bootstrap, image tag, digest, and evidence blobs are immutable identities |
| IV. Nix-first | PASS | Focused tests/lint are flake checks and the exact existing Build Gate remains authoritative |
| V. Smallest provable step | PASS | One vertical reconcile-to-receipt slice with every failure seam injected before production activation |

Post-design check: PASS. The design adds orchestration and strict receipts,
not a fork, upstream patch, producer behavior, moving tag, or long-lived key.

## Boundary Review

The changed system has five seams that must agree:

```text
bare upstream → exact pin PR → final-main CI → SHA image publication
              → public handoff → day result
```

Unit success on any one side is insufficient. The focused suite injects the
transport and drives the complete state machine. Hosted PR evidence crosses
the App-event/rules seam. The existing Build Gate and Docker live verifier
cross the real binary and producer/runtime seams. The production handoff is
created only after final-main CI and registry digest evidence agree.

## Project Structure

### Documentation for this ticket

```text
specs/075-daily-amaru-handoff/
├── checklists/requirements.md
├── contracts/
│   ├── daily-result-v1.schema.json
│   ├── handoff-v1.schema.json
│   └── image-publication-v1.schema.json
├── data-model.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
```

### Implementation surface

```text
.github/workflows/
├── daily-amaru-handoff.yml
└── publish-bootstrap-image.yml
docs/
└── daily-amaru-handoff.md
scripts/
└── daily-amaru-handoff.sh
tests/
├── fixtures/daily-amaru-handoff/**
└── test-daily-amaru-handoff.bats
flake.nix
flake.lock
justfile
mkdocs.yml
nix/checks.nix
```

`tests/lib/cli-mock-surface.bash` is evidence-only temporary mutation for the
negative control and must be byte-restored before the implementation diff is
frozen. `.github/workflows/ci.yml` is read-only evidence proving the existing
Build Gate invocation.

**Structure Decision**: Keep orchestration in one testable Bash executable,
wire it through focused GitHub Actions, register its deterministic checks in
the existing Nix check set, and document only the public/operator contract.

## Slice 1 - Reconcile, validate, publish receipts, and wire automation

**Risk tier**: PAIR. This slice owns authentication, immutable publication,
protected integration, and a cross-repository contract; semantic review is
mandatory even where individual edits are mechanical.

**Provider allocation**:

- driver: Qwen CLI `qwen3.8-max-preview`, pinned explicitly;
- navigator: `codex-raw` model `gpt-5.6-sol`, reasoning effort `xhigh`;
- Claude-backed workers: forbidden while the exact generic release-hold file
  is absent;
- retired `agy`: forbidden;
- nested driver tools: forbidden because no approved external sandbox and
  attestation launcher is named; `workhorse-usage=NORMAL`, eligible=0.

**Owned files**:

- `.github/workflows/daily-amaru-handoff.yml` (new)
- `.github/workflows/publish-bootstrap-image.yml` (minimum publication receipt
  and digest evidence only)
- `scripts/daily-amaru-handoff.sh` (new)
- `tests/test-daily-amaru-handoff.bats` (new)
- `tests/fixtures/daily-amaru-handoff/**` (new)
- `nix/checks.nix`
- `justfile`
- `docs/daily-amaru-handoff.md` (new)
- `mkdocs.yml` (one navigation entry only)
- `flake.nix` and `flake.lock` only by running the new exact-SHA updater
  against the freshly observed bare upstream SHA and proving all non-Amaru
  lock nodes unchanged

**Evidence-only temporary file**:

- `tests/lib/cli-mock-surface.bash`: one mock-only rejected command during the
  CLI reachability negative control; restore by inverse patch and hash proof
  before freezing any GREEN diff.

**Forbidden scope**: producer/relay scripts, accepted CLI mocks/tests,
`nix/amaru.nix`, Cardano dependencies, Haskell, image contents, bootstrap
bundle semantics, any downstream repository, Antithesis, spec artifacts,
`gate.sh`, Git configuration, secrets, branch rules, and every other worktree.
If the newly selected upstream requires a producer/build compatibility change
outside this fence, stop with a Q-file; do not widen or work around it.

### RED and pre-falsification

The ticket-owner gate is frozen before dispatch and fails on the accepted base
because the strict state machine and focused flake check do not exist. The
PAIR must then prove:

1. an injected changed input reaches the exact observed-SHA proposal and no
   success receipt before complete evidence;
2. an injected real-equal tuple with a valid handoff reaches `UNCHANGED` and
   performs zero pin/image mutation;
3. wrong owner/repository/ref fails before mutation;
4. absent CI, publication receipt, or digest each fail before handoff;
5. an existing same-key different receipt fails without replacement;
6. a temporary mock-only CLI command makes the exact `just build-gate` path
   fail, followed by byte-exact restoration.

The driver writes tests first, observes their expected failures, freezes RED,
and receives literal navigator RED approval before production implementation.

### GREEN

- The exact same focused tests pass through the injected transport.
- All three strict schemas reject unknown/missing/wrong-identity fields; the
  runtime validator proves cross-field equality and canonical bytes.
- `scripts/daily-amaru-handoff.sh` is the only state machine used by schedule,
  manual, and PR fixture paths.
- The production transport mints only a repository-scoped App token, never
  prints it, uses a PR and required check, and binds final evidence to the
  integrated bootstrap SHA.
- Release publication is create-or-compare and never replace/delete.
- Image publication exposes a strict digest receipt for the exact source SHA.
- The hosted App probe is same-repository, explicit-label gated, disposable,
  exact-target cleaned, and verifies the live rules endpoint plus observed
  `Build Gate` event.
- The updater is run against a fresh bare upstream observation in this branch;
  the final pin equals that observation and every non-Amaru lock node is
  unchanged.
- The restored CLI surface, focused flake check, exact Build Gate, and full
  Docker CI are green after the final edit.

**Commit**: `feat(ci): publish daily validated amaru handoff`

**Trailer**:
`Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010, T011, T012`

## Finalization - Hosted and ticket acceptance (orchestrator-owned)

After the driver commit and navigator verification agree, the ticket owner
inspects the complete diff, reruns the immutable slice gate and ticket gate,
stamps T001-T012 into the local commit, pushes, and refreshes the draft PR.
The owner then enables the explicit App-probe PR path, verifies its exact
hosted evidence and cleanup, verifies current-head CI and PR image publication
receipt, runs final local gates/audits, stamps finalization tasks in a forward
docs commit if necessary, marks the PR ready, and hands it to the epic owner.
The ticket owner does not merge or activate production through an out-of-band
operation.

## Complexity Tracking

No constitutional violation or exception is required. Three receipt types are
separate because they have different producers, required fields, and immutable
keys; combining them would make partial-state validation weaker.
