#!/usr/bin/env bats

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  SCRIPT="$REPO_ROOT/scripts/daily-amaru-handoff.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures/daily-amaru-handoff"
  TEST_ROOT="$BATS_TEST_TMPDIR/fixture"
  DAY=2026-08-19
}

use_fixture() {
  local name="$1"
  rm -rf "$TEST_ROOT"
  cp -R "$FIXTURES/$name" "$TEST_ROOT"
  mkdir -p "$TEST_ROOT/published"
}

reconcile() {
  run "$SCRIPT" reconcile \
    --observation-day "$DAY" \
    --transport fixture \
    --fixture-root "$TEST_ROOT"
}

mutate_json() {
  local file="$1"
  local program="$2"
  jq -S "$program" "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

published_path() {
  printf '%s/published/%s.json\n' "$TEST_ROOT" "$1"
}

published_set_manifest() {
  local file
  while IFS= read -r -d '' file; do
    printf '%s  %s\n' \
      "$(sha256sum "$file" | cut -d' ' -f1)" \
      "${file#"$TEST_ROOT/published/"}"
  done < <(find "$TEST_ROOT/published" -type f -print0 | sort -z)
}

assert_published_set_empty() {
  if find "$TEST_ROOT/published" -type f -print -quit | grep -q .; then
    return 1
  fi
}

assert_published_set_unchanged() {
  local before="$1"
  [ "$(published_set_manifest)" = "$before" ]
}

assert_no_mutation_operations() {
  if [[ -f "$TEST_ROOT/operations.log" ]]; then
    ! grep -Eq '^(resolve_peer_snapshots|propose_pin|open_pull_request) ' \
      "$TEST_ROOT/operations.log"
  fi
}

@test "unchanged tuple publishes one canonical immutable daily result" {
  use_fixture unchanged-existing

  reconcile

  [ "$status" -eq 0 ]
  result=$(published_path "amaru-daily-v1-$DAY")
  [ -f "$result" ]
  jq -e \
    '.result == "UNCHANGED"
     and .observed_sha == "1111111111111111111111111111111111111111"
     and .pinned_sha == .observed_sha
     and (has("handoff") | not)' "$result"
  run "$SCRIPT" validate-daily-result --file "$result"
  [ "$status" -eq 0 ]
  assert_no_mutation_operations
}

@test "identical same-day retry is byte-idempotent" {
  use_fixture unchanged-existing
  reconcile
  [ "$status" -eq 0 ]
  result=$(published_path "amaru-daily-v1-$DAY")
  before=$(sha256sum "$result")

  reconcile

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$result")" = "$before" ]
  [ "$(find "$TEST_ROOT/published" -type f | wc -l)" -eq 1 ]
  grep -q '^publish_immutable .* identical$' "$TEST_ROOT/operations.log"
}

@test "different same-day bytes conflict without replacement" {
  use_fixture unchanged-existing
  result=$(published_path "amaru-daily-v1-$DAY")
  printf '{"occupied":true}\n' >"$result"
  before=$(published_set_manifest)

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFLICT-RECEIPT"* ]]
  assert_published_set_unchanged "$before"
}

@test "existing handoff release target must equal bootstrap identity" {
  use_fixture unchanged-existing
  mutate_json "$TEST_ROOT/scenario.json" \
    '.handoff_target_sha = "9999999999999999999999999999999999999999"'
  before=$(published_set_manifest)

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFLICT-RECEIPT"* ]]
  assert_published_set_unchanged "$before"
}

@test "changed source publishes strict handoff and day result for integrated SHA" {
  use_fixture changed-success

  reconcile

  [ "$status" -eq 0 ]
  handoff_key=amaru-handoff-v1-1111111111111111111111111111111111111111-4444444444444444444444444444444444444444
  handoff=$(published_path "$handoff_key")
  result=$(published_path "amaru-daily-v1-$DAY")
  [ -f "$handoff" ]
  [ -f "$result" ]
  jq -e \
    '.upstream.sha == "1111111111111111111111111111111111111111"
     and .bootstrap.sha == "4444444444444444444444444444444444444444"
     and .ci.head_sha == .bootstrap.sha
     and .image.tag == .bootstrap.sha
     and .publication.head_sha == .bootstrap.sha
     and .peer_snapshots.configurations_sha == "5555555555555555555555555555555555555555"' \
    "$handoff"
  jq -e --arg key "$handoff_key" \
    '.result == "HANDOFF" and .handoff.release_tag == $key' "$result"
  run "$SCRIPT" validate-handoff --file "$handoff"
  [ "$status" -eq 0 ]
  run "$SCRIPT" validate-daily-result --file "$result"
  [ "$status" -eq 0 ]
}

@test "changed path never publishes pre-integration bootstrap identity" {
  use_fixture changed-success

  reconcile

  [ "$status" -eq 0 ]
  ! find "$TEST_ROOT/published" -type f \
    -name '*3333333333333333333333333333333333333333*' | grep -q .
  ! grep -R -q '3333333333333333333333333333333333333333' \
    "$TEST_ROOT/published"
  grep -q '^read_bootstrap_sha 3333333333333333333333333333333333333333$' \
    "$TEST_ROOT/operations.log"
  grep -q '^integrated_sha 75 4444444444444444444444444444444444444444$' \
    "$TEST_ROOT/operations.log"
}

