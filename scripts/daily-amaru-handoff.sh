#!/usr/bin/env bash
set -euo pipefail

readonly UPSTREAM_REPOSITORY=https://github.com/pragma-org/amaru
readonly UPSTREAM_REF=refs/heads/main
readonly GH_REPOSITORY=lambdasistemi/amaru-bootstrap
readonly IMAGE_REPOSITORY=ghcr.io/lambdasistemi/amaru-bootstrap-producer

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
contract_root=$repo_root/specs/075-daily-amaru-handoff/contracts
transport=
fixture_root=
work_dir=

die() {
  local class="$1"
  shift
  printf '%s: %s\n' "$class" "$*" >&2
  exit 1
}

actions_gh() {
  local token=${ACTIONS_TOKEN:-${GH_TOKEN:-}}
  [[ -n "$token" ]] || die authentication "Actions read token is unavailable"
  GH_TOKEN=$token gh "$@"
}

usage() {
  cat >&2 <<'EOF'
usage:
  daily-amaru-handoff.sh reconcile --observation-day DAY --transport production|fixture [--fixture-root DIR]
  daily-amaru-handoff.sh propose [--branch-ref REF] --transport production|fixture [--fixture-root DIR]
  daily-amaru-handoff.sh observe-pr-checks --pr-number NUMBER --transport production|fixture [--fixture-root DIR]
  daily-amaru-handoff.sh verify-branch-ownership --file FILE --branch REF
  daily-amaru-handoff.sh validate-handoff --file FILE
  daily-amaru-handoff.sh validate-daily-result --file FILE
  daily-amaru-handoff.sh validate-image-receipt --file FILE
EOF
  exit 64
}

require_sha() {
  local operation="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] \
    || die "transport-$operation" "invalid Sha40 result"
}

require_digest() {
  local operation="$1"
  local value="$2"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "transport-$operation" "invalid Digest result"
}

require_day() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || die usage "invalid observation day"
  [[ "$(date --utc --date="$value" '+%Y-%m-%d' 2>/dev/null || true)" == "$value" ]] \
    || die usage "invalid UTC calendar day"
}

canonical_json() {
  local file="$1"
  local canonical=$work_dir/canonical.json
  jq -S . "$file" >"$canonical" \
    || die validation "invalid JSON: $file"
  cmp -s "$file" "$canonical" \
    || die validation "canonical JSON required: $file"
}

schema_json() {
  local schema="$1"
  local file="$2"
  check-jsonschema --schemafile "$schema" "$file" >/dev/null \
    || die validation "schema validation failed: $file"
}

validate_ci_block() {
  local file="$1"
  canonical_json "$file"
  jq -e '
    type == "object"
    and (keys == ["conclusion", "event", "head_sha", "job_id",
                  "repository", "required_check", "run_attempt", "run_id",
                  "workflow"])
    and .repository == "lambdasistemi/amaru-bootstrap"
    and .workflow == "CI"
    and .event == "push"
    and .required_check == "Build Gate"
    and .conclusion == "success"
    and (.head_sha | test("^[0-9a-f]{40}$"))
    and (.run_id | type == "number" and . >= 1 and floor == .)
    and (.run_attempt | type == "number" and . >= 1 and floor == .)
    and (.job_id | type == "number" and . >= 1 and floor == .)
  ' "$file" >/dev/null \
    || die validation "CI evidence block is not strict"
}

validate_cli_block() {
  local file="$1"
  canonical_json "$file"
  jq -e '
    type == "object"
    and (keys == ["flake_check", "invocation_sha256", "job", "job_id",
                  "step", "workflow_blob_sha", "workflow_path"])
    and .flake_check == ".#checks.x86_64-linux.cli-mock-honesty"
    and .workflow_path == ".github/workflows/ci.yml"
    and .job == "Build Gate"
    and .step == "Build all flake checks"
    and (.workflow_blob_sha | test("^[0-9a-f]{40}$"))
    and (.invocation_sha256 | test("^sha256:[0-9a-f]{64}$"))
    and (.job_id | type == "number" and . >= 1 and floor == .)
  ' "$file" >/dev/null \
    || die validation "CLI honesty evidence block is not strict"
}

validate_image_receipt_file() {
  local file="$1"
  canonical_json "$file"
  schema_json "$contract_root/image-publication-v1.schema.json" "$file"
  jq -e --arg repository "$IMAGE_REPOSITORY" '
    .bootstrap_sha == .image.tag
    and .bootstrap_sha == .publication.head_sha
    and .image.reference
      == ($repository + ":" + .image.tag + "@" + .image.digest)
  ' "$file" >/dev/null \
    || die validation "image receipt identity mismatch"
}

validate_handoff_file() {
  local file="$1"
  canonical_json "$file"
  schema_json "$contract_root/handoff-v1.schema.json" "$file"
  jq -e --arg repository "$IMAGE_REPOSITORY" '
    .bootstrap.sha == .image.tag
    and .bootstrap.sha == .ci.head_sha
    and .bootstrap.sha == .publication.head_sha
    and .image.reference
      == ($repository + ":" + .image.tag + "@" + .image.digest)
    and .ci.job_id == .cli_honesty.job_id
  ' "$file" >/dev/null \
    || die validation "handoff identity mismatch"
}

validate_daily_result_file() {
  local file="$1"
  canonical_json "$file"
  schema_json "$contract_root/daily-result-v1.schema.json" "$file"
  jq -e '
    . as $root
    | if .result == "HANDOFF" then
      .handoff.asset_url
        == ("https://github.com/lambdasistemi/amaru-bootstrap/releases/download/"
            + .handoff.release_tag + "/handoff-v1.json")
      and (.handoff.release_tag
        | startswith("amaru-handoff-v1-" + $root.observed_sha + "-"))
    else true end
  ' "$file" >/dev/null \
    || die validation "daily result identity mismatch"
}

log_fixture_operation() {
  printf '%s\n' "$*" >>"$fixture_root/operations.log"
}

fixture_scenario() {
  jq -er "$1" "$fixture_root/scenario.json"
}

