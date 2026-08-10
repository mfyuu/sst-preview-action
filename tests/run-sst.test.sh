#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly plan_script="${repository_root}/scripts/plan-reconciliation.mjs"
readonly remove_reconciled_script="${repository_root}/scripts/remove-reconciled-stages.sh"
readonly script_under_test="${repository_root}/scripts/run-sst.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"

  grep -Fq "$expected" "$file" || fail "${file} does not contain: ${expected}"
}

run_action() {
  local temp_dir="$1"
  shift

  env \
    PATH="${temp_dir}/bin:${PATH}" \
    GITHUB_OUTPUT="${temp_dir}/github-output" \
    INPUT_CLEANUP_ON_DEPLOY_FAILURE="${INPUT_CLEANUP_ON_DEPLOY_FAILURE:-true}" \
    INPUT_OPERATION="${INPUT_OPERATION:-auto}" \
    INPUT_PR_NUMBER="${INPUT_PR_NUMBER-}" \
    INPUT_REMOVE_MAX_ATTEMPTS="${INPUT_REMOVE_MAX_ATTEMPTS:-3}" \
    INPUT_REMOVE_RETRY_DELAY_SECONDS="0" \
    INPUT_UNLOCK_ON_LOCK="${INPUT_UNLOCK_ON_LOCK:-true}" \
    INPUT_URL_OUTPUT_KEY="${INPUT_URL_OUTPUT_KEY-url}" \
    INPUT_VERIFY_REMOVAL="${INPUT_VERIFY_REMOVAL:-auto}" \
    PR_EVENT_ACTION="${PR_EVENT_ACTION:-opened}" \
    PR_EVENT_NAME="${PR_EVENT_NAME-pull_request}" \
    PR_NUMBER="${PR_NUMBER-123}" \
    RUNNER_TEMP="$temp_dir" \
    TEST_CALL_LOG="${temp_dir}/calls" \
    TEST_COUNTER_FILE="${temp_dir}/counter" \
    TEST_DEFAULT_PR_STATE="${TEST_DEFAULT_PR_STATE-}" \
    TEST_OUTPUTS_JSON="${TEST_OUTPUTS_JSON-}" \
    TEST_PR_STATE_FAILURE_NUMBER="${TEST_PR_STATE_FAILURE_NUMBER-}" \
    TEST_PR_STATES="${TEST_PR_STATES-}" \
    TEST_REAL_NODE="$(command -v node)" \
    TEST_STREAM_RELEASE_FILE="${temp_dir}/stream-release" \
    TEST_SCENARIO="$1" \
    bash -c 'cd "$1" && exec bash "$2"' _ "$temp_dir" "$script_under_test"
}

run_reconcile_action() {
  local candidates_file
  local plan_file
  local scenario="$2"
  local temp_dir="$1"

  if ! run_action "$temp_dir" "$scenario"; then
    return 1
  fi

  candidates_file="$(
    sed -n 's/^reconcile_candidates_file=//p' "${temp_dir}/github-output"
  )"
  if [[ -z "$candidates_file" ]]; then
    fail "reconciliation did not emit a candidates file"
  fi

  touch "${temp_dir}/reconcile-output"
  if ! env \
    PATH="${temp_dir}/bin:${PATH}" \
    GITHUB_OUTPUT="${temp_dir}/reconcile-output" \
    RECONCILE_CANDIDATES_FILE="$candidates_file" \
    RECONCILE_GITHUB_API_URL="https://api.github.test" \
    RECONCILE_GITHUB_REPOSITORY="owner/repository" \
    RECONCILE_GITHUB_TOKEN="test-token" \
    RUNNER_TEMP="$temp_dir" \
    TEST_CALL_LOG="${temp_dir}/calls" \
    TEST_COUNTER_FILE="${temp_dir}/counter" \
    TEST_DEFAULT_PR_STATE="${TEST_DEFAULT_PR_STATE-}" \
    TEST_PR_STATE_FAILURE_NUMBER="${TEST_PR_STATE_FAILURE_NUMBER-}" \
    TEST_PR_STATES="${TEST_PR_STATES-}" \
    TEST_REAL_NODE="$(command -v node)" \
    node "$plan_script"; then
    return 1
  fi

  plan_file="$(
    sed -n 's/^plan_file=//p' "${temp_dir}/reconcile-output"
  )"
  if [[ -z "$plan_file" ]]; then
    fail "reconciliation did not emit a plan file"
  fi

  env \
    PATH="${temp_dir}/bin:${PATH}" \
    GITHUB_OUTPUT="${temp_dir}/remove-output" \
    INPUT_REMOVE_MAX_ATTEMPTS="${INPUT_REMOVE_MAX_ATTEMPTS:-3}" \
    INPUT_REMOVE_RETRY_DELAY_SECONDS="0" \
    INPUT_UNLOCK_ON_LOCK="${INPUT_UNLOCK_ON_LOCK:-true}" \
    INPUT_VERIFY_REMOVAL="${INPUT_VERIFY_REMOVAL:-auto}" \
    RECONCILE_PLAN_FILE="$plan_file" \
    TEST_CALL_LOG="${temp_dir}/calls" \
    TEST_COUNTER_FILE="${temp_dir}/counter" \
    TEST_OUTPUTS_JSON="${TEST_OUTPUTS_JSON-}" \
    TEST_REAL_NODE="$(command -v node)" \
    TEST_SCENARIO="$scenario" \
    bash -c 'cd "$1" && exec bash "$2"' _ "$temp_dir" "$remove_reconciled_script"
}

