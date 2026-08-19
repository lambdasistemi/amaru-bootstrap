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

propose() {
  run "$SCRIPT" propose \
    --transport fixture \
    --fixture-root "$TEST_ROOT"
}

observe_pr_checks() {
  AMARU_OBSERVATION_ATTEMPTS=3 \
    AMARU_OBSERVATION_INTERVAL_SECONDS=0 \
    run "$SCRIPT" observe-pr-checks \
      --pr-number 75 \
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

probe_job() {
  sed -n '/^  app-event-probe:/,$p' "$1"
}

assert_probe_execution_identity() {
  local probe
  probe=$(probe_job "$1")
  [ "$(grep -Fc \
    '          branch="probe/daily-handoff-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"' \
    <<<"$probe")" -eq 1 ] || return 1
  [ "$(grep -Fc '          ref: ${{ github.event.pull_request.head.sha }}' \
    <<<"$probe")" -eq 1 ] || return 1
  [ "$(grep -Fc 'uses: actions/checkout@v4' \
    <<<"$probe")" -eq 1 ] || return 1
  [ "$(grep -Fc \
    '            -c scripts/daily-amaru-handoff.sh propose \' \
    <<<"$probe")" -eq 1 ] || return 1
  [ "$(grep -Fc '              --branch-ref "$branch" --transport production)' \
    <<<"$probe")" -eq 1 ] || return 1
  ! grep -Fq -- '--transport fixture' <<<"$probe" || return 1
}

assert_probe_cleanup_contract() {
  local probe close_line receipt_line ownership_line delete_line verify_line
  probe=$(probe_job "$1")
  grep -Fq 'sha256sum "$receipt_dir/probe-receipt-before-deletion.json"' \
    <<<"$probe" || return 1
  grep -Fq '[[ "$branch_query_status" -eq 2 ]]' <<<"$probe" || return 1
  grep -Fq 'and .mergedAt == null' \
    <<<"$(sed -n '/cleanup_pr=/,/cleanup-verification.json/p' <<<"$probe")" \
    || return 1
  grep -Fq 'ownership_receipt' <<<"$probe" || return 1
  [ "$(grep -Ec '^[[:space:]]+owned_branch=true$' \
    <<<"$probe")" -eq 2 ] || return 1
  [ "$(grep -Fc \
    'scripts/daily-amaru-handoff.sh verify-branch-ownership \' \
    <<<"$probe")" -eq 2 ] || return 1
  grep -Fq \
    'if [[ -n "$pr_number" && "$owned_branch" == true ]]; then' \
    <<<"$probe" || return 1
  grep -Fqx '          [[ "$owned_branch" == true ]]' \
    <<<"$probe" || return 1

  close_line=$(grep -n 'gh pr close ' <<<"$probe" | tail -n 1 | cut -d: -f1)
  receipt_line=$(grep -n 'probe-receipt-before-deletion.json' <<<"$probe" \
    | tail -n 1 | cut -d: -f1)
  ownership_line=$(grep -nF '          [[ "$owned_branch" == true ]]' \
    <<<"$probe" | cut -d: -f1)
  delete_line=$(grep -n 'git push origin --delete ' <<<"$probe" \
    | tail -n 1 | cut -d: -f1)
  verify_line=$(grep -n 'cleanup-verification.json' <<<"$probe" \
    | tail -n 1 | cut -d: -f1)
  [ "$close_line" -lt "$receipt_line" ] || return 1
  [ "$receipt_line" -lt "$delete_line" ] || return 1
  [ "$ownership_line" -lt "$delete_line" ] || return 1
  [ "$delete_line" -lt "$verify_line" ] || return 1
}

install_gh_checks_shim() {
  GH_SHIM_BIN="$BATS_TEST_TMPDIR/gh-checks-bin"
  mkdir -p "$GH_SHIM_BIN"
  cat >"$GH_SHIM_BIN/gh" <<'EOF'
set -euo pipefail
printf '%s\n' "$*" >>"$GH_SHIM_LOG"
[[ "${1:-}" == pr && "${2:-}" == checks ]] || exit 90
attempt=0
if [[ -f "$GH_SHIM_ATTEMPT_FILE" ]]; then
  read -r attempt <"$GH_SHIM_ATTEMPT_FILE"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$GH_SHIM_ATTEMPT_FILE"
outcome=$(sed -n "${attempt}p" "$GH_SHIM_SEQUENCE_FILE")
case "$outcome" in
  empty)
    printf '[]\n'
    ;;
  pending)
    printf '[{"bucket":"pending","name":"Build Gate","state":"IN_PROGRESS","workflow":"CI"}]\n'
    ;;
  failure)
    printf '[{"bucket":"fail","name":"Build Gate","state":"FAILURE","workflow":"CI"}]\n'
    exit 1
    ;;
  malformed)
    printf '<html>upstream 502</html>\n'
    ;;
  nonzero-valid)
    printf '[{"bucket":"pass","name":"Build Gate","state":"SUCCESS","workflow":"CI"}]\n'
    exit 1
    ;;
  success)
    printf '[{"bucket":"pass","name":"Build Gate","state":"SUCCESS","workflow":"CI"}]\n'
    ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$GH_SHIM_BIN/gh"
  cat >"$GH_SHIM_BIN/sleep" <<'EOF'
