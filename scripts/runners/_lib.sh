#!/usr/bin/env bash
# _lib.sh — Shared helper library for benchmark runner scripts
#
# Source this file at the top of every runner:
#   # shellcheck source=scripts/runners/_lib.sh
#   source "$(dirname -- "${BASH_SOURCE[0]}")/_lib.sh"
#
# Callers must set before sourcing (or override immediately after):
#   RUNNER_NAME   — short script identifier for log records (e.g. "run-pool-b")
#   CAMPAIGN      — set by parse_args in the caller
#   TARGET        — "opus47", "opus46", "opus47-direct", "gpt55", or "vllm"
#                   (set by parse_args in caller)
#   BENCH         — current benchmark name (set per-bench loop)
#
# This library provides:
#   log / log_info / log_warn / log_error / log_debug
#   retry_cmd
#   ssm_get_key
#   s3_sync_results
#   write_result_json
#   validate_target
#   lib_preflight
#
# Design mirrors: scripts/harness-up.sh (structured logging, retry_aws, err trap)
# Issue: benchmarks-<CAMPAIGN> / benchmarks-<CAMPAIGN>
# Refactor 2026-05-11: dropped gemini target; added gpt55 (OpenAI direct) as
#   second frontier baseline. See project-scope-clarification-max-2026-05-09.

# ============================================================
# Guard against double-sourcing
# ============================================================
[[ -n "${_LIB_SOURCED:-}" ]] && return 0
readonly _LIB_SOURCED=1

# ============================================================
# Strict mode (callers must also set this, but set defensively here too)
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Constants
# ============================================================
readonly LIB_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
readonly LIB_S3_BUCKET="${RESULTS_BUCKET:-<RESULTS_BUCKET>}"
readonly LIB_RUNNER_LOG="/var/log/harness-runner.log"
readonly LIB_ERROR_DIR="/var/lib/harness/runner-errors"
readonly LIB_RESULTS_BASE="/var/lib/harness/results"

# Valid target values — enforced by validate_target.
# 'vllm' is generic — model_id, endpoint URL, and API key are passed at
# runtime via the runner's --vllm-* flags rather than hardcoded here. See
# benchmarks-<CAMPAIGN>.
readonly -a LIB_VALID_TARGETS=("opus47" "opus46" "opus47-direct" "gpt55" "vllm")

# Model ID mapping (Bedrock cross-region inference profiles for opus*).
# Note: 4.7's profile is bare "claude-opus-4-7" (no version), 4.6's is
# "claude-opus-4-6-v1" — Bedrock's profile-naming is inconsistent across
# Anthropic releases. Verified 2026-05-08 against ListInferenceProfiles.
readonly MODEL_ID_OPUS47="us.anthropic.claude-opus-4-7"
readonly MODEL_ID_OPUS46="us.anthropic.claude-opus-4-6-v1"

# Anthropic direct-API (not Bedrock) target — required by SEC-bench because
# Bedrock's content filter trips on poc-san agent step 2 (see bd memory
# bedrock-content-filter-secbench-opus-2026-05-16). The Anthropic CVP guardrail
# set is more permissive for documented security research and does NOT extend
# to Bedrock. The litellm prefix is "anthropic/<model>" (not "us.anthropic..."),
# so the model id here is the bare release name.
# Issue: benchmarks-b9i.
readonly MODEL_ID_OPUS47_DIRECT="claude-opus-4-7"

# SSM path for Anthropic direct-API key (provisioned 2026-05-16 from laptop
# via iptadmin; SecureString under alias/aws/ssm). Read access is granted to
# harness-driver-role via the existing parameter/sandbox/* wildcard.
readonly SSM_ANTHROPIC_KEY_PATH="/sandbox/api-keys/anthropic"