make_temp_dir() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/bin"
  touch "${temp_dir}/calls" "${temp_dir}/github-output"

  cat >"${temp_dir}/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${RECONCILE_GITHUB_TOKEN:-}" ]]; then
  echo "GitHub token leaked to npx" >&2
  exit 98
fi

if [[ -r "/proc/${PPID}/environ" ]] &&
  tr '\0' '\n' <"/proc/${PPID}/environ" |
    grep -Fq 'RECONCILE_GITHUB_TOKEN=test-token'; then
  echo "GitHub token leaked through the parent process environment" >&2
  exit 98
fi

echo "$*" >>"$TEST_CALL_LOG"

case "${TEST_SCENARIO}:$1:$2" in
  deploy-success:sst:deploy)
    echo "✓ Complete"
    echo "https://abc123.cloudfront.net"
    ;;
  deploy-failure:sst:deploy)
    echo "deploy failed" >&2
    exit 1
    ;;
  deploy-stream:sst:deploy)
    echo "deploy started"
    while [[ ! -e "$TEST_STREAM_RELEASE_FILE" ]]; do
      sleep 0.01
    done
    echo "https://streamed.cloudfront.net"
    ;;
  deploy-named-output:sst:deploy)
    mkdir -p .sst
    printf '%s' "$TEST_OUTPUTS_JSON" >.sst/outputs.json
    echo "https://legacy.cloudfront.net"
    ;;
  deploy-no-url:sst:deploy)
    echo "✓ Complete"
    ;;
  deploy-failure:sst:remove)
    ;;
  deploy-failure:sst:state)
    printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    ;;
  remove-retry:sst:remove)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    count="$((count + 1))"
    echo "$count" >"$TEST_COUNTER_FILE"
    if [[ "$count" -eq 1 ]]; then
      exit 1
    fi
    ;;
  remove-retry:sst:state)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 1 ]]; then
      printf 'Stages: dev\n        %s\n' "$5"
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  stage-not-found:sst:remove)
    echo "Stage not found" >&2
    exit 1
    ;;
  stage-not-found:sst:state)
    printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    ;;
  remove-and-state-failure:sst:remove)
    echo "remove unavailable" >&2
    exit 1
    ;;
  remove-and-state-failure:sst:state)
    echo "state unavailable" >&2
    exit 1
    ;;
  verify-retry:sst:remove)
    ;;
  verify-retry:sst:state)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    count="$((count + 1))"
    echo "$count" >"$TEST_COUNTER_FILE"
    if [[ "$count" -eq 1 ]]; then
      printf 'Stages: dev\n            pr-123\n'
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  auto-remove:sst:remove)
    ;;
  auto-remove:sst:state)
    printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    ;;
  remove-lock:sst:remove)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    count="$((count + 1))"
    echo "$count" >"$TEST_COUNTER_FILE"
    if [[ "$count" -eq 1 ]]; then
      echo "Locked A concurrent update was detected on the app. Run sst unlock to remove the lock and try again." >&2
      exit 1
    fi
    ;;
  remove-lock:sst:state)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 1 ]]; then
      printf 'Stages: dev\n        %s\n' "$5"
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  remove-lock:sst:unlock)
    ;;
  unlock:sst:unlock)
    ;;
  state-unavailable:sst:remove)
    ;;
  state-unavailable:sst:state)
    echo "Unknown command: state" >&2
    exit 1
    ;;
  not-deployed:sst:remove)
    ;;
  not-deployed:sst:state)
    printf '\033[90mStages:\033[0m\n  pr-123 (not deployed)\n'
    ;;
  old-sst:sst:remove)
    ;;
  old-sst:sst:state)
    printf 'Stages:\n  pr-123\n'
    ;;
  old-sst:sst:version)
    echo "4.12.9"
    ;;
  unknown-version:sst:remove)
    ;;
  unknown-version:sst:state)
    echo "backend unavailable" >&2
    exit 1
    ;;
  unknown-version:sst:version)
    echo "development build"
    ;;
  verify-unrecognized:sst:remove)
    ;;
  verify-unrecognized:sst:state)
    echo "state format changed"
    ;;
  verify-missing-marker:sst:remove)
    ;;
  verify-missing-marker:sst:state)
    echo "Stages: dev"
    ;;
  reconcile-mixed:sst:state)
    if [[ "$*" == "sst state list --stage pr-1" ]]; then
      printf 'pr-999\n' >&2
      printf '\033[90mStages:\033[0m dev\n'
      printf '            stg\n'
      printf '            prod\n'
      printf '            123\n'
      printf '            -legacy\n'
      printf '            pr-123\n'
      printf '            pr-456\n'
      printf '            pr-prod\n'
      printf '            pr-0\n'
      printf '            pr-001\n'
      printf '            pr-789 (not deployed)\n'
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  reconcile-mixed:sst:remove)
    ;;
  reconcile-state-failure:sst:state)
    echo "state backend unavailable" >&2
    exit 1
    ;;
  reconcile-remove-failure:sst:state)
    echo "Stages: pr-456"
    ;;
  reconcile-remove-failure:sst:remove)
    exit 1
    ;;
  reconcile-stage-already-removed:sst:state)
    if [[ "$*" == "sst state list --stage pr-1" ]]; then
      printf 'Stages: pr-456\n        pr-1 (not deployed)\n'
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  reconcile-stage-already-removed:sst:remove)
    echo "Stage not found" >&2
    exit 1
    ;;
  reconcile-partial-failure:sst:state)
    if [[ "$*" == "sst state list --stage pr-1" ]]; then
      printf 'Stages: pr-456\n        pr-789\n        pr-1 (not deployed)\n'
    elif [[ "$5" == "pr-456" ]]; then
      printf 'Stages: dev\n        pr-456\n'
    else
      printf 'Stages: dev\n        %s (not deployed)\n' "$5"
    fi
    ;;
  reconcile-partial-failure:sst:remove)
    if [[ "$4" == "pr-456" ]]; then
      exit 1
    fi
    ;;
  reconcile-lock:sst:state)
    if [[ "$*" == "sst state list --stage pr-1" ]]; then
      printf 'Stages: pr-456\n        pr-1 (not deployed)\n'
    else
      count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
      if [[ "$count" -eq 1 ]]; then
        printf 'Stages: dev\n        %s\n' "$5"
      else
        printf 'Stages: dev\n        %s (not deployed)\n' "$5"
      fi
    fi
    ;;
  reconcile-lock:sst:remove)
    count="$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo 0)"
    count="$((count + 1))"
    echo "$count" >"$TEST_COUNTER_FILE"
    if [[ "$count" -eq 1 ]]; then
      echo "Locked A concurrent update was detected on the app. Run sst unlock to remove the lock and try again." >&2
      exit 1
    fi
    ;;
  reconcile-lock:sst:unlock)
    ;;
  reconcile-no-stages:sst:state)
    printf 'Stages: dev\n'
    printf '        stg\n'
    printf '        prod\n'
    printf '        pr-prod\n'
    printf '        pr-0\n'
    printf '        pr-001\n'
    printf '        pr-789 (not deployed)\n'
    ;;
  reconcile-limit:sst:state)
    echo "Stages: pr-1"
    for number in {2..21}; do
      printf '        pr-%s\n' "$number"
    done
    ;;
  reconcile-unrecognized-output:sst:state)
    printf 'Stages:\n- pr-456\n'
    ;;
  *:sst:version)
    echo "4.17.1"
    ;;
  *)
    echo "Unexpected invocation: ${TEST_SCENARIO}:$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "${temp_dir}/bin/npx"

  cat >"${temp_dir}/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != */plan-reconciliation.mjs ]]; then
  exec "$TEST_REAL_NODE" "$@"