set -euo pipefail
printf '%s\n' "$*" >>"$SLEEP_SHIM_LOG"
EOF
  chmod +x "$GH_SHIM_BIN/sleep"
}

make_propose_process_harness() {
  local root="$1"
  local pinned=2222222222222222222222222222222222222222
  local configurations=5555555555555555555555555555555555555555
  mkdir -p "$root/scripts" "$root/nix/peer-snapshots" "$root/bin"
  cp "$SCRIPT" "$root/scripts/daily-amaru-handoff.sh"
  cat >"$root/flake.nix" <<EOF
{
  inputs = {
    amaru = {
      url = "github:pragma-org/amaru/$pinned";
    };
    cardano-configurations = {
      url = "github:cardano-foundation/cardano-configurations/$configurations";
    };
  };
}
EOF
  cat >"$root/flake.lock" <<EOF
{
  "nodes": {
    "amaru": {"locked": {"rev": "$pinned"}},
    "cardano-configurations": {"locked": {"rev": "$configurations"}},
    "root": {"inputs": {"amaru": "amaru", "cardano-configurations": "cardano-configurations"}}
  },
  "root": "root",
  "version": 7
}
EOF
  cat >"$root/nix/peer-snapshots/resolution.json" <<EOF
{
  "amaru_committer_date_utc": "2026-08-19T00:00:00Z",
  "amaru_rev": "1111111111111111111111111111111111111111",
  "configs_rev": "$configurations",
  "query_url": "https://example.invalid/query",
  "resolved_at_utc": "2026-08-19T00:00:00Z",
  "snapshots": {
    "mainnet": {"sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    "preprod": {"sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "preview": {"sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
  }
}
EOF
  cat >"$root/scripts/resolve-peer-snapshots" <<'EOF'
set -euo pipefail
[[ "${1:-}" == --write ]]
EOF
  chmod +x "$root/scripts/resolve-peer-snapshots"
  cat >"$root/bin/nix" <<'EOF'
set -euo pipefail
printf 'nix' >>"$PROCESS_SHIM_LOG"
printf ' %q' "$@" >>"$PROCESS_SHIM_LOG"
printf '\n' >>"$PROCESS_SHIM_LOG"
if [[ "${1:-}" == build ]]; then
  exit 0
fi
[[ "${1:-}" == flake && "${2:-}" == lock ]]
repo=$3
shift 3
target="$repo/flake.lock"
amaru=
configurations=
while (($#)); do
  case "$1" in
    --output-lock-file) target=$2; shift 2 ;;
    git+https://github.com/pragma-org/amaru\?rev=*) amaru=${1##*=}; shift ;;
    git+https://github.com/cardano-foundation/cardano-configurations\?rev=*)
      configurations=${1##*=}; shift ;;
    *) shift ;;
  esac
done
if [[ -n "$amaru" ]]; then
  jq --arg rev "$amaru" '.nodes.amaru.locked.rev = $rev' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
fi
if [[ -n "$configurations" ]]; then
  jq --arg rev "$configurations" \
    '.nodes."cardano-configurations".locked.rev = $rev' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
fi
EOF
  cat >"$root/bin/git" <<'EOF'
set -euo pipefail
printf 'git' >>"$PROCESS_SHIM_LOG"
printf ' %q' "$@" >>"$PROCESS_SHIM_LOG"
printf '\n' >>"$PROCESS_SHIM_LOG"
if [[ "${1:-}" == ls-remote ]]; then
  printf '1111111111111111111111111111111111111111\trefs/heads/main\n'
  exit 0
fi
[[ "${1:-}" == -C ]]
case "${3:-}" in
  switch | add | commit) exit 0 ;;
  push)
    if [[ "${PROCESS_SHIM_PUSH_RESULT:-success}" == reject ]]; then
      printf '! [rejected] HEAD -> %s (stale info)\n' "${*: -1}" >&2
      exit 1
    fi
    ;;
  rev-parse)
    printf '%s\n' \
      "${PROCESS_SHIM_HEAD_SHA:-4444444444444444444444444444444444444444}"
    ;;
  *) exit 92 ;;
