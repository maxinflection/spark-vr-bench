#!/usr/bin/env bash
# harness-down.sh — Idempotent teardown for the benchmarks eval-harness EC2 host
#
# Usage: harness-down.sh [OPTIONS]
#
# Options:
#   --campaign NAME       Campaign name (used to find state file and tag)
#   --instance-id ID      Explicit instance ID (overrides state file lookup)
#   --final-sync DIR      Sync results from S3 before teardown
#   --force-terminate     Force teardown even if --final-sync fails
#   --find-orphans        List all eval-harness instances (no campaign required)
#   --keep-iam            Keep IAM role/profile (default: keep)
#   --delete-iam          Delete IAM role/profile (for true final teardown)
#   --keep-bucket         Keep S3 bucket (default: keep)
#   --delete-bucket       Delete S3 bucket (DESTRUCTIVE — removes results)
#   --keep-sg             Keep security group (default: keep)
#   --delete-sg           Delete security group
#   --profile NAME        AWS CLI profile (default: credential chain)
#   --debug               Enable debug logging and set -x
#   -h, --help            Show this help message
#
# Design reference: docs/research/ec2-harness-design.md
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Constants
# ============================================================
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(dirname -- "${SCRIPT_DIR}")"
readonly SCRIPT_NAME="harness-down.sh"
readonly REGION="us-east-1"
readonly ACCOUNT_ID="<AWS_ACCOUNT_ID>"
readonly IAM_ROLE_NAME="harness-driver-role"
readonly INSTANCE_PROFILE_NAME="harness-driver-profile"
readonly S3_BUCKET="<RESULTS_BUCKET>"
readonly SG_NAME="harness-eval-sg"

# ============================================================
# Defaults
# ============================================================
CAMPAIGN="default"
INSTANCE_ID=""
FINAL_SYNC_DIR=""
FORCE_TERMINATE=false
FIND_ORPHANS=false
DELETE_IAM=false
DELETE_BUCKET=false
DELETE_SG=false
AWS_PROFILE=""
LOG_LEVEL="info"

# ============================================================
# Logging
# ============================================================
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[harness][%s][%s] message=%s campaign=%s instance=%s\n' \
    "${level}" "${ts}" "${msg}" "${CAMPAIGN}" "${INSTANCE_ID:-unknown}" >&2
}
log_info()  { log "info"  "$@"; }
log_warn()  { log "warn"  "$@"; }
log_error() { log "error" "$@"; }
log_debug() { [[ "${LOG_LEVEL}" == "debug" ]] && log "debug" "$@" || true; }

# ============================================================
# Error trap
# ============================================================
_ERR_FILE="/tmp/harness-down-error-$(date +%Y%m%d-%H%M%S).err"
_err_trap() {
  local exit_code=$?
  local line_no="${1:-}"
  log_error "Unhandled error at line ${line_no} (exit=${exit_code})"
  {
    printf 'script=%s\n' "${SCRIPT_NAME}"
    printf 'campaign=%s\n' "${CAMPAIGN}"
    printf 'instance=%s\n' "${INSTANCE_ID:-unknown}"
    printf 'exit_code=%s\n' "${exit_code}"
    printf 'line=%s\n' "${line_no}"
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${_ERR_FILE}"
  log_error "Bug report written to ${_ERR_FILE}"
}
trap '_err_trap ${LINENO}' ERR

# ============================================================
# AWS CLI wrapper
# ============================================================
aws_cmd() {
  if [[ -n "${AWS_PROFILE}" ]]; then
    aws "$@" --profile "${AWS_PROFILE}" --region "${REGION}"
  else
    aws "$@" --region "${REGION}"
  fi
}

# ============================================================
# Retry with exponential backoff
# ============================================================
retry_aws() {
  local max_attempts="$1"; shift
  local attempt=1
  local delay=2
  while true; do
    # Capture exit code via `||` not `if … then … fi` — after a failed `if`
    # condition with no else branch, $? is 0 (the if-statement's own exit),
    # not the failed command's exit. The `||` form preserves the actual code.
    local exit_code=0
    "$@" || exit_code=$?
    if (( exit_code == 0 )); then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      log_error "Command failed after ${max_attempts} attempts: $*"
      return "${exit_code}"
    fi
    log_warn "Attempt ${attempt}/${max_attempts} failed (exit=${exit_code}); retrying in ${delay}s"
    sleep "${delay}"
    (( attempt++ ))
    (( delay = delay * 2 > 60 ? 60 : delay * 2 ))
  done
}

# ============================================================
# Argument parsing
# ============================================================
usage() {
  # F-T3-4: print all leading # comment lines until first non-comment line
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^!'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --campaign)       CAMPAIGN="$2";         shift 2 ;;
      --instance-id)    INSTANCE_ID="$2";      shift 2 ;;
      --final-sync)     FINAL_SYNC_DIR="$2";   shift 2 ;;
      --force-terminate) FORCE_TERMINATE=true; shift   ;;
      --find-orphans)   FIND_ORPHANS=true;     shift   ;;
      --delete-iam)     DELETE_IAM=true;       shift   ;;
      --keep-iam)       DELETE_IAM=false;      shift   ;;
      --delete-bucket)  DELETE_BUCKET=true;    shift   ;;
      --keep-bucket)    DELETE_BUCKET=false;   shift   ;;
      --delete-sg)      DELETE_SG=true;        shift   ;;
      --keep-sg)        DELETE_SG=false;       shift   ;;
      --profile)        AWS_PROFILE="$2";      shift 2 ;;
      --debug)          LOG_LEVEL="debug"; set -x; shift ;;
      -h|--help)        usage ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done
}