# GPT-5.5 target model ID — operator sets GPT55_MODEL_ID env var to override.
# Default is a placeholder; the exact model name will be confirmed when the
# OpenAI key is provisioned. The litellm model arg is openai/<GPT55_MODEL_ID>.
readonly GPT55_MODEL_ID="${GPT55_MODEL_ID:-gpt-5.5}"

# SSM path for GPT-5.5 (OpenAI) API key (placeholder; key will be provisioned)
readonly SSM_GPT55_KEY_PATH="/sandbox/api-keys/openai"

# SSM path for the HuggingFace token. Used by lm-eval / cybergym data
# downloads. Without it, HF Hub rate-limits anonymous requests, which
# eventually rejects large bench runs. Per bd memory
# api-key-inventory-closed-2026-05-07-replaces.
readonly SSM_HF_TOKEN_PATH="/sandbox/api-keys/hf-token"

# vLLM target runtime state (set by the runner's parse_args before any
# lib_model_id / build_model_args call). Centralized here so both Pool A
# and Pool B runners share the same field names.
VLLM_MODEL_ID="${VLLM_MODEL_ID:-}"
VLLM_API_BASE="${VLLM_API_BASE:-}"
VLLM_API_KEY="${VLLM_API_KEY:-}"

# ============================================================
# Runtime state (callers may pre-set these before sourcing)
# ============================================================
RUNNER_NAME="${RUNNER_NAME:-runner}"
CAMPAIGN="${CAMPAIGN:-unknown}"
TARGET="${TARGET:-}"
BENCH="${BENCH:-}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# ============================================================
# Logging
# Produces single-line records mirroring harness-up.sh format:
#   [runner][LEVEL][TIMESTAMP] runner=<name> target=<target> bench=<bench> message=...
# Tee'd to stdout AND /var/log/harness-runner.log
# ============================================================
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="[runner][${level}][${ts}] runner=${RUNNER_NAME} campaign=${CAMPAIGN} target=${TARGET:-unset} bench=${BENCH:-unset} message=${msg}"
  # tee to both stdout and persistent log file
  # LIB_RUNNER_LOG may not exist yet (first run before harness fully set up); tolerate failure
  if [[ -w "${LIB_RUNNER_LOG}" ]] || mkdir -p "$(dirname "${LIB_RUNNER_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" | tee -a "${LIB_RUNNER_LOG}"
  else
    printf '%s\n' "${line}"
  fi
}
log_info()  { log "info"  "$@"; }
log_warn()  { log "warn"  "$@"; }
log_error() { log "error" "$@"; }
log_debug() { [[ "${LOG_LEVEL}" == "debug" ]] && log "debug" "$@" || true; }

# ============================================================
# ERR trap — structured bug report to /var/lib/harness/runner-errors/
# Pattern from harness-up.sh:_err_trap
# Callers register this trap:  trap 'lib_err_trap ${LINENO}' ERR
# ============================================================
lib_err_trap() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local ts_file
  ts_file="$(date -u +%Y%m%d-%H%M%S)"

  log_error "Unhandled error at line ${line_no} (exit=${exit_code}) runner=${RUNNER_NAME}"

  mkdir -p "${LIB_ERROR_DIR}"
  local err_file="${LIB_ERROR_DIR}/${RUNNER_NAME}-${ts_file}.err"
  {
    printf 'runner=%s\n'       "${RUNNER_NAME}"
    printf 'campaign=%s\n'     "${CAMPAIGN}"
    printf 'target=%s\n'       "${TARGET:-unset}"
    printf 'bench=%s\n'        "${BENCH:-unset}"
    printf 'exit_code=%s\n'    "${exit_code}"
    printf 'file=%s\n'         "${BASH_SOURCE[1]:-unknown}"
    printf 'line=%s\n'         "${line_no}"
    printf 'last_command=%s\n' "${BASH_COMMAND:-unknown}"
    printf 'timestamp=%s\n'    "${ts}"
    printf 'log=%s\n'          "${LIB_RUNNER_LOG}"
  } > "${err_file}"
  log_error "Bug report written to ${err_file}"
}

