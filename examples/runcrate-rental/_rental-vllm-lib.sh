#!/usr/bin/env bash
# _rental-vllm-lib.sh — Shared helpers for rental-vllm-up.sh / rental-vllm-down.sh
#
# Source this file at the top of either script:
#   # shellcheck source=scripts/_rental-vllm-lib.sh
#   source "$(dirname -- "${BASH_SOURCE[0]}")/_rental-vllm-lib.sh"
#
# Provides:
#   rv_log / rv_log_info / rv_log_warn / rv_log_error
#   rv_yaml_to_json    — bash↔python YAML→JSON helper (uses python3+PyYAML)
#   rv_load_spec       — loads <spec>.yaml into a flat env-variable namespace
#   rv_short_hash      — deterministic 8-char hash for tmux session naming
#   rv_state_path      — canonical state file path on the harness
#   rv_state_write     — atomic JSON state write
#   rv_state_read      — read field from state JSON via jq
#   rv_ssh_run         — SSH wrapper (StrictHostKeyChecking accept-new, ConnectTimeout)
#   rv_ssh_test        — preflight SSH connectivity check
#   rv_ssh_tunnel_alive — check whether a local-forward tunnel is alive
#
# Issue: benchmarks-<CAMPAIGN>

# Guard against double-sourcing
[[ -n "${_RV_LIB_SOURCED:-}" ]] && return 0
readonly _RV_LIB_SOURCED=1

# ============================================================
# Strict mode (callers also set this)
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Constants
# ============================================================
readonly RV_STATE_DIR="/var/lib/harness/rentals"
readonly RV_LOG_FILE="/var/log/harness-rental-vllm.log"
# Persistent SSH known_hosts file for rental hosts. Lives under /var/lib/harness
# (writable by root; canonical sudo invocation) rather than $HOME/.ssh/... so
# that hostkey verification persists across the ubuntu/root user split and the
# cleanup of state files.
readonly RV_RENTED_KNOWN_HOSTS="/var/lib/harness/rented_known_hosts"
# gpu-rental key path — cloud-init plants it at /home/ubuntu/.ssh/gpu-rental.
# Operator-facing invocation is via sudo, so HOME=/root and ${HOME}/.ssh/...
# does not exist. Prefer the canonical path; fall back to $HOME/.ssh/gpu-rental
# for dev runs from the operator laptop or anywhere that's mocked the key in
# the current user's home dir. Override with RV_GPU_RENTAL_KEY env var.
_rv_resolve_gpu_rental_key() {
  if [[ -n "${RV_GPU_RENTAL_KEY:-}" && -r "${RV_GPU_RENTAL_KEY}" ]]; then
    printf '%s' "${RV_GPU_RENTAL_KEY}"
    return 0
  fi
  local candidate
  for candidate in /home/ubuntu/.ssh/gpu-rental "${HOME}/.ssh/gpu-rental"; do
    if [[ -r "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  # Fall through to canonical (will trigger preflight failure with a clear
  # error message at first ssh attempt).
  printf '%s' "/home/ubuntu/.ssh/gpu-rental"
}
RV_GPU_RENTAL_KEY="$(_rv_resolve_gpu_rental_key)"
readonly RV_GPU_RENTAL_KEY
# AWS region for SSM fetches — falls back to us-east-1 (the harness EC2's home).
# shellcheck disable=SC2034
readonly RV_AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
# vLLM bind port on the rental — fixed; SSH tunnel maps a (per-rental) local
# port on the harness to this. Hardcoded on the rental side because vLLM only
# ever serves one model per rental box in this campaign.
readonly RV_RENTAL_VLLM_PORT=8000
# vLLM serving log on the rental — used by rental-vllm-up.sh
# shellcheck disable=SC2034
readonly RV_RENTAL_VLLM_LOG="/var/log/vllm.log"
# Default startup wait — Cold-load + torch.compile can take ~10 min per the
# 2026-05-07 spike; give it 25 min headroom for first-launch + bigger models.
# shellcheck disable=SC2034
readonly RV_DEFAULT_READY_TIMEOUT_SEC=1500
# vLLM venv path on the rental (uv-managed) — used by rental-vllm-up.sh
# shellcheck disable=SC2034
readonly RV_RENTAL_VENV="/opt/vllm-venv"

# ============================================================
# Logging — mirrors scripts/runners/_lib.sh format but with rv_ prefix so the
# two libs don't collide if both happen to be sourced (e.g. by an orchestrator
# that runs runners after provisioning).
# ============================================================
RV_RUNNER_NAME="${RV_RUNNER_NAME:-rental-vllm}"
RV_RENTAL_HOST="${RV_RENTAL_HOST:-unset}"

rv_log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="[rental-vllm][${level}][${ts}] script=${RV_RUNNER_NAME} rental=${RV_RENTAL_HOST} message=$*"
  if [[ -w "${RV_LOG_FILE}" ]] || (mkdir -p "$(dirname "${RV_LOG_FILE}")" 2>/dev/null && touch "${RV_LOG_FILE}" 2>/dev/null); then
    printf '%s\n' "${line}" | tee -a "${RV_LOG_FILE}" >&2
  else
    printf '%s\n' "${line}" >&2
  fi
}
rv_log_info()  { rv_log "info"  "$@"; }
rv_log_warn()  { rv_log "warn"  "$@"; }
rv_log_error() { rv_log "error" "$@"; }

# ============================================================
# YAML → JSON via python3+PyYAML
# Usage: rv_yaml_to_json <spec.yaml>
# Prints JSON to stdout.
# ============================================================
rv_yaml_to_json() {
  local spec="$1"
  if [[ ! -r "${spec}" ]]; then
    rv_log_error "Spec file not readable: ${spec}"
    return 1
  fi
  if ! python3 -c 'import yaml' 2>/dev/null; then
    rv_log_error "python3 PyYAML missing on harness; run: sudo apt-get install -y python3-yaml"
    return 1
  fi
  python3 - "${spec}" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict):
    print("spec must be a YAML mapping at top level", file=sys.stderr)
    sys.exit(1)
print(json.dumps(data))
PY
}