fixture_resolve_upstream_head() {
  local requested_repository="$1"
  local requested_ref="$2"
  local actual_repository actual_ref value
  actual_repository=$(fixture_scenario .upstream_repository)
  actual_ref=$(fixture_scenario .upstream_ref)
  if [[ "$requested_repository" != "$UPSTREAM_REPOSITORY" \
    || "$requested_ref" != "$UPSTREAM_REF" \
    || "$actual_repository" != "$UPSTREAM_REPOSITORY" \
    || "$actual_ref" != "$UPSTREAM_REF" ]]; then
    die BLOCKED-WRONG-ORIGIN "source must be bare pragma-org/amaru refs/heads/main"
  fi
  value=$(fixture_scenario .observed_sha)
  require_sha resolve_upstream_head "$value"
  log_fixture_operation "resolve_upstream_head $requested_repository $requested_ref $value"
  printf '%s\n' "$value"
}

fixture_read_pinned_sha() {
  local value
  value=$(fixture_scenario .pinned_sha)
  require_sha read_pinned_sha "$value"
  log_fixture_operation "read_pinned_sha $value"
  printf '%s\n' "$value"
}

fixture_read_bootstrap_sha() {
  local value
  value=$(fixture_scenario .bootstrap_sha)
  require_sha read_bootstrap_sha "$value"
  log_fixture_operation "read_bootstrap_sha $value"
  printf '%s\n' "$value"
}

fixture_find_handoff() {
  local upstream_sha="$1"
  local bootstrap_sha="$2"
  local key=amaru-handoff-v1-$upstream_sha-$bootstrap_sha
  local target
  local file=$fixture_root/published/$key.json
  if [[ -f "$file" ]]; then
    target=$bootstrap_sha
  else
    file=$fixture_root/handoff.json
    target=$(fixture_scenario '.handoff_target_sha // .bootstrap_sha')
  fi
  if [[ ! -f "$file" ]]; then
    log_fixture_operation "find_handoff $upstream_sha $bootstrap_sha absent"
    printf 'ABSENT\n'
    return
  fi
  if ! (validate_handoff_file "$file") >/dev/null 2>&1; then
    die CONFLICT-RECEIPT "existing handoff is invalid"
  fi
  [[ "$target" == "$bootstrap_sha" ]] \
    || die CONFLICT-RECEIPT "handoff release tag points to wrong commit"
  jq -e --arg upstream "$upstream_sha" --arg bootstrap "$bootstrap_sha" '
    .upstream.sha == $upstream and .bootstrap.sha == $bootstrap
  ' "$file" >/dev/null \
    || die CONFLICT-RECEIPT "handoff key points to a different identity"
  log_fixture_operation "find_handoff $upstream_sha $bootstrap_sha present"
  cat "$file"
}

fixture_find_daily_result() {
  local observation_day="$1"
  local file=$fixture_root/published/amaru-daily-v1-$observation_day.json
  if [[ ! -f "$file" ]]; then
    log_fixture_operation "find_daily_result $observation_day absent"
    printf 'ABSENT\n'
    return
  fi
  validate_daily_result_file "$file"
  log_fixture_operation "find_daily_result $observation_day present"
  cat "$file"
}

fixture_publish_immutable() {
  local key="$1"
  local bytes="$2"
  local destination=$fixture_root/published/$key.json
  local result
  mkdir -p "$fixture_root/published"
  if [[ ! -e "$destination" ]]; then
    cp "$bytes" "$destination"
    result=created
  elif cmp -s "$bytes" "$destination"; then
    result=identical
  else
    result=conflict
  fi
  log_fixture_operation "publish_immutable $key $result"
  printf '%s\n' "$result"
}

fixture_open_pull_request() {
  local branch_ref="$1"
  local expected value
  expected=$(fixture_scenario .branch_ref)
  [[ "$branch_ref" == "$expected" ]] \
    || die integration "unexpected fixture branch"
  value=$(fixture_scenario .pr_number)
  [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || die integration "invalid fixture PR number"
  log_fixture_operation "open_pull_request $branch_ref $value"
  printf '%s\n' "$value"
}

fixture_required_ci_evidence() {
  local sha="$1"
  local file=$fixture_root/ci.json
  local state
  if [[ ! -f "$file" ]]; then
    state=absent
  elif [[ "$(head -n 1 "$file")" =~ ^(absent|pending|failure)$ ]]; then
    state=$(head -n 1 "$file")
  else
    validate_ci_block "$file"
    jq -e --arg sha "$sha" '.head_sha == $sha' "$file" >/dev/null \
      || die BLOCKED-REQUIRED-CI "CI evidence names wrong SHA"
    state=success
  fi
  log_fixture_operation "required_ci_evidence $sha $state"
  if [[ "$state" == success ]]; then
    cat "$file"
  else
    printf '%s\n' "$state"
  fi
}

fixture_required_pr_checks() {
  local pr_number="$1"
  local expected state attempt_file=$work_dir/pr-check-attempt
  local attempts=0
  expected=$(fixture_scenario .pr_number)
  [[ "$pr_number" == "$expected" ]] \
    || die integration "unexpected fixture PR number"
  if [[ -f "$attempt_file" ]]; then
    attempts=$(<"$attempt_file")
  fi
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" >"$attempt_file"
  if [[ -f "$fixture_root/pr-check-observations.txt" ]]; then
    state=$(sed -n "${attempts}p" \
      "$fixture_root/pr-check-observations.txt")
  else
    state=
  fi
  [[ -n "$state" ]] || state=not-yet-reported
  log_fixture_operation "required_pr_checks $pr_number $state"
  case "$state" in
    not-yet-reported | pending | failure) printf '%s\n' "$state" ;;
    success)
      jq -S . "$fixture_root/pr-checks.json" \
        || die integration "invalid fixture PR check evidence"
      ;;
    *) die integration "invalid fixture PR check state: $state" ;;
  esac
}

fixture_integrated_sha() {
  local pr_number="$1"
  local expected value
  expected=$(fixture_scenario .pr_number)
  [[ "$pr_number" == "$expected" ]] \
    || die integration "unexpected fixture PR number"
  value=$(fixture_scenario .integrated_sha)
  require_sha integrated_sha "$value"
  log_fixture_operation "integrated_sha $pr_number $value"
  printf '%s\n' "$value"
}

