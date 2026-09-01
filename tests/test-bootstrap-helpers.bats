#!/usr/bin/env bats

# T001/T003: fatal-log cleanliness contract.
# Per specs/057-fatal-amaru-detection/contracts/fatal-log-contract.md:
#   - five fatal classes in table order
#   - caller-facing cleanliness check: 0 = readable + clean, nonzero = fatal | missing
#   - bounded diagnostics: at most two lines before and after the first match

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# --- T001: future-rollback signature ---

@test "scan: future-rollback class matches 'roll back in the future'" {
  printf 'attempted to roll back in the future\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "future-rollback" ]
}

# --- T001: caller-facing cleanliness result ---

@test "cleanliness: nonzero and consensus diagnostic on fatal log" {
  printf 'Consensus died, this should not happen!\n' >"$TMP_DIR/log"
  run assert_amaru_log_clean "$TMP_DIR/log"
  [ "$status" -ne 0 ]
  [[ "$output" == *"consensus"* ]]
  [[ "$output" == *"Consensus died, this should not happen!"* ]]
}

@test "cleanliness: zero on clean log" {
  # Fixture text tracks the startup trace the pinned Amaru actually emits
  # (build.ledger_opened; build_ledger was renamed away upstream), so the
  # cleanliness matcher is proven not to treat the real marker as fatal.
  printf 'build.ledger_opened\nchain sync ok\n' >"$TMP_DIR/log"
  run assert_amaru_log_clean "$TMP_DIR/log"
  [ "$status" -eq 0 ]
}

@test "cleanliness: nonzero and names path on missing log" {
  run assert_amaru_log_clean "$TMP_DIR/does-not-exist"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  [[ "$output" == *"$TMP_DIR/does-not-exist"* ]]
}

@test "cleanliness: nonzero on unreadable log" {
  printf 'Consensus died, this should not happen!\n' >"$TMP_DIR/log"
  chmod 000 "$TMP_DIR/log"
  [ ! -r "$TMP_DIR/log" ]
  run assert_amaru_log_clean "$TMP_DIR/log"
  chmod 644 "$TMP_DIR/log"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

# --- T003: all five fatal classes ---

@test "scan: vrf class" {
  printf 'Invalid VRF proof detected\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "vrf" ]
}

@test "scan: consensus class" {
  printf 'Consensus died, this should not happen!\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "consensus" ]
}

@test "scan: header class" {
  printf 'HeaderValidationError: block rejected\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "header" ]
}

@test "scan: rollback class" {
  printf 'ledger inconsistency at slot 42\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "rollback" ]
}

# --- T003: first-class ordering ---

@test "scan: vrf wins over rollback (existing classes)" {
  {
    printf 'ledger inconsistency at slot 1\n'
    printf 'Invalid VRF proof at slot 2\n'
  } >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "vrf" ]
}

@test "scan: rollback wins over future-rollback (table order)" {
  {
    printf 'roll back in the future at slot 1\n'
    printf 'ledger inconsistency at slot 2\n'
  } >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "rollback" ]
}

# --- T003: bounded diagnostic shape ---

@test "scan: single match diagnostic has at most two lines before and after" {
  {
    printf 'line1\n'
    printf 'line2\n'
    printf 'line3\n'
    printf 'line4\n'
    printf 'Consensus died here\n'
    printf 'after1\n'
    printf 'after2\n'
    printf 'after3\n'
    printf 'after4\n'
  } >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  # lines[0] is the class label on stdout; the diagnostic block on
  # stderr starts at lines[1]. Count content lines between the ---
  # header and footer (exclusive): at most 2 before + 1 match + 2
  # after = 5.
  local content=0
  local i
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      '--- amaru consume failure: '*) ;;
      '--- end amaru consume failure ---') ;;
      *) content=$((content + 1)) ;;
    esac
  done
  # Subtract 1 for the class label on stdout (lines[0]).
  content=$((content - 1))
  [ "$content" -le 5 ]
}

@test "scan: multiple matches — only first match in bounded diagnostic" {
  {
    printf 'b1\n'
    printf 'b2\n'
    printf 'b3\n'
    printf 'b4\n'
    printf 'Consensus died FIRST\n'
    printf 'a1\n'
    printf 'a2\n'
    printf 'a3\n'
    printf 'a4\n'
    printf 'a5\n'
    printf 'a6\n'
    printf 'a7\n'
    printf 'Consensus died SECOND\n'
    printf 'c1\n'
    printf 'c2\n'
  } >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "consensus" ]
  # The diagnostic must contain the first match.
  [[ "$output" == *"Consensus died FIRST"* ]]
  # The diagnostic must NOT contain the second match.
  [[ "$output" != *"Consensus died SECOND"* ]]
  # At most 5 content lines (2 before + 1 match + 2 after).
  local content=0
  local i
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      '--- amaru consume failure: '*) ;;
      '--- end amaru consume failure ---') ;;
      *) content=$((content + 1)) ;;
    esac
  done
  content=$((content - 1))
  [ "$content" -le 5 ]
}

# --- T003: no match and missing file ---

@test "scan: no match returns 1" {
  printf 'all good\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 1 ]
}

@test "scan: missing file returns 1" {
  run scan_amaru_log_for_fatal "$TMP_DIR/does-not-exist"
  [ "$status" -eq 1 ]
}

# --- T003: case sensitivity ---

@test "scan: case-sensitive — lowercase 'consensus died' is clean" {
  printf 'consensus died lowercase\n' >"$TMP_DIR/log"
  run scan_amaru_log_for_fatal "$TMP_DIR/log"
  [ "$status" -eq 1 ]
}