# ============================================================
# EXIT trap — always sync partial results to S3
# Callers register this trap:  trap 'lib_exit_trap' EXIT
# ============================================================
lib_exit_trap() {
  local exit_code=$?
  log_info "EXIT trap fired exit_code=${exit_code}; syncing partial results"
  # Best-effort sync; suppress error output so it doesn't mask the real exit cause
  s3_sync_results 2>/dev/null || log_warn "EXIT trap: s3_sync_results failed (partial results may be missing)"
}

# ============================================================
# Retry with exponential backoff
# Usage: retry_cmd <max_attempts> <cmd...>
# Mirrors harness-up.sh:retry_aws (renamed to avoid confusion — callers pass
# full commands including 'aws'; this is not AWS-specific)
# ============================================================
retry_cmd() {
  local max_attempts="$1"; shift
  local attempt=1
  local delay=2
  while true; do
    local exit_code=0
    "$@" || exit_code=$?
    if (( exit_code == 0 )); then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      log_error "Command failed after ${max_attempts} attempts (exit=${exit_code}): $*"
      return "${exit_code}"
    fi
    log_warn "Attempt ${attempt}/${max_attempts} failed (exit=${exit_code}); retrying in ${delay}s"
    sleep "${delay}"
    (( ++attempt ))
    (( delay = delay * 2 > 60 ? 60 : delay * 2 ))
  done
}

# ============================================================
# SSM key fetch — pull a SecureString parameter value
# Usage: ssm_get_key <ssm_path>
# Prints the plaintext value to stdout.
# NEVER writes the value to disk — callers must store in a variable only.
# ============================================================
ssm_get_key() {
  local path="$1"
  retry_cmd 3 aws ssm get-parameter \
    --region "${LIB_REGION}" \
    --name "${path}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

# ============================================================
# GPT-5.5 (OpenAI direct) key setup — fetch from SSM and export as OPENAI_API_KEY
# Called by runners when target=gpt55 before any eval invocation.
# NOTE: for gpt55, OPENAI_API_BASE is NOT overridden — litellm's openai
# provider uses the default api.openai.com endpoint.
# NEVER write the key to disk.
# ============================================================
lib_setup_gpt55_key() {
  log_info "Fetching OpenAI API key from SSM ${SSM_GPT55_KEY_PATH}"
  local key
  key="$(ssm_get_key "${SSM_GPT55_KEY_PATH}")"
  if [[ -z "${key}" ]]; then
    log_error "SSM returned empty value for ${SSM_GPT55_KEY_PATH}"
    return 1
  fi
  export OPENAI_API_KEY="${key}"
  log_info "OPENAI_API_KEY exported (not logged)"
}

# ============================================================
# HuggingFace token setup — fetch from SSM and export as HF_TOKEN +
# HUGGING_FACE_HUB_TOKEN (HF tooling honors both names).
# Called by lib_preflight universally so every bench has dataset access at
# anonymous-bypass rate. Best-effort: a missing SSM entry is a WARN not
# an ERROR (HF Hub allows anonymous downloads, just rate-limits them).
# Never writes the token to disk.
# ============================================================
lib_setup_hf_token() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    log_info "HF_TOKEN already set in env; skipping SSM fetch"
    export HF_TOKEN HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
    return 0
  fi
  local key
  key="$(ssm_get_key "${SSM_HF_TOKEN_PATH}" 2>/dev/null || true)"
  if [[ -z "${key}" ]]; then
    log_warn "HF_TOKEN unavailable from SSM ${SSM_HF_TOKEN_PATH}; HF Hub rate-limited anonymous mode in effect. Full bench runs may stall on dataset cache misses."
    return 0
  fi
  export HF_TOKEN="${key}"
  export HUGGING_FACE_HUB_TOKEN="${key}"
  log_info "HF_TOKEN exported (not logged)"
}