fi

if [[ "${RECONCILE_GITHUB_TOKEN:-}" != "test-token" ]]; then
  echo "Missing GitHub token in reconciliation planner" >&2
  exit 1
fi

plan_file="${TEST_COUNTER_FILE}-plan"
: >"$plan_file"
closed_count=0

while IFS= read -r stage; do
  [[ -n "$stage" ]] || continue
  pr_number="${stage#pr-}"
  echo "github pull request ${pr_number}" >>"$TEST_CALL_LOG"

  if [[ "$TEST_PR_STATE_FAILURE_NUMBER" == "$pr_number" ]]; then
    echo "GitHub API unavailable" >&2
    exit 1
  fi

  state=""
  while IFS="=" read -r candidate_number candidate_state; do
    if [[ "$candidate_number" == "$pr_number" ]]; then
      state="$candidate_state"
      break
    fi
  done < <(tr "," "\n" <<<"$TEST_PR_STATES")

  state="${state:-$TEST_DEFAULT_PR_STATE}"
  if [[ "$state" != "open" && "$state" != "closed" && "$state" != "grace" ]]; then
    echo "Missing test PR state for ${pr_number}" >&2
    exit 1
  fi

  if [[ "$state" == "closed" ]]; then
    printf '%s\n' "$stage" >>"$plan_file"
    closed_count="$((closed_count + 1))"
  fi
