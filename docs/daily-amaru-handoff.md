# Daily validated Amaru handoff

The daily handoff workflow turns one UTC observation of bare
`pragma-org/amaru` `refs/heads/main` into an explicit, immutable result. It
never treats silence, a partial build, or a mutable image tag as success.

## Operator outcomes

Every successful observation publishes one `daily-result-v1` document under
the release key `amaru-daily-v1-YYYY-MM-DD`:

- `UNCHANGED` means the observed Amaru SHA equals the pinned SHA and a strict
  handoff already exists for the current bootstrap commit.
- `HANDOFF` means validation completed and the result names the immutable
  tuple handoff that was created or found byte-identical.

Failures are emitted by the workflow and do not consume the daily release key.
That allows an operator to repair evidence and retry on the same day.

## Immutable contracts

Tuple handoffs use
`amaru-handoff-v1-<upstream-sha>-<bootstrap-sha>` and the asset
`handoff-v1.json`. They bind:

- the exact bare-upstream Amaru revision;
- the exact bootstrap repository revision;
- the rule-selected `cardano-configurations` revision and committed
  peer-snapshot record hash;
- the full-SHA GHCR tag and independently resolved digest;
- successful `Build Gate` run and job identity;
- successful image-publication run, job, and receipt hash; and
- the exact hosted CLI-honesty workflow and invocation identity.

The image workflow emits `image-publication-v1.json` only after pushing the
full-SHA image tag and resolving its digest from GHCR. The reconciliation
workflow compares that digest with the registry again; the receipt never gets
to define both sides of its own verification.

All documents are sorted-key canonical JSON with a trailing newline. Existing
assets are create-or-compare: identical bytes are idempotent success, while
different bytes, a missing asset under an existing tag, or a wrong identity is
a conflict. Automation never replaces or deletes a published receipt.

The schemas are public under
`specs/075-daily-amaru-handoff/contracts/`. The script also exposes strict
validators:

```console
scripts/daily-amaru-handoff.sh validate-handoff --file handoff-v1.json
scripts/daily-amaru-handoff.sh validate-daily-result --file daily-result-v1.json
scripts/daily-amaru-handoff.sh validate-image-receipt --file image-publication-v1.json
```

The production proposal boundary is also explicit:

```console
scripts/daily-amaru-handoff.sh propose --transport production
scripts/daily-amaru-handoff.sh observe-pr-checks --pr-number 123 --transport production
```

`propose` resolves the bare upstream revision and rule-selected peer snapshots,
creates and pushes the exact bump commit, opens its pull request, and stops. It
never calls the protected landing operation. The changed `reconcile` path is
the same proposal operation followed by landing and receipt publication.

Both required-main-CI and pull-request-check observations retry explicit
`not-yet-reported`, `pending`, and transport-error results. Production
observation is deliberately unbounded, matching the previous protected landing
semantics and exceeding any finite job deadline; only a reported failed check
is terminal. Fixture observation uses a bounded injected window so absence and
pending exhaustion remain fast, deterministic test cases.

## Failure vocabulary

The workflow exits nonzero and publishes no success handoff for:

| Class | Meaning |
| --- | --- |
| `BLOCKED-WRONG-ORIGIN` | Source is not bare `pragma-org/amaru` main. |
| `BLOCKED-PEER-SNAPSHOT-RESOLUTION` | Discovery, exact-pin isolation, verification, or the offline anchor failed. |
| `BLOCKED-REQUIRED-CI` | Exact integrated-revision CI is absent, pending, or failed. |
| `BLOCKED-PUBLICATION` | The exact image-publication receipt is absent or invalid. |
| `BLOCKED-DIGEST` | GHCR has no digest or disagrees with the receipt. |
| `BLOCKED-CLI-HONESTY` | Required CLI-honesty evidence is absent or inconsistent. |
| `CONFLICT-RECEIPT` | An immutable key already contains different bytes or identity. |

## Triggering and safety

The workflow runs daily on its UTC schedule and can be started from the
Actions page with **Run workflow**. Both production triggers invoke the same
`reconcile` state machine. Pull requests run the same machine through a
directory-backed fixture transport that has no network, registry, release, or
credential operation.

On a changed observation, the production transport mints the existing
repository-scoped `lambdasistemi-ci` App token, follows the documented
two-call peer-snapshot procedure, creates an exact-pin pull request, waits for
protected integration and final-main `Build Gate`, and only then validates
publication. The discovery resolver status is deliberately ignored because it
conflates expected old-pin drift with failure; its written record is validated,
then the second resolver call must exit zero and the offline anchor must pass.

Maintainers can apply the `daily-amaru-app-probe` label to a same-repository
pull request to exercise the App event boundary before schedule activation.
The probe runs the pull-request head's shipped `propose --transport production`
entrypoint, so its pull request carries the
real two-pin bump commit rather than a fabricated empty commit. It waits through
the not-yet-reported state for required `Build Gate`, verifies that the active
`main` rules still require pull requests and `Build Gate`, and closes the exact
pull request unlanded with an explicit close-by-design reason. The PR number,
head SHA, check conclusions, ruleset, and close timestamp are frozen before the
exact branch is deleted. A separate receipt then verifies both that the PR is
closed and unmerged and that the remote branch is absent; successful cleanup is
not inferred from the failure trap. Probe branches use the disjoint
`probe/daily-handoff-<run>-<attempt>` namespace, while scheduled proposals use
`automation/amaru-<sha>`. Creation uses an atomic absent-ref lease and writes an
ownership receipt; cleanup refuses to close or delete a target unless that
receipt proves this run created its exact branch. Fork pull requests cannot
enter this credentialed path.