@test "changed proposal carries exactly observed and rule-selected revisions" {
  use_fixture changed-success

  reconcile

  [ "$status" -eq 0 ]
  grep -q \
    '^propose_pin 1111111111111111111111111111111111111111 5555555555555555555555555555555555555555 ' \
    "$TEST_ROOT/operations.log"
  [ "$(grep -c '^resolve_upstream_head ' "$TEST_ROOT/operations.log")" -eq 1 ]
}

@test "lock isolation rejects drift outside amaru and configurations nodes" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/lock-after.json" \
    '.nodes.nixpkgs.locked.rev = "ffffffffffffffffffffffffffffffffffffffff"'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-PEER-SNAPSHOT-RESOLUTION"* ]]
  assert_published_set_empty
}

@test "peer snapshot resolution failure publishes nothing" {
  use_fixture changed-success
  printf '{"status":"failure"}\n' >"$TEST_ROOT/peer-resolution.json"

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-PEER-SNAPSHOT-RESOLUTION"* ]]
  assert_published_set_empty
}

@test "wrong upstream repository fails before mutation" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" \
    '.upstream_repository = "https://github.com/example/amaru"'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-WRONG-ORIGIN"* ]]
  assert_published_set_empty
  assert_no_mutation_operations
}

@test "wrong upstream ref fails before mutation" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" '.upstream_ref = "refs/heads/release"'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-WRONG-ORIGIN"* ]]
  assert_published_set_empty
  assert_no_mutation_operations
}

@test "absent pending and failed required CI are distinct fail-closed states" {
  local state
  for state in absent pending failure; do
    use_fixture changed-success
    printf '%s\n' "$state" >"$TEST_ROOT/ci.json"
    reconcile
    [ "$status" -ne 0 ]
    [[ "$output" == *"BLOCKED-REQUIRED-CI"* ]]
    [[ "$output" == *"state=$state"* ]]
    assert_published_set_empty
  done
}

@test "missing image publication receipt publishes nothing" {
  use_fixture changed-success
  rm "$TEST_ROOT/image-publication-receipt.json"

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-PUBLICATION"* ]]
  assert_published_set_empty
}

@test "missing registry digest publishes nothing" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" 'del(.registry_digest)'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-DIGEST"* ]]
  assert_published_set_empty
}

@test "registry digest mismatch is terminal and receipt digest is not replaced" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" \
    '.registry_digest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-DIGEST"* ]]
  assert_published_set_empty
}

@test "missing CLI honesty evidence publishes nothing" {
  use_fixture changed-success
  rm "$TEST_ROOT/cli-honesty.json"

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-CLI-HONESTY"* ]]
  assert_published_set_empty
}

@test "strict validators reject unknown missing and inconsistent fields" {
  use_fixture unchanged-existing
  cp "$TEST_ROOT/handoff.json" "$TEST_ROOT/invalid.json"
  mutate_json "$TEST_ROOT/invalid.json" '.unexpected = true'
  run "$SCRIPT" validate-handoff --file "$TEST_ROOT/invalid.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* || "$output" == *"unknown"* ]]

  cp "$FIXTURES/current-pin-resume/image-publication-receipt.json" \
    "$TEST_ROOT/invalid-image.json"
  mutate_json "$TEST_ROOT/invalid-image.json" 'del(.publication.job_id)'
  run "$SCRIPT" validate-image-receipt --file "$TEST_ROOT/invalid-image.json"
  [ "$status" -ne 0 ]

  cp "$TEST_ROOT/handoff.json" "$TEST_ROOT/invalid.json"
  mutate_json "$TEST_ROOT/invalid.json" \
    '.image.tag = "9999999999999999999999999999999999999999"'
  run "$SCRIPT" validate-handoff --file "$TEST_ROOT/invalid.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]
}

@test "validator rejects non-canonical bytes even when JSON values are valid" {
  use_fixture unchanged-existing
  jq -c . "$TEST_ROOT/handoff.json" >"$TEST_ROOT/noncanonical.json"

  run "$SCRIPT" validate-handoff --file "$TEST_ROOT/noncanonical.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]
}

@test "handoff publication converges on identical bytes and rejects conflicts" {
  use_fixture changed-success
  reconcile
  [ "$status" -eq 0 ]
  handoff=$(find "$TEST_ROOT/published" -name 'amaru-handoff-v1-*.json')
  before=$(sha256sum "$handoff")

  reconcile
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$handoff")" = "$before" ]

  printf '{"conflict":true}\n' >"$handoff"
  conflict=$(published_set_manifest)
  reconcile
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFLICT-RECEIPT"* ]]
  assert_published_set_unchanged "$conflict"
}

