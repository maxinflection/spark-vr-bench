#!/usr/bin/env bash
# harness-up.sh — Idempotent EC2 launch script for the benchmarks eval-harness host
#
# PREREQUISITE (bd benchmarks-<CAMPAIGN>): the one-time, IAM-admin resources (the
# harness-driver-role + instance profile, the harness-eval-sg security group, and
# the <RESULTS_BUCKET> bucket) are created by scripts/harness-bootstrap.sh,
# run ONCE under operator/admin creds. This script is the DAY-TO-DAY launcher: it
# only DESCRIBES those resources (no iam:Create*, no ec2:CreateSecurityGroup) and
# fails fast pointing at harness-bootstrap.sh if any are missing. It is runnable by
# a least-privilege principal holding scripts/iam/harness-launcher-least-priv.json.
#
# Usage: harness-up.sh [OPTIONS]
#
# Options:
#   --campaign NAME           Campaign tag and instance name (default: default)
#   --ssh-key PATH            Operator SSH public key file (default: ~/.ssh/id_ed25519.pub)
#   --instance-type TYPE      EC2 instance type (default: c7i.24xlarge — see SIZING)
#   --persistent              Stop instead of terminate on harness-down
#   --root-volume-size GB     Root EBS volume size in GB (default: 100)
#   --data-volume-size GB     /data EBS volume size in GB (default: 600 — see SIZING;
#                             pass 0 to skip for a light bench).
#                             When set, attaches a gp3 EBS at /dev/sdb with 6000 IOPS
#                             and cloud-init mounts it at /data + sets Docker data-root
#                             to /data/docker BEFORE apt installs docker.io.
#                             See benchmarks-2on for full Pool A rationale.
#
# SIZING — defaults are tuned for the CyberGym hermetic pool, NOT one-size-fits-all
# (bd benchmarks-b51, operator 2026-06-16; design docs/research/ec2-harness-design.md):
#   The CyberGym bounded worker pool is the HEAVY profile — each concurrent task is a
#   C/C++ build + ASan + a docker-in-docker OpenHands runtime + a task-local grading
#   server + grader containers. For N≈16-24 it needs c7i.24xlarge-class CPU (96 vCPU)
#   AND a sized /data (docker data-root + workspaces ≈ N×15 GB + base images; 600 GB
#   covers N≈24 + headroom). This box launches ON-DEMAND (NOT spot): a powered run is
#   ~1.5-3 h and a spot reclaim mid-run would waste it (per-task S3 resume mitigates
#   but on-demand removes the risk for a few dollars on a one-off run).
#   LIGHTER benches must override: e.g. Pool B lm-eval (decode-bound, near-nil
#   per-task disk) → `--instance-type m6i.xlarge --data-volume-size 0`; the 3xi.2
#   coding bench sizes on its own runtime profile. Do NOT impose this SKU on them.
#   --bootstrap-timeout SEC   Seconds to wait for bootstrap.ok sentinel (default: 1200)
#   --profile NAME            AWS CLI profile (default: credential chain)
#   --region NAME             AWS region (default: us-east-1, forced)
#   --connect                 Auto-connect via SSM after launch
#   --debug                   Enable debug-level log output and set -x
#   -h, --help                Show this help message
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
readonly SCRIPT_NAME="harness-up.sh"
readonly REGION="us-east-1"
readonly ACCOUNT_ID="<AWS_ACCOUNT_ID>"
readonly FALLBACK_VPC_ID="<VPC_ID>"
# Private workload subnet (aws-baseline-private-subnet-1-prod, 10.0.10/24, AZ-a).
# NACL <NACL_ID> has unrestricted egress (rule 100 = allow ALL 0.0.0.0/0),
# so outbound :22 to rental boxes works. The corporate subnet (10.0.20/24) was
# previously used and had a strict allow-list NACL that blocked outbound :22 (v7x).
readonly FALLBACK_SUBNET_ID="<SUBNET_ID>"
# IAM_ROLE_NAME lives in harness-bootstrap.sh / harness-down.sh now — the slim
# launcher only passes the INSTANCE_PROFILE_NAME to run-instances (bd <CAMPAIGN>).
readonly INSTANCE_PROFILE_NAME="harness-driver-profile"
readonly S3_BUCKET="<RESULTS_BUCKET>"
readonly SG_NAME="harness-eval-sg"
readonly UBUNTU_OWNER="099720109477"
readonly UBUNTU_AMI_FILTER="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
readonly LOG_FILE="/tmp/harness-up-$(date +%Y%m%d-%H%M%S).log"

# ============================================================
# Defaults
# ============================================================
CAMPAIGN="default"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
# Default SKU/storage = the CyberGym hermetic-pool powered-run host (bd benchmarks-b51,
# operator 2026-06-16): c7i.24xlarge (96 vCPU) ON-DEMAND + a 600 GB /data volume sized
# for N≈16-24 concurrent C/C++ build+ASan+docker tasks (≈ N×15 GB + base images). Lighter
# benches MUST override --instance-type / --data-volume-size (see SIZING in the header).
INSTANCE_TYPE="c7i.24xlarge"
PERSISTENT=false
ROOT_VOLUME_SIZE=100
DATA_VOLUME_SIZE=600
BOOTSTRAP_TIMEOUT_SEC=1200
# Honor an exported AWS_PROFILE (the --profile flag still overrides). The old
# unconditional AWS_PROFILE="" clobbered an exported value, producing
# "config profile () could not be found" for callers who set it via env (bd <CAMPAIGN>).
AWS_PROFILE="${AWS_PROFILE:-}"
AUTO_CONNECT=false
LOG_LEVEL="info"
# AMI_ID and SUBNET_ID are set during resolve_ami / resolve_network;
# initialized here so set -u is happy when an existing instance is reused.
AMI_ID=""
SUBNET_ID=""
SG_ID=""
VPC_ID=""
INSTANCE_ID=""

