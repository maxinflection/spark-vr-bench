#!/usr/bin/env bash
# run-swebench-pro-smoke.sh — SWE-bench Pro LLM wiring + prompt-cache smoke
# (bd benchmarks-3xi.2.1 wiring, 3xi.2.2 caching). Runs ON the harness box.
#
# Drives the canonical SWE-agent scaffold (scaleapi/SWE-agent fork) against one
# or more SWE-bench Pro public instances in a LOCAL docker sandbox. Produces
# preds.json; grade with swe_bench_pro_eval.py.
#
# MODEL (env): litellm model id. Default = cheap Haiku via the direct Anthropic
#   key in SSM. For the frontier smoke, set MODEL=bedrock/us.anthropic.claude-opus-4-7
#   (the box's harness-driver-role is Opus-only on Bedrock; AWS creds = instance
#   role + region, NO api key). The runner auto-detects the route from MODEL:
#     bedrock/* -> AWS Bedrock (instance role);
#     openai/*  -> OpenAI-compatible endpoint (vLLM rental / generic openai) — or
#                  force with VLLM=1 (see vLLM block below);
#     else      -> direct Anthropic via the SSM key.
# FILTER (env): SWE-agent instance filter regex (anchored re.match). Default =
#   smoke/CHOSEN_ID. For n>1, pass an alternation '(id1|id2|...)'.
# CALL_LIMIT (env, default 75): per-instance API call cap.
# NO_CACHE=1 (env): skip the cache_control overlay AND the usage probe (Phase-1
#   legacy behaviour; leaves DefaultHistoryProcessor => NO prompt caching =>
#   O(turns^2) cost, and no per-call usage capture).
#
# vLLM / OpenAI-compatible route (bd benchmarks-3xi.2.6 — the open-weight column):
#   MODEL=openai/<served-model-id> (or VLLM=1 with any MODEL). Mirrors the Pool A/B
#   generic vLLM target (scripts/runners/_lib.sh + run-pool-b.sh + gpu-rental-flow).
#   VLLM_API_BASE (env, REQUIRED): OpenAI-compatible endpoint, WITH the /v1 suffix,
#     e.g. https://<rental-host>/v1 . Must be https:// (or http://localhost). litellm's
#     openai provider reads OPENAI_API_BASE + OPENAI_API_KEY from ENV (the reliable
#     channel — the Pool B finding is that api_base passed via model-args is NOT
#     forwarded by some litellm callers; we also pass --agent.model.api_base for SWE-agent).
#   VLLM_API_KEY (env) | VLLM_API_KEY_SSM (env): the endpoint key (literal or SSM
#     param name). Defaults to the 'sk-vllm-noauth' placeholder (a vLLM started
#     without --api-key accepts anything). Never written to disk.
#   The Anthropic cache_control overlay is SKIPPED on this route (vLLM does prefix
#   caching server-side; cache_control is not in the OpenAI schema). The usage
#   probe (sitecustomize.py) STILL loads to capture per-turn decode volume — the
#   input to the 3xi.2.6 safe-N characterization (its temperature/top_p scrub is
#   gated to Bedrock-Opus models, so it is a no-op on the vLLM path; vLLM accepts
#   sampling params).
#
# Parallelism (bd benchmarks-3xi.2.6):
#   NUM_WORKERS (env, default 1): SWE-agent run-batch native concurrency (N streams).
#   PREWARM (env, default 'auto'): builder pre-warm before an N>1 run (one CPython
#     compile populates the BuildKit builder-stage cache so the N parallel deploys
#     don't each compile -> the §4e OOM-wedge). 'auto' = on iff NUM_WORKERS>1;
#     '1' = force; '0' = disable. PREWARM_IMAGE overrides the auto-derived base image.
#
# PROMPT CACHING (bd 3xi.2.2): config/tool_use.yaml sets no history_processors
# and so falls back to DefaultHistoryProcessor (pass-through, NO cache_control).
# We add config/_cache_overlay.yaml (history_processors: [cache_control,
# last_n_messages: 2]) as a second --config — SWE-agent deep-merges it. This is
# the SAME cache_control processor every canonical SWE-agent Anthropic config
# ships; a SUBSTRATE fix, not a scaffold swap. SWE-agent's InstanceStats discards
# response.usage, so per-call cache usage is captured by a litellm wrapper
# (cache_probe/sitecustomize.py on PYTHONPATH) into $SWEAGENT_CACHE_USAGE_OUT;
# analyze with _cache_analyze.py --source sweagent.
#
# Phase-0/1 quirks (still apply): swe-rex patched for local-docker on the Pro
# images (_swerex_docker_libffi_patch.py: libffi-dev + real pip index); the
# [/bin/bash] ENTRYPOINT neutralised by --instances.deployment.docker_args
# '["--entrypoint",""]'. (The Pro fork's own path is Modal.)
#
# Validated:
#   - Haiku, no-cache (Phase 1): 44 calls, 3810-char patch -> eval 1.0 (resolved).
#   - Haiku + cache_control (3xi.2.2): per-call cache_read grows turn-over-turn,
#     APC hit >=~90% (see _cache_analyze.py output).
set -uo pipefail
# Capture our own dir BEFORE the cd below (sibling helpers live here on the box,
# delivered to /opt/benchmarks/scripts/runners/).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Pick the docker build backend ONCE and use it consistently for BOTH the pre-warm
# and swe-rex's per-instance builds — they must share ONE layer cache or the
# pre-warm doesn't help (bd 3xi.2.6). BuildKit is preferred but on Docker 23+ a
# plain `docker build` with DOCKER_BUILDKIT=1 routes through the buildx CLI plugin
# and ERRORS if buildx is absent (observed on a Docker 29 box with no buildx). So
# detect buildx: use BuildKit iff present, else the LEGACY builder (which also
# caches layers across builds, so the pre-warm still serves). Exported so swe-rex's
# `docker build` subprocess + _swebench_pro_prewarm.py inherit the same choice.
if [[ -z "${DOCKER_BUILDKIT:-}" ]]; then
  if docker buildx version >/dev/null 2>&1; then
    export DOCKER_BUILDKIT=1
  else
    export DOCKER_BUILDKIT=0
    echo "NOTE: docker buildx not found -> using the legacy builder (its layer cache still serves the pre-warm). Install the buildx plugin for the BuildKit path."
  fi
