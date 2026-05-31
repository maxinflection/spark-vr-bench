#!/usr/bin/env bash
# run-pool-b.sh — Pool B unattended frontier benchmark runner
#
# Drives HumanEval+, BigCodeBench-Hard, and IFEval against a single target:
# either a Bedrock Anthropic model, GPT-5.5 via OpenAI direct, or any
# OpenAI-compatible vLLM endpoint (e.g. a self-hosted model on a rented GPU
# box). Designed to run unattended after being invoked over SSH-over-SSM from
# a Proxmox sandbox.
#
# Usage: run-pool-b.sh --target <opus47|opus46|gpt55|vllm> --campaign NAME [OPTIONS]
#
# Options:
#   --target opus47|opus46|gpt55|vllm
#                             Model target. opus47/opus46 = Bedrock cross-region
#                             inference profile; gpt55 = GPT-5.5 via OpenAI
#                             direct (OPENAI_API_KEY from SSM); vllm = generic
#                             OpenAI-compatible endpoint
#                             (REQUIRED)
#   --campaign NAME           Campaign identifier (REQUIRED)
#   --benches BENCH1[,BENCH2,...]
#                             Comma-separated list of benches to run. Valid
#                             values: humaneval-plus, ifeval, bigcodebench-hard.
#                             Default: all three (current behavior).
#                             Order is always the canonical order regardless of
#                             the order given here. Unknown names cause exit 1.
#                             Example: --benches humaneval-plus,bigcodebench-hard
#   --force                   Overwrite existing per-bench results (default: skip if present)
#   --limit N                 Smoke-mode: cap each bench at N samples (passes
#                             --limit to lm-eval). Result files are flagged
#                             with smoke=true; do NOT compare to full-run
#                             numbers. Useful for harness validation.
#   --debug                   Enable set -x and verbose logging
#   -h, --help                Show this help message
#
# vLLM-target options (REQUIRED when --target=vllm):
#   --vllm-url URL            Endpoint base URL with /v1 suffix, e.g.
#                             https://rental-host.example.com/v1
#   --vllm-model MODEL_ID     Model identifier as served by the endpoint
#                             (e.g. Qwen/Qwen3.6-27B-FP8). Becomes
#                             openai/<MODEL_ID> in the litellm model_args.
#   --vllm-key KEY            API key passed in Authorization: Bearer header.
#                             Mutually exclusive with --vllm-key-ssm.
#   --vllm-key-ssm PATH       SSM SecureString path to fetch the API key from
#                             at runtime (e.g. /sandbox/api-keys/rental-vllm/foo).
#                             Mutually exclusive with --vllm-key. If neither
#                             is given, a placeholder is used (suitable for
#                             vLLM started without --api-key).
#   --vllm-eos-string STR     Optional EOS token string to forward to lm-eval
#                             as eos_string in --model_args. Required for
#                             models whose tokenizer's EOS isn't auto-derivable
#                             from the litellm/openai endpoint (lm-eval logs
#                             "Cannot determine EOS string to pass to stop
#                             sequence" when this is missing). Set to the
#                             chat-end token from the model's tokenizer_config
#                             (e.g. "<|im_end|>" for Qwen/ChatML, "<end_of_turn>"
#                             for Gemma). Default: empty (no eos_string).
#   --vllm-extra-body JSON    Optional JSON object forwarded as extra_body on
#                             every chat-completion request (via the litellm
#                             monkey-patch in _litellm_patches.py). Used to
#                             pass chat_template_kwargs to vLLM — most commonly
#                             {"chat_template_kwargs": {"enable_thinking": false}}
#                             to disable Qwen3's thinking-mode preamble that
#                             otherwise consumes the generation budget on code
#                             tasks. Default: empty (no extra_body).
#   --vllm-bcb-max-tokens N   Override bigcodebench --max_new_tokens (default
#                             1280 inside bigcodebench is too tight for any
#                             model that emits a chain-of-thought preamble
#                             before code). Default: 16384 per thinking-mode
#                             lock (2026-05-19) — reasoning-on models need
#                             ≥16K to emit a full <think> block + final code.
#   --gpt55-bcb-max-tokens N  Same as --vllm-bcb-max-tokens but applied when
#                             TARGET=gpt55. Reasoning tokens consume the
#                             completion budget so this needs to be higher.
#                             Default: 16384.
#   --opus47-bcb-max-tokens N Same as --vllm-bcb-max-tokens but applied when
#                             TARGET=opus47 or opus46. Greedy decoding, no
#                             extended thinking enabled. Default: 4096.
#
# Exit codes:
#   0  — all selected benches completed successfully
#   1  — unknown --benches value, or one or more benches failed; partial results synced to S3
#
# Runtime estimates (frontier API targets):
#   HumanEval+:        ~30 min, ~$5/target
#   BigCodeBench-Hard: ~40 min, ~$10/target
#   IFEval:            ~30 min, ~$5/target
#
# Results land at:
#   Local:  /var/lib/harness/results/<campaign>/<target>/<bench>/results.json
#   S3:     s3://<RESULTS_BUCKET>/<campaign>/<target>/<bench>/
#
# Prerequisites: install-harness.sh must have run (lm-evaluation-harness venv present)
# Design reference: docs/research/ec2-harness-design.md, docs/harness-setup.md
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap: locate lib and source it
# ============================================================
RUNNER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly RUNNER_SCRIPT_DIR
RUNNER_NAME="run-pool-b"
export RUNNER_NAME

# shellcheck source=scripts/runners/_lib.sh
source "${RUNNER_SCRIPT_DIR}/_lib.sh"

# ============================================================
# Constants
# ============================================================
readonly LM_EVAL_VENV="/opt/harnesses/lm-evaluation-harness/.venv"
# Use the patched wrapper (loads scripts/runners/_litellm_patches.py before lm-eval),
# not the venv's bare `lm-eval` binary. The patch strips temperature for Opus 4.7
# (litellm issue #26444). The wrapper is invoked via the venv's python so that
# lm_eval and litellm are importable.
readonly LM_EVAL_PYTHON="${LM_EVAL_VENV}/bin/python"
readonly LM_EVAL_WRAPPER="/opt/benchmarks/scripts/runners/lm-eval-patched.py"

# bigcodebench split: GENERATION runs from the lm-eval venv (lightweight,
# only needs the openai client + datasets + fire). GRADING runs in the
# upstream Docker image, which has the full 74-package requirements-eval.txt
# preinstalled — much cleaner than fighting host Python+wheel ABI matrix
# for 4-year-old pins (see bap + feedback-max-2026-05-09-pinning).
readonly BCB_DOCKER_IMAGE="bigcodebench/bigcodebench-evaluate:latest"
# Local lm-eval task overrides (<CAMPAIGN>): we ship humaneval_plus_instruct
# here because upstream only has the base-completion humaneval_plus.
readonly LM_EVAL_TASK_DIR="${RUNNER_SCRIPT_DIR}/lm-eval-tasks"

# Pool B bench identifiers (canonical names used in JSON output and S3 paths).
# bigcodebench-hard is NOT in lm-evaluation-harness — it ships in the separate
# `bigcodebench` pip package, invoked via `python -m bigcodebench.evaluate`.
# In this runner it is wired only for the `vllm` target (the actual screening
# use case for <CAMPAIGN>-11). Bedrock-routed Opus targets emit a 'skipped' marker
# instead of trying to run, since bigcodebench's --backend anthropic does not
# support Bedrock cross-region inference profiles. See benchmarks-<CAMPAIGN>.
#
# Override via env: POOL_B_BENCHES_OVERRIDE="humaneval-plus,ifeval" (comma-sep,
# whitespace-tolerated). Useful for smoke runs that want to skip the full
# bigcodebench-hard pass (148 tasks, no --limit support).
if [[ -n "${POOL_B_BENCHES_OVERRIDE:-}" ]]; then
  IFS=',' read -r -a POOL_B_BENCHES <<< "$(printf '%s' "${POOL_B_BENCHES_OVERRIDE}" | tr -d ' ')"
  readonly POOL_B_BENCHES