# ============================================================
# Logging
# ============================================================
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line="[harness][${level}][${ts}] message=${msg} campaign=${CAMPAIGN}"
  printf '%s\n' "${line}" | tee -a "${LOG_FILE}" >&2
}
log_info()  { log "info"  "$@"; }
log_warn()  { log "warn"  "$@"; }
log_error() { log "error" "$@"; }
log_debug() { [[ "${LOG_LEVEL}" == "debug" ]] && log "debug" "$@" || true; }

# ============================================================
# Error / Exit traps
# ============================================================
_ERR_FILE="/tmp/harness-up-error-$(date +%Y%m%d-%H%M%S).err"
_err_trap() {
  local exit_code=$?
  local line_no="${1:-}"
  log_error "Unhandled error at line ${line_no} (exit=${exit_code})"
  {
    printf 'script=%s\n' "${SCRIPT_NAME}"
    printf 'campaign=%s\n' "${CAMPAIGN}"
    printf 'exit_code=%s\n' "${exit_code}"
    printf 'line=%s\n' "${line_no}"
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'log=%s\n' "${LOG_FILE}"
  } > "${_ERR_FILE}"
  log_error "Bug report written to ${_ERR_FILE}"
}
trap '_err_trap ${LINENO}' ERR

_exit_trap() {
  log_debug "EXIT trap fired"
}
trap '_exit_trap' EXIT

# ============================================================
# AWS CLI wrapper — honors --profile
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
# Usage: retry_aws <max_attempts> <cmd...>
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
    log_warn "Attempt ${attempt}/${max_attempts} failed (exit=${exit_code}); retrying in ${delay}s…"
    sleep "${delay}"
    (( attempt++ ))
    (( delay = delay * 2 > 60 ? 60 : delay * 2 ))
  done
}

# Persisted campaign registry (bd benchmarks-iwa) — records a durable 'launched' event
# to S3 so the box survives in harness-campaigns.sh even after teardown. Best-effort;
# guarded so a missing helper never aborts a launch.
if [[ -f "${SCRIPT_DIR}/_harness_registry.sh" ]]; then
  # shellcheck source=scripts/_harness_registry.sh
  source "${SCRIPT_DIR}/_harness_registry.sh"
fi

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
      --campaign)    CAMPAIGN="$2";       shift 2 ;;
      --ssh-key)     SSH_KEY_PATH="$2";   shift 2 ;;
      --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
      --persistent)  PERSISTENT=true;     shift   ;;
      --root-volume-size) ROOT_VOLUME_SIZE="$2"; shift 2 ;;
      --data-volume-size) DATA_VOLUME_SIZE="$2"; shift 2 ;;
      --bootstrap-timeout) BOOTSTRAP_TIMEOUT_SEC="$2"; shift 2 ;;
      --profile)     AWS_PROFILE="$2";    shift 2 ;;
      --region)
        if [[ "$2" != "${REGION}" ]]; then
          log_warn "Region forced to ${REGION} per design; ignoring --region $2"
        fi
        shift 2
        ;;
      --connect)     AUTO_CONNECT=true;   shift   ;;
      --debug)       LOG_LEVEL="debug";   set -x; shift ;;
      -h|--help)     usage ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done
}

