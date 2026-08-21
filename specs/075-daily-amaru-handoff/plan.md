# Implementation Plan: Daily Validated Amaru Image Handoff

**Branch**: `ci/75-daily-amaru-handoff` | **Spec**: [spec.md](spec.md)
**Created**: 2026-07-31 | **Refreshed**: 2026-08-19 | **Base**: `origin/main`
`889e5cb035490b76409f22fc558c89456c822c46`

## Summary

Add one fail-closed daily reconciliation state machine with an injected test
transport and a production GitHub transport. It observes bare upstream main,
updates only the exact Amaru pin (and the rule-selected configurations pin)
through a protected pull request when needed, waits for final-main CI and
SHA-tagged image publication, and emits strict public receipts. Schedule and
manual triggers drive the same implementation; pull requests run deterministic
fixtures and an explicit scoped-App event probe before schedule activation.

Placement is in [modules-model.md](modules-model.md), signatures in
[functions-model.md](functions-model.md), fields in [data-model.md](data-model.md),
decisions in [research.md](research.md); this file owns strategy and slice order.

## Technical Context

| | |
|---|---|
| Language | Bash 5 `set -euo pipefail`; Actions YAML; JSON Schema 2020-12 |
| Dependencies | Nix, `git`, `gh`, `jq`, registry inspection, `actions/create-github-app-token`, existing CI and publication workflows |
| Storage | Canonical public JSON assets on uniquely tagged GitHub Releases |
| Testing | Bats through the injected transport, strict schema and cross-field validation, shellcheck, actionlint, exact Build Gate reachability, `just build-gate`, `just ci`, hosted PR fixtures and App probe |
| Platform | x86_64 Linux, self-hosted NixOS runners; public GitHub and GHCR |
| Constraints | exact upstream SHA; no fork/tag/patch; no direct protected-main push; no long-lived credential; no moving image tag; no partial handoff; no producer/runtime or downstream change |

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | Resolver and pin gate accept only bare `pragma-org/amaru` main and one full SHA |
| II. Stock tools, custom orchestration | PASS | Stock Git/GitHub/Nix/registry tools orchestrated; no upstream code patched |
| III. Reproducibility by SHA | PASS | Source, bootstrap, image tag, digest, and evidence blobs are immutable identities |
| IV. Nix-first | PASS | Focused tests and lint are flake checks; the existing Build Gate stays authoritative |
| V. Smallest provable step | PASS | One vertical reconcile-to-receipt slice with every failure seam injected before production activation |

Post-design: PASS — orchestration and receipts only; no fork, patch, producer change, moving tag, or long-lived key.

## What the rebase changed

`origin/main` merged issue #77 while this ticket was parked, anchoring the
peer-snapshot resolution to the Amaru revision through the required
`peer-snapshot-anchor` check. Every Amaru bump now also moves the
`cardano-configurations` pin and regenerates
`nix/peer-snapshots/resolution.json`, so FR-006 as written was unsatisfiable.

Ruled by **A-001, option C**: confine the live resolution query to the daily
bump job; keep every build and verify path offline and anchored. Full decision
record, rejected options, fences, and honest costs are in
[research.md](research.md) R-007. FR-006 is amended in [spec.md](spec.md) and
FR-021..FR-024 carry the fences. Owned surface gains exactly
`nix/peer-snapshots/resolution.json`, the `cardano-configurations` flake input,
and one sentence of `docs/peer-snapshots.md`; the gate.s lock-invariance
assertion narrows to `del(.nodes.amaru, .nodes."cardano-configurations")` and
still rejects every other lock drift.

## Boundary Review

Five seams must agree — `bare upstream → exact pin PR → final-main CI → SHA
image publication → public handoff → day result`.

Unit success on any one side is insufficient. The focused suite injects the
transport and drives the whole state machine; hosted PR evidence crosses the
App-event and rules seam; the Build Gate and Docker live verifier cross the
real-binary and producer/runtime seams. The handoff is created only after
final-main CI and registry digest evidence agree.

A sixth seam is new and easy to miss: `.github/workflows/ci.yml` duplicates the
Build Gate list instead of calling `just build-gate`, so a check registered only
in `nix/checks.nix` and `justfile` is green whatever it asserts. FR-025 and
M-007 own that wiring.

## Implementation surface

Every path, its owning component, and its dependency direction are in
[modules-model.md](modules-model.md) M-001..M-009. Slice 1 owns all of them
except the pin-mutation rows (`flake.nix`, `flake.lock`,
`nix/peer-snapshots/resolution.json`, `docs/peer-snapshots.md`), which are
slice 2.

`tests/lib/cli-mock-surface.bash` is evidence-only temporary mutation for the
negative control and must be byte-restored before any GREEN diff is frozen.

**Structure Decision**: keep orchestration in one testable Bash executable, wire
it through focused GitHub Actions, register its deterministic checks in the Nix
check set and both Build Gate lists, and document only the public contract.

## Slice 1 — reconcile, validate, publish receipts, wire automation

**Topology**: `OWNER`. The slice owns authentication, immutable publication,
protected integration, and a cross-organization contract, so a gate cannot
supply acceptance and LIGHT is unavailable.

**Seat allocation** (NOTE-025 minimize-Codex; derived by
`alternate-authoritative-cli`, not copied): ticket owner Claude
`claude-opus-5[1m]` high; commit owner Grok `grok --always-approve -m grok-4.6`
in its own pane; a fresh Claude `claude-opus-5[1m]` high auditor per submission
in a new pane and root. Draft is `qwen` or `NONE`, never authoritative. `agy`
is revoked. A Codex seat needs both Claude and Grok unavailable, disclosed in
STATUS first.