else
  readonly -a POOL_B_BENCHES=("humaneval-plus" "ifeval" "bigcodebench-hard")
fi

# ============================================================
# Defaults (overridden by parse_args)
# ============================================================
TARGET=""
CAMPAIGN=""
FORCE="false"
SMOKE_LIMIT=""    # empty = full run; integer N = pass --limit N to lm-eval
BENCHES_FILTER="" # empty = run all; CSV of bench names to select
ACTIVE_BENCHES=() # populated by parse_args after --benches validation

# vLLM-target args (only used when TARGET=vllm)
VLLM_URL=""
VLLM_MODEL=""
VLLM_KEY=""
VLLM_KEY_SSM=""
VLLM_EOS_STRING=""
VLLM_EXTRA_BODY=""
# num_concurrent for the litellm openai client when TARGET=vllm. Default 1
# matches Bedrock/OpenAI behavior; bump to ~8 on rentals where vLLM is serving
# one user. Hot-patch in <CAMPAIGN> first attempt was 8; CLI knob lands 2026-05-15
# (<CAMPAIGN>) so future rentals can opt in without editing the runner.
VLLM_NUM_CONCURRENT="1"
# 16384 per thinking-mode lock 2026-05-19: reasoning-capable open-weights with
# enable_thinking=true emit a <think> block + final code answer in one call;
# 4096 truncates ~all of them mid-think (<CAMPAIGN> first-attempt symptom). bd
# <CAMPAIGN> plumbing (None-tolerance in graders + sanitize) lands the rest of
# the unblock; override via --vllm-bcb-max-tokens for non-thinking models.
VLLM_BCB_MAX_TOKENS="16384"
# Token budget for bigcodebench-hard generate phase when TARGET=gpt55. GPT-5.x
# reasoning tokens are charged against the completion budget (per gpt55-api-
# quirks memo, ~2-4× output overhead), so 4096 starves multi-step Hard tasks.
# 16384 keeps a comfortable margin; bump higher with --gpt55-bcb-max-tokens
# if usage logs show truncation.
GPT55_BCB_MAX_TOKENS="16384"
# Token budget for bigcodebench-hard generate phase when TARGET=opus47/opus46.
# Bedrock Anthropic Opus 4.x via greedy decoding (no extended thinking); 4096
# matches the vllm default and is comfortable for Hard tasks. Bump via
# --opus47-bcb-max-tokens if truncation shows up.
OPUS47_BCB_MAX_TOKENS="4096"