done <"$RECONCILE_CANDIDATES_FILE"

if ((closed_count > 20)); then
  echo "Too many stages" >&2
  exit 1
fi

echo "plan_file=${plan_file}" >>"$GITHUB_OUTPUT"
EOF
  chmod +x "${temp_dir}/bin/node"
  echo "$temp_dir"
}

test_deploy_success() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy run_action "$temp_dir" deploy-success

  assert_contains "${temp_dir}/github-output" "operation=deploy"
  assert_contains "${temp_dir}/github-output" "stage=pr-123"
  assert_contains "${temp_dir}/github-output" "url=https://abc123.cloudfront.net"
  assert_contains "${temp_dir}/calls" "sst deploy --stage pr-123"
}

test_deploy_failure_rolls_back() {
  local temp_dir
  local output_file
  temp_dir="$(make_temp_dir)"
  output_file="${temp_dir}/output"

  if INPUT_OPERATION=deploy run_action "$temp_dir" deploy-failure >"$output_file" 2>&1; then
    fail "deploy failure unexpectedly succeeded"
  fi

  assert_contains "${temp_dir}/calls" "sst deploy --stage pr-123"
  assert_contains "${temp_dir}/calls" "sst remove --stage pr-123"
  assert_contains "${temp_dir}/calls" "sst state list"
  [[ "$(grep -Fxc "deploy failed" "$output_file")" -eq 1 ]] ||
    fail "deploy failure output was not streamed exactly once"
}

test_deploy_output_is_streamed() {
  local action_pid
  local output_file
  local stream_observed="false"
  local temp_dir
  temp_dir="$(make_temp_dir)"
  output_file="${temp_dir}/output"

  INPUT_OPERATION=deploy run_action "$temp_dir" deploy-stream >"$output_file" 2>&1 &
  action_pid=$!

  for _ in {1..200}; do
    if grep -Fq "deploy started" "$output_file"; then
      stream_observed="true"
      break
    fi
    sleep 0.01
  done

  touch "${temp_dir}/stream-release"
  wait "$action_pid"

  [[ "$stream_observed" == "true" ]] ||
    fail "deploy output was not visible before deployment completed"
  assert_contains "${temp_dir}/github-output" "url=https://streamed.cloudfront.net"
}

test_named_output_url_is_preferred() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    TEST_OUTPUTS_JSON='{"url":"https://preview.example.com"}' \
    run_action "$temp_dir" deploy-named-output

  assert_contains "${temp_dir}/github-output" "url=https://preview.example.com/"
}

test_custom_named_output_key_is_supported() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    INPUT_URL_OUTPUT_KEY=previewUrl \
    TEST_OUTPUTS_JSON='{"previewUrl":"https://custom.example.com"}' \
    run_action "$temp_dir" deploy-named-output

  assert_contains "${temp_dir}/github-output" "url=https://custom.example.com/"
}

test_named_output_url_is_normalized_before_use() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    TEST_OUTPUTS_JSON='{"url":"https://preview.example.com/\" onclick=\"alert(1)"}' \
    run_action "$temp_dir" deploy-named-output

  assert_contains \
    "${temp_dir}/github-output" \
    "url=https://preview.example.com/%22%20onclick=%22alert(1)"
}

