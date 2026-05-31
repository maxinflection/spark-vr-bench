#!/usr/bin/env bash
# check-pool-b-status.sh -- one-shot status check for an unattended Pool B run.
#
# Reports: tmux session presence, runner-log tail, per-bench results
# summary (pass_rate, n_tasks, wall, tokens, smoke flag) when synced.
# Safe to invoke from anywhere with SSH-over-SSM access AND default AWS
# creds that can read s3://<RESULTS_BUCKET>/.
#
# Usage:
#   ./check-pool-b-status.sh --campaign NAME --target opus47|opus46|gpt55|vllm [--profile P]

set -Eeuo pipefail
IFS=$'\n\t'

CAMPAIGN=""
TARGET=""
INSTANCE_ID=""
AWS_PROFILE_ARG=""

usage() {
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign)    CAMPAIGN="$2"; shift 2 ;;
    --target)      TARGET="$2"; shift 2 ;;
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --profile)     AWS_PROFILE_ARG="--profile $2"; shift 2 ;;
    -h|--help)     usage ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -z "${CAMPAIGN}" ]] && { echo "--campaign is required" >&2; exit 1; }
[[ -z "${TARGET}"   ]] && { echo "--target is required (opus47, opus46, gpt55, or vllm)" >&2; exit 1; }

if [[ -z "${INSTANCE_ID}" ]]; then
  STATE_FILE="/tmp/harness-instance-${CAMPAIGN}.id"
  if [[ -f "${STATE_FILE}" ]]; then
    INSTANCE_ID="$(cat "${STATE_FILE}")"
  else
    # Tag-based discovery as fallback
    INSTANCE_ID="$(
      aws ${AWS_PROFILE_ARG} ec2 describe-instances --region us-east-1 \
        --filters "Name=tag:Campaign,Values=${CAMPAIGN}" \
                  "Name=tag:Component,Values=eval-harness" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null \
      | head -1
    )"
    [[ -z "${INSTANCE_ID}" ]] && { echo "No instance found for campaign ${CAMPAIGN}" >&2; exit 1; }
  fi
fi

SESSION_NAME="pool-b-${TARGET}"

printf '\n=== campaign=%s target=%s instance=%s ===\n' \
  "${CAMPAIGN}" "${TARGET}" "${INSTANCE_ID}"

printf '\n--- tmux session presence ---\n'
if ssh -o BatchMode=yes -o ConnectTimeout=10 "ubuntu@${INSTANCE_ID}" \
      "sudo tmux has-session -t ${SESSION_NAME} 2>/dev/null"; then
  printf 'session %s: RUNNING\n' "${SESSION_NAME}"
else
  printf 'session %s: not present (finished, crashed, or never started)\n' "${SESSION_NAME}"
fi

printf '\n--- last 10 lines of runner log on box ---\n'
ssh "ubuntu@${INSTANCE_ID}" 'sudo tail -10 /var/log/harness-runner.log 2>/dev/null || echo "(log not present)"'

printf '\n--- bench results summary ---\n'
S3_PREFIX="s3://<RESULTS_BUCKET>/${CAMPAIGN}/${TARGET}/"

# Find synced results.json files and pull each through jq for a one-line summary.
RESULTS_LIST="$(aws ${AWS_PROFILE_ARG} s3 ls --recursive "${S3_PREFIX}" 2>/dev/null \
  | awk '/\/results\.json$/ {print $4}')"

if [[ -z "${RESULTS_LIST}" ]]; then
  printf '(no results.json synced yet)\n'
else
  printf '%-18s %-9s %8s %8s %10s %10s %s\n' \
    "bench" "pass_rate" "n_tasks" "wall_s" "tokens_in" "tokens_out" "notes"
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    local_url="s3://<RESULTS_BUCKET>/${key}"
    body="$(aws ${AWS_PROFILE_ARG} s3 cp "${local_url}" - 2>/dev/null)" || continue
    printf '%s\n' "${body}" | jq -r '
      def n: . // 0;
      def fmt: if . == null then "null" else (. | tostring) end;
      [
        (.bench | fmt),
        ((.pass_rate | n) | tostring),
        ((.n_tasks | n) | tostring),
        ((.wall_time_seconds | n) | tostring),
        ((.tokens_in | n) | tostring),
        ((.tokens_out | n) | tostring),
        (
          [
            (if .status == "failed" then "FAILED(exit=" + (.exit_code | tostring) + ")" else empty end),
            (if .status == "skipped" then "SKIPPED" else empty end),
            (if (.extra.smoke // false) then "smoke(limit=" + ((.extra.smoke_limit // 0) | tostring) + ")" else empty end),
            (if (._repaired_by_rlp23 // false) then "repaired" else empty end)
          ] | join(",")
        )
      ] | @tsv' 2>/dev/null \
      | awk -F'\t' '{ printf "%-18s %-9.4f %8d %8d %10d %10d %s\n", $1, $2, $3, $4, $5, $6, $7 }'
  done <<< "${RESULTS_LIST}"
fi

printf '\n--- error sentinels (if any) ---\n'
ssh "ubuntu@${INSTANCE_ID}" \
  'sudo ls -la /var/lib/harness/runner-errors/ 2>/dev/null || echo "(none)"'

printf '\n'
