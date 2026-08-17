#!/usr/bin/env bash
# run-pool-a-cybergym.sh — Pool A CyberGym monitored runner (3-task or 10-task subset)
#
# Drives the CyberGym task subset against a single target model: Opus 4.7 via
# Bedrock, GPT-5.5 via OpenAI direct, or any OpenAI-compatible vLLM endpoint
# (e.g. a self-hosted model on a rented GPU box). Designed to run unattended
# after being invoked over SSH-over-SSM from a Proxmox sandbox.
#
# Differs from Pool B in three ways:
#   1. Per-task docker isolation (CyberGym harness manages containers)
#   2. Spend watchdog: hard cap on Bedrock cost delta; aborts mid-run cleanly
#      (bypassed for vllm and gpt55 targets — see WATCHDOG section below)
#   3. Progress reports: 60s heartbeat written to S3 for operator monitoring
#
# Usage: run-pool-a-cybergym.sh --target <opus47|gpt55|vllm> --campaign NAME [OPTIONS]
#
# Options:
#   --target opus47|gpt55|vllm
#                             Model target to evaluate (REQUIRED)
#   --campaign NAME           Campaign identifier (REQUIRED)
#   --spend-cap-usd FLOAT     Hard Bedrock spend cap in USD (default: 300)
#                             Ignored for --target vllm or gpt55 (watchdog bypassed)
#   --cybergym-subset 3|10|40|50
#                             Which task subset to run (default: 10 for vllm,
#                             3 for opus47/gpt55 — preserves existing <CAMPAIGN>
#                             behavior for frontier API targets). 40/50 are the
#                             seeded random POWERED subsets (bd 9g4.3.1); 40 ⊂ 50.
#   --reasoning-effort VALUE  none|minimal|low|medium|high. Flows to run.py's
#                             CYBERGYM_REASONING_EFFORT env -> config["llm"]
#                             ["reasoning_effort"] in the OpenHands config.toml
#                             (litellm passthrough). "none" = thinking-OFF.
#                             Omit to leave config.toml unchanged (default path).
#                             NOTE: only reasoning-capable models honor this; some
#                             vLLM servers / non-reasoning models reject the param.
#   --force                   Overwrite existing per-task results (default: skip if present)
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
#   --vllm-eos-string STR     Optional EOS token string to forward to the CyberGym
#                             agent harness (model-specific stop token). Required
#                             for models whose tokenizer's EOS isn't auto-derivable
#                             from the litellm/openai endpoint. Set to the
#                             chat-end token from the model's tokenizer_config
#                             (e.g. "<|im_end|>" for Qwen/ChatML, "<end_of_turn>"
#                             for Gemma). Default: empty (no eos_string).
#   --vllm-extra-body JSON    Optional JSON object forwarded as extra_body on
#                             every chat-completion request. Used to pass
#                             chat_template_kwargs to vLLM — most commonly
#                             {"chat_template_kwargs": {"enable_thinking": false}}
#                             to disable Qwen3's thinking-mode preamble.
#                             Default: empty (no extra_body).
#
# Exit codes:
#   0  — all tasks completed successfully
#   2  — spend cap exceeded; partial results synced to S3
#   1  — task failure or unexpected error; partial results synced to S3
#
# Runtime estimates (frontier API targets):
#   CyberGym 3-task:  ~2-3 hr total, ~$50-150/target
#   CyberGym 10-task: ~6-10 hr total (vllm rental, no spend watchdog)
#
# WATCHDOG:
#   For opus47 target: spend-watchdog.sh is called every 60s during task
#   execution. Exit 2 from watchdog triggers a clean abort and final S3
#   sync. If watchdog itself fails (CE unavailable), the run continues
#   (conservative). Spend baseline is sampled at run start.
#
#   For vllm and gpt55 targets: the Bedrock spend watchdog is BYPASSED
#   entirely — for vllm the correct cost gate is operator-side rental teardown
#   (rental-vllm-down.sh); for gpt55, OpenAI spend is not visible to Bedrock
#   Cost Explorer. The runner logs clearly when watchdog is bypassed so
#   operators know cost is not auto-capped.
#   # TODO(z1s.1): Adapt watchdog to rental hours for vllm targets — blocked
#   # on GPU telemetry integration tracked in benchmarks-<CAMPAIGN>.
#
# NO-PROGRESS / LOOP DETECTION (bd benchmarks-tz5; default-ON since 9g4.4):
#   A sidecar aborts a task early when it makes no progress — a STALL (no new
#   OpenHands event for CYBERGYM_STALL_SECS, default 600) or a LOOP (the modal
#   informative observation fills >= CYBERGYM_LOOP_THRESHOLD of the last
#   CYBERGYM_LOOP_WINDOW observations). Attacks the dominant Pool A wall term (the
#   ~10% of runs that loop to the 7200s cap). Pass/fail is unaffected (a real PASS
#   submits first); it only cuts wall + $. ON by default (validated on the real
#   ejv loopers, 9g4.4); set CYBERGYM_NOPROGRESS_ABORT=0 to reproduce a
#   pre-9g4.4 paired baseline exactly.
#   Knobs: CYBERGYM_STALL_SECS, CYBERGYM_LOOP_WINDOW, CYBERGYM_LOOP_THRESHOLD,
#   CYBERGYM_NOPROGRESS_MIN_EVENTS, CYBERGYM_NOPROGRESS_POLL_SECS,
#   CYBERGYM_NOPROGRESS_TERM_GRACE. Validated + tuning guide:
#   docs/research/cybergym-noprogress-detection-2026-06-14.md
#
# Progress reports:
#   Every 60s: s3://<RESULTS_BUCKET>/<campaign>/_progress/cybergym-<target>.log
#   Operator can monitor: aws s3 cp <above> - (prints to stdout, re-run to poll)
#
# Results land at:
#   Local:  /var/lib/harness/results/<campaign>/<target>/cybergym-N/
#   S3:     s3://<RESULTS_BUCKET>/<campaign>/<target>/cybergym-N/
#   (N = subset size: 3 for opus47/gpt55, 10 for vllm unless overridden by
#    --cybergym-subset)
#
# Prerequisites:
#   - install-harness.sh must have run (cybergym repo + docker present)
#   - Pool B must have completed (sanity gate: checked by run-frontier-baseline.sh)
#   - For opus47: instance role grants Bedrock access (no keys needed)
#   - For gpt55: OPENAI_API_KEY fetched from SSM /sandbox/api-keys/openai
#   - For vllm: rental endpoint running + accessible from harness EC2
#
# CyberGym harness reference: https://github.com/sunblaze-ucb/cybergym
# Design reference: docs/research/ec2-harness-design.md, docs/harness-setup.md
# Issue: benchmarks-<CAMPAIGN>, benchmarks-z1s

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RUNNER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly RUNNER_SCRIPT_DIR
RUNNER_NAME="run-pool-a-cybergym"
export RUNNER_NAME