# ============================================================
# Anthropic direct-API key setup — fetch from SSM and export as ANTHROPIC_API_KEY
# Called by runners when target=opus47-direct before any eval invocation.
# litellm's anthropic provider uses the default api.anthropic.com endpoint —
# ANTHROPIC_API_BASE is intentionally NOT overridden here.
# NEVER write the key to disk.
# Issue: benchmarks-b9i.
# ============================================================
lib_setup_anthropic_key() {
  log_info "Fetching Anthropic API key from SSM ${SSM_ANTHROPIC_KEY_PATH}"
  local key
  key="$(ssm_get_key "${SSM_ANTHROPIC_KEY_PATH}")"
  if [[ -z "${key}" ]]; then
    log_error "SSM returned empty value for ${SSM_ANTHROPIC_KEY_PATH}"
    return 1
  fi
  export ANTHROPIC_API_KEY="${key}"
  log_info "ANTHROPIC_API_KEY exported (not logged)"
}

# ============================================================
# vLLM endpoint key setup (<CAMPAIGN>)
# Two modes:
#   --vllm-key <literal>   → set VLLM_API_KEY directly (operator types it)
#   --vllm-key-ssm <path>  → fetch from SSM and assign to VLLM_API_KEY
# Default if neither is set: a placeholder ('sk-vllm-noauth') so litellm's
# OpenAI provider, which insists on a non-empty api_key, doesn't reject the
# request — vLLM itself will accept anything when started without --api-key.
# Caller must set VLLM_API_KEY (literal) or VLLM_API_KEY_SSM (path) before
# invoking this. NEVER writes the key to disk.
# ============================================================
lib_setup_vllm_key() {
  if [[ -n "${VLLM_API_KEY:-}" ]]; then
    log_info "VLLM_API_KEY already set (literal); not fetching from SSM"
    export VLLM_API_KEY
    return 0
  fi
  if [[ -n "${VLLM_API_KEY_SSM:-}" ]]; then
    log_info "Fetching vLLM API key from SSM ${VLLM_API_KEY_SSM}"
    local key
    key="$(ssm_get_key "${VLLM_API_KEY_SSM}")"
    if [[ -z "${key}" ]]; then
      log_error "SSM returned empty value for ${VLLM_API_KEY_SSM}"
      return 1
    fi
    export VLLM_API_KEY="${key}"
    log_info "VLLM_API_KEY exported from SSM (not logged)"
    return 0
  fi
  # Neither set — default to placeholder for unauthenticated endpoints.
  export VLLM_API_KEY="sk-vllm-noauth"
  log_warn "No --vllm-key or --vllm-key-ssm given; defaulting to 'sk-vllm-noauth' placeholder (vLLM started without --api-key will accept this)"
}

# ============================================================
# vLLM endpoint connectivity check (<CAMPAIGN>)
# Hits <api_base>/models with the configured key and confirms a 200 + the
# requested model_id is in the returned list. Catches typos, network gaps,
# wrong key, and stale rentals before paying for a full bench run.
# Required env: VLLM_API_BASE, VLLM_API_KEY, VLLM_MODEL_ID.
# ============================================================
lib_check_vllm_endpoint() {
  : "${VLLM_API_BASE:?VLLM_API_BASE must be set}"
  : "${VLLM_API_KEY:?VLLM_API_KEY must be set}"
  : "${VLLM_MODEL_ID:?VLLM_MODEL_ID must be set}"

  log_info "Checking vLLM endpoint ${VLLM_API_BASE}/models for model=${VLLM_MODEL_ID}"
  local body http_code
  local tmp
  tmp="$(mktemp)"
  http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    --max-time 15 \
    -H "Authorization: Bearer ${VLLM_API_KEY}" \
    "${VLLM_API_BASE}/models" 2>/dev/null || printf '000')"

  if [[ "${http_code}" != "200" ]]; then
    log_error "vLLM endpoint check failed: HTTP ${http_code} from ${VLLM_API_BASE}/models"
    log_error "Body (first 300 chars): $(head -c 300 "${tmp}" 2>/dev/null | tr '\n' ' ')"
    rm -f "${tmp}"
    return 1
  fi

  body="$(cat "${tmp}")"
  rm -f "${tmp}"

  # OpenAI /v1/models returns {"data":[{"id":"<model>",...},...]}. Match the
  # full requested model_id; warn (not fail) on mismatch — operator may have
  # served the model under a different alias intentionally.
  if printf '%s' "${body}" | jq -e --arg m "${VLLM_MODEL_ID}" '.data[]?.id == $m' >/dev/null 2>&1; then
    log_info "vLLM endpoint OK: ${VLLM_MODEL_ID} present in /models"
  else
    local served
    served="$(printf '%s' "${body}" | jq -r '[.data[]?.id] | join(",")' 2>/dev/null)"
    log_warn "vLLM endpoint reachable but '${VLLM_MODEL_ID}' not in /models (served: ${served:-<empty>}); proceeding anyway"
  fi
}

