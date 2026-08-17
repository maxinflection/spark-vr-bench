#!/usr/bin/env bash
# audit-pool-a-sec-bench.sh — apply the same audit discipline to SEC-bench-11
# campaigns that audit-pool-a-cybergym.sh applies to CyberGym. Read-only; no
# side effects on the run.
#
# The load-bearing addition vs the cybergym audit is `check_sandbox_blocklist`
# (Check 5): SEC-bench's smolagents `LocalPythonExecutor` enforces a tight
# whitelist on imports AND on Python builtins. Models that hit the whitelist
# get visible "not allowed" / "constructor" / "authorized_imports" errors in
# their per-step traces, then iterate-on-error until step exhaustion. This
# audit makes that pattern legible at audit time, so we don't run another
# 0/11 cell without knowing whether the model was capability-bounded or
# sandbox-bounded.
#
# Discovery + scope: `bd <ISSUE>` (P2, 2026-05-24). Methodology cross-reference:
# `docs/research/secbench-harness-methodology-2026-05-19.md`.
#
# Usage: audit-pool-a-sec-bench.sh <CAMPAIGN_NAME> [TARGET] [BENCH]
#   - CAMPAIGN_NAME: required, e.g. "<CAMPAIGN>-secbench11-<ISSUE>-2026-05-25"
#   - TARGET: default "vllm" (also: "opus47", "opus47direct", "gpt55")
#   - BENCH:  default "sec-bench-11"
#
# Exit code: 0 = clean, 1 = audit flags raised. Non-zero counts only — does
# not interpret pass-rates (that's the runner's job; this is methodology
# integrity).

set -uo pipefail
CAMPAIGN="${1:?Usage: $0 <CAMPAIGN> [TARGET] [BENCH]}"
TARGET="${2:-vllm}"
BENCH="${3:-sec-bench-11}"
LOCAL_ROOT="/var/lib/harness/results/${CAMPAIGN}/${TARGET}/${BENCH}"
S3_ROOT="s3://<RESULTS_BUCKET>/${CAMPAIGN}/${TARGET}/${BENCH}"

# Use local results dir if present; else materialize via S3 sync to a temp
# dir so the audit works against historical campaigns no longer on disk.
ROOT="${LOCAL_ROOT}"
if ! sudo test -d "${ROOT}"; then
  TMP_ROOT="$(mktemp -d -t audit-secb-XXXXXX)"
  echo "Local results dir ${LOCAL_ROOT} missing — syncing from ${S3_ROOT} to ${TMP_ROOT}"
  aws s3 sync --quiet "${S3_ROOT}/" "${TMP_ROOT}/" || {
    echo "  ⚠  S3 sync failed; aborting audit"
    exit 2
  }
  ROOT="${TMP_ROOT}"
  trap 'rm -rf "${TMP_ROOT}"' EXIT
fi

flagged=0
flag() { echo "  ⚠  $*"; flagged=$((flagged+1)); }
ok()   { echo "  ✓  $*"; }

echo "=== Audit campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH} ==="
echo "    results root: ${ROOT}"

# Check 1: per-task result.json present (n=11 for sec-bench-11)
# SEC-bench has 11 canonical instances; cells with fewer indicate harness
# crashes mid-run. (Different from cybergym which uses verdict.json — sec-
# bench writes result.json with `pass`/`sanitizer_triggered`/`reason` directly.)
echo
echo "[1] per-task result.json present (expected n=11)"
expected=11
found_result=$(sudo find "${ROOT}" -mindepth 2 -maxdepth 2 -name result.json | wc -l)
if [[ "${found_result}" -eq "${expected}" ]]; then ok "result.json ${found_result}/${expected}"
else flag "result.json ${found_result}/${expected} (missing ${expected} - ${found_result})"; fi

# Check 2: harness_variant legibility
# bd <ISSUE> + bd <ISSUE> dual-track depends on every result.json carrying the
# variant. Missing or null = stamp-file read failure at runner time.
echo
echo "[2] harness_variant field present in every result.json"
missing_variant=0
for rj in $(sudo find "${ROOT}" -name result.json); do
  hv=$(sudo jq -r '(.extra.harness_variant.variant // .extra.harness_variant // "<missing>")' "${rj}")
  if [[ "${hv}" == "<missing>" || "${hv}" == "null" ]]; then
    task=$(basename "$(dirname "${rj}")")
    flag "${task}: harness_variant missing — stamp-file read failure?"
    missing_variant=$((missing_variant+1))
  fi