# ============================================================
# Pre-flight checks
# ============================================================
preflight_checks() {
  log_info "Running pre-flight checks"

  # Verify required tools
  local required_tools=("aws" "jq" "ssh-keygen")
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
  log_debug "Required tools present: ${required_tools[*]}"

  # Validate SSH key
  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    log_error "SSH public key file not found: ${SSH_KEY_PATH}"
    log_error "Provide a valid path with --ssh-key PATH"
    exit 1
  fi
  local key_contents
  key_contents="$(< "${SSH_KEY_PATH}")"
  if [[ ! "${key_contents}" =~ ^(ssh-|ecdsa-) ]]; then
    log_error "File does not look like an SSH public key: ${SSH_KEY_PATH}"
    exit 1
  fi
  log_debug "SSH key OK: ${SSH_KEY_PATH}"

  # Validate campaign name (alphanumeric + hyphen/underscore only)
  if [[ ! "${CAMPAIGN}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Campaign name must be alphanumeric with hyphens/underscores only: ${CAMPAIGN}"
    exit 1
  fi

  log_info "Pre-flight checks passed"
}

# ============================================================
# Identity verification
# ============================================================
verify_identity() {
  log_info "Verifying AWS caller identity"

  local identity_json
  identity_json="$(retry_aws 3 aws_cmd sts get-caller-identity --output json)"

  local actual_account
  actual_account="$(printf '%s' "${identity_json}" | jq -r '.Account')"

  if [[ "${actual_account}" != "${ACCOUNT_ID}" ]]; then
    log_error "Account mismatch: expected=${ACCOUNT_ID} actual=${actual_account}"
    log_error "Refusing to deploy to wrong account. Check --profile or AWS credential chain."
    exit 1
  fi

  local caller_arn
  caller_arn="$(printf '%s' "${identity_json}" | jq -r '.Arn')"
  log_info "Authenticated as ${caller_arn} in account ${actual_account}"
}

# ============================================================
# VPC / Subnet resolution
# ============================================================
resolve_network() {
  log_info "Resolving VPC and subnet"

  # F-T1-8: explicit if/else instead of command || VAR="" pattern
  # Try SSM first
  local vpc_tmp
  if vpc_tmp="$(retry_aws 3 aws_cmd ssm get-parameter \
    --name '/infrastructure/vpc/id' \
    --query 'Parameter.Value' --output text 2>/dev/null)"; then
    VPC_ID="${vpc_tmp}"
  else
    VPC_ID=""
  fi

  if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
    log_warn "SSM /infrastructure/vpc/id not found; falling back to constant ${FALLBACK_VPC_ID}"
    VPC_ID="${FALLBACK_VPC_ID}"
  else
    log_info "VPC resolved from SSM: ${VPC_ID}"
  fi

  # Try SSM for subnet (returns comma-separated list; pick first).
  # We use the *private* workload subnets (general NAT egress, no NACL port
  # allow-list) — not corporate (locked-down NACL for internal services).
  # See v7x: putting the harness in corporate blocked outbound :22.
  local ssm_subnets
  if ssm_subnets="$(retry_aws 3 aws_cmd ssm get-parameter \
    --name '/infrastructure/vpc/private_subnet_ids' \
    --query 'Parameter.Value' --output text 2>/dev/null)"; then
    : # ssm_subnets set above
  else
    ssm_subnets=""
  fi

  if [[ -z "${ssm_subnets}" || "${ssm_subnets}" == "None" ]]; then
    log_warn "SSM /infrastructure/vpc/private_subnet_ids not found; falling back to constant ${FALLBACK_SUBNET_ID}"
    SUBNET_ID="${FALLBACK_SUBNET_ID}"
  else
    SUBNET_ID="$(printf '%s' "${ssm_subnets}" | cut -d',' -f1 | tr -d '[:space:]')"
    log_info "Subnet resolved from SSM: ${SUBNET_ID} (first of: ${ssm_subnets})"
  fi
}

# ============================================================
# AMI resolution — latest Ubuntu 24.04
# ============================================================
resolve_ami() {
  log_info "Resolving latest Ubuntu 24.04 AMI"

  AMI_ID="$(retry_aws 3 aws_cmd ec2 describe-images \
    --owners "${UBUNTU_OWNER}" \
    --filters "Name=name,Values=${UBUNTU_AMI_FILTER}" \
              "Name=state,Values=available" \
              "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)"

  if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
    log_error "Could not resolve Ubuntu 24.04 AMI from owner ${UBUNTU_OWNER}"
    exit 1
  fi
  log_info "Resolved AMI: ${AMI_ID}"
}

# ============================================================
# Verify day-to-day prerequisites (DESCRIBE only — bd <CAMPAIGN>)
#
# The IAM role/instance-profile, security group, and results bucket are created
# ONCE by scripts/harness-bootstrap.sh under admin creds. This launcher only needs
# to find the SG (to pass --security-group-ids to run-instances); it deliberately
# does NOT introspect IAM (the least-privilege launcher policy holds iam:PassRole
# only — no iam:GetRole/GetInstanceProfile), so a missing role/profile surfaces as
# a clear run-instances failure handled in launch_instance(). Fails fast here if
# the SG is absent, pointing the operator back at harness-bootstrap.sh.
# ============================================================
verify_prereqs() {
  log_info "Verifying day-to-day prerequisites (describe-only)"

  SG_ID="$(retry_aws 3 aws_cmd ec2 describe-security-groups \
    --filters "Name=tag:Component,Values=eval-harness" \
              "Name=tag:ManagedBy,Values=${SCRIPT_NAME}" \
              "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)" || SG_ID=""

  if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
    log_error "Security group ${SG_NAME} (tag Component=eval-harness, ManagedBy=${SCRIPT_NAME}) not found in VPC ${VPC_ID}."
    log_error "This account has not been bootstrapped. Run ONCE under IAM-admin creds:"
    log_error "    ${REPO_ROOT}/scripts/harness-bootstrap.sh --profile iptadmin"
    log_error "That creates the harness-driver-role + instance profile, the ${SG_NAME} SG, and the ${S3_BUCKET} bucket."
    exit 1
  fi
  log_info "Security group found: ${SG_ID}"
  log_info "Assuming role/profile ${INSTANCE_PROFILE_NAME} + bucket ${S3_BUCKET} exist (created by harness-bootstrap.sh)"
}

# ============================================================
# F-T1-1: Find an existing instance for this campaign
# Returns: sets INSTANCE_ID and EXISTING_INSTANCE_STATE if found;
#          sets INSTANCE_ID="" if none found.
# ============================================================
find_existing_instance() {
  log_info "Checking for existing instance campaign=${CAMPAIGN}"

  local result
  result="$(retry_aws 3 aws_cmd ec2 describe-instances \
    --filters \
      "Name=tag:Campaign,Values=${CAMPAIGN}" \
      "Name=tag:Component,Values=eval-harness" \
      "Name=instance-state-name,Values=stopped,running,pending" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
    --output text 2>/dev/null)" || result=""

  if [[ -z "${result}" || "${result}" == "None" ]]; then
    log_info "No existing instance found for campaign=${CAMPAIGN}"
    INSTANCE_ID=""
    EXISTING_INSTANCE_STATE=""
    return 0
  fi

  INSTANCE_ID="$(printf '%s' "${result}" | awk '{print $1}' | head -1)"
  EXISTING_INSTANCE_STATE="$(printf '%s' "${result}" | awk '{print $2}' | head -1)"

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    INSTANCE_ID=""
    EXISTING_INSTANCE_STATE=""
    return 0
  fi

  log_info "Found existing instance id=${INSTANCE_ID} state=${EXISTING_INSTANCE_STATE}"

  # Overwrite state file with discovered ID
  local state_file="/tmp/harness-instance-${CAMPAIGN}.id"
  printf '%s\n' "${INSTANCE_ID}" > "${state_file}"
  log_info "State file updated: ${state_file}"
}