# ============================================================
# Model ID resolution
# Usage: lib_model_id <target>  →  prints model ID to stdout
# ============================================================
lib_model_id() {
  local target="$1"
  case "${target}" in
    opus47)        printf '%s' "${MODEL_ID_OPUS47}" ;;
    opus46)        printf '%s' "${MODEL_ID_OPUS46}" ;;
    opus47-direct) printf '%s' "${MODEL_ID_OPUS47_DIRECT}" ;;
    gpt55)         printf '%s' "${GPT55_MODEL_ID}" ;;
    vllm)
      # For vllm, the model_id is provided by the runner via --vllm-model
      # and stashed in VLLM_MODEL_ID before this is called.
      if [[ -z "${VLLM_MODEL_ID:-}" ]]; then
        log_error "lib_model_id: target=vllm but VLLM_MODEL_ID is unset"
        return 1
      fi
      printf '%s' "${VLLM_MODEL_ID}"
      ;;
    *)
      log_error "lib_model_id: unknown target '${target}'"
      return 1
      ;;
  esac
}

# ============================================================
# S3 sync — upload results directory for current campaign/target/bench
# Usage: s3_sync_results [bench_override]
# Syncs: LIB_RESULTS_BASE/<campaign>/<target>/<bench>/ →
#        s3://LIB_S3_BUCKET/<campaign>/<target>/<bench>/
# If bench_override is provided, uses that instead of $BENCH.
# ============================================================
# shellcheck disable=SC2120  # optional $1 arg is passed by callers outside this file
s3_sync_results() {
  local bench_name="${1:-${BENCH:-}}"
  if [[ -z "${CAMPAIGN}" || -z "${TARGET}" ]]; then
    log_warn "s3_sync_results: CAMPAIGN or TARGET unset — skipping sync"
    return 0
  fi

  local local_dir="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}"
  [[ -n "${bench_name}" ]] && local_dir="${local_dir}/${bench_name}"

  if [[ ! -d "${local_dir}" ]]; then
    log_debug "s3_sync_results: local dir not found (${local_dir}); nothing to sync"
    return 0
  fi

  local s3_prefix="s3://${LIB_S3_BUCKET}/${CAMPAIGN}/${TARGET}"
  [[ -n "${bench_name}" ]] && s3_prefix="${s3_prefix}/${bench_name}"
  s3_prefix="${s3_prefix}/"

  log_info "S3 sync: ${local_dir}/ -> ${s3_prefix}"
  retry_cmd 3 aws s3 sync \
    "${local_dir}/" \
    "${s3_prefix}" \
    --region "${LIB_REGION}" \
    --no-progress
  log_info "S3 sync complete: ${s3_prefix}"
}