test_missing_named_output_falls_back_to_deploy_log() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    INPUT_URL_OUTPUT_KEY=url \
    TEST_OUTPUTS_JSON='{"apiUrl":"https://api.example.com"}' \
    run_action "$temp_dir" deploy-named-output

  assert_contains "${temp_dir}/github-output" "url=https://legacy.cloudfront.net"
}

test_invalid_named_output_cannot_inject_action_outputs() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    INPUT_URL_OUTPUT_KEY=url \
    TEST_OUTPUTS_JSON='{"url":"https://preview.example.com\nunsafe=true"}' \
    run_action "$temp_dir" deploy-named-output

  assert_contains "${temp_dir}/github-output" "url=https://legacy.cloudfront.net"
  [[ "$(wc -l <"${temp_dir}/github-output")" -eq 3 ]] ||
    fail "invalid named output injected an additional action output"
}

test_malformed_outputs_file_falls_back_to_deploy_log() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=deploy \
    INPUT_URL_OUTPUT_KEY=url \
    TEST_OUTPUTS_JSON='not-json' \
    run_action "$temp_dir" deploy-named-output

  assert_contains "${temp_dir}/github-output" "url=https://legacy.cloudfront.net"
}

test_missing_preview_url_emits_empty_output() {
  local output_file
  local temp_dir
  temp_dir="$(make_temp_dir)"
  output_file="${temp_dir}/output"

  INPUT_OPERATION=deploy run_action "$temp_dir" deploy-no-url >"$output_file" 2>&1

  assert_contains "${temp_dir}/github-output" "url="
  assert_contains "$output_file" "Deploy succeeded, but no preview URL was found"
}

test_remove_retries() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove run_action "$temp_dir" remove-retry

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 2 ]] ||
    fail "remove was not attempted twice"
  [[ "$(grep -Fc "sst unlock --stage pr-123" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "a non-lock removal failure unexpectedly unlocked the stage"
}

test_remove_unlocks_a_stale_lock_before_retrying() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove run_action "$temp_dir" remove-lock

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 2 ]] ||
    fail "lock recovery did not retry removal"
  [[ "$(grep -Fc "sst unlock --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "lock recovery did not unlock exactly once"
}

test_remove_can_disable_automatic_unlock() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_UNLOCK_ON_LOCK=false \
    run_action "$temp_dir" remove-lock

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 2 ]] ||
    fail "removal retries changed when automatic unlock was disabled"
  [[ "$(grep -Fc "sst unlock --stage pr-123" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "automatic unlock ran despite being disabled"
}

test_verification_retries() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove run_action "$temp_dir" verify-retry

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 2 ]] ||
    fail "remove was not retried after failed verification"
}

test_auto_closed_event_removes() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=auto PR_EVENT_ACTION=closed run_action "$temp_dir" auto-remove

  assert_contains "${temp_dir}/github-output" "operation=remove"
  assert_contains "${temp_dir}/calls" "sst remove --stage pr-123"
}

test_unlock_uses_explicit_pr_stage() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=unlock INPUT_PR_NUMBER=456 PR_EVENT_NAME=workflow_dispatch PR_NUMBER= \
    run_action "$temp_dir" unlock

  assert_contains "${temp_dir}/github-output" "operation=unlock"
  assert_contains "${temp_dir}/github-output" "stage=pr-456"
  assert_contains "${temp_dir}/calls" "sst unlock --stage pr-456"
  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "unlock unexpectedly removed a stage"
  [[ "$(grep -Fc "sst deploy --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "unlock unexpectedly deployed a stage"
}

test_unlock_requires_workflow_dispatch() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=unlock INPUT_PR_NUMBER=456 PR_EVENT_NAME=pull_request PR_NUMBER= \
    run_action "$temp_dir" unlock; then
    fail "unlock unexpectedly ran outside workflow_dispatch"
  fi

  [[ ! -s "${temp_dir}/calls" ]] ||
    fail "unlock invoked npx outside workflow_dispatch"
}

test_unlock_requires_explicit_pr_number() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=unlock INPUT_PR_NUMBER= PR_EVENT_NAME=workflow_dispatch PR_NUMBER= \
    run_action "$temp_dir" unlock; then
    fail "unlock unexpectedly ran without an explicit PR number"
  fi

  [[ ! -s "${temp_dir}/calls" ]] ||
    fail "unlock invoked npx without an explicit PR number"
}

test_auto_verification_rejects_unavailable_state_on_modern_sst() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=auto run_action "$temp_dir" state-unavailable; then
    fail "automatic verification unexpectedly ignored a state error"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "automatic verification did not retry removal"
}