# ============================================================
# Render cloud-init user-data
# ============================================================
render_user_data() {
  log_info "Rendering cloud-init user-data"

  local template="${REPO_ROOT}/cloud-init/harness-bootstrap.yaml"
  if [[ ! -f "${template}" ]]; then
    log_error "cloud-init template not found: ${template}"
    exit 1
  fi

  # install-harness.sh is no longer embedded in user-data — it's pushed via
  # SSM after bootstrap.ok lands (push_install_harness_via_ssm). The script
  # plus 2on.1-.3 additions exceeded the 16,384-byte gzipped user-data cap.
  local install_harness_script="${REPO_ROOT}/scripts/install-harness.sh"
  if [[ ! -f "${install_harness_script}" ]]; then
    log_error "install-harness.sh not found at ${install_harness_script}; cannot stage for SSM push"
    exit 1
  fi

  local ssh_key_contents
  ssh_key_contents="$(< "${SSH_KEY_PATH}")"

  # Substitute placeholders — awk avoids eval and shell injection.
  USER_DATA_RENDERED="$(awk \
    -v key="${ssh_key_contents}" \
    '{
       gsub(/\$\{SSH_KEY_FILE_CONTENTS\}/, key);
       print
     }' "${template}")"

  # AWS user-data is capped at 16,384 bytes RAW (post-decode). cloud-init
  # auto-decompresses payloads that start with the gzip magic byte sequence,
  # so we gzip the rendered YAML and hand AWS CLI the binary via fileb://.
  # AWS CLI base64-encodes for transport; cloud-init decompresses on the
  # instance. Drops ~17 KB to ~5-6 KB; well under both 16,384 raw and
  # 25,600 encoded limits.
  USER_DATA_GZ="$(mktemp -t harness-userdata-XXXXXX.gz)"
  printf '%s' "${USER_DATA_RENDERED}" | gzip -9c > "${USER_DATA_GZ}"
  local raw_size=${#USER_DATA_RENDERED}
  local gz_size
  gz_size="$(wc -c < "${USER_DATA_GZ}")"
  log_info "User-data rendered: ${raw_size} bytes raw -> ${gz_size} bytes gzip'd (limit 16384 raw)"
  if (( gz_size > 16384 )); then
    log_error "Compressed user-data ${gz_size} bytes still exceeds 16384 limit; trim cloud-init or split bootstrap into a stage-2 fetch"
    rm -f "${USER_DATA_GZ}"
    exit 1
  fi
}