# ============================================================
# F-T1-2: Find orphaned eval-harness instances across all campaigns
# ============================================================
find_orphans() {
  log_info "Scanning for eval-harness instances across all campaigns"
  local result
  result="$(retry_aws 3 aws_cmd ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=benchmarks" \
      "Name=tag:Component,Values=eval-harness" \
      "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Campaign`].Value|[0],State.Name,LaunchTime]' \
    --output text 2>/dev/null)" || result=""

  if [[ -z "${result}" || "${result}" == "None" ]]; then
    log_info "No eval-harness instances found"
    return 0
  fi

  printf '\n%-22s %-35s %-12s %s\n' "InstanceId" "Campaign" "State" "LaunchTime"
  printf '%s\n' "$(printf -- '-%.0s' {1..85})"
  while IFS=$'\t' read -r inst_id campaign state launch_time; do
    printf '%-22s %-35s %-12s %s\n' "${inst_id}" "${campaign:-<untagged>}" "${state}" "${launch_time}"
  done <<< "${result}"
  printf '\n'
  log_info "To clean up: harness-down.sh --instance-id <id>"
}

# ============================================================
# Resolve instance ID
# ============================================================
resolve_instance_id() {
  if [[ -n "${INSTANCE_ID}" ]]; then
    log_info "Using explicit instance ID: ${INSTANCE_ID}"
    return 0
  fi

  local state_file="/tmp/harness-instance-${CAMPAIGN}.id"
  if [[ -f "${state_file}" ]]; then
    INSTANCE_ID="$(< "${state_file}")"
    INSTANCE_ID="$(printf '%s' "${INSTANCE_ID}" | tr -d '[:space:]')"
    if [[ -z "${INSTANCE_ID}" ]]; then
      log_error "State file ${state_file} is empty"
      exit 1
    fi
    log_info "Resolved instance ID from state file: ${INSTANCE_ID}"
    return 0
  fi

  # Fall back to tag-based discovery
  log_info "No state file at ${state_file}; attempting tag-based discovery for campaign=${CAMPAIGN}"
  INSTANCE_ID="$(retry_aws 3 aws_cmd ec2 describe-instances \
    --filters \
      "Name=tag:Campaign,Values=${CAMPAIGN}" \
      "Name=tag:Component,Values=eval-harness" \
      "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[0].InstanceId' \
    --output text 2>/dev/null | head -1)" || INSTANCE_ID=""

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    # F-Q3: double-invoke is a valid idempotent case — exit 0 cleanly
    log_info "No instance found for campaign=${CAMPAIGN} — already torn down"
    exit 0
  fi
  log_info "Discovered instance via tag: ${INSTANCE_ID}"
}

# ============================================================
# Determine stop vs terminate from Persistent tag
# ============================================================
determine_lifecycle_action() {
  local persistent_tag
  persistent_tag="$(retry_aws 3 aws_cmd ec2 describe-tags \
    --filters \
      "Name=resource-id,Values=${INSTANCE_ID}" \
      "Name=key,Values=Persistent" \
    --query 'Tags[0].Value' --output text 2>/dev/null)" || persistent_tag=""

  if [[ "${persistent_tag}" == "true" ]]; then
    LIFECYCLE_ACTION="stop"
    log_info "Instance has Persistent=true tag; will STOP (not terminate)"
  else
    LIFECYCLE_ACTION="terminate"
    log_info "Instance has no Persistent tag; will TERMINATE"
  fi
}