esac
EOF
  cat >"$root/bin/gh" <<'EOF'
set -euo pipefail
printf 'gh' >>"$PROCESS_SHIM_LOG"
printf ' %q' "$@" >>"$PROCESS_SHIM_LOG"
printf '\n' >>"$PROCESS_SHIM_LOG"
if [[ "${1:-}" == pr && "${2:-}" == create ]]; then
  printf 'https://example.invalid/pull/75\n'
elif [[ "${1:-}" == pr && "${2:-}" == view ]]; then
  printf '75\n'
else
  exit 93
fi
EOF
  chmod +x "$root/bin/nix" "$root/bin/git" "$root/bin/gh"
}

run_proposal_case() {
  local implementation="$1"
  local variant="$2"
  local root="$3"
  (
    # shellcheck source=/dev/null
    source "$SCRIPT"
    transport=fixture
    fixture_root="$root"
    work_dir="$root/work"
    mkdir -p "$work_dir"
    if [[ "$variant" == invalid-pr ]]; then
      fixture_open_pull_request() {
        log_fixture_operation "open_pull_request $1 0"
        printf '0\n'
      }
    fi
    if [[ "$implementation" == reference ]]; then
      proposal_resolution=$(transport_call resolve_peer_snapshots \
        1111111111111111111111111111111111111111)
      proposal_branch_ref=$(transport_call propose_pin \
        1111111111111111111111111111111111111111 \
        "$(jq -r .configurations_sha <<<"$proposal_resolution")" '')
      proposal_pr_number=$(transport_call open_pull_request \
        "$proposal_branch_ref")
      [[ "$proposal_pr_number" =~ ^[1-9][0-9]*$ ]] \
        || die integration "invalid proposal PR number"
      proposal_observed_sha=1111111111111111111111111111111111111111
      proposal_pinned_sha=2222222222222222222222222222222222222222
    else
      propose \
        1111111111111111111111111111111111111111 \
        2222222222222222222222222222222222222222 ''
    fi
    jq -cn --argjson resolution "$proposal_resolution" \
      --arg branch "$proposal_branch_ref" \
      --arg pr "$proposal_pr_number" \
      --arg observed "$proposal_observed_sha" \
      --arg pinned "$proposal_pinned_sha" \
      '{branch: $branch, observed: $observed, pinned: $pinned,
        pr: $pr, resolution: $resolution}'
  ) >"$root/result" 2>"$root/error"
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