# shellcheck source=scripts/runners/_lib.sh
source "${RUNNER_SCRIPT_DIR}/_lib.sh"
# shellcheck source=scripts/runners/_cybergym_common.sh
# Shared install-path constants (CYBERGYM_REPO / _PYTHON / _DATA_DIR / _AGENT_RUNNER /
# _OPENHANDS_RUNTIME_IMAGE) + write_progress. The per-task execution constants
# (task timeout/iter/difficulty/output-tokens, the no-progress knobs, the task-local
# grading server + its db) and the agent invocation now live in the hermetic per-task
# entrypoint run-one-cybergym-task.sh, which this dispatcher invokes per task.
# shellcheck source=scripts/runners/_cybergym_common.sh
source "${RUNNER_SCRIPT_DIR}/_cybergym_common.sh"

# ============================================================
# Constants
# ============================================================
# The hermetic per-task entrypoint this dispatcher shells out to (bd benchmarks-b51).
readonly CYBERGYM_TASK_ENTRYPOINT="${RUNNER_SCRIPT_DIR}/run-one-cybergym-task.sh"

# The bounded-pool parent (bd benchmarks-b51 Phase 2): a dependency-free STDLIB
# Python orchestrator that runs up to CYBERGYM_POOL_N hermetic entrypoints
# concurrently, owns signal fan-out + a docker reap backstop by cg_campaign label,
# and tallies each task's status.json. Run with the system python3 (no pip/venv/uv:
# the design floated `uv run`, but the operator clarified 2026-06-16 that the uv
# preference was only to avoid this host's pip/venv pain — a stdlib-only script
# needs none of that, so there is nothing to provision).
readonly CYBERGYM_POOL_DISPATCHER="${RUNNER_SCRIPT_DIR}/_cybergym_pool.py"
readonly CYBERGYM_POOL_PYTHON="${CYBERGYM_POOL_PYTHON:-python3}"

# Pool concurrency knob (bd benchmarks-b51). N tasks run AT ONCE. N=1 = today's
# strictly-sequential path (the parent runs tasks one-at-a-time in list order →
# byte-identical results, the acceptance bar). N is a per-n/per-host knob set by
# the harness-host CPU/disk knee — never bake one value in (design §8): the
# small-N validation floor is 4 on the dev VM; the powered run ramps to ~8–24.
readonly CYBERGYM_POOL_N="${CYBERGYM_POOL_N:-1}"

# N-aware disk preflight (design §8): each concurrent task burns ~15 GB transient
# (OpenHands runtime + grader images + CyberGym binary data + workspace + overlay2
# churn + logs). Budget N × this, floored at the old flat 30 GB. Tunable so the
# small-disk dev VM can run small-N validation without tripping the production budget.
readonly CYBERGYM_DISK_GB_PER_TASK="${CYBERGYM_DISK_GB_PER_TASK:-15}"

