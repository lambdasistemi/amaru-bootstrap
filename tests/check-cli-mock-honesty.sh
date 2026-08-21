#!/usr/bin/env bash
set -euo pipefail

# Validate the declared mock surfaces against the real flake-built
# binaries and confirm guard coverage in every audited bats owner.
# Sourced surface arrays are the single source of truth shared with
# the runtime guard in tests/lib/cli-mock-surface.bash.

source "$(dirname "$0")/lib/cli-mock-surface.bash"

fail=0

# --- Amaru: exit 0 from `<path> --help` means accepted ---
for cmd_path in "${CLI_MOCK_ACCEPTED_AMARU[@]}"; do
  # shellcheck disable=SC2086
  if amaru $cmd_path --help >/dev/null 2>&1; then
    printf 'OK: amaru %s accepted by real binary\n' "$cmd_path"
  else
    printf 'FAIL: amaru %s rejected by real binary\n' "$cmd_path" >&2
    fail=1
  fi
done

# --- Known invalid paths must be rejected ---
# shellcheck disable=SC2086
if amaru convert-ledger-state --help >/dev/null 2>&1; then
  printf 'FAIL: amaru convert-ledger-state accepted (expected rejection)\n' >&2
  fail=1
else
  printf 'OK: amaru convert-ledger-state rejected\n'
fi

# --- I-095-MOCK: real node bootstrap exposes --era-history ---
bootstrap_help=$(amaru node bootstrap --help 2>&1) || {
  printf 'FAIL: amaru node bootstrap --help exited non-zero\n' >&2
  fail=1
  bootstrap_help=""
}
if printf '%s\n' "$bootstrap_help" | grep -q -- '--era-history'; then
  printf 'OK: amaru node bootstrap exposes --era-history\n'
else
  printf 'FAIL: amaru node bootstrap --help missing --era-history\n' >&2
  fail=1
fi
if printf '%s\n' "$bootstrap_help" | grep -q 'AMARU_ERA_HISTORY'; then
  printf 'OK: amaru node bootstrap exposes AMARU_ERA_HISTORY\n'
else
  printf 'FAIL: amaru node bootstrap --help missing AMARU_ERA_HISTORY\n' >&2
  fail=1
fi

# --- I-095-AUDIT / F-095-S1-RANGE-WHITESPACE ---
# Carried patch artifacts must be free of trailing whitespace. A clean
# worktree `git diff --check` is not range proof: an added patch file
# with space-only unified-diff context lines is invisible there.
# Auditor: auditor-codex-s1 instrument
# 3fea684f8484e74b826ca9dd499d6f75a38b551fc2bfb2028231c2f8c69e36bb
# against 0aed4f706171b9fe9216c70c34d33518dd8c4ce4.
RANGE_WHITESPACE_BASE=5dd7c8fee7f37a7c11737595c6c5b1c6e80cdea7
REJECTED_WHITESPACE_CANDIDATE=0aed4f706171b9fe9216c70c34d33518dd8c4ce4

patch_has_trailing_whitespace() {
  grep -nE '[[:space:]]$' "$1"
}

# Control 1: synthetic trailing space must make the scanner fail.
ws_ctrl=$(mktemp)
printf 'diff --git a/x b/x\n \n' >"$ws_ctrl"
if patch_has_trailing_whitespace "$ws_ctrl" >/dev/null; then
  printf 'OK: patch whitespace scanner fails a synthetic trailing-space mutant\n'
else
  printf 'FAIL: patch whitespace scanner did not fail a synthetic mutant\n' >&2
  fail=1
fi
rm -f "$ws_ctrl"

# Control 2: rejected candidate blob must remain red (property class).
if git cat-file -e "$REJECTED_WHITESPACE_CANDIDATE:nix/patches/amaru-node-bootstrap-era-history.patch" 2>/dev/null; then
  ws_rej=$(mktemp)
  git cat-file blob \
    "$REJECTED_WHITESPACE_CANDIDATE:nix/patches/amaru-node-bootstrap-era-history.patch" \
    >"$ws_rej"
  if patch_has_trailing_whitespace "$ws_rej" >/dev/null; then
    printf 'OK: rejected candidate %s patch is whitespace-red\n' \
      "$REJECTED_WHITESPACE_CANDIDATE"
  else
    printf 'FAIL: property did not fail on rejected candidate patch\n' >&2
    fail=1
  fi
  rm -f "$ws_rej"
