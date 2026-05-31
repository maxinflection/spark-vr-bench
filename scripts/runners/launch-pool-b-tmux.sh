#!/usr/bin/env bash
# launch-pool-b-tmux.sh -- start a Pool B runner in a detached tmux session
# on the harness EC2 box, so it survives SSH disconnect / Claude Code session
# exit / proxmox sandbox restart.
#
# Why tmux: a plain `ssh ubuntu@<id> sudo bash run-pool-b.sh ...` invocation
# inherits the SSH session as parent. SIGHUP on disconnect kills lm-eval
# mid-run. tmux reparents to init so the runner survives.
#
# Usage:
#   ./launch-pool-b-tmux.sh --campaign NAME --target opus47|opus46|gpt55|vllm \
#       [--profile P] [--limit N] [--force]
#       [--vllm-url URL --vllm-model MODEL [--vllm-key KEY | --vllm-key-ssm PATH]]
#
# --limit N    Smoke mode: cap each bench at N samples. Result files are
#              tagged with extra.smoke=true so they can't be confused with
#              full-run numbers. Useful for harness validation.
# --force      Overwrite existing per-bench results (default: skip if present).
#
# vLLM-target args (REQUIRED when --target=vllm):
#   --vllm-url URL          OpenAI-compatible base, e.g. https://host/v1
#   --vllm-model MODEL_ID   Model identifier as served by the endpoint
#   --vllm-key KEY          Literal API key (mutually exclusive with --vllm-key-ssm)
#   --vllm-key-ssm PATH     SSM SecureString path to fetch the key from
#
# Other helpful one-liners after launch (run from anywhere with SSH-over-SSM):
#   List sessions:    ssh ubuntu@<id> 'sudo tmux ls'
#   View live:        ssh ubuntu@<id> 'sudo tmux attach -t pool-b-<target>'
#                     (Ctrl-b d to detach without killing)
#   Tail log only:    ssh ubuntu@<id> 'sudo tail -f /var/log/harness-runner.log'
#   Kill (rare):      ssh ubuntu@<id> 'sudo tmux kill-session -t pool-b-<target>'
#
# Reads instance ID from /tmp/harness-instance-${CAMPAIGN}.id (written by
# harness-up.sh) or accepts --instance-id explicitly.

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

SCRIPT_NAME="launch-pool-b-tmux.sh"

CAMPAIGN=""
TARGET=""
INSTANCE_ID=""
AWS_PROFILE_ARG=""
SMOKE_LIMIT=""
FORCE_FLAG=""

# vLLM-target args (propagated to run-pool-b.sh when --target=vllm)
VLLM_URL=""
VLLM_MODEL=""
VLLM_KEY=""
VLLM_KEY_SSM=""

usage() {
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign)     CAMPAIGN="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --instance-id)  INSTANCE_ID="$2"; shift 2 ;;
    --profile)      AWS_PROFILE_ARG="--profile $2"; export AWS_PROFILE="$2"; shift 2 ;;
    --limit)        SMOKE_LIMIT="$2"; shift 2 ;;
    --force)        FORCE_FLAG="--force"; shift ;;
    --vllm-url)     VLLM_URL="$2";     shift 2 ;;
    --vllm-model)   VLLM_MODEL="$2";   shift 2 ;;
    --vllm-key)     VLLM_KEY="$2";     shift 2 ;;
    --vllm-key-ssm) VLLM_KEY_SSM="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "${CAMPAIGN}" ]] && { err "--campaign is required"; exit 1; }
[[ -z "${TARGET}"   ]] && { err "--target is required (opus47, opus46, gpt55, or vllm)"; exit 1; }
case "${TARGET}" in
  opus47|opus46|gpt55|vllm) : ;;
  *) err "--target must be 'opus47', 'opus46', 'gpt55', or 'vllm' (got: ${TARGET})"; exit 1 ;;
esac

# vLLM-target args sanity (the runner re-validates; we check here so the
# operator gets feedback before we ssh + tmux).
if [[ "${TARGET}" == "vllm" ]]; then
  [[ -z "${VLLM_URL}"   ]] && { err "--target vllm requires --vllm-url"; exit 1; }
  [[ -z "${VLLM_MODEL}" ]] && { err "--target vllm requires --vllm-model"; exit 1; }
  if [[ -n "${VLLM_KEY}" && -n "${VLLM_KEY_SSM}" ]]; then
    err "--vllm-key and --vllm-key-ssm are mutually exclusive"
    exit 1
  fi
fi

