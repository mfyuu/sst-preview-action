#!/usr/bin/env bash

set -euo pipefail

readonly operation_input="${INPUT_OPERATION:-auto}"
readonly input_pr_number="${INPUT_PR_NUMBER:-}"
readonly cleanup_on_deploy_failure="${INPUT_CLEANUP_ON_DEPLOY_FAILURE:-true}"
readonly remove_max_attempts="${INPUT_REMOVE_MAX_ATTEMPTS:-3}"
readonly remove_retry_delay_seconds="${INPUT_REMOVE_RETRY_DELAY_SECONDS:-30}"
readonly unlock_on_lock="${INPUT_UNLOCK_ON_LOCK:-true}"
readonly url_output_key="${INPUT_URL_OUTPUT_KEY-url}"
readonly verify_removal="${INPUT_VERIFY_REMOVAL:-auto}"
readonly event_action="${PR_EVENT_ACTION:-}"
readonly event_name="${PR_EVENT_NAME:-}"
readonly event_pr_number="${PR_NUMBER:-}"
# state list evaluates sst.config for this canonical preview stage, then lists
# every stage belonging to the resolved app. It does not deploy or remove pr-1.
readonly reconcile_probe_stage="pr-1"
readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error() {
  echo "::error::$*" >&2
}

validate_boolean() {
  local value="$1"
  local input_name="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    error "${input_name} must be either true or false"
    exit 1
  fi
}

validate_boolean "$cleanup_on_deploy_failure" "cleanup-on-deploy-failure"
validate_boolean "$unlock_on_lock" "unlock-on-lock"

if [[ "$verify_removal" != "auto" && "$verify_removal" != "true" && "$verify_removal" != "false" ]]; then
  error "verify-removal must be auto, true, or false"
  exit 1
fi

if [[ ! "$remove_max_attempts" =~ ^[1-9][0-9]*$ ]]; then
  error "remove-max-attempts must be a positive integer"
  exit 1
fi

if [[ ! "$remove_retry_delay_seconds" =~ ^[0-9]+$ ]]; then
  error "remove-retry-delay-seconds must be a non-negative integer"
  exit 1
fi

validate_pr_number() {
  local value="$1"
  local source="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    error "${source} must be a positive integer without leading zeros"
    exit 1
  fi
}

operation=""
case "$operation_input" in
  auto)
    case "$event_name" in
      schedule)
        operation="reconcile"
        ;;
      *)
        if [[ "$event_action" == "closed" ]]; then
          operation="remove"
        else
          operation="deploy"
        fi
        ;;
    esac
    ;;
  deploy | remove | unlock | reconcile)
    operation="$operation_input"
    ;;
  *)
    error "operation must be auto, deploy, remove, unlock, or reconcile"
    exit 1
    ;;
esac
readonly operation

if [[ "$operation" == "unlock" && "$event_name" != "workflow_dispatch" ]]; then
  error "unlock is supported only for workflow_dispatch events"
  exit 1
fi

pr_number=""
stage=""
if [[ "$operation" != "reconcile" ]]; then
  if [[ -n "$input_pr_number" ]]; then
    validate_pr_number "$input_pr_number" "pr-number"
  fi

  if [[ -n "$event_pr_number" ]]; then
    validate_pr_number "$event_pr_number" "github.event.pull_request.number"
  fi

  if [[ -n "$input_pr_number" && -n "$event_pr_number" && "$input_pr_number" != "$event_pr_number" ]]; then
    error "pr-number does not match github.event.pull_request.number"
    exit 1
  fi

  if [[ "$operation" == "unlock" && -z "$input_pr_number" ]]; then
    error "unlock requires an explicit pr-number"
    exit 1
  fi

  pr_number="${input_pr_number:-$event_pr_number}"
  if [[ -z "$pr_number" ]]; then
    error "This action requires pr-number or github.event.pull_request.number"
    exit 1
  fi

  stage="pr-${pr_number}"
fi
readonly pr_number
readonly stage

{
  echo "operation=${operation}"
  echo "stage=${stage}"
} >>"$GITHUB_OUTPUT"

run_state_list() {
  local error_file
  local state_list
  local status
  local target_stage="$1"

  error_file="$(
    mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sst-preview-state-error.XXXXXX"
  )"
  if state_list="$(npx sst state list --stage "$target_stage" 2>"$error_file")"; then
    status=0
  else
    status=$?
  fi

  if [[ -s "$error_file" ]]; then
    cat "$error_file" >&2
  fi
  rm -f -- "$error_file"

  if ((status != 0)); then
    return "$status"
  fi

  printf '%s' "$state_list"
}

