#!/usr/bin/env bash
# run-pool-a-sec-bench.sh — Pool A SEC-bench runner driver (curated instance subset)
#
# Drives the SEC-bench eval subset against a single target model: Opus 4.7 via
# Bedrock, GPT-5.5 via OpenAI direct, or any OpenAI-compatible vLLM endpoint
# (e.g. a self-hosted model on a rented GPU box).
#
# Differs from CyberGym in three ways:
#   1. No long-running sidecar grading server; eval is post-hoc per task.
#   2. Agent invocation is config.toml-driven (smolagent secb-run --config FOO).
#      We template a per-task config and shell out for each instance.
#   3. Verdict lives in report_<mode>.jsonl (JSONL, one record per instance),
#      not SQLite. Per-task records are extracted with jq.
#
# Per-instance flow (<CAMPAIGN> resilient pattern):
#   1. Template <output>/<instance>/config.toml (model, task type, instance_id).
#   2. `smolagent secb-run --config config.toml` → agent run lands at
#      <output>/<instance>/agent_out/<YYYYMMDD_HHMMSS>/<instance_id>/output.jsonl.
#   3. `python -m secb.evaluator.eval_instances --input-dir <agent-out>/<ts>
#         --type {poc|patch} --agent smolagent --output-dir <eval-out>` →
#      <eval-out>/report_sanitizer.jsonl (for poc) or report_<mode>.jsonl (for patch).
#      The PoC writer hardcodes "sanitizer" as the file-mode string regardless of
#      the --mode arg (eval_instances.py:1455 save_results(..., "sanitizer", ...)).
#   4. Parse the per-task report, write canonical result.json, sync to S3.
#
# Usage: run-pool-a-sec-bench.sh --target <opus47|opus47-direct|gpt55|vllm> --campaign NAME [OPTIONS]
#
# Options:
#   --target opus47|opus47-direct|gpt55|vllm
#                             Model target to evaluate (REQUIRED).
#                             opus47-direct routes Opus 4.7 via the Anthropic
#                             direct API (not Bedrock) — needed for SEC-bench
#                             because Bedrock's content filter trips on
#                             poc-san agent step 2 (benchmarks-b9i).
#   --campaign NAME           Campaign identifier (REQUIRED)
#   --spend-cap-usd FLOAT     Hard Bedrock spend cap in USD (default: 300)
#                             Ignored for --target vllm, gpt55, or
#                             opus47-direct (watchdog bypassed — Anthropic
#                             spend is not visible to AWS Cost Explorer)
#   --limit N                 Run only the first N instances from the subset
#                             (smoke testing). Default: all instances.
#   --instance-ids CSV        Comma-separated instance_ids to run, overriding
#                             the baked-in subset. E.g. "njs.cve-2022-32414"
#                             for a 1-instance smoke.
#   --task-type TYPE          SEC-bench task type: poc-san (default), poc-desc,
#                             poc-repo, or patch. poc-san mirrors CyberGym
#                             level1's "CVE description + sanitizer report"
#                             input set.
#   --force                   Overwrite existing per-instance results
#                             (default: skip if present)
#   --debug                   Enable set -x and verbose logging
#   -h, --help                Show this help message
#
# vLLM-target options (REQUIRED when --target=vllm):
#   --vllm-url URL            Endpoint base URL with /v1 suffix
#   --vllm-model MODEL_ID     Model identifier as served by the endpoint
#   --vllm-key KEY            API key passed in Authorization: Bearer header.
#                             Mutually exclusive with --vllm-key-ssm.
#   --vllm-key-ssm PATH       SSM SecureString path to fetch the API key from.
#
# Exit codes:
#   0  — all instances completed successfully
#   2  — spend cap exceeded; partial results synced to S3
#   1  — instance failure or unexpected error; partial results synced to S3
#
# Runtime estimates:
#   ~5-30 min per instance (smolagent default task.timeout_seconds=3600 cap).
#   For the 11-instance subset: ~1-6 hr wall (frontier API targets).
#
# WATCHDOG: identical policy to run-pool-a-cybergym.sh — see WATCHDOG section
#   there. Bypassed for vllm, gpt55, and opus47-direct targets (none of which
#   bill through Bedrock so AWS Cost Explorer can't see their spend).
#
# Results land at:
#   Local:  /var/lib/harness/results/<campaign>/<target>/sec-bench-N/
#   S3:     s3://<RESULTS_BUCKET>/<campaign>/<target>/sec-bench-N/
#   (N = active instance count after --limit / --instance-ids resolution)
#
# Subset note:
#   The handoff documented a canonical ~50-instance subset for Pool A SEC-bench,
#   but install-harness.sh currently pre-pulls only 11 eval images (see
#   /data/sec-bench/.installed-images). This runner defaults to those 11.
#   Expanding to a 50-image subset is tracked in a follow-up bd; the runner
#   will pick up any additional images automatically when the install list
#   is extended (the subset constant below is the source of truth).
#
# Prerequisites:
#   - install-harness.sh must have run (sec-bench repo + venv + smolagent
#     CLI + eval images present)
#   - For opus47: instance role grants Bedrock access (no keys needed)
#   - For opus47-direct: ANTHROPIC_API_KEY fetched from SSM
#     /sandbox/api-keys/anthropic (benchmarks-b9i)
#   - For gpt55: OPENAI_API_KEY fetched from SSM /sandbox/api-keys/openai
#   - For vllm: rental endpoint running + accessible from harness EC2
#
# SEC-bench reference: https://github.com/SEC-bench/SEC-bench
# Design reference: docs/research/pool-a-runner-contracts-2026-05-11.md
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RUNNER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly RUNNER_SCRIPT_DIR
RUNNER_NAME="run-pool-a-sec-bench"
export RUNNER_NAME