# 3-task subset task IDs (frontier API targets — <CAMPAIGN> behavior preserved)
# TODO(<CAMPAIGN>-followup): confirm exact CyberGym task IDs for the 3-task subset.
# The CyberGym 10-task representative subset is documented in the paper/repo;
# pick 3 from that set. Use numeric IDs or project/CVE identifiers per
# the harness's --task-id or --task-list argument format.
# Reference: https://github.com/sunblaze-ucb/cybergym (README, tasks/ directory)
readonly -a CYBERGYM_TASKS_3=("arvo:47101" "arvo:3938" "arvo:24993")

# 10-task subset task IDs — the "representative subset" from the CyberGym paper.
# Source: /opt/harnesses/cybergym/README.md (the "Download Server Data / Subset
# data" section), verified 2026-05-11 against the upstream README at
# https://github.com/sunblaze-ucb/cybergym. The subset is described as
# "5 tasks that the agent can successfully generate the PoC and 5 tasks that
# are not easy for the agent":
#   arvo:47101, arvo:3938, arvo:24993, arvo:1065, arvo:10400, arvo:368
#   oss-fuzz:42535201, oss-fuzz:42535468, oss-fuzz:370689421, oss-fuzz:385167047
readonly -a CYBERGYM_TASKS_10=(
  "arvo:47101"
  "arvo:3938"
  "arvo:24993"
  "arvo:1065"
  "arvo:10400"
  "arvo:368"
  "oss-fuzz:42535201"
  "oss-fuzz:42535468"
  "oss-fuzz:370689421"
  "oss-fuzz:385167047"
)

# 40-/50-task POWERED subsets (bd benchmarks-9g4.3.1). The existing 3/10 sets are
# a hand-picked "5 solvable + 5 not" demo subset — deliberately balanced, so NOT a
# representative pass-rate estimator. To honestly RANK dsv4pro/k2.6/k2.7 (9g4.3) we
# need an UNBIASED sample of the CyberGym task universe.
#
# CURATION (decided from the data, not by fiat):
#   - Universe = mask_map.json from the cybergym repo @ commit 3ae9067: 1507 gradeable
#     task IDs, 1368 arvo + 139 oss-fuzz. It is ENTIRELY C/C++ (arvo + OSS-Fuzz crash
#     repros), so stratify-by-LANGUAGE is moot (uniform). Stratify-by-DIFFICULTY is
#     impossible a priori — difficulty is only known for the 13 tasks already run
#     (data/task-manifest.csv from 3xi.1), not for unseen tasks.
#   - => documented SEEDED RANDOM SAMPLE, stratified by SOURCE to preserve the
#     90.8/9.2 arvo:oss-fuzz proportion (50 = 45 arvo + 5 oss-fuzz; 40 = 36 + 4).
#   - 40 ⊂ 50 (nested) so a 40-run's per-task S3 results are reused by a later 50-run
#     (the b51 pool skips valid results on resume).
# Regenerate / audit with: scripts/runners/curate-cybergym-subset.py --seed 20260617
# (reads the pinned mask_map.json; reproducible across CPython 3.x).
readonly -a CYBERGYM_TASKS_40=(
  "arvo:17715"
  "arvo:28109"
  "arvo:11908"
  "arvo:25943"
  "arvo:52475"
  "arvo:29366"
  "arvo:19414"
  "arvo:24183"
  "arvo:66371"
  "arvo:66108"
  "arvo:42325"
  "arvo:24465"
  "arvo:42560"
  "arvo:14529"
  "arvo:32785"
  "arvo:62183"
  "arvo:30403"
  "arvo:59602"
  "arvo:64079"
  "arvo:20775"
  "arvo:35727"
  "arvo:36930"
  "arvo:14455"
  "arvo:58428"
  "arvo:45523"
  "arvo:21936"
  "arvo:62388"
  "arvo:34299"
  "arvo:11382"
  "arvo:61998"
  "arvo:11896"
  "arvo:26400"
  "arvo:28253"
  "arvo:34691"
  "arvo:6418"
  "arvo:14767"
  "oss-fuzz:42538001"
  "oss-fuzz:42537788"
  "oss-fuzz:42536646"
  "oss-fuzz:42537586"
)

# 50 = the 40 above + 10 more (9 arvo + 1 oss-fuzz). Keep in this order so 40 ⊂ 50.
readonly -a CYBERGYM_TASKS_50=(
  "${CYBERGYM_TASKS_40[@]}"
  "arvo:6247"
  "arvo:64286"
  "arvo:26635"
  "arvo:13466"
  "arvo:4670"
  "arvo:22105"
  "arvo:28185"
  "arvo:53054"
  "arvo:61235"
  "oss-fuzz:42537827"
)

# Spend watchdog defaults
readonly DEFAULT_SPEND_CAP_USD="300"
readonly WATCHDOG_INTERVAL_SEC=60
# shellcheck disable=SC2034  # used by future explicit heartbeat timer loop
readonly PROGRESS_INTERVAL_SEC=60