# ============================================================
# Launch instance
# ============================================================
launch_instance() {
  # ON-DEMAND launch (no --instance-market-options spot). Deliberate per bd
  # benchmarks-b51 (operator 2026-06-16): a CyberGym powered run is ~1.5-3 h and a
  # spot reclaim mid-run would waste it. Do NOT add spot market options to this path.
  log_info "Launching EC2 instance (type=${INSTANCE_TYPE}, ON-DEMAND, campaign=${CAMPAIGN})"

  local shutdown_behavior="terminate"
  local delete_on_term="true"
  if "${PERSISTENT}"; then
    shutdown_behavior="stop"
    delete_on_term="false"
    log_info "Persistent mode: shutdown-behavior=stop, EBS delete-on-termination=false"
  fi

  # Build block device mappings — root always, /data EBS optional.
  # /data is attached at /dev/sdb (Nitro presents as /dev/nvme1n1) with
  # 6000 provisioned IOPS to keep `docker pull` of large image sets (Pool A
  # SEC-bench/CVE-Bench, ~250 GB) from being IOPS-bottlenecked. See benchmarks-2on.
  local block_devs="[{
      \"DeviceName\": \"/dev/sda1\",
      \"Ebs\": {
        \"VolumeSize\": ${ROOT_VOLUME_SIZE},
        \"VolumeType\": \"gp3\",
        \"DeleteOnTermination\": ${delete_on_term},
        \"Encrypted\": true
      }
    }"
  if (( DATA_VOLUME_SIZE > 0 )); then
    log_info "Attaching /data EBS volume: ${DATA_VOLUME_SIZE} GB gp3 (6000 IOPS) at /dev/sdb"
    block_devs+=", {
      \"DeviceName\": \"/dev/sdb\",
      \"Ebs\": {
        \"VolumeSize\": ${DATA_VOLUME_SIZE},
        \"VolumeType\": \"gp3\",
        \"Iops\": 6000,
        \"DeleteOnTermination\": ${delete_on_term},
        \"Encrypted\": true
      }
    }"
  fi
  block_devs+="]"

  # Capture run-instances failure explicitly so an IAM error (the most likely
  # cause for the day-to-day launcher) gets an actionable hint rather than an
  # opaque ERR-trap exit. bd <CAMPAIGN>.
  local run_rc=0
  INSTANCE_ID="$(retry_aws 3 aws_cmd ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${SG_ID}" \
    --iam-instance-profile Name="${INSTANCE_PROFILE_NAME}" \
    --user-data "fileb://${USER_DATA_GZ}" \
    --instance-initiated-shutdown-behavior "${shutdown_behavior}" \
    --metadata-options \
      "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled,InstanceMetadataTags=enabled" \
    --block-device-mappings "${block_devs}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[
        {Key=Name,Value=harness-${CAMPAIGN}},
        {Key=Project,Value=benchmarks},
        {Key=Component,Value=eval-harness},
        {Key=Campaign,Value=${CAMPAIGN}},
        {Key=ManagedBy,Value=${SCRIPT_NAME}},
        {Key=Persistent,Value=${PERSISTENT}}
      ]" \
      "ResourceType=volume,Tags=[
        {Key=Project,Value=benchmarks},
        {Key=Component,Value=eval-harness},
        {Key=Campaign,Value=${CAMPAIGN}},
        {Key=ManagedBy,Value=${SCRIPT_NAME}}
      ]" \
    --query 'Instances[0].InstanceId' --output text)" || run_rc=$?

  if (( run_rc != 0 )) || [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    log_error "run-instances failed (exit=${run_rc}) — no instance launched."
    log_error "Most common cause for the day-to-day launcher: an IAM error on"
    log_error "  --iam-instance-profile Name=${INSTANCE_PROFILE_NAME} (iam:PassRole denied, or the"
    log_error "  role/instance-profile does not exist yet). The account may not be bootstrapped."
    log_error "Fix: run ONCE under IAM-admin creds —"
    log_error "    ${REPO_ROOT}/scripts/harness-bootstrap.sh --profile iptadmin"
    log_error "(also grants the launcher the least-privilege harness-launcher policy)."
    exit 1
  fi

  log_info "Instance launched: ${INSTANCE_ID}"

  # Save state file
  local state_file="/tmp/harness-instance-${CAMPAIGN}.id"
  printf '%s\n' "${INSTANCE_ID}" > "${state_file}"
  log_info "Instance ID saved to ${state_file}"

  # Durable launch record (bd benchmarks-iwa) — survives teardown, unlike the local
  # state file above. Best-effort: never fails the launch.
  if declare -F harness_registry_append >/dev/null 2>&1; then
    harness_registry_append launched "${CAMPAIGN}" "${INSTANCE_ID}" "${INSTANCE_TYPE}" || true
  fi
  # TODO(T2-8): add fallback git remote for benchmarks repo clone at cloud-init if primary fails
  # TODO(T3-3): clean up orphaned /tmp/harness-instance-*.id files older than N days
}

# ============================================================
# Wait for instance + system reachability
# ============================================================
wait_for_instance() {
  log_info "Waiting for instance-status-ok (${INSTANCE_ID})"
  retry_aws 5 aws_cmd ec2 wait instance-status-ok \
    --instance-ids "${INSTANCE_ID}"
  log_info "Instance status: OK"
}

# ============================================================
# F-T2-3: Wait for SSM agent to register before sending commands
# ============================================================
wait_for_ssm_agent() {
  log_info "Waiting for SSM agent to register (timeout=300s)"
  local deadline=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < deadline )); do
    local ssm_count
    ssm_count="$(retry_aws 3 aws_cmd ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'length(InstanceInformationList)' --output text 2>/dev/null)" || ssm_count="0"
    if [[ "${ssm_count}" =~ ^[0-9]+$ ]] && (( ssm_count >= 1 )); then
      log_info "SSM agent registered for ${INSTANCE_ID}"
      return 0
    fi
    log_debug "SSM agent not yet registered; waiting 5s"
    sleep 5
  done
  log_warn "SSM agent did not register within 300s; proceeding anyway (bootstrap poll may retry)"
}

# ============================================================
# F-T1-5: Consolidated bootstrap sentinel poll (one SSM call per attempt)
# F-T2-2: Uses BOOTSTRAP_TIMEOUT_SEC variable (default 1200)
# ============================================================
poll_bootstrap_sentinel() {
  log_info "Polling for /var/lib/harness/bootstrap.ok via SSM (timeout=${BOOTSTRAP_TIMEOUT_SEC}s)"

  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SEC ))
  local attempt=0
  local sleep_interval=15

  while (( $(date +%s) < deadline )); do
    # Pre-increment, not post-: with `set -e`, post-increment from 0 returns
    # exit 1 (the OLD value 0 == false), aborting the script.
    (( ++attempt ))

    # F-T1-5: Single SSM send-command fetches both sentinel files, split on ---DELIM---
    local cmd_id
    cmd_id="$(retry_aws 3 aws_cmd ssm send-command \
      --instance-ids "${INSTANCE_ID}" \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["cat /var/lib/harness/bootstrap.ok 2>/dev/null; echo ---DELIM---; cat /var/lib/harness/bootstrap.err 2>/dev/null; true"]' \
      --query 'Command.CommandId' --output text 2>/dev/null)" || {
      log_debug "SSM send-command not yet ready (attempt ${attempt}); waiting ${sleep_interval}s"
      sleep "${sleep_interval}"
      continue
    }

    # Brief wait for command to execute
    sleep 5

    local cmd_status
    cmd_status="$(retry_aws 3 aws_cmd ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null)" || cmd_status="Pending"

    log_debug "SSM command ${cmd_id}: status=${cmd_status} (attempt ${attempt})"

    if [[ "${cmd_status}" == "Success" ]]; then
      local combined_output
      combined_output="$(retry_aws 3 aws_cmd ssm get-command-invocation \
        --command-id "${cmd_id}" \
        --instance-id "${INSTANCE_ID}" \
        --query 'StandardOutputContent' --output text)"

      # Split on ---DELIM--- to get ok_content and err_content
      local ok_content err_content
      ok_content="$(printf '%s' "${combined_output}" | awk 'BEGIN{p=1} /^---DELIM---/{p=0;next} p{print}')"
      err_content="$(printf '%s' "${combined_output}" | awk 'BEGIN{p=0} /^---DELIM---/{p=1;next} p{print}')"

      if [[ -n "${err_content}" ]]; then
        log_error "Bootstrap failed! Error content: ${err_content}"
        log_error "Tail full log: aws ssm start-session --target ${INSTANCE_ID}"
        log_error "  Then: tail -f /var/log/harness-bootstrap.log"
        exit 1
      fi

      if [[ -n "${ok_content}" ]]; then
        log_info "Bootstrap sentinel found: ${ok_content}"
        return 0
      fi
    fi

    local elapsed=$(( $(date +%s) - (deadline - BOOTSTRAP_TIMEOUT_SEC) ))
    log_info "Bootstrap not yet complete (${elapsed}s elapsed); waiting ${sleep_interval}s…"
    sleep "${sleep_interval}"
  done

  log_error "Timed out waiting for bootstrap.ok after ${BOOTSTRAP_TIMEOUT_SEC}s"
  log_error "Connect and check: aws ssm start-session --target ${INSTANCE_ID}"
  log_error "  Then: tail -f /var/log/harness-bootstrap.log"
  exit 1
}

