# Research: Preview the Amaru #1098 Fix Head

## R-001 - Freeze the pull-request head twice

**Decision**: Capture
`refs/heads/etorreborre/fix/rollback-in-the-future` immediately before the
dependency edit and again before final evidence. The initial expected value
is `b077d1dd38ed207c701283743b6e9379f7186ab0`.

**Rationale**: The preview targets an open, force-pushable branch. A moved
head changes the artifact being validated, so the revision and evidence
must move together rather than silently validating a stale commit.

**Alternatives considered**:

- Trust the filing-time SHA: rejected because the brief explicitly treats a
  force-push as an execution-time event.
- Pin the branch name: rejected because a moving reference is not
  reproducible.

## R-002 - Treat divergence as a preview-only exception

**Decision**: Record that the initial target is 7 commits ahead and 27
commits behind the repository's currently selected Amaru revision, with
merge base `f9c4aa086cb312e5218bb5724fd7339ecbeb5cb6`. Permit that selection
only on PR #73, which remains draft and never merges.

**Rationale**: This is not an upstream-main bump. It is an experiment
against an open fix branch whose value is precisely that it can be tested
before integration. The constitution guard is satisfied only while the
non-main source is confined to disposable preview history.

**Alternatives considered**:

- Rebase or merge the fix onto current upstream main ourselves: rejected
  because that creates a consumer-maintained upstream variant.
- Land the preview selection on repository main: forbidden by the brief and
  Constitution Principles I and II.

## R-003 - Update only the Amaru input

**Decision**: Replace the full revision in `flake.nix`, let Nix refresh only
the `amaru` input in `flake.lock`, and compare lock JSON with
`.nodes.amaru` removed.

**Rationale**: Nix should calculate generated source metadata. The
structural comparison proves the preview did not accidentally move another
dependency.

**Alternatives considered**:

- Hand-author lock metadata: rejected because generated timestamps and
  content hashes are not an orchestrator-owned edit.
- Refresh the complete lock file: rejected because it widens the
  experiment beyond one source.

## R-004 - Reuse and challenge the existing peer-snapshot staging

**Decision**: Begin with no consumer adaptation. The selected PR does not
change the peer-snapshot README, and its `amaru-node` build-script delta
against the current pin only inlines an existing rerun directive. Require a
real build to decide whether `nix/amaru.nix` needs any change.

**Rationale**: Main already carries deterministic offline staging for
mainnet, preprod, and preview. Rewriting it without a failing build would
be speculative. Because the target branch diverged from main, only the
selected-source build is authoritative.

**Alternatives considered**:

- Copy or patch upstream peer-snapshot sources: rejected by the
  constitution.
- Assume matching documentation proves compatibility: rejected because the
  build crosses the actual consumer boundary and can falsify the assumption.

## R-005 - Prove command-surface honesty in both directions

**Decision**: Before accepting a green `cli-mock-honesty` result,
temporarily add one known-invalid command to the declared accepted surface
and require the real-binary check to fail. Restore the seed before the pin
change, then run the same check against the target.

**Rationale**: A green check is evidence only after its comparator is shown
able to detect a false accepted surface.

**Alternatives considered**:

- Trust yesterday's negative control from #68: rejected because evidence
  belongs to this preview run.
- Add a permanent exact-SHA assertion: rejected as a duplicate mutable
  source of truth.

## R-006 - Keep the live boundary in the gate

**Decision**: Run `just ci` through `./gate.sh` after the final edit and
require the hosted `Build Gate` and `Live Bootstrap Producer` checks on the
exact preview commit.

**Rationale**: Package and mock checks cannot prove that the target binary
opens the bundle generated from a live cardano-node 10.7.1 ChainDB. The
Docker verifier crosses that seam.

**Alternatives considered**:

- Stop at the Amaru package build: rejected because it proves neither
  command wiring nor live consumption.
- Substitute hosted checks for local evidence: rejected because both are
  required and run in different environments.

## R-007 - Use the existing PR-image publisher unchanged

**Decision**: Let `.github/workflows/publish-bootstrap-image.yml` publish
the immutable `<commit-sha>` and `pr-73-<commit-sha>` tags after successful
PR CI. Resolve the registry digest mechanically and describe the PR tag as
the preview/1098 image in the desk report.

**Rationale**: The workflow already provides the authorized same-repository
PR path. The PR number, immutable SHA, PR title, and body together identify
the #1098 preview without inventing a new moving tag or changing publishing
infrastructure.

**Alternatives considered**:

- Add a `preview/1098` workflow or moving tag: rejected because the brief
  forbids invented publishing infrastructure and moving production tags.
- Publish locally with ad-hoc credentials: rejected because it bypasses the
  repository's reviewed workflow.