# ============================================================
# Defaults
# ============================================================
TARGET=""
CAMPAIGN=""
FORCE="false"
SPEND_CAP_USD="${DEFAULT_SPEND_CAP_USD}"
CYBERGYM_SUBSET=""   # empty = choose by target in preflight
# Reasoning-effort tier flowed to run.py's CYBERGYM_REASONING_EFFORT env (bd amh).
# Empty = not passed = config.toml carries no reasoning_effort key (default path,
# byte-identical to today). "none" = thinking-OFF.
REASONING_EFFORT=""

# vLLM-target args (only used when TARGET=vllm)
VLLM_URL=""
VLLM_MODEL=""
VLLM_KEY=""
VLLM_KEY_SSM=""
# Currently unused for the cybergym OpenHands agent path (kept for CLI
# symmetry with run-pool-b.sh and as a reserved hook). bc7-followup:
# wire VLLM_EXTRA_BODY through to OpenHands if/when we need
# chat_template_kwargs forwarding for thinking-mode models on Pool A.
# shellcheck disable=SC2034
VLLM_EOS_STRING=""
# shellcheck disable=SC2034
VLLM_EXTRA_BODY=""

# Active task list — populated in preflight after subset resolution
CYBERGYM_TASKS=()

# BENCH_NAME is set in preflight once CYBERGYM_SUBSET is resolved
BENCH_NAME=""

# Watchdog state (set at runtime)
WATCHDOG_BASELINE_USD="0"
WATCHDOG_PID=""

# ============================================================
# ERR + EXIT traps
# ============================================================
trap 'lib_err_trap ${LINENO}' ERR
trap '_exit_handler' EXIT

# pid of the bounded-pool parent (bd benchmarks-b51 Phase 2), empty until launched.
# On exit/abort the EXIT handler signals it so it fans SIGTERM out to every running
# worker's process group — each worker's own self-cleanup trap then reaps its
# task-local server + labelled container + agent subtree — and the parent does a
# docker reap backstop by label before exiting. The shell EXIT handler is the final
# backstop reap if the parent itself didn't finish.
POOL_PID=""