@test "propose opens the real bump PR and halts before landing" {
  use_fixture changed-success

  propose

  [ "$status" -eq 0 ]
  [[ "$output" == *"PROPOSED upstream=1111111111111111111111111111111111111111"* ]]
  [[ "$output" == *"branch=automation/amaru-1111111111111111111111111111111111111111"* ]]
  [[ "$output" == *"pr=75"* ]]
  [ "$(grep -Ec '^(resolve_peer_snapshots|propose_pin|open_pull_request) ' \
    "$TEST_ROOT/operations.log")" -eq 3 ]
  ! grep -Eq '^(integrated_sha|publish_immutable) ' \
    "$TEST_ROOT/operations.log"
}

@test "proposal boundary matches the straight-line reference across results" {
  local variant actual reference actual_status reference_status
  for variant in success alternate-pr invalid-pr; do
    actual="$BATS_TEST_TMPDIR/proposal-$variant-actual"
    reference="$BATS_TEST_TMPDIR/proposal-$variant-reference"
    cp -R "$FIXTURES/changed-success" "$actual"
    cp -R "$FIXTURES/changed-success" "$reference"
    if [[ "$variant" == alternate-pr ]]; then
      mutate_json "$actual/scenario.json" '.pr_number = 91'
      mutate_json "$reference/scenario.json" '.pr_number = 91'
    fi
    run run_proposal_case candidate "$variant" "$actual"
    actual_status=$status
    run run_proposal_case reference "$variant" "$reference"
    reference_status=$status

    [ "$actual_status" -eq "$reference_status" ]
    cmp -s "$actual/result" "$reference/result"
    cmp -s "$actual/error" "$reference/error"
    cmp -s "$actual/operations.log" "$reference/operations.log"
  done
}

@test "changed reconcile reaches proposal boundary and lands its returned PR" {
  use_fixture changed-success
  mutate_json "$TEST_ROOT/scenario.json" '.pr_number = 91'

  run bash -c '
    source "$1"
    transport=fixture
    fixture_root="$2"
    work_dir="$2/work"
    mkdir -p "$work_dir"
    eval "$(declare -f propose | sed "1s/^propose/original_propose/")"
    propose() {
      printf "called\n" >"$fixture_root/propose-called"
      original_propose "$@"
    }
    reconcile 2026-08-19
  ' _ "$SCRIPT" "$TEST_ROOT"

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/propose-called" ]
  grep -q '^integrated_sha 91 4444444444444444444444444444444444444444$' \
    "$TEST_ROOT/operations.log"
}

@test "observer retries not-yet-reported checks before accepting evidence" {
  use_fixture changed-success
  printf '%s\n' not-yet-reported pending success \
    >"$TEST_ROOT/pr-check-observations.txt"
  cat >"$TEST_ROOT/pr-checks.json" <<'EOF'
[{"bucket":"pass","name":"Build Gate","state":"SUCCESS","workflow":"CI"}]
EOF

  observe_pr_checks

  [ "$status" -eq 0 ]
  [[ "$output" == *'"name": "Build Gate"'* ]]
  grep -q '^required_pr_checks 75 not-yet-reported$' \
    "$TEST_ROOT/operations.log"
  grep -q '^required_pr_checks 75 pending$' "$TEST_ROOT/operations.log"
  grep -q '^required_pr_checks 75 success$' "$TEST_ROOT/operations.log"
}

@test "observer reports absence only after the observation window" {
  use_fixture changed-success
  printf '%s\n' not-yet-reported not-yet-reported not-yet-reported \
    >"$TEST_ROOT/pr-check-observations.txt"

  observe_pr_checks

  [ "$status" -ne 0 ]
  [[ "$output" == *"state=not-yet-reported attempt=1/3"* ]]
  [[ "$output" == *"state=absent-after-observation attempts=3"* ]]
}