fixture_image_publication_receipt() {
  local bootstrap_sha="$1"
  local file=$fixture_root/image-publication-receipt.json
  if [[ ! -f "$file" ]]; then
    log_fixture_operation "image_publication_receipt $bootstrap_sha absent"
    printf 'ABSENT\n'
    return
  fi
  validate_image_receipt_file "$file"
  jq -e --arg sha "$bootstrap_sha" '.bootstrap_sha == $sha' "$file" >/dev/null \
    || die BLOCKED-PUBLICATION "image receipt names wrong bootstrap SHA"
  log_fixture_operation "image_publication_receipt $bootstrap_sha present"
  cat "$file"
}

fixture_resolve_registry_digest() {
  local image_tag="$1"
  local value
  value=$(fixture_scenario '.registry_digest // "ABSENT"')
  if [[ "$value" == ABSENT ]]; then
    log_fixture_operation "resolve_registry_digest $image_tag absent"
    printf 'ABSENT\n'
    return
  fi
  require_digest resolve_registry_digest "$value"
  log_fixture_operation "resolve_registry_digest $image_tag $value"
  printf '%s\n' "$value"
}

fixture_cli_honesty_evidence() {
  local bootstrap_sha="$1"
  local file=$fixture_root/cli-honesty.json
  if [[ ! -f "$file" ]]; then
    log_fixture_operation "cli_honesty_evidence $bootstrap_sha absent"
    printf 'ABSENT\n'
    return
  fi
  validate_cli_block "$file"
  log_fixture_operation "cli_honesty_evidence $bootstrap_sha present"
  cat "$file"
}

select_proposal_branch_ref() {
  local observed_sha="$1"
  local requested_branch_ref="${2:-}"
  require_sha select_proposal_branch_ref "$observed_sha"
  if [[ -n "$requested_branch_ref" ]]; then
    [[ "$requested_branch_ref" =~ ^probe/daily-handoff-[1-9][0-9]*-[1-9][0-9]*$ ]] \
      || die integration "invalid probe branch"
    printf '%s\n' "$requested_branch_ref"
  else
    printf 'automation/amaru-%s\n' "$observed_sha"
  fi
}

verify_branch_ownership() {
  local file="$1"
  local branch_ref="$2"
  [[ -f "$file" ]] || return 1
  jq -e --arg branch "$branch_ref" '
    .created == true
    and .branch == $branch
    and (.head_sha | test("^[0-9a-f]{40}$"))
  ' "$file" >/dev/null
}

fixture_propose_pin() {
  local observed_sha="$1"
  local configurations_sha="$2"
  local requested_branch_ref="${3:-}"
  local expected_observed expected_configurations branch_ref
  expected_observed=$(fixture_scenario .observed_sha)
  expected_configurations=$(jq -er .configurations_sha \
    "$fixture_root/peer-resolution.json")
  [[ "$observed_sha" == "$expected_observed" \
    && "$configurations_sha" == "$expected_configurations" ]] \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "proposal identity drift"
  cmp -s \
    <(jq -S 'del(.nodes.amaru, .nodes."cardano-configurations")' \
      "$fixture_root/lock-before.json") \
    <(jq -S 'del(.nodes.amaru, .nodes."cardano-configurations")' \
      "$fixture_root/lock-after.json") \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "unrelated lock node moved"
  branch_ref=$(select_proposal_branch_ref "$observed_sha" \
    "$requested_branch_ref")
  if [[ -z "$requested_branch_ref" ]]; then
    [[ "$branch_ref" == "$(fixture_scenario .branch_ref)" ]] \
      || die integration "unexpected fixture branch"
  fi
  log_fixture_operation "propose_pin $observed_sha $configurations_sha $branch_ref"
  printf '%s\n' "$branch_ref"
}

fixture_resolve_peer_snapshots() {
  local amaru_sha="$1"
  local file=$fixture_root/peer-resolution.json
  local status configurations_sha resolution_sha256
  status=$(jq -er .status "$file" 2>/dev/null || printf failure)
  [[ "$status" == success ]] \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "fixture resolution failed"
  configurations_sha=$(jq -er .configurations_sha "$file")
  resolution_sha256=$(jq -er .resolution_sha256 "$file")
  require_sha resolve_peer_snapshots "$configurations_sha"
  require_digest resolve_peer_snapshots "$resolution_sha256"
  log_fixture_operation "resolve_peer_snapshots $amaru_sha $configurations_sha $resolution_sha256"
  jq -cn --arg configurations_sha "$configurations_sha" \
    --arg resolution_sha256 "$resolution_sha256" \
    '{configurations_sha: $configurations_sha,
      resolution_sha256: $resolution_sha256}'
}

fixture_read_peer_snapshot_record() {
  local file=$fixture_root/peer-record.json
  local configurations_sha resolution_sha256
  configurations_sha=$(jq -er .configurations_sha "$file")
  resolution_sha256=$(jq -er .resolution_sha256 "$file")
  require_sha read_peer_snapshot_record "$configurations_sha"
  require_digest read_peer_snapshot_record "$resolution_sha256"
  log_fixture_operation "read_peer_snapshot_record $configurations_sha $resolution_sha256"
  jq -cn --arg configurations_sha "$configurations_sha" \
    --arg resolution_sha256 "$resolution_sha256" \
    '{configurations_sha: $configurations_sha,
      resolution_sha256: $resolution_sha256}'
}

production_resolve_upstream_head() {
  local repository="$1"
  local ref="$2"
  local value
  [[ "$repository" == "$UPSTREAM_REPOSITORY" && "$ref" == "$UPSTREAM_REF" ]] \
    || die BLOCKED-WRONG-ORIGIN "source must be bare pragma-org/amaru refs/heads/main"
  value=$(git ls-remote --exit-code "$repository" "$ref" | awk 'NR == 1 {print $1}')
  require_sha resolve_upstream_head "$value"
  printf '%s\n' "$value"
}