fi

shopt -s nullglob
ws_artifacts=(nix/patches/*.patch)
shopt -u nullglob
if [[ ${#ws_artifacts[@]} -eq 0 ]]; then
  printf 'FAIL: no carried patch artifacts under nix/patches/\n' >&2
  fail=1
fi
for ws_patch in "${ws_artifacts[@]+"${ws_artifacts[@]}"}"; do
  if patch_has_trailing_whitespace "$ws_patch" >/dev/null; then
    printf 'FAIL: trailing whitespace in carried patch %s\n' "$ws_patch" >&2
    patch_has_trailing_whitespace "$ws_patch" >&2 || true
    fail=1
  else
    printf 'OK: no trailing whitespace in %s\n' "$ws_patch"
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && git cat-file -e "${RANGE_WHITESPACE_BASE}^{commit}" 2>/dev/null; then
  if git diff --check "${RANGE_WHITESPACE_BASE}..HEAD"; then
    printf 'OK: git diff --check %s..HEAD\n' "$RANGE_WHITESPACE_BASE"
  else
    printf 'FAIL: range git diff --check %s..HEAD\n' "$RANGE_WHITESPACE_BASE" >&2
    fail=1
  fi
fi

# --- Guard coverage: every audited success-capable mock owner ---
for bats_file in \
  tests/test-bootstrap-producer-canonical-cli.bats \
  tests/test-bootstrap-producer-history.bats \
  tests/test-bootstrap-producer-sparse-boundaries.bats \
  tests/test-amaru-relay-bootstrap.bats \
  tests/test-relay-entrypoint.bats; do
  if grep -q 'cli_mock_guard' "$bats_file"; then
    printf 'OK: %s invokes cli_mock_guard\n' "$bats_file"
  else
    printf 'FAIL: %s missing cli_mock_guard\n' "$bats_file" >&2
    fail=1
  fi
done

# --- Helper reachability: every declared helper under tests/lib/ must
# have a command-position call site or an explicit exemption ---
#
# Caller grammar: match the helper name in command position after
# stripping comments, splitting at command separators (; && || | & $(
# ` ( ) { }), and allowing shell/bats keyword prefixes (run if elif
# while until then else do time command eval !).
#
# Known limitations (grep heuristic, not a bash parser):
# - A '#' inside a quoted string triggers trailing-comment truncation.
#   No real call site in the tree follows a '#' inside quotes.
# - A helper name after a separator inside a double-quoted string
#   (e.g. echo "a; helper_name") may be falsely accepted.
# - A helper name in a case pattern (e.g. helper_name) return 0 ;;)
#   may be falsely accepted.
# These are false-accept holes: they can miss a dead helper but never
# produce a false alarm on a live one.
# - Self-calls count as reachable. A self-recursive helper nobody else
#   calls is dead code this audit blesses.

audit_helper_reachability() {
  local lib_root="$1"
  local caller_root="$2"
  local audit_fail=0

  # --- Discovery ---
  local -a lib_files=()
  local f
  for f in "$lib_root"/*.bash; do
    [[ -f "$f" ]] && lib_files+=("$f")
  done
  if [[ ${#lib_files[@]} -eq 0 ]]; then
    printf 'helper-reachability: FAIL: no *.bash files in %s\n' "$lib_root" >&2
    return 1
  fi

  # Strict discovery: name() at column 0
  local -a decls=()
  mapfile -t decls < <(
    grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${lib_files[@]}" \
      | sed 's/()$//'
  )

  # Permissive cross-check: catch function-keyword, indented, or
  # spaced-paren forms the strict grammar does not claim.
  local ambiguous
  ambiguous=$(
    grep -hE '^[[:space:]]*(function[[:space:]]+[a-zA-Z_]|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\))' \
      "${lib_files[@]}" \
    | grep -vE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' \
    || true
  )
  if [[ -n "$ambiguous" ]]; then
    printf 'helper-reachability: FAIL: ambiguous discovery:\n%s\n' "$ambiguous" >&2
    return 1
  fi

  # Zero declarations from a non-empty file set
  if [[ ${#decls[@]} -eq 0 ]]; then
    printf 'helper-reachability: FAIL: zero declarations in %s\n' "$lib_root" >&2
    return 1
  fi

  # Duplicate detection (before sort -u)
  local dupes
  dupes=$(printf '%s\n' "${decls[@]}" | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    printf 'helper-reachability: FAIL: duplicate declarations: %s\n' "$dupes" >&2
    return 1
  fi

  mapfile -t decls < <(printf '%s\n' "${decls[@]}" | sort -u)

  # --- Caller file set ---
  local -a caller_files=("${lib_files[@]}")
  for f in "$caller_root"/*.bats "$caller_root"/*.sh; do
    [[ -f "$f" ]] && caller_files+=("$f")
  done

  # --- Exemption validation ---
  local exempt
  for exempt in ${HELPER_REACHABILITY_EXEMPT[@]+"${HELPER_REACHABILITY_EXEMPT[@]}"}; do
    local found=0
    local d
    for d in "${decls[@]}"; do
      [[ "$d" == "$exempt" ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      printf 'helper-reachability: FAIL: stale exemption: %s\n' "$exempt" >&2
      audit_fail=1
    fi
  done

  # --- Per-helper reachability ---
  local rejected=0
  local func
  for func in "${decls[@]}"; do
    # Command-position call-site count (C1: || true under pipefail)
    local hits
    hits=$(
      cat "${caller_files[@]}" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' \
      | sed 's/[[:space:]]#.*$//' \
      | grep -v "^${func}()" \
      | sed 's/\$(/\n/g; s/&&/\n/g; s/||/\n/g; s/[;|&`(){}]/\n/g' \
      | grep -cE "^[[:space:]]*((run|if|elif|while|until|then|else|do|time|command|eval|!)[[:space:]]+)*${func}([[:space:]<>]|$)" \
      || true
    )

    # Exemption check
    local is_exempt=0
    for exempt in ${HELPER_REACHABILITY_EXEMPT[@]+"${HELPER_REACHABILITY_EXEMPT[@]}"}; do
      [[ "$func" == "$exempt" ]] && { is_exempt=1; break; }
    done

    if [[ $is_exempt -eq 1 ]]; then
      if [[ "$hits" -gt 0 ]]; then
        printf 'helper-reachability: FAIL: redundant exemption: %s has %s call sites\n' "$func" "$hits" >&2
        audit_fail=1
      else
        printf 'accept %s (exempt)\n' "$func"
      fi
    elif [[ "$hits" -eq 0 ]]; then
      printf 'REJECT %s\n' "$func" >&2
      (( rejected++ )) || true
      audit_fail=1
    else
      printf 'accept %s (%s)\n' "$func" "$hits"
    fi
  done

  printf 'helper-reachability: census=%s rejected=%s\n' "${#decls[@]}" "$rejected"
  return "$audit_fail"
}

reachability_tmpdir=$(mktemp -d)
trap 'rm -rf "$reachability_tmpdir"' EXIT

# Control 1: declaration-only -> REJECT naming the helper
mkdir -p "$reachability_tmpdir/t1/lib"
printf '%s\n' 'reachability_orphan_fixture() { :; }' \
  > "$reachability_tmpdir/t1/lib/a.bash"
output=$(audit_helper_reachability "$reachability_tmpdir/t1/lib" "$reachability_tmpdir/t1" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 1: expected rejection of reachability_orphan_fixture, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reachability_orphan_fixture"* ]]; then
  printf 'FAIL: reachability 1: rejection did not name reachability_orphan_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 1: reachability_orphan_fixture rejected and named\n'
fi

# Control 2: doc-comment-only -> REJECT
mkdir -p "$reachability_tmpdir/t2/lib"
printf '%s\n' \
  '# reachability_doc_fixture <args>' \
  '#' \
  '# Does a thing.' \
  'reachability_doc_fixture() { :; }' \
  > "$reachability_tmpdir/t2/lib/a.bash"
output=$(audit_helper_reachability "$reachability_tmpdir/t2/lib" "$reachability_tmpdir/t2" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 2: expected rejection of reachability_doc_fixture, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reachability_doc_fixture"* ]]; then
  printf 'FAIL: reachability 2: rejection did not name reachability_doc_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 2: reachability_doc_fixture rejected and named\n'
fi

# Control 3: string-literal-only -> REJECT
mkdir -p "$reachability_tmpdir/t3/lib"
printf '%s\n' \
  'reachability_string_fixture() { :; }' \
  'reachability_string_caller() {' \
  "  printf 'reachability_string_fixture: done\\n'" \
  '}' \
  > "$reachability_tmpdir/t3/lib/a.bash"
printf '%s\n' \
  '@test "call caller" {' \
  '  reachability_string_caller' \
  '}' \
  > "$reachability_tmpdir/t3/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t3/lib" "$reachability_tmpdir/t3" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 3: expected rejection of reachability_string_fixture, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reachability_string_fixture"* ]]; then
  printf 'FAIL: reachability 3: rejection did not name reachability_string_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 3: reachability_string_fixture rejected and named\n'
fi

# Control 4: trailing-comment-only -> REJECT
mkdir -p "$reachability_tmpdir/t4/lib"
printf '%s\n' \
  'reachability_trailing_fixture() { :; }' \
  'reachability_trailing_caller() {' \
  '  true # see reachability_trailing_fixture' \
  '}' \
  > "$reachability_tmpdir/t4/lib/a.bash"
printf '%s\n' \
  '@test "call caller" {' \
  '  reachability_trailing_caller' \
  '}' \
  > "$reachability_tmpdir/t4/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t4/lib" "$reachability_tmpdir/t4" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 4: expected rejection of reachability_trailing_fixture, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reachability_trailing_fixture"* ]]; then
  printf 'FAIL: reachability 4: rejection did not name reachability_trailing_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 4: reachability_trailing_fixture rejected and named\n'
fi

# Control 5: substring — declare reach_foo, call reach_foo_bar -> REJECT reach_foo
mkdir -p "$reachability_tmpdir/t5/lib"
printf '%s\n' \
  'reach_foo() { :; }' \
  'reach_foo_bar() { :; }' \
  > "$reachability_tmpdir/t5/lib/a.bash"
printf '%s\n' \
  '@test "call foo_bar" {' \
  '  reach_foo_bar' \
  '}' \
  > "$reachability_tmpdir/t5/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t5/lib" "$reachability_tmpdir/t5" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 5: expected rejection of reach_foo, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reach_foo"* ]]; then
  printf 'FAIL: reachability 5: rejection did not name reach_foo\n' >&2
  fail=1
else
  printf 'OK: reachability 5: reach_foo rejected and named\n'
fi

# Control 6: reverse-substring — declare reach_foo_bar, call reach_foo -> REJECT reach_foo_bar
mkdir -p "$reachability_tmpdir/t6/lib"
printf '%s\n' \
  'reach_foo_bar() { :; }' \
  'reach_foo() { :; }' \
  > "$reachability_tmpdir/t6/lib/a.bash"
printf '%s\n' \
  '@test "call foo" {' \
  '  reach_foo' \
  '}' \
  > "$reachability_tmpdir/t6/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t6/lib" "$reachability_tmpdir/t6" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 6: expected rejection of reach_foo_bar, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"reach_foo_bar"* ]]; then
  printf 'FAIL: reachability 6: rejection did not name reach_foo_bar\n' >&2
  fail=1
else
  printf 'OK: reachability 6: reach_foo_bar rejected and named\n'
fi

# Control 7: duplicate declaration name -> HARD FAIL naming the duplicate
mkdir -p "$reachability_tmpdir/t7/lib"
printf '%s\n' 'reachability_dup_fixture() { :; }' \
  > "$reachability_tmpdir/t7/lib/a.bash"
printf '%s\n' 'reachability_dup_fixture() { :; }' \
  > "$reachability_tmpdir/t7/lib/b.bash"
output=$(audit_helper_reachability "$reachability_tmpdir/t7/lib" "$reachability_tmpdir/t7" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 7: expected hard-fail for duplicate reachability_dup_fixture, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"duplicate"* || "$output" != *"reachability_dup_fixture"* ]]; then
  printf 'FAIL: reachability 7: hard-fail did not name duplicate reachability_dup_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 7: duplicate reachability_dup_fixture hard-fail\n'
fi

# Control 8: zero declarations -> HARD FAIL
mkdir -p "$reachability_tmpdir/t8/lib"
printf '%s\n' '# no declarations here' \
  > "$reachability_tmpdir/t8/lib/a.bash"
output=$(audit_helper_reachability "$reachability_tmpdir/t8/lib" "$reachability_tmpdir/t8" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 8: expected hard-fail for zero declarations, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"zero"* ]]; then
  printf 'FAIL: reachability 8: hard-fail did not mention zero declarations\n' >&2
  fail=1
else
  printf 'OK: reachability 8: zero declarations hard-fail\n'
fi

# Control 9: ambiguous declaration (function keyword) -> HARD FAIL
# A valid strict declaration is present so zero-declarations is false;
# only the ambiguity condition is live.
mkdir -p "$reachability_tmpdir/t9/lib"
printf '%s\n' \
  'reachability_valid_decl() { :; }' \
  'function reachability_ambiguous { :; }' \
  > "$reachability_tmpdir/t9/lib/a.bash"
printf '%s\n' \
  '@test "call valid" {' \
  '  reachability_valid_decl' \
  '}' \
  > "$reachability_tmpdir/t9/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t9/lib" "$reachability_tmpdir/t9" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 9: expected hard-fail for ambiguous declaration, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"ambiguous"* ]]; then
  printf 'FAIL: reachability 9: hard-fail did not mention ambiguous discovery\n' >&2
  fail=1
else
  printf 'OK: reachability 9: ambiguous declaration hard-fail\n'
fi

# Control 10: stale exemption -> HARD FAIL naming the bogus entry
mkdir -p "$reachability_tmpdir/t10/lib"
printf '%s\n' 'reachability_real_helper() { :; }' \
  > "$reachability_tmpdir/t10/lib/a.bash"
printf '%s\n' \
  '@test "call it" {' \
  '  reachability_real_helper' \
  '}' \
  > "$reachability_tmpdir/t10/caller.bats"
HELPER_REACHABILITY_EXEMPT=(reachability_nonexistent_helper)
output=$(audit_helper_reachability "$reachability_tmpdir/t10/lib" "$reachability_tmpdir/t10" 2>&1) && rc=0 || rc=$?
HELPER_REACHABILITY_EXEMPT=()
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 10: expected hard-fail for stale exemption reachability_nonexistent_helper, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"stale"* || "$output" != *"reachability_nonexistent_helper"* ]]; then
  printf 'FAIL: reachability 10: hard-fail did not name stale exemption reachability_nonexistent_helper\n' >&2
  fail=1
else
  printf 'OK: reachability 10: stale exemption reachability_nonexistent_helper hard-fail\n'
fi

# Control 11: redundant exemption -> HARD FAIL naming the entry
mkdir -p "$reachability_tmpdir/t11/lib"
printf '%s\n' 'reachability_redundant_helper() { :; }' \
  > "$reachability_tmpdir/t11/lib/a.bash"
printf '%s\n' \
  '@test "call it" {' \
  '  reachability_redundant_helper' \
  '}' \
  > "$reachability_tmpdir/t11/caller.bats"
HELPER_REACHABILITY_EXEMPT=(reachability_redundant_helper)
output=$(audit_helper_reachability "$reachability_tmpdir/t11/lib" "$reachability_tmpdir/t11" 2>&1) && rc=0 || rc=$?
HELPER_REACHABILITY_EXEMPT=()
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: reachability 11: expected hard-fail for redundant exemption reachability_redundant_helper, got acceptance\n' >&2
  fail=1
elif [[ "$output" != *"redundant"* || "$output" != *"reachability_redundant_helper"* ]]; then
  printf 'FAIL: reachability 11: hard-fail did not name redundant exemption reachability_redundant_helper\n' >&2
  fail=1
else
  printf 'OK: reachability 11: redundant exemption reachability_redundant_helper hard-fail\n'
fi

# Control 12: reachable helper -> ACCEPT with nonzero census
mkdir -p "$reachability_tmpdir/t12/lib"
printf '%s\n' 'reachability_called_fixture() { :; }' \
  > "$reachability_tmpdir/t12/lib/a.bash"
printf '%s\n' \
  '@test "call it" {' \
  '  reachability_called_fixture' \
  '}' \
  > "$reachability_tmpdir/t12/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t12/lib" "$reachability_tmpdir/t12" 2>&1) && rc=0 || rc=$?
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 12: reachable helper reachability_called_fixture rejected\n' >&2
  fail=1
elif [[ "$census" -eq 0 ]]; then
  printf 'FAIL: reachability 12: census=0, expected nonzero\n' >&2
  fail=1
elif [[ "$output" != *"reachability_called_fixture"* ]]; then
  printf 'FAIL: reachability 12: per-helper verdict missing for reachability_called_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 12: reachability_called_fixture accepted, census=%s\n' "$census"
fi

# Control 13: exempt helper -> ACCEPT with nonzero census
mkdir -p "$reachability_tmpdir/t13/lib"
printf '%s\n' 'reachability_exempt_fixture() { :; }' \
  > "$reachability_tmpdir/t13/lib/a.bash"
HELPER_REACHABILITY_EXEMPT=(reachability_exempt_fixture)
output=$(audit_helper_reachability "$reachability_tmpdir/t13/lib" "$reachability_tmpdir/t13" 2>&1) && rc=0 || rc=$?
HELPER_REACHABILITY_EXEMPT=()
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 13: exempt helper reachability_exempt_fixture rejected\n' >&2
  fail=1
elif [[ "$census" -eq 0 ]]; then
  printf 'FAIL: reachability 13: census=0, expected nonzero\n' >&2
  fail=1
elif [[ "$output" != *"reachability_exempt_fixture"* ]]; then
  printf 'FAIL: reachability 13: per-helper verdict missing for reachability_exempt_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 13: reachability_exempt_fixture accepted (exempt), census=%s\n' "$census"
fi

# Control 14: intra-library call -> ACCEPT with nonzero census
mkdir -p "$reachability_tmpdir/t14/lib"
printf '%s\n' 'reachability_intra_callee() { :; }' \
  > "$reachability_tmpdir/t14/lib/a.bash"
printf '%s\n' \
  'reachability_intra_caller() {' \
  '  reachability_intra_callee' \
  '}' \
  > "$reachability_tmpdir/t14/lib/b.bash"
printf '%s\n' \
  '@test "call caller" {' \
  '  reachability_intra_caller' \
  '}' \
  > "$reachability_tmpdir/t14/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t14/lib" "$reachability_tmpdir/t14" 2>&1) && rc=0 || rc=$?
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 14: intra-library callee reachability_intra_callee rejected\n' >&2
  fail=1
elif [[ "$census" -eq 0 ]]; then
  printf 'FAIL: reachability 14: census=0, expected nonzero\n' >&2
  fail=1
elif [[ "$output" != *"reachability_intra_callee"* ]]; then
  printf 'FAIL: reachability 14: per-helper verdict missing for reachability_intra_callee\n' >&2
  fail=1
else
  printf 'OK: reachability 14: reachability_intra_callee accepted (intra-library), census=%s\n' "$census"
fi

# Control 15: self-call -> ACCEPT (known limitation: self-recursive
# helper nobody else calls is dead code this audit blesses)
mkdir -p "$reachability_tmpdir/t15/lib"
printf '%s\n' \
  'reachability_self_call() {' \
  '  reachability_self_call' \
  '}' \
  > "$reachability_tmpdir/t15/lib/a.bash"
output=$(audit_helper_reachability "$reachability_tmpdir/t15/lib" "$reachability_tmpdir/t15" 2>&1) && rc=0 || rc=$?
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 15: self-call helper reachability_self_call rejected\n' >&2
  fail=1
elif [[ "$census" -eq 0 ]]; then
  printf 'FAIL: reachability 15: census=0, expected nonzero\n' >&2
  fail=1
elif [[ "$output" != *"reachability_self_call"* ]]; then
  printf 'FAIL: reachability 15: per-helper verdict missing for reachability_self_call\n' >&2
  fail=1
else
  printf 'OK: reachability 15: reachability_self_call accepted (self-call), census=%s\n' "$census"
fi

# Control 16: redirect-no-space call -> ACCEPT (C4: V4 shape)
mkdir -p "$reachability_tmpdir/t16/lib"
printf '%s\n' 'reachability_redir_fixture() { :; }' \
  > "$reachability_tmpdir/t16/lib/a.bash"
printf '%s\n' \
  '@test "redirect" {' \
  '  reachability_redir_fixture>/dev/null' \
  '}' \
  > "$reachability_tmpdir/t16/caller.bats"
output=$(audit_helper_reachability "$reachability_tmpdir/t16/lib" "$reachability_tmpdir/t16" 2>&1) && rc=0 || rc=$?
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 16: redirect helper reachability_redir_fixture rejected\n' >&2
  fail=1
elif [[ "$census" -eq 0 ]]; then
  printf 'FAIL: reachability 16: census=0, expected nonzero\n' >&2
  fail=1
elif [[ "$output" != *"reachability_redir_fixture"* ]]; then
  printf 'FAIL: reachability 16: per-helper verdict missing for reachability_redir_fixture\n' >&2
  fail=1
else
  printf 'OK: reachability 16: reachability_redir_fixture accepted, census=%s\n' "$census"
fi

# Control 17: real tree — audit tests/lib with caller_root=tests
# Asserts census equals an independently re-derived count, the four
# brief-named intra-library helpers each appear as accepted, and
# prints the full per-helper verdict output on success.
output=$(audit_helper_reachability tests/lib tests 2>&1) && rc=0 || rc=$?
census=$(printf '%s\n' "$output" | grep -oE 'census=[0-9]+' | head -1 | cut -d= -f2) || true
census=${census:-0}
expected=$( { grep -hcE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' tests/lib/*.bash || true; } \
  | awk '{s+=$1} END {print s+0}')
if [[ $rc -ne 0 ]]; then
  printf 'FAIL: reachability 17: real helper tree rejected\n' >&2
  printf '%s\n' "$output" >&2
  fail=1
elif [[ "$census" -ne "$expected" ]]; then
  printf 'FAIL: reachability 17: census=%s, expected %s (independently derived)\n' "$census" "$expected" >&2
  fail=1
elif [[ "$output" != *"refresh_amaru_consumer_log"* ]]; then
  printf 'FAIL: reachability 17: missing verdict for refresh_amaru_consumer_log\n' >&2
  fail=1
elif [[ "$output" != *"assert_amaru_consumer_running"* ]]; then
  printf 'FAIL: reachability 17: missing verdict for assert_amaru_consumer_running\n' >&2
  fail=1
elif [[ "$output" != *"report_amaru_exited_early"* ]]; then
  printf 'FAIL: reachability 17: missing verdict for report_amaru_exited_early\n' >&2
  fail=1
elif [[ "$output" != *"scan_amaru_log_for_fatal"* ]]; then
  printf 'FAIL: reachability 17: missing verdict for scan_amaru_log_for_fatal\n' >&2
  fail=1
else
  printf 'OK: reachability 17: real helper tree accepted, census=%s\n' "$census"
  printf '%s\n' "$output"
fi

exit "$fail"
