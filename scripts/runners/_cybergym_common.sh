#!/usr/bin/env bash
# _cybergym_common.sh — shared CyberGym constants + helpers for the Pool A
# harness, split out by bd benchmarks-b51 when run_cybergym_task was extracted
# into the hermetic per-task entrypoint run-one-cybergym-task.sh.
#
# Sourced (after _lib.sh) by BOTH:
#   - run-pool-a-cybergym.sh        (the dispatcher: preflight + pre-pull + loop)
#   - run-one-cybergym-task.sh      (the hermetic per-task entrypoint)
#
# Holds ONLY what both need: the install-path constants (so the runtime-image
# tag etc. can never drift between the dispatcher's pre-pull and the task's
# per-task check) and write_progress (the dispatcher emits a failure heartbeat;
# the task emits running/pass/fail). Task-execution constants + the per-task
# functions (build_openhands_argv, verdict extraction, hermetic server, reaping)
# live in run-one-cybergym-task.sh — the dispatcher no longer needs them.
#
# This file defines functions + readonly constants only; it has no side effects
# and runs no top-level work, so double-sourcing is harmless.

# ============================================================
# Install-path constants (shared dispatcher <-> task)
# ============================================================
# These readonly constants are consumed by the SOURCING scripts (run-pool-a-cybergym.sh
# preflight/pre-pull + run-one-cybergym-task.sh), not all within this file — hence the
# SC2034 disable.
# CyberGym repo + its editable-install venv interpreter (install-harness.sh
# uv-pip-installs cybergym there; system python3 lacks the module).
readonly CYBERGYM_REPO="${CYBERGYM_REPO:-/opt/harnesses/cybergym}"
# shellcheck disable=SC2034
readonly CYBERGYM_PYTHON="${CYBERGYM_PYTHON:-${CYBERGYM_REPO}/.venv/bin/python}"

# CyberGym binary dataset root (large; lives on the sized /data EBS per bd <ISSUE>).
# shellcheck disable=SC2034
readonly CYBERGYM_DATA_DIR="${CYBERGYM_DATA_DIR:-/data/cybergym/cybergym_data/data}"

# OpenHands agent runner entry point (relative to CYBERGYM_REPO). The cybench
# example agent has no --base_url flag, so we use OpenHands which accepts it
# (bd cybergym-openhands-agent-cli-2026-05-11).
# shellcheck disable=SC2034
readonly CYBERGYM_AGENT_RUNNER="${CYBERGYM_REPO}/examples/agents/openhands/run.py"

# OpenHands sandbox runtime image — pre-pulled once by the dispatcher (shared
# across tasks), checked per-task by the entrypoint. Tag MUST match the installed
# OpenHands app version (0.33.0) — a mismatch causes immediate container exit
# after handshake (0 LLM calls, 0/N pass). See bd <ISSUE> Stage 1.
# shellcheck disable=SC2034
readonly CYBERGYM_OPENHANDS_RUNTIME_IMAGE="${CYBERGYM_OPENHANDS_RUNTIME_IMAGE:-ghcr.io/all-hands-ai/runtime:0.33-nikolaik}"

# ============================================================
# Progress reporter — one-line heartbeat (local log + best-effort S3 object)
# Usage: write_progress <task_index> <task_id> <status>
#
# Reads CYBERGYM_N_TOTAL (the column's task count) — the dispatcher sets it to
# ${#CYBERGYM_TASKS[@]}; the per-task entrypoint sets it from --n-total. On an
# on-prem/offline harness (no aws CLI) the S3 object write is skipped cleanly
# and the local log_info is the source of truth.
#
# bd b51 Phase 2 (§7): the S3 object key is per-task + sub-second unique
# (cybergym-<target>-<task_id>-<ts>-<nanos>.log). Under the bounded worker pool N
# tasks heartbeat concurrently; the old 1 s-granularity key (cybergym-<target>-<ts>)
# would collide and overwrite when two tasks reported in the same second.
# ============================================================
write_progress() {
  local task_index="$1"
  local task_id="$2"
  local status="$3"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local line
  line="$(printf '[%s] runner=%s campaign=%s target=%s task=%s (%d/%d) status=%s\n' \
    "${ts}" "${RUNNER_NAME}" "${CAMPAIGN}" "${TARGET}" \
    "${task_id}" "${task_index}" "${CYBERGYM_N_TOTAL:-0}" "${status}")"

  # S3 heartbeat — skip entirely on an on-prem/offline harness with no aws CLI
  # (otherwise this retries 'aws' twice per progress write -> exit-127 noise).
  if command -v aws &>/dev/null; then
    # Per-task + sub-second-unique object key so concurrent pool tasks never
    # overwrite each other's heartbeat (cybergym task ids embed a ':' — sanitize).
    local task_id_key="${task_id//:/_}"
    local ts_compact nanos
    ts_compact="$(date -u +%Y%m%dT%H%M%SZ)"
    nanos="$(date -u +%N)"
    [[ "${nanos}" =~ ^[0-9]+$ ]] || nanos="${RANDOM}${RANDOM}"
    local progress_key="s3://${LIB_S3_BUCKET}/${CAMPAIGN}/_progress/cybergym-${TARGET}-${task_id_key}-${ts_compact}-${nanos}.log"
    printf '%s\n' "${line}" | \
      retry_cmd 2 aws s3 cp - \
        "${progress_key}" \
        --region "${LIB_REGION}" \
        --no-progress 2>/dev/null \
      || log_warn "Progress report upload failed (non-fatal)"
  fi

  log_info "Progress: ${line}"
}
