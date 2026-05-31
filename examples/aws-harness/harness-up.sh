#!/usr/bin/env bash
# harness-up.sh — Idempotent EC2 launch script for the benchmarks eval-harness host
#
# Usage: harness-up.sh [OPTIONS]
#
# Options:
#   --campaign NAME           Campaign tag and instance name (default: default)
#   --ssh-key PATH            Operator SSH public key file (default: ~/.ssh/id_ed25519.pub)
#   --instance-type TYPE      EC2 instance type (default: m6i.xlarge)
#   --persistent              Stop instead of terminate on harness-down
#   --root-volume-size GB     Root EBS volume size in GB (default: 100)
#   --data-volume-size GB     Optional /data EBS volume size in GB (default: 0 = none).
#                             Recommended for Pool A: 1000 (m6i.2xlarge + 1 TB).
#                             When set, attaches a gp3 EBS at /dev/sdb with 6000 IOPS
#                             and cloud-init mounts it at /data + sets Docker data-root
#                             to /data/docker BEFORE apt installs docker.io.
#                             See benchmarks-2on for full Pool A rationale.
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
readonly IAM_ROLE_NAME="harness-driver-role"
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
INSTANCE_TYPE="m6i.xlarge"
PERSISTENT=false
ROOT_VOLUME_SIZE=100
DATA_VOLUME_SIZE=0
BOOTSTRAP_TIMEOUT_SEC=1200
AWS_PROFILE=""
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
# IAM — role, inline policy, instance profile
# ============================================================
reconcile_iam() {
  log_info "Reconciling IAM role and instance profile"

  local trust_policy
  trust_policy='{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

  # Create role if missing
  if ! retry_aws 3 aws_cmd iam get-role --role-name "${IAM_ROLE_NAME}" \
      --query 'Role.RoleName' --output text &>/dev/null; then
    log_info "Creating IAM role: ${IAM_ROLE_NAME}"
    retry_aws 3 aws_cmd iam create-role \
      --role-name "${IAM_ROLE_NAME}" \
      --assume-role-policy-document "${trust_policy}" \
      --tags "Key=Project,Value=benchmarks" \
             "Key=Component,Value=eval-harness" \
             "Key=ManagedBy,Value=${SCRIPT_NAME}" \
      --output text > /dev/null
    log_info "IAM role created"
  else
    log_debug "IAM role exists: ${IAM_ROLE_NAME}"
  fi

  # Detach managed policies (defensive — we only want inline)
  local attached_policies
  attached_policies="$(retry_aws 3 aws_cmd iam list-attached-role-policies \
    --role-name "${IAM_ROLE_NAME}" \
    --query 'AttachedPolicies[].PolicyArn' --output text)"
  if [[ -n "${attached_policies}" ]]; then
    log_warn "Detaching managed policies from ${IAM_ROLE_NAME} (inline-only design)"
    while IFS= read -r arn; do
      [[ -z "${arn}" ]] && continue
      retry_aws 3 aws_cmd iam detach-role-policy \
        --role-name "${IAM_ROLE_NAME}" --policy-arn "${arn}"
      log_info "Detached managed policy: ${arn}"
    done <<< "${attached_policies}"
  fi

  # F-T1-7: Compare existing inline policy to desired; skip put if identical.
  # This eliminates the transient 403 window on rerun for in-flight S3 PutObject calls.
  # TODO(skipped-finding): all SSM secrets fetched by this role must be under /sandbox/* to
  # match the SSMParameters Resource ARN; audit any new SSM paths added in future.
  log_info "Reconciling inline policy on ${IAM_ROLE_NAME}"
  local inline_policy
  inline_policy="{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"SSMParameters\",
        \"Effect\": \"Allow\",
        \"Action\": [\"ssm:GetParameter\", \"ssm:GetParameters\"],
        \"Resource\": \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/sandbox/*\"
      },
      {
        \"Sid\": \"S3Objects\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\"],
        \"Resource\": \"arn:aws:s3:::${S3_BUCKET}/*\"
      },
      {
        \"Sid\": \"S3Bucket\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:ListBucket\", \"s3:GetBucketLocation\"],
        \"Resource\": \"arn:aws:s3:::${S3_BUCKET}\"
      },
      {
        \"Sid\": \"Bedrock\",
        \"Effect\": \"Allow\",
        \"Action\": [\"bedrock:InvokeModel\", \"bedrock:InvokeModelWithResponseStream\"],
        \"Resource\": [
          \"arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/us.anthropic.claude-opus-4-*\",
          \"arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-*\"
        ]
      },
      {
        \"Sid\": \"KMSViaSSM\",
        \"Effect\": \"Allow\",
        \"Action\": \"kms:Decrypt\",
        \"Resource\": \"*\",
        \"Condition\": {
          \"StringEquals\": {
            \"kms:ViaService\": \"ssm.${REGION}.amazonaws.com\"
          }
        }
      },
      {
        \"Sid\": \"SSMSessionManager\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"ssmmessages:CreateControlChannel\",
          \"ssmmessages:CreateDataChannel\",
          \"ssmmessages:OpenControlChannel\",
          \"ssmmessages:OpenDataChannel\",
          \"ssm:UpdateInstanceInformation\",
          \"ec2messages:*\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Sid\": \"EC2SelfTag\",
        \"Effect\": \"Allow\",
        \"Action\": \"ec2:DescribeTags\",
        \"Resource\": \"*\"
      }
    ]
  }"

  # F-T1-7: fetch existing policy and compare via canonical jq -S sort
  local existing_policy_raw
  if existing_policy_raw="$(retry_aws 3 aws_cmd iam get-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "harness-driver-inline" \
    --query 'PolicyDocument' --output json 2>/dev/null)"; then
    # URL-decode is not needed when using --output json; jq -S gives canonical sort
    local existing_canonical desired_canonical
    existing_canonical="$(printf '%s' "${existing_policy_raw}" | jq -S '.')"
    desired_canonical="$(printf '%s' "${inline_policy}" | jq -S '.')"
    if [[ "${existing_canonical}" == "${desired_canonical}" ]]; then
      log_info "Inline policy unchanged — skipping put-role-policy (avoids transient 403 window)"
    else
      log_info "Inline policy changed — applying update"
      retry_aws 3 aws_cmd iam put-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-name "harness-driver-inline" \
        --policy-document "${inline_policy}" \
        --output text > /dev/null
      log_info "Inline policy applied"
    fi
  else
    log_info "No existing inline policy found — creating"
    retry_aws 3 aws_cmd iam put-role-policy \
      --role-name "${IAM_ROLE_NAME}" \
      --policy-name "harness-driver-inline" \
      --policy-document "${inline_policy}" \
      --output text > /dev/null
    log_info "Inline policy applied"
  fi

  # Create instance profile if missing
  if ! retry_aws 3 aws_cmd iam get-instance-profile \
      --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
      --query 'InstanceProfile.InstanceProfileName' --output text &>/dev/null; then
    log_info "Creating instance profile: ${INSTANCE_PROFILE_NAME}"
    retry_aws 3 aws_cmd iam create-instance-profile \
      --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
      --output text > /dev/null
    log_info "Instance profile created"
  else
    log_debug "Instance profile exists: ${INSTANCE_PROFILE_NAME}"
  fi

  # Add role to instance profile if not already present
  local profile_roles
  profile_roles="$(retry_aws 3 aws_cmd iam get-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --query 'InstanceProfile.Roles[].RoleName' --output text)"
  if ! printf '%s' "${profile_roles}" | grep -qw "${IAM_ROLE_NAME}"; then
    log_info "Adding ${IAM_ROLE_NAME} to instance profile"
    retry_aws 3 aws_cmd iam add-role-to-instance-profile \
      --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
      --role-name "${IAM_ROLE_NAME}"
    # IAM propagation delay
    log_info "Waiting 10s for IAM propagation"
    sleep 10
  else
    log_debug "Role already in instance profile"
  fi
}

