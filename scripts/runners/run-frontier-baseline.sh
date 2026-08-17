#!/usr/bin/env bash
# run-frontier-baseline.sh — Top-level orchestrator for frontier baseline runs
#
# Drives the full frontier baseline sequence:
#   1. Pool B (HumanEval+, BigCodeBench-Hard, IFEval) × opus47
#   2. Pool B × gpt55
#   3. Sanity gate: abort Pool A if Pool B results look broken
#   4. Pool A CyberGym 3-task × opus47
#   5. Pool A CyberGym 3-task × gpt55
#
# Designed to be the single invocation point for both <CAMPAIGN> and <CAMPAIGN>
# when running the complete frontier baseline campaign. Can also run a
# subset by passing --pools or --targets flags.
#
# Usage: run-frontier-baseline.sh --campaign NAME [OPTIONS]
#
# Options:
#   --campaign NAME       Campaign identifier (REQUIRED)
#   --pools pool-b|pool-a|all
#                         Which pool(s) to run (default: all)
#   --targets opus47|gpt55|all
#                         Which target(s) to run (default: all)
#   --spend-cap-usd FLOAT Total spend cap for Pool A runs (default: 300)
#   --force               Pass --force to sub-runners (overwrite existing results)
#   --skip-sanity-gate    Skip Pool B sanity check before Pool A (not recommended)
#   --debug               Enable set -x and verbose logging in this script and sub-runners
#   -h, --help            Show this help message
#
# Exit codes:
#   0  — all requested runs completed successfully
#   3  — Pool B sanity gate failed; Pool A was not started
#   2  — Pool A aborted due to spend cap
#   1  — one or more runners failed
#
# Pool B → Pool A gating:
#   Before starting Pool A, this script checks that Pool B results exist and
#   that pass_rate > 0 for at least one bench/target combo. A completely zero
#   pass rate suggests a wiring failure, not a model quality signal.
#   Override with --skip-sanity-gate if you need to run Pool A independently.
#
# Invocation from Proxmox sandbox (SSH-over-SSM, unattended):
#   ssh ubuntu@<instance-id> \
#     sudo /opt/benchmarks/scripts/runners/run-frontier-baseline.sh \
#       --campaign frontier-pool-b-2026-05
#
# Design reference: docs/research/ec2-harness-design.md, docs/harness-setup.md
# Issue: benchmarks-<CAMPAIGN> / benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RUNNER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly RUNNER_SCRIPT_DIR
RUNNER_NAME="run-frontier-baseline"
export RUNNER_NAME

# shellcheck source=scripts/runners/_lib.sh
source "${RUNNER_SCRIPT_DIR}/_lib.sh"

# ============================================================
# Defaults
# ============================================================
CAMPAIGN=""
POOLS="all"
TARGETS="all"
SPEND_CAP_USD="300"
FORCE="false"
SKIP_SANITY_GATE="false"

# Expansion of "all" values
readonly -a ALL_TARGETS=("opus47" "gpt55")
readonly -a ALL_POOLS=("pool-b" "pool-a")

# Pool B bench names for sanity gate check
readonly -a POOL_B_BENCHES=("humaneval-plus" "bigcodebench-hard" "ifeval")

# ============================================================
# ERR + EXIT traps
# ============================================================
trap 'lib_err_trap ${LINENO}' ERR
trap 'lib_exit_trap' EXIT

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
      --campaign)          CAMPAIGN="$2";        shift 2 ;;
      --pools)             POOLS="$2";           shift 2 ;;
      --targets)           TARGETS="$2";         shift 2 ;;
      --spend-cap-usd)     SPEND_CAP_USD="$2";   shift 2 ;;
      --force)             FORCE="true";         shift   ;;
      --skip-sanity-gate)  SKIP_SANITY_GATE="true"; shift ;;
      --debug)             LOG_LEVEL="debug"; set -x; shift ;;
      -h|--help)           usage ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done
}

# ============================================================
# Pre-flight
# ============================================================
preflight() {
  lib_preflight

  : "${CAMPAIGN:?--campaign is required}"

  if [[ ! "${CAMPAIGN}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Campaign name must be alphanumeric with hyphens/underscores: ${CAMPAIGN}"
    exit 1
  fi

  # Validate --pools
  case "${POOLS}" in
    all|pool-b|pool-a) ;;
    *)
      log_error "--pools must be one of: all, pool-b, pool-a. Got: ${POOLS}"
      exit 1
      ;;
  esac

  # Validate --targets
  case "${TARGETS}" in
    all|opus47|gpt55) ;;
    *)
      log_error "--targets must be one of: all, opus47, gpt55. Got: ${TARGETS}"
      exit 1
      ;;
  esac

  log_info "Frontier baseline preflight passed campaign=${CAMPAIGN} pools=${POOLS} targets=${TARGETS}"
}

# ============================================================
# Resolve target list from --targets flag
# Prints targets to stdout, one per line
# ============================================================
resolve_targets() {
  if [[ "${TARGETS}" == "all" ]]; then
    printf '%s\n' "${ALL_TARGETS[@]}"
  else
    printf '%s\n' "${TARGETS}"
  fi
}

# ============================================================
# Resolve pool list from --pools flag
# Prints pools to stdout, one per line
# ============================================================
resolve_pools() {
  if [[ "${POOLS}" == "all" ]]; then
    printf '%s\n' "${ALL_POOLS[@]}"
  else
    printf '%s\n' "${POOLS}"
  fi
}

