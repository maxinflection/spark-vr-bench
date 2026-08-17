#!/usr/bin/env bash
# spend-watchdog.sh — Bedrock cost-delta watchdog helper
#
# Queries AWS Cost Explorer for the current month's Bedrock spend and checks
# whether the delta since this run's start exceeds the configured cap.
# Called periodically by run-pool-a-cybergym.sh's watchdog loop.
#
# Usage: spend-watchdog.sh [OPTIONS]
#
# Options:
#   --cap-usd FLOAT       Hard spend cap in USD (REQUIRED; abort if delta exceeds this)
#   --baseline-usd FLOAT  Spend value at runner start (default 0; bedrock-ce mode only)
#   --campaign NAME        Campaign identifier for logging (default: unknown)
#   --target TARGET        Target for logging (default: unknown)
#   --mode MODE            'bedrock-ce' (default, Bedrock targets) or 'rental-hours'
#                          (vllm targets — wallclock × $/hr).
#   --rental-start-ts EPOCH  Unix-epoch seconds when the rental started.
#                            REQUIRED when --mode=rental-hours.
#   --rental-rate-usd-per-hour FLOAT  Hourly rate of the rental.
#                            REQUIRED when --mode=rental-hours. Can be passed
#                            multiple times paired with --rental-start-ts to
#                            sum across concurrent rentals.
#   --debug               Enable set -x and verbose logging
#   -h, --help            Show this help message
#
# Exit codes:
#   0  — spend is within cap (caller should continue)
#   2  — spend cap exceeded (caller should abort the run)
#   1  — internal error (CE API unavailable or parse failure) — CONSERVATIVE: caller should continue
#
# CONSERVATIVE policy: if Cost Explorer is unavailable or returns malformed data,
# this script exits 1 (not 2) so callers do NOT abort on monitoring infrastructure
# failure. Only a clean cap-exceeded detection triggers exit 2.
#
# CE propagation delay: Cost Explorer data lags ~4-8 hours. Early in a run,
# the delta will appear $0. This is expected and not treated as an error.
#
# Design reference: docs/research/ec2-harness-design.md
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RUNNER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly RUNNER_SCRIPT_DIR
RUNNER_NAME="spend-watchdog"
export RUNNER_NAME

# shellcheck source=scripts/runners/_lib.sh
source "${RUNNER_SCRIPT_DIR}/_lib.sh"

# ============================================================
# Defaults
# ============================================================
CAP_USD=""
BASELINE_USD="0"
CAMPAIGN="${CAMPAIGN:-unknown}"
TARGET="${TARGET:-unknown}"
MODE="bedrock-ce"
declare -a RENTAL_START_TS=()
declare -a RENTAL_RATE_USD=()

# ============================================================
# No ERR trap here: CE query failures must NOT propagate as fatal errors.
# The watchdog's conservative policy is to exit 1 (not 2) on any monitoring
# infrastructure failure so the caller continues the run.
# We handle errors explicitly via || patterns below.
# ============================================================

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
      --cap-usd)      CAP_USD="$2";      shift 2 ;;
      --baseline-usd) BASELINE_USD="$2"; shift 2 ;;
      --campaign)     CAMPAIGN="$2";     shift 2 ;;
      --target)       TARGET="$2";       shift 2 ;;
      --mode)         MODE="$2";         shift 2 ;;
      --rental-start-ts)         RENTAL_START_TS+=("$2"); shift 2 ;;
      --rental-rate-usd-per-hour) RENTAL_RATE_USD+=("$2"); shift 2 ;;
      --debug)        LOG_LEVEL="debug"; set -x; shift ;;
      -h|--help)      usage ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done
}