# ============================================================
# Push install-harness.sh via SSM after bootstrap.ok lands.
#
# Previously the script shipped in user-data as encoding:gz+b64 (<CAMPAIGN>) but
# after 2on.1-.3 the gzipped+b64 payload + cloud-init template exceeds AWS's
# 16,384-byte user-data cap. Cloud-init now lays down everything except
# install-harness.sh, and this function bridges the gap via SSM send-command
# (max ~64 KB total parameter payload — install-harness.sh is ~39 KB raw,
# ~11 KB gzip+b64, well within).
# ============================================================
push_install_harness_via_ssm() {
  local script_path="${REPO_ROOT}/scripts/install-harness.sh"
  if [[ ! -f "${script_path}" ]]; then
    log_error "install-harness.sh not found at ${script_path}; cannot push to harness"
    exit 1
  fi

  log_info "Pushing install-harness.sh to ${INSTANCE_ID}:/opt/benchmarks/scripts/install-harness.sh via SSM"

  local gzb64
  gzb64="$(gzip -9c < "${script_path}" | base64 -w0)"

  # build the remote shell command. cloud-init owns /opt/benchmarks/scripts
  # already (root:root, 0755) — bootstrap.ok would not have fired otherwise.
  # AWS-RunShellScript invokes /bin/sh (dash); dash supports `set -eu` but
  # not `pipefail`. The base64-decode → gunzip pipeline fails loudly on
  # corrupt input (gunzip errors on a bad stream) so pipefail isn't needed.
  local remote_cmd
  remote_cmd="set -eu; \
mkdir -p /opt/benchmarks/scripts; \
printf '%s' '${gzb64}' | base64 -d | gunzip > /opt/benchmarks/scripts/install-harness.sh; \
chmod 0755 /opt/benchmarks/scripts/install-harness.sh; \
chown root:root /opt/benchmarks/scripts/install-harness.sh; \
echo install-harness.sh installed: \$(wc -c < /opt/benchmarks/scripts/install-harness.sh) bytes"

  # AWS CLI's --parameters parser handles long values fine but the shell here
  # would expand them; use --cli-input-json for the payload to keep the gzb64
  # value out of argv (also avoids quoting headaches with the embedded "'").
  local params_json
  params_json="$(jq -n --arg cmd "${remote_cmd}" --arg iid "${INSTANCE_ID}" '{
    InstanceIds: [ $iid ],
    DocumentName: "AWS-RunShellScript",
    Parameters: { commands: [ $cmd ] }
  }')"

  local cmd_id
  cmd_id="$(retry_aws 3 aws_cmd ssm send-command \
    --cli-input-json "${params_json}" \
    --query 'Command.CommandId' --output text)"

  # poll for completion (script copy should be sub-second; allow 60s)
  local deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    sleep 2
    local status
    status="$(retry_aws 3 aws_cmd ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null)" || status="Pending"
    case "${status}" in
      Success)
        local stdout
        stdout="$(retry_aws 3 aws_cmd ssm get-command-invocation \
          --command-id "${cmd_id}" \
          --instance-id "${INSTANCE_ID}" \
          --query 'StandardOutputContent' --output text)"
        log_info "install-harness.sh pushed: ${stdout}"
        return 0
        ;;
      Failed|Cancelled|TimedOut)
        local stderr
        stderr="$(retry_aws 3 aws_cmd ssm get-command-invocation \
          --command-id "${cmd_id}" \
          --instance-id "${INSTANCE_ID}" \
          --query 'StandardErrorContent' --output text)"
        log_error "install-harness.sh push failed (status=${status}): ${stderr}"
        exit 1
        ;;
    esac
  done

  log_error "Timed out waiting for install-harness.sh SSM push (cmd_id=${cmd_id})"
  exit 1
}