# ============================================================
# ERR + EXIT traps
# ============================================================
trap 'lib_err_trap ${LINENO}' ERR
trap 'lib_exit_trap' EXIT

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
      --target)   TARGET="$2";        shift 2 ;;
      --campaign) CAMPAIGN="$2";      shift 2 ;;
      --benches)  BENCHES_FILTER="$2"; shift 2 ;;
      --force)    FORCE="true";       shift   ;;
      --limit)    SMOKE_LIMIT="$2";   shift 2 ;;
      --debug)    LOG_LEVEL="debug"; set -x; shift ;;
      --vllm-url)     VLLM_URL="$2";     shift 2 ;;
      --vllm-model)   VLLM_MODEL="$2";   shift 2 ;;
      --vllm-key)     VLLM_KEY="$2";     shift 2 ;;
      --vllm-key-ssm) VLLM_KEY_SSM="$2"; shift 2 ;;
      --vllm-eos-string)    VLLM_EOS_STRING="$2";    shift 2 ;;
      --vllm-extra-body)    VLLM_EXTRA_BODY="$2";    shift 2 ;;
      --vllm-num-concurrent) VLLM_NUM_CONCURRENT="$2"; shift 2 ;;
      --vllm-bcb-max-tokens) VLLM_BCB_MAX_TOKENS="$2"; shift 2 ;;
      --gpt55-bcb-max-tokens) GPT55_BCB_MAX_TOKENS="$2"; shift 2 ;;
      --opus47-bcb-max-tokens) OPUS47_BCB_MAX_TOKENS="$2"; shift 2 ;;
      -h|--help)  usage ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Validate --limit is a positive integer if set
  if [[ -n "${SMOKE_LIMIT}" && ! "${SMOKE_LIMIT}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "--limit must be a positive integer (got: ${SMOKE_LIMIT})"
    exit 1
  fi

  # Validate --benches CSV against the canonical POOL_B_BENCHES set.
  # Build ACTIVE_BENCHES preserving canonical order regardless of CLI order.
  if [[ -n "${BENCHES_FILTER}" ]]; then
    local -a requested_benches=()
    IFS=',' read -r -a requested_benches <<< "$(printf '%s' "${BENCHES_FILTER}" | tr -d ' ')"
    # Validate each requested name
    local req
    for req in "${requested_benches[@]}"; do
      local found=false
      local canonical
      for canonical in "${POOL_B_BENCHES[@]}"; do
        if [[ "${req}" == "${canonical}" ]]; then
          found=true
          break
        fi
      done
      if ! "${found}"; then
        local valid_list
        valid_list="$(IFS=','; printf '%s' "${POOL_B_BENCHES[*]}")"
        log_error "--benches: unknown bench name '${req}'. Valid names: ${valid_list}"
        exit 1
      fi
    done
    # Build filtered list in canonical order
    ACTIVE_BENCHES=()
    for canonical in "${POOL_B_BENCHES[@]}"; do
      for req in "${requested_benches[@]}"; do
        if [[ "${canonical}" == "${req}" ]]; then
          ACTIVE_BENCHES+=("${canonical}")
          break
        fi
      done
    done
  else
    ACTIVE_BENCHES=("${POOL_B_BENCHES[@]}")
  fi

  # vLLM-target arg validation
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
    # Reject http:// URLs unless explicitly localhost (defensive — Bearer
    # tokens over plaintext leak; rentals must be TLS).
    if [[ ! "${VLLM_URL}" =~ ^https:// && ! "${VLLM_URL}" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
      log_error "--vllm-url must be https:// (or http://localhost for local testing); got: ${VLLM_URL}"
      exit 1
    fi
    # Stash into the lib's vllm slots before lib_model_id / build_model_args run.
    VLLM_MODEL_ID="${VLLM_MODEL}"
    VLLM_API_BASE="${VLLM_URL}"
    VLLM_API_KEY="${VLLM_KEY}"
    VLLM_API_KEY_SSM="${VLLM_KEY_SSM}"
    export VLLM_MODEL_ID VLLM_API_BASE VLLM_API_KEY VLLM_API_KEY_SSM
  else
    # Non-vllm targets: reject vllm-specific args (catch typos)
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

  # Validate campaign name (alphanumeric + hyphen/underscore only)
  if [[ ! "${CAMPAIGN}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Campaign name must be alphanumeric with hyphens/underscores: ${CAMPAIGN}"
    exit 1
  fi

  # Check lm-eval venv
  if [[ ! -f "${LM_EVAL_PYTHON}" ]]; then
    log_error "lm-evaluation-harness venv not found at ${LM_EVAL_PYTHON}"
    log_error "Run: sudo /opt/benchmarks/scripts/install-harness.sh"
    exit 1
  fi

  # GPT-5.5 target: fetch OpenAI API key from SSM (instance role grants access)
  if [[ "${TARGET}" == "gpt55" ]]; then
    lib_setup_gpt55_key
  fi

  # vLLM target: resolve API key (literal / SSM / placeholder) and verify
  # the endpoint is reachable + serving the requested model_id before we
  # commit to a full bench run.
  if [[ "${TARGET}" == "vllm" ]]; then
    lib_setup_vllm_key
    lib_check_vllm_endpoint
  fi

  log_info "Pool B preflight passed target=${TARGET} campaign=${CAMPAIGN} benches=[${ACTIVE_BENCHES[*]}]"
}

# ============================================================
# Build litellm model_args string for lm-evaluation-harness
# Usage: build_model_args <target>  →  prints model_args string to stdout
#
# lm-evaluation-harness litellm mode reference:
#   https://github.com/EleutherAI/lm-evaluation-harness
# Bedrock cross-region inference profile: invoked via instance role (no keys needed)
# GPT-5.5: uses OPENAI_API_KEY env var exported by lib_setup_gpt55_key;
#   no OPENAI_API_BASE override — uses default api.openai.com
# ============================================================
build_model_args() {
  local target="$1"
  local model_id
  model_id="$(lib_model_id "${target}")"

  case "${target}" in
    opus47|opus46)
      # Bedrock cross-region inference profile via litellm. Discovery 2026-05-08
      # confirmed: model=bedrock/<inference-profile-id>,aws_region_name=us-east-1
      # works once boto3 is installed in the venv. litellm uses the EC2
      # instance role for Bedrock auth (no keys needed).
      #
      # Opus 4.7 has a temperature-deprecation quirk (drop temperature/top_p/
      # top_k); _litellm_patches.py scopes that strip to 4.7 only, so 4.6
      # passes temperature=0 through normally. The trailing-assistant-ws
      # strip and empty-stops drop apply to both via the same patch (Bedrock+
      # Anthropic-wide).
      printf 'model=bedrock/%s,aws_region_name=%s' "${model_id}" "${LIB_REGION}"
      ;;
    gpt55)
      # GPT-5.5 via OpenAI direct. OPENAI_API_KEY is exported by
      # lib_setup_gpt55_key before this is called. No api_base override —
      # litellm's openai provider uses the default api.openai.com endpoint.
      # TODO: if GPT-5.5 needs analogous temperature-stripping to Opus 4.7,
      # add a _litellm_patches.py scrub for it once the key is provisioned
      # and the exact model name is confirmed.
      printf 'model=openai/%s' "${model_id}"
      ;;
    vllm)
      # OpenAI-compatible endpoint via litellm's openai provider.
      #
      # IMPORTANT: lm-eval's LiteLLMChatCompletion._create_payload (in
      # lm_eval/models/openai_completions.py) only forwards messages, model,
      # max_tokens, temperature, stop, seed to litellm.completion(). api_base
      # and api_key from --model_args are stored on the constructor but
      # NEVER reach the litellm call. So passing them here is a no-op.
      # We redirect litellm at the rental endpoint via OPENAI_API_BASE +
      # OPENAI_API_KEY env vars set in run_bench()'s env_prefix instead.
      # (Verified 2026-05-09 smoke; before this fix the runner hit the real
      # api.openai.com and got "Incorrect API key".)
      #
      # eos_string: lm-eval's API model can't auto-detect EOS without a
      # local tokenizer (litellm backend doesn't load one). Without it,
      # handle_stop_sequences() returns the task's `until` list unchanged
      # — empty for humaneval-plus-chat / ifeval — which means vLLM keeps
      # generating past the model's actual EOS into the next chat turn.
      # Setting eos_string here makes lm-eval append it to every `stop=`
      # list sent to the API. Defaults empty (caller must pass
      # --vllm-eos-string for models where it matters; Qwen/ChatML uses
      # "<|im_end|>", Gemma uses "<end_of_turn>").
      # num_concurrent: vLLM serves single-tenant on a rental, so parallelize
      # litellm calls. Hot-patched to 8 during <CAMPAIGN> first attempt; CLI knob
      # via --vllm-num-concurrent N (default 1) added 2026-05-15 (<CAMPAIGN>).
      local extra=""
      if [[ "${VLLM_NUM_CONCURRENT}" != "1" ]]; then
        extra="${extra},num_concurrent=${VLLM_NUM_CONCURRENT}"
      fi
      if [[ -n "${VLLM_EOS_STRING}" ]]; then
        printf 'model=openai/%s,eos_string=%s%s' "${model_id}" "${VLLM_EOS_STRING}" "${extra}"
      else
        printf 'model=openai/%s%s' "${model_id}" "${extra}"
      fi
      ;;
  esac
}

# ============================================================
# Redact api_key from a litellm model_args string for safe persistence.
# Matches `api_key=<value>` and replaces with `api_key=REDACTED`.
# Only used by run_bench when writing results.json.
# ============================================================
redact_model_args() {
  local s="$1"
  # Replace any api_key=<non-comma-or-end> with api_key=REDACTED.
  printf '%s' "${s}" | sed -E 's/(api_key=)[^,]*/\1REDACTED/g'
}

# ============================================================
# Run a single Pool B bench. Dispatches by bench name:
#   humaneval-plus, ifeval     → lm-evaluation-harness (this function)
#   bigcodebench-hard          → bigcodebench package (_run_bigcodebench_hard)
#
# Usage: run_bench <bench_name>
# ============================================================
run_bench() {
  local bench="$1"
  BENCH="${bench}"

  if [[ "${bench}" == "bigcodebench-hard" ]]; then
    _run_bigcodebench_hard
    return $?
  fi

  local model_id
  model_id="$(lib_model_id "${TARGET}")"

  local result_dir="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}/${bench}"
  local result_file="${result_dir}/results.json"

  if lib_should_skip "${result_file}"; then
    return 0
  fi

  mkdir -p "${result_dir}"
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local start_epoch
  start_epoch="$(date +%s)"

  log_info "Starting bench=${bench} target=${TARGET} model_id=${model_id}"

  local model_args
  model_args="$(build_model_args "${TARGET}")"

  # lm-evaluation-harness task names (verified via `lm-eval ls tasks` 2026-05-08).
  local lm_eval_task
  local -a lm_eval_extra_args=()
  case "${bench}" in
    humaneval-plus)
      # <CAMPAIGN>: use our local humaneval_plus_chat task (no assistant-message
      # prefill, single user prompt + regex code-block extraction). Upstream's
      # humaneval_plus is base-completion-only and produces pathological
      # 0/164 pass@1 against chat models. Upstream's *_instruct variants use
      # gen_prefix (assistant prefill), which Bedrock Anthropic Opus 4.7
      # explicitly rejects with "This model does not support assistant
      # message prefill". humaneval_plus_chat sidesteps both.
      lm_eval_task="humaneval_plus_chat"
      # HumanEval+ executes model-generated Python; lm-evaluation-harness
      # requires --confirm_run_unsafe_code IN ADDITION TO HF_ALLOW_CODE_EVAL=1
      # (the env var gates HF's `evaluate.code_eval`; the CLI flag gates
      # lm-eval's own task-runner). Without it, task-load aborts with
      # ValueError("...marked as unsafe. Set confirm_run_unsafe_code=True...")
      # See benchmarks-<CAMPAIGN> (HF_ALLOW_CODE_EVAL fix) and benchmarks-<CAMPAIGN>
      # (the second-gate fix).
      lm_eval_extra_args+=("--confirm_run_unsafe_code")
      ;;
    ifeval)
      # ifeval_chat (<CAMPAIGN>): vendored copy of upstream ifeval that tolerates
      # response.content=None from reasoning models. vLLM PR #35230 codified
      # the None-on-truncation behavior; upstream lm-eval has not merged its
      # fix yet (PR #3709 in review). See scripts/runners/lm-eval-tasks/
      # ifeval_chat.yaml + ifeval_utils.py.
      lm_eval_task="ifeval_chat"
      ;;
    *)
      log_error "Unknown bench in run_bench: ${bench}"
      return 1
      ;;
  esac

  # Raw output dir for lm-eval artifacts (separate from our results.json)
  local raw_output_dir="${result_dir}/lm-eval-raw"
  mkdir -p "${raw_output_dir}"

  log_info "Invoking lm-evaluation-harness bench=${bench} task=${lm_eval_task}"

  # Verified invocation (discovery 2026-05-08). Notes:
  #   - We invoke the patched wrapper (lm-eval-patched.py), NOT the venv's
  #     bare `lm-eval` binary. The wrapper imports _litellm_patches.py first
  #     so Opus 4.7 calls have temperature/top_p/top_k stripped before
  #     hitting Bedrock (litellm issue #26444).
  #   - --batch_size 1 is required for API backends (no real batching).
  #   - --apply_chat_template needed for instruction-tuned frontier models.
  #   - --num_fewshot 0: frontier models don't need few-shot priming.
  #   - --log_samples writes per-prompt JSONL alongside the aggregate JSON;
  #     useful for delta investigation if numbers diverge from anchors.
  #   - HF_ALLOW_CODE_EVAL=1 is REQUIRED for any code-execution benchmark
  #     (HumanEval+, BigCodeBench, etc.). HF's `evaluate` library's code_eval
  #     metric runs model-generated Python and refuses to start without this
  #     opt-in. Per HF docs the host should be sandboxed; we run on a
  #     dedicated EC2 with no SSH ingress and instance-role IAM only, so
  #     the sandboxing requirement is satisfied. Scoped to the lm-eval call,
  #     not exported to the whole script, so non-code-eval invocations
  #     (e.g. ifeval) don't have a destructive-code-OK flag set.
  #
  # Token usage capture (<CAMPAIGN>-followup): _litellm_patches.py registers an
  # atexit hook that flushes aggregated prompt/completion token counts to
  # this path when the lm-eval process exits.
  local usage_file="${result_dir}/usage.json"

  # Smoke mode: pass --limit N to lm-eval. Tagged into extra_json so a stale
  # smoke result.json can't be mistaken for a full-run number.
  local -a smoke_args=()
  if [[ -n "${SMOKE_LIMIT}" ]]; then
    smoke_args+=("--limit" "${SMOKE_LIMIT}")
    log_warn "SMOKE MODE: bench=${bench} capped at ${SMOKE_LIMIT} samples — result is NOT a full-run number"
  fi

  # PIPESTATUS check below is required (not just pipefail+errexit): when
  # run_bench is invoked from a conditional context (e.g. `( run_bench ... )
  # || rc=$?` in main's per-bench loop), bash suppresses errexit inside the
  # function, so a failed lm-eval would be silently swallowed and we'd parse
  # a missing results JSON. See benchmarks-<CAMPAIGN>.
  #
  # Env-var prefix assembled as an array fed to `env`, since conditional
  # env-var assignments via array expansion (e.g. "${arr[@]+...}") are seen as
  # command words after expansion and won't take effect as env-var prefixes
  # to a simple command. `env VAR=val ... cmd` always works.
  #
  # vllm target: lm-eval's LiteLLMChatCompletion._create_payload doesn't
  # forward api_base / api_key from --model_args to litellm.completion(),
  # so the only way to redirect litellm at a custom OpenAI-compatible
  # endpoint is via env vars OPENAI_API_BASE + OPENAI_API_KEY (which the
  # litellm openai provider reads on every call). Verified 2026-05-09
  # smoke — without OPENAI_API_BASE the runner hits real api.openai.com.
  # For non-vllm targets these are harmless (Bedrock uses instance role;
  # gpt55 uses OPENAI_API_KEY env via lib_setup_gpt55_key but does NOT set
  # OPENAI_API_BASE — it routes to the default api.openai.com).
  local -a env_prefix=(
    "HF_ALLOW_CODE_EVAL=1"
    "LITELLM_PATCH_USAGE_OUT=${usage_file}"
  )
  if [[ "${TARGET}" == "vllm" ]]; then
    env_prefix+=(
      "OPENAI_API_KEY=${VLLM_API_KEY}"
      "OPENAI_API_BASE=${VLLM_API_BASE}"
    )
    # Forward extra_body (e.g. {"chat_template_kwargs":{"enable_thinking":false}})
    # via env var read by _litellm_patches._inject_extra_body. We pass even when
    # empty so a stale value from the parent shell doesn't leak into this run.
    env_prefix+=("LM_EVAL_VLLM_EXTRA_BODY=${VLLM_EXTRA_BODY}")
  fi

  env "${env_prefix[@]}" \
  "${LM_EVAL_PYTHON}" "${LM_EVAL_WRAPPER}" run \
    --model litellm \
    --model_args "${model_args}" \
    --tasks "${lm_eval_task}" \
    --include_path "${LM_EVAL_TASK_DIR}" \
    --num_fewshot 0 \
    --apply_chat_template \
    --output_path "${raw_output_dir}" \
    --log_samples \
    --batch_size 1 \
    "${lm_eval_extra_args[@]+"${lm_eval_extra_args[@]}"}" \
    "${smoke_args[@]+"${smoke_args[@]}"}" \
    2>&1 | tee -a "${LIB_RUNNER_LOG}"
  local lm_eval_rc="${PIPESTATUS[0]}"
  if (( lm_eval_rc != 0 )); then
    log_error "lm-evaluation-harness failed bench=${bench} task=${lm_eval_task} exit_code=${lm_eval_rc}"
    return 1
  fi

  local completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local end_epoch
  end_epoch="$(date +%s)"
  local wall_secs=$(( end_epoch - start_epoch ))

  # lm-eval writes results_<timestamp>.json into a model-named subdir under
  # --output_path. Find the most recent and parse pass-rate.
  # Schema: .results.<task_name>.<metric>,none  (where metric varies per task)
  # Token counts: lm-eval does NOT natively aggregate tokens for API backends.
  # Parsing per-prompt usage from the --log_samples JSONL is a follow-up
  # (<CAMPAIGN>-followup); leaving as 0 for the smoke run.
  local pass_rate n_tasks tokens_in tokens_out
  local lm_eval_results_json
  lm_eval_results_json="$(find "${raw_output_dir}" -name 'results_*.json' -type f 2>/dev/null | sort | tail -1)"
  if [[ -z "${lm_eval_results_json}" ]]; then
    log_error "lm-eval produced no results_*.json in ${raw_output_dir}"
    return 1
  fi

  case "${bench}" in
    humaneval-plus)
      # HumanEval+ reports pass@1 with a task-config-dependent filter suffix
      # (e.g. ',create_test' for the lm-eval humaneval_plus task — observed
      # 2026-05-08, see <CAMPAIGN>). Prefer any 'pass@1,*' key; fall back to
      # 'pass_at_1,*' or 'acc,*'. Exclude '*_stderr' keys.
      pass_rate="$(jq -r --arg t "${lm_eval_task}" '
        ([.results[$t] | to_entries[]
          | select(.key | test("^(pass@1|pass_at_1|acc),(?!.*_stderr)"))
          | .value
        ] | first) // 0
      ' "${lm_eval_results_json}" 2>/dev/null || printf '0')"
      ;;
    ifeval)
      # IFEval headline score: prompt_level_strict_acc (the strictest of the
      # four). Match the metric regardless of filter suffix (see <CAMPAIGN>).
      pass_rate="$(jq -r --arg t "${lm_eval_task}" '
        ([.results[$t] | to_entries[]
          | select(.key | test("^prompt_level_strict_acc,(?!.*_stderr)"))
          | .value
        ] | first) // 0
      ' "${lm_eval_results_json}" 2>/dev/null || printf '0')"
      ;;
  esac
  n_tasks="$(jq -r --arg t "${lm_eval_task}" \
    '.["n-samples"][$t].effective // 0' \
    "${lm_eval_results_json}" 2>/dev/null || printf '0')"

  # Token counts come from the litellm patch's atexit-flushed usage.json
  # (<CAMPAIGN>-followup). If the file is absent (older patch on box, env var
  # unset, lm-eval crashed before atexit), default to 0.
  if [[ -f "${usage_file}" ]]; then
    tokens_in="$(jq -r '.prompt_tokens // 0' "${usage_file}" 2>/dev/null || printf '0')"
    tokens_out="$(jq -r '.completion_tokens // 0' "${usage_file}" 2>/dev/null || printf '0')"
  else
    tokens_in=0
    tokens_out=0
    log_warn "Usage file not produced bench=${bench} (${usage_file}); tokens_in/out=0"
  fi

  local smoke_flag="false"
  [[ -n "${SMOKE_LIMIT}" ]] && smoke_flag="true"
  # Redact api_key=<value> from the persisted model_args (vllm target
  # carries the literal Bearer token in there; never write it to disk).
  local model_args_safe
  model_args_safe="$(redact_model_args "${model_args}")"
  local extra_json
  # Capture chat_template_kwargs (enable_thinking, etc.) and num_concurrent
  # from the live config so downstream aggregators can isolate thinking-mode
  # as a comparison variable later (<CAMPAIGN>: thinking is a measurement axis
  # we want to track separately from the model/quant axis).
  local extra_body_json="${VLLM_EXTRA_BODY:-}"
  [[ -z "${extra_body_json}" ]] && extra_body_json="null"
  extra_json="$(jq -n \
    --arg     task        "${lm_eval_task}" \
    --arg     model_args  "${model_args_safe}" \
    --arg     raw_dir     "${raw_output_dir}" \
    --argjson smoke       "${smoke_flag}" \
    --arg     smoke_limit "${SMOKE_LIMIT:-}" \
    --arg     vllm_url    "${VLLM_URL:-}" \
    --arg     vllm_model  "${VLLM_MODEL:-}" \
    --arg     vllm_concurrent "${VLLM_NUM_CONCURRENT:-1}" \
    --argjson vllm_extra_body "${extra_body_json}" \
    '{
      "lm_eval_task": $task,
      "model_args": $model_args,
      "raw_output_dir": $raw_dir,
      "smoke": $smoke,
      "smoke_limit": (if $smoke_limit == "" then null else ($smoke_limit | tonumber) end),
      "vllm_url": (if $vllm_url == "" then null else $vllm_url end),
      "vllm_model": (if $vllm_model == "" then null else $vllm_model end),
      "vllm_num_concurrent": ($vllm_concurrent | tonumber),
      "vllm_extra_body": $vllm_extra_body,
      "enable_thinking": (try $vllm_extra_body.chat_template_kwargs.enable_thinking catch null)
    }')"

  write_result_json \
    "${result_file}" \
    "${bench}" \
    "${model_id}" \
    "${started_at}" \
    "${completed_at}" \
    "${wall_secs}" \
    "${pass_rate}" \
    "${n_tasks}" \
    "${tokens_in}" \
    "${tokens_out}" \
    "${extra_json}"

  # Sync this bench's results to S3 immediately — don't wait for script exit
  s3_sync_results "${bench}"

  log_info "Completed bench=${bench} wall_time_seconds=${wall_secs} pass_rate=${pass_rate}"
}