done
if [[ "${missing_variant}" -eq 0 ]] && [[ "${found_result}" -gt 0 ]]; then
  hv_sample=$(sudo jq -r '(.extra.harness_variant.variant // .extra.harness_variant // "<missing>")' \
    "$(sudo find "${ROOT}" -name result.json | head -1)")
  ok "all ${found_result} results carry harness_variant=${hv_sample}"
fi

# Check 3: agent_id is 32-char hex (no dashes), same discipline as cybergym
# audit per memory feedback_pool_a_grading_audit. SEC-bench's smolagent
# scaffold also emits agent_id; dashed-UUID = wrong-format capture.
echo
echo "[3] agent_id is 32-char hex"
bad_ids=0
for rj in $(sudo find "${ROOT}" -name result.json); do
  aid=$(sudo jq -r '.agent_id // ""' "${rj}")
  if [[ -n "${aid}" && ! "${aid}" =~ ^[0-9a-f]{32}$ ]]; then
    flag "${rj#${ROOT}/}: agent_id=${aid:-<empty>}"
    bad_ids=$((bad_ids+1))
  fi
done
[[ "${bad_ids}" -eq 0 ]] && ok "all agent_ids are 32-char hex (or absent — sec-bench harness may not always emit)"

# Check 4: walltime distribution. SEC-bench tasks are 30-3600s typical; <30s
# = harness crash before agent ran; ≥3600s = timeout.
echo
echo "[4] walltime sanity (flag <30s or ≥3600s)"
suspicious=0
declare -A WT
for rj in $(sudo find "${ROOT}" -name result.json); do
  task_dir=$(dirname "${rj}")
  task=$(basename "${task_dir}")
  wt=$(sudo jq -r '.wall_time_seconds // 0' "${rj}")
  WT["${task}"]="${wt}"
  if [[ "${wt}" -lt 30 ]] || [[ "${wt}" -ge 3600 ]]; then
    flag "${task}: wall_time_seconds=${wt} suspicious"
    suspicious=$((suspicious+1))
  fi
done
[[ "${suspicious}" -eq 0 ]] && ok "all walltimes in 30..3600s band"
echo "  walltime distribution:"
for k in $(printf "%s\n" "${!WT[@]}" | sort); do
  printf "    %-30s %ss\n" "${k}" "${WT[$k]}"
done

# Check 5: SANDBOX-BLOCK PATTERN (the bd <ISSUE> load-bearing addition).
# Look for the ACTUAL smolagents InterpreterError signatures in the cleanest
# log surface: smolagent.log (one per task). This file has the agent's
# step-by-step output WITHOUT the repeated system prompt that pollutes
# trajectory.jsonl / output.json.
#
# Pattern strings (real block signals from smolagents/local_python_executor.py):
#   - "Code execution failed.*unauthorized import"  # the executor's error wrapper
#   - "InterpreterError: Import of .* is not allowed"   # raw class string
#   - "Forbidden access to module:"                 # check_safer_result reject
#   - "Forbidden access to function:"               # DANGEROUS_FUNCTIONS reject
#   - "Forbidden access to dunder attribute:"       # nodunder_getattr reject
#
# NOT MATCHED: bare "not allowed" / "authorized_imports" / "constructor" — these
# appear in the smolagents prompt template ({{authorized_imports}}, etc.) which
# the agent echoes back through its reasoning text. Counting them counted the
# prompt N times (one per step), not actual block events. The historical
# <CAMPAIGN>/5/7/10 audits showing 60-100 hits/task were ~95% false positives.
#
# Flagging threshold: a task with ≥2 REAL block events suggests sandbox
# interference. One block could be a one-off (e.g. agent probes subprocess
# which we intentionally don't allow); ≥2 indicates the sandbox is repeatedly
# binding.
echo
echo "[5] sandbox-block pattern in per-task smolagent.log (bd <ISSUE> signature)"
sandbox_blocked_tasks=0
sandbox_clean_tasks=0
declare -A SANDBOX_HITS
for task_dir in $(sudo find "${ROOT}" -mindepth 1 -maxdepth 1 -type d); do
  task=$(basename "${task_dir}")
  log="${task_dir}/smolagent.log"
  if ! sudo test -f "${log}"; then
    SANDBOX_HITS["${task}"]="no-log"
    continue
  fi
  # Count real InterpreterError signals only
  hits=$(sudo grep -cE 'Code execution failed due to an unauthorized import|InterpreterError: Import of .* is not allowed|Forbidden access to (module|function|dunder)' "${log}" 2>/dev/null)
  SANDBOX_HITS["${task}"]="${hits}"
  if [[ "${hits}" -ge 2 ]]; then
    flag "${task}: smolagent.log sandbox-block hits=${hits} (suggests bd <ISSUE> confound)"
    sandbox_blocked_tasks=$((sandbox_blocked_tasks+1))
  else
    sandbox_clean_tasks=$((sandbox_clean_tasks+1))
  fi