# ============================================================
# Validate numeric float
# Returns 0 if value looks like a non-negative float, 1 otherwise
# ============================================================
is_float() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# ============================================================
# Fetch current month Bedrock spend from Cost Explorer
# Prints a float (dollars) to stdout.
# Returns 0 on success, 1 on any CE failure.
#
# CE has ~4-8hr propagation delay; a $0 result early in a run is normal.
# ============================================================
# ============================================================
# rental-hours mode (<CAMPAIGN>): sum (now - rental_start_ts) × rate_usd_per_hour
# across all configured rentals. No external API call — purely wallclock.
# Caller sets baseline-usd to 0 (or omits it) so cap is checked directly
# against accumulated rental burn.
# ============================================================
fetch_rental_hours_spend() {
  local n_rentals=${#RENTAL_START_TS[@]}
  if (( n_rentals == 0 )); then
    log_warn "spend-watchdog: --mode=rental-hours but no --rental-start-ts pairs; returning 0"
    printf '0'
    return 0
  fi
  if (( ${#RENTAL_RATE_USD[@]} != n_rentals )); then
    log_error "spend-watchdog: --rental-start-ts count (${n_rentals}) != --rental-rate-usd-per-hour count (${#RENTAL_RATE_USD[@]})"
    return 1
  fi
  local now_epoch
  now_epoch="$(date +%s)"
  local total i start rate elapsed_s usd
  total="0"
  for (( i = 0; i < n_rentals; i++ )); do
    start="${RENTAL_START_TS[i]}"
    rate="${RENTAL_RATE_USD[i]}"
    if ! [[ "${start}" =~ ^[0-9]+$ ]]; then
      log_warn "spend-watchdog: rental[${i}] start_ts '${start}' is not an integer epoch; skipping"
      continue
    fi
    if ! is_float "${rate}"; then
      log_warn "spend-watchdog: rental[${i}] rate '${rate}' is not numeric; skipping"
      continue
    fi
    elapsed_s=$(( now_epoch - start ))
    if (( elapsed_s < 0 )); then
      elapsed_s=0
    fi
    # usd = elapsed_s / 3600 × rate ; awk for float math
    usd="$(awk -v s="${elapsed_s}" -v r="${rate}" 'BEGIN{printf "%.4f", (s/3600.0)*r}')"
    total="$(awk -v a="${total}" -v b="${usd}" 'BEGIN{printf "%.4f", a+b}')"
    log_debug "spend-watchdog: rental[${i}] start=${start} elapsed=${elapsed_s}s rate=${rate}/hr usd=${usd}"
  done
  printf '%s' "${total}"
}

fetch_bedrock_spend() {
  # shellcheck disable=SC2034  # ce_json/current_spend used in the non-stub impl block below
  local start_date end_date ce_json current_spend

  # First day of current month
  start_date="$(date -u +%Y-%m-01)"
  # Tomorrow (CE end date is exclusive)
  end_date="$(date -u -d '+1 day' +%Y-%m-%d 2>/dev/null \
    || date -u -v+1d +%Y-%m-%d 2>/dev/null)" || {
    log_warn "spend-watchdog: could not compute end_date; using start+32d fallback"
    # Fallback: add 32 days to start and truncate to YYYY-MM-01 of next month
    end_date="$(date -u +%Y-%m-%d)"
  }

  log_debug "spend-watchdog: querying CE start=${start_date} end=${end_date}"

  # TODO(<CAMPAIGN>-followup): validate the CE filter syntax for Bedrock specifically.
  # AWS CE service code for Bedrock is "AmazonBedrock" — confirm in Cost Explorer
  # console before relying on this. The Dimension filter below is the standard
  # approach but CE service codes are not always obvious.
  #
  # Note: the harness-driver-role does NOT have ce:GetCostAndUsage in its inline
  # policy (only ssm, s3, bedrock, kms, ssmmessages, ec2). The watchdog must
  # either: (a) be run from the sandbox (which may have billing permissions), or
  # (b) require harness-driver-role to have ce:GetCostAndUsage added.
  # TODO(<CAMPAIGN>-followup): decide which account/role runs spend-watchdog and add
  # ce:GetCostAndUsage to the appropriate policy if running from harness EC2.
  #
  # Expected command shape:
  #   aws ce get-cost-and-usage \
  #     --region us-east-1 \
  #     --time-period Start="${start_date}",End="${end_date}" \
  #     --granularity MONTHLY \
  #     --metrics "UnblendedCost" \
  #     --filter '{"Dimensions":{"Key":"SERVICE","Values":["AmazonBedrock"]}}' \
  #     --output json
  #
  # For now, stub with a safe $0 return so the caller continues.
  log_warn "spend-watchdog: AWS CE get-cost-and-usage not yet wired (see TODO above); returning 0"
  printf '0'
  return 0

  # IMPLEMENTATION STUB — replace the above printf/return with the block below
  # once CE permissions are confirmed:
  #
  # ce_json="$(aws ce get-cost-and-usage \
  #   --region "${LIB_REGION}" \
  #   --time-period "Start=${start_date},End=${end_date}" \
  #   --granularity MONTHLY \
  #   --metrics "UnblendedCost" \
  #   --filter '{"Dimensions":{"Key":"SERVICE","Values":["AmazonBedrock"]}}' \
  #   --output json 2>&1)" || {
  #   log_warn "spend-watchdog: CE query failed (propagation delay or IAM gap) — returning 0 (conservative)"
  #   printf '0'
  #   return 0
  # }
  #
  # current_spend="$(printf '%s' "${ce_json}" | jq -r \
  #   '.ResultsByTime[0].Total.UnblendedCost.Amount // "0"' 2>/dev/null)" || current_spend="0"
  #
  # if ! is_float "${current_spend}"; then
  #   log_warn "spend-watchdog: CE returned non-numeric amount '${current_spend}' — returning 0 (conservative)"
  #   printf '0'
  #   return 0
  # fi
  #
  # printf '%s' "${current_spend}"
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"

  if [[ -z "${CAP_USD}" ]]; then
    log_error "spend-watchdog: --cap-usd is required"
    exit 1
  fi

  if ! is_float "${CAP_USD}"; then
    log_error "spend-watchdog: --cap-usd must be a non-negative number, got '${CAP_USD}'"
    exit 1
  fi

  if ! is_float "${BASELINE_USD}"; then
    log_warn "spend-watchdog: --baseline-usd '${BASELINE_USD}' is not a valid float; defaulting to 0"
    BASELINE_USD="0"
  fi

  # Fetch current spend — if this fails, exit 1 (conservative: caller continues)
  local current_usd
  case "${MODE}" in
    bedrock-ce)
      current_usd="$(fetch_bedrock_spend)" || {
        log_warn "spend-watchdog: fetch_bedrock_spend failed — conservative exit 1 (caller should continue)"
        exit 1
      }
      ;;
    rental-hours)
      current_usd="$(fetch_rental_hours_spend)" || {
        log_warn "spend-watchdog: fetch_rental_hours_spend failed — conservative exit 1 (caller should continue)"
        exit 1
      }
      ;;
    *)
      log_error "spend-watchdog: unknown --mode '${MODE}'; valid: bedrock-ce, rental-hours"
      exit 1
      ;;
  esac

  # delta = current - baseline (use awk for float arithmetic — bash can't do floats)
  local delta_usd
  delta_usd="$(awk -v curr="${current_usd}" -v base="${BASELINE_USD}" \
    'BEGIN { d = curr - base; if (d < 0) d = 0; printf "%.4f", d }')"

  local source_label
  case "${MODE}" in
    bedrock-ce)    source_label="bedrock_spend_usd" ;;
    rental-hours)  source_label="rental_hours_usd" ;;
    *)             source_label="spend_usd" ;;
  esac
  log_info "spend-watchdog: mode=${MODE} ${source_label}=${current_usd} baseline_usd=${BASELINE_USD} delta_usd=${delta_usd} cap_usd=${CAP_USD}"

  # Compare delta to cap (awk returns 1 if delta >= cap, 0 otherwise)
  local exceeded
  exceeded="$(awk -v delta="${delta_usd}" -v cap="${CAP_USD}" \
    'BEGIN { print (delta >= cap) ? "1" : "0" }')"

  if [[ "${exceeded}" == "1" ]]; then
    log_warn "spend-watchdog: SPEND CAP EXCEEDED delta_usd=${delta_usd} cap_usd=${CAP_USD}"
    log_warn "spend-watchdog: signaling caller to abort via exit 2"
    exit 2
  fi

  log_info "spend-watchdog: within cap delta_usd=${delta_usd} cap_usd=${CAP_USD} — continue"
  exit 0
}

main "$@"