test_strict_verification_rejects_unavailable_state() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=true run_action "$temp_dir" state-unavailable; then
    fail "strict verification unexpectedly succeeded"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "strict verification did not retry removal"
}

test_not_deployed_state_is_treated_as_removed() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove SST_STAGE=pr-123 run_action "$temp_dir" not-deployed

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "remove was retried for a stage marked as not deployed"
  assert_contains "${temp_dir}/calls" "sst state list --stage pr-123"
}

test_missing_stage_is_treated_as_removed() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=auto PR_EVENT_ACTION=closed run_action "$temp_dir" stage-not-found

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "remove was retried for an already missing stage"
  assert_contains "${temp_dir}/calls" "sst state list --stage pr-123"
}

test_missing_stage_is_verified_when_verification_is_disabled() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=false \
    run_action "$temp_dir" stage-not-found

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "remove was retried for a verified missing stage"
  assert_contains "${temp_dir}/calls" "sst state list --stage pr-123"
}

test_disabled_verification_skips_state_after_successful_remove() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=false \
    run_action "$temp_dir" auto-remove

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "successful remove was retried with verification disabled"
  [[ "$(grep -Fc "sst state list --stage pr-123" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "successful remove was verified despite verification being disabled"
}

test_disabled_verification_does_not_mask_unverified_remove_failure() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=false \
    run_action "$temp_dir" remove-and-state-failure; then
    fail "unverified remove failure unexpectedly succeeded"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "unverified remove failure did not use all attempts"
  [[ "$(grep -Fc "sst state list --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "failed remove was not state-checked on every attempt"
}

test_auto_verification_supports_old_state_cleanup() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=auto run_action "$temp_dir" old-sst

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "remove was retried for an SST version that retains state"
  assert_contains "${temp_dir}/calls" "sst version"
}

test_unknown_version_enforces_verification() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=auto run_action "$temp_dir" unknown-version; then
    fail "an unknown SST version unexpectedly skipped verification"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "an unknown SST version did not retry removal"
}

test_verification_rejects_unrecognized_state_output() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=true \
    run_action "$temp_dir" verify-unrecognized; then
    fail "verification unexpectedly accepted unrecognized SST state output"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "unrecognized state output did not trigger removal retries"
}

test_verification_requires_an_explicit_not_deployed_marker() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_VERIFY_REMOVAL=true \
    run_action "$temp_dir" verify-missing-marker; then
    fail "verification unexpectedly succeeded without a not-deployed marker"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-123" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "a missing not-deployed marker did not trigger removal retries"
}

test_invalid_pr_number_is_rejected() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if PR_NUMBER='123;echo unsafe' run_action "$temp_dir" auto-remove; then
    fail "invalid PR number unexpectedly succeeded"
  fi

  [[ ! -s "${temp_dir}/calls" ]] || fail "npx was called for an invalid PR number"
}

test_explicit_pr_number_supports_manual_remove() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_PR_NUMBER=456 PR_NUMBER= run_action "$temp_dir" auto-remove

  assert_contains "${temp_dir}/github-output" "stage=pr-456"
  assert_contains "${temp_dir}/calls" "sst remove --stage pr-456"
}

test_matching_explicit_and_event_pr_numbers_are_allowed() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=remove INPUT_PR_NUMBER=123 PR_NUMBER=123 run_action "$temp_dir" auto-remove

  assert_contains "${temp_dir}/github-output" "stage=pr-123"
  assert_contains "${temp_dir}/calls" "sst remove --stage pr-123"
}

test_mismatched_explicit_and_event_pr_numbers_are_rejected() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_PR_NUMBER=456 PR_NUMBER=123 run_action "$temp_dir" auto-remove; then
    fail "mismatched PR numbers unexpectedly succeeded"
  fi

  [[ ! -s "${temp_dir}/calls" ]] || fail "npx was called for mismatched PR numbers"
}

test_noncanonical_pr_numbers_are_rejected() {
  local invalid_pr_number

  for invalid_pr_number in 0 001 '123;echo unsafe'; do
    local temp_dir
    temp_dir="$(make_temp_dir)"

    if INPUT_OPERATION=remove INPUT_PR_NUMBER="$invalid_pr_number" PR_NUMBER= run_action "$temp_dir" auto-remove; then
      fail "invalid explicit PR number unexpectedly succeeded: ${invalid_pr_number}"
    fi

    [[ ! -s "${temp_dir}/calls" ]] ||
      fail "npx was called for invalid explicit PR number: ${invalid_pr_number}"
  done
}