production_read_pinned_sha() {
  local value
  value=$(jq -er '.nodes.amaru.locked.rev' "$repo_root/flake.lock")
  require_sha read_pinned_sha "$value"
  printf '%s\n' "$value"
}

production_read_bootstrap_sha() {
  local value
  value=$(git -C "$repo_root" rev-parse HEAD)
  require_sha read_bootstrap_sha "$value"
  printf '%s\n' "$value"
}

production_release_asset() {
  local key="$1"
  local asset="$2"
  local output="$3"
  local release asset_id error_file=$work_dir/release-error
  if ! release=$(gh api "repos/$GH_REPOSITORY/releases/tags/$key" \
    2>"$error_file"); then
    if grep -q 'HTTP 404' "$error_file"; then
      printf 'ABSENT\n'
      return
    fi
    die publication "cannot read release key: $key"
  fi
  asset_id=$(jq -er --arg asset "$asset" \
    '.assets[] | select(.name == $asset) | .id' <<<"$release" 2>/dev/null || true)
  [[ -n "$asset_id" ]] \
    || die CONFLICT-RECEIPT "release exists without expected asset: $key"
  gh api -H 'Accept: application/octet-stream' \
    "repos/$GH_REPOSITORY/releases/assets/$asset_id" >"$output"
  cat "$output"
}

production_find_handoff() {
  local upstream_sha="$1"
  local bootstrap_sha="$2"
  local key=amaru-handoff-v1-$upstream_sha-$bootstrap_sha
  local file=$work_dir/production-handoff.json
  local value tag_target
  value=$(production_release_asset "$key" handoff-v1.json "$file")
  [[ "$value" == ABSENT ]] && { printf 'ABSENT\n'; return; }
  tag_target=$(gh api "repos/$GH_REPOSITORY/git/ref/tags/$key" --jq .object.sha)
  [[ "$tag_target" == "$bootstrap_sha" ]] \
    || die CONFLICT-RECEIPT "handoff release tag points to wrong commit"
  if ! (validate_handoff_file "$file") >/dev/null 2>&1; then
    die CONFLICT-RECEIPT "existing handoff is invalid"
  fi
  jq -e --arg upstream "$upstream_sha" --arg bootstrap "$bootstrap_sha" '
    .upstream.sha == $upstream and .bootstrap.sha == $bootstrap
  ' "$file" >/dev/null \
    || die CONFLICT-RECEIPT "handoff identity differs from release key"
  cat "$file"
}

production_find_daily_result() {
  local observation_day="$1"
  local key=amaru-daily-v1-$observation_day
  local file=$work_dir/production-daily.json
  local value
  value=$(production_release_asset "$key" daily-result-v1.json "$file")
  [[ "$value" == ABSENT ]] && { printf 'ABSENT\n'; return; }
  validate_daily_result_file "$file"
  cat "$file"
}

production_publish_immutable() {
  local key="$1"
  local bytes="$2"
  local asset target existing tag_target error_file=$work_dir/release-error
  local release_state
  case "$key" in
    amaru-handoff-v1-*)
      asset='handoff-v1.json'
      target=${key##*-}
      ;;
    amaru-daily-v1-*)
      asset='daily-result-v1.json'
      if [[ "$(jq -r .result "$bytes")" == HANDOFF ]]; then
        target=$(jq -r '.handoff.release_tag | split("-")[-1]' "$bytes")
      else
        target=$(git -C "$repo_root" rev-parse HEAD)
      fi
      ;;
    *) die CONFLICT-RECEIPT "unsupported immutable key" ;;
  esac
  require_sha publish_immutable "$target"
  if gh api "repos/$GH_REPOSITORY/releases/tags/$key" \
    >"$work_dir/release.json" 2>"$error_file"; then
    release_state=present
  elif grep -q 'HTTP 404' "$error_file"; then
    release_state=absent
  else
    die publication "cannot inspect immutable release key: $key"
  fi
  if [[ "$release_state" == present ]]; then
    tag_target=$(gh api "repos/$GH_REPOSITORY/git/ref/tags/$key" --jq .object.sha)
    [[ "$tag_target" == "$target" ]] \
      || die CONFLICT-RECEIPT "release tag points to wrong commit: $key"
    existing=$work_dir/existing-$asset
    production_release_asset "$key" "$asset" "$existing" >/dev/null
    if cmp -s "$bytes" "$existing"; then
      printf 'identical\n'
    else
      printf 'conflict\n'
    fi
    return
  fi
  if ! gh release create "$key" --repo "$GH_REPOSITORY" --target "$target" \
    --title "$key" --notes 'Immutable Amaru automation receipt.'; then
    existing=$work_dir/raced-$asset
    if production_release_asset "$key" "$asset" "$existing" >/dev/null \
      && cmp -s "$bytes" "$existing"; then
      printf 'identical\n'
      return
    fi
    die CONFLICT-RECEIPT "release creation raced with different state: $key"
  fi
  if ! gh release upload "$key" "$bytes#$asset" --repo "$GH_REPOSITORY"; then
    existing=$work_dir/raced-$asset
    if production_release_asset "$key" "$asset" "$existing" >/dev/null \
      && cmp -s "$bytes" "$existing"; then
      printf 'identical\n'
      return
    fi
    die CONFLICT-RECEIPT "asset upload raced with different state: $key"
  fi
  printf 'created\n'
}

production_open_pull_request() {
  local branch_ref="$1"
  local pr_url
  pr_url=$(gh pr create --repo "$GH_REPOSITORY" --base main --head "$branch_ref" \
    --title 'build(ci): bump amaru through daily handoff' \
    --body 'Automated exact-SHA Amaru and peer-snapshot pin proposal.')
  gh pr view "$pr_url" --repo "$GH_REPOSITORY" --json number --jq .number
}

