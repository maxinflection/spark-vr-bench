#!/usr/bin/env bash
# rental-stock-watch.sh — poll Runcrate for deployable multi-GPU inventory
#
# Watches the SKUs that block benchmarks-<CAMPAIGN>/9/10 (and similar) and alerts
# when one transitions out-of-stock → in-stock. Runs as a cron job on the
# harness EC2.
#
# Why this exists: Runcrate has no read-only availability endpoint.
# /v1/instances/types returns the full SKU catalog regardless of stock; the
# only true signal is POST /v1/instances which either:
#   - HTTP 500 "no longer available"      → SKU out of stock, nothing deployed
#   - HTTP 201 with instance body         → SKU in stock and WE JUST DEPLOYED IT
#
# So the probe IS the deploy. On 201 we capture instance_id and DELETE
# immediately. Runcrate's minimum billing granularity is ~1 minute; worst-case
# cost per accidental land is ~$0.26 (1 min @ rtxpro6000x8 $15.75/hr). Vastly
# cheaper than missing a 15-min window of availability.
#
# Usage (typically from cron every 15 min):
#   sudo bash /opt/benchmarks/scripts/rental-stock-watch.sh
#
# Output:
#   - Log:     /var/log/rental-stock-watch.log
#   - State:   /var/lib/harness/rental-stock-watch.state.json
#   - Alerts:  /var/lib/harness/rental-stock-alerts.jsonl  (append-only)
#
# To watch a different SKU set, edit the WATCH_SKUS array below.
#
# Exit codes:
#   0 — always (cron-friendly; errors logged, never raised)

set -Eeo pipefail
IFS=$'\n\t'

SCRIPT_NAME="rental-stock-watch"
readonly SCRIPT_NAME

# ============================================================
# Config
# ============================================================
# SKUs to watch. Currently the multi-GPU Runcrate SKUs that block <CAMPAIGN>/9/10.
# Each entry: "<instance_type_id>:<purpose>"
readonly -a WATCH_SKUS=(
  "jolly-maxwell-rtxpro6000x2-065d:RTXPro6000x2 KC \$3.94/hr — <CAMPAIGN>/9 primary"
  "upbeat-haibt-rtxpro6000x4-fac3:RTXPro6000x4 KC \$7.88/hr — <CAMPAIGN> primary"
  "stoic-tharp-h100x2-4d7a:H100x2 Paris \$6.69/hr — <CAMPAIGN>/9 secondary"
)

readonly RUNCRATE_API_BASE="https://www.runcrate.ai/api/v1"
readonly RUNCRATE_KEY_SSM="/sandbox/api-keys/runcrate"
readonly AWS_REGION_DEFAULT="us-east-1"

readonly STATE_DIR="/var/lib/harness"
readonly STATE_FILE="${STATE_DIR}/rental-stock-watch.state.json"
readonly ALERT_LOG="${STATE_DIR}/rental-stock-alerts.jsonl"
readonly LOG_FILE="/var/log/rental-stock-watch.log"
readonly LOCK_FILE="${STATE_DIR}/.rental-stock-watch.lock"

# Curl timeouts. Probe has to be tight: if 30s in, we're either deploying
# something we'll need to clean up OR the API is wedged. Either way bail.
readonly CURL_CONNECT_TIMEOUT=10
readonly CURL_MAX_TIME=30

# ============================================================
# Logging
# ============================================================
log() {
  local ts level msg
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  level="$1"; shift
  msg="$*"
  local line="[${ts}] [${level}] ${msg}"
  printf '%s\n' "${line}" >&2
  printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
}
log_info()  { log "info"  "$@"; }
log_warn()  { log "warn"  "$@"; }
log_error() { log "error" "$@"; }

# ============================================================
# Setup
# ============================================================
ensure_dirs() {
  mkdir -p "${STATE_DIR}"
  : > "${LOG_FILE}.touch-probe" 2>/dev/null && rm -f "${LOG_FILE}.touch-probe" || {
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  }
}

