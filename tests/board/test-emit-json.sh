#!/usr/bin/env bash
# test-emit-json.sh — offline self-test for update-sweep-status.sh --emit-json
# (bd <ISSUE>). Drives the aggregator with tests/board/results-fixture.jsonl via
# the RESULTS_FIXTURE seam (no S3), then asserts the board.json it emits is
# schema-valid and that every condition-tagging / filtering rule behaves.
#
# Run:  bash tests/board/test-emit-json.sh
# Exit: 0 all pass; 1 a check failed.

set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd -P)"
FIXTURE="${HERE}/results-fixture.jsonl"
SCRIPT="${REPO_ROOT}/scripts/update-sweep-status.sh"
SCHEMA="${REPO_ROOT}/docs/board/schema.json"
VALIDATOR="${REPO_ROOT}/scripts/validate-board-json.py"

BOARD="$(mktemp)"
trap 'rm -f "${BOARD}"' EXIT

fail=0
pass() { printf '  ✓ %s\n' "$1"; }
ng()   { printf '  ✗ %s\n' "$1" >&2; fail=1; }
# check <desc> <jq-filter> : filter must evaluate true against the board.json
check() {
  local desc="$1" filter="$2"
  if [[ "$(jq -r "${filter}" "${BOARD}")" == "true" ]]; then pass "${desc}"; else ng "${desc}"; fi
}

echo "[emit] generating board.json from fixture..."
RESULTS_FIXTURE="${FIXTURE}" bash "${SCRIPT}" --emit-json "${BOARD}"

echo "[schema] validating against ${SCHEMA##*/}..."
if python3 "${VALIDATOR}" "${BOARD}" --schema "${SCHEMA}"; then pass "schema-valid"; else ng "schema-valid"; fi

echo "[invariants]"
# Condition derivation: thinking off/on from extra.enable_thinking
check "HE+ Qwen27B keeps BOTH thinking modes (no collapse)" \
  '[.scores[]|select(.model_id=="qwen3.6-27b-fp8" and .bench_id=="humaneval-plus").measurements[]|select(.status!="smoke").condition.thinking]|sort==["off","on"]'
# Smoke is preserved but tagged, not dropped
check "HE+ smoke run kept with status=smoke" \
  '[.scores[]|select(.model_id=="qwen3.6-27b-fp8" and .bench_id=="humaneval-plus").measurements[]|select(.status=="smoke")]|length==1'
# SEC-bench: stock + <ISSUE> both present (harness axis preserved)
check "SEC-bench Gemma31 keeps stock AND <ISSUE>" \
  '[.scores[]|select(.model_id=="gemma4-31b-nvfp4" and .bench_id=="sec-bench").measurements[].condition.harness]|sort==["<ISSUE>","stock"]'
# variant_class=exclude (bd-227-only) dropped -> no third harness value, no dup
check "SEC-bench exclude-class (<ISSUE>-only) dropped" \
  '[.scores[]|select(.model_id=="gemma4-31b-nvfp4" and .bench_id=="sec-bench").measurements[]]|length==2'
# harness pinned ONLY on benches with a harness axis (sec-bench); omitted elsewhere
check "non-harness benches omit harness condition (HE+/IFEval/CyberGym/CVE)" \
  '[.scores[]|select(.bench_id!="sec-bench").measurements[].condition|has("harness")]|any|not'
# every condition is non-empty (schema minProperties>=1)
check "every measurement condition has >=1 dim" \
  '[.scores[].measurements[].condition|length>0]|all'
# bd <ISSUE> junk campaign never renders
check "bd <ISSUE> junk campaign (Qwen235B sec-bench) absent" \
  '[.scores[]|select(.model_id=="qwen3-235b-a22b-thinking-awq" and .bench_id=="sec-bench")]|length==0'
# CVE max_turns derived from extra.max_messages (==30, matches canonical_condition)
check "CVE-Bench Opus max_turns derived from max_messages=30" \
  '(.scores[]|select(.model_id=="opus-4-7" and .bench_id=="cve-bench").measurements[0].condition.max_turns)=="30"'
# CyberGym max_turns stamped from bench default_condition (not in result.json)
check "CyberGym max_turns stamped from default_condition=100" \
  '(.scores[]|select(.bench_id=="cybergym").measurements[0].condition.max_turns)=="100"'
# Direct-API Opus (model_id claude-opus-4-7) aliased + mapped to opus-4-7 row
check "direct-API Opus CVE row aliased into opus-4-7" \
  '[.scores[]|select(.model_id=="opus-4-7" and .bench_id=="cve-bench")]|length==1'
# Unknown model dropped (no board registry entry)
check "unknown model_id dropped" \
  '[.scores[].model_id]|index("someorg/Unknown-Model-99B")==null'
# emit-only fields stripped from output
check "model.match stripped from output" '[.models[]|has("match")]|any|not'
check "bench.emit stripped from output"  '[.benches[]|has("emit")]|any|not'
# canonical_condition carried through per benchmark-canonical-protocols.md
check "CVE-Bench canonical_condition max_turns=30" \
  '(.benches[]|select(.id=="cve-bench").canonical_condition)=={"max_turns":"30"}'
check "SEC-bench canonical_condition omitted (harness-divergent)" \
  '(.benches[]|select(.id=="sec-bench")|has("canonical_condition"))|not'
check "HumanEval+ canonical_condition omitted (authors silent on thinking)" \
  '(.benches[]|select(.id=="humaneval-plus")|has("canonical_condition"))|not'

if [[ "${fail}" -eq 0 ]]; then echo "ALL EMIT-JSON CHECKS PASSED"; else echo "EMIT-JSON CHECKS FAILED" >&2; fi
exit "${fail}"