# ============================================================
# Run bigcodebench-hard via the `bigcodebench` pip package
# (`python -m bigcodebench.evaluate`). Wired only for --target=vllm —
# Bedrock/Anthropic-direct support is deferred (bigcodebench's --backend
# anthropic does not accept Bedrock cross-region inference profile model IDs).
#
# For non-vllm targets, a status=skipped marker is written so downstream
# parsers can distinguish 'intentionally not run' from 'errored out'.
# ============================================================
_run_bigcodebench_hard() {
  local bench="bigcodebench-hard"
  BENCH="${bench}"

  local model_id
  model_id="$(lib_model_id "${TARGET}")"

  local result_dir="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}/${bench}"
  local result_file="${result_dir}/results.json"

  if lib_should_skip "${result_file}"; then
    return 0
  fi

  mkdir -p "${result_dir}"

  # Per-target backend config for the bigcodebench generate phase.
  # vllm: existing path. gpt55: openai-direct via a monkey-patch shim
  # (bd <ISSUE>) that strips temperature/top_p (gpt-5.x server rejects them).
  # opus47/opus46: monkey-patch shim that replaces bigcodebench's make_request
  # with a litellm.completion call against the Bedrock cross-region inference
  # profile (bd <ISSUE>). _litellm_patches.py handles the Opus 4.x server-side
  # quirks (temp/top_p drop on 4.7; trailing-ws strip + empty-stops drop on
  # all Bedrock Anthropic).
  local bcb_model_id="" bcb_api_key="" bcb_base_url="" bcb_max_tokens=""
  case "${TARGET}" in
    vllm)
      bcb_model_id="${VLLM_MODEL_ID}"
      bcb_api_key="${VLLM_API_KEY}"
      bcb_base_url="${VLLM_API_BASE}"
      bcb_max_tokens="${VLLM_BCB_MAX_TOKENS}"
      ;;
    gpt55)
      bcb_model_id="${GPT55_MODEL_ID}"
      bcb_api_key="${OPENAI_API_KEY:-}"
      bcb_base_url=""  # openai SDK default = https://api.openai.com/v1
      bcb_max_tokens="${GPT55_BCB_MAX_TOKENS}"
      if [[ -z "${bcb_api_key}" ]]; then
        log_error "bench=${bench} target=gpt55 but OPENAI_API_KEY is empty (lib_setup_gpt55_key should have set this)"
        return 1
      fi
      ;;
    opus47|opus46)
      # bcb_model_id is the bare Bedrock inference profile id (e.g.
      # us.anthropic.claude-opus-4-7). The shim prepends 'bedrock/' before
      # handing it to litellm. Passed to bigcodebench's --model arg as well
      # for output-filename purposes; the openai client constructed by the
      # backend is never actually used (make_request is replaced).
      bcb_model_id="${model_id}"
      # bigcodebench's openai backend requires OPENAI_API_KEY be non-empty
      # at openai.OpenAI() construction time, but the replaced make_request
      # never touches the network through it. Placeholder is fine.
      bcb_api_key="bedrock-placeholder-key"
      bcb_base_url=""  # ignored — shim routes via litellm.completion
      bcb_max_tokens="${OPUS47_BCB_MAX_TOKENS}"
      ;;
    *)
      log_warn "bench=${bench} not currently wired for target=${TARGET}; writing skip marker"
      local skip_ts
      skip_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      jq -n \
        --arg campaign     "${CAMPAIGN}" \
        --arg target       "${TARGET}" \
        --arg bench        "${bench}" \
        --arg model_id     "${model_id}" \
        --arg started_at   "${skip_ts}" \
        --arg completed_at "${skip_ts}" \
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
          status:             "skipped",
          skip_reason:        "bigcodebench-hard not wired for this target (vllm + gpt55 + opus47/opus46 are supported)"
        }' > "${result_file}"
      s3_sync_results "${bench}"
      log_info "bench=${bench} skipped for target=${TARGET}"
      return 0
      ;;
  esac

  local started_at start_epoch
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start_epoch="$(date +%s)"

  log_info "Starting bench=${bench} target=${TARGET} model_id=${model_id} via bigcodebench"

  # bigcodebench writes its artifacts to ./bcb_results/ in cwd. We chdir
  # into a per-bench scratch dir so artifacts land alongside our results.json
  # and don't pollute the runner's working directory.
  local raw_output_dir="${result_dir}/bcb-raw"
  mkdir -p "${raw_output_dir}"

  # Smoke mode is not directly supported by bigcodebench (no --limit); the
  # closest equivalent is `--selective_evaluate` with task IDs, which would
  # require a separate task-id list. For now, smoke runs are a follow-up.
  if [[ -n "${SMOKE_LIMIT}" ]]; then
    log_warn "SMOKE MODE requested but bigcodebench-hard does not currently support --limit; running full Hard subset (148 tasks)"
  fi

  # Two-phase: GENERATE from lm-eval venv → samples.jsonl in raw_output_dir/
  # bcb_results/, then EVALUATE inside the upstream Docker image with the
  # samples mounted in. This split avoids installing bigcodebench's heavy
  # 74-package requirements-eval.txt on the host (bap + bd memory
  # feedback-max-2026-05-09-pinning-outdated-versions).
  #
  # --no_gt: skip the ground-truth-solution sanity-check phase (it re-runs
  #   canonical solutions; adds wall-time without affecting model scores).
  # --pass_k 1: pass@1 only (greedy, our profile).
  # --temperature 0 --n_samples 1: greedy.

  # ---- Phase 1: generate samples (lm-eval venv has bigcodebench installed,
  #               only needs openai client + datasets at this stage) ----
  # For target=gpt55, the upstream openai backend hard-codes top_p=0.95 and
  # passes temperature=<arg> straight through — both rejected by gpt-5.x
  # ("Only the default (1) value is supported"). Patch via a monkey-patch
  # shim that replaces bigcodebench.gen.util.openai_request.make_request
  # before runpy-ing the generate module. bd <ISSUE>.
  #
  # For target=opus47/opus46, bigcodebench has no Bedrock backend; the shim
  # replaces make_request to route via litellm.completion(model=bedrock/...).
  # The runner dir is added to sys.path so the shim can import
  # _litellm_patches and pick up the existing Opus 4.x Bedrock quirks. bd <ISSUE>.
  local bcb_rc=0
  if [[ "${TARGET}" == "gpt55" ]]; then
    log_info "bigcodebench generate phase (target=gpt55 model=${bcb_model_id} max_tokens=${bcb_max_tokens})"
    local shim_py="${raw_output_dir}/_bcb_gpt5_shim.py"
    cat > "${shim_py}" <<'PYSHIM'
