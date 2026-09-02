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

# --- consumer startup-marker helpers (live predicate logic, docker-free) ---

@test "markers: ledger-opened accepts both spellings, rejects absence" {
  printf 'noise\n{"level":"INFO","fields":{"message":"build.ledger_opened","tip":[2519,"aa"]}}\n' >"$TMP_DIR/log"
  run amaru_log_has_ledger_opened "$TMP_DIR/log"
  [ "$status" -eq 0 ]

  printf 'build_ledger done\n' >"$TMP_DIR/log"
  run amaru_log_has_ledger_opened "$TMP_DIR/log"
  [ "$status" -eq 0 ]

  printf 'neither spelling anywhere\n' >"$TMP_DIR/log"
  run amaru_log_has_ledger_opened "$TMP_DIR/log"
  [ "$status" -ne 0 ]
}

@test "markers: connected-to accepts the info chainsync intersect_found event in both renderings and the legacy string" {
  # The info-level observable at the pinned node:
  # consensus::chainsync::INTERSECT_FOUND (track_peers, on the consumer's
  # upstream chainsync path). Console rendering: name as the message field
  # after the target, peer as a bare Display value.
  printf '%s\n' \
    '2026-01-01T00:00:00.000000Z  INFO amaru::consensus: chainsync.intersect_found peer=127.0.0.1:3001 conn_id=17 current=Point { slot: Slot(2519), hash: Hash(aa) } highest=Point { slot: Slot(2520), hash: Hash(bb) }' \
    >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -eq 0 ]

  # --with-json-traces rendering: name inside fields.message, peer as a
  # JSON string. The full dotted path is NOT pinned by the helper, so
  # this line exercises the substring that both renderings share.
  printf '%s\n' \
    '{"timestamp":"2026-01-01T00:00:00.000000Z","level":"INFO","fields":{"message":"chainsync.intersect_found","peer":"127.0.0.1:3001","conn_id":17,"current":{"slot":2519},"highest":{"slot":2520}},"target":"amaru::consensus"}' \
    >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -eq 0 ]

  # Legacy spelling still accepted (line carries both marker and peer).
  printf 'connection established with "peer":"127.0.0.1:3001"\n' >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -eq 0 ]
}

@test "markers: connected-to is falsifiable in every wrong direction" {
  # Intersected with a different port must not satisfy the requested peer.
  printf '%s\n' \
    'INFO amaru::consensus: chainsync.intersect_found peer=127.0.0.1:3002 conn_id=17' \
    >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -ne 0 ]

  # The peer address on its own line must not be combined with a marker
  # line about another peer: both spellings are line-scoped.
  printf '%s\n%s\n' \
    'chainsync.intersect_found peer=127.0.0.1:3002' \
    '"peer":"127.0.0.1:3001" alone on a line' \
    >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -ne 0 ]

  # Near-miss names must not match: INTERSECT_NOT_FOUND is the failure
  # outcome, not success evidence.
  printf '%s\n' \
    'INFO amaru::consensus: chainsync.intersect_not_found peer=127.0.0.1:3001 highest=Point' \
    >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -ne 0 ]

  # A consumer that never connects matches nothing.
  printf 'no connections here\n' >"$TMP_DIR/log"
  run amaru_log_has_connected_to "$TMP_DIR/log" 127.0.0.1:3001
  [ "$status" -ne 0 ]
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
