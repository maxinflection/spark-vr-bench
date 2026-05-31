#!/usr/bin/env bash
# audit-eb-shakedown.sh — read-only audit of an ExploitBench shakedown
# run (2-task × 30-turn) for plumbing validation before firing canonical
# 14×300 cells. Designed for new model bring-up (V4-Flash, future models)
# where the LiteLLM ↔ vLLM ↔ tool-call-parser path is untested.
#
# Usage: audit-eb-shakedown.sh <CAMPAIGN> [<TARGET=vllm>] [<BENCH=exploitbench-14-shakedown>]
#
# Exit code: 0 = clean (proceed to canonical), 1 = audit flags raised (STOP).

set -uo pipefail
CAMPAIGN="${1:?Usage: $0 <CAMPAIGN> [target] [bench]}"
TARGET="${2:-vllm}"
BENCH="${3:-exploitbench-14-shakedown}"
ROOT="/var/lib/harness/results/${CAMPAIGN}/${TARGET}/${BENCH}"
EXPECTED_TASKS=2  # shakedown is 2-task by convention

flagged=0
warned=0
flag() { echo "  ✗  $*"; flagged=$((flagged+1)); }
warn() { echo "  ⚠  $*"; warned=$((warned+1)); }
ok()   { echo "  ✓  $*"; }

echo "=== ExploitBench shakedown audit ==="
echo "    campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH}"
echo "    root=${ROOT}"
echo

# Check 1: per-task artifacts present
echo "[1] per-task artifacts (result.json + verdict.json + eb_artifacts/)"
if ! sudo test -d "${ROOT}"; then
  flag "ROOT dir missing: ${ROOT} — runner may have crashed before any task wrote"
  echo
  echo "RESULT: ${flagged} hard fail(s), ${warned} warning(s)"
  exit 1