fetch_runcrate_key() {
  if [[ -n "${RUNCRATE_API_KEY:-}" ]]; then
    printf '%s' "${RUNCRATE_API_KEY}"
    return 0
  fi
  local region="${AWS_REGION:-${AWS_REGION_DEFAULT}}"
  aws ssm get-parameter \
    --region "${region}" \
    --name "${RUNCRATE_KEY_SSM}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null
}

fetch_ssh_key_id() {
  # Project has a single registered key (gpu-rental). If multiple, prefer the
  # one named "gpu-rental".
  local key="$1"
  curl -sS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    -H "Authorization: Bearer ${key}" \
    "${RUNCRATE_API_BASE}/ssh-keys" 2>/dev/null \
    | jq -r '.data[] | select(.name == "gpu-rental") | .id' 2>/dev/null \
    | head -n1
}

# ============================================================
# Probe + cleanup
# ============================================================
# Returns one of: in_stock | out_of_stock | error
# On in_stock, captures instance_id in INSTANCE_ID and triggers cleanup.
INSTANCE_ID=""
probe_sku() {
  local sku_id="$1"
  local key="$2"
  local ssh_key_id="$3"
  INSTANCE_ID=""

  local probe_name="stock-watch-probe-${sku_id:0:30}-$(date +%s)"
  # 64-char hard cap on names per Runcrate observation; trim if needed.
  probe_name="${probe_name:0:60}"

  local body http_code
  body=$(curl -sS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    -X POST \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${probe_name}\",\"ssh_key_id\":\"${ssh_key_id}\",\"instance_type_id\":\"${sku_id}\"}" \
    -w "\n__HTTP_CODE__:%{http_code}" \
    "${RUNCRATE_API_BASE}/instances" 2>/dev/null) || {
    log_error "sku=${sku_id} probe curl failed"
    printf 'error'
    return 0
  }
  http_code="${body##*__HTTP_CODE__:}"
  body="${body%__HTTP_CODE__:*}"

  case "${http_code}" in
    201)
      INSTANCE_ID="$(printf '%s' "${body}" | jq -r '.id // .data.id // empty' 2>/dev/null)"
      if [[ -z "${INSTANCE_ID}" ]]; then
        log_error "sku=${sku_id} probe returned 201 but no id field; body=$(printf '%s' "${body}" | head -c 200)"
        printf 'error'
        return 0
      fi
      log_warn "sku=${sku_id} IN STOCK — deployed probe instance_id=${INSTANCE_ID}, will DELETE"
      printf 'in_stock'
      return 0
      ;;
    500)
      local msg
      msg="$(printf '%s' "${body}" | jq -r '.error.message // empty' 2>/dev/null)"
      if [[ "${msg}" == *"no longer available"* ]]; then
        printf 'out_of_stock'
        return 0
      fi
      log_warn "sku=${sku_id} HTTP 500 (other): ${msg:-no error message}"
      printf 'error'
      return 0
      ;;
    *)
      log_warn "sku=${sku_id} unexpected HTTP ${http_code}: $(printf '%s' "${body}" | head -c 200)"
      printf 'error'
      return 0
      ;;
  esac
}

cleanup_instance() {
  local instance_id="$1"
  local key="$2"
  local http_code
  http_code=$(curl -sS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    -X DELETE \
    -H "Authorization: Bearer ${key}" \
    -o /dev/null -w "%{http_code}" \
    "${RUNCRATE_API_BASE}/instances/${instance_id}" 2>/dev/null) || {
    log_error "instance=${instance_id} DELETE curl failed — instance may be running"
    return 1
  }
  if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
    log_info "instance=${instance_id} DELETE ok (HTTP ${http_code})"
    return 0
  fi
  log_error "instance=${instance_id} DELETE returned HTTP ${http_code} — VERIFY MANUALLY"
  return 1
}

