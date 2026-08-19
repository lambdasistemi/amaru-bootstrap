# Data Model: Daily Validated Amaru Image Handoff

## Observation

An observation is immutable for one workflow attempt.

| Field | Constraint |
|---|---|
| `observation_day` | UTC calendar day, `YYYY-MM-DD` |
| `upstream_repository` | exactly `https://github.com/pragma-org/amaru` |
| `upstream_ref` | exactly `refs/heads/main` |
| `observed_sha` | full lowercase 40-hex Git SHA |
| `pinned_sha` | full lowercase 40-hex Git SHA |
| `handoff_state` | `present-valid`, `absent`, or `conflict` |

State classification:

```text
origin/ref invalid                     → FAILED
observed = pinned + present-valid      → UNCHANGED
observed = pinned + absent             → VALIDATE/PUBLISH CURRENT PIN
observed ≠ pinned                      → EXACT-PIN PR
any handoff conflict                   → FAILED
```

The observed SHA is resolved once. All later transitions carry that value;
they do not re-resolve a moving upstream ref.

The bootstrap identity has two sources and they are not interchangeable. On the
unchanged and current-pin-resume paths there is no pull request, so the tuple
key uses `read_bootstrap_sha` — the exact current bootstrap commit. On the
changed path the published identity is `integrated_sha` after protected
integration, because a pre-integration pull-request head SHA names a revision
whose CI and image evidence belong to something else.

## Exact pin proposal

The proposal binds one automation branch and pull request to the observation.
Only the Amaru SHA declaration, the resolved Amaru lock node, and the
configurations lock node selected by the recorded peer-snapshot resolution rule
may differ. The normalized lock JSON with both of those nodes removed must
remain identical (A-001, amending FR-006).

The second node is not optional. `nix/peer-snapshots/anchor.sh` asserts
`.amaru_rev == $amaruRev`, so an Amaru bump that leaves
`nix/peer-snapshots/resolution.json` alone makes the required
`peer-snapshot-anchor` check red. The bump therefore regenerates that record
with the unmodified `scripts/resolve-peer-snapshots --write`, and moves the
configurations pin only to the revision that recorded rule selects — never to
a hand-chosen or latest-by-default revision.

```text
OBSERVED
  → BRANCH_PUSHED
  → PR_OPEN
  → REQUIRED_CHECK_SUCCESS
  → INTEGRATED
```

The first step is `OBSERVED → RESOLVED → BRANCH_PUSHED` in full: the resolution
step runs the live query once, in the bump job only, and commits its evidence.
Every later build and verify path re-enforces that evidence offline through
`peer-snapshot-anchor`, exactly as today. Resolving a pin and verifying a pin
stay separate; only the first is ever online.

Any failure is terminal for the daily attempt. No image or handoff success is
inferred from a pre-integration PR SHA.

## Image publication receipt v1

Produced by the image publication workflow only after the full-SHA tag is
pushed and independently resolved from the registry. It binds:

- final bootstrap SHA;
- exact tag, digest, and `tag@digest` reference;
- publication repository, workflow, run attempt, job, and successful
  conclusion.

The canonical JSON contract is
[image-publication-v1.schema.json](contracts/image-publication-v1.schema.json).

## Handoff v1

The cross-organization contract binds one source tuple:

```text
(upstream SHA, bootstrap SHA)
  ├── configurations revision + resolution record hash
  ├── immutable image tag@digest
  ├── successful CI run + Build Gate job
  ├── successful publication run + job + receipt digest
  └── exact CLI-honesty workflow blob + invocation digest
```

The release key is
`amaru-handoff-v1-<upstream-sha>-<bootstrap-sha>`. Canonical bytes are
generated once. An existing identical asset is idempotent success; a missing
asset under an existing tag, wrong tag target, or different asset bytes are
conflicts.

The strict JSON contract is
[handoff-v1.schema.json](contracts/handoff-v1.schema.json). JSON Schema checks
shape and constants; runtime validation also enforces equality among all
duplicated build SHAs, the image tag/reference, and evidence identities.

The `peer_snapshots` block is additive under A-001 decision 2: it names the
configurations repository, the exact configurations revision the recorded rule
selected, and the SHA-256 of the committed `nix/peer-snapshots/resolution.json`
that produced it. Peer snapshots are embedded in the Amaru build, so a handoff
that named only the Amaru SHA would not identify every source input that
determines the image. Announce this field in the ticket release event so the
epic records it in the contract registry.

## Daily result v1

One result is keyed by UTC day through
`amaru-daily-v1-<observation-day>`.

- `UNCHANGED`: observed and pinned SHAs are equal and the tuple handoff is
  already valid. No handoff field is present.
- `HANDOFF`: names the strict tuple handoff release tag, asset URL, and asset
  SHA-256 after successful changed/current-pin validation.

The strict JSON contract is
[daily-result-v1.schema.json](contracts/daily-result-v1.schema.json).

## Failure vocabulary

Failure classes are named, machine-readable, and emitted on the failing run —
not published under an immutable key:

| Class | Raised when |
|---|---|
| `BLOCKED-WRONG-ORIGIN` | resolved source is not bare `pragma-org/amaru` `refs/heads/main` |
| `BLOCKED-PEER-SNAPSHOT-RESOLUTION` | the resolution rule or the offline anchor fails on a changed day |
| `BLOCKED-REQUIRED-CI` | required CI for the exact integrated SHA is not `success` |
| `BLOCKED-PUBLICATION` | no image-publication receipt for the integrated SHA |
| `BLOCKED-DIGEST` | the registry resolves no digest, or an unexpected one |
| `BLOCKED-CLI-HONESTY` | CLI-honesty reachability evidence is absent or inconsistent |
| `CONFLICT-RECEIPT` | an existing key holds different canonical bytes |

These are **not** values of `daily_result.result`. The day key stays keyed to a
success record with enum `UNCHANGED | HANDOFF`, because publishing a failure
under the immutable day key would consume that key and make a later same-day
recovery a permanent conflict — breaking the idempotence FR-013 requires. A
blocked day is one loud red run carrying its named class as run output and job
summary, which FR-005 already admits as a valid daily outcome. This is a
deliberate, recorded divergence from the literal wording of A-001 decision 1;
the named vocabulary it asked for is preserved, its publication key is not.

## Failure and immutability invariants

- No success receipt is synthesized from unavailable evidence.
- No existing release asset is overwritten or deleted.
- Canonical JSON has stable key order and a trailing newline.
- Unknown fields are rejected at every level.
- Receipt SHA-256 values are computed after the final bytes exist.
- Secrets and tokens are not fields and are rejected by the owned-key set.