"""Run bigcodebench.generate with a make_request monkey-patch that handles
gpt-5.x server-side parameter restrictions (no temperature, no top_p,
max_completion_tokens instead of max_tokens — though max_tokens rename is
already done upstream).

Invoked by run-pool-b.sh::_run_bigcodebench_hard for TARGET=gpt55.
"""
import re
import runpy
import sys

from bigcodebench.gen.util import openai_request as _orq

_GPT5_RE = re.compile(r"^(openai/)?gpt-5([.\-]|$)")


def _make_request_gpt5_aware(
    client,
    message,
    model,
    max_tokens=512,
    temperature=1,
    reasoning_effort="medium",
    n=1,
    **kwargs,
):
    if _GPT5_RE.match(model):
        # gpt-5.x: server requires default temperature (1), rejects max_tokens
        # (must be max_completion_tokens — which the openai SDK already maps),
        # and we omit top_p to avoid the same default-only gate firing on it.
        kwargs["max_completion_tokens"] = max_tokens
        kwargs.pop("top_p", None)
        kwargs.pop("temperature", None)
    elif model.startswith("o1-") or model.startswith("o3-") or model.endswith("-reasoner"):
        kwargs["reasoning_effort"] = reasoning_effort
    else:
        kwargs["top_p"] = 0.95
        kwargs["max_completion_tokens"] = max_tokens
        kwargs["temperature"] = temperature
    return client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": message}],
        n=n,
        **kwargs,
    )