# ============================================================
# Structured JSON result writer
# Usage: write_result_json <output_file> <bench> <model_id> \
#          <started_at> <completed_at> <wall_secs> \
#          <pass_rate> <n_tasks> <tokens_in> <tokens_out> \
#          [extra_json]
#
# Produces the canonical schema required by both <CAMPAIGN> and <CAMPAIGN>:
# {
#   "campaign":         "...",
#   "target":           "opus47" | "gpt55",
#   "bench":            "humaneval-plus" | "bigcodebench-hard" | "ifeval" | "cybergym-3",
#   "model_id":         "us.anthropic.claude-opus-4-7" | "gpt-5.5",
#   "started_at":       "2026-05-07T...Z",
#   "completed_at":     "...",
#   "wall_time_seconds": ...,
#   "pass_rate":        ...,
#   "n_tasks":          ...,
#   "tokens_in":        ...,
#   "tokens_out":       ...,
#   "extra":            { ... bench-specific ... }
# }
# ============================================================
write_result_json() {
  local output_file="$1"
  local bench="$2"
  local model_id="$3"
  local started_at="$4"
  local completed_at="$5"
  local wall_secs="$6"
  local pass_rate="$7"
  local n_tasks="$8"
  local tokens_in="$9"
  local tokens_out="${10}"
  local extra_json="${11:-{\}}"

  # Validate numeric fields
  if ! [[ "${wall_secs}"  =~ ^[0-9]+(\.[0-9]+)?$ ]]; then wall_secs=0; fi
  if ! [[ "${pass_rate}"  =~ ^[0-9]+(\.[0-9]+)?$ ]]; then pass_rate=0; fi
  if ! [[ "${n_tasks}"    =~ ^[0-9]+$ ]]; then n_tasks=0; fi
  if ! [[ "${tokens_in}"  =~ ^[0-9]+$ ]]; then tokens_in=0; fi
  if ! [[ "${tokens_out}" =~ ^[0-9]+$ ]]; then tokens_out=0; fi

  mkdir -p "$(dirname -- "${output_file}")"

  jq -n \
    --arg  campaign       "${CAMPAIGN}" \
    --arg  target         "${TARGET}" \
    --arg  bench          "${bench}" \
    --arg  model_id       "${model_id}" \
    --arg  started_at     "${started_at}" \
    --arg  completed_at   "${completed_at}" \
    --argjson wall_secs   "${wall_secs}" \
    --argjson pass_rate   "${pass_rate}" \
    --argjson n_tasks     "${n_tasks}" \
    --argjson tokens_in   "${tokens_in}" \
    --argjson tokens_out  "${tokens_out}" \
    --argjson extra       "${extra_json}" \
    '{
      campaign:           $campaign,
      target:             $target,
      bench:              $bench,
      model_id:           $model_id,
      started_at:         $started_at,
      completed_at:       $completed_at,
      wall_time_seconds:  $wall_secs,
      pass_rate:          $pass_rate,
      n_tasks:            $n_tasks,
      tokens_in:          $tokens_in,
      tokens_out:         $tokens_out,
      extra:              $extra
    }' > "${output_file}"

  log_info "Result JSON written to ${output_file}"
}