_exit_handler() {
  local exit_code=$?
  log_info "EXIT handler fired exit_code=${exit_code}"
  # Hand the pool parent its abort signal so it fans out teardown to all workers
  # (each worker's trap reaps its server + labelled container + agent subtree).
  # Grace must exceed the parent's own worker-grace (it SIGTERMs workers, waits,
  # then SIGKILLs + backstop-reaps) so it can finish cleanly before we SIGKILL it.
  if [[ -n "${POOL_PID:-}" ]] && kill -0 "${POOL_PID}" 2>/dev/null; then
    log_info "EXIT handler: signalling pool parent pid=${POOL_PID} for fan-out teardown"
    kill -TERM "${POOL_PID}" 2>/dev/null || true
    local _w
    for ((_w = 0; _w < 30; _w++)); do
      kill -0 "${POOL_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${POOL_PID}" 2>/dev/null || true
    wait "${POOL_PID}" 2>/dev/null || true
  fi
  # Backstop: reap any of this campaign's labelled containers that outlived their
  # worker (defensive — the worker traps + the pool parent normally handle this).
  if command -v docker &>/dev/null && [[ -n "${CAMPAIGN:-}" ]]; then
    local _ids
    _ids="$(docker ps -aq --filter "label=cg_campaign=${CAMPAIGN}" 2>/dev/null || printf '')"
    if [[ -n "${_ids}" ]]; then
      log_warn "EXIT handler: reaping ${_ids//$'\n'/ } orphaned cg_campaign=${CAMPAIGN} container(s)"
      # shellcheck disable=SC2086
      docker rm -f ${_ids} >/dev/null 2>&1 || true
    fi
  fi
  # Kill watchdog subprocess if running
  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    log_debug "Stopping watchdog subprocess pid=${WATCHDOG_PID}"
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    wait "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  # Final S3 sync — always, even on failure
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
      --target)           TARGET="$2";           shift 2 ;;
      --campaign)         CAMPAIGN="$2";         shift 2 ;;
      --spend-cap-usd)    SPEND_CAP_USD="$2";    shift 2 ;;
      --cybergym-subset)  CYBERGYM_SUBSET="$2";  shift 2 ;;
      --reasoning-effort) REASONING_EFFORT="$2"; shift 2 ;;
      --force)            FORCE="true";          shift   ;;
      --debug)            LOG_LEVEL="debug"; set -x; shift ;;
      --vllm-url)         VLLM_URL="$2";         shift 2 ;;
      --vllm-model)       VLLM_MODEL="$2";       shift 2 ;;
      --vllm-key)         VLLM_KEY="$2";         shift 2 ;;
      --vllm-key-ssm)     VLLM_KEY_SSM="$2";     shift 2 ;;
      --vllm-eos-string)  VLLM_EOS_STRING="$2";  export VLLM_EOS_STRING; shift 2 ;;
      --vllm-extra-body)  VLLM_EXTRA_BODY="$2";  export VLLM_EXTRA_BODY; shift 2 ;;
      -h|--help)          usage ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Validate --cybergym-subset if explicitly set
  case "${CYBERGYM_SUBSET}" in
    ""|3|10|40|50) ;;
    *)
      log_error "--cybergym-subset must be 3, 10, 40, or 50 (got: ${CYBERGYM_SUBSET})"
      exit 1
      ;;
  esac

  # Validate --reasoning-effort if explicitly set. Values are passed verbatim to
  # run.py's CYBERGYM_REASONING_EFFORT env (config["llm"]["reasoning_effort"]).
  # "none" = thinking-OFF; the rest are the OpenAI-style tiers litellm forwards.
  if [[ -n "${REASONING_EFFORT}" \
        && "${REASONING_EFFORT}" != "none" \
        && "${REASONING_EFFORT}" != "minimal" \
        && "${REASONING_EFFORT}" != "low" \
        && "${REASONING_EFFORT}" != "medium" \
        && "${REASONING_EFFORT}" != "high" ]]; then
    log_error "--reasoning-effort must be one of none|minimal|low|medium|high (got: ${REASONING_EFFORT})"
    exit 1
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
    # Reject http:// URLs unless localhost OR a private/internal host. Bearer
    # tokens over plaintext leak, so https is required for public/rental
    # endpoints — but an internal no-auth vLLM (e.g. the ejv Gemma endpoint on
    # the <SPARK_NODE_2> Spark, reached over the on-prem LAN/VPN) is fine over http.
    # Allow loopback + RFC1918 (10/8, 192.168/16, 172.16-31/12) + *.internal.
    _vllm_http_ok='^http://(localhost|127\.0\.0\.1|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|[a-zA-Z0-9.-]+\.internal\.)'
    if [[ ! "${VLLM_URL}" =~ ^https:// && ! "${VLLM_URL}" =~ ${_vllm_http_ok} ]]; then
      log_error "--vllm-url must be https:// (or http:// to localhost / an RFC1918 / .internal host); got: ${VLLM_URL}"
      exit 1
    fi
    # Plaintext key-leak guard: a key over http to a non-loopback host is only
    # acceptable on a trusted internal network — warn, don't silently allow.
    if [[ "${VLLM_URL}" =~ ^http:// && ! "${VLLM_URL}" =~ ^http://(localhost|127\.0\.0\.1) && -n "${VLLM_KEY}${VLLM_KEY_SSM}" ]]; then
      log_warn "vLLM key sent over plaintext http:// to ${VLLM_URL} — ensure this is a trusted internal network."
    fi
    # Stash into the lib's vllm slots before lib_model_id runs.
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
# Available GB on the filesystem that holds <path>. Walks up to the nearest
# existing ancestor (the path may not exist yet, e.g. a fresh results base or
# docker root), then reads df. Prints an integer GB (0 on failure).
# ============================================================
_avail_gb() {
  local p="$1"
  while [[ ! -e "${p}" && "${p}" != "/" ]]; do p="$(dirname -- "${p}")"; done
  df -Pk "${p}" 2>/dev/null | awk 'NR==2 {print int($4 / 1024 / 1024)}'
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

  if [[ ! -d "${CYBERGYM_REPO}" ]]; then
    log_error "CyberGym repo not found at ${CYBERGYM_REPO}"
    log_error "Run: sudo /opt/benchmarks/scripts/install-harness.sh"
    exit 1
  fi

  if [[ ! -f "${CYBERGYM_AGENT_RUNNER}" ]]; then
    log_error "CyberGym OpenHands agent runner not found at ${CYBERGYM_AGENT_RUNNER}"
    log_error "Ensure the cybergym repo submodule examples/agents is initialized."
    exit 1
  fi

  if [[ ! -d "${CYBERGYM_DATA_DIR}" ]]; then
    log_error "CyberGym data dir not found at ${CYBERGYM_DATA_DIR} — bd <ISSUE> must complete first"
    log_error "Set CYBERGYM_DATA_DIR env if mounted elsewhere."
    exit 1
  fi

  if ! command -v docker &>/dev/null; then
    log_error "docker not found — required for CyberGym task execution"
    exit 1
  fi

  if ! command -v sqlite3 &>/dev/null; then
    log_error "sqlite3 not found — required for poc.db verdict extraction"
    exit 1
  fi

  # Disk pre-flight — N-AWARE (bd b51 §8). Each concurrent task burns ~15 GB
  # transient, so budget N × CYBERGYM_DISK_GB_PER_TASK (floored at the old flat
  # 30 GB), and check BOTH the docker data-root (overlay2 / images) AND the
  # results/workspace volume — on the powered host both live on a sized /data.
  local required_gb=$(( CYBERGYM_POOL_N * CYBERGYM_DISK_GB_PER_TASK ))
  (( required_gb < 30 )) && required_gb=30
  local docker_root results_root avail_docker avail_results min_avail
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || printf '')"
  [[ -n "${docker_root}" ]] || docker_root="/var/lib/docker"
  results_root="${LIB_RESULTS_BASE}"
  avail_docker="$(_avail_gb "${docker_root}")"
  avail_results="$(_avail_gb "${results_root}")"
  [[ "${avail_docker}"  =~ ^[0-9]+$ ]] || avail_docker=0
  [[ "${avail_results}" =~ ^[0-9]+$ ]] || avail_results=0
  min_avail=$(( avail_docker < avail_results ? avail_docker : avail_results ))
  if (( min_avail < required_gb )); then
    log_error "Insufficient disk for pool_n=${CYBERGYM_POOL_N}: need ${required_gb} GB (${CYBERGYM_DISK_GB_PER_TASK} GB/task), have docker-root(${docker_root})=${avail_docker} GB results(${results_root})=${avail_results} GB"
    log_error "Lower CYBERGYM_POOL_N, raise CYBERGYM_DISK_GB_PER_TASK headroom, or attach a larger /data volume."
    exit 1
  fi
  log_info "Disk preflight OK: pool_n=${CYBERGYM_POOL_N} need=${required_gb} GB; docker-root(${docker_root})=${avail_docker} GB results(${results_root})=${avail_results} GB"

  # GPT-5.5 target: fetch OpenAI API key from SSM
  if [[ "${TARGET}" == "gpt55" ]]; then
    lib_setup_gpt55_key
  fi

  # vLLM target: resolve API key and verify endpoint reachability.
  if [[ "${TARGET}" == "vllm" ]]; then
    lib_setup_vllm_key
    lib_check_vllm_endpoint
  fi

  # Resolve cybergym subset: explicit --cybergym-subset wins; otherwise default
  # 10 for vllm (abbreviated profile sweep), 3 for opus47/gpt55 (<CAMPAIGN> behavior).
  if [[ -z "${CYBERGYM_SUBSET}" ]]; then
    if [[ "${TARGET}" == "vllm" ]]; then
      CYBERGYM_SUBSET="10"
    else
      CYBERGYM_SUBSET="3"
    fi
    log_info "cybergym_subset defaulted to ${CYBERGYM_SUBSET} for target=${TARGET}"
  fi

  # Populate active task list + bench name from resolved subset
  case "${CYBERGYM_SUBSET}" in
    3)
      CYBERGYM_TASKS=("${CYBERGYM_TASKS_3[@]}")
      BENCH_NAME="cybergym-3"
      ;;
    10)
      CYBERGYM_TASKS=("${CYBERGYM_TASKS_10[@]}")
      BENCH_NAME="cybergym-10"
      ;;
    40)
      CYBERGYM_TASKS=("${CYBERGYM_TASKS_40[@]}")
      BENCH_NAME="cybergym-40"
      ;;
    50)
      CYBERGYM_TASKS=("${CYBERGYM_TASKS_50[@]}")
      BENCH_NAME="cybergym-50"
      ;;
    *)
      log_error "Unexpected cybergym subset value after validation: ${CYBERGYM_SUBSET}"
      exit 1
      ;;
  esac

  # Optional: drop specific task IDs from the run (space/comma-separated).
  # Use when a task's image won't pull upstream — excluding keeps the wall-time
  # distribution clean instead of letting that task fail fast and skew it.
  # ejv 2026-06-12: cybergym/oss-fuzz:385167047-fix has un-pullable layers
  # upstream → CYBERGYM_TASK_EXCLUDE="oss-fuzz:385167047" gives a clean n=9.
  if [[ -n "${CYBERGYM_TASK_EXCLUDE:-}" ]]; then
    local _excl=" ${CYBERGYM_TASK_EXCLUDE//,/ } " _keep=() _t
    for _t in "${CYBERGYM_TASKS[@]}"; do
      if [[ "${_excl}" == *" ${_t} "* ]]; then
        log_warn "excluding task ${_t} (CYBERGYM_TASK_EXCLUDE)"
      else
        _keep+=("${_t}")
      fi
    done
    CYBERGYM_TASKS=("${_keep[@]}")
  fi

  log_info "Pool A preflight passed target=${TARGET} campaign=${CAMPAIGN} subset=${CYBERGYM_SUBSET} bench=${BENCH_NAME} n_tasks=${#CYBERGYM_TASKS[@]}"
}

