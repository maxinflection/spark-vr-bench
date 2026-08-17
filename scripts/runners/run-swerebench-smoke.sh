#!/usr/bin/env bash
# run-swerebench-smoke.sh — SWE-rebench-v2 Phase-1 OpenHands wiring + grading smoke
# (bd benchmarks-3xi.2.1, rebench/OpenHands half). Runs ON the harness box, NOT
# the sandbox. Mirrors run-swebench-pro-smoke.sh for the OpenHands-native cell.
#
# Drives the OpenHands `swebench-infer` harness (github.com/OpenHands/benchmarks),
# retargeted at nebius/SWE-rebench-v2 via a dataset subclass, against a cheap
# model (Haiku via the direct Anthropic key in SSM), in a LOCAL DockerWorkspace.
# Produces output.jsonl; grades with the rebench-faithful execution grader.
#
# Validated 2026-06-16 on <HARNESS_INSTANCE_ID>:
#   - No-LLM grading gate (instance codezonediitj__pydatastructs-177):
#       gold patch  -> resolved=true  (F2P test PASSED, test_exit 0)
#       empty patch -> resolved=false (F2P MISSING, test_exit 2)
#   - Cheap-model loop: OpenHands swebench-infer + Haiku 4.5 (max_iter 100),
#       224 events, 4946-char patch -> grader resolved=false (Haiku's patch
#       applied ok but did not solve the parallel-merge-sort task). The grader
#       discriminates the gold solution from both empty and Haiku's wrong patch.
#   - Loop/no-progress detector (_swerebench_progress_watch.py) aborts a live
#       stalled run (stall) and a live looping run (loop); ok on the healthy run.
#   - Footprint: swerebenchv2 base ~3 GB + OpenHands agent-server layer ~3.3 GB
#       = ~6.3 GB/instance (base shared across same base_image_name instances).
#
# OpenHands "builds its OWN eval-agent-server images" (the agent-server layer is
# built LOCALLY on top of the rebench base via buildx) -> it sidesteps the
# swe-rex / Pro-image quirks (libffi, 127.0.0.1:9876 pip mirror, [/bin/bash]
# entrypoint) the SWE-agent path needed. But it needed its OWN substrate fixes:
#
# PREREQS (one-time, on the box; all are SUBSTRATE fixes, NOT scaffold swaps):
#   1. uv -> $HOME/bin (the box's $HOME/.local is root-owned):
#        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/bin" sh
#   2. sudo chown -R ubuntu:ubuntu $HOME/.local   # else `uv build` (sdist for the
#        agent-server image) can't write $HOME/.local/share/uv/python -> EACCES.
#   3. docker buildx plugin + a docker-container builder (Docker 29 has no buildx
#        by default; the 'docker' driver fallback breaks the phased content-hash
#        tag match):
#        curl -fsSL <buildx release>/buildx-<tag>.linux-amd64 -o ~/.docker/cli-plugins/docker-buildx; chmod +x ...
#        docker buildx create --name openhands-builder --driver docker-container --use
#        docker buildx inspect --bootstrap
#   4. OpenHands/benchmarks @ 4e0d5b2 cloned to /opt/harnesses/openhands-benchmarks,
#        `make build` (uv sync --dev; vendor/software-agent-sdk @ c950fdb = SDK
#        v1.24.0-45 = the pinned tested-together tuple). The swerebench subclass +
#        event-JSONL sink deployed to benchmarks/swerebench/run_infer.py
#        (see _openhands_swerebench_infer.py).
#   5. SWE-rebench/SWE-bench-fork @ e4907b7 cloned to /opt/harnesses/swe-rebench-fork,
#        installed in its own venv (uv venv --python 3.11 .venv; uv pip install -e .)
#        — used ONLY for its canonical log-parser registry (MAP_REPO_TO_PARSER).
#        Its run_evaluation LOCAL path can't grade the swerebenchv2 prebuilt images
#        (assumes legacy conda/testbed layout -> KeyError 'python'); rebench-v2
#        images put the repo at /<reponame> with system python, so we grade with
#        _rebench_grade.py (canonical image + install_config.test_cmd + fork parser).
#
# KEY RUN-TIME FLAGS (set by this script):
#   IMAGE_TAG_PREFIX=c950fdb   # bypass the content-hash tag (build_image tags
#                              # {sdk}-{custom}; get_phased_image_tag_prefix() else
#                              # expects {sdk}-{contenthash}-{custom} and never matches)
#   REBENCH_EVENT_DIR=...      # where the event-JSONL sink writes <id>.events.jsonl
set -uo pipefail
OHB=/opt/harnesses/openhands-benchmarks
FORK=/opt/harnesses/swe-rebench-fork
RB="$OHB/_rebench"
export PATH="$HOME/bin:$PATH"
export OPENHANDS_SUPPRESS_BANNER=1
export IMAGE_TAG_PREFIX=c950fdb
export REBENCH_EVENT_DIR="$RB/events"
MAXITER="${MAXITER:-100}"
MODE="${1:-all}"   # all | grade-gold | grade-empty | infer | grade-model
# LLM_CONFIG (env): llm config json. Default = cheap Haiku (direct Anthropic, SSM
#   key). For the 3xi.2.2 frontier smoke set LLM_CONFIG=$RB/llm_opus.json
#   ({"model":"bedrock/us.anthropic.claude-opus-4-7","aws_region_name":"us-east-1"};
#   NO temperature — Opus 4.7 on Bedrock rejects it, and the SDK does not strip it
#   for Opus since it is not in EXTENDED_THINKING_MODELS; None is dropped, 0.0 is
#   rejected). Bedrock auth = box instance role; needs boto3 in the venv.
# SELECT (env): instance id(s) to run; default = CHOSEN_ID.
# Prompt caching (3xi.2.2): ON by default — SDK llm.caching_prompt defaults True
#   and _apply_prompt_caching marks system + last user/tool msg; per-turn cache
#   tokens are in EvalOutput.metrics.token_usages (analyze with _cache_analyze.py
#   --source openhands). No extra wiring needed; just confirm in the metrics.
LLM_CONFIG="${LLM_CONFIG:-$RB/llm_haiku.json}"