# ============================================================
# Deliver scripts/runners + scripts/patches to the box via S3 (bd 9g4.5)
#
# install-harness.sh references ${SCRIPT_DIR}/runners and ${SCRIPT_DIR}/patches
# (= /opt/benchmarks/scripts/{runners,patches}) and the sweep needs the runners,
# but nothing in the automated path used to deliver them — every launch silently
# required a manual `rsync ~/benchmarks/scripts/ ubuntu@<id>:/opt/benchmarks/scripts/`.
# The payload (~150 KB) exceeds the ~64 KB SSM single-command cap, so we stage it
# through S3: the launcher uploads a tarball (s3:PutObject — in the launcher policy)
# and the box pulls it with its instance role (s3:GetObject — already granted, the
# same path result-sync uses). End-to-end sha256-verified.
# ============================================================
push_repo_scripts_via_s3() {
  local runners_dir="${REPO_ROOT}/scripts/runners"
  local patches_dir="${REPO_ROOT}/scripts/patches"
  if [[ ! -d "${runners_dir}" || ! -d "${patches_dir}" ]]; then
    log_error "scripts/runners or scripts/patches missing under ${REPO_ROOT}/scripts; cannot deliver to box"
    exit 1
  fi

  log_info "Delivering scripts/runners + scripts/patches to ${INSTANCE_ID}:/opt/benchmarks/scripts via S3"

  # Deterministic tarball (sorted, fixed owner/mtime) so the sha is stable per tree.
  local tarball sha s3_key s3_uri
  tarball="$(mktemp -t harness-scripts-XXXXXX.tgz)"
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
    -czf "${tarball}" -C "${REPO_ROOT}/scripts" runners patches 2>/dev/null \
    || tar -czf "${tarball}" -C "${REPO_ROOT}/scripts" runners patches
  sha="$(sha256sum "${tarball}" | awk '{print $1}')"
  s3_key="_bootstrap/${CAMPAIGN}/scripts-${sha}.tgz"
  s3_uri="s3://${S3_BUCKET}/${s3_key}"

  log_info "Uploading runners+patches tarball ($(wc -c < "${tarball}") bytes, sha256=${sha:0:12}…) to ${s3_uri}"
  if ! retry_aws 3 aws_cmd s3 cp "${tarball}" "${s3_uri}"; then
    log_error "Failed to upload scripts tarball to ${s3_uri} — the launcher needs s3:PutObject on ${S3_BUCKET}."
    log_error "If this is AccessDenied, run scripts/harness-bootstrap.sh once (admin) to grant the launcher policy."
    rm -f "${tarball}"
    exit 1
  fi
  rm -f "${tarball}"

  # On-box: pull via the instance role, verify sha, extract into /opt/benchmarks/scripts.
  # AWS-RunShellScript runs as root under /bin/sh; aws is at /usr/local/bin/aws
  # (cloud-init symlink) or via /snap/bin. sha256sum + tar are coreutils (always present).
  local remote_cmd
  remote_cmd="set -eu; \
export PATH=/usr/local/bin:/snap/bin:\$PATH; \
mkdir -p /opt/benchmarks/scripts; \
aws s3 cp '${s3_uri}' /tmp/harness-scripts.tgz --region '${REGION}'; \
echo '${sha}  /tmp/harness-scripts.tgz' | sha256sum -c -; \
tar -xzf /tmp/harness-scripts.tgz -C /opt/benchmarks/scripts; \
chown -R root:root /opt/benchmarks/scripts/runners /opt/benchmarks/scripts/patches; \
rm -f /tmp/harness-scripts.tgz; \
test -f /opt/benchmarks/scripts/runners/run-pool-b.sh; \
echo runners-delivered: \$(find /opt/benchmarks/scripts/runners -type f | wc -l) runner files, \$(find /opt/benchmarks/scripts/patches -type f | wc -l) patches"

  local params_json cmd_id
  params_json="$(jq -n --arg cmd "${remote_cmd}" --arg iid "${INSTANCE_ID}" '{
    InstanceIds: [ $iid ],
    DocumentName: "AWS-RunShellScript",
    Parameters: { commands: [ $cmd ] }
  }')"
  cmd_id="$(retry_aws 3 aws_cmd ssm send-command \
    --cli-input-json "${params_json}" \
    --query 'Command.CommandId' --output text)"

  local deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    sleep 3
    local status
    status="$(retry_aws 3 aws_cmd ssm get-command-invocation \
      --command-id "${cmd_id}" --instance-id "${INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null)" || status="Pending"
    case "${status}" in
      Success)
        local stdout
        stdout="$(retry_aws 3 aws_cmd ssm get-command-invocation \
          --command-id "${cmd_id}" --instance-id "${INSTANCE_ID}" \
          --query 'StandardOutputContent' --output text)"
        log_info "runner scripts delivered: ${stdout}"
        return 0
        ;;
      Failed|Cancelled|TimedOut)
        local stderr
        stderr="$(retry_aws 3 aws_cmd ssm get-command-invocation \
          --command-id "${cmd_id}" --instance-id "${INSTANCE_ID}" \
          --query 'StandardErrorContent' --output text)"
        log_error "runner scripts delivery failed (status=${status}): ${stderr}"
        exit 1
        ;;
    esac
  done
  log_error "Timed out waiting for runner scripts S3 delivery (cmd_id=${cmd_id})"
  exit 1
}

# ============================================================
# Deliver everything the box needs after bootstrap.ok: install-harness.sh (SSM
# gz+b64) + the runner/patch scripts (S3-staged). bd 9g4.5.
# ============================================================
deliver_to_box() {
  push_install_harness_via_ssm
  push_repo_scripts_via_s3
}