# ============================================================
# S3 bucket reconciliation
# ============================================================
reconcile_s3() {
  log_info "Reconciling S3 bucket: ${S3_BUCKET}"

  # Create bucket if missing (404 = not found)
  if ! retry_aws 3 aws_cmd s3api head-bucket --bucket "${S3_BUCKET}" &>/dev/null; then
    log_info "Creating S3 bucket: ${S3_BUCKET}"
    retry_aws 3 aws_cmd s3api create-bucket \
      --bucket "${S3_BUCKET}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" \
      --output text > /dev/null 2>&1 || {
      # us-east-1 does not accept LocationConstraint — retry without it
      retry_aws 3 aws_cmd s3api create-bucket \
        --bucket "${S3_BUCKET}" \
        --output text > /dev/null
    }
    log_info "Bucket created"
  else
    log_debug "Bucket exists: ${S3_BUCKET}"
  fi

  # Versioning
  retry_aws 3 aws_cmd s3api put-bucket-versioning \
    --bucket "${S3_BUCKET}" \
    --versioning-configuration Status=Enabled \
    --output text > /dev/null
  log_debug "Versioning enabled"

  # Block public access
  retry_aws 3 aws_cmd s3api put-public-access-block \
    --bucket "${S3_BUCKET}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --output text > /dev/null
  log_debug "BPA applied"

  # SSE (AES-256)
  retry_aws 3 aws_cmd s3api put-bucket-encryption \
    --bucket "${S3_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": false
      }]
    }' \
    --output text > /dev/null
  log_debug "SSE AES-256 applied"

  # Lifecycle: expire noncurrent versions at 30 days
  retry_aws 3 aws_cmd s3api put-bucket-lifecycle-configuration \
    --bucket "${S3_BUCKET}" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "expire-noncurrent-30d",
        "Status": "Enabled",
        "Filter": { "Prefix": "" },
        "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
      }]
    }' \
    --output text > /dev/null
  log_debug "Lifecycle rule applied"

  # Tagging
  retry_aws 3 aws_cmd s3api put-bucket-tagging \
    --bucket "${S3_BUCKET}" \
    --tagging 'TagSet=[
      {Key=Project,Value=benchmarks},
      {Key=Component,Value=eval-harness},
      {Key=ManagedBy,Value=harness-up.sh}
    ]' \
    --output text > /dev/null
  log_info "S3 bucket reconciled"
}

