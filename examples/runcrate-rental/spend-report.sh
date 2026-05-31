#!/usr/bin/env bash
# spend-report.sh — Print compute + inference spend across the benchmarks
# campaign.
#
# Aggregates three sources:
#   1. ACTIVE Runcrate rentals — live cost-per-hour × time-since-deployed
#      (queried from www.runcrate.ai/api/v1/instances; auth from SSM
#      /sandbox/api-keys/runcrate)
#   2. HISTORICAL Runcrate rentals — local JSONL ledger at
#      /var/lib/harness/spend-ledger.jsonl, populated by rental-vllm-up.sh
#      (start record) and rental-vllm-down.sh (end record). Captures runs
#      that are no longer in the API's `/instances` list.
#   3. AWS Bedrock/EC2 spend — via Cost Explorer (if the caller has
#      `ce:GetCostAndUsage`). Degrades gracefully otherwise.
#
# Usage:
#   spend-report.sh              # default 7-day window
#   spend-report.sh --days 1     # last 24 hours
#   spend-report.sh --days 30    # last month
#   spend-report.sh --json       # one-line JSON output (for scripting)
#
# Best run from the harness (instance role has SSM access for the Runcrate
# key) or from operator laptop with iptadmin (which adds Cost Explorer).
#
# Issue: spend-report-script (filed alongside the bigcodebench bap work)

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Constants
# ============================================================
readonly RUNCRATE_API_BASE="https://www.runcrate.ai/api/v1"
readonly RUNCRATE_KEY_SSM="/sandbox/api-keys/runcrate"
readonly LEDGER_PATH="/var/lib/harness/spend-ledger.jsonl"
readonly AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ============================================================
# Args
# ============================================================
DAYS=7
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    -h|--help)
      awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^!'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if ! [[ "${DAYS}" =~ ^[1-9][0-9]*$ ]]; then
  printf '--days must be a positive integer\n' >&2
  exit 1
fi