**Secrets bar**: the slice writes workflow YAML that *names* hosted secrets and
mints a short-lived App token at runtime; it handles no credential material in
the repository, which was ruled clear for a Grok seat. Real credential material
inside the fence escalates by Q-file rather than improvising.

**Owned files**: the Implementation surface rows above, minus the pin-mutation
rows (`flake.nix`, `flake.lock`, `nix/peer-snapshots/resolution.json`), which
belong to slice 2.

**Forbidden scope**: producer and relay scripts, accepted CLI mocks,
`nix/amaru.nix`, Cardano dependency pins other than the rule-selected
`cardano-configurations` pin in slice 2, `scripts/resolve-peer-snapshots` and
the resolution rule itself, Haskell, image contents, bootstrap bundle
semantics, any downstream repository, Antithesis, spec artifacts, `gate.sh`,
Git configuration, secrets, branch rules, and every other worktree.

### RED and pre-falsification

The ticket gate is frozen before dispatch and fails on the accepted base because
the state machine and focused flake check do not exist. Before production code
the commit owner must prove, each shown able to fail on the unmodified base and
not merely present:

1. an injected changed input reaches the exact observed-SHA proposal and emits
   no success receipt before complete evidence;
2. an injected equal tuple with a valid handoff reaches `UNCHANGED` with zero
   pin or image mutation;
3. wrong owner, repository, or ref fails before mutation;
4. absent CI, publication receipt, or digest each fail before handoff;
5. an existing same-key different receipt fails without replacement;
6. a temporary mock-only CLI command makes the exact `just build-gate` path
   fail, followed by byte-exact restoration.

### GREEN

- the same focused tests pass through the injected transport;
- all three strict schemas reject unknown, missing, and wrong-identity fields;
  the runtime validator proves cross-field equality and canonical bytes;
- `scripts/daily-amaru-handoff.sh` is the only state machine reached by the
  schedule, manual, and PR fixture paths;
- the production transport mints only a repository-scoped App token, never
  prints it, uses a pull request and required check, and binds final evidence to
  the integrated bootstrap SHA; publication is create-or-compare and never
  replaces or deletes; image publication exposes a strict digest receipt for the
  exact source SHA;
- the hosted App probe is same-repository, label-gated, disposable, exact-target
  cleaned, and verifies the live rules endpoint plus the observed `Build Gate`
  event;
- the new focused check appears in `nix/checks.nix`, `justfile`, and the hosted
  `ci.yml` Build Gate list, and has been shown red from the hosted path;
- the restored CLI surface, focused check, exact Build Gate, and full Docker CI
  are green after the final edit.

**Commit**: `feat(ci): publish daily validated amaru handoff`

## Slice 2 — real pin mutation through the accepted machinery (re-cut as #79)

**Topology**: `OWNER`, seats re-derived at dispatch. Slice 1 is accepted and
pushed at `03aa184`; its machinery is frozen and out of scope here.

**Integration boundary (A-004, option B).** The shipped production transport
lands its automation PR on `main` once required checks pass. This slice runs the
real changed path up to that point and **stops**: the automation may open its
real PR against `main` through the scoped App token and let required checks run,
but the PR is then closed unlanded and its branch deleted, with the PR number,
head SHA, check conclusions and close timestamp frozen as evidence **before**
deletion. The close reason states plainly that it is a proof run closed by
design — never that the bump was rejected on content. Publication evidence comes
from PR #76's own head, which publishes a SHA-tagged image because
`publish-bootstrap-image.yml` fires on same-repo pull requests.

Residual `CNA205-AB79-INTEGRATION-CALL-FIXTURE-ONLY`: the final integration call
never executes against a real PR in this campaign and stays proven by the
injected-transport controls plus the T014 probe. Registered at epic altitude
with a watch duty on the first real production changed-day.

**Landing PR #76 is not ours.** It activates the `17 4 * * *` schedule and
therefore unattended main-integrating automation. Owner: epic owner, under an
explicit desk ruling. No seat in this lane lands it.

A-001 decision 3 requires the proof bump to be **produced by the automation path
itself**, never by hand-editing: run the accepted updater against a freshly
resolved bare upstream observation, commit the regenerated resolution evidence,
move both pins by the rule, prove `peer-snapshot-anchor` green offline, and pass
full CI including reachable `cli-mock-honesty` on the new tuple. That lands the
breakage risk of a stale pin inside this reviewed PR rather than inside the
first production fire, and makes the first real reconciliation after merge
genuinely `UNCHANGED` — or a genuinely new upstream commit, equally the system
working.

It is a separate slice because it is the one part that can go red for a reason
that is not a defect in this ticket. If it does, that red is evidence: freeze
it, report it, keep slice 1.s fixture-proven machinery, leave the pin where it
is, and escalate to the epic owner as a LOCAL operator-ready packet. Nothing is
ever filed on `pragma-org/amaru`. Injected fixtures still carry the synthetic
controls; the real bump adds evidence, it never substitutes for them.

## Finalization — hosted and ticket acceptance (ticket-owner-owned)

After each `PROOF-COMPLETE` the ticket owner parks the commit owner, spawns a
fresh alternate-provider auditor on the exact candidate SHA, and decides from
the hash-bound report. On acceptance it stamps tasks, has the commit owner
produce the final squash, mechanically proves the final tree, pushes, and
refreshes the PR. It then enables the App-probe path, verifies its hosted
evidence and cleanup, verifies current-head CI and the PR image publication
receipt, runs final gates and the finalization audit, marks the PR ready, and
hands off. It does not merge and does not activate the production schedule out
of band.

## Complexity Tracking

No constitutional violation or exception is required. The three receipt types
stay separate because they have different producers, required fields, and
immutable keys; combining them would weaken partial-state validation.