_orq.make_request = _make_request_gpt5_aware

sys.argv = ["bigcodebench.generate"] + sys.argv[1:]
runpy.run_module("bigcodebench.generate", run_name="__main__")
PYSHIM
    (
      cd "${raw_output_dir}"
      OPENAI_API_KEY="${bcb_api_key}" \
      "${LM_EVAL_PYTHON}" "${shim_py}" \
        --model "${bcb_model_id}" \
        --split instruct \
        --subset hard \
        --backend openai \
        --temperature 0 \
        --max_new_tokens "${bcb_max_tokens}" \
        --n_samples 1
    ) 2>&1 | tee -a "${LIB_RUNNER_LOG}"
    bcb_rc="${PIPESTATUS[0]}"
  elif [[ "${TARGET}" == "opus47" || "${TARGET}" == "opus46" ]]; then
    log_info "bigcodebench generate phase (target=${TARGET} bedrock_model=${bcb_model_id} region=${LIB_REGION} max_tokens=${bcb_max_tokens})"
    local shim_py="${raw_output_dir}/_bcb_opus47_shim.py"
    cat > "${shim_py}" <<'PYSHIM'
"""Run bigcodebench.generate against Bedrock Anthropic (Opus 4.x cross-region
inference profile) by replacing bigcodebench's openai make_request with a
litellm.completion call. bigcodebench has no native Bedrock backend; --backend
anthropic doesn't accept Bedrock inference-profile IDs.

Imports _litellm_patches first (rebinds litellm.completion to scrub Opus 4.7
server-side quirks: drops temperature/top_p/top_k, strips trailing whitespace
on assistant messages, drops empty stop sequences). Bedrock auth uses the
EC2 instance role via boto3 — no API keys.

Invoked by run-pool-b.sh::_run_bigcodebench_hard for TARGET=opus47/opus46.
"""
import os
import runpy
import sys

# Make _litellm_patches importable before any litellm.completion call.
_RUNNERS_DIR = os.environ["BCB_OPUS47_RUNNERS_DIR"]
if _RUNNERS_DIR not in sys.path:
    sys.path.insert(0, _RUNNERS_DIR)
import _litellm_patches  # noqa: F401  -- side-effect: rebinds litellm.completion

import litellm
from bigcodebench.gen.util import openai_request as _orq

_BEDROCK_MODEL = "bedrock/" + os.environ["BCB_OPUS47_BEDROCK_MODEL_ID"]
_AWS_REGION = os.environ["BCB_OPUS47_AWS_REGION"]


def _make_request_opus_bedrock(
    client,
    message,
    model,
    max_tokens=512,
    temperature=1,
    reasoning_effort="medium",
    n=1,
    **kwargs,
):
    """Route via litellm.completion to Bedrock. The `client` and `model` args
    from bigcodebench's openai backend are ignored — we use the Bedrock model
    id from env. temperature/top_p are dropped by _litellm_patches for Opus
    4.7; for 4.6 they pass through. n>1 is not supported on this path
    (bigcodebench's profile uses n=1 anyway)."""
    return litellm.completion(
        model=_BEDROCK_MODEL,
        aws_region_name=_AWS_REGION,
        messages=[{"role": "user", "content": message}],
        max_tokens=max_tokens,
    )