done
# Aggregate: what % of failed tasks show the sandbox-block signature?
total_tasks=$((sandbox_blocked_tasks + sandbox_clean_tasks))
if [[ "${total_tasks}" -gt 0 ]]; then
  pct=$((100 * sandbox_blocked_tasks / total_tasks))
  if [[ "${pct}" -ge 30 ]]; then
    flag "campaign-level: ${sandbox_blocked_tasks}/${total_tasks} (${pct}%) tasks show sandbox-block — bd <ISSUE> hypothesis SUPPORTED for this cell"
  elif [[ "${sandbox_blocked_tasks}" -gt 0 ]]; then
    echo "  ⚠  campaign-level: ${sandbox_blocked_tasks}/${total_tasks} (${pct}%) tasks show sandbox-block — bd <ISSUE> hypothesis WEAK for this cell"
  else
    ok "no tasks exceed sandbox-block threshold (>3 hits)"
  fi
fi
echo "  per-task sandbox-block hit counts:"
for k in $(printf "%s\n" "${!SANDBOX_HITS[@]}" | sort); do
  printf "    %-30s %s hits\n" "${k}" "${SANDBOX_HITS[$k]}"
done

# Check 6: sanitizer report presence per task. report_sanitizer.jsonl is the
# eval-mode-specific filename for `--type poc` (per `eval_instances.py`
# hardcoded path). Other modes (medium, custom) produce different filenames;
# missing/wrong = runner picked wrong eval mode.
echo
echo "[6] report_sanitizer.jsonl present per instance (eval-mode sanity)"
missing_reports=0
for task_dir in $(sudo find "${ROOT}" -mindepth 1 -maxdepth 1 -type d); do
  task=$(basename "${task_dir}")
  rs="${task_dir}/eval_out/report_sanitizer.jsonl"
  if ! sudo test -f "${rs}"; then
    other=$(sudo find "${task_dir}/eval_out" -name "report_*.jsonl" 2>/dev/null | head -1)
    if [[ -n "${other}" ]]; then
      flag "${task}: report_sanitizer.jsonl missing, but ${other#${task_dir}/} present (wrong eval-mode filename)"
    else
      flag "${task}: report_sanitizer.jsonl missing AND no other report_*.jsonl found"
    fi
    missing_reports=$((missing_reports+1))
  fi
done
[[ "${missing_reports}" -eq 0 ]] && ok "all ${total_tasks} tasks have report_sanitizer.jsonl"

# Check 7: pass distribution
echo
echo "[7] pass distribution"
passes=0; san_trig=0; san_no_trig=0; harness_err=0; other=0
for rj in $(sudo find "${ROOT}" -name result.json); do
  task=$(basename "$(dirname "${rj}")")
  pass=$(sudo jq -r '.pass // false' "${rj}")
  san=$(sudo jq -r '.sanitizer_triggered // "<missing>"' "${rj}")
  reason=$(sudo jq -r '.reason // "<missing>"' "${rj}")
  if [[ "${pass}" == "true" ]]; then
    passes=$((passes+1))
  fi
  case "${san}" in
    true) san_trig=$((san_trig+1)) ;;
    false) san_no_trig=$((san_no_trig+1)) ;;
    *) other=$((other+1)) ;;
  esac
  # Surface explicit "harness crashed" reasons separately
  if [[ "${reason}" =~ (timeout|crash|exception|harness) ]]; then
    harness_err=$((harness_err+1))
  fi
done
echo "  pass=${passes}/${total_tasks} sanitizer_triggered=${san_trig} no_trigger=${san_no_trig} other=${other} harness_err=${harness_err}"

echo
echo "=== Audit complete: flagged=${flagged} ==="
exit $(( flagged > 0 ? 1 : 0 ))
