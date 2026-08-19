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

## R-007 - Peer-snapshot resolution coupling (A-001, option C)

**Discovered by**: the 2026-08-19 rebase onto `origin/main` `889e5cb`, which
merged issue #77 while this ticket was parked.

**Finding**: `nix/peer-snapshots/anchor.sh` asserts `.amaru_rev == $amaruRev`
against `flake.lock`, and `peer-snapshot-anchor` is in the required Build Gate.
Every Amaru pin bump therefore makes a required check red until
`nix/peer-snapshots/resolution.json` is regenerated — which needs a live GitHub
query and a `cardano-configurations` pin move. Mechanically confirmed the same
day: upstream main `3b8a4ec8...` (committer date `2026-08-19T07:08:04Z`) moves
the rule-selected configurations revision from `4a9b6910...` to `46364b2d...`
(`2026-08-12T02:59:29Z`). The coupled case is the common case, not the rare one.

**Rejected — A, widen fully**: run the whole documented bump procedure with no
review step. Deletes #77's recorded-evidence review without replacement and
puts a retroactively-mutable live query on the critical path.

**Rejected as primary — B, fail closed and hand back**: keep the Amaru-only
fence and stop for an operator whenever a re-resolution is needed. Preserves
every #77 invariant, but makes the ticket's autonomy outcome false on most
days. It survives as C's failure mode.

**Chosen — C, confine the live query to the bump job**: the daily
reconciliation job runs the unmodified `scripts/resolve-peer-snapshots --write`
once, commits the evidence, and moves both pins by the recorded rule. Every
build and verify path stays offline and anchored, and the required Build Gate
re-enforces `peer-snapshot-anchor` on the proposed commit exactly as today.

**Why it holds**: #77 itself draws the resolve-vs-verify distinction. Resolving
a pin is a one-time online act whose result becomes reviewable committed
evidence; verifying a pin is an offline act repeated on every build. C puts the
live query on the first side only. Nothing about the reproducibility of a build
changes.

**Honest cost**: #77's human review of the resolution diff becomes post-hoc
audit of the automation PR rather than a pre-merge gate. The pre-merge
protection is the offline anchor re-verification. `docs/peer-snapshots.md` must
say this plainly and must not claim a human reviews every bump.

**Fences**: configurations pin moves only to the rule-selected revision; the
rule is #77-owned and out of scope; the resolver is consumed unmodified;
resolution or anchor failure is fail-closed as
`BLOCKED-PEER-SNAPSHOT-RESOLUTION`; the live query never runs unauthenticated
on the development host (NOTE-018 API budget), so local proofs use injected
transports only.
