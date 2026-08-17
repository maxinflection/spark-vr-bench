#!/usr/bin/env bash
# audit_cybergym_chain.sh — apply the bd <ISSUE> audit prescriptions (and the
# feedback_pool_a_grading_audit memory checks) to a live Pool A cybergym
# campaign. Read-only; no side effects on the run.
#
# Usage: audit_cybergym_chain.sh <CAMPAIGN_NAME>
#
# Exit code: 0 = clean, 1 = audit flags raised (details on stdout).

set -uo pipefail
CAMPAIGN="${1:?Usage: $0 <CAMPAIGN>}"
TARGET="${2:-vllm}"
BENCH="${3:-cybergym-10}"
ROOT="/var/lib/harness/results/${CAMPAIGN}/${TARGET}/${BENCH}"
POC_DB="/var/lib/harness/cybergym-server/${CAMPAIGN}/poc.db"

flagged=0
flag() { echo "  ⚠  $*"; flagged=$((flagged+1)); }
ok()   { echo "  ✓  $*"; }

echo "=== Audit campaign=${CAMPAIGN} target=${TARGET} bench=${BENCH} ==="

# Check 1: per-task result.json + verdict.json present
echo
echo "[1] per-task artifacts present"
expected=10
found_result=$(sudo find "${ROOT}" -mindepth 2 -maxdepth 2 -name result.json | wc -l)
found_verdict=$(sudo find "${ROOT}" -mindepth 2 -maxdepth 2 -name verdict.json | wc -l)
if [[ "${found_result}" -eq "${expected}" ]]; then ok "result.json ${found_result}/${expected}"
else flag "result.json ${found_result}/${expected} (missing ${expected} - ${found_result})"; fi
if [[ "${found_verdict}" -eq "${expected}" ]]; then ok "verdict.json ${found_verdict}/${expected}"
else flag "verdict.json ${found_verdict}/${expected}"; fi

# Check 2: poc_records COUNT > 0 (server access proof)
# Per memory feedback_cybergym_server_url — zero rows = silent grading bug.
echo
echo "[2] cybergym server received submissions (poc.db)"
if sudo test -f "${POC_DB}"; then
  count=$(sudo sqlite3 "${POC_DB}" 'SELECT COUNT(*) FROM poc_records' 2>/dev/null)
  if [[ "${count:-0}" -gt 0 ]]; then ok "poc_records=${count}"
  else flag "poc_records=0 — server never reached (URL bug class? per memory feedback_cybergym_server_url)"
  fi
else
  flag "poc.db missing at ${POC_DB}"
fi

# Check 3: agent_id is 32-char hex (no dashes) in verdict.json
# Per memory feedback_pool_a_grading_audit — dashed-UUID format means the
# runner's regex grabbed OpenHands' session UUID instead of cybergym's
# gen_task agent id. Silent grading bug.
echo
echo "[3] agent_id is 32-char hex"
bad_ids=0
for vj in $(sudo find "${ROOT}" -name verdict.json); do
  aid=$(sudo jq -r '.agent_id // ""' "${vj}")
  if [[ ! "${aid}" =~ ^[0-9a-f]{32}$ ]]; then
    flag "${vj#$ROOT/}: agent_id=${aid:-<empty>}"
    bad_ids=$((bad_ids+1))
  fi
done
[[ "${bad_ids}" -eq 0 ]] && ok "all ${found_verdict} agent_ids are 32-char hex"

# Check 4: walltime distribution — flag any task < 30s (likely container-404
# failure per skill memo) OR ≥ 7200s (hit per-task timeout)
echo
echo "[4] walltime sanity (flag <30s or ≥7200s)"
suspicious=0
declare -A WT
for rj in $(sudo find "${ROOT}" -name result.json); do
  task_dir=$(dirname "${rj}")
  task=$(basename "${task_dir}")
  wt=$(sudo jq -r '.wall_time_seconds // 0' "${rj}")
  WT["${task}"]="${wt}"
  if [[ "${wt}" -lt 30 ]] || [[ "${wt}" -ge 7200 ]]; then
    flag "${task}: wall_time_seconds=${wt} suspicious"
    suspicious=$((suspicious+1))
  fi
done
[[ "${suspicious}" -eq 0 ]] && ok "all walltimes in 30..7200s band"
echo "  walltime distribution:"
for k in $(printf "%s\n" "${!WT[@]}" | sort); do
  printf "    %-30s %ss\n" "${k}" "${WT[$k]}"
done

# Check 5: short-openhands-log heuristic — per skill Step 8 cost-guard
# "agent log shows <6 lines → OpenHands runtime container didn't start"
echo
echo "[5] openhands-run.log size (skill cost-guard: <6 lines → container 404)"
short_logs=0
for ohlog in $(sudo find "${ROOT}" -name openhands-run.log); do
  task_dir=$(dirname "${ohlog}")
  task=$(basename "${task_dir}")
  lines=$(sudo wc -l < "${ohlog}")
  if [[ "${lines}" -lt 6 ]]; then
    flag "${task}: openhands-run.log only ${lines} lines"
    short_logs=$((short_logs+1))
  fi
done
[[ "${short_logs}" -eq 0 ]] && ok "all openhands logs ≥ 6 lines"

# Check 6: pass distribution + sanitizer_verdict cross-check
echo
echo "[6] pass distribution + sanitizer_verdict cross-check"
passes=0; nopocs=0; nocrash=0; nosan=0; other=0
for vj in $(sudo find "${ROOT}" -name verdict.json); do
  task=$(basename "$(dirname "${vj}")")
  pass=$(sudo jq -r '.pass // false' "${vj}")
  sv=$(sudo jq -r '.sanitizer_verdict // "<missing>"' "${vj}")
  case "${pass}-${sv}" in
    true-*pass*|true-*success*|true-triggered) passes=$((passes+1)) ;;
    true-*) passes=$((passes+1)); flag "${task}: pass=true but sanitizer_verdict=${sv}" ;;
    false-no_poc_submitted) nopocs=$((nopocs+1)) ;;
    false-no_crash) nocrash=$((nocrash+1)) ;;
    false-no_sanitizer) nosan=$((nosan+1)) ;;
    *) other=$((other+1)); echo "    ${task}: pass=${pass} sv=${sv}" ;;
  esac
done
echo "  pass=${passes} no_poc=${nopocs} no_crash=${nocrash} no_sanitizer=${nosan} other=${other}"

echo
echo "=== Audit complete: flagged=${flagged} ==="
exit $(( flagged > 0 ? 1 : 0 ))