production_required_ci_evidence() {
  local sha="$1"
  local runs run run_id run_attempt conclusion jobs job
  runs=$(actions_gh api \
    "repos/$GH_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&per_page=20")
  run=$(jq -c '[.workflow_runs | sort_by(.run_number) | reverse | .[0]] | .[0] // empty' <<<"$runs")
  if [[ -z "$run" ]]; then
    printf 'absent\n'
    return
  fi
  conclusion=$(jq -r '.conclusion // empty' <<<"$run")
  if [[ -z "$conclusion" ]]; then
    printf 'pending\n'
    return
  elif [[ "$conclusion" != success ]]; then
    printf 'failure\n'
    return
  fi
  run_id=$(jq -r .id <<<"$run")
  run_attempt=$(jq -r .run_attempt <<<"$run")
  jobs=$(actions_gh api \
    "repos/$GH_REPOSITORY/actions/runs/$run_id/jobs?filter=latest")
  job=$(jq -c '[.jobs[] | select(.name == "Build Gate")][0] // empty' <<<"$jobs")
  [[ -n "$job" && "$(jq -r .conclusion <<<"$job")" == success ]] \
    || { printf 'failure\n'; return; }
  jq -S -n --arg sha "$sha" --argjson run_id "$run_id" \
    --argjson run_attempt "$run_attempt" \
    --argjson job_id "$(jq -r .id <<<"$job")" \
    '{conclusion: "success", event: "push", head_sha: $sha,
      job_id: $job_id, repository: "lambdasistemi/amaru-bootstrap",
      required_check: "Build Gate", run_attempt: $run_attempt,
      run_id: $run_id, workflow: "CI"}'
}

production_required_pr_checks() {
  local pr_number="$1"
  local output=$work_dir/pr-checks.json
  local error=$work_dir/pr-checks.error
  local rc
  set +e
  actions_gh pr checks "$pr_number" --repo "$GH_REPOSITORY" --required \
    --json bucket,name,state,workflow >"$output" 2>"$error"
  rc=$?
  set -e
  if grep -q "no checks reported" "$error"; then
    printf 'not-yet-reported\n'
    return
  fi
  if ! jq -e 'type == "array"' "$output" >/dev/null 2>&1; then
    printf 'transport-error\n'
    return
  fi
  if jq -e 'length == 0' "$output" >/dev/null; then
    printf 'not-yet-reported\n'
  elif jq -e 'any(.[]; .bucket == "fail" or .bucket == "cancel")' \
    "$output" >/dev/null; then
    printf 'failure\n'
  elif jq -e 'any(.[]; .bucket == "pending")' "$output" >/dev/null; then
    printf 'pending\n'
  elif [[ "$rc" -ne 0 ]]; then
    printf 'transport-error\n'
  else
    jq -S . "$output"
  fi
}

production_integrated_sha() {
  local pr_number="$1"
  local value
  await_observation required_pr_checks "$pr_number" >/dev/null
  gh pr merge "$pr_number" --repo "$GH_REPOSITORY" --rebase --delete-branch
  value=$(gh pr view "$pr_number" --repo "$GH_REPOSITORY" \
    --json mergeCommit --jq '.mergeCommit.oid')
  require_sha integrated_sha "$value"
  printf '%s\n' "$value"
}

production_image_publication_receipt() {
  local bootstrap_sha="$1"
  local run_id artifact file=$work_dir/image-publication-receipt.json
  run_id=$(actions_gh run list --repo "$GH_REPOSITORY" \
    --workflow publish-bootstrap-image.yml --commit "$bootstrap_sha" \
    --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [[ -n "$run_id" ]] || { printf 'ABSENT\n'; return; }
  artifact=image-publication-receipt-$bootstrap_sha
  actions_gh run download "$run_id" --repo "$GH_REPOSITORY" --name "$artifact" \
    --dir "$work_dir/image-receipt"
  cp "$work_dir/image-receipt/image-publication-v1.json" "$file"
  validate_image_receipt_file "$file"
  cat "$file"
}

production_resolve_registry_digest() {
  local image_tag="$1"
  local value
  value=$(skopeo inspect "docker://$IMAGE_REPOSITORY:$image_tag" \
    --format '{{.Digest}}' 2>/dev/null || true)
  [[ -n "$value" ]] || { printf 'ABSENT\n'; return; }
  require_digest resolve_registry_digest "$value"
  printf '%s\n' "$value"
}

production_cli_honesty_evidence() {
  local bootstrap_sha="$1"
  local ci_file=$repo_root/.github/workflows/ci.yml
  local workflow_blob invocation job_id
  workflow_blob=$(gh api "repos/$GH_REPOSITORY/contents/.github/workflows/ci.yml?ref=$bootstrap_sha" --jq .sha)
  require_sha cli_honesty_evidence "$workflow_blob"
  invocation=$(sed -n '/name: Build all flake checks/,/name: Materialize/p' "$ci_file" \
    | sha256sum | cut -d' ' -f1)
  job_id=$(production_required_ci_evidence "$bootstrap_sha" \
    | jq -er .job_id 2>/dev/null || true)
  [[ "$job_id" =~ ^[1-9][0-9]*$ ]] || { printf 'ABSENT\n'; return; }
  jq -S -n --arg workflow_blob "$workflow_blob" \
    --arg invocation "sha256:$invocation" --argjson job_id "$job_id" \
    '{flake_check: ".#checks.x86_64-linux.cli-mock-honesty",
      invocation_sha256: $invocation, job: "Build Gate", job_id: $job_id,
      step: "Build all flake checks", workflow_blob_sha: $workflow_blob,
      workflow_path: ".github/workflows/ci.yml"}'
}

replace_flake_revision() {
  local input="$1"
  local revision="$2"
  local file=$repo_root/flake.nix
  sed -E -i \
    "/^[[:space:]]*$input = \{/,/^[[:space:]]*\};/ s#(github:[^/]+/[^/]+/)[0-9a-f]{40}#\\1$revision#" \
    "$file"
}