else
  export DOCKER_BUILDKIT
fi
ROOT=/opt/harnesses/swebench-pro
CALL_LIMIT="${CALL_LIMIT:-75}"
MODEL="${MODEL:-anthropic/claude-haiku-4-5-20251001}"
REGION="${REGION:-us-east-1}"
NUM_WORKERS="${NUM_WORKERS:-1}"
cd "$ROOT/repo/SWE-agent"
source "$ROOT/.venv-sweagent/bin/activate"

# Auth + endpoint routing (3 mutually-exclusive routes, selected by MODEL):
#   bedrock/* -> AWS Bedrock via the box instance role (no api key)
#   openai/* (or VLLM=1) -> OpenAI-compatible endpoint (vLLM rental / generic openai)
#   else      -> direct Anthropic via the SSM key
IS_BEDROCK=0
IS_VLLM=0
API_BASE_ARGS=()
if [[ "$MODEL" == bedrock/* ]]; then
  IS_BEDROCK=1
  export AWS_REGION_NAME="$REGION" AWS_DEFAULT_REGION="$REGION"
  unset ANTHROPIC_API_KEY || true
elif [[ "$MODEL" == openai/* || "${VLLM:-0}" == "1" ]]; then
  IS_VLLM=1
  : "${VLLM_API_BASE:?VLLM_API_BASE (OpenAI-compatible endpoint WITH /v1 suffix) required for the vLLM/openai route}"
  # Plaintext http is rejected on the PUBLIC internet (a Bearer token would leak),
  # but allowed for trusted local/private endpoints — the open-weight column serves
  # vLLM on a private network (localhost, an RFC1918 IP, or a *.internal host) with a
  # no-secret placeholder key, the same trust level as the localhost exemption. https
  # is always allowed. (bd 3xi.2.6: the dgx Spark endpoints are http://10.x on the
  # internal net.) Override the gate with VLLM_ALLOW_INSECURE=1 if ever needed.
  _vllm_host="${VLLM_API_BASE#*://}"; _vllm_host="${_vllm_host%%[:/]*}"
  if [[ "$VLLM_API_BASE" == https://* || "${VLLM_ALLOW_INSECURE:-0}" == "1" ]]; then
    : # ok
  elif [[ "$VLLM_API_BASE" == http://* ]] && [[ \
        "$_vllm_host" == localhost || "$_vllm_host" == 127.0.0.1 || \
        "$_vllm_host" == 10.* || \
        "$_vllm_host" == 192.168.* || \
        "$_vllm_host" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || \
        "$_vllm_host" == *.internal || "$_vllm_host" == *.internal.* ]]; then
    : # trusted private / internal-network plaintext endpoint
  else
    echo "FATAL: VLLM_API_BASE must be https:// or a private/internal http:// endpoint (localhost / RFC1918 / *.internal); got: $VLLM_API_BASE (set VLLM_ALLOW_INSECURE=1 to override)" >&2
    exit 1
  fi
  # Resolve the endpoint key: literal VLLM_API_KEY, else VLLM_API_KEY_SSM, else placeholder.
  if [[ -n "${VLLM_API_KEY:-}" ]]; then
    : # operator-supplied literal (not logged)
  elif [[ -n "${VLLM_API_KEY_SSM:-}" ]]; then
    VLLM_API_KEY="$(aws ssm get-parameter --region "$REGION" \
      --name "$VLLM_API_KEY_SSM" --with-decryption --query Parameter.Value --output text)"
  else
    VLLM_API_KEY="sk-vllm-noauth"  # vLLM started without --api-key accepts anything
  fi
  export OPENAI_API_BASE="$VLLM_API_BASE"
  export OPENAI_API_KEY="$VLLM_API_KEY"
  API_BASE_ARGS=(--agent.model.api_base "$VLLM_API_BASE")
  # Pre-flight: confirm the endpoint is reachable + serving MODEL before a long run
  # (catches a dead/typo'd rental cheaply — same probe shape as _lib.sh).
  _vllm_model_id="${MODEL#openai/}"
  _probe="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer $VLLM_API_KEY" "$VLLM_API_BASE/models" 2>/dev/null || echo 000)"
  if [[ "$_probe" != "200" ]]; then
    _probe="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
      -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
      -d "{\"model\":\"$_vllm_model_id\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":1}" \
      "$VLLM_API_BASE/chat/completions" 2>/dev/null || echo 000)"
    [[ "$_probe" == "200" ]] || { echo "FATAL: vLLM endpoint $VLLM_API_BASE unreachable (/models + chat/completions probe both failed: $_probe)" >&2; exit 1; }
  fi
  echo "VLLM route OK: endpoint=$VLLM_API_BASE model=$_vllm_model_id probe=$_probe"
else
  export ANTHROPIC_API_KEY="$(aws ssm get-parameter --region "$REGION" \
    --name /sandbox/api-keys/anthropic --with-decryption --query Parameter.Value --output text)"
fi
MODEL_TAG="$(echo "$MODEL" | tr '/.:' '___')"

ID="${FILTER:-$(cat "$ROOT/smoke/CHOSEN_ID")}"
OUT="$ROOT/smoke/sweagent_out_${MODEL_TAG}"
rm -rf "$OUT"; mkdir -p "$OUT"

CONFIGS=(--config config/tool_use.yaml)
# Two independent instrumentation toggles (both off when NO_CACHE=1):
#  (A) Anthropic cache_control overlay — restores prompt caching on the Anthropic/
#      Bedrock routes. SKIPPED on the vLLM/openai route: vLLM does prefix caching
#      server-side and `cache_control` is an Anthropic-schema-only message field
#      that an OpenAI-compatible endpoint can reject. (bd 3xi.2.6)
#  (B) Per-call usage probe (cache_probe/sitecustomize.py on PYTHONPATH) — captures
#      real per-call usage incl. OUTPUT (decode) tokens into a JSONL. Loaded on ALL
#      routes (it is the input to the 3xi.2.6 per-turn-decode-volume -> safe-N
#      characterization). On Bedrock it ALSO scrubs temperature/top_p at the litellm
#      boundary (SWE-agent's config defaults top_p=1.0 and can't be nulled — that
#      breaks its model-id property — and litellm drop_params doesn't gate it); that
#      scrub is gated to Bedrock-Opus model ids, so it is a no-op on the vLLM path.
if [[ "${NO_CACHE:-0}" != "1" ]]; then
  if [[ "$IS_VLLM" != "1" ]]; then
    CONFIGS+=(--config config/_cache_overlay.yaml)
  fi
  export PYTHONPATH="$ROOT/cache_probe:${PYTHONPATH:-}"
  export SWEAGENT_CACHE_USAGE_OUT="$OUT/cache_usage.jsonl"
  export SWEAGENT_CACHE_INSTANCE="$ID"
  rm -f "$SWEAGENT_CACHE_USAGE_OUT"
fi

# Builder pre-warm (bd 3xi.2.6). At N>1, the N parallel swe-rex deploys would EACH
# start the identical standalone-CPython compile at once -> N concurrent compiles
# OOM-wedge the box (the §4e / 3xi.2.5 HARD LESSON). One throwaway build of the
# (3xi.2.5-patched) glibc_dockerfile's BUILDER stage populates the BuildKit
# builder-stage cache; every deploy then reuses it and runs only the cheap
# production stage. The builder stage is image-independent, so any one of the run's
# base images warms it for all. Default 'auto' = on iff NUM_WORKERS>1 (non-fatal on
# failure). PREWARM_IMAGE overrides the auto-derived base image.
if [[ "${PREWARM:-auto}" == "1" || ( "${PREWARM:-auto}" == "auto" && "$NUM_WORKERS" -gt 1 ) ]]; then
  PREWARM_IMAGE="${PREWARM_IMAGE:-$(python - "$ID" <<'PY'
# Derive a base image from data/instances.yaml: the first instance whose id matches
# the filter regex. Best-effort — prints nothing on any failure (caller warns+skips).
import sys, re
try:
    import yaml
    flt = re.compile(sys.argv[1])
    with open("data/instances.yaml") as fh:
        data = yaml.safe_load(fh)
    insts = data if isinstance(data, list) else (data.get("instances") or data.get("data") or [])
    for it in insts:
        if not isinstance(it, dict):
            continue
        iid = it.get("instance_id") or it.get("id") or ""
        if flt.match(str(iid)):
            img = it.get("image_name") or it.get("image") or it.get("docker_image")
            if img:
                print(img)
                break
except Exception:
    pass
PY
)}"
  if [[ -n "${PREWARM_IMAGE:-}" ]]; then
    echo "PREWARM: warming builder-stage cache from $PREWARM_IMAGE (one CPython compile)"
    python "$SCRIPT_DIR/_swebench_pro_prewarm.py" --image "$PREWARM_IMAGE" \
      || echo "PREWARM WARNING: pre-warm build failed; N-wide deploys may each compile CPython (non-fatal)"
  else
    echo "PREWARM WARNING: could not derive a base image from data/instances.yaml (filter=$ID); skipping pre-warm"
  fi
fi

ROUTE=$([[ $IS_BEDROCK == 1 ]] && echo bedrock || { [[ $IS_VLLM == 1 ]] && echo vllm || echo anthropic; })
echo "START=$(date -u +%T) ROUTE=$ROUTE MODEL=$MODEL FILTER=$ID CALL_LIMIT=$CALL_LIMIT NUM_WORKERS=$NUM_WORKERS CACHE=$([[ ${NO_CACHE:-0} == 1 ]] && echo off || { [[ $IS_VLLM == 1 ]] && echo probe-only || echo on; })"
sweagent run-batch \
  "${CONFIGS[@]}" \
  --output_dir "$OUT" \
  --instances.type file \
  --instances.path data/instances.yaml \
  --instances.filter "$ID" \
  --instances.deployment.type=docker \
  --instances.deployment.docker_args='["--entrypoint",""]' \
  --instances.deployment.startup_timeout 1800 \
  --agent.model.name "$MODEL" \
  "${API_BASE_ARGS[@]+"${API_BASE_ARGS[@]}"}" \
  --agent.model.per_instance_call_limit "$CALL_LIMIT" \
  --agent.model.per_instance_cost_limit 0 \
  --num_workers "$NUM_WORKERS"
echo "SWEAGENT_EXIT=$?"
echo "DONE=$(date -u +%T)"
find "$OUT" -name "preds.json" 2>/dev/null | head
[[ -f "${SWEAGENT_CACHE_USAGE_OUT:-/nonexistent}" ]] && \
  echo "CACHE_USAGE=$SWEAGENT_CACHE_USAGE_OUT ($(wc -l < "$SWEAGENT_CACHE_USAGE_OUT") calls)"