# ============================================================
# Security group reconciliation — no ingress, all egress
# ============================================================
reconcile_sg() {
  log_info "Reconciling security group"

  # Look up SG by tag
  SG_ID="$(retry_aws 3 aws_cmd ec2 describe-security-groups \
    --filters "Name=tag:Component,Values=eval-harness" \
              "Name=tag:ManagedBy,Values=${SCRIPT_NAME}" \
              "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)" || SG_ID=""

  if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
    log_info "Creating security group: ${SG_NAME}"
    SG_ID="$(retry_aws 3 aws_cmd ec2 create-security-group \
      --group-name "${SG_NAME}" \
      --description "Eval-harness host SG -- no ingress, all egress (SSH-over-SSM)" \
      --vpc-id "${VPC_ID}" \
      --tag-specifications "ResourceType=security-group,Tags=[
        {Key=Project,Value=benchmarks},
        {Key=Component,Value=eval-harness},
        {Key=Campaign,Value=${CAMPAIGN}},
        {Key=ManagedBy,Value=${SCRIPT_NAME}},
        {Key=Name,Value=${SG_NAME}}
      ]" \
      --query 'GroupId' --output text)"
    log_info "Security group created: ${SG_ID}"
  else
    log_debug "Security group exists: ${SG_ID}"
  fi

  # --- Ingress reconcile: desired = empty set ---
  local current_ingress
  current_ingress="$(retry_aws 3 aws_cmd ec2 describe-security-groups \
    --group-ids "${SG_ID}" \
    --query 'SecurityGroups[0].IpPermissions' --output json)"

  local ingress_count
  ingress_count="$(printf '%s' "${current_ingress}" | jq 'length')"
  if (( ingress_count > 0 )); then
    log_warn "Revoking ${ingress_count} unexpected ingress rule(s) on ${SG_ID}"
    retry_aws 3 aws_cmd ec2 revoke-security-group-ingress \
      --group-id "${SG_ID}" \
      --ip-permissions "${current_ingress}" \
      --output text > /dev/null
    log_info "All ingress rules revoked"
  else
    log_debug "Ingress: already empty (correct)"
  fi

  # --- Egress reconcile: desired = all outbound ---
  local current_egress
  current_egress="$(retry_aws 3 aws_cmd ec2 describe-security-groups \
    --group-ids "${SG_ID}" \
    --query 'SecurityGroups[0].IpPermissionsEgress' --output json)"

  # Desired egress rule: protocol=-1 (all), cidr 0.0.0.0/0
  local has_allout
  has_allout="$(printf '%s' "${current_egress}" | \
    jq 'map(select(.IpProtocol=="-1" and (.IpRanges[]?.CidrIp=="0.0.0.0/0"))) | length')"

  if (( has_allout == 0 )); then
    # F-T1-6: Before revoking, check if any running instance uses this SG.
    # Revoking egress on a SG with in-flight traffic drops active connections.
    local running_users
    running_users="$(retry_aws 3 aws_cmd ec2 describe-instances \
      --filters "Name=instance.group-id,Values=${SG_ID}" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)" || running_users=""

    if [[ -n "${running_users}" && "${running_users}" != "None" ]]; then
      log_warn "SG ${SG_ID} has running instances (${running_users}); skipping egress revoke to avoid dropping in-flight traffic"
      log_warn "The existing egress rules are already permissive enough — re-run harness-up.sh after instance stops to fully reconcile"
    else
      # No running instances — safe to revoke and re-authorize
      local egress_count
      egress_count="$(printf '%s' "${current_egress}" | jq 'length')"
      if (( egress_count > 0 )); then
        log_info "Revoking ${egress_count} existing egress rule(s) for clean reconcile"
        retry_aws 3 aws_cmd ec2 revoke-security-group-egress \
          --group-id "${SG_ID}" \
          --ip-permissions "${current_egress}" \
          --output text > /dev/null
      fi
      log_info "Authorizing all-outbound egress on ${SG_ID}"
      retry_aws 3 aws_cmd ec2 authorize-security-group-egress \
        --group-id "${SG_ID}" \
        --ip-permissions '[{
          "IpProtocol": "-1",
          "IpRanges": [{"CidrIp": "0.0.0.0/0",
            "Description": "All outbound -- NAT GW; HF/GitHub/Bedrock/Spheron/Anthropic API"}]
        }]' \
        --output text > /dev/null
      log_info "All-outbound egress authorized"
    fi
  else
    log_debug "Egress: all-outbound rule present (correct)"
  fi

  log_info "Security group reconciled: ${SG_ID}"
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
  log_info "Launching EC2 instance (type=${INSTANCE_TYPE}, campaign=${CAMPAIGN})"

  local shutdown_behavior="terminate"
  local delete_on_term="true"
  if "${PERSISTENT}"; then
    shutdown_behavior="stop"
    delete_on_term="false"
    log_info "Persistent mode: shutdown-behavior=stop, EBS delete-on-termination=false"
  fi

  local optional_tags="{Key=Persistent,Value=${PERSISTENT}}"

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
    --query 'Instances[0].InstanceId' --output text)"

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    log_error "run-instances returned no instance ID"
    exit 1
  fi

  log_info "Instance launched: ${INSTANCE_ID}"

  # Save state file
  local state_file="/tmp/harness-instance-${CAMPAIGN}.id"
  printf '%s\n' "${INSTANCE_ID}" > "${state_file}"
  log_info "Instance ID saved to ${state_file}"
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
  reconcile_iam
  reconcile_s3
  reconcile_sg

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
        push_install_harness_via_ssm
        ;;
      running|pending)
        log_info "Instance already ${EXISTING_INSTANCE_STATE}: ${INSTANCE_ID} — skipping launch and bootstrap poll"
        # If SSM is available and bootstrap.ok present, poll is instant; otherwise skip
        wait_for_ssm_agent
        poll_bootstrap_sentinel
        push_install_harness_via_ssm
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
    push_install_harness_via_ssm
  fi

  append_ssh_config
  print_connect_info
  auto_connect

  log_info "harness-up complete instance=${INSTANCE_ID} campaign=${CAMPAIGN}"
}

main "$@"