production_resolve_peer_snapshots() {
  local amaru_sha="$1"
  local proposed_lock=$work_dir/proposed-flake.lock
  local record=$repo_root/nix/peer-snapshots/resolution.json
  local configurations_sha resolution_sha256
  require_sha resolve_peer_snapshots "$amaru_sha"
  cp "$repo_root/flake.lock" "$proposed_lock"
  nix flake lock "$repo_root" --output-lock-file "$proposed_lock" \
    --override-input amaru \
      "git+https://github.com/pragma-org/amaru?rev=$amaru_sha" >&2
  set +e
  FLAKE_LOCK="$proposed_lock" \
    "$repo_root/scripts/resolve-peer-snapshots" --write >&2
  set -e
  jq -e --arg amaru "$amaru_sha" '
    (keys == ["amaru_committer_date_utc", "amaru_rev", "configs_rev",
              "query_url", "resolved_at_utc", "snapshots"])
    and .amaru_rev == $amaru
    and (.configs_rev | test("^[0-9a-f]{40}$"))
    and (.snapshots | keys == ["mainnet", "preprod", "preview"])
    and ([.snapshots[].sha256]
      | all(test("^[0-9a-f]{64}$")))
  ' "$record" >/dev/null \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "discovery record is absent or incomplete"
  cp "$record" "$work_dir/discovery-resolution.json"
  configurations_sha=$(jq -er .configs_rev "$record")
  resolution_sha256=sha256:$(sha256sum "$record" | cut -d' ' -f1)
  jq -cn --arg configurations_sha "$configurations_sha" \
    --arg resolution_sha256 "$resolution_sha256" \
    '{configurations_sha: $configurations_sha,
      resolution_sha256: $resolution_sha256}'
}

production_propose_pin() {
  local observed_sha="$1"
  local configurations_sha="$2"
  local requested_branch_ref="${3:-}"
  local before=$work_dir/lock-before.json
  local branch_ref
  local ownership_file=${AMARU_BRANCH_OWNERSHIP_FILE:-}
  local head_sha
  branch_ref=$(select_proposal_branch_ref "$observed_sha" \
    "$requested_branch_ref")
  cp "$repo_root/flake.lock" "$before"
  replace_flake_revision amaru "$observed_sha"
  replace_flake_revision cardano-configurations "$configurations_sha"
  nix flake lock "$repo_root" \
    --override-input amaru "git+https://github.com/pragma-org/amaru?rev=$observed_sha" \
    --override-input cardano-configurations \
      "git+https://github.com/cardano-foundation/cardano-configurations?rev=$configurations_sha" \
    >&2
  cmp -s \
    <(jq -S 'del(.nodes.amaru, .nodes."cardano-configurations")' "$before") \
    <(jq -S 'del(.nodes.amaru, .nodes."cardano-configurations")' "$repo_root/flake.lock") \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "unrelated lock node moved"
  [[ "$(jq -r .nodes.amaru.locked.rev "$repo_root/flake.lock")" == "$observed_sha" \
    && "$(jq -r '.nodes."cardano-configurations".locked.rev' "$repo_root/flake.lock")" \
      == "$configurations_sha" ]] \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "lock revisions differ from resolution"
  "$repo_root/scripts/resolve-peer-snapshots" --write >&2 \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "verification resolver call failed"
  [[ -f "$work_dir/discovery-resolution.json" ]] \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "discovery record was not retained"
  cp "$work_dir/discovery-resolution.json" \
    "$repo_root/nix/peer-snapshots/resolution.json"
  nix build --quiet "$repo_root#checks.x86_64-linux.peer-snapshot-anchor" >&2 \
    || die BLOCKED-PEER-SNAPSHOT-RESOLUTION "offline anchor failed"
  git -C "$repo_root" switch -c "$branch_ref" >&2
  git -C "$repo_root" add flake.nix flake.lock nix/peer-snapshots/resolution.json
  git -C "$repo_root" commit --quiet \
    -m 'build(ci): bump amaru through daily updater' \
    -m 'Move the Amaru and rule-selected configurations pins together and retain the resolver evidence verified by the offline anchor.' \
    -m 'Tasks: T012, T020, T021, T022'
  git -C "$repo_root" push --quiet \
    --force-with-lease="refs/heads/$branch_ref:" origin \
    "HEAD:refs/heads/$branch_ref" >&2 \
    || die integration "proposal branch already exists or push failed"
  if [[ -n "$ownership_file" ]]; then
    head_sha=$(git -C "$repo_root" rev-parse HEAD)
    jq -S -n --arg branch "$branch_ref" --arg head_sha "$head_sha" '
      {branch: $branch, created: true, head_sha: $head_sha}
    ' >"$ownership_file.tmp"
    mv "$ownership_file.tmp" "$ownership_file"
  fi
  printf '%s\n' "$branch_ref"
}

production_read_peer_snapshot_record() {
  local record=$repo_root/nix/peer-snapshots/resolution.json
  local configurations_sha resolution_sha256
  configurations_sha=$(jq -er .configs_rev "$record")
  require_sha read_peer_snapshot_record "$configurations_sha"
  resolution_sha256=sha256:$(sha256sum "$record" | cut -d' ' -f1)
  jq -cn --arg configurations_sha "$configurations_sha" \
    --arg resolution_sha256 "$resolution_sha256" \
    '{configurations_sha: $configurations_sha,
      resolution_sha256: $resolution_sha256}'
}

transport_call() {
  local operation="$1"
  shift
  "${transport}_${operation}" "$@"
}

await_observation() {
  local operation="$1"
  local subject="$2"
  local attempts=0
  local interval=${AMARU_OBSERVATION_INTERVAL_SECONDS:-10}
  local attempt value state
  if [[ "$transport" != production ]]; then
    attempts=${AMARU_OBSERVATION_ATTEMPTS:-1}
  fi
  [[ "$attempts" =~ ^[0-9]+$ && "$interval" =~ ^[0-9]+$ ]] \
    || die usage "invalid observation window"
  for ((attempt = 1; ; attempt++)); do
    value=$(transport_call "$operation" "$subject")
    case "$value" in
      absent | not-yet-reported)
        state=not-yet-reported
        ;;
      pending)
        state=pending
        ;;
      transport-error)
        state='transport-error'
        ;;
      failure)
        die BLOCKED-REQUIRED-CI \
          "state=failure attempt=$attempt/$attempts subject=$subject"
        ;;
      *)
        printf '%s\n' "$value"
        return
        ;;
    esac
    printf 'OBSERVE subject=%s state=%s attempt=%s/%s\n' \
      "$subject" "$state" "$attempt" \
      "$([[ "$attempts" -eq 0 ]] && printf unbounded || printf '%s' "$attempts")" \
      >&2
    if ((attempts > 0 && attempt >= attempts)); then
      break
    fi
    sleep "$interval"
  done
  if [[ "$state" == not-yet-reported ]]; then
    die BLOCKED-REQUIRED-CI \
      "state=absent-after-observation attempts=$attempts subject=$subject"
  fi
  die BLOCKED-REQUIRED-CI \
    "state=pending-after-observation attempts=$attempts subject=$subject"
}