@test "production observation retries every non-verdict without a ceiling" {
  local root="$BATS_TEST_TMPDIR/production-observation"
  mkdir -p "$root"
  install_gh_checks_shim
  printf '%s\n' empty pending malformed nonzero-valid success \
    >"$root/sequence"

  ACTIONS_TOKEN=fixture-actions-token \
    GH_SHIM_SEQUENCE_FILE="$root/sequence" \
    GH_SHIM_ATTEMPT_FILE="$root/attempt" \
    GH_SHIM_LOG="$root/gh.log" \
    SLEEP_SHIM_LOG="$root/sleep.log" \
    PATH="$GH_SHIM_BIN:$PATH" \
    AMARU_OBSERVATION_INTERVAL_SECONDS=0 \
    run "$SCRIPT" observe-pr-checks \
      --pr-number 75 --transport production

  [ "$status" -eq 0 ]
  [[ "$output" == *'state=not-yet-reported attempt=1/unbounded'* ]]
  [[ "$output" == *'state=pending attempt=2/unbounded'* ]]
  [[ "$output" == *'state=transport-error attempt=3/unbounded'* ]]
  [[ "$output" == *'state=transport-error attempt=4/unbounded'* ]]
  [[ "$output" == *'"bucket": "pass"'* ]]
  [ "$(wc -l <"$root/gh.log")" -eq 5 ]
  [ "$(wc -l <"$root/sleep.log")" -eq 4 ]
  grep -Fq 'pr checks 75 --repo lambdasistemi/amaru-bootstrap --required --json bucket,name,state,workflow' \
    "$root/gh.log"
}

@test "only a reported check failure terminates observation" {
  local root="$BATS_TEST_TMPDIR/reported-failure"
  mkdir -p "$root"
  install_gh_checks_shim
  printf '%s\n' failure success >"$root/sequence"

  ACTIONS_TOKEN=fixture-actions-token \
    GH_SHIM_SEQUENCE_FILE="$root/sequence" \
    GH_SHIM_ATTEMPT_FILE="$root/attempt" \
    GH_SHIM_LOG="$root/gh.log" \
    PATH="$GH_SHIM_BIN:$PATH" \
    AMARU_OBSERVATION_INTERVAL_SECONDS=0 \
    run "$SCRIPT" observe-pr-checks \
      --pr-number 75 --transport production

  [ "$status" -ne 0 ]
  [[ "$output" == *"state=failure attempt=1"* ]]
  [ "$(wc -l <"$root/gh.log")" -eq 1 ]
}

@test "production landing reaches the retrying observer before merge" {
  landing=$(sed -n '/^production_integrated_sha()/,/^}/p' "$SCRIPT")

  [[ "$landing" == *'await_observation required_pr_checks "$pr_number"'* ]]
  [[ "$landing" != *'gh pr checks'* ]]
  [[ "$landing" == *'gh pr merge'* ]]
}

