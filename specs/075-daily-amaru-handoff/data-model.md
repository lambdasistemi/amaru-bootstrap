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

## Exact pin proposal

The proposal binds one automation branch and pull request to the observation.
Only the Amaru SHA declaration and resolved Amaru lock node may differ. The
normalized lock JSON with `.nodes.amaru` removed must remain identical.

```text
OBSERVED
  → BRANCH_PUSHED
  → PR_OPEN
  → REQUIRED_CHECK_SUCCESS
  → INTEGRATED
```

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

## Daily result v1

One result is keyed by UTC day through
`amaru-daily-v1-<observation-day>`.

- `UNCHANGED`: observed and pinned SHAs are equal and the tuple handoff is
  already valid. No handoff field is present.
- `HANDOFF`: names the strict tuple handoff release tag, asset URL, and asset
  SHA-256 after successful changed/current-pin validation.

The strict JSON contract is
[daily-result-v1.schema.json](contracts/daily-result-v1.schema.json).

## Failure and immutability invariants

- No success receipt is synthesized from unavailable evidence.
- No existing release asset is overwritten or deleted.
- Canonical JSON has stable key order and a trailing newline.
- Unknown fields are rejected at every level.
- Receipt SHA-256 values are computed after the final bytes exist.
- Secrets and tokens are not fields and are rejected by the owned-key set.
