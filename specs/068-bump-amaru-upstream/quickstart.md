# Quickstart: Verify the Amaru upstream bump

Run from `/code/amaru-bootstrap-issue-68`. Every acceptance command is
captured with `set -o pipefail`, raw combined output, and the real first
pipeline exit code. Evidence hashes are taken later, after the final edit.

## 1. Freeze the upstream target and premise

```bash
set -o pipefail
git ls-remote https://github.com/pragma-org/amaru.git refs/heads/main \
  2>&1 | tee "$DRIVER_ROOT/handoffs/upstream-main.raw.log"
rc=${PIPESTATUS[0]}
printf 'UPSTREAM_MAIN_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/upstream-main.raw.log"
test "$rc" -eq 0

gh api repos/pragma-org/amaru/pulls/1098 \
  --jq '{state:.state,merged:.merged,head:.head.sha,base:.base.sha}' \
  2>&1 | tee "$DRIVER_ROOT/handoffs/upstream-1098.raw.log"
rc=${PIPESTATUS[0]}
printf 'UPSTREAM_1098_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/upstream-1098.raw.log"
test "$rc" -eq 0
```

If pull request #1098 is merged, stop and write a Q-file before editing.

## 2. Observe the dependency RED

Set `TARGET_SHA` from the single `ls-remote` record, then require both old
records to equal it. This command must exit nonzero before the pin change.

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
`CLI_MOCK_ACCEPTED_AMARU`, run the real-binary check, and require nonzero.
Freeze the RED diff and raw output for navigator review. Restore only that
temporary seed after RED approval; do not use destructive Git commands.

```bash
set -o pipefail
nix build .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 | tee "$DRIVER_ROOT/handoffs/cli-seeded-red.raw.log"
rc=${PIPESTATUS[0]}
printf 'CLI_SEEDED_RED_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/cli-seeded-red.raw.log"
test "$rc" -ne 0
```

## 4. Update and isolate the lock change

Edit only the full SHA in `flake.nix`, then let Nix update only the named
input:

```bash
nix flake lock --update-input amaru
```

Compare the lock files structurally with the Amaru node removed:

```bash
jq -S 'del(.nodes.amaru)' \
  <(git show HEAD:flake.lock) >"$DRIVER_ROOT/handoffs/lock-before.json"
jq -S 'del(.nodes.amaru)' flake.lock \
  >"$DRIVER_ROOT/handoffs/lock-after.json"
diff -u "$DRIVER_ROOT/handoffs/lock-before.json" \
  "$DRIVER_ROOT/handoffs/lock-after.json"
```

The diff must exit 0 and print no differences.

## 5. Focused GREEN

```bash
set -o pipefail
nix build .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 | tee "$DRIVER_ROOT/handoffs/cli-green.raw.log"
rc=${PIPESTATUS[0]}
printf 'CLI_GREEN_EXIT=%s\n' "$rc" \
  | tee -a "$DRIVER_ROOT/handoffs/cli-green.raw.log"
test "$rc" -eq 0
```

Re-run the exact-pin assertion from step 2 and require exit 0.

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

After the final edit and these runs, capture fresh file hashes, re-capture
the full frozen GREEN diff (including any intent-to-add files), run the
handoff completeness gate, and verify each frozen artifact semantically
before making any readiness claim.