propose() {
  local observed_sha="$1"
  local pinned_sha="$2"
  local requested_branch_ref="${3:-}"
  proposal_resolution=$(transport_call resolve_peer_snapshots "$observed_sha")
  proposal_branch_ref=$(transport_call propose_pin "$observed_sha" \
    "$(jq -r .configurations_sha <<<"$proposal_resolution")" \
    "$requested_branch_ref")
  proposal_pr_number=$(transport_call open_pull_request "$proposal_branch_ref")
  [[ "$proposal_pr_number" =~ ^[1-9][0-9]*$ ]] \
    || die integration "invalid proposal PR number"
  proposal_observed_sha=$observed_sha
  proposal_pinned_sha=$pinned_sha
}

publish_or_fail() {
  local key="$1"
  local file="$2"
  local result
  result=$(transport_call publish_immutable "$key" "$file")
  case "$result" in
    created | identical) ;;
    conflict) die CONFLICT-RECEIPT "immutable key differs: $key" ;;
    *) die CONFLICT-RECEIPT "invalid publication result: $result" ;;
  esac
}

write_value_file() {
  local value="$1"
  local file="$2"
  printf '%s\n' "$value" >"$file"
}

build_and_publish_handoff() {
  local observation_day="$1"
  local observed_sha="$2"
  local pinned_sha="$3"
  local bootstrap_sha="$4"
  local peer_json="$5"
  local handoff_key=amaru-handoff-v1-$observed_sha-$bootstrap_sha
  local handoff_file=$work_dir/handoff-v1.json
  local existing ci image_receipt registry_digest cli
  local ci_file=$work_dir/ci.json
  local image_file=$work_dir/image.json
  local cli_file=$work_dir/cli.json
  local peer_file=$work_dir/peer.json
  local receipt_hash asset_hash daily_file daily_key

  existing=$(transport_call find_handoff "$observed_sha" "$bootstrap_sha")
  if [[ "$existing" != ABSENT ]]; then
    write_value_file "$existing" "$handoff_file"
    validate_handoff_file "$handoff_file"
  else
    ci=$(await_observation required_ci_evidence "$bootstrap_sha")
    write_value_file "$ci" "$ci_file"
    validate_ci_block "$ci_file"

    image_receipt=$(transport_call image_publication_receipt "$bootstrap_sha")
    [[ "$image_receipt" != ABSENT ]] \
      || die BLOCKED-PUBLICATION "receipt absent for $bootstrap_sha"
    write_value_file "$image_receipt" "$image_file"
    validate_image_receipt_file "$image_file"

    registry_digest=$(transport_call resolve_registry_digest "$bootstrap_sha")
    [[ "$registry_digest" != ABSENT ]] \
      || die BLOCKED-DIGEST "registry digest absent for $bootstrap_sha"
    [[ "$registry_digest" == "$(jq -r .image.digest "$image_file")" ]] \
      || die BLOCKED-DIGEST "registry and receipt digest differ"

    cli=$(transport_call cli_honesty_evidence "$bootstrap_sha")
    [[ "$cli" != ABSENT ]] \
      || die BLOCKED-CLI-HONESTY "evidence absent for $bootstrap_sha"
    write_value_file "$cli" "$cli_file"
    validate_cli_block "$cli_file"
    write_value_file "$peer_json" "$peer_file"
    receipt_hash=sha256:$(sha256sum "$image_file" | cut -d' ' -f1)

    jq -S -n --arg day "$observation_day" --arg upstream "$observed_sha" \
      --arg bootstrap "$bootstrap_sha" \
      --arg configurations "$(jq -r .configurations_sha "$peer_file")" \
      --arg resolution "$(jq -r .resolution_sha256 "$peer_file")" \
      --arg receipt_hash "$receipt_hash" \
      --slurpfile ci "$ci_file" --slurpfile receipt "$image_file" \
      --slurpfile cli "$cli_file" '
      {
        bootstrap: {
          repository: "https://github.com/lambdasistemi/amaru-bootstrap",
          sha: $bootstrap
        },
        ci: $ci[0],
        cli_honesty: $cli[0],
        image: $receipt[0].image,
        observation_day: $day,
        peer_snapshots: {
          configurations_repository: "https://github.com/cardano-foundation/cardano-configurations",
          configurations_sha: $configurations,
          resolution_sha256: $resolution
        },
        publication: ($receipt[0].publication + {
          receipt_sha256: $receipt_hash
        }),
        schema: "amaru-bootstrap-handoff/v1",
        upstream: {
          ref: "refs/heads/main",
          repository: "https://github.com/pragma-org/amaru",
          sha: $upstream
        }
      }' >"$handoff_file"
    validate_handoff_file "$handoff_file"
    publish_or_fail "$handoff_key" "$handoff_file"
  fi

  asset_hash=sha256:$(sha256sum "$handoff_file" | cut -d' ' -f1)
  daily_file=$work_dir/daily-result-v1.json
  jq -S -n --arg day "$observation_day" --arg observed "$observed_sha" \
    --arg pinned "$pinned_sha" --arg key "$handoff_key" \
    --arg asset_hash "$asset_hash" '
    {
      handoff: {
        asset_sha256: $asset_hash,
        asset_url: ("https://github.com/lambdasistemi/amaru-bootstrap/releases/download/"
          + $key + "/handoff-v1.json"),
        release_tag: $key
      },
      observation_day: $day,
      observed_sha: $observed,
      pinned_sha: $pinned,
      result: "HANDOFF",
      schema: "amaru-bootstrap-daily-result/v1"
    }' >"$daily_file"
  validate_daily_result_file "$daily_file"
  daily_key=amaru-daily-v1-$observation_day
  publish_or_fail "$daily_key" "$daily_file"
  printf 'HANDOFF upstream=%s bootstrap=%s key=%s\n' \
    "$observed_sha" "$bootstrap_sha" "$handoff_key"
}

