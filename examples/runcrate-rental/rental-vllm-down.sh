#!/usr/bin/env bash
# rental-vllm-down.sh — Tear down vLLM serving on a rented GPU box and clean
# up the harness-side SSH tunnel + state file. Sibling to rental-vllm-up.sh.
#
# Usage:
#   /opt/benchmarks/scripts/rental-vllm-down.sh <rental-host>
#   /opt/benchmarks/scripts/rental-vllm-down.sh --spec <spec.yaml>
#
# What this does:
#   1. Resolve the rental host (positional arg or spec.yaml field)
#   2. Read the persisted state file at /var/lib/harness/rentals/<host>.json
#   3. Kill the SSH local-forward tunnel (by pid from state)
#   4. Kill the tmux session on the rental (vLLM stops, weights stay cached
#      on disk for the next launch)
#   5. Delete the state file
#
# What this does NOT do:
#   - Terminate or stop-bill the rental box itself (out of scope; operator
#     manages rentals via the Runcrate dashboard)
#   - Remove the vLLM venv on the rental (cached for the next launch)
#   - Remove HF model weights on the rental (cached for the next launch)
#
# Exit codes:
#   0  — clean teardown, OR state file already absent (idempotent)
#   1  — fatal error (e.g. SSH unreachable but state still listed it as alive)
#
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RV_RUNNER_NAME="rental-vllm-down"
export RV_RUNNER_NAME
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

# shellcheck source=scripts/_rental-vllm-lib.sh
source "${SCRIPT_DIR}/_rental-vllm-lib.sh"

# ============================================================
# Args
# ============================================================
RENTAL_HOST=""
SPEC_PATH=""

usage() {
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^!'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec) SPEC_PATH="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) rv_log_error "Unknown option: $1"; exit 1 ;;
      *)
        if [[ -n "${RENTAL_HOST}" ]]; then
          rv_log_error "Multiple positional args"
          exit 1
        fi
        RENTAL_HOST="$1"; shift
        ;;
    esac
  done
  if [[ -n "${SPEC_PATH}" ]]; then
    if [[ ! -f "${SPEC_PATH}" ]]; then
      rv_log_error "Spec file not found: ${SPEC_PATH}"
      exit 1
    fi
    rv_load_spec "${SPEC_PATH}"
    RENTAL_HOST="${RV_SPEC_RENTAL_HOST}"
  fi
  if [[ -z "${RENTAL_HOST}" ]]; then
    rv_log_error "Missing rental-host (positional) or --spec <spec.yaml>"
    exit 1
  fi
  RV_RENTAL_HOST="${RENTAL_HOST}"
  export RV_RENTAL_HOST
}

main() {
  parse_args "$@"

  local state_file
  state_file="$(rv_state_path "${RENTAL_HOST}")"
  if [[ ! -f "${state_file}" ]]; then
    rv_log_info "No state file at ${state_file}; nothing to tear down (already torn or never up)"
    exit 0
  fi

  # Read the bits we need.
  local tmux_session ssh_tunnel_pid rental_user
  tmux_session="$(jq -r '.tmux_session // empty' < "${state_file}")"
  ssh_tunnel_pid="$(jq -r '.ssh_tunnel_pid // empty' < "${state_file}")"
  rental_user="$(jq -r '.rental_user // "root"' < "${state_file}")"

  # Kill SSH tunnel on harness. Best-effort — process may have died, in which
  # case the kill returns nonzero and we just log.
  if [[ -n "${ssh_tunnel_pid}" ]] && kill -0 "${ssh_tunnel_pid}" 2>/dev/null; then
    rv_log_info "Killing SSH tunnel pid=${ssh_tunnel_pid}"
    kill "${ssh_tunnel_pid}" || rv_log_warn "Failed to kill SSH tunnel pid=${ssh_tunnel_pid}"
  else
    rv_log_info "No active SSH tunnel for pid=${ssh_tunnel_pid:-<empty>} (already exited)"
  fi

  # Kill tmux session on rental. Best-effort — if rental is unreachable, log
  # and continue cleaning up local state. The vLLM process will keep running
  # on the rental until the box is rebooted/terminated by the operator; that's
  # acceptable since the operator is the only one paying the rental hours.
  rv_log_info "Killing tmux session ${tmux_session} on ${rental_user}@${RENTAL_HOST}"
  if ! rv_ssh_run "${rental_user}" "${RENTAL_HOST}" \
        "tmux kill-session -t ${tmux_session}" 2>/dev/null; then
    rv_log_warn "Could not kill tmux session on rental (rental unreachable, or session already gone)"
  fi

  # Remove state file.
  rm -f "${state_file}"
  rv_log_info "Teardown complete; state file removed"
}

main "$@"
