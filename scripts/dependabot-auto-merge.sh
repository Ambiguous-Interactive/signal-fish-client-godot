#!/usr/bin/env bash
set -euo pipefail

required_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "::error::Required command '${name}' was not found on PATH."
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Required environment variable '${name}' is not set."
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

required_command gh
required_command jq
require_env GITHUB_REPOSITORY
require_env GH_TOKEN

HEAD_SHA="${HEAD_SHA:-}"
HEAD_BRANCH="${HEAD_BRANCH:-}"
REQUIRED_WORKFLOWS="${REQUIRED_WORKFLOWS:-Runtime CI|LLM Harness}"
DEPENDABOT_TARGET_BRANCH="${DEPENDABOT_TARGET_BRANCH:-main}"
DEPENDABOT_LOGIN="${DEPENDABOT_LOGIN:-dependabot[bot]}"

if [[ -z "${HEAD_SHA}" || -z "${HEAD_BRANCH}" ]]; then
  echo "Missing workflow_run head metadata; skipping."
  exit 0
fi

pull_numbers="$(
  gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/pulls" |
    jq -r \
      --arg repo "${GITHUB_REPOSITORY}" \
      --arg sha "${HEAD_SHA}" \
      --arg base "${DEPENDABOT_TARGET_BRANCH}" \
      --arg login "${DEPENDABOT_LOGIN}" \
      '.[] | select(
          .state == "open" and
          .user.login == $login and
          .base.ref == $base and
          .head.repo.full_name == $repo and
          .head.sha == $sha
        ) | .number'
)"

if [[ -z "${pull_numbers}" ]]; then
  echo "No open Dependabot PR found for ${HEAD_SHA}; skipping."
  exit 0
fi

pull_count="$(printf '%s\n' "${pull_numbers}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "${pull_count}" != "1" ]]; then
  echo "Expected exactly one Dependabot PR for ${HEAD_SHA}, found ${pull_count}:"
  printf '%s\n' "${pull_numbers}"
  exit 1
fi

pull_number="$(printf '%s\n' "${pull_numbers}" | sed '/^$/d' | head -n 1)"
pr_info="$(
  gh pr view "${pull_number}" --json baseRefName,headRefOid,isDraft,state |
    jq -r '[.state, .baseRefName, (.isDraft | tostring), .headRefOid] | @tsv'
)"
IFS=$'\t' read -r pr_state base_ref is_draft head_ref_oid <<<"${pr_info}"

if [[ "${pr_state}" != "OPEN" || "${base_ref}" != "${DEPENDABOT_TARGET_BRANCH}" || "${is_draft}" != "false" ]]; then
  echo "PR #${pull_number} is not an open, ready Dependabot PR targeting ${DEPENDABOT_TARGET_BRANCH}; skipping."
  exit 0
fi

if [[ "${head_ref_oid}" != "${HEAD_SHA}" ]]; then
  echo "PR #${pull_number} moved from ${HEAD_SHA} to ${head_ref_oid}; skipping stale workflow_run."
  exit 0
fi

runs_json="$(
  gh api --paginate --slurp \
    "/repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${HEAD_SHA}&event=pull_request&per_page=100"
)"

IFS='|' read -ra required_workflows <<<"${REQUIRED_WORKFLOWS}"
for workflow in "${required_workflows[@]}"; do
  workflow="$(trim "${workflow}")"
  if [[ -z "${workflow}" ]]; then
    continue
  fi

  run_state="$(
    jq -r \
      --arg workflow "${workflow}" \
      --arg sha "${HEAD_SHA}" \
      '[.[].workflow_runs[]? | select(.name == $workflow and .head_sha == $sha)]
       | if length == 0 then
           ["missing", ""]
         else
           (sort_by(.created_at) | reverse | .[0] | [.status // "missing", .conclusion // ""])
         end
       | @tsv' <<<"${runs_json}"
  )"
  IFS=$'\t' read -r run_status run_conclusion <<<"${run_state}"
  echo "${workflow}: status=${run_status} conclusion=${run_conclusion:-none}"

  if [[ "${run_status}" != "completed" ]]; then
    echo "${workflow} is ${run_status}; waiting for another workflow_run event."
    exit 0
  fi

  if [[ "${run_conclusion}" != "success" ]]; then
    echo "${workflow} concluded ${run_conclusion}; not merging."
    exit 0
  fi
done

set +e
checks_json="$(gh pr checks "${pull_number}" --json bucket,name,state,workflow)"
checks_exit=$?
set -e

if [[ ${checks_exit} -eq 8 ]]; then
  echo "PR #${pull_number} still has pending checks; waiting for another workflow_run event."
  exit 0
fi

if [[ ${checks_exit} -ne 0 ]]; then
  echo "Unable to read PR checks for #${pull_number}; gh exited ${checks_exit}."
  exit "${checks_exit}"
fi

non_passing_checks="$(
  jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | [.workflow, .name, .state] | @tsv' <<<"${checks_json}"
)"
if [[ -n "${non_passing_checks}" ]]; then
  echo "PR #${pull_number} has non-passing checks; not merging:"
  printf '%s\n' "${non_passing_checks}"
  exit 0
fi

gh pr merge "${pull_number}" \
  --squash \
  --delete-branch \
  --match-head-commit "${HEAD_SHA}"