cd "$OHB"
[ -f "$RB/llm_haiku.json" ] || {
  KEY=$(aws ssm get-parameter --region us-east-1 --name /sandbox/api-keys/anthropic \
        --with-decryption --query Parameter.Value --output text)
  printf '{"model": "anthropic/claude-haiku-4-5-20251001", "api_key": "%s", "temperature": 0.0}\n' "$KEY" > "$RB/llm_haiku.json"
}
SELECT="${SELECT:-$(cat "$RB/CHOSEN_ID")}"
ID="$SELECT"
echo "START=$(date -u +%T) instance=$ID maxiter=$MAXITER mode=$MODE llm=$LLM_CONFIG"

grade() {  # $1=predictions.jsonl  $2=out_dir
  ( cd "$FORK" && .venv/bin/python _rebench_grade.py \
      --dataset "$RB/slice.jsonl" --predictions "$1" --out "$2" --timeout 1800 )
}

if [ "$MODE" = grade-gold ] || [ "$MODE" = all ]; then
  echo "### no-LLM gold control"; grade "$RB/predictions_gold.jsonl" "$RB/grade_gold"
fi
if [ "$MODE" = grade-empty ] || [ "$MODE" = all ]; then
  echo "### no-LLM empty control"; grade "$RB/predictions_empty.jsonl" "$RB/grade_empty"
fi
if [ "$MODE" = infer ] || [ "$MODE" = all ]; then
  echo "### model inference ($LLM_CONFIG)"
  OUTDIR="${OUTDIR:-$RB/eval_outputs}"
  rm -rf "$REBENCH_EVENT_DIR" "$OUTDIR"
  # SELECT may be a single id (default) or a newline file path via SELECT_FILE.
  SEL_ARG="$RB/CHOSEN_ID"; [ "$SELECT" != "$(cat "$RB/CHOSEN_ID")" ] && { printf '%s\n' "$SELECT" > "$RB/_select_one.txt"; SEL_ARG="$RB/_select_one.txt"; }
  [ -n "${SELECT_FILE:-}" ] && SEL_ARG="$SELECT_FILE"
  uv run python -m benchmarks.swerebench.run_infer "$LLM_CONFIG" \
    --dataset "$RB/slice.jsonl" --split train --workspace docker \
    --select "$SEL_ARG" --max-iterations "$MAXITER" --num-workers "${NUM_WORKERS:-1}" \
    --output-dir "$OUTDIR"
fi
if [ "$MODE" = grade-model ] || [ "$MODE" = all ]; then
  echo "### grade model patch"
  OUTDIR="${OUTDIR:-$RB/eval_outputs}"
  OJ=$(find "$OUTDIR" -name output.jsonl | head -1)
  python3 - "$OJ" "$RB/predictions_model.jsonl" <<'PY'
import json, sys
d = [json.loads(l) for l in open(sys.argv[1])][0]
open(sys.argv[2], "w").write(json.dumps({
    "instance_id": d["instance_id"],
    "model_patch": d["test_result"]["git_patch"],
    "model_name_or_path": "haiku-4-5-rebench"}) + "\n")
PY
  grade "$RB/predictions_model.jsonl" "$RB/grade_model"
fi
echo "DONE=$(date -u +%T)"
