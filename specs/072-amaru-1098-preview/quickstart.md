# Quickstart: Verify the Amaru #1098 Preview

Run from `/code/amaru-bootstrap-issue-72`. Driver evidence is captured
under its runtime `handoffs/` directory with `set -o pipefail`, raw output,
and explicit exit markers. Hashes are captured only after the final edit.

## 1. Freeze the upstream head

```bash
set -o pipefail
git ls-remote https://github.com/pragma-org/amaru.git \
  refs/heads/etorreborre/fix/rollback-in-the-future \
  2>&1 | tee "$DRIVER_ROOT/handoffs/upstream-head.raw.log"
rc=${PIPESTATUS[0]}
printf 'UPSTREAM_HEAD_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/upstream-head.raw.log"
test "$rc" -eq 0
```

Require exactly one record and set `TARGET_SHA` from it. If it differs from
the brief target, stop with a Q-file before editing so the plan and PR can
record the moved head.

## 2. Observe the dependency RED

```bash
set -o pipefail
(
  source_rev=$(sed -n \
    's|.*github:pragma-org/amaru/\([0-9a-f]\{40\}\).*|\1|p' flake.nix)
  lock_rev=$(jq -r '.nodes.amaru.locked.rev' flake.lock)
  test "$source_rev" = "$TARGET_SHA"
  test "$lock_rev" = "$TARGET_SHA"
) 2>&1 | tee "$DRIVER_ROOT/handoffs/pin-red.raw.log"
rc=${PIPESTATUS[0]}
printf 'PIN_RED_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/pin-red.raw.log"
test "$rc" -ne 0
```

## 3. Prove CLI honesty can fail

Temporarily add one known-rejected command to
`CLI_MOCK_ACCEPTED_AMARU` in `tests/lib/cli-mock-surface.bash`, then:

```bash
set -o pipefail
nix build .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 | tee "$DRIVER_ROOT/handoffs/cli-seeded-red.raw.log"
rc=${PIPESTATUS[0]}
printf 'CLI_SEEDED_RED_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/cli-seeded-red.raw.log"
test "$rc" -ne 0
```

Freeze the complete RED diff, pass the handoff completeness gate, obtain
navigator approval, and restore only the temporary seed without destructive
Git commands.

## 4. Update only the Amaru lock input

Edit the full SHA in `flake.nix`, then:

```bash
nix flake lock --update-input amaru
```

Prove every unrelated lock node is unchanged:

```bash
jq -S 'del(.nodes.amaru)' \
  <(git show HEAD:flake.lock) >"$DRIVER_ROOT/handoffs/lock-before.json"
jq -S 'del(.nodes.amaru)' flake.lock \
  >"$DRIVER_ROOT/handoffs/lock-after.json"
diff -u "$DRIVER_ROOT/handoffs/lock-before.json" \
  "$DRIVER_ROOT/handoffs/lock-after.json"
```

The diff must exit zero and print no differences.

## 5. Focused GREEN and staging proof

```bash
set -o pipefail
nix build .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 | tee "$DRIVER_ROOT/handoffs/cli-green.raw.log"
rc=${PIPESTATUS[0]}
printf 'CLI_GREEN_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/cli-green.raw.log"
test "$rc" -eq 0

git diff --exit-code HEAD -- nix/amaru.nix
```

The successful selected-source build plus the zero `nix/amaru.nix` diff is
the proof that main's peer-snapshot staging still suffices. If the build
fails because that contract changed, preserve the raw log and write a
Q-file; do not edit outside the owned fence.

## 6. Full GREEN

```bash
set -o pipefail
just build-gate 2>&1 \
  | tee "$DRIVER_ROOT/handoffs/build-gate.raw.log"
rc=${PIPESTATUS[0]}
printf 'BUILD_GATE_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/build-gate.raw.log"
test "$rc" -eq 0

set -o pipefail
./gate.sh 2>&1 | tee "$DRIVER_ROOT/handoffs/full-gate.raw.log"
rc=${PIPESTATUS[0]}
printf 'FULL_GATE_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/full-gate.raw.log"
test "$rc" -eq 0
```

Re-resolve the upstream branch. If it moved, stop and report; evidence for
the old target cannot certify the new head.

## 7. Freeze evidence and commit

After the last write, sequentially re-capture the GREEN diff, file hashes,
and upstream head; run the handoff completeness gate; verify the frozen
artifacts contain the expected two-file pin change and no final CLI seed.
Only then request GREEN review and commit the exact approved bytes.

## 8. Hosted checks and image

After the orchestrator pushes the accepted commit:

1. mechanically verify `Build Gate` and `Live Bootstrap Producer` succeed
   on that exact SHA;
2. find the successful `Publish bootstrap-producer image` workflow run
   sourced from that CI run;
3. resolve
   `ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-73-<full-sha>` to its
   registry digest;
4. record the tag, digest, check URLs, and exact source SHA in PR #73 and
   the milestone STATUS report;
5. leave PR #73 draft and open.