@test "equal pin with missing handoff resumes using current bootstrap and offline peer record" {
  use_fixture current-pin-resume

  reconcile

  [ "$status" -eq 0 ]
  grep -q '^read_bootstrap_sha 3333333333333333333333333333333333333333$' \
    "$TEST_ROOT/operations.log"
  grep -q '^read_peer_snapshot_record 5555555555555555555555555555555555555555 ' \
    "$TEST_ROOT/operations.log"
  ! grep -q '^resolve_peer_snapshots ' "$TEST_ROOT/operations.log"
  handoff=$(find "$TEST_ROOT/published" -name 'amaru-handoff-v1-*.json')
  jq -e '.bootstrap.sha == "3333333333333333333333333333333333333333"' \
    "$handoff"
}

@test "malformed transport SHA is rejected at its boundary" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" '.observed_sha = "not-a-sha"'

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve_upstream_head"* ]]
  assert_published_set_empty
  assert_no_mutation_operations
}

@test "failure output and receipts never contain credential values" {
  use_fixture changed-success
  rm "$TEST_ROOT/cli-honesty.json"
  export GH_TOKEN=fixture-secret-must-not-appear

  reconcile

  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED-CLI-HONESTY"* ]]
  [[ "$output" != *"fixture-secret-must-not-appear"* ]]
  assert_published_set_empty
  ! grep -R -q 'fixture-secret-must-not-appear' "$TEST_ROOT"
}

@test "publication-set assertions cover future receipt kinds" {
  use_fixture changed-success
  before=$(published_set_manifest)
  assert_published_set_empty

  printf '{"future":true}\n' >"$TEST_ROOT/published/future-receipt.json"

  run assert_published_set_empty
  [ "$status" -ne 0 ]
  run assert_published_set_unchanged "$before"
  [ "$status" -ne 0 ]
}

@test "no build or verify workflow invokes live peer snapshot resolver" {
  audit_no_live_resolver() {
    local found=0
    local workflow
    for workflow in "$@"; do
      if grep -q 'resolve-peer-snapshots' "$workflow"; then
        found=1
      fi
    done
    return "$found"
  }

  mapfile -d '' -t workflows < <(
    find "$REPO_ROOT/.github/workflows" -maxdepth 1 -xtype f \
      ! -name 'daily-amaru-handoff.yml' -print0 | sort -z
  )
  [ "${#workflows[@]}" -gt 1 ]
  audit_no_live_resolver "${workflows[@]}"

  mkdir "$BATS_TEST_TMPDIR/workflow-mutants"
  local index=0
  local workflow
  local -a mutants=()
  for workflow in "${workflows[@]}"; do
    mutants+=("$BATS_TEST_TMPDIR/workflow-mutants/$index.yml")
    cp "$workflow" "${mutants[$index]}"
    index=$((index + 1))
  done
  printf '\n# scripts/resolve-peer-snapshots --write\n' \
    >>"${mutants[0]}"
  run audit_no_live_resolver "${mutants[@]}"
  [ "$status" -ne 0 ]
}

@test "CI and just Build Gate check-name sets are identical" {
  extract_ci_build_gate_checks() {
    awk '
      /- name: Build all flake checks/ { in_gate = 1; next }
      in_gate && /^[[:space:]]+- name:/ { exit }
      in_gate { print }
    ' "$1" \
      | grep -oE '\.#checks\.x86_64-linux\.[A-Za-z0-9_-]+' \
      | sed 's/.*\.//' \
      | sort -u
  }

  extract_just_build_gate_checks() {
    awk '
      /^build-gate:/ { in_gate = 1; next }
      in_gate && /^[^[:space:]#]/ { exit }
      in_gate { print }
    ' "$1" \
      | grep -oE '\.#checks\.x86_64-linux\.[A-Za-z0-9_-]+' \
      | sed 's/.*\.//' \
      | sort -u
  }

  assert_build_gate_list_parity() {
    local ci_checks
    local just_checks
    ci_checks=$(extract_ci_build_gate_checks "$1")
    just_checks=$(extract_just_build_gate_checks "$2")
    [ -n "$ci_checks" ]
    [ -n "$just_checks" ]
    [ "$ci_checks" = "$just_checks" ]
  }

  assert_build_gate_list_parity \
    "$REPO_ROOT/.github/workflows/ci.yml" "$REPO_ROOT/justfile"

  sed '/daily-amaru-handoff/d' "$REPO_ROOT/.github/workflows/ci.yml" \
    >"$BATS_TEST_TMPDIR/ci-list-mutant.yml"
  run assert_build_gate_list_parity \
    "$BATS_TEST_TMPDIR/ci-list-mutant.yml" "$REPO_ROOT/justfile"
  [ "$status" -ne 0 ]

  sed '/daily-amaru-handoff/d' "$REPO_ROOT/justfile" \
    >"$BATS_TEST_TMPDIR/just-list-mutant"
  run assert_build_gate_list_parity \
    "$REPO_ROOT/.github/workflows/ci.yml" "$BATS_TEST_TMPDIR/just-list-mutant"
  [ "$status" -ne 0 ]
}