# write_progress() now lives in _cybergym_common.sh (shared with the per-task
# entrypoint). It reads CYBERGYM_N_TOTAL, which main() sets to ${#CYBERGYM_TASKS[@]}
# after subset resolution. This dispatcher only calls it on the failure path now;
# the per-task entrypoint emits running/skipped/pass/fail.

# ============================================================
# Spend watchdog loop — runs in background, signals parent on cap exceeded
# Starts as a background subshell; kills parent's process group on exit 2
#
# NOTE: This loop is only started for the opus47 target. For vllm and gpt55 targets
# the watchdog is bypassed entirely — see main() and the WATCHDOG section in
# the file header comment.
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
      0)
        log_debug "Watchdog: within cap — continuing"
        ;;
      2)
        log_warn "Watchdog: spend cap EXCEEDED — sending SIGTERM to parent ${parent_pid}"
        # Send SIGTERM to the parent runner (not SIGKILL — allow EXIT trap to run)
        kill -TERM "${parent_pid}" 2>/dev/null || true
        return 0
        ;;
      *)
        # exit 1 from watchdog = monitoring infrastructure failure
        # CONSERVATIVE: do NOT abort on monitoring failure
        log_warn "Watchdog: monitoring failure (exit ${watchdog_exit}) — continuing run (conservative policy)"
        ;;
    esac
  done
}