_orq.make_request = _make_request_opus_bedrock

sys.argv = ["bigcodebench.generate"] + sys.argv[1:]
runpy.run_module("bigcodebench.generate", run_name="__main__")
PYSHIM
    (
      cd "${raw_output_dir}"
      OPENAI_API_KEY="${bcb_api_key}" \
      BCB_OPUS47_RUNNERS_DIR="${RUNNER_SCRIPT_DIR}" \
      BCB_OPUS47_BEDROCK_MODEL_ID="${bcb_model_id}" \
      BCB_OPUS47_AWS_REGION="${LIB_REGION}" \
      "${LM_EVAL_PYTHON}" "${shim_py}" \
        --model "${bcb_model_id}" \
        --split instruct \
        --subset hard \
        --backend openai \
        --temperature 0 \
        --max_new_tokens "${bcb_max_tokens}" \
        --n_samples 1
    ) 2>&1 | tee -a "${LIB_RUNNER_LOG}"
    bcb_rc="${PIPESTATUS[0]}"
  else
    log_info "bigcodebench generate phase (vllm endpoint=${bcb_base_url} model=${bcb_model_id})"
    (
      cd "${raw_output_dir}"
      OPENAI_API_KEY="${bcb_api_key}" \
      "${LM_EVAL_PYTHON}" -m bigcodebench.generate \
        --model "${bcb_model_id}" \
        --split instruct \
        --subset hard \
        --backend openai \
        --base_url "${bcb_base_url}" \
        --temperature 0 \
        --max_new_tokens "${bcb_max_tokens}" \
        --n_samples 1
    ) 2>&1 | tee -a "${LIB_RUNNER_LOG}"
    bcb_rc="${PIPESTATUS[0]}"
  fi
  if (( bcb_rc != 0 )); then
    log_error "bigcodebench generate failed bench=${bench} exit_code=${bcb_rc}"
    return 1
  fi

  # The samples land in raw_output_dir/bcb_results/<...>-sanitized_calibrated.jsonl.
  local samples_jsonl samples_basename
  samples_jsonl="$(find "${raw_output_dir}/bcb_results" -name '*sanitized_calibrated.jsonl' \
                   -type f -printf '%T@ %p\n' 2>/dev/null \
                   | sort -k1nr | head -1 | cut -d' ' -f2-)"
  if [[ -z "${samples_jsonl}" || ! -f "${samples_jsonl}" ]]; then
    log_error "bigcodebench generate produced no sanitized_calibrated.jsonl under ${raw_output_dir}/bcb_results"
    return 1
  fi
  samples_basename="$(basename -- "${samples_jsonl}")"
  log_info "bigcodebench generate complete: ${samples_jsonl}"

  # ---- Phase 1.5: None-tolerance filter (<CAMPAIGN>) ----
  # bigcodebench/sanitize.py crashes with TypeError on null `solution` fields
  # in samples.jsonl. vLLM emits content=None when a reasoning model truncates
  # inside the <think> block (codified by vLLM PR #35230, 2026-02-26). Replace
  # null/missing solution fields with "" so the docker eval sees a string and
  # scores those tasks as failed (empty completion = SyntaxError verdict).
  # Stats are logged for diagnostic visibility.
  python3 - <<EOF | tee -a "${LIB_RUNNER_LOG}"
import json, os
path = "${samples_jsonl}"
stats_path = os.path.join(os.path.dirname(path), "bcb-none-filter-stats.json")
total = 0
null_solutions = 0
lines = []
with open(path) as f:
    for raw in f:
        if not raw.strip():
            continue
        rec = json.loads(raw)
        total += 1
        sol = rec.get("solution")
        if sol is None or not isinstance(sol, str):
            null_solutions += 1
            rec["solution"] = ""
        lines.append(json.dumps(rec))
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
# bd <ISSUE>: persist counters so future audits don't need to re-fetch samples
# JSONL. The aggregator + downstream audits read this file from S3.
null_rate = (null_solutions / total) if total > 0 else 0.0
with open(stats_path, "w") as f:
    json.dump({"null_solutions": null_solutions, "total": total, "null_rate": null_rate}, f)