parse_state_entries() {
  local entry
  local header_found="false"
  local line
  local normalized_state_list
  local stage_name
  local state_list="$1"

  normalized_state_list="$(
    sed -E $'s/\x1b\\[[0-9;?]*[ -\\/]*[@-~]//g' <<<"$state_list"
  )"

  while IFS= read -r line; do
    if [[ "$header_found" == "false" ]]; then
      if [[ ! "$line" =~ ^[[:space:]]*Stages:[[:space:]]*(.*)$ ]]; then
        continue
      fi
      header_found="true"
      entry="${BASH_REMATCH[1]}"
    else
      entry="$line"
    fi

    if [[ "$entry" =~ ^[[:space:]]*$ ]]; then
      continue
    fi

    if [[ ! "$entry" =~ ^[[:space:]]*([A-Za-z0-9-]+)([[:space:]]+\(not[[:space:]]+deployed\))?[[:space:]]*$ ]]; then
      error "Unable to recognize an entry in the SST Stages section"
      return 1
    fi

    stage_name="${BASH_REMATCH[1]}"
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      printf '%s (not deployed)\n' "$stage_name"
    else
      printf '%s\n' "$stage_name"
    fi
  done <<<"$normalized_state_list"

  if [[ "$header_found" == "false" ]]; then
    error "Unable to find the SST Stages section"
    return 1
  fi
}

verify_stage_removed() {
  local target_stage="$1"
  local quiet_stage_present="${2:-false}"
  local state_entries
  local state_list

  if ! state_list="$(run_state_list "$target_stage")"; then
    error "Unable to verify whether ${target_stage} is still present in SST state"
    return 2
  fi

  printf '%s\n' "$state_list"
  if ! state_entries="$(parse_state_entries "$state_list")"; then
    error "Unable to recognize the SST state list output while verifying ${target_stage}"
    return 2
  fi

  if grep -Fqx -- "$target_stage" <<<"$state_entries"; then
    if [[ "$quiet_stage_present" == "true" ]]; then
      echo "::notice::${target_stage} is still present in SST state"
    else
      error "${target_stage} is still present in SST state"
    fi
    return 1
  fi

  if ! grep -Fqx -- "${target_stage} (not deployed)" <<<"$state_entries"; then
    error "SST did not confirm that ${target_stage} is no longer deployed"
    return 2
  fi
}

sst_supports_state_removal() {
  local version_output
  local version
  local major
  local minor

  if ! version_output="$(npx sst version 2>&1)"; then
    printf '%s\n' "$version_output" >&2
    return 2
  fi

  version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$version_output" | tail -1 || true)"
  if [[ -z "$version" ]]; then
    printf '%s\n' "$version_output" >&2
    return 2
  fi

  IFS=. read -r major minor <<<"${version%.*}"
  if ((major > 4 || (major == 4 && minor >= 13))); then
    return 0
  fi

  return 1
}