@test "App probe uses propose and freezes verified close-by-design cleanup" {
  local workflow="$REPO_ROOT/.github/workflows/daily-amaru-handoff.yml"
  local probe
  probe=$(sed -n '/^  app-event-probe:/,$p' "$workflow")

  assert_probe_execution_identity "$workflow"
  assert_probe_cleanup_contract "$workflow"
  [[ "$probe" == *'scripts/daily-amaru-handoff.sh propose'* ]]
  [[ "$probe" == *'scripts/daily-amaru-handoff.sh observe-pr-checks'* ]]
  [[ "$probe" != *'--allow-empty'* ]]
  [[ "$probe" == *'proof run closed by design'* ]]
  [[ "$probe" == *'probe-receipt-before-deletion.json'* ]]
  [[ "$probe" == *'cleanup-verification.json'* ]]
  [[ "$probe" != *'|| true'* ]]

  cp "$workflow" "$BATS_TEST_TMPDIR/probe-mutant.yml"
  sed -i 's/ref: \${{ github.event.pull_request.head.sha }}/ref: main/' \
    "$BATS_TEST_TMPDIR/probe-mutant.yml"
  run assert_probe_execution_identity "$BATS_TEST_TMPDIR/probe-mutant.yml"
  [ "$status" -ne 0 ]

  cp "$workflow" "$BATS_TEST_TMPDIR/probe-mutant.yml"
  sed -i \
    's|branch="probe/daily-handoff-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"|branch="automation/amaru-${GITHUB_SHA}"|' \
    "$BATS_TEST_TMPDIR/probe-mutant.yml"
  run assert_probe_execution_identity "$BATS_TEST_TMPDIR/probe-mutant.yml"
  [ "$status" -ne 0 ]

  cp "$workflow" "$BATS_TEST_TMPDIR/probe-mutant.yml"
  sed -i 's/--transport production/--transport fixture/' \
    "$BATS_TEST_TMPDIR/probe-mutant.yml"
  run assert_probe_execution_identity "$BATS_TEST_TMPDIR/probe-mutant.yml"
  [ "$status" -ne 0 ]

  local guard
  for guard in branch-query pr-state receipt-hash fallback-ownership \
    ownership ownership-verifier; do
    cp "$workflow" "$BATS_TEST_TMPDIR/probe-mutant.yml"
    case "$guard" in
      branch-query)
        sed -i '/\[\[ "$branch_query_status" -eq 2 \]\]/d' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
      pr-state)
        sed -i '/and \.mergedAt == null/d' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
      receipt-hash)
        sed -i '/sha256sum "$receipt_dir\/probe-receipt-before-deletion.json"/,+1d' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
      fallback-ownership)
        sed -i \
          's/if \[\[ -n "$pr_number" && "$owned_branch" == true \]\]; then/if [[ -n "$pr_number" ]]; then/' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
      ownership)
        sed -i '/^          \[\[ "$owned_branch" == true \]\]/d' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
      ownership-verifier)
        sed -i '/scripts\/daily-amaru-handoff.sh verify-branch-ownership/,+1d' \
          "$BATS_TEST_TMPDIR/probe-mutant.yml"
        ;;
    esac
    run assert_probe_cleanup_contract "$BATS_TEST_TMPDIR/probe-mutant.yml"
    [ "$status" -ne 0 ]
  done
}

@test "probe and daily proposal branches are disjoint by construction" {
  local observed=1111111111111111111111111111111111111111

  run bash -c 'source "$1"; select_proposal_branch_ref "$2"' \
    _ "$SCRIPT" "$observed"
  [ "$status" -eq 0 ]
  [ "$output" = "automation/amaru-$observed" ]

  run bash -c 'source "$1"; select_proposal_branch_ref "$2" "$3"' \
    _ "$SCRIPT" "$observed" probe/daily-handoff-123-1
  [ "$status" -eq 0 ]
  [ "$output" = probe/daily-handoff-123-1 ]

  run bash -c 'source "$1"; select_proposal_branch_ref "$2" "$3"' \
    _ "$SCRIPT" "$observed" "automation/amaru-$observed"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid probe branch"* ]]
}

@test "production propose carries branch lease and ownership through process boundaries" {
  local root="$BATS_TEST_TMPDIR/production-probe"
  local branch=probe/daily-handoff-123-1
  local head=7777777777777777777777777777777777777777
  make_propose_process_harness "$root"

  GH_TOKEN=fixture-app-token \
    PROCESS_SHIM_LOG="$root/process.log" \
    PROCESS_SHIM_HEAD_SHA="$head" \
    AMARU_BRANCH_OWNERSHIP_FILE="$root/ownership.json" \
    PATH="$root/bin:$PATH" \
    run "$root/scripts/daily-amaru-handoff.sh" propose \
      --branch-ref "$branch" --transport production

  [ "$status" -eq 0 ]
  [[ "$output" == *"branch=$branch pr=75"* ]]
  grep -Fq -- \
    "--force-with-lease=refs/heads/$branch: origin HEAD:refs/heads/$branch" \
    "$root/process.log"
  grep -Fq -- "--base main --head $branch" "$root/process.log"
  jq -e --arg branch "$branch" --arg head "$head" '
    .created == true
    and .branch == $branch
    and .head_sha == $head
  ' "$root/ownership.json"

  run "$root/scripts/daily-amaru-handoff.sh" verify-branch-ownership \
    --file "$root/ownership.json" --branch "$branch"
  [ "$status" -eq 0 ]
  run "$root/scripts/daily-amaru-handoff.sh" verify-branch-ownership \
    --file "$root/ownership.json" --branch probe/daily-handoff-999-1
  [ "$status" -ne 0 ]

  root="$BATS_TEST_TMPDIR/production-daily"
  make_propose_process_harness "$root"
  GH_TOKEN=fixture-app-token \
    PROCESS_SHIM_LOG="$root/process.log" \
    AMARU_BRANCH_OWNERSHIP_FILE="$root/ownership.json" \
    PATH="$root/bin:$PATH" \
    run "$root/scripts/daily-amaru-handoff.sh" propose \
      --transport production

  [ "$status" -eq 0 ]
  [[ "$output" == *'branch=automation/amaru-1111111111111111111111111111111111111111'* ]]
  grep -Fq -- \
    '--force-with-lease=refs/heads/automation/amaru-1111111111111111111111111111111111111111:' \
    "$root/process.log"
}

