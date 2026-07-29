# Quickstart: Verify the Amaru #1098 adoption

Run from `/code/amaru-bootstrap-issue-67`. Capture raw combined output and
real pipeline exit codes under the driver runtime.

## 1. Freeze and qualify upstream main

Capture `git ls-remote https://github.com/pragma-org/amaru.git
refs/heads/main`, require one full SHA, fetch that commit in a temporary
bare repository, and require
`437ff6c4fb506e1347eee9e619271a5ccb55a401` to be its ancestor.

## 2. RED

Require both current dependency records to equal the target and retain
their nonzero result. Temporarily add `definitely-not-a-command` to
`CLI_MOCK_ACCEPTED_AMARU`, run
`nix build .#checks.x86_64-linux.cli-mock-honesty`, require nonzero and the
literal rejected-command failure, then freeze the RED diff for review.

## 3. Update and isolate

After RED approval, explicitly remove the temporary seed. Change only the
full SHA in `flake.nix` and run:

```bash
nix flake lock --update-input amaru
```

Compare sorted before/after lock JSON with `.nodes.amaru` removed; the diff
must be empty. Require both locked and original revisions to equal the
target and require the original record to have no `ref`.

## 4. Focused and full GREEN

```bash
nix build .#checks.x86_64-linux.cli-mock-honesty
just build-gate
./gate.sh
```

Require every exit to be zero, `nix/amaru.nix` and the CLI declaration to
have no final diff, and the live output to record at least a 60-second
consumer hold.

After the final edit, freeze `green.diff`, file hashes, lock proofs, and
raw logs. Obtain navigator approval, create the one implementation commit,
and run the commit gate.

## 5. Hosted artifact

After push, require both named hosted checks to succeed on the exact
implementation commit. Inspect:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-74-<commit-sha>
```

Record the registry digest, keep the PR draft, and ask the milestone desk
for merge authorization.