# ============================================================
# Verify instance state
# ============================================================
check_instance_state() {
  local state
  state="$(retry_aws 3 aws_cmd ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null)" || state=""

  case "${state}" in
    terminated|"")
      log_info "Instance ${INSTANCE_ID} is already terminated or not found — nothing to do"
      LIFECYCLE_ACTION="noop"
      ;;
    stopping|stopped)
      if [[ "${LIFECYCLE_ACTION}" == "terminate" ]]; then
        log_info "Instance is ${state}; will terminate"
      else
        log_info "Instance is already ${state}; lifecycle_action=stop is already done"
        LIFECYCLE_ACTION="noop"
      fi
      ;;
    running|pending)
      log_info "Instance is ${state}; proceeding with lifecycle_action=${LIFECYCLE_ACTION}"
      ;;
    *)
      log_warn "Unexpected instance state: ${state}; proceeding with lifecycle_action=${LIFECYCLE_ACTION}"
      ;;
  esac
}

# ============================================================
# Final S3 sync
# ============================================================
run_final_sync() {
  if [[ -z "${FINAL_SYNC_DIR}" ]]; then
    log_debug "No --final-sync requested; skipping"
    return 0
  fi

  log_info "Final S3 sync: s3://${S3_BUCKET}/${CAMPAIGN}/ -> ${FINAL_SYNC_DIR}"
  mkdir -p "${FINAL_SYNC_DIR}"

  local profile_args=()
  [[ -n "${AWS_PROFILE}" ]] && profile_args+=(--profile "${AWS_PROFILE}")

  # F-T2-7: sync failure aborts teardown unless --force-terminate is passed
  if ! retry_aws 3 aws s3 sync \
    "s3://${S3_BUCKET}/${CAMPAIGN}/" \
    "${FINAL_SYNC_DIR}/" \
    --region "${REGION}" \
    "${profile_args[@]+"${profile_args[@]}"}"; then
    if "${FORCE_TERMINATE}"; then
      log_warn "S3 sync failed — continuing with teardown because --force-terminate is set"
    else
      log_error "S3 sync failed — aborting teardown to preserve results. Use --force-terminate to override."
      exit 1
    fi
  else
    log_info "S3 sync complete: ${FINAL_SYNC_DIR}"
  fi
}

# ============================================================
# Stop or terminate instance
# ============================================================
apply_lifecycle_action() {
  if [[ "${LIFECYCLE_ACTION}" == "noop" ]]; then
    log_info "Nothing to do (instance already in target state)"
    return 0
  fi

  if [[ "${LIFECYCLE_ACTION}" == "stop" ]]; then
    log_info "Stopping instance ${INSTANCE_ID}"
    retry_aws 3 aws_cmd ec2 stop-instances \
      --instance-ids "${INSTANCE_ID}" \
      --output text > /dev/null

    log_info "Waiting for instance to reach stopped state"
    retry_aws 5 aws_cmd ec2 wait instance-stopped \
      --instance-ids "${INSTANCE_ID}"
    log_info "Instance stopped"

  elif [[ "${LIFECYCLE_ACTION}" == "terminate" ]]; then
    log_info "Terminating instance ${INSTANCE_ID}"
    retry_aws 3 aws_cmd ec2 terminate-instances \
      --instance-ids "${INSTANCE_ID}" \
      --output text > /dev/null

    log_info "Waiting for instance to reach terminated state"
    retry_aws 5 aws_cmd ec2 wait instance-terminated \
      --instance-ids "${INSTANCE_ID}"
    log_info "Instance terminated"
  fi
}

# ============================================================
# Optional: delete security group
# ============================================================
cleanup_sg() {
  if ! "${DELETE_SG}"; then
    log_debug "Keeping security group (pass --delete-sg to remove)"
    return 0
  fi

  log_info "Looking up security group for deletion"
  local sg_id
  sg_id="$(retry_aws 3 aws_cmd ec2 describe-security-groups \
    --filters "Name=tag:Component,Values=eval-harness" \
              "Name=tag:ManagedBy,Values=harness-up.sh" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)" || sg_id=""

  if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
    log_info "Security group not found (already deleted?)"
    return 0
  fi

  log_info "Deleting security group: ${sg_id}"
  retry_aws 3 aws_cmd ec2 delete-security-group \
    --group-id "${sg_id}" \
    --output text > /dev/null && \
    log_info "Security group deleted: ${sg_id}" || \
    log_warn "Security group deletion failed (may still be in use by a running instance)"
}