# ============================================================
# Spec loading — reads YAML, validates required keys, exports flat env vars.
# Required spec keys:
#   model_id              (string) HF model id, e.g. "Qwen/Qwen3.6-27B-FP8"
#   rental_host           (string) hostname or IP of provisioned rental box
# Optional with defaults:
#   rental_user           (string) default "root" (Runcrate convention)
#   tensor_parallel_size  (int)    default 1
#   quant                 (string) default "" (no --quantization flag)
#   max_model_len         (int)    default "" (let vLLM pick — but ALL repo
#                                   specs explicitly set 131072 / 128K as the
#                                   FLOOR. Smaller values silently truncate
#                                   prompts: SEC-bench poc-san first-message
#                                   ASan + system prompt frequently exceeds
#                                   16K, and Pool B reasoning-mode (Qwen3
#                                   <think> blocks) can exceed 8K. Caught
#                                   2026-05-17 when an earlier 16K override
#                                   on the harness caused Qwen3.6-27B
#                                   SEC-bench-11 to ContextWindowExceededError
#                                   on every first call.
#   vllm_args             (list)   default []  — extra flags appended verbatim
#   vllm_env              (map)    default {}  — env vars exported in the launch
#                          heredoc before `vllm serve` (e.g. {VLLM_USE_FLASHINFER_MOE_FP8: "0"}).
#                          Use for env-only knobs that have no CLI flag.
#   vllm_min_version      (string) default "0.20"  — uv pip install 'vllm>={ver}'
#   local_port            (int)    default 8000  — SSH local-forward port on harness
#   hf_token_ssm          (string) default "/sandbox/api-keys/hf-token"
#                          set to empty string in spec to disable HF auth
#
# Side effect: exports RV_SPEC_* env vars used by the up/down scripts.
# ============================================================
rv_load_spec() {
  local spec_path="$1"
  local spec_json
  spec_json="$(rv_yaml_to_json "${spec_path}")"

  # Required
  RV_SPEC_MODEL_ID="$(printf '%s' "${spec_json}" | jq -r '.model_id // empty')"
  RV_SPEC_RENTAL_HOST="$(printf '%s' "${spec_json}" | jq -r '.rental_host // empty')"
  if [[ -z "${RV_SPEC_MODEL_ID}" ]]; then
    rv_log_error "Spec missing required field: model_id"
    return 1
  fi
  if [[ -z "${RV_SPEC_RENTAL_HOST}" ]]; then
    rv_log_error "Spec missing required field: rental_host"
    return 1
  fi

  # Optional
  RV_SPEC_RENTAL_USER="$(printf '%s' "${spec_json}" | jq -r '.rental_user // "root"')"
  RV_SPEC_TP_SIZE="$(printf '%s' "${spec_json}" | jq -r '.tensor_parallel_size // 1')"
  RV_SPEC_QUANT="$(printf '%s' "${spec_json}" | jq -r '.quant // ""')"
  RV_SPEC_MAX_MODEL_LEN="$(printf '%s' "${spec_json}" | jq -r '.max_model_len // ""')"
  RV_SPEC_VLLM_MIN_VER="$(printf '%s' "${spec_json}" | jq -r '.vllm_min_version // "0.20"')"
  RV_SPEC_LOCAL_PORT="$(printf '%s' "${spec_json}" | jq -r '.local_port // 8000')"
  RV_SPEC_HF_TOKEN_SSM="$(printf '%s' "${spec_json}" | jq -r '.hf_token_ssm // "/sandbox/api-keys/hf-token"')"

  # vllm_args is a JSON array; serialise back to a JSON string for downstream.
  RV_SPEC_VLLM_ARGS_JSON="$(printf '%s' "${spec_json}" | jq -c '.vllm_args // []')"
  # Validate it parses as an array
  if ! printf '%s' "${RV_SPEC_VLLM_ARGS_JSON}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    rv_log_error "Spec field vllm_args must be a YAML list (got: ${RV_SPEC_VLLM_ARGS_JSON})"
    return 1
  fi

  # vllm_env is a JSON object (string->scalar); serialise back to JSON for downstream.
  RV_SPEC_VLLM_ENV_JSON="$(printf '%s' "${spec_json}" | jq -c '.vllm_env // {}')"
  if ! printf '%s' "${RV_SPEC_VLLM_ENV_JSON}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    rv_log_error "Spec field vllm_env must be a YAML mapping (got: ${RV_SPEC_VLLM_ENV_JSON})"
    return 1
  fi

  # Numeric validation
  if ! [[ "${RV_SPEC_TP_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
    rv_log_error "Spec field tensor_parallel_size must be a positive integer (got: ${RV_SPEC_TP_SIZE})"
    return 1
  fi
  if ! [[ "${RV_SPEC_LOCAL_PORT}" =~ ^[1-9][0-9]{2,4}$ ]]; then
    rv_log_error "Spec field local_port must be a port number (got: ${RV_SPEC_LOCAL_PORT})"
    return 1
  fi

  RV_RENTAL_HOST="${RV_SPEC_RENTAL_HOST}"
  export RV_SPEC_MODEL_ID RV_SPEC_RENTAL_HOST RV_SPEC_RENTAL_USER \
         RV_SPEC_TP_SIZE RV_SPEC_QUANT RV_SPEC_MAX_MODEL_LEN \
         RV_SPEC_VLLM_MIN_VER RV_SPEC_LOCAL_PORT RV_SPEC_HF_TOKEN_SSM \
         RV_SPEC_VLLM_ARGS_JSON RV_SPEC_VLLM_ENV_JSON RV_RENTAL_HOST

  local env_keys
  env_keys="$(printf '%s' "${RV_SPEC_VLLM_ENV_JSON}" | jq -r 'keys | join(",")')"
  rv_log_info "Spec loaded: model=${RV_SPEC_MODEL_ID} rental=${RV_SPEC_RENTAL_HOST} tp=${RV_SPEC_TP_SIZE} quant=${RV_SPEC_QUANT:-none} local_port=${RV_SPEC_LOCAL_PORT} vllm_env=[${env_keys}]"
}

# ============================================================
# Short hash — first 8 hex chars of sha256(input). Used for tmux session
# naming so the same model on the same rental gets the same session id.
# ============================================================
rv_short_hash() {
  printf '%s' "$1" | sha256sum | cut -c1-8
}

# ============================================================
# State file — one per rental host, JSON.
# ============================================================
rv_state_path() {
  local rental_host="$1"
  printf '%s/%s.json' "${RV_STATE_DIR}" "${rental_host}"
}

# Atomic write — file-replace via temp-file rename.
rv_state_write() {
  local rental_host="$1"
  local json_body="$2"
  mkdir -p "${RV_STATE_DIR}"
  local target tmp
  target="$(rv_state_path "${rental_host}")"
  tmp="$(mktemp "${RV_STATE_DIR}/.${rental_host}.XXXXXX")"
  printf '%s\n' "${json_body}" > "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${target}"
  rv_log_info "State written: ${target}"
}

# Read a top-level field (jq filter) from the state file.
# Returns empty string + exit 1 if the file or field is missing.
rv_state_read() {
  local rental_host="$1"
  local jq_filter="${2:-.}"
  local state_file
  state_file="$(rv_state_path "${rental_host}")"
  if [[ ! -r "${state_file}" ]]; then
    return 1
  fi
  jq -r "${jq_filter} // empty" < "${state_file}"
}

# ============================================================
# SSH wrapper — uses gpu-rental key, accepts new host keys, modest timeouts.
# Usage: rv_ssh_run <user> <host> <remote-cmd...>
# Stdout/stderr from the remote command are passed through.
# ============================================================
rv_ssh_run() {
  local user="$1"; shift
  local host="$1"; shift
  # Best-effort: known_hosts dir may be unwritable in dev runs (no sudo), in
  # which case ssh proceeds with a warning. On the harness (sudo invocation)
  # the dir is writable.
  mkdir -p "$(dirname -- "${RV_RENTED_KNOWN_HOSTS}")" 2>/dev/null || true
  ssh \
    -i "${RV_GPU_RENTAL_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${RV_RENTED_KNOWN_HOSTS}" \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=10 \
    -o BatchMode=yes \
    "${user}@${host}" "$@"
}

# ============================================================
# SSH preflight — confirm we can connect and run a trivial command.
# Retries with backoff because Runcrate's API returns status=running
# 90s–~4 min before the gpu-rental SSH key is actually injected into
# the rental's authorized_keys (benchmarks-15f). The exact gap varies
# by region: KC ~90s, Montreal ~3+ min observed 2026-05-09.
# 10 × 30s = 300s tolerated startup window covers Montreal with margin.
# ============================================================
rv_ssh_test() {
  local user="$1"
  local host="$2"
  local attempt
  local max_attempts=10

  # Runcrate (and likely other providers) recycle IPs across teardowns —
  # a host that was <RENTAL_IP> yesterday will have a different host
  # key today. With StrictHostKeyChecking=accept-new + a stale entry,
  # SSH refuses with HOST KEY MISMATCH and our 10×30s loop burns on
  # something fixable in one line. Strip any prior entry now; rv_ssh_run's
  # accept-new will re-add the current key on first successful connect.
  if [[ -f "${RV_RENTED_KNOWN_HOSTS}" ]]; then
    ssh-keygen -R "${host}" -f "${RV_RENTED_KNOWN_HOSTS}" >/dev/null 2>&1 || true
  fi

  rv_log_info "SSH preflight: ${user}@${host} (up to ${max_attempts} attempts × 30s backoff)"
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    if rv_ssh_run "${user}" "${host}" 'echo ok' >/dev/null 2>&1; then
      rv_log_info "SSH preflight OK on attempt ${attempt}/${max_attempts}"
      return 0
    fi
    if (( attempt < max_attempts )); then
      rv_log_warn "SSH preflight attempt ${attempt}/${max_attempts} failed (typical: rental key-injection race ~90s); retrying in 30s"
      sleep 30
    fi
  done
  rv_log_error "SSH preflight failed after ${max_attempts} attempts (key=${RV_GPU_RENTAL_KEY}). Verify the rental host is up and the gpu-rental key is registered with the provider."
  return 1
}

# ============================================================
# SSH tunnel liveness — checks whether a process matching the expected
# `ssh -fN -L <local_port>:127.0.0.1:<rental_port>` pattern is running and
# the local port is listening.
#
# Usage: rv_ssh_tunnel_alive <local_port> <user> <host>
# Returns 0 if alive, 1 otherwise.
# ============================================================
rv_ssh_tunnel_alive() {
  local local_port="$1"
  local user="$2"
  local host="$3"
  # Look for the process; pgrep returns nonzero if no match. Pattern matches
  # the local-forward spec; we don't anchor on host because users sometimes
  # connect via IP vs hostname.
  if ! pgrep -af "ssh.*-L ${local_port}:127.0.0.1:${RV_RENTAL_VLLM_PORT}.*${user}@${host}" >/dev/null 2>&1; then
    return 1
  fi
  # Confirm the local port is actually listening
  if command -v ss &>/dev/null; then
    if ! ss -tln "sport = :${local_port}" 2>/dev/null | grep -q LISTEN; then
      return 1
    fi
  fi
  return 0
}