# ============================================================
# Session setup: pre-pull the shared OpenHands runtime image once (bd benchmarks-b51).
#
# The grading server is no longer started here — each task runs its OWN task-local
# cybergym.server + poc.db inside run-one-cybergym-task.sh (hermetic per-task state,
# no shared SQLite, no cross-task contention). This dispatcher only pre-pulls the
# multi-GB runtime image once so N concurrent tasks don't each pay the pull tax; the
# per-task entrypoint pulls it only if still missing. Called by main() after preflight,
# before the task loop.
# ============================================================
session_setup() {
  log_info "session_setup: pre-pulling OpenHands runtime image ${CYBERGYM_OPENHANDS_RUNTIME_IMAGE}"
  if ! docker pull "${CYBERGYM_OPENHANDS_RUNTIME_IMAGE}" 2>&1 | tee -a "${LIB_RUNNER_LOG}"; then
    log_error "Failed to pull OpenHands runtime image; cannot proceed"
    return 1
  fi
  return 0
}

# ============================================================
# Fetch Bedrock spend baseline at runner start
# Used for delta calculation throughout the run.
# NOT called for vllm targets (watchdog is bypassed).
# ============================================================
fetch_baseline_spend() {
  log_info "Fetching Bedrock spend baseline from Cost Explorer"
  # CONSERVATIVE: if baseline fetch fails, use 0 (watchdog will see all spend as delta)
  local baseline=0
  baseline="$("${RUNNER_SCRIPT_DIR}/spend-watchdog.sh" \
    --cap-usd "999999" \
    --baseline-usd "0" \
    --campaign "${CAMPAIGN}" \
    --target "${TARGET}" \
    2>/dev/null; printf '0')" || baseline=0
  # spend-watchdog always exits 0 when within cap; we want the actual CE number
  # TODO(<CAMPAIGN>-followup): expose a --print-current-spend mode in spend-watchdog.sh
  # so baseline can be fetched without triggering the cap check.
  log_info "Baseline spend: ${baseline} USD (may be 0 due to CE propagation delay)"
  WATCHDOG_BASELINE_USD="${baseline}"
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  preflight

  # write_progress (in _cybergym_common.sh) reports the column size from this.
  CYBERGYM_N_TOTAL="${#CYBERGYM_TASKS[@]}"

  BENCH="${BENCH_NAME}"
  log_info "Starting Pool A CyberGym run campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} n_tasks=${CYBERGYM_N_TOTAL} pool_n=${CYBERGYM_POOL_N} spend_cap=${SPEND_CAP_USD}"

  # Fresh-host resume (bd b51 §6): on a replacement/ephemeral box the local results
  # tree is empty, but completed tasks may already live in S3 — pull them back FIRST
  # so the per-task entrypoint's valid-result skip sees and skips them. No-op offline.
  s3_pull_results "${BENCH_NAME}" || log_warn "S3 pull-back failed (continuing; tasks may re-run)"

  # Pre-pull the shared OpenHands runtime image once (each task runs its own
  # task-local grading server now — see run-one-cybergym-task.sh). The EXIT trap
  # (_exit_handler) reaps any in-flight task + orphaned labelled containers.
  if ! session_setup; then
    log_error "session_setup failed; cannot proceed with CyberGym batch"
    exit 1
  fi

  # Abort handler (Ctrl-C / SIGTERM): exit cleanly so the EXIT handler runs and
  # signals the in-flight per-task entrypoint for its self-cleanup (bd b51 §5 —
  # task-local server + labelled container + agent subtree). The opus47 spend-cap
  # path re-traps TERM below with its exit-2 handler (preserving that exit code).
  _abort_handler() {
    log_warn "abort signal received (SIGINT/SIGTERM) — initiating clean shutdown"
    exit 143
  }
  trap '_abort_handler' INT TERM

  # ---- Spend watchdog (Bedrock targets only) ----
  # For vllm targets: Bedrock Cost Explorer watchdog is meaningless — GPU rental
  # cost is tracked by the operator-side rental teardown script (rental-vllm-down.sh).
  # For gpt55 targets: OpenAI spend is not visible to Bedrock Cost Explorer.
  # Bypassing for both and logging clearly so operators know cost is not auto-capped.
  # TODO(z1s.1): Adapt watchdog to rental GPU-hours for vllm targets
  # (tracked in benchmarks-<CAMPAIGN> — GPU telemetry integration).
  if [[ "${TARGET}" == "vllm" || "${TARGET}" == "gpt55" ]]; then
    log_warn "Spend watchdog BYPASSED for target=${TARGET} — cost gate is operator-side (rental teardown for vllm; OpenAI portal spend cap for gpt55). Ensure spend is monitored externally."
  else
    fetch_baseline_spend

    # Start watchdog in background
    watchdog_loop "$$" "${WATCHDOG_BASELINE_USD}" &
    WATCHDOG_PID="$!"
    log_info "Watchdog started pid=${WATCHDOG_PID}"

    # Set up SIGTERM handler — triggered by watchdog on cap exceeded
    # Graceful: sync results, then exit 2 (cap exceeded exit code)
    trap '_sigterm_handler' TERM
    _sigterm_handler() {
      log_warn "SIGTERM received — spend cap exceeded; initiating clean abort"
      # EXIT handler will run after exit 2, performing final S3 sync
      exit 2
    }
  fi

  # ---- Bounded worker pool (bd benchmarks-b51 Phase 2) ----
  # The sequential bash loop is replaced by a stdlib Python parent that runs up to
  # CYBERGYM_POOL_N hermetic per-task entrypoints concurrently against the one Spark.
  # It owns: dispatch, signal fan-out to each worker's process group + a docker reap
  # backstop by cg_campaign label, and a tally from each task's status.json (the
  # entrypoint writes harness_rc + pass + sanitizer_verdict + early_abort, and now
  # also writes its OWN failure marker/status.json on a harness error — design §3).
  # N=1 = today's strictly-sequential path (concurrency 1, list order, byte-identical).
  #
  # Per-task resilience (benchmarks-<CAMPAIGN>, preserved): a worker's nonzero rc is a
  # HARNESS error (NOT a vuln FAIL, which the entrypoint records as a normal verdict).
  # It is tallied (parent exits 1 if any worker failed) without aborting the others.
  # Spend-cap (exit 2) still wins via this shell's SIGTERM handler, which trips the
  # parent shell; _exit_handler then signals the pool parent for fan-out teardown.
  local -r n_total="${#CYBERGYM_TASKS[@]}"

  local pool_python
  pool_python="$(command -v "${CYBERGYM_POOL_PYTHON}" 2>/dev/null || printf '')"
  if [[ -z "${pool_python}" ]]; then
    log_error "pool parent: python3 not found (CYBERGYM_POOL_PYTHON=${CYBERGYM_POOL_PYTHON}); cannot dispatch"
    exit 1
  fi
  if [[ ! -f "${CYBERGYM_POOL_DISPATCHER}" ]]; then
    log_error "pool parent script not found at ${CYBERGYM_POOL_DISPATCHER}"
    exit 1
  fi

  # Args for the parent. The secret LLM key is NOT passed on argv — the entrypoint
  # (spawned by the parent) inherits the resolved key from the exported env
  # (VLLM_API_KEY / OPENAI_API_KEY), so nothing can leak it via a process listing.
  local -a pool_args=(
    "${CYBERGYM_POOL_DISPATCHER}"
    --pool-n        "${CYBERGYM_POOL_N}"
    --entrypoint    "${CYBERGYM_TASK_ENTRYPOINT}"
    --campaign      "${CAMPAIGN}"
    --target        "${TARGET}"
    --bench         "${BENCH_NAME}"
    --n-total       "${n_total}"
    --results-base  "${LIB_RESULTS_BASE}"
  )
  [[ "${FORCE}" == "true" ]] && pool_args+=(--force)
  # bd amh: only pass --reasoning-effort when set so the default path stays
  # byte-identical (no env exported downstream ⇒ no reasoning_effort in config.toml).
  [[ -n "${REASONING_EFFORT}" ]] && pool_args+=(--reasoning-effort "${REASONING_EFFORT}")
  if [[ "${TARGET}" == "vllm" ]]; then
    pool_args+=(--vllm-url "${VLLM_URL}" --vllm-model "${VLLM_MODEL}")
  fi
  pool_args+=(-- "${CYBERGYM_TASKS[@]}")

  log_info "Launching pool parent pool_n=${CYBERGYM_POOL_N} n_tasks=${n_total} python=${pool_python}"
  # Background + wait so this shell's signal traps still fire (spend cap / Ctrl-C):
  # on a trap the shell exits, and _exit_handler signals POOL_PID for fan-out.
  "${pool_python}" "${pool_args[@]}" &
  POOL_PID=$!
  local pool_rc=0
  wait "${POOL_PID}" || pool_rc=$?
  POOL_PID=""   # parent exited on its own; nothing for _exit_handler to signal

  if (( pool_rc == 0 )); then
    log_info "Pool A CyberGym complete campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} pool_n=${CYBERGYM_POOL_N} n_tasks=${n_total} (no harness failures)"
    return 0
  fi

  log_error "Pool A CyberGym finished with harness failures campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH_NAME} pool_rc=${pool_rc}"
  exit 1
}

main "$@"
