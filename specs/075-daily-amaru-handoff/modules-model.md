# Modules Model: Daily Validated Amaru Image Handoff

Component responsibility, dependency direction, and promotion decisions.
Fields and validation live in [data-model.md](data-model.md); signatures live
in [functions-model.md](functions-model.md); neither is repeated here.

## Components

### M-001 — reconciliation state machine (new)

`scripts/daily-amaru-handoff.sh`

Sole owner of the state transition table in `data-model.md`. Resolves one
observation, classifies it, validates every piece of evidence, and performs at
most one create-or-compare publication per immutable key.

- consumes: the transport operation set (M-002) and a UTC observation day;
- emits: process exit status, one canonical daily result, and — on the changed
  or resume path — one canonical handoff;
- depends on: M-002 only.

No other component may contain a state transition. If a workflow step decides
anything about `UNCHANGED`, integration, or handoff eligibility, that decision
has escaped M-001 and the slice is wrong.

### M-002 — transport boundary (new)

One operation set with two implementations selected at invocation:

- **M-002a production transport** — bare-upstream ref resolution, protected
  integration, required-check reads, registry digest resolution, and immutable
  publication;
- **M-002b injected fixture transport** — deterministic directory-backed
  answers under `tests/fixtures/daily-amaru-handoff/**`.

Dependency direction is strictly M-001 → M-002. A transport never imports,
re-implements, or short-circuits classification. Both implementations satisfy
the identical operation set, so every failure class provable against M-002b is
provable against the same code path that runs in production. A failure class
reachable only through M-002b is not a proof of anything.

### M-003 — exact-pin updater (slice 2)

Owns mutation of `flake.nix`, `flake.lock`, and
`nix/peer-snapshots/resolution.json`, and the proof that no other lock node
moved.

`origin/main` binds the Amaru revision to a `cardano-configurations` revision
through the required `peer-snapshot-anchor` check, so "only the Amaru node
moves" is not achievable. Under A-001 option C this component:

- moves the Amaru pin to exactly the observed bare-upstream SHA;
- invokes the **unmodified** `scripts/resolve-peer-snapshots --write` in the
  bump job only, following the documented #77 procedure exactly: a **discovery**
  call against a proposed lock carrying the new Amaru revision, then a
  **verification** call on the real tree after both pins have moved. The
  documented procedure expects the first call to mismatch, because the
  configurations input still points at the previous resolution;
- treats the discovery call's exit status as **carrying no success meaning at
  all**. It is expected to be nonzero on a coupled bump, and the resolver
  conflates that expected drift with a genuine fetch failure, so the transport
  instead validates the written record structurally and takes `configs_rev`
  from it. The only success signals are the verification call exiting 0 and the
  offline `peer-snapshot-anchor` passing on the proposed commit
  (INV-75-RESOLVE-FAIL-CLOSED);
- moves the `cardano-configurations` pin only to the revision that record
  names — never a hand-chosen or latest-by-default revision;
- proves `del(.nodes.amaru, .nodes."cardano-configurations")` is byte-identical
  to the base, so the fence narrows rather than disappears;
- fails closed as `BLOCKED-PEER-SNAPSHOT-RESOLUTION` on resolution or anchor
  failure, publishing nothing.

It is the only component permitted to reach the network for resolution, and
only in the bump job. No build or verify path may invoke it. The resolution
rule itself is owned by issue #77 and is outside this fence.

### M-004 — daily trigger surface (new)

`.github/workflows/daily-amaru-handoff.yml`

Trigger surface only: UTC schedule, manual dispatch, pull-request fixture run,
and the explicit label-gated App-event probe. It selects a transport and calls
M-001. It holds no reconciliation logic, no comparison, and no receipt
generation.

### M-005 — image publication receipt producer

`.github/workflows/publish-bootstrap-image.yml`, minimum change only.

Emits image-publication receipt v1 after the full-SHA tag is pushed and the
digest is independently resolved from the registry. It is a producer of
evidence and never a consumer of M-001; the dependency runs one way only.

### M-006 — strict contracts (already committed)

`specs/075-daily-amaru-handoff/contracts/*.json`

Single source of truth for the shape of all three receipts. M-001's runtime
validator and any downstream consumer reference these; neither re-states a
field list. Cross-field identity equality is runtime validation, not schema.

### M-007 — reachability wiring

`nix/checks.nix` (new `daily-amaru-handoff` check), the `build-gate` list in
`justfile`, and the Build Gate list in `.github/workflows/ci.yml`.

All three are required. `.github/workflows/ci.yml` duplicates the check list
rather than calling `just build-gate`, so a check registered only in
`nix/checks.nix` and `justfile` never runs in hosted CI and reports green
whatever it asserts. Repository precedent for this exact wiring is
`specs/070-cli-mock-honesty-ci-wiring`. Adding one check name to the hosted
list is the minimum change that makes the new check able to fail.

### M-008 — focused proof suite (new)

`tests/test-daily-amaru-handoff.bats` and
`tests/fixtures/daily-amaru-handoff/**`

Drives M-001 through M-002b only. Never reaches the network, a registry, a
token, or another worktree.

### M-009 — public documentation (new)

`docs/daily-amaru-handoff.md` plus exactly one `mkdocs.yml` navigation entry.
Documents the public contract, immutable keys, operator-visible daily result,
failure vocabulary, and manual trigger. It documents only accepted behavior.

## Dependency direction

```text
M-004 trigger ──┐
                ├──▶ M-001 state machine ──▶ M-002 transport ──▶ M-002a | M-002b
M-008 tests  ───┘             │
                              ├──▶ M-006 contracts (shape)
                              └──▶ M-003 pin updater (slice 2)

M-005 receipt producer ──▶ (evidence read by M-002a)
M-007 wiring ──▶ makes M-008 reachable from the required Build Gate
```

No cycle is permitted. In particular M-002 must not read M-001's classification
and M-005 must not read M-001 at all.

## Promotion

Nothing is promoted to a shared or upstream owner. Constitution principle II
keeps orchestration in-repo and consumes `git`, `gh`, `jq`, Nix, and the
registry as stock tools. `scripts/resolve-peer-snapshots` is consumed
unmodified (A-001).

## Boundary the slice must not cross

`nix/amaru.nix`, producer and relay scripts, accepted CLI mocks, the
`cli-mock-honesty` implementation, Haskell sources, Cardano dependency pins
other than the rule-selected `cardano-configurations` pin, the resolution rule
and `scripts/resolve-peer-snapshots` themselves, bootstrap bundle semantics,
`gate.sh`, branch rules, and every downstream repository stay untouched. A compatibility change required
outside this fence is a stop-and-ask, never a widening.
