# Research: Daily Validated Amaru Image Handoff

## R-001 - Public immutable publication surface

**Decision**: Publish canonical JSON as assets on unique GitHub Releases:
`amaru-handoff-v1-<upstream-sha>-<bootstrap-sha>` for handoffs and
`amaru-daily-v1-<YYYY-MM-DD>` for daily results. Existing assets are only
accepted after byte equality; they are never replaced or deleted.

**Rationale**: The repository is public, so consumers in another organization
can retrieve release metadata and assets without a shared PAT. Unique tags are
non-moving, durable, discoverable through the GitHub API, and naturally
support fail-on-conflict idempotence.

**Alternatives considered**: Workflow artifacts expire and public downloads
are less convenient; a moving `latest` tag violates repository policy; a
dedicated branch creates a mutable pointer and unnecessary merge contention;
an external object store adds credentials and infrastructure.

## R-002 - Protected changed-source integration

**Decision**: The daily workflow creates an exact-SHA automation branch and
pull request using a repository-scoped `lambdasistemi-ci` installation token,
waits for the required `Build Gate`, integrates by rebase, then waits for CI
and image publication on the final main SHA.

**Rationale**: The App token is short-lived and its events trigger downstream
workflows. A pull request exercises the active main ruleset instead of pushing
directly to protected main. Binding later evidence to the final integrated SHA
avoids confusing a PR head with the published build identity.

**Alternatives considered**: `GITHUB_TOKEN` events are suppressed for chained
workflows; direct App pushes could use an admin bypass; a long-lived PAT or
deploy key violates the credential contract; auto-merge is disabled in the
repository and is not required when the workflow explicitly waits and merges.

## R-003 - Safe hosted proof before schedule activation

**Decision**: Pull requests always run injected no-production fixtures. A
same-repository PR bearing the explicit probe label may additionally mint the
scoped App token, create a disposable empty-diff probe PR from main, observe a
hosted `Build Gate`, re-read the active main rules, then close and delete only
the recorded probe branch.

**Rationale**: A new `workflow_dispatch` workflow is unavailable before its
file exists on the default branch. A label-gated PR probe supplies real event
evidence without pin, image, release, or production-schedule mutation. The
probe branch does not contain the new workflow, preventing recursion.

**Alternatives considered**: Waiting until after merge would activate the
schedule before proving the App boundary; pushing the feature branch from its
own workflow risks loops and cancellation; a hand-authored transcript is not
mechanical evidence.

## R-004 - Three strict receipts

**Decision**: Define separate strict schemas for image publication, handoff,
and daily result. Runtime validation additionally enforces equality across
source, build, tag, image reference, CI, and publication fields.

**Rationale**: Publication happens in a different workflow from reconciliation
and needs a machine handoff of its own. A day result and a source-tuple handoff
have different idempotence keys. Keeping the documents separate prevents a
partial publication event from masquerading as a complete downstream handoff.

**Alternatives considered**: One permissive envelope makes conditional fields
easy to omit and is harder to validate fail-closed; job summaries are prose;
parsing image-push logs is brittle.

## R-005 - Exact pin mutation

**Decision**: Resolve upstream once, validate the fixed owner/repository/ref,
replace only the exact Amaru SHA declaration, regenerate only the Amaru lock
node, and structurally compare every other lock node to the baseline.

**Rationale**: This follows the constitution's exact-SHA and no-forks rules and
turns unrelated lock movement into a hard failure.

**Alternatives considered**: A moving `main` flake ref is not reproducible;
manual lock editing risks incorrect content hashes; a broad flake update can
move unrelated inputs.

## R-006 - CLI-honesty evidence

**Decision**: Bind the exact Build Gate job/run, CI workflow blob, step name,
flake attribute, and normalized invocation digest in handoff v1. Prove
reachability by seeding a temporary rejected mock-only command through the
same Build Gate entry point and byte-restoring it.

**Rationale**: Registration is not reachability. The job and immutable
workflow blob establish what ran; the seeded failure proves that the path can
block publication.

**Alternatives considered**: Standalone check success does not show the daily
path reaches it; help-text snapshots do not prove executable behavior;
handwritten evidence cannot disagree mechanically with the claim.