# ============================================================
# Per-bench failure marker
# Usage: lib_write_failure_marker <result_file> <bench> <model_id> \
#          <started_at> <exit_code> <error_excerpt>
#
# Writes a results.json that mirrors write_result_json's schema (so partial-
# results syncs and downstream parsers see one shape) but with status=failed,
# zero metrics, and exit_code/error fields filled in for triage.
# Used by per-bench try/catch loops (see benchmarks-<CAMPAIGN>).
# ============================================================
lib_write_failure_marker() {
  local result_file="$1"
  local bench="$2"
  local model_id="$3"
  local started_at="$4"
  local exit_code="$5"
  local error_excerpt="${6:-}"

  if ! [[ "${exit_code}" =~ ^[0-9]+$ ]]; then exit_code=1; fi

  local completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname -- "${result_file}")"

  jq -n \
    --arg     campaign     "${CAMPAIGN}" \
    --arg     target       "${TARGET}" \
    --arg     bench        "${bench}" \
    --arg     model_id     "${model_id}" \
    --arg     started_at   "${started_at}" \
    --arg     completed_at "${completed_at}" \
    --argjson exit_code    "${exit_code}" \
    --arg     error        "${error_excerpt}" \
    '{
      campaign:           $campaign,
      target:             $target,
      bench:              $bench,
      model_id:           $model_id,
      started_at:         $started_at,
      completed_at:       $completed_at,
      wall_time_seconds:  0,
      pass_rate:          0,
      n_tasks:            0,
      tokens_in:          0,
      tokens_out:         0,
      status:             "failed",
      exit_code:          $exit_code,
      error:              $error
    }' > "${result_file}"

  log_info "Failure marker written to ${result_file} exit_code=${exit_code}"
}

# ============================================================
# Log tail excerpt — last N lines of LIB_RUNNER_LOG, flattened to one line.
# Newlines collapsed to '|' and length-capped so it fits cleanly in JSON.
# Used to capture an error excerpt for failure markers without grepping logs.
# ============================================================
lib_log_tail_excerpt() {
  local n="${1:-30}"
  if [[ ! -r "${LIB_RUNNER_LOG}" ]]; then
    printf 'log unavailable: %s' "${LIB_RUNNER_LOG}"
    return 0
  fi
  tail -n "${n}" "${LIB_RUNNER_LOG}" 2>/dev/null \
    | tr '\n' '|' \
    | tr -d '\t' \
    | cut -c1-2000
}

# ============================================================
# Target validation
# Usage: validate_target <target>
# Aborts with exit 1 if target is not in LIB_VALID_TARGETS
# ============================================================
validate_target() {
  local target="$1"
  local valid
  for valid in "${LIB_VALID_TARGETS[@]}"; do
    [[ "${target}" == "${valid}" ]] && return 0
  done
  log_error "Invalid --target '${target}'. Valid values: ${LIB_VALID_TARGETS[*]}"
  return 1
}

# ============================================================
# Result skip-or-overwrite check
# Usage: lib_should_skip <result_file>
# Returns 0 if the result file exists AND --force was not set
# Returns 1 if we should proceed (run the bench)
# Callers must have FORCE set (default false) before sourcing
# ============================================================
lib_should_skip() {
  local result_file="$1"
  if [[ -f "${result_file}" ]] && [[ "${FORCE:-false}" == "false" ]]; then
    log_info "Skipping bench=${BENCH} — result file exists and --force not set: ${result_file}"
    return 0
  fi
  return 1
}

# ============================================================
# Library pre-flight: validate required tools exist on the harness host
# ============================================================
lib_preflight() {
  local required_tools=("aws" "jq" "docker" "python3")
  local tool
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "lib_preflight: required tool not found: ${tool}"
      log_error "Was install-harness.sh run? Check /var/lib/harness/install.ok"
      return 1
    fi
  done

  # Validate install sentinel
  if [[ ! -f "/var/lib/harness/install.ok" ]]; then
    log_warn "lib_preflight: /var/lib/harness/install.ok not found — harnesses may not be installed"
    log_warn "Run: sudo /opt/benchmarks/scripts/install-harness.sh"
  fi

  # Ensure results base dir exists
  mkdir -p "${LIB_RESULTS_BASE}"

  # HuggingFace token: best-effort; warn-not-error if missing.
  # Universally fetched so every bench has dataset access without
  # anonymous-mode rate limits. Per bd memory api-key-inventory-closed-2026-05-07.
  lib_setup_hf_token

  log_info "lib_preflight passed"
}

# ============================================================
# Env validation helper
# Usage: lib_require_env VAR [VAR...]
# Aborts if any listed variable is unset or empty
# ============================================================
lib_require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required environment variable not set: ${var}"
      return 1
    fi
  done
}