fi
task_dirs=$(sudo find "${ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
n_tasks=$(echo "${task_dirs}" | grep -c '/')
if [[ "${n_tasks}" -ne "${EXPECTED_TASKS}" ]]; then
  flag "expected ${EXPECTED_TASKS} task dirs, found ${n_tasks}"
fi
for d in ${task_dirs}; do
  task=$(basename "${d}")
  for art in result.json verdict.json eb_artifacts/score.json eb_artifacts/transcript.jsonl eb_artifacts/cost.json; do
    if sudo test -f "${d}/${art}"; then
      ok "${task}: ${art}"
    else
      flag "${task}: ${art} MISSING"
    fi
  done
done

# Check 2: raw_bitmap has exactly 16 elements per task
echo
echo "[2] raw_bitmap shape (16 elements, 0/1 values)"
for d in ${task_dirs}; do
  task=$(basename "${d}")
  rfile="${d}/result.json"
  if ! sudo test -f "${rfile}"; then continue; fi
  shape=$(sudo jq -r '.extra.raw_bitmap // .raw_bitmap // empty | length' "${rfile}" 2>/dev/null)
  if [[ "${shape}" == "16" ]]; then
    bits=$(sudo jq -r '.extra.raw_bitmap // .raw_bitmap | join("")' "${rfile}" 2>/dev/null)
    ok "${task}: bitmap_len=16 bits=${bits}"
  else
    flag "${task}: raw_bitmap shape=${shape:-MISSING} (expected 16)"
  fi
done

# Check 3: tool_calls emitted + accepted (CRITICAL for V4-Flash deepseek_v4 parser test)
echo
echo "[3] tool_calls emitted in transcript (parser plumbing check)"
for d in ${task_dirs}; do
  task=$(basename "${d}")
  trans="${d}/eb_artifacts/transcript.jsonl"
  if ! sudo test -f "${trans}"; then continue; fi
  # Count assistant messages with non-empty tool_calls vs empty/null.
  with_tc=$(sudo jq -s '[.[] | select(.role == "assistant") | select(.tool_calls != null and (.tool_calls | length) > 0)] | length' "${trans}" 2>/dev/null || echo 0)
  asst_total=$(sudo jq -s '[.[] | select(.role == "assistant")] | length' "${trans}" 2>/dev/null || echo 0)
  if [[ "${with_tc}" == "0" && "${asst_total}" -gt 0 ]]; then
    flag "${task}: 0/${asst_total} assistant msgs had tool_calls — deepseek_v4 parser likely broken (or <think> swallowing per vllm#41132)"
  elif [[ "${asst_total}" == "0" ]]; then
    flag "${task}: no assistant messages in transcript — agent never reached the model"
  else
    ok "${task}: tool_calls in ${with_tc}/${asst_total} assistant turns"
  fi
done

# Check 4: finish_reason histogram (no all-content_filter or all-length)
echo
echo "[4] finish_reason histogram (no content_filter / length saturation)"
for d in ${task_dirs}; do
  task=$(basename "${d}")
  trans="${d}/eb_artifacts/transcript.jsonl"
  if ! sudo test -f "${trans}"; then continue; fi
  hist=$(sudo jq -r 'select(.finish_reason != null) | .finish_reason' "${trans}" 2>/dev/null | sort | uniq -c | tr '\n' ' ')
  echo "    ${task}: ${hist:-<no finish_reason fields>}"
  if echo "${hist}" | grep -q "content_filter"; then
    warn "${task}: content_filter seen — V4-Flash safety filter triggered (unusual but track it)"
  fi
done

# Check 5: audit_replay_verdict not 'discrepancy' on both tasks
echo
echo "[5] audit_replay_verdict (consistent/discrepancy/skipped)"
audit_log="${ROOT}/audit-replay.log"
if sudo test -f "${audit_log}"; then
  discrep=$(sudo grep -c "verdict.*discrepancy" "${audit_log}" 2>/dev/null || echo 0)
  if [[ "${discrep}" == "${EXPECTED_TASKS}" ]]; then
    flag "all ${EXPECTED_TASKS}/${EXPECTED_TASKS} tasks had verdict=discrepancy — methodology broken"
  elif [[ "${discrep}" -gt 0 ]]; then
    warn "${discrep}/${EXPECTED_TASKS} tasks had verdict=discrepancy (mixed)"
  else
    ok "no discrepancy verdicts in audit-replay.log"
  fi
else
  warn "audit-replay.log not found at ${audit_log} — replay may not have run"
fi

# Check 6: vLLM server log on rental for crashes
echo
echo "[6] vLLM server log for kernel crashes / DeepGEMM assertions"
ep_file="/var/lib/harness/rentals/<REDACTED_IP>.json"
if sudo test -f "${ep_file}"; then
  RENTAL_HOST=$(sudo jq -r '.rental_host' "${ep_file}" 2>/dev/null)
else
  RENTAL_HOST="<REDACTED_IP>"  # fallback for <CAMPAIGN>
fi
crash_signatures=$(sudo ssh -i /home/ubuntu/.ssh/gpu-rental -o StrictHostKeyChecking=accept-new "root@${RENTAL_HOST}" \
  'grep -E "Unsupported architecture|deepgemm.*assertion|CUDA error|RuntimeError|out of memory|OOM" /var/log/vllm.log 2>/dev/null | tail -5' 2>/dev/null || true)
if [[ -n "${crash_signatures}" ]]; then
  flag "kernel crash signatures in vllm.log:"
  echo "${crash_signatures}" | sed 's/^/      /'
else
  ok "no kernel crash signatures in vllm.log"
fi

echo
echo "========================================================================"
echo "RESULT: ${flagged} hard fail(s), ${warned} warning(s)"
if [[ "${flagged}" -gt 0 ]]; then
  echo "STATUS: ✗  SHAKEDOWN FAILED — STOP. Do NOT fire canonical run."
  echo "Next steps: diagnose per the launch script's 'Likely failure modes',"
  echo "OR teardown via: bash /opt/benchmarks/scripts/rental-vllm-down.sh"
  exit 1
fi
echo "STATUS: ✓  SHAKEDOWN PASSED — proceed to Stage 3 (Pool B + Pool A lanes)."
exit 0