reconcile() {
  local observation_day="$1"
  local observed_sha pinned_sha current_bootstrap handoff peer resolution
  local daily_file=$work_dir/daily-result-v1.json
  local daily_key=amaru-daily-v1-$observation_day
  local bootstrap_sha

  require_day "$observation_day"
  observed_sha=$(transport_call resolve_upstream_head \
    "$UPSTREAM_REPOSITORY" "$UPSTREAM_REF")
  pinned_sha=$(transport_call read_pinned_sha)
  current_bootstrap=$(transport_call read_bootstrap_sha)

  if [[ "$observed_sha" == "$pinned_sha" ]]; then
    handoff=$(transport_call find_handoff "$observed_sha" "$current_bootstrap")
    if [[ "$handoff" != ABSENT ]]; then
      write_value_file "$handoff" "$work_dir/existing-handoff.json"
      validate_handoff_file "$work_dir/existing-handoff.json"
      jq -S -n --arg day "$observation_day" --arg observed "$observed_sha" \
        --arg pinned "$pinned_sha" '
        {
          observation_day: $day,
          observed_sha: $observed,
          pinned_sha: $pinned,
          result: "UNCHANGED",
          schema: "amaru-bootstrap-daily-result/v1"
        }' >"$daily_file"
      validate_daily_result_file "$daily_file"
      publish_or_fail "$daily_key" "$daily_file"
      printf 'UNCHANGED upstream=%s bootstrap=%s\n' \
        "$observed_sha" "$current_bootstrap"
      return
    fi
    peer=$(transport_call read_peer_snapshot_record)
    build_and_publish_handoff "$observation_day" "$observed_sha" \
      "$pinned_sha" "$current_bootstrap" "$peer"
    return
  fi

  propose "$observed_sha" "$pinned_sha"
  resolution=$proposal_resolution
  bootstrap_sha=$(transport_call integrated_sha "$proposal_pr_number")
  build_and_publish_handoff "$observation_day" "$observed_sha" \
    "$pinned_sha" "$bootstrap_sha" "$resolution"
}

main() {
  local command=${1:-}
  local file=''
  local observation_day=''
  local pr_number=''
  local branch_ref=''
  local observed_sha pinned_sha
  shift || true
  work_dir=$(mktemp -d)
  trap 'rm -rf -- "$work_dir"' EXIT

  case "$command" in
    validate-handoff | validate-daily-result | validate-image-receipt)
      [[ "${1:-}" == --file && -n "${2:-}" && $# -eq 2 ]] || usage
      file=$2
      case "$command" in
        validate-handoff) validate_handoff_file "$file" ;;
        validate-daily-result) validate_daily_result_file "$file" ;;
        validate-image-receipt) validate_image_receipt_file "$file" ;;
      esac
      ;;
    reconcile)
      while (($#)); do
        case "$1" in
          --observation-day) observation_day=${2:-}; shift 2 ;;
          --transport) transport=${2:-}; shift 2 ;;
          --fixture-root) fixture_root=${2:-}; shift 2 ;;
          *) usage ;;
        esac
      done
      [[ -n "$observation_day" && "$transport" =~ ^(production|fixture)$ ]] \
        || usage
      if [[ "$transport" == fixture ]]; then
        [[ -n "$fixture_root" && -d "$fixture_root" ]] || usage
      elif [[ -n "$fixture_root" ]]; then
        usage
      fi
      reconcile "$observation_day"
      ;;
    propose)
      while (($#)); do
        case "$1" in
          --branch-ref) branch_ref=${2:-}; shift 2 ;;
          --transport) transport=${2:-}; shift 2 ;;
          --fixture-root) fixture_root=${2:-}; shift 2 ;;
          *) usage ;;
        esac
      done
      [[ "$transport" =~ ^(production|fixture)$ ]] || usage
      if [[ "$transport" == fixture ]]; then
        [[ -n "$fixture_root" && -d "$fixture_root" ]] || usage
      elif [[ -n "$fixture_root" ]]; then
        usage
      fi
      observed_sha=$(transport_call resolve_upstream_head \
        "$UPSTREAM_REPOSITORY" "$UPSTREAM_REF")
      pinned_sha=$(transport_call read_pinned_sha)
      [[ "$observed_sha" != "$pinned_sha" ]] \
        || die integration "no changed Amaru revision to propose"
      propose "$observed_sha" "$pinned_sha" "$branch_ref"
      printf 'PROPOSED upstream=%s pinned=%s branch=%s pr=%s\n' \
        "$proposal_observed_sha" "$proposal_pinned_sha" \
        "$proposal_branch_ref" "$proposal_pr_number"
      ;;
    observe-pr-checks)
      while (($#)); do
        case "$1" in
          --pr-number) pr_number=${2:-}; shift 2 ;;
          --transport) transport=${2:-}; shift 2 ;;
          --fixture-root) fixture_root=${2:-}; shift 2 ;;
          *) usage ;;
        esac
      done
      [[ "$pr_number" =~ ^[1-9][0-9]*$ \
        && "$transport" =~ ^(production|fixture)$ ]] || usage
      if [[ "$transport" == fixture ]]; then
        [[ -n "$fixture_root" && -d "$fixture_root" ]] || usage
      elif [[ -n "$fixture_root" ]]; then
        usage
      fi
      await_observation required_pr_checks "$pr_number"
      ;;
    verify-branch-ownership)
      local ownership_file=''
      while (($#)); do
        case "$1" in
          --file) ownership_file=${2:-}; shift 2 ;;
          --branch) branch_ref=${2:-}; shift 2 ;;
          *) usage ;;
        esac
      done
      [[ -n "$ownership_file" && -n "$branch_ref" ]] || usage
      verify_branch_ownership "$ownership_file" "$branch_ref"
      ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