# ============================================================
# Optional: delete IAM role + instance profile
# ============================================================
cleanup_iam() {
  if ! "${DELETE_IAM}"; then
    log_debug "Keeping IAM resources (pass --delete-iam for full teardown)"
    return 0
  fi

  log_info "Cleaning up IAM role and instance profile"

  # Remove role from instance profile first
  local profile_roles
  profile_roles="$(retry_aws 3 aws_cmd iam get-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --query 'InstanceProfile.Roles[].RoleName' \
    --output text 2>/dev/null)" || profile_roles=""

  if printf '%s' "${profile_roles}" | grep -qw "${IAM_ROLE_NAME}" 2>/dev/null; then
    retry_aws 3 aws_cmd iam remove-role-from-instance-profile \
      --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
      --role-name "${IAM_ROLE_NAME}" \
      --output text > /dev/null && \
      log_info "Role removed from instance profile" || \
      log_warn "Role removal failed (idempotent — may already be removed)"
  fi

  # Delete instance profile
  retry_aws 3 aws_cmd iam delete-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --output text > /dev/null 2>&1 && \
    log_info "Instance profile deleted" || \
    log_info "Instance profile not found or already deleted"

  # Delete inline policy
  retry_aws 3 aws_cmd iam delete-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "harness-driver-inline" \
    --output text > /dev/null 2>&1 && \
    log_info "Inline policy deleted" || \
    log_info "Inline policy not found or already deleted"

  # Delete role
  retry_aws 3 aws_cmd iam delete-role \
    --role-name "${IAM_ROLE_NAME}" \
    --output text > /dev/null 2>&1 && \
    log_info "IAM role deleted" || \
    log_info "IAM role not found or already deleted"
}

# ============================================================
# Optional: delete S3 bucket (DESTRUCTIVE)
# ============================================================
cleanup_bucket() {
  if ! "${DELETE_BUCKET}"; then
    log_debug "Keeping S3 bucket (pass --delete-bucket to remove — DESTRUCTIVE)"
    return 0
  fi

  log_warn "DESTRUCTIVE: deleting S3 bucket ${S3_BUCKET} and ALL contents"
  log_warn "This will remove ALL campaign results stored in this bucket"

  # Remove all objects + versions first (required for versioned bucket)
  local profile_args=()
  [[ -n "${AWS_PROFILE}" ]] && profile_args+=(--profile "${AWS_PROFILE}")

  retry_aws 3 aws s3 rm "s3://${S3_BUCKET}" --recursive \
    --region "${REGION}" \
    "${profile_args[@]+"${profile_args[@]}"}" > /dev/null 2>&1 || \
    log_warn "s3 rm failed (bucket may be empty or already gone)"

  # Delete all object versions and delete markers
  local versions
  versions="$(retry_aws 3 aws_cmd s3api list-object-versions \
    --bucket "${S3_BUCKET}" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null)" || versions="[]"

  if [[ "$(printf '%s' "${versions}" | jq 'length')" -gt 0 ]]; then
    local delete_payload
    delete_payload="$(printf '%s' "${versions}" | \
      jq '{Objects: [.[] | {Key:.Key, VersionId:.VersionId}], Quiet: true}')"
    retry_aws 3 aws_cmd s3api delete-objects \
      --bucket "${S3_BUCKET}" \
      --delete "${delete_payload}" \
      --output text > /dev/null
  fi

  # Delete the bucket
  retry_aws 3 aws_cmd s3api delete-bucket \
    --bucket "${S3_BUCKET}" \
    --output text > /dev/null 2>&1 && \
    log_info "S3 bucket deleted: ${S3_BUCKET}" || \
    log_info "S3 bucket not found or already deleted"
}

# ============================================================
# Remove local state file
# ============================================================
cleanup_state_file() {
  local state_file="/tmp/harness-instance-${CAMPAIGN}.id"
  if [[ -f "${state_file}" ]]; then
    rm -f -- "${state_file}"
    log_info "State file removed: ${state_file}"
  else
    log_debug "State file not present: ${state_file}"
  fi
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"

  log_info "Starting harness-down campaign=${CAMPAIGN} script=${SCRIPT_NAME}"

  # F-T1-2: --find-orphans mode: no campaign required; print table and exit
  if "${FIND_ORPHANS}"; then
    find_orphans
    exit 0
  fi

  resolve_instance_id
  determine_lifecycle_action
  check_instance_state
  run_final_sync
  apply_lifecycle_action
  cleanup_sg
  cleanup_iam
  cleanup_bucket
  cleanup_state_file

  log_info "harness-down complete instance=${INSTANCE_ID} campaign=${CAMPAIGN}"
}

main "$@"