# ============================================================
# SSH-over-SSM config
# ============================================================
append_ssh_config() {
  log_info "Ensuring SSH-over-SSM ProxyCommand block in ~/.ssh/config"

  local ssh_config="${HOME}/.ssh/config"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  # F-T2-4: grep for the exact sentinel comment line, not the generic Host i-* directive
  # The block STARTS with the sentinel comment so subsequent runs detect it reliably.
  if ! grep -q '# Eval-harness SSH-over-SSM (auto-added by harness-up.sh)' "${ssh_config}" 2>/dev/null; then
    local profile_arg=""
    [[ -n "${AWS_PROFILE}" ]] && profile_arg=" --profile ${AWS_PROFILE}"

    cat >> "${ssh_config}" << SSH_BLOCK

# Eval-harness SSH-over-SSM (auto-added by harness-up.sh)
# Allows: ssh ubuntu@<instance-id>  (no open ingress required)
Host i-*
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'${profile_arg}
  User ubuntu
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/harness_known_hosts
SSH_BLOCK
    chmod 600 "${ssh_config}"
    log_info "SSH-over-SSM config appended to ${ssh_config}"
  else
    log_debug "SSH-over-SSM block already present in ${ssh_config} (sentinel comment found)"
  fi
}

# ============================================================
# Print connect instructions
# ============================================================
print_connect_info() {
  local profile_arg=""
  [[ -n "${AWS_PROFILE}" ]] && profile_arg=" --profile ${AWS_PROFILE}"

  printf '\n'
  printf '=%.0s' {1..60}; printf '\n'
  printf 'Eval-harness ready\n'
  printf '=%.0s' {1..60}; printf '\n'
  printf 'Instance:   %s\n' "${INSTANCE_ID}"
  printf 'Campaign:   %s\n' "${CAMPAIGN}"
  printf 'Type:       %s\n' "${INSTANCE_TYPE}"
  printf 'AMI:        %s\n' "${AMI_ID:-<existing-instance>}"
  printf 'Subnet:     %s\n' "${SUBNET_ID}"
  printf 'Persistent: %s\n' "${PERSISTENT}"
  printf '\n'
  printf 'SSH connect (via SSM ProxyCommand):\n'
  printf '  ssh ubuntu@%s\n' "${INSTANCE_ID}"
  printf '\n'
  printf 'SSM session (no SSH):\n'
  printf '  aws ssm start-session --target %s%s\n' "${INSTANCE_ID}" "${profile_arg}"
  printf '\n'
  printf 'Install harnesses (after SSH):\n'
  printf '  ssh ubuntu@%s\n' "${INSTANCE_ID}"
  printf '  sudo /opt/benchmarks/scripts/install-harness.sh\n'
  printf '\n'
  printf 'Tear down:\n'
  printf '  %s/scripts/harness-down.sh --campaign %s\n' "${REPO_ROOT}" "${CAMPAIGN}"
  printf '=%.0s' {1..60}; printf '\n'
  printf '\n'
}

# ============================================================
# Auto-connect
# ============================================================
auto_connect() {
  if "${AUTO_CONNECT}"; then
    log_info "Auto-connecting via SSM start-session"
    local profile_arg=()
    [[ -n "${AWS_PROFILE}" ]] && profile_arg=(--profile "${AWS_PROFILE}")
    aws ssm start-session --target "${INSTANCE_ID}" \
      --region "${REGION}" "${profile_arg[@]+"${profile_arg[@]}"}"
  fi
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"

  log_info "Starting harness-up campaign=${CAMPAIGN} script=${SCRIPT_NAME}"

  preflight_checks
  verify_identity
  resolve_network
  verify_prereqs

  # F-T1-1: Check for an existing instance before launching a new one
  EXISTING_INSTANCE_STATE=""
  find_existing_instance

  if [[ -n "${INSTANCE_ID}" ]]; then
    case "${EXISTING_INSTANCE_STATE}" in
      stopped)
        log_info "Persistent instance found in stopped state — starting id=${INSTANCE_ID}"
        retry_aws 3 aws_cmd ec2 start-instances \
          --instance-ids "${INSTANCE_ID}" \
          --output text > /dev/null
        retry_aws 5 aws_cmd ec2 wait instance-running \
          --instance-ids "${INSTANCE_ID}"
        log_info "Instance running: ${INSTANCE_ID}"
        # cloud-init does NOT re-run on start; bootstrap.ok is already present
        wait_for_ssm_agent
        poll_bootstrap_sentinel
        deliver_to_box
        ;;
      running|pending)
        log_info "Instance already ${EXISTING_INSTANCE_STATE}: ${INSTANCE_ID} — skipping launch and bootstrap poll"
        # If SSM is available and bootstrap.ok present, poll is instant; otherwise skip
        wait_for_ssm_agent
        poll_bootstrap_sentinel
        deliver_to_box
        ;;
      *)
        log_warn "Unexpected existing instance state=${EXISTING_INSTANCE_STATE}; treating as new launch"
        INSTANCE_ID=""
        ;;
    esac
  fi

  if [[ -z "${INSTANCE_ID}" ]]; then
    # No existing instance — full launch path
    resolve_ami
    render_user_data
    launch_instance
    wait_for_instance
    wait_for_ssm_agent
    poll_bootstrap_sentinel
    deliver_to_box
  fi

  append_ssh_config
  print_connect_info
  auto_connect

  log_info "harness-up complete instance=${INSTANCE_ID} campaign=${CAMPAIGN}"
}

main "$@"