# shellcheck source=scripts/runners/_lib.sh
source "${RUNNER_SCRIPT_DIR}/_lib.sh"

# ============================================================
# Constants
# ============================================================
readonly SECBENCH_REPO="/opt/harnesses/sec-bench"
readonly SECBENCH_PYTHON="${SECBENCH_REPO}/.venv/bin/python"
readonly SECBENCH_SMOLAGENT="${SECBENCH_REPO}/.venv/bin/smolagent"

# Eval-image install marker — install-harness.sh's sec-bench-images step
# writes one image fqn per line under SUCCEEDED. We don't read this file
# directly (subset is hardcoded below for explicit baseline composition);
# kept here for the documentation cross-reference.
# readonly SECBENCH_IMAGES_MARKER="/data/sec-bench/.installed-images"

# Docker image prefix — must match the one in config.toml's [docker] section.
readonly SECBENCH_IMAGE_PREFIX="hwiwonlee/secb.eval.x86_64"

# Per-instance defaults (smolagent task.timeout_seconds + agent.max_steps).
# 3600s/30 are smolagents upstream defaults. bd <ISSUE> concluded max_steps=30
# was not the binding constraint (the iteration-on-error pattern from bd <ISSUE>
# was burning steps on wrong-PoC churn, not on near-miss reasoning). With
# bd <ISSUE> patches now removing that error-iteration loop, the question
# reopens: does the model need more than 30 steps for real reasoning? Lift
# default to 50 so the bd-227+bd-55z patched runs are not artificially
# capped at the historical pre-bd-55z ceiling. Operator can override down
# (SECBENCH_MAX_STEPS=30) to reproduce the historical baseline directly.
readonly SECBENCH_TIMEOUT_SECS="${SECBENCH_TIMEOUT_SECS:-3600}"
readonly SECBENCH_MAX_STEPS="${SECBENCH_MAX_STEPS:-50}"

# Agent scaffold: CodeAgent emits Python code blocks (no tool-calling JSON
# requirement, drop-in for any LiteLLM endpoint per the runner-contracts research).
readonly SECBENCH_AGENT_TYPE="${SECBENCH_AGENT_TYPE:-CodeAgent}"

# Evaluator mode: medium is the upstream-recommended primary mode (exit code
# matches dataset's expected_exit_code). strict/generous available via env.
readonly SECBENCH_EVAL_MODE="${SECBENCH_EVAL_MODE:-medium}"

# Dataset split: eval is the screening profile; cve/oss split the eval by source.
readonly SECBENCH_SPLIT="${SECBENCH_SPLIT:-eval}"

# HuggingFace dataset name.
readonly SECBENCH_HF_DATASET="${SECBENCH_HF_DATASET:-SEC-bench/SEC-bench}"

# Pre-pulled SEC-bench eval instance subset. The 11 IDs below are what
# install-harness.sh's sec-bench-images step currently pulls; treated as
# the source of truth for the v1 baseline cell. Adding to this list also
# requires extending the install-harness pull set (otherwise the run will
# fail with `docker run` image-not-found for the missing instances).
#
# Source: /data/sec-bench/.installed-images on harness-frontier-poolb-2026-05.
# To regen after expansion: ssh harness 'cat /data/sec-bench/.installed-images
#   | grep -oE "secb.eval.x86_64\.[^ ]+" | sed "s|^secb.eval.x86_64\.||"'.
readonly -a SECBENCH_INSTANCES_DEFAULT=(
  "gpac.cve-2023-0760"
  "gpac.cve-2023-5586"
  "gpac.cve-2023-46929"
  "gpac.cve-2024-0321"
  "libarchive.cve-2017-14503"
  "libredwg.cve-2020-21816"
  "mruby.cve-2022-0240"
  "njs.cve-2022-28049"
  "njs.cve-2022-31307"
  "njs.cve-2022-32414"
  "njs.cve-2022-38890"
)

# Spend watchdog defaults
readonly DEFAULT_SPEND_CAP_USD="300"
readonly WATCHDOG_INTERVAL_SEC=60

# ============================================================
# Defaults
# ============================================================
TARGET=""
CAMPAIGN=""
FORCE="false"
SPEND_CAP_USD="${DEFAULT_SPEND_CAP_USD}"
SECBENCH_LIMIT=""           # empty = run all instances in subset
SECBENCH_INSTANCE_IDS_CSV="" # empty = use SECBENCH_INSTANCES_DEFAULT
SECBENCH_TASK_TYPE="poc-san" # CyberGym-level1 analog (CVE desc + sanitizer)

# vLLM-target args (only used when TARGET=vllm)
VLLM_URL=""
VLLM_MODEL=""
VLLM_KEY=""
VLLM_KEY_SSM=""