# ============================================================
# State + alerting
# ============================================================
load_state() {
  if [[ -s "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}"
  else
    printf '{}'
  fi
}

save_state() {
  local state_json="$1"
  printf '%s\n' "${state_json}" > "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

# Append a jsonl record on every OUT→IN transition. Idempotent: we only call
# this when status actually flipped.
record_alert() {
  local sku_id="$1"
  local purpose="$2"
  local cleanup_status="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg ts "${ts}" \
    --arg sku "${sku_id}" \
    --arg purpose "${purpose}" \
    --arg cleanup "${cleanup_status}" \
    '{ts: $ts, event: "stock_in", sku: $sku, purpose: $purpose, probe_cleanup: $cleanup}' \
    >> "${ALERT_LOG}"
}

# ============================================================
# Main
# ============================================================
main() {
  ensure_dirs

  # Cron lockfile: skip if a previous run is still going.
  exec 9>"${LOCK_FILE}" 2>/dev/null || {
    log_error "Cannot open lockfile ${LOCK_FILE}; aborting"
    exit 0
  }
  if ! flock -n 9; then
    log_warn "Another rental-stock-watch instance is running; skipping"
    exit 0
  fi

  local key ssh_key_id
  key="$(fetch_runcrate_key || printf '')"
  if [[ -z "${key}" ]]; then
    log_error "Could not fetch Runcrate API key from SSM ${RUNCRATE_KEY_SSM}; aborting (RUNCRATE_API_KEY env override also empty)"
    exit 0
  fi

  ssh_key_id="$(fetch_ssh_key_id "${key}" || printf '')"
  if [[ -z "${ssh_key_id}" ]]; then
    log_error "Could not resolve gpu-rental ssh_key_id from /v1/ssh-keys; aborting"
    exit 0
  fi

  log_info "Starting poll: ${#WATCH_SKUS[@]} SKUs, ssh_key_id=${ssh_key_id}"

  local state new_state sku_id purpose old_status new_status entry
  state="$(load_state)"
  new_state="${state}"

  for entry in "${WATCH_SKUS[@]}"; do
    sku_id="${entry%%:*}"
    purpose="${entry#*:}"

    old_status="$(printf '%s' "${state}" | jq -r --arg k "${sku_id}" '.[$k] // "unknown"' 2>/dev/null)"
    new_status="$(probe_sku "${sku_id}" "${key}" "${ssh_key_id}")"

    local cleanup_status=""
    if [[ "${new_status}" == "in_stock" && -n "${INSTANCE_ID}" ]]; then
      if cleanup_instance "${INSTANCE_ID}" "${key}"; then
        cleanup_status="deleted"
      else
        cleanup_status="DELETE_FAILED"
      fi

      # Only alert on transition (or first-ever observation).
      if [[ "${old_status}" != "in_stock" ]]; then
        record_alert "${sku_id}" "${purpose}" "${cleanup_status}"
        log_warn "ALERT: sku=${sku_id} OUT→IN transition (purpose: ${purpose}); cleanup=${cleanup_status}"
      else
        log_info "sku=${sku_id} still in_stock; cleanup=${cleanup_status}"
      fi
    elif [[ "${new_status}" == "out_of_stock" ]]; then
      if [[ "${old_status}" == "in_stock" ]]; then
        log_info "sku=${sku_id} IN→OUT transition (back to out_of_stock)"
      fi
    fi

    # Persist the latest observed status (skip error states so a transient
    # API hiccup doesn't clobber a known-good prior reading).
    if [[ "${new_status}" != "error" ]]; then
      new_state="$(printf '%s' "${new_state}" | jq --arg k "${sku_id}" --arg v "${new_status}" '.[$k] = $v' 2>/dev/null)"
    fi

    log_info "sku=${sku_id} status=${new_status} (was: ${old_status})"
  done

  save_state "${new_state}"
  log_info "Poll complete"
}

main "$@"