test_missing_pr_number_is_rejected() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=remove INPUT_PR_NUMBER= PR_NUMBER= run_action "$temp_dir" auto-remove; then
    fail "missing PR number unexpectedly succeeded"
  fi

  [[ ! -s "${temp_dir}/calls" ]] || fail "npx was called without a PR number"
}

test_schedule_auto_reconciles_without_a_pr_number() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=auto PR_EVENT_NAME=schedule PR_NUMBER= \
    run_reconcile_action "$temp_dir" reconcile-no-stages

  assert_contains "${temp_dir}/github-output" "operation=reconcile"
  assert_contains "${temp_dir}/github-output" "stage="
  assert_contains "${temp_dir}/calls" "sst state list --stage pr-1"
}

test_workflow_dispatch_auto_deploys_the_requested_pr() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=auto INPUT_PR_NUMBER=456 PR_EVENT_NAME=workflow_dispatch PR_NUMBER= \
    run_action "$temp_dir" deploy-success

  assert_contains "${temp_dir}/github-output" "operation=deploy"
  assert_contains "${temp_dir}/calls" "sst deploy --stage pr-456"
}

test_reconcile_removes_only_closed_canonical_pr_stages() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='123=open,456=closed' \
    run_reconcile_action "$temp_dir" reconcile-mixed

  assert_contains "${temp_dir}/calls" "github pull request 123"
  assert_contains "${temp_dir}/calls" "github pull request 456"
  assert_contains "${temp_dir}/calls" "sst remove --stage pr-456"
  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "reconcile removed an unexpected number of stages"

  for unsafe_stage in dev stg prod 123 -legacy pr-prod pr-0 pr-001 pr-789; do
    if grep -Fq "sst remove --stage ${unsafe_stage}" "${temp_dir}/calls"; then
      fail "reconcile attempted to remove unsafe stage: ${unsafe_stage}"
    fi
  done

  [[ "$(grep -Fc "github pull request 789" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "not-deployed stage was sent to the GitHub API"
  [[ "$(grep -Fc "github pull request 999" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "a stage-like stderr line was sent to the GitHub API"
}

test_reconcile_api_failure_removes_nothing() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='123=closed' \
    TEST_PR_STATE_FAILURE_NUMBER=456 \
    run_reconcile_action "$temp_dir" reconcile-mixed; then
    fail "reconcile unexpectedly ignored a GitHub API failure"
  fi

  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "reconcile removed a stage before completing its plan"
}

test_reconcile_state_failure_never_queries_or_removes() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile PR_NUMBER= run_reconcile_action "$temp_dir" reconcile-state-failure; then
    fail "reconcile unexpectedly ignored an SST state failure"
  fi

  [[ "$(grep -Fc "github pull request" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "GitHub was queried after SST state listing failed"
  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "a stage was removed after SST state listing failed"
}

test_reconcile_rejects_unrecognized_state_output() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile PR_NUMBER= \
    run_reconcile_action "$temp_dir" reconcile-unrecognized-output; then
    fail "reconcile unexpectedly accepted unrecognized SST state output"
  fi

  [[ "$(grep -Fc "github pull request" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "GitHub was queried for unrecognized SST state output"
  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "a stage was removed for unrecognized SST state output"
}

test_reconcile_aggregates_removal_failure() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='456=closed' \
    run_reconcile_action "$temp_dir" reconcile-remove-failure; then
    fail "reconcile unexpectedly ignored a removal failure"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-456" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "reconcile did not apply the configured removal retries"
}

test_reconcile_unlocks_a_stale_lock_before_retrying() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='456=closed' \
    run_reconcile_action "$temp_dir" reconcile-lock

  [[ "$(grep -Fc "sst remove --stage pr-456" "${temp_dir}/calls")" -eq 2 ]] ||
    fail "reconcile lock recovery did not retry removal"
  [[ "$(grep -Fc "sst unlock --stage pr-456" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "reconcile lock recovery did not unlock exactly once"
}

test_reconcile_accepts_a_stage_removed_after_planning() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='456=closed' \
    run_reconcile_action "$temp_dir" reconcile-stage-already-removed

  [[ "$(grep -Fc "sst remove --stage pr-456" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "reconcile retried a stage that was already removed"
  assert_contains "${temp_dir}/calls" "sst state list --stage pr-456"
}

test_reconcile_continues_after_an_individual_removal_failure() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_PR_STATES='456=closed,789=closed' \
    run_reconcile_action "$temp_dir" reconcile-partial-failure; then
    fail "reconcile unexpectedly ignored an individual removal failure"
  fi

  [[ "$(grep -Fc "sst remove --stage pr-456" "${temp_dir}/calls")" -eq 3 ]] ||
    fail "failing stage did not use all removal attempts"
  [[ "$(grep -Fc "sst remove --stage pr-789" "${temp_dir}/calls")" -eq 1 ]] ||
    fail "reconcile did not continue to a later stage"
}

test_reconcile_refuses_an_excessive_removal_plan() {
  local temp_dir
  temp_dir="$(make_temp_dir)"

  if INPUT_OPERATION=reconcile \
    PR_NUMBER= \
    TEST_DEFAULT_PR_STATE=closed \
    run_reconcile_action "$temp_dir" reconcile-limit; then
    fail "reconcile unexpectedly accepted an excessive removal plan"
  fi

  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "reconcile started removal before enforcing its safety limit"
}

test_reconcile_revalidates_the_entire_plan_before_removal() {
  local plan_file
  local temp_dir
  temp_dir="$(make_temp_dir)"
  plan_file="${temp_dir}/unsafe-plan"
  printf 'pr-456\ndev\n' >"$plan_file"

  if env \
    PATH="${temp_dir}/bin:${PATH}" \
    GITHUB_OUTPUT="${temp_dir}/remove-output" \
    INPUT_REMOVE_RETRY_DELAY_SECONDS=0 \
    RECONCILE_PLAN_FILE="$plan_file" \
    TEST_CALL_LOG="${temp_dir}/calls" \
    TEST_COUNTER_FILE="${temp_dir}/counter" \
    TEST_REAL_NODE="$(command -v node)" \
    TEST_SCENARIO=reconcile-mixed \
    bash -c 'cd "$1" && exec bash "$2"' _ "$temp_dir" "$remove_reconciled_script"; then
    fail "reconcile unexpectedly accepted an unsafe plan"
  fi

  [[ "$(grep -Fc "sst remove --stage" "${temp_dir}/calls")" -eq 0 ]] ||
    fail "reconcile started removal before validating the entire plan"
}

test_deploy_success
test_deploy_failure_rolls_back
test_deploy_output_is_streamed
test_named_output_url_is_preferred
test_custom_named_output_key_is_supported
test_named_output_url_is_normalized_before_use
test_missing_named_output_falls_back_to_deploy_log
test_invalid_named_output_cannot_inject_action_outputs
test_malformed_outputs_file_falls_back_to_deploy_log
test_missing_preview_url_emits_empty_output
test_remove_retries
test_remove_unlocks_a_stale_lock_before_retrying
test_remove_can_disable_automatic_unlock
test_verification_retries
test_auto_closed_event_removes
test_unlock_uses_explicit_pr_stage
test_unlock_requires_workflow_dispatch
test_unlock_requires_explicit_pr_number
test_auto_verification_rejects_unavailable_state_on_modern_sst
test_strict_verification_rejects_unavailable_state
test_not_deployed_state_is_treated_as_removed
test_missing_stage_is_treated_as_removed
test_missing_stage_is_verified_when_verification_is_disabled
test_disabled_verification_skips_state_after_successful_remove
test_disabled_verification_does_not_mask_unverified_remove_failure
test_auto_verification_supports_old_state_cleanup
test_unknown_version_enforces_verification
test_verification_rejects_unrecognized_state_output
test_verification_requires_an_explicit_not_deployed_marker
test_invalid_pr_number_is_rejected
test_explicit_pr_number_supports_manual_remove
test_matching_explicit_and_event_pr_numbers_are_allowed
test_mismatched_explicit_and_event_pr_numbers_are_rejected
test_noncanonical_pr_numbers_are_rejected
test_missing_pr_number_is_rejected
test_schedule_auto_reconciles_without_a_pr_number
test_workflow_dispatch_auto_deploys_the_requested_pr
test_reconcile_removes_only_closed_canonical_pr_stages
test_reconcile_api_failure_removes_nothing
test_reconcile_state_failure_never_queries_or_removes
test_reconcile_rejects_unrecognized_state_output
test_reconcile_aggregates_removal_failure
test_reconcile_unlocks_a_stale_lock_before_retrying
test_reconcile_accepts_a_stage_removed_after_planning
test_reconcile_continues_after_an_individual_removal_failure
test_reconcile_refuses_an_excessive_removal_plan
test_reconcile_revalidates_the_entire_plan_before_removal

echo "All run-sst tests passed"