# Active instance list — populated in preflight
SECBENCH_INSTANCES=()

# BENCH_NAME is set in preflight once the instance count is known
BENCH_NAME=""

# Watchdog state
WATCHDOG_BASELINE_USD="0"
WATCHDOG_PID=""

# ============================================================
# ERR + EXIT traps
# ============================================================
trap 'lib_err_trap ${LINENO}' ERR
trap '_exit_handler' EXIT

_exit_handler() {
  local exit_code=$?
  log_info "EXIT handler fired exit_code=${exit_code}"
  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    log_debug "Stopping watchdog subprocess pid=${WATCHDOG_PID}"
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    wait "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  s3_sync_results "${BENCH_NAME:-}" 2>/dev/null \
    || log_warn "EXIT handler: s3_sync_results failed"
  log_info "EXIT handler complete"
}

# ============================================================
# Argument parsing
# ============================================================
usage() {
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)              TARGET="$2";                  shift 2 ;;
      --campaign)            CAMPAIGN="$2";                shift 2 ;;
      --spend-cap-usd)       SPEND_CAP_USD="$2";           shift 2 ;;
      --limit)               SECBENCH_LIMIT="$2";          shift 2 ;;
      --instance-ids)        SECBENCH_INSTANCE_IDS_CSV="$2"; shift 2 ;;
      --task-type)           SECBENCH_TASK_TYPE="$2";      shift 2 ;;
      --force)               FORCE="true";                 shift   ;;
      --debug)               LOG_LEVEL="debug"; set -x;    shift   ;;
      --vllm-url)            VLLM_URL="$2";                shift 2 ;;
      --vllm-model)          VLLM_MODEL="$2";              shift 2 ;;
      --vllm-key)            VLLM_KEY="$2";                shift 2 ;;
      --vllm-key-ssm)        VLLM_KEY_SSM="$2";            shift 2 ;;
      -h|--help)             usage ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  case "${SECBENCH_TASK_TYPE}" in
    poc-san|poc-desc|poc-repo|patch) ;;
    *) log_error "--task-type must be one of: poc-san|poc-desc|poc-repo|patch (got: ${SECBENCH_TASK_TYPE})"; exit 1 ;;
  esac

  if [[ -n "${SECBENCH_LIMIT}" && ! "${SECBENCH_LIMIT}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "--limit must be a positive integer (got: ${SECBENCH_LIMIT})"
    exit 1
  fi

  # vLLM-target arg validation (mirrors run-pool-a-cybergym.sh)
  if [[ "${TARGET}" == "vllm" ]]; then
    if [[ -z "${VLLM_URL}" ]]; then
      log_error "--target vllm requires --vllm-url"
      exit 1
    fi
    if [[ -z "${VLLM_MODEL}" ]]; then
      log_error "--target vllm requires --vllm-model"
      exit 1
    fi
    if [[ -n "${VLLM_KEY}" && -n "${VLLM_KEY_SSM}" ]]; then
      log_error "--vllm-key and --vllm-key-ssm are mutually exclusive"
      exit 1
    fi
    if [[ ! "${VLLM_URL}" =~ ^https:// && ! "${VLLM_URL}" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
      log_error "--vllm-url must be https:// (or http://localhost for local testing); got: ${VLLM_URL}"
      exit 1
    fi
    VLLM_MODEL_ID="${VLLM_MODEL}"
    VLLM_API_BASE="${VLLM_URL}"
    VLLM_API_KEY="${VLLM_KEY}"
    VLLM_API_KEY_SSM="${VLLM_KEY_SSM}"
    export VLLM_MODEL_ID VLLM_API_BASE VLLM_API_KEY VLLM_API_KEY_SSM
  else
    if [[ -n "${VLLM_URL}${VLLM_MODEL}${VLLM_KEY}${VLLM_KEY_SSM}" ]]; then
      log_error "--vllm-* flags only valid with --target vllm"
      exit 1
    fi
  fi
}

# ============================================================
# Pre-flight
# ============================================================
preflight() {
  lib_preflight

  : "${TARGET:?--target is required}"
  : "${CAMPAIGN:?--campaign is required}"

  validate_target "${TARGET}"

  if [[ ! "${CAMPAIGN}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Campaign name must be alphanumeric with hyphens/underscores: ${CAMPAIGN}"
    exit 1
  fi

  if [[ ! -d "${SECBENCH_REPO}" ]]; then
    log_error "SEC-bench repo not found at ${SECBENCH_REPO}"
    log_error "Run: sudo /opt/benchmarks/scripts/install-harness.sh"
    exit 1
  fi

  if [[ ! -x "${SECBENCH_PYTHON}" ]]; then
    log_error "SEC-bench venv python not at ${SECBENCH_PYTHON} — install-harness.sh did not create the venv"
    exit 1
  fi

  if [[ ! -x "${SECBENCH_SMOLAGENT}" ]]; then
    log_error "smolagent CLI not at ${SECBENCH_SMOLAGENT} — install-harness.sh did not pip-install requirements.txt (the SEC-bench/smolagents fork is referenced there)"
    log_error "Re-run install-harness.sh; the sec-bench section now includes the requirements.txt step."
    exit 1
  fi

  # Verify the evaluator's `docker` import works (caught the missing
  # dependency that motivated the install-harness fix).
  if ! "${SECBENCH_PYTHON}" -c "import docker" 2>/dev/null; then
    log_error "SEC-bench venv missing 'docker' Python package — requirements.txt was not installed"
    exit 1
  fi

  if ! command -v docker &>/dev/null; then
    log_error "docker not found — required for SEC-bench eval container runs"
    exit 1
  fi

  # Disk pre-flight: each eval image is ~4 GB; 11-image subset is ~45 GB
  # (already pre-pulled). Per-run output is a few MB. We just need workspace.
  local avail_gb
  avail_gb="$(df --output=avail / | tail -1 | awk '{print int($1 / 1024 / 1024)}')"
  if (( avail_gb < 10 )); then
    log_error "Insufficient disk: ${avail_gb} GB available; SEC-bench needs ~10 GB workspace"
    exit 1
  fi
  log_info "Disk preflight: ${avail_gb} GB available"

  if [[ "${TARGET}" == "gpt55" ]]; then
    lib_setup_gpt55_key
  fi
  if [[ "${TARGET}" == "opus47-direct" ]]; then
    lib_setup_anthropic_key
  fi
  if [[ "${TARGET}" == "vllm" ]]; then
    lib_setup_vllm_key
    lib_check_vllm_endpoint
  fi

  # Resolve active instance list
  if [[ -n "${SECBENCH_INSTANCE_IDS_CSV}" ]]; then
    IFS=',' read -ra SECBENCH_INSTANCES <<< "${SECBENCH_INSTANCE_IDS_CSV}"
    log_info "Using operator-supplied instance list: ${#SECBENCH_INSTANCES[@]} instances"
  else
    SECBENCH_INSTANCES=("${SECBENCH_INSTANCES_DEFAULT[@]}")
    log_info "Using baked-in default subset: ${#SECBENCH_INSTANCES[@]} instances"
  fi

  if [[ -n "${SECBENCH_LIMIT}" ]] && (( SECBENCH_LIMIT < ${#SECBENCH_INSTANCES[@]} )); then
    SECBENCH_INSTANCES=("${SECBENCH_INSTANCES[@]:0:${SECBENCH_LIMIT}}")
    log_info "Limited to first ${SECBENCH_LIMIT} instances by --limit"
  fi

  # Validate each instance has a pre-pulled image (fail-fast vs. failing inside
  # eval_instances after the agent run has already burned model tokens).
  local missing=()
  local inst image
  for inst in "${SECBENCH_INSTANCES[@]}"; do
    image="${SECBENCH_IMAGE_PREFIX}.${inst}:latest"
    if ! docker image inspect "${image}" &>/dev/null; then
      missing+=("${inst}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "Missing pre-pulled docker images for ${#missing[@]} instance(s): ${missing[*]}"
    log_error "Either pull them (docker pull ${SECBENCH_IMAGE_PREFIX}.<id>:latest) or remove them from --instance-ids"
    exit 1
  fi

  BENCH_NAME="sec-bench-${#SECBENCH_INSTANCES[@]}"

  log_info "Pool A SEC-bench preflight passed target=${TARGET} campaign=${CAMPAIGN} bench=${BENCH_NAME} n_instances=${#SECBENCH_INSTANCES[@]} task_type=${SECBENCH_TASK_TYPE}"
}

# ============================================================
# Progress reporter — writes a one-line heartbeat to S3
# ============================================================
write_progress() {
  local idx="$1"
  local inst="$2"
  local status="$3"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$(printf '[%s] runner=%s campaign=%s target=%s instance=%s (%d/%d) status=%s\n' \
    "${ts}" "${RUNNER_NAME}" "${CAMPAIGN}" "${TARGET}" \
    "${inst}" "${idx}" "${#SECBENCH_INSTANCES[@]}" "${status}")"

  local ts_compact
  ts_compact="$(date -u +%Y%m%dT%H%M%SZ)"
  local progress_key="s3://${LIB_S3_BUCKET}/${CAMPAIGN}/_progress/sec-bench-${TARGET}-${ts_compact}.log"
  printf '%s\n' "${line}" \
    | retry_cmd 2 aws s3 cp - "${progress_key}" --region "${LIB_REGION}" --no-progress 2>/dev/null \
    || log_warn "Progress report upload failed (non-fatal)"

  log_info "Progress: ${line}"
}

# ============================================================
# Spend watchdog loop (Bedrock targets only)
# Identical contract to run-pool-a-cybergym.sh:watchdog_loop.
# ============================================================
watchdog_loop() {
  local parent_pid="$1"
  local baseline_usd="$2"

  log_info "Watchdog loop started pid=$$ parent=${parent_pid} cap=${SPEND_CAP_USD} baseline=${baseline_usd}"

  while true; do
    sleep "${WATCHDOG_INTERVAL_SEC}"

    local watchdog_exit=0
    "${RUNNER_SCRIPT_DIR}/spend-watchdog.sh" \
      --cap-usd "${SPEND_CAP_USD}" \
      --baseline-usd "${baseline_usd}" \
      --campaign "${CAMPAIGN}" \
      --target "${TARGET}" \
      || watchdog_exit=$?

    case "${watchdog_exit}" in
      0) log_debug "Watchdog: within cap — continuing" ;;
      2)
        log_warn "Watchdog: spend cap EXCEEDED — sending SIGTERM to parent ${parent_pid}"
        kill -TERM "${parent_pid}" 2>/dev/null || true
        return 0
        ;;
      *)
        log_warn "Watchdog: monitoring failure (exit ${watchdog_exit}) — continuing run (conservative policy)"
        ;;
    esac
  done
}

fetch_baseline_spend() {
  log_info "Fetching Bedrock spend baseline from Cost Explorer"
  local baseline=0
  baseline="$("${RUNNER_SCRIPT_DIR}/spend-watchdog.sh" \
    --cap-usd "999999" \
    --baseline-usd "0" \
    --campaign "${CAMPAIGN}" \
    --target "${TARGET}" \
    2>/dev/null; printf '0')" || baseline=0
  log_info "Baseline spend: ${baseline} USD (may be 0 due to CE propagation delay)"
  WATCHDOG_BASELINE_USD="${baseline}"
}

# ============================================================
# Template a per-instance config.toml for smolagent secb-run.
# Path: <task_dir>/config.toml — written with mode 0600 so the api_key
# (if a literal vllm key is used) is not world-readable.
# ============================================================
write_instance_config() {
  local task_dir="$1"
  local instance_id="$2"
  local model_id="$3"
  local agent_output_dir="$4"

  local model_arg
  local api_base_line=""
  local api_key_line=""

  case "${TARGET}" in
    opus47|opus46)
      # Bedrock: do NOT emit api_key. LiteLLM's Bedrock provider uses boto3
      # to discover IAM creds from the instance role. If we pass a literal
      # api_key it gets forwarded to AWS, which rejects with "Invalid API
      # Key format: Must start with pre-defined prefix" (Bedrock interprets
      # the field as an Amazon Bedrock short-term API key, not an IAM
      # credential pass-through). Caught 2026-05-16 in <CAMPAIGN> smoke.
      model_arg="bedrock/${model_id}"
      ;;
    opus47-direct)
      # Anthropic direct API (benchmarks-b9i). model_id is "claude-opus-4-7"
      # (bare release name) per MODEL_ID_OPUS47_DIRECT; litellm's anthropic
      # provider hits api.anthropic.com by default — do NOT set api_base.
      model_arg="anthropic/${model_id}"
      if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        log_error "ANTHROPIC_API_KEY is empty at config-template time — lib_setup_anthropic_key failed?"
        return 1
      fi
      api_key_line="api_key = \"${ANTHROPIC_API_KEY}\""
      ;;
    gpt55)
      model_arg="openai/${model_id}"
      if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        log_error "OPENAI_API_KEY is empty at config-template time — lib_setup_gpt55_key failed?"
        return 1
      fi
      api_key_line="api_key = \"${OPENAI_API_KEY}\""
      ;;
    vllm)
      model_arg="openai/${model_id}"
      api_key_line="api_key = \"${VLLM_API_KEY:-}\""
      api_base_line="api_base = \"${VLLM_API_BASE}\""
      ;;
    *)
      log_error "write_instance_config: unsupported target ${TARGET}"
      return 1
      ;;
  esac

  local cfg="${task_dir}/config.toml"
  install -m 0600 /dev/null "${cfg}"
  cat > "${cfg}" <<EOF
# Auto-generated by run-pool-a-sec-bench.sh — DO NOT HAND-EDIT.
# campaign=${CAMPAIGN} target=${TARGET} instance=${instance_id}

[model]
type = "LiteLLMModel"
model_id = "${model_arg}"
${api_key_line}
${api_base_line}

[agent]
type = "${SECBENCH_AGENT_TYPE}"
max_steps = ${SECBENCH_MAX_STEPS}
verbosity_level = 1
tools = ["python_interpreter", "cmd"]

[dataset]
name = "${SECBENCH_HF_DATASET}"
split = "${SECBENCH_SPLIT}"
instance_ids = ["${instance_id}"]

[output]
output_dir = "${agent_output_dir}"

[docker]
image_prefix = "${SECBENCH_IMAGE_PREFIX}"
[docker.run_kwargs]
mem_limit = "8g"
network_mode = "host"
auto_remove = true

[task]
type = "${SECBENCH_TASK_TYPE}"
timeout_seconds = ${SECBENCH_TIMEOUT_SECS}
EOF
}

# ============================================================
# Locate the latest timestamped session directory smolagent wrote.
# smolagent emits <agent_output_dir>/<YYYYMMDD_HHMMSS>/<instance_id>/.
# We pick the most-recent timestamp dir to feed into eval_instances.
# Echoes the absolute path or empty string.
# ============================================================
latest_smolagent_session_dir() {
  local agent_output_dir="$1"
  [[ -d "${agent_output_dir}" ]] || { printf ''; return 0; }
  # Match the 8-digit-date_6-digit-time pattern.
  find "${agent_output_dir}" -maxdepth 1 -mindepth 1 -type d \
       -regextype posix-extended -regex '.*/[0-9]{8}_[0-9]{6}$' 2>/dev/null \
    | sort \
    | tail -1
}

# ============================================================
# Run a single SEC-bench instance
# Usage: run_instance <idx> <instance_id>
# ============================================================
run_instance() {
  local idx="$1"
  local instance_id="$2"
  BENCH="${BENCH_NAME}"

  local model_id
  model_id="$(lib_model_id "${TARGET}")"

  local result_dir="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}/${BENCH_NAME}"
  # SEC-bench instance ids are dot/dash-only (e.g. njs.cve-2022-32414) — safe
  # for filesystem paths and S3 keys without sanitization.
  local task_dir="${result_dir}/${instance_id}"
  local task_result_file="${task_dir}/result.json"

  if [[ -f "${task_result_file}" ]] && [[ "${FORCE}" == "false" ]]; then
    log_info "Skipping instance=${instance_id} — result exists and --force not set"
    write_progress "${idx}" "${instance_id}" "skipped"
    return 0
  fi

  mkdir -p "${task_dir}"
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local start_epoch
  start_epoch="$(date +%s)"

  log_info "Starting SEC-bench instance=${instance_id} (${idx}/${#SECBENCH_INSTANCES[@]}) target=${TARGET} task_type=${SECBENCH_TASK_TYPE}"
  write_progress "${idx}" "${instance_id}" "running"

  local agent_output_dir="${task_dir}/agent_out"
  local eval_output_dir="${task_dir}/eval_out"
  mkdir -p "${agent_output_dir}" "${eval_output_dir}"

  if ! write_instance_config "${task_dir}" "${instance_id}" "${model_id}" "${agent_output_dir}"; then
    log_error "Failed to template config.toml for instance=${instance_id}"
    return 1
  fi

  # ---------------------------------------------------------------
  # Phase 1: smolagent secb-run
  # ---------------------------------------------------------------
  local agent_log="${task_dir}/smolagent.log"
  log_info "Invoking smolagent secb-run instance=${instance_id} timeout=${SECBENCH_TIMEOUT_SECS}s agent=${SECBENCH_AGENT_TYPE}"

  local agent_rc=0
  (
    cd "${SECBENCH_REPO}"
    # Hard wall-clock cap with a 60s buffer above task.timeout_seconds.
    timeout "$(( SECBENCH_TIMEOUT_SECS + 60 ))" \
      "${SECBENCH_SMOLAGENT}" secb-run \
        --config "${task_dir}/config.toml"
  ) 2>&1 | tee "${agent_log}" | tee -a "${LIB_RUNNER_LOG}"
  agent_rc="${PIPESTATUS[0]}"

  if (( agent_rc != 0 )); then
    log_warn "smolagent exited rc=${agent_rc} instance=${instance_id} (continuing to verdict extract — agent may still have written a session dir)"
  fi

  # ---------------------------------------------------------------
  # Phase 2: locate the agent's session dir and run the evaluator.
  # ---------------------------------------------------------------
  local session_dir
  session_dir="$(latest_smolagent_session_dir "${agent_output_dir}")"
  if [[ -z "${session_dir}" ]]; then
    log_error "No smolagent session directory found under ${agent_output_dir} — agent likely crashed before emitting output"
    return 1
  fi
  log_info "smolagent session dir: ${session_dir}"

  # SECBENCH_TASK_TYPE poc-san/poc-desc/poc-repo all map to eval --type=poc.
  # eval_instances ignores --mode for poc (interpret_poc_results is mode-blind);
  # only --type=patch consumes strict/medium/generous.
  local eval_type="poc"
  [[ "${SECBENCH_TASK_TYPE}" == "patch" ]] && eval_type="patch"

  local -a eval_argv=(
    --input-dir "${session_dir}"
    --type "${eval_type}"
    --split "${SECBENCH_SPLIT}"
    --agent smolagent
    --output-dir "${eval_output_dir}"
  )
  if [[ "${eval_type}" == "patch" ]]; then
    eval_argv+=(--mode "${SECBENCH_EVAL_MODE}")
  fi

  local eval_log="${task_dir}/eval.log"
  log_info "Invoking eval_instances type=${eval_type} agent=smolagent"

  local eval_rc=0
  (
    cd "${SECBENCH_REPO}"
    "${SECBENCH_PYTHON}" -m secb.evaluator.eval_instances "${eval_argv[@]}"
  ) 2>&1 | tee "${eval_log}" | tee -a "${LIB_RUNNER_LOG}"
  eval_rc="${PIPESTATUS[0]}"

  if (( eval_rc != 0 )); then
    log_warn "eval_instances exited rc=${eval_rc} instance=${instance_id} (continuing — report file may still exist)"
  fi

  # ---------------------------------------------------------------
  # Phase 3: parse the eval report for the per-instance verdict.
  # PoC: <eval-out>/report_sanitizer.jsonl (mode hardcoded by save_results)
  # Patch: <eval-out>/report_<mode>.jsonl
  # ---------------------------------------------------------------
  local report_mode_string
  if [[ "${eval_type}" == "poc" ]]; then
    report_mode_string="sanitizer"
  else
    report_mode_string="${SECBENCH_EVAL_MODE}"
  fi
  local report_file="${eval_output_dir}/report_${report_mode_string}.jsonl"

  local pass_flag="false"
  local success_field=""
  local reason_field=""
  local exit_code_field="null"
  local sanitizer_triggered_field="null"

  if [[ -f "${report_file}" ]]; then
    # JSONL: one record per instance. We filter on .instance_id to be safe
    # (config.toml only enumerates this single instance, but a stale report
    # file from a prior run could otherwise pollute the verdict).
    local rec
    rec="$(jq -c --arg id "${instance_id}" 'select(.instance_id == $id)' "${report_file}" 2>/dev/null | tail -1)"
    if [[ -n "${rec}" ]]; then
      # jq's // (alternative) operator treats `false` as falsy alongside null,
      # so `.field // null` returns null on a legitimate boolean false. For
      # boolean fields use the no-default form — jq emits "null" naturally
      # when the field is missing, and "false" when it's present-and-false.
      success_field="$(printf '%s' "${rec}" | jq -r '.success')"
      reason_field="$(printf '%s' "${rec}" | jq -r '.reason // ""')"
      exit_code_field="$(printf '%s' "${rec}" | jq -r '.exit_code // null')"
      sanitizer_triggered_field="$(printf '%s' "${rec}" | jq -r '.sanitizer_triggered')"
      [[ "${success_field}" == "true" ]] && pass_flag="true"
    else
      log_warn "report_${report_mode_string}.jsonl has no record for instance=${instance_id}"
    fi
  else
    log_warn "report_${report_mode_string}.jsonl not found at ${report_file}"
  fi

  # Recover token usage from smolagents output.json (bd <ISSUE>). smolagent
  # writes one `.steps[].token_usage.{input_tokens,output_tokens}` record per
  # agent step; summing across steps yields the run total. The
  # output.json path is <session_dir>/<instance_id>/artifacts/output.json.
  local tokens_in=0 tokens_out=0
  local output_json="${session_dir}/${instance_id}/artifacts/output.json"
  if [[ -f "${output_json}" ]]; then
    tokens_in="$(jq '[.steps[].token_usage.input_tokens // 0] | add // 0' "${output_json}" 2>/dev/null || printf '0')"
    tokens_out="$(jq '[.steps[].token_usage.output_tokens // 0] | add // 0' "${output_json}" 2>/dev/null || printf '0')"
    [[ -z "${tokens_in}"  || "${tokens_in}"  == "null" ]] && tokens_in=0
    [[ -z "${tokens_out}" || "${tokens_out}" == "null" ]] && tokens_out=0
  fi

  jq -n \
    --arg     instance_id          "${instance_id}" \
    --argjson pass                 "${pass_flag}" \
    --arg     success_field        "${success_field}" \
    --arg     reason               "${reason_field}" \
    --argjson exit_code            "${exit_code_field}" \
    --argjson sanitizer_triggered  "${sanitizer_triggered_field}" \
    --argjson agent_rc             "${agent_rc}" \
    --argjson eval_rc              "${eval_rc}" \
    --arg     eval_mode            "${report_mode_string}" \
    --arg     task_type            "${SECBENCH_TASK_TYPE}" \
    --argjson tokens_in            "${tokens_in}" \
    --argjson tokens_out           "${tokens_out}" \
    '{
      instance_id: $instance_id,
      pass: $pass,
      success_field: $success_field,
      reason: $reason,
      exit_code: $exit_code,
      sanitizer_triggered: $sanitizer_triggered,
      agent_exit_code: $agent_rc,
      eval_exit_code: $eval_rc,
      eval_mode: $eval_mode,
      task_type: $task_type,
      tokens_in: $tokens_in,
      tokens_out: $tokens_out
    }' > "${task_dir}/verdict.json"

  # Build canonical result.json
  local model_args=""
  case "${TARGET}" in
    opus47|opus46) model_args="bedrock/${model_id}" ;;
    opus47-direct) model_args="anthropic/${model_id}" ;;
    gpt55)         model_args="openai/${model_id}" ;;
    vllm)          model_args="openai/${model_id}@${VLLM_API_BASE}" ;;
  esac

  local completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local end_epoch
  end_epoch="$(date +%s)"
  local wall_secs=$(( end_epoch - start_epoch ))

  local pass_rate=0
  [[ "${pass_flag}" == "true" ]] && pass_rate=1

  # bd <ISSUE> transparency: read the harness-variant stamp written by
  # install-harness.sh. Defaults to "stock" if no stamp file exists (i.e.
  # the harness was installed before bd <ISSUE> patches landed). Every result
  # JSON from this runner carries the variant so dual-track reporting is
  # correct by construction. See docs/research/secbench-harness-methodology-2026-05-19.md.
  local harness_variant_json="null"
  if [[ -f "/opt/benchmarks/.secb-harness-variant.json" ]]; then
    harness_variant_json="$(cat /opt/benchmarks/.secb-harness-variant.json)"
  else
    harness_variant_json='{"variant":"stock","patches":[]}'
  fi

  local extra_json
  extra_json="$(jq -n \
    --arg     instance_id          "${instance_id}" \
    --arg     task_type            "${SECBENCH_TASK_TYPE}" \
    --arg     eval_mode            "${report_mode_string}" \
    --arg     reason               "${reason_field}" \
    --argjson sanitizer_triggered  "${sanitizer_triggered_field}" \
    --arg     output_dir           "${task_dir}" \
    --arg     model_args           "${model_args}" \
    --arg     vllm_url             "${VLLM_URL:-}" \
    --arg     vllm_model           "${VLLM_MODEL:-}" \
    --argjson harness_variant      "${harness_variant_json}" \
    '{
      instance_id:          $instance_id,
      task_type:            $task_type,
      eval_mode:            $eval_mode,
      reason:               (if $reason == "" then null else $reason end),
      sanitizer_triggered:  $sanitizer_triggered,
      output_dir:           $output_dir,
      model_args:           $model_args,
      vllm_url:             (if $vllm_url  == "" then null else $vllm_url  end),
      vllm_model:           (if $vllm_model == "" then null else $vllm_model end),
      harness_variant:      $harness_variant
    }')"

  write_result_json \
    "${task_result_file}" \
    "${BENCH_NAME}" \
    "${model_id}" \
    "${started_at}" \
    "${completed_at}" \
    "${wall_secs}" \
    "${pass_rate}" \
    "1" \
    "0" \
    "0" \
    "${extra_json}"

  # Scrub api_key from config.toml before S3 sync. Opus47/Bedrock paths
  # don't write an api_key line, but gpt55 (OPENAI_API_KEY) and vllm
  # (VLLM_API_KEY) do — without scrubbing, the per-task config.toml that
  # the EXIT-trap S3 sync uploads to s3://<RESULTS_BUCKET>/<campaign>/
  # would expose the literal key. The file lives on disk at 0600 but the S3
  # object has bucket-default ACLs.
  if [[ -f "${task_dir}/config.toml" ]]; then
    sed -i 's/^api_key = ".*"$/api_key = "<redacted>"/' "${task_dir}/config.toml"
  fi

  s3_sync_results "${BENCH_NAME}"

  local status="pass"
  [[ "${pass_flag}" != "true" ]] && status="fail"
  write_progress "${idx}" "${instance_id}" "${status}"

  log_info "Completed instance=${instance_id} pass=${pass_flag} success_field=${success_field} wall_time_seconds=${wall_secs}"
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  preflight

  log_info "Starting Pool A SEC-bench run campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} n_instances=${#SECBENCH_INSTANCES[@]} spend_cap=${SPEND_CAP_USD}"

  # ---- Spend watchdog (Bedrock targets only) ----
  if [[ "${TARGET}" == "vllm" || "${TARGET}" == "gpt55" || "${TARGET}" == "opus47-direct" ]]; then
    log_warn "Spend watchdog BYPASSED for target=${TARGET} — cost gate is operator-side (rental teardown for vllm; OpenAI portal spend cap for gpt55; Anthropic Console usage cap for opus47-direct). Ensure spend is monitored externally."
  else
    fetch_baseline_spend
    watchdog_loop "$$" "${WATCHDOG_BASELINE_USD}" &
    WATCHDOG_PID="$!"
    log_info "Watchdog started pid=${WATCHDOG_PID}"

    trap '_sigterm_handler' TERM
    _sigterm_handler() {
      log_warn "SIGTERM received — spend cap exceeded; initiating clean abort"
      exit 2
    }
  fi

  # Per-instance resilience (<CAMPAIGN>): each run_instance call is captured via
  # `|| rc=$?` from a subshell with ERR/EXIT traps cleared. A failure inside
  # the subshell is recorded as a failure marker without aborting the loop.
  local idx=0
  local instance_id
  local rc started_at error_excerpt task_result_file
  local n_passed=0
  local n_failed=0
  local -a failed_instances=()
  local model_id
  model_id="$(lib_model_id "${TARGET}")"
  local -r n_total="${#SECBENCH_INSTANCES[@]}"

  for instance_id in "${SECBENCH_INSTANCES[@]}"; do
    (( ++idx ))
    BENCH="${BENCH_NAME}"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rc=0
    (
      trap - ERR EXIT
      run_instance "${idx}" "${instance_id}"
    ) || rc=$?

    if (( rc == 0 )); then
      (( ++n_passed ))
      continue
    fi

    (( ++n_failed ))
    failed_instances+=("${instance_id}")
    log_error "Instance failed instance=${instance_id} exit_code=${rc}; recording failure marker and continuing"

    task_result_file="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}/${BENCH_NAME}/${instance_id}/result.json"
    error_excerpt="$(lib_log_tail_excerpt 30)"
    lib_write_failure_marker \
      "${task_result_file}" "${BENCH_NAME}" "${model_id}" \
      "${started_at}" "${rc}" "${error_excerpt}" \
      || log_warn "Failure marker write failed instance=${instance_id}"
    write_progress "${idx}" "${instance_id}" "failed" || true
    s3_sync_results "${BENCH_NAME}" \
      || log_warn "S3 sync after failure marker failed instance=${instance_id}"
  done

  if (( n_failed == 0 )); then
    log_info "Pool A SEC-bench complete campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} passed=${n_passed}/${n_total}"
    return 0
  fi

  log_error "Pool A SEC-bench finished with failures campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} passed=${n_passed}/${n_total} failed=[${failed_instances[*]}]"
  exit 1
}

main "$@"
