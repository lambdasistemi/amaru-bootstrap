# Functions Model: Daily Validated Amaru Image Handoff

Only new or changed signatures, argument names, result types, and
signature-level constraints. No bodies, algorithms, control flow, or helpers.
Component placement is in [modules-model.md](modules-model.md); field
constraints are in [data-model.md](data-model.md).

## Types used below

| Type | Constraint |
|---|---|
| `Sha40` | `^[0-9a-f]{40}$` |
| `Digest` | `^sha256:[0-9a-f]{64}$` |
| `Day` | `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`, UTC calendar day |
| `Absent \| T` | a total two-valued result; `Absent` is distinct from empty string, `null`, and `""` |
| `Canonical` | stable key order, trailing newline, no unknown fields |

`Absent` being a distinct value is a signature-level constraint, not a style
note: an operation that maps "no such receipt" onto the empty string lets a
missing-evidence failure class read as a present-but-empty one, and the
fail-closed requirement FR-016 becomes unprovable at that boundary.

## M-001 — command surface

`scripts/daily-amaru-handoff.sh <subcommand> [options]`, executable, exits
nonzero on every failure class.

### `reconcile`

| Argument | Type | Required |
|---|---|---|
| `--observation-day` | `Day` | yes |
| `--transport` | `production \| fixture` | yes |
| `--fixture-root` | directory path | required iff `--transport fixture` |

Result: exit `0` when the run reached exactly one immutable published outcome
(`UNCHANGED` or `HANDOFF`) or converged idempotently on an identical existing
one; nonzero otherwise.

Effects: at most one create-or-compare publication per immutable key. Never
replaces, deletes, or moves an existing asset or tag. Never writes a token to
stdout, stderr, a file, or a receipt field.

### `validate-handoff`, `validate-daily-result`, `validate-image-receipt`

| Argument | Type | Required |
|---|---|---|
| `--file` | path | yes |

Result: exit `0` iff the file is `Canonical` and strictly valid against the
matching contract in `contracts/`, including cross-field identity equality for
every duplicated SHA, tag, and reference; nonzero otherwise, with the failing
constraint named on stderr.

These three are separately invocable because a downstream consumer, the test
suite, and the workflow each need validation without running `reconcile`.

## M-002 — transport operation set

Both M-002a and M-002b provide exactly this set with these argument names.
Neither adds an operation the other lacks; an operation present in only one
implementation makes the fixture proof non-transferable.

| Operation | Arguments | Result |
|---|---|---|
| `resolve_upstream_head` | `upstream_repository`, `upstream_ref` | `Sha40` |
| `read_pinned_sha` | — | `Sha40` |
| `read_bootstrap_sha` | — | `Sha40` |
| `find_handoff` | `upstream_sha`, `bootstrap_sha` | `Absent \| Canonical` |
| `find_daily_result` | `observation_day` | `Absent \| Canonical` |
| `publish_immutable` | `key`, `bytes` | `created \| identical \| conflict` |
| `open_pull_request` | `branch_ref` | `pr_number` |
| `required_ci_evidence` | `sha` | `absent \| pending \| failure \| Canonical` |
| `integrated_sha` | `pr_number` | `Absent \| Sha40` |
| `image_publication_receipt` | `bootstrap_sha` | `Absent \| Canonical` |
| `resolve_registry_digest` | `image_tag` | `Absent \| Digest` |
| `cli_honesty_evidence` | `bootstrap_sha` | `Absent \| Canonical` |
| `propose_pin` | `observed_sha`, `configurations_sha` | `branch_ref` |
| `resolve_peer_snapshots` | `amaru_sha` | `configurations_sha` + `resolution_sha256` |

Signature-level constraints:

- every `Sha40` and `Digest` result is validated at the boundary, so a
  malformed upstream answer fails at the transport rather than surfacing as a
  wrong-looking receipt field;
- `required_ci_evidence` returns one typed value covering both the gating
  decision and the evidence. Its four variants stay distinct: `pending` and
  `absent` are not interchangeable, because treating a check that has not
  started as one that failed turns a retryable state into a terminal one and
  hides a wiring defect. On success the `Canonical` value **is** the strict
  handoff `ci` block.

  It replaced a scalar `required_check_conclusion` plus a separate evidence
  read for a reason worth keeping: two queries can observe two different runs.
  A conclusion read that says `success` for run N followed by an evidence read
  that returns run N+1 publishes, under an immutable key, a CI identity that
  did not produce the state the handoff claims. One query cannot disagree with
  itself;
- `publish_immutable` returns three values, not a boolean. `identical` is
  idempotent success and `conflict` is terminal failure; collapsing them makes
  FR-013 unprovable;
- no operation accepts, returns, or logs a credential;
- `resolve_registry_digest` is a **verification** operation, not a source of
  published identity. The `image` block is built from
  `image_publication_receipt`; the independently resolved digest exists to be
  compared against it, and a mismatch is terminal (INV-75-DIGEST). Using the
  re-resolved value to populate the block instead of to check it would delete
  the only cross-check that the receipt describes what the registry holds;
- `read_bootstrap_sha` returns the exact current bootstrap repository commit —
  the production implementation validates it and the fixture implementation
  returns the injected exact SHA. It exists because the tuple key
  `(upstream_sha, bootstrap_sha)` must be constructible on the unchanged and
  current-pin-resume paths, where there is no pull request and therefore no
  `pr_number` to pass to `integrated_sha`. Without it M-001 would have to read
  `git rev-parse HEAD` or `GITHUB_SHA` directly, which is a hidden input
  outside the transport boundary;
- `read_bootstrap_sha` and `integrated_sha` are never interchangeable. On the
  changed path the published bootstrap identity is the value returned by
  `integrated_sha` after protected integration; `read_bootstrap_sha` describes
  the pre-integration checkout and must never reach a published receipt on that
  path. Conflating them publishes an identity whose CI and image evidence do
  not belong to it (INV-75-BOOTSTRAP-IDENTITY).

## M-003 — pin updater (slice 2)

`propose_pin` takes both revisions because A-001 makes them one atomic change:
a branch carrying a new Amaru pin without the matching configurations pin and
regenerated record is a branch whose required `peer-snapshot-anchor` check is
red by construction. A two-argument signature makes that impossible to express;
a one-argument signature makes it the default.

`resolve_peer_snapshots` is the **only** operation permitted to reach the
network, and only from the bump job. It is a thin call onto the unmodified
`scripts/resolve-peer-snapshots --write`; this ticket adds no resolution logic
of its own. Its `configurations_sha` result feeds `propose_pin` unchanged —
never a separately chosen value.

In the fixture transport both operations are injected, so no local proof ever
performs the live query (NOTE-018 host API budget).

## M-005 — image publication receipt

No new function. The workflow gains steps that emit an
`image-publication-v1` receipt whose fields are fixed by
`contracts/image-publication-v1.schema.json`. The digest it records is resolved
from the registry after the push, never inferred from the tag it just wrote.