if [[ -z "${INSTANCE_ID}" ]]; then
  # 1. State file (only present on the host that ran harness-up.sh — usually laptop).
  STATE_FILE="/tmp/harness-instance-${CAMPAIGN}.id"
  if [[ -f "${STATE_FILE}" ]]; then
    INSTANCE_ID="$(cat "${STATE_FILE}")"
    log "Resolved instance from state file: ${INSTANCE_ID}"
  else
    # 2. Tag-based discovery fallback (works from anywhere with EC2 read perms —
    # proxmox sandbox, second laptop, CI runner, etc.).
    log "No state file at ${STATE_FILE}; falling back to EC2 tag discovery"
    INSTANCE_ID="$(
      aws ${AWS_PROFILE_ARG} ec2 describe-instances --region us-east-1 \
        --filters "Name=tag:Campaign,Values=${CAMPAIGN}" \
                  "Name=tag:Component,Values=eval-harness" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null \
      | tr -d '\r' | awk 'NF{print; exit}'
    )"
    if [[ -z "${INSTANCE_ID}" ]]; then
      err "No running instance found for campaign=${CAMPAIGN}"
      err "  Either: pass --instance-id explicitly, or run harness-up.sh on the lifecycle host first."
      exit 1
    fi
    log "Resolved instance from EC2 tags: ${INSTANCE_ID}"
  fi
fi

SESSION_NAME="pool-b-${TARGET}"

# Refuse to clobber an existing live session with the same name.
if ssh -o BatchMode=yes -o ConnectTimeout=10 "ubuntu@${INSTANCE_ID}" \
      "sudo tmux has-session -t ${SESSION_NAME} 2>/dev/null" 2>/dev/null; then
  err "tmux session '${SESSION_NAME}' already running on ${INSTANCE_ID}"
  err "  attach:  ssh ubuntu@${INSTANCE_ID} 'sudo tmux attach -t ${SESSION_NAME}'"
  err "  kill:    ssh ubuntu@${INSTANCE_ID} 'sudo tmux kill-session -t ${SESSION_NAME}'"
  exit 1
fi

# Single-quoted inner command so $vars don't expand on the laptop side.
# `tmux new -d` creates detached; the inner runner is what does the work.
INNER_CMD="/opt/benchmarks/scripts/runners/run-pool-b.sh --campaign ${CAMPAIGN} --target ${TARGET}"
[[ -n "${SMOKE_LIMIT}" ]] && INNER_CMD="${INNER_CMD} --limit ${SMOKE_LIMIT}"
[[ -n "${FORCE_FLAG}" ]] && INNER_CMD="${INNER_CMD} ${FORCE_FLAG}"
# vLLM args. --vllm-key contains a literal secret; tmux env on the box is
# only readable by root (where the runner already runs via sudo), and the
# runner redacts api_key from results.json before persisting (see
# redact_model_args in run-pool-b.sh). Prefer --vllm-key-ssm for any
# longer-lived rental — the SSM path stays out of process state entirely.
[[ -n "${VLLM_URL}"     ]] && INNER_CMD="${INNER_CMD} --vllm-url ${VLLM_URL}"
[[ -n "${VLLM_MODEL}"   ]] && INNER_CMD="${INNER_CMD} --vllm-model ${VLLM_MODEL}"
[[ -n "${VLLM_KEY}"     ]] && INNER_CMD="${INNER_CMD} --vllm-key ${VLLM_KEY}"
[[ -n "${VLLM_KEY_SSM}" ]] && INNER_CMD="${INNER_CMD} --vllm-key-ssm ${VLLM_KEY_SSM}"

log "Starting tmux session '${SESSION_NAME}' on ${INSTANCE_ID}"
log "  campaign=${CAMPAIGN} target=${TARGET}"
log "  runner=${INNER_CMD}"

ssh "ubuntu@${INSTANCE_ID}" \
  "sudo tmux new-session -d -s ${SESSION_NAME} '${INNER_CMD}; echo done; sleep 5'"

# Verify session is live.
if ssh -o BatchMode=yes "ubuntu@${INSTANCE_ID}" \
      "sudo tmux has-session -t ${SESSION_NAME} 2>/dev/null"; then
  log "Session '${SESSION_NAME}' running on ${INSTANCE_ID}"
  cat <<USAGE_HINTS
Re-attach:        ssh ubuntu@${INSTANCE_ID} 'sudo tmux attach -t ${SESSION_NAME}'
                  (Ctrl-b d to detach without stopping the run)
Tail runner log:  ssh ubuntu@${INSTANCE_ID} 'sudo tail -f /var/log/harness-runner.log'
List sessions:    ssh ubuntu@${INSTANCE_ID} 'sudo tmux ls'
Status helper:    ./scripts/runners/check-pool-b-status.sh --campaign ${CAMPAIGN} --target ${TARGET}
USAGE_HINTS
else
  err "Failed to verify tmux session start"
  exit 1
fi
