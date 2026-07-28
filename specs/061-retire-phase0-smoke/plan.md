# Implementation Plan: Retire Obsolete Phase-0 Smoke

**Branch**: `fix/61-phase-0-smoke-verdict` | **Date**: 2026-07-28 |
**Spec**: [spec.md](spec.md)  
**Input**: Feature specification from
`/specs/061-retire-phase0-smoke/spec.md`

## Summary

Retire the Phase-0 experiment as an executable repository surface. Remove its
script, flake app/checks, CI job, Just recipes, dedicated tests/helpers, and
tracked generated output. Preserve the legitimate 2026-04-28
`FAIL: format mismatch` conclusion as navigable history, and update only active
documentation that currently advertises the retired capability.

The decision follows direct measurement of
[GitHub Actions run 30356417382, job 90265660051](https://github.com/lambdasistemi/amaru-bootstrap/actions/runs/30356417382/job/90265660051):
the job reached conversion after synthesis and dump succeeded, the pinned Amaru
rejected `convert-ledger-state` with exit 2, the script emitted
`FAIL: format mismatch`, and the workflow accepted that verdict as success.
Substituting a current command would change the historical hypothesis, so the
epic owner approved retirement.

## Technical Context

**Language/Version**: Bash 5, Nix, GitHub Actions YAML, Markdown  
**Primary Dependencies**: Existing pinned Amaru and IOG consensus tools;
MkDocs Material navigation  
**Storage**: Delete the tracked generated `tmp/smoke-out/` tree; add `tmp/` to
the repository ignore rules  
**Testing**: Structural RED/GREEN retirement audit, `cli-mock-honesty`,
`nix flake check`, documentation build, and Docker live producer verifier  
**Target Platform**: x86_64 Linux on self-hosted NixOS runners  
**Project Type**: Build/test harness and documentation retirement  
**Performance Goals**: Remove one obsolete multi-minute CI job without reducing
current producer coverage  
**Constraints**: Historical specifications and constitution remain unchanged;
`nix/checks.nix` edits stay localized; the marker module permits only one
Haddock-claim correction  
**Scale/Scope**: One obsolete command surface and its direct active
documentation

## Constitution Check

- **No forks**: Pass. No dependency or upstream source changes.
- **Stock tools**: Pass. Retirement removes an invalid orchestration path and
  does not replace upstream behavior.
- **Pin by SHA**: Pass. No pin, lock file, or image tag changes.
- **Nix-first**: Pass. Flake evaluation and all retained checks remain the
  verification source of truth.
- **Smallest provable step**: Pass. The experiment already answered its
  question; removing the false rerun is smaller and more honest than inventing
  a different hypothesis.
- **Bundle output contract**: Pass by construction. No producer, bundle, or
  fixture behavior changes.
- **Big deletion approval**: Pass. The epic owner explicitly approved complete
  retirement and the widened file fence after reviewing captured evidence.

## Design

### Complete execution-surface removal

Remove every path that can invoke, register, or test the old orchestrator:

- the `Smoke Test (Phase 0 verdict)` workflow job;
- the `smoke-test` flake app and two dedicated flake checks;
- `just smoke`, `smoke-bundle`, and the smoke-only bats recipe, plus the
  Phase-0 stage inside `just ci`;
- `scripts/smoke-test.sh`;
- the three dedicated bats files and their shared fixture helper.

The general `shellcheck` check remains and continues checking the two production
shell entrypoints. Delete only the retired `tests/test-tool-error.bats` entry
from the CLI-mock-honesty owner inventory. The checker's real-binary
`convert-ledger-state` negative-control logic remains byte-identical and must
still prove the removed command is rejected.

### Generated-output cleanup

The 100 tracked files under `tmp/smoke-out/` are outputs of the retired command,
not a current fixture. Delete the tree and add `tmp/` to `.gitignore`.

A dependency sweep found no non-historical consumer of these paths. References
inside `specs/001-snapshot-format-smoke/**` are the immutable primary record and
remain intentionally untouched.

### Navigable history and current documentation

Add `docs/history/phase-0-snapshot-format.md` containing:

- the 2026-04-28 finding;
- the original `FAIL: format mismatch` verdict;
- the no-fork pivot the finding caused;
- the 2026-07-28 discovery that the rerun invoked a removed command;
- links to the primary Phase-0 specification, issue #61, and the measured CI
  job.

Add the page to the existing MkDocs History navigation. Update only the retired
capability references in `README.md`, `docs/bootstrap-producer.md`, `AGENTS.md`,
and the repository skill. In `lib/AmaruBootstrap.hs`, replace only the Haddock
claim that the smoke script is the project deliverable; code and exports remain
byte-identical.

Historical specs, `.specify/memory/constitution.md`, and
`docs/history/what-amaru-needs.md` remain unchanged.

### Versioned RED/GREEN proof

The slice does not add a permanent retirement check. Before repository edits,
the driver writes a structural audit under its external `handoffs/` directory.
The audit asserts that:

- the retired files/directories and named flake/CI/Just surfaces are absent;
- active documentation no longer advertises the retired capability;
- `tmp/` is ignored;
- the new history page is navigable;
- forbidden historical files are unchanged relative to the slice base.

The initial audit is frozen RED before implementation. During GREEN, the
focused CLI-mock-honesty check exposed its stale ownership reference to the
deleted test. Following the ticket owner's scope approval, revise only the
audit invariant that previously required the whole checker to be
byte-identical: it must instead prove the exact one-line owner-list deletion
and byte-identical negative-control logic. Freeze the audit delta and the
focused failing check as correction RED evidence, obtain navigator acceptance
of the amendment, then run the revised audit GREEN.

Running the audit on the pre-change tree is RED because all retired surfaces
exist. The driver freezes the command and raw failure output for navigator
review; the repository `red.diff` is intentionally empty because no
implementation has begun. The identical audit is GREEN after the retirement.
This is a real observed RED, not a test skip, while avoiding a new permanent
test whose sole purpose is to remember a deleted test.

## Project Structure

```text
.github/workflows/ci.yml                    # remove Phase-0 job/check entry
.gitignore                                  # ignore tmp/
AGENTS.md                                   # remove retired commands
README.md                                   # remove retired app/CI stage
docs/
├── bootstrap-producer.md                   # describe retained CI only
└── history/
    └── phase-0-snapshot-format.md           # new historical verdict page
justfile                                    # remove smoke recipes/stage
lib/AmaruBootstrap.hs                       # Haddock claim only
mkdocs.yml                                  # link history page
nix/
├── apps.nix                                # remove smoke-test app
└── checks.nix                              # remove smoke definitions/checks
scripts/smoke-test.sh                       # delete
skills/amaru-bootstrap-guide/SKILL.md       # remove retired guide surface
tests/
├── lib/fixture-helpers.bash                # delete
├── test-config-error.bats                  # delete
├── test-smoke-integration.bats             # delete
└── test-tool-error.bats                    # delete
tmp/smoke-out/**                            # delete tracked generated output
```

## Slice Plan

### Slice 1 - Retire the false Phase-0 signal and preserve its verdict

Run the external structural audit RED, remove the complete executable/test
surface and generated output, add the navigable history page, and correct the
active documentation. Apply the owner-approved one-line CLI-mock-honesty
inventory correction, run the amended audit GREEN, then run the CLI negative
control, documentation build, and full ticket gate. Land everything in one
bisect-safe commit so no intermediate revision exports an app whose script is
missing or removes the finding before history is reachable.

**Owned files**:

- `.github/workflows/ci.yml`
- `.gitignore`
- `AGENTS.md`
- `README.md`
- `docs/bootstrap-producer.md`
- `docs/history/phase-0-snapshot-format.md`
- `justfile`
- `lib/AmaruBootstrap.hs` (Haddock claim only)
- `mkdocs.yml`
- `nix/apps.nix`
- `nix/checks.nix` (localized smoke definitions only)
- `scripts/smoke-test.sh`
- `skills/amaru-bootstrap-guide/SKILL.md`
- `tests/lib/fixture-helpers.bash`
- `tests/check-cli-mock-honesty.sh` (remove one owner-list line only)
- `tests/test-config-error.bats`
- `tests/test-smoke-integration.bats`
- `tests/test-tool-error.bats`
- `tmp/smoke-out/**`

**Focused proof**:

```text
<driver handoffs>/retirement-audit.sh
git diff -- tests/check-cli-mock-honesty.sh
nix build .#checks.x86_64-linux.cli-mock-honesty
nix shell nixpkgs#python3Packages.mkdocs-material -c \
  mkdocs build --strict --site-dir <driver handoffs>/docs-site
./gate.sh
```

**Commit**:

```text
fix: retire obsolete Phase-0 smoke signal

Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009
```

### Slice 2 - Publish review evidence (orchestrator-owned)

After accepting and pushing Slice 1, update the human-readable PR body with the
measured exit/verdict, the retirement chapter, the retained coverage argument,
and fresh gate evidence. Check the parent inbox, close task accounting, and run
the finalization audit. No driver or navigator edits repository behavior in
this slice.

## Complexity Tracking

No constitutional violation or lasting complexity exception is required.