remove_stage() {
  local -a remove_pipeline_status
  local target_stage="$1"
  local attempt
  local lock_detected
  local remove_log
  local remove_succeeded
  local state_removal_support
  local unlock_attempted="false"
  local verification_mode="$verify_removal"

  if [[ ! "$target_stage" =~ ^pr-[1-9][0-9]*$ ]]; then
    error "Refusing to remove noncanonical stage: ${target_stage}"
    return 1
  fi

  if [[ "$verification_mode" == "auto" ]]; then
    if sst_supports_state_removal; then
      verification_mode="true"
    else
      state_removal_support=$?
      if [[ "$state_removal_support" -eq 1 ]]; then
        echo "::warning::Skipping state verification because SST state removal requires SST 4.13.0 or newer"
        verification_mode="false"
      else
        echo "::warning::Unable to determine the SST version; enforcing state verification"
        verification_mode="true"
      fi
    fi
  fi

  remove_log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sst-preview-remove.XXXXXX")"

  for ((attempt = 1; attempt <= remove_max_attempts; attempt++)); do
    echo "Removing ${target_stage} (attempt ${attempt}/${remove_max_attempts})"

    : >"$remove_log"
    set +e
    npx sst remove --stage "$target_stage" 2>&1 | tee "$remove_log"
    remove_pipeline_status=("${PIPESTATUS[@]}")
    set -e

    if ((remove_pipeline_status[0] == 0)); then
      remove_succeeded="true"
    else
      remove_succeeded="false"
    fi

    lock_detected="false"
    if [[ "$remove_succeeded" == "false" ]] &&
      grep -Eiq -- 'concurrent update was detected|run sst unlock to remove the lock' "$remove_log"; then
      lock_detected="true"
    fi

    if [[ "$remove_succeeded" == "true" && "$verification_mode" == "false" ]]; then
      rm -f -- "$remove_log"
      return 0
    fi

    if verify_stage_removed "$target_stage" "$lock_detected"; then
      if [[ "$remove_succeeded" == "false" ]]; then
        echo "::notice::${target_stage} is already absent from SST state"
      fi
      rm -f -- "$remove_log"
      return 0
    fi

    if [[ "$lock_detected" == "true" &&
      "$unlock_on_lock" == "true" &&
      "$unlock_attempted" == "false" ]]; then
      unlock_attempted="true"
      echo "::warning::SST state lock detected for ${target_stage}; attempting unlock before retrying"
      if npx sst unlock --stage "$target_stage"; then
        echo "::notice::Unlocked ${target_stage}; retrying removal"
      else
        error "Failed to unlock ${target_stage} after a lock-specific remove failure"
      fi
    fi

    if ((attempt < remove_max_attempts)); then
      sleep "$remove_retry_delay_seconds"
    fi
  done

  rm -f -- "$remove_log"
  error "Failed to remove ${target_stage} after ${remove_max_attempts} attempts"
  return 1
}

discover_reconcile_stages() {
  local candidates_file
  local preview_stages
  local state_entries
  local state_list

  if ! state_list="$(run_state_list "$reconcile_probe_stage")"; then
    error "Unable to list SST stages for reconciliation"
    return 1
  fi

  printf '%s\n' "$state_list"
  if ! state_entries="$(parse_state_entries "$state_list")"; then
    error "Unable to recognize the SST state list output; no stages were removed"
    return 1
  fi

  preview_stages="$(
    sed -E -n -e '/^pr-[1-9][0-9]*$/p' <<<"$state_entries" |
      LC_ALL=C sort -u
  )"

  candidates_file="$(
    mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sst-preview-candidates.XXXXXX"
  )"
  printf '%s\n' "$preview_stages" >"$candidates_file"
  echo "reconcile_candidates_file=${candidates_file}" >>"$GITHUB_OUTPUT"

  if [[ -z "$preview_stages" ]]; then
    echo "No deployed pull-request stages found"
  fi
}

if [[ "$operation" == "reconcile" ]]; then
  discover_reconcile_stages
  exit 0
fi

if [[ "$operation" == "remove" ]]; then
  remove_stage "$stage"
  exit 0
fi

if [[ "$operation" == "unlock" ]]; then
  echo "Unlocking ${stage}"
  if ! npx sst unlock --stage "$stage"; then
    error "Failed to unlock ${stage}"
    exit 1
  fi
  exit 0
fi

deploy_log="$(mktemp)"
cleanup_deploy_log() {
  rm -f -- "$deploy_log"
}
trap cleanup_deploy_log EXIT

set +e
npx sst deploy --stage "$stage" 2>&1 | tee "$deploy_log"
deploy_pipeline_status=("${PIPESTATUS[@]}")
set -e

readonly deploy_status="${deploy_pipeline_status[0]}"
readonly tee_status="${deploy_pipeline_status[1]}"

if ((deploy_status != 0)); then
  error "SST deploy failed for ${stage}"

  if [[ "$cleanup_on_deploy_failure" == "true" ]]; then
    echo "Deploy failed; removing partially created resources for ${stage}"
    if ! remove_stage "$stage"; then
      error "Deploy and rollback both failed for ${stage}"
    fi
  fi

  exit 1
fi

if ((tee_status != 0)); then
  echo "::warning::SST deploy succeeded, but its output could not be captured completely"
fi

url=""
if [[ -n "$url_output_key" ]]; then
  if ! url="$(
    node "${script_directory}/read-sst-output.mjs" ".sst/outputs.json" "$url_output_key"
  )"; then
    url=""
  fi
fi

if [[ -z "$url" ]]; then
  url="$(grep -oE 'https://[a-z0-9]+\.cloudfront\.net' "$deploy_log" | head -1 || true)"
fi

echo "url=${url}" >>"$GITHUB_OUTPUT"

if [[ -z "$url" ]]; then
  echo "::warning::Deploy succeeded, but no preview URL was found"
fi