# ============================================================
# Build sub-runner flags string
# ============================================================
sub_runner_flags() {
  local target="$1"
  local flags="--campaign ${CAMPAIGN} --target ${target}"
  [[ "${FORCE}" == "true" ]]       && flags="${flags} --force"
  [[ "${LOG_LEVEL}" == "debug" ]] && flags="${flags} --debug"
  printf '%s' "${flags}"
}

# ============================================================
# Pool B sanity gate
# Checks that at least one Pool B result file exists with pass_rate > 0
# across any target. A completely zero pass_rate on all targets/benches
# suggests a harness wiring failure before spending agentic Pool A hours.
# ============================================================
pool_b_sanity_gate() {
  if [[ "${SKIP_SANITY_GATE}" == "true" ]]; then
    log_warn "Sanity gate SKIPPED via --skip-sanity-gate (not recommended for production runs)"
    return 0
  fi

  log_info "Running Pool B sanity gate before Pool A"
  BENCH="sanity-gate"

  local any_nonzero=false
  local target bench result_file pass_rate

  while IFS= read -r target; do
    for bench in "${POOL_B_BENCHES[@]}"; do
      result_file="${LIB_RESULTS_BASE}/${CAMPAIGN}/${target}/${bench}/results.json"
      if [[ ! -f "${result_file}" ]]; then
        log_warn "Sanity gate: result file missing for target=${target} bench=${bench}"
        continue
      fi
      pass_rate="$(jq -r '.pass_rate // 0' "${result_file}" 2>/dev/null || printf '0')"
      log_info "Sanity gate: target=${target} bench=${bench} pass_rate=${pass_rate}"
      # Check if pass_rate > 0 using awk (bash can't compare floats)
      local is_nonzero
      is_nonzero="$(awk -v pr="${pass_rate}" 'BEGIN { print (pr > 0) ? "1" : "0" }')"
      if [[ "${is_nonzero}" == "1" ]]; then
        any_nonzero=true
      fi
    done
  done < <(resolve_targets)

  if [[ "${any_nonzero}" == "false" ]]; then
    log_error "Sanity gate FAILED: all Pool B pass_rate values are 0 across all targets and benches"
    log_error "This likely indicates a harness wiring failure, not a model quality signal"
    log_error "Check lm-evaluation-harness invocation. Use --skip-sanity-gate to override."
    return 1
  fi

  log_info "Sanity gate PASSED: at least one non-zero Pool B pass_rate found"
}

# ============================================================
# Run Pool B for all resolved targets
# ============================================================
run_pool_b_all() {
  log_info "Running Pool B for all resolved targets"
  local target pool_b_exit
  while IFS= read -r target; do
    log_info "Pool B: starting target=${target}"
    pool_b_exit=0
    # shellcheck disable=SC2046
    "${RUNNER_SCRIPT_DIR}/run-pool-b.sh" \
      $(sub_runner_flags "${target}") \
      || pool_b_exit=$?

    if (( pool_b_exit != 0 )); then
      log_error "Pool B FAILED for target=${target} (exit=${pool_b_exit})"
      # Continue to other targets even on failure — collect as much as possible
    else
      log_info "Pool B COMPLETE for target=${target}"
    fi
  done < <(resolve_targets)
}

# ============================================================
# Run Pool A (CyberGym) for all resolved targets
# ============================================================
run_pool_a_all() {
  log_info "Running Pool A (CyberGym) for all resolved targets"
  local target pool_a_exit
  while IFS= read -r target; do
    log_info "Pool A: starting target=${target}"
    pool_a_exit=0
    # shellcheck disable=SC2046
    "${RUNNER_SCRIPT_DIR}/run-pool-a-cybergym.sh" \
      $(sub_runner_flags "${target}") \
      --spend-cap-usd "${SPEND_CAP_USD}" \
      || pool_a_exit=$?

    case "${pool_a_exit}" in
      0) log_info "Pool A COMPLETE for target=${target}" ;;
      2)
        log_warn "Pool A ABORTED (spend cap) for target=${target} — stopping Pool A across all targets"
        return 2
        ;;
      *)
        log_error "Pool A FAILED for target=${target} (exit=${pool_a_exit})"
        # Continue to other targets
        ;;
    esac
  done < <(resolve_targets)
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  preflight

  log_info "Starting frontier baseline orchestrator campaign=${CAMPAIGN} pools=${POOLS} targets=${TARGETS}"

  local run_pool_b=false
  local run_pool_a=false
  while IFS= read -r pool; do
    [[ "${pool}" == "pool-b" ]] && run_pool_b=true
    [[ "${pool}" == "pool-a" ]] && run_pool_a=true
  done < <(resolve_pools)

  # Phase 1: Pool B
  if [[ "${run_pool_b}" == "true" ]]; then
    log_info "Phase 1: Pool B"
    run_pool_b_all
    log_info "Phase 1 complete"
  fi

  # Sanity gate between Pool B and Pool A
  if [[ "${run_pool_a}" == "true" ]]; then
    if [[ "${run_pool_b}" == "true" ]]; then
      pool_b_sanity_gate || {
        log_error "Aborting: Pool B sanity gate failed — Pool A will not run"
        exit 3
      }
    fi

    # Phase 2: Pool A
    log_info "Phase 2: Pool A (CyberGym)"
    local pool_a_rc=0
    run_pool_a_all || pool_a_rc=$?
    if (( pool_a_rc == 2 )); then
      log_warn "Pool A aborted due to spend cap — partial results synced to S3"
      exit 2
    fi
    log_info "Phase 2 complete"
  fi

  log_info "Frontier baseline orchestrator complete campaign=${CAMPAIGN}"
}

main "$@"