@test "rejected leased push aborts before ownership receipt or pull request" {
  local root="$BATS_TEST_TMPDIR/rejected-lease"
  local branch=probe/daily-handoff-123-1
  make_propose_process_harness "$root"

  GH_TOKEN=fixture-app-token \
    PROCESS_SHIM_LOG="$root/process.log" \
    PROCESS_SHIM_PUSH_RESULT=reject \
    AMARU_BRANCH_OWNERSHIP_FILE="$root/ownership.json" \
    PATH="$root/bin:$PATH" \
    run "$root/scripts/daily-amaru-handoff.sh" propose \
      --branch-ref "$branch" --transport production

  [ "$status" -ne 0 ]
  [[ "$output" == *"proposal branch already exists or push failed"* ]]
  grep -Fq -- \
    "--force-with-lease=refs/heads/$branch: origin HEAD:refs/heads/$branch" \
    "$root/process.log"
  ! find "$root" -maxdepth 1 -name 'ownership.json*' -print -quit \
    | grep -q .
  ! grep -Fq 'gh pr create' "$root/process.log"
}

@test "ownership verifier rejects each invalid receipt field independently" {
  local root="$BATS_TEST_TMPDIR/ownership-fields"
  local branch=probe/daily-handoff-123-1
  mkdir -p "$root"
  jq -S -n --arg branch "$branch" '
    {branch: $branch, created: true,
      head_sha: "7777777777777777777777777777777777777777"}
  ' >"$root/ownership.json"

  run "$SCRIPT" verify-branch-ownership \
    --file "$root/ownership.json" --branch "$branch"
  [ "$status" -eq 0 ]

  mutate_json "$root/ownership.json" '.created = false'
  run "$SCRIPT" verify-branch-ownership \
    --file "$root/ownership.json" --branch "$branch"
  [ "$status" -ne 0 ]

  mutate_json "$root/ownership.json" \
    '.created = true | .head_sha = "not-a-sha"'
  run "$SCRIPT" verify-branch-ownership \
    --file "$root/ownership.json" --branch "$branch"
  [ "$status" -ne 0 ]
}

@test "ownership receipt cannot read the raw requested branch" {
  local root="$BATS_TEST_TMPDIR/raw-requested-branch"
  local branch=probe/daily-handoff-123-1
  make_propose_process_harness "$root"
  sed -i \
    '/--arg branch "$branch_ref" --arg head_sha/s/--arg branch "$branch_ref"/--arg branch "$requested_branch_ref"/' \
    "$root/scripts/daily-amaru-handoff.sh"
  grep -Fq -- '--arg branch "$requested_branch_ref"' \
    "$root/scripts/daily-amaru-handoff.sh"

  GH_TOKEN=fixture-app-token \
    PROCESS_SHIM_LOG="$root/process.log" \
    AMARU_BRANCH_OWNERSHIP_FILE="$root/ownership.json" \
    PATH="$root/bin:$PATH" \
    run "$root/scripts/daily-amaru-handoff.sh" propose \
      --branch-ref "$branch" --transport production

  [ "$status" -ne 0 ]
  [ ! -e "$root/ownership.json" ]
  ! grep -Fq 'gh pr create' "$root/process.log"
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