# ============================================================
# Helpers
# ============================================================
err() { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Fetch Runcrate key from SSM (best-effort).
fetch_runcrate_key() {
  if [[ -n "${RUNCRATE_API_KEY:-}" ]]; then
    printf '%s' "${RUNCRATE_API_KEY}"
    return 0
  fi
  aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "${RUNCRATE_KEY_SSM}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null
}

# ============================================================
# 1. Active Runcrate rentals
# Returns JSON array: [{id, name, region, hourly, hours_active, cost}, ...]
# ============================================================
collect_active_rentals() {
  local key="$1"
  if [[ -z "${key}" ]]; then
    printf '[]'
    return 0
  fi
  local body
  body="$(curl -sS --max-time 15 -H "Authorization: Bearer ${key}" \
    "${RUNCRATE_API_BASE}/instances" 2>/dev/null || printf '{"data":[]}')"
  printf '%s' "${body}" | jq --argjson now "$(date -u +%s)" '
    [
      .data[]?
      | select(.status == "running" or .status == "deploying")
      | (.deployed_at // .created_at) as $start_iso
      | ($start_iso | sub("\\.[0-9]+"; "") | sub("\\+.*$"; "Z")) as $start_clean
      | ($start_clean | fromdateiso8601) as $start
      | (($now - $start) / 3600.0) as $hours
      | {
          id,
          name,
          region,
          status,
          hourly: .cost_per_hour,
          hours_active: ($hours | . * 100 | round | . / 100),
          cost: ($hours * .cost_per_hour | . * 100 | round | . / 100)
        }
    ]
  '
}

# ============================================================
# 2. Historical Runcrate rentals from local ledger
# Ledger format (one JSON object per line):
#   {"event":"start","id":"<uuid>","name":"...","cost_per_hour":1.97,
#    "deployed_at":"2026-05-09T00:00:00Z"}
#   {"event":"end","id":"<uuid>","ended_at":"...","total_cost":3.45}
# Sums total_cost for end-events within the window. Skips active rentals
# (those have a start but no end yet) since they're covered in (1).
# ============================================================
collect_historical_ledger() {
  local since_epoch="$1"
  if [[ ! -r "${LEDGER_PATH}" ]]; then
    printf '{"total":0,"count":0,"sources":[]}'
    return 0
  fi
  jq -s --argjson since "${since_epoch}" '
    [
      .[]
      | select(.event == "end")
      | select((.ended_at | sub("\\.[0-9]+";""; "g") | sub("\\+.*$"; "Z") | fromdateiso8601) >= $since)
    ] as $ends
    | {
        total: ($ends | map(.total_cost // 0) | add // 0),
        count: ($ends | length),
        sources: $ends
      }
  ' < "${LEDGER_PATH}"
}

# ============================================================
# 3. AWS Cost Explorer — Bedrock + EC2 (best-effort)
# Returns JSON: {bedrock: <usd>, ec2: <usd>, ce_available: true|false}
# ============================================================
collect_aws_costs() {
  local since="$1"
  local until
  until="$(date -u +%Y-%m-%d)"
  local probe_err
  probe_err="$(aws ce get-cost-and-usage \
    --time-period "Start=${since},End=${until}" \
    --granularity DAILY \
    --metrics UnblendedCost \
    --region "${AWS_REGION}" \
    --filter '{"Or":[{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}},{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}]}' \
    --group-by 'Type=DIMENSION,Key=SERVICE' \
    2>&1 1>/tmp/.spend_ce_out || true)"

  if [[ ! -s /tmp/.spend_ce_out ]] || grep -q 'AccessDenied\|UnauthorizedOperation' <<< "${probe_err}"; then
    printf '{"ce_available":false,"bedrock":0,"ec2":0,"error":%s}' \
      "$(printf '%s' "${probe_err}" | head -c 200 | jq -Rs .)"
    rm -f /tmp/.spend_ce_out
    return 0
  fi

  local body
  body="$(cat /tmp/.spend_ce_out)"
  rm -f /tmp/.spend_ce_out

  printf '%s' "${body}" | jq '
    .ResultsByTime as $days
    | {
        ce_available: true,
        bedrock: ([
          $days[].Groups[]?
          | select(.Keys[0] == "Amazon Bedrock")
          | (.Metrics.UnblendedCost.Amount | tonumber)
        ] | add // 0),
        ec2: ([
          $days[].Groups[]?
          | select(.Keys[0] == "Amazon Elastic Compute Cloud - Compute")
          | (.Metrics.UnblendedCost.Amount | tonumber)
        ] | add // 0)
      }
    | .bedrock = (.bedrock * 100 | round / 100)
    | .ec2 = (.ec2 * 100 | round / 100)
  '
}

# ============================================================
# Main
# ============================================================
main() {
  local since_iso since_epoch
  since_iso="$(date -u -d "${DAYS} days ago" +%Y-%m-%d)"
  since_epoch="$(date -u -d "${DAYS} days ago" +%s)"

  local key active_rentals historical aws_costs
  key="$(fetch_runcrate_key || printf '')"
  active_rentals="$(collect_active_rentals "${key}")"
  historical="$(collect_historical_ledger "${since_epoch}")"
  aws_costs="$(collect_aws_costs "${since_iso}")"

  local active_total active_count
  active_total="$(printf '%s' "${active_rentals}" | jq '[.[].cost] | add // 0')"
  active_count="$(printf '%s' "${active_rentals}" | jq 'length')"
  local hist_total hist_count
  hist_total="$(printf '%s' "${historical}" | jq '.total')"
  hist_count="$(printf '%s' "${historical}" | jq '.count')"
  local bedrock ec2 ce_ok
  bedrock="$(printf '%s' "${aws_costs}" | jq '.bedrock')"
  ec2="$(printf '%s' "${aws_costs}" | jq '.ec2')"
  ce_ok="$(printf '%s' "${aws_costs}" | jq '.ce_available')"

  local grand_total
  grand_total="$(jq -n \
    --argjson a "${active_total}" \
    --argjson h "${hist_total}" \
    --argjson b "${bedrock}" \
    --argjson e "${ec2}" \
    '($a + $h + $b + $e) * 100 | round / 100')"

  if [[ "${JSON_OUTPUT}" == "true" ]]; then
    jq -n \
      --arg     window_days  "${DAYS}" \
      --arg     since_iso    "${since_iso}" \
      --argjson active       "${active_rentals}" \
      --argjson active_total "${active_total}" \
      --argjson hist         "${historical}" \
      --argjson aws          "${aws_costs}" \
      --argjson grand_total  "${grand_total}" \
      '{
        window_days: $window_days,
        since: $since_iso,
        runcrate_active: { rentals: $active, total: $active_total },
        runcrate_historical: $hist,
        aws: $aws,
        grand_total_usd: $grand_total
      }'
    return 0
  fi

  printf '\n=== Spend report (last %s day%s, since %s) ===\n\n' \
    "${DAYS}" "$( [[ ${DAYS} -eq 1 ]] && printf '' || printf 's' )" "${since_iso}"

  printf '── Runcrate (active rentals) ──\n'
  if (( active_count == 0 )); then
    printf '  (no active rentals)\n'
  else
    printf '%s' "${active_rentals}" | jq -r '
      .[] | "  \(.name) (\(.id[0:8])) — \(.region)\n    status=\(.status) hourly=$\(.hourly) hours_active=\(.hours_active) → $\(.cost)"'
    printf '  Subtotal active: $%s\n' "${active_total}"
  fi
  printf '\n'

  printf '── Runcrate (historical, from %s) ──\n' "${LEDGER_PATH}"
  if (( hist_count == 0 )); then
    if [[ ! -r "${LEDGER_PATH}" ]]; then
      printf '  (ledger file not present yet — populated by rental-vllm-up/down.sh)\n'
    else
      printf '  (no completed rentals in window)\n'
    fi
  else
    printf '  Completed rentals in window: %s\n' "${hist_count}"
    printf '  Subtotal historical: $%s\n' "${hist_total}"
  fi
  printf '\n'

  printf '── AWS Cost Explorer (last %s days, full account scope) ──\n' "${DAYS}"
  if [[ "${ce_ok}" == "true" ]]; then
    printf '  Bedrock: $%s\n' "${bedrock}"
    printf '  EC2:     $%s\n' "${ec2}"
  else
    printf '  (Cost Explorer access denied for this caller — needs `ce:GetCostAndUsage`)\n'
    printf '  Run from operator iptadmin profile for full picture.\n'
  fi
  printf '\n'

  printf '── Total visible to this caller ──\n'
  printf '  $%s\n' "${grand_total}"
  printf '  Note: only AWS+Runcrate-visible costs counted. OpenAI (gpt55),\n'
  printf '        HuggingFace LFS bandwidth, and 3rd-party services are\n'
  printf '        not included.\n\n'
}

main