print(f"[bcb-none-filter] {null_solutions}/{total} samples had null/non-str solution; replaced with '' for eval (null_rate={null_rate:.3f}, stats={stats_path})")
EOF

  # ---- Phase 2: evaluate inside upstream docker image ----
  # --user 0:0: the image's default user can't write to the root-owned mount
  # (run-pool-b is invoked via sudo, so the host dir is root-owned). Smoke
  # 2026-05-09 hit PermissionError on eval_results.json without this.
  # --pass_k INTENTIONALLY OMITTED: passing `--pass_k 1` makes Fire CLI
  # interpret it as int 1, then bigcodebench/evaluate.py:367 calls
  # pass_at_k.update({k: ... for k in pass_k}) — iterating over an int
  # raises TypeError. Default `--pass_k 1,5,10` (string) avoids the bug;
  # pass@1 is what we care about, the others are computed-but-unused for
  # n_samples=1.
  #
  # Pre-clean prior eval outputs: bigcodebench's evaluate is INTERACTIVE
  # when *_eval_results.json already exists ("Press [Y/N] to overwrite"),
  # which deadlocks under docker without a TTY (EOFError on stdin). Delete
  # them so the eval always runs fresh. Samples jsonl is preserved (phase-1
  # output, eval reads it).
  rm -f "${raw_output_dir}/bcb_results/"*_eval_results.json \
        "${raw_output_dir}/bcb_results/"*_pass_at_k.json 2>/dev/null || true

  log_info "bigcodebench evaluate phase (docker image=${BCB_DOCKER_IMAGE})"
  docker run --rm --user 0:0 \
    -v "${raw_output_dir}/bcb_results:/app" \
    "${BCB_DOCKER_IMAGE}" \
      --execution local \
      --split instruct \
      --subset hard \
      --no_gt \
      --samples "${samples_basename}" \
    2>&1 | tee -a "${LIB_RUNNER_LOG}"
  bcb_rc="${PIPESTATUS[0]}"
  if (( bcb_rc != 0 )); then
    log_error "bigcodebench evaluate (docker) failed bench=${bench} exit_code=${bcb_rc}"
    return 1
  fi

  local completed_at end_epoch wall_secs
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end_epoch="$(date +%s)"
  wall_secs=$(( end_epoch - start_epoch ))

  # Parse the most-recent pass_at_k.json. bigcodebench names the file:
  #   <model_name_with_slashes_replaced>--bigcodebench-instruct--openai-0-1-sanitized_calibrated_pass_at_k.json
  # Use `-printf %T@ %p` so we can pick the most-recent file safely without
  # piping through xargs (avoids SC2038 around exotic filenames).
  _bcb_find_latest() {
    find "$1" -name "$2" -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -k1nr | head -1 | cut -d' ' -f2-
  }

  local pass_at_k_json eval_results_json samples_jsonl
  pass_at_k_json="$(_bcb_find_latest "${raw_output_dir}/bcb_results" '*pass_at_k.json')"
  if [[ -z "${pass_at_k_json}" ]]; then
    log_error "bigcodebench produced no pass_at_k.json under ${raw_output_dir}/bcb_results"
    return 1
  fi

  local pass_rate n_tasks
  pass_rate="$(jq -r '."pass@1" // 0' "${pass_at_k_json}" 2>/dev/null || printf '0')"

  # n_tasks: prefer eval_results.json (one entry per task); fall back to
  # counting the .jsonl samples; final fallback to the published Hard size.
  eval_results_json="$(_bcb_find_latest "${raw_output_dir}/bcb_results" '*_eval_results.json')"
  samples_jsonl="$(_bcb_find_latest "${raw_output_dir}/bcb_results" '*sanitized_calibrated.jsonl')"
  if [[ -n "${eval_results_json}" ]]; then
    n_tasks="$(jq -r '(.eval // {}) | length' "${eval_results_json}" 2>/dev/null || printf '0')"
  elif [[ -n "${samples_jsonl}" ]]; then
    n_tasks="$(wc -l < "${samples_jsonl}" 2>/dev/null | tr -d ' ' || printf '0')"
  else
    n_tasks=0
  fi
  # Defensive fallback if both parses returned 0 but we got a pass_rate.
  if [[ "${n_tasks}" == "0" ]] && [[ "${pass_rate}" != "0" ]]; then
    n_tasks=148  # current BCB-Hard subset size
    log_warn "bench=${bench}: could not derive n_tasks from artifacts; defaulting to published Hard subset size 148"
  fi

  # Tokens: bigcodebench's openai backend uses the openai client directly,
  # not litellm; no usage aggregation hook is in place. Leave 0 for now;
  # vLLM serve-side logs have per-request counts if needed retroactively.
  local tokens_in=0 tokens_out=0

  # Capture thinking-state per result (<CAMPAIGN>): same rationale as the lm-eval
  # branch — thinking-mode is a measurement axis we want to track separately
  # from the model/quant axis. enable_thinking is derived from VLLM_EXTRA_BODY.
  local extra_body_json="${VLLM_EXTRA_BODY:-}"
  [[ -z "${extra_body_json}" ]] && extra_body_json="null"

  # bd <ISSUE>: pick up [bcb-none-filter] stats sidecar (truncation telemetry).
  local none_filter_path none_filter_json
  none_filter_path="${raw_output_dir}/bcb_results/bcb-none-filter-stats.json"
  if [[ -f "${none_filter_path}" ]]; then
    none_filter_json="$(cat "${none_filter_path}")"
  else
    none_filter_json="null"
  fi

  local extra_json
  extra_json="$(jq -n \
    --arg     pass_at_k_path  "${pass_at_k_json}" \
    --arg     samples_path    "${samples_jsonl}" \
    --arg     eval_results    "${eval_results_json}" \
    --arg     vllm_url        "${VLLM_API_BASE}" \
    --arg     vllm_model      "${VLLM_MODEL_ID}" \
    --arg     bcb_split       "instruct" \
    --arg     bcb_subset      "hard" \
    --argjson bcb_calibrated  true \
    --argjson vllm_extra_body "${extra_body_json}" \
    --argjson bcb_none_filter "${none_filter_json}" \
    '{
      bigcodebench_runner:  "python -m bigcodebench.evaluate",
      pass_at_k_path:       $pass_at_k_path,
      samples_path:         (if $samples_path == "" then null else $samples_path end),
      eval_results_path:    (if $eval_results == "" then null else $eval_results end),
      bcb_split:            $bcb_split,
      bcb_subset:           $bcb_subset,
      bcb_calibrated:       $bcb_calibrated,
      vllm_url:             $vllm_url,
      vllm_model:           $vllm_model,
      vllm_extra_body:      $vllm_extra_body,
      enable_thinking:      (try $vllm_extra_body.chat_template_kwargs.enable_thinking catch null),
      vllm_num_concurrent:  null,
      tokens_capture:       "not_implemented_for_bigcodebench",
      tokens_capture_note:  "bigcodebench uses its own openai client (not litellm); --vllm-num-concurrent does not apply here",
      bcb_none_filter:      $bcb_none_filter
    }')"

  write_result_json \
    "${result_file}" \
    "${bench}" \
    "${model_id}" \
    "${started_at}" \
    "${completed_at}" \
    "${wall_secs}" \
    "${pass_rate}" \
    "${n_tasks}" \
    "${tokens_in}" \
    "${tokens_out}" \
    "${extra_json}"

  s3_sync_results "${bench}"

  log_info "Completed bench=${bench} wall_time_seconds=${wall_secs} pass_rate=${pass_rate} n_tasks=${n_tasks}"
}

# ============================================================
# Regenerate the cross-campaign sweep dashboard at docs/results/sweep-status.md
# from S3-backed canonical results.json files. Best-effort: a regen failure
# does NOT change the pool-b exit code — the bench results that just landed
# are still in S3 and the operator can re-regen by hand.
# ============================================================
regen_sweep_status() {
  local script="${RUNNER_SCRIPT_DIR}/../update-sweep-status.sh"
  if [[ ! -x "${script}" ]]; then
    log_warn "update-sweep-status.sh not found at ${script}; skipping dashboard regen"
    return 0
  fi
  log_info "Regenerating docs/results/sweep-status.md from S3"
  if ! bash "${script}" 2>&1 | tee -a "${LIB_RUNNER_LOG}"; then
    log_warn "update-sweep-status.sh exited non-zero; dashboard may be stale (re-run by hand on harness)"
  fi
}

# ============================================================
# Main
#
# Per-bench resilience (benchmarks-<CAMPAIGN>): each run_bench call runs in a
# subshell with ERR/EXIT traps cleared. A failure inside the subshell exits
# the subshell with non-zero (errexit is inherited), is captured here via
# `|| rc=$?`, and is recorded as a failure marker — without firing the
# orchestration-level ERR trap or aborting subsequent benches.
# Final exit code: 0 if all passed, 1 if any failed (operator signal).
# ============================================================
main() {
  parse_args "$@"
  preflight

  log_info "Starting Pool B run campaign=${CAMPAIGN} target=${TARGET}"

  local model_id
  model_id="$(lib_model_id "${TARGET}")"

  local bench
  local rc started_at error_excerpt result_file
  local n_passed=0
  local n_failed=0
  local -a failed_benches=()
  local -r n_total="${#ACTIVE_BENCHES[@]}"

  for bench in "${ACTIVE_BENCHES[@]}"; do
    BENCH="${bench}"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rc=0
    (
      trap - ERR EXIT
      run_bench "${bench}"
    ) || rc=$?

    if (( rc == 0 )); then
      (( ++n_passed ))
      continue
    fi

    (( ++n_failed ))
    failed_benches+=("${bench}")
    log_error "Bench failed bench=${bench} exit_code=${rc}; recording failure marker and continuing"

    result_file="${LIB_RESULTS_BASE}/${CAMPAIGN}/${TARGET}/${bench}/results.json"
    error_excerpt="$(lib_log_tail_excerpt 30)"
    lib_write_failure_marker \
      "${result_file}" "${bench}" "${model_id}" \
      "${started_at}" "${rc}" "${error_excerpt}" \
      || log_warn "Failure marker write failed bench=${bench}"
    s3_sync_results "${bench}" \
      || log_warn "S3 sync after failure marker failed bench=${bench}"
  done

  regen_sweep_status

  if (( n_failed == 0 )); then
    log_info "Pool B complete campaign=${CAMPAIGN} target=${TARGET} passed=${n_passed}/${n_total}"
    return 0
  fi

  log_error "Pool B finished with failures campaign=${CAMPAIGN} target=${TARGET} passed=${n_passed}/${n_total} failed=[${failed_benches[*]}]"
  exit 1
}

main "$@"
