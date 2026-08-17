#!/usr/bin/env bash
# rental-vllm-up.sh — Provision vLLM on a rented GPU box and expose it to the
# eval-harness EC2 via an SSH local-port-forward.
#
# Canonical invocation (on the eval-harness host):
#   /opt/benchmarks/scripts/rental-vllm-up.sh <model-spec.yaml>
#
# What this does (idempotent at every stage):
#   1. Load the spec, validate fields
#   2. SSH preflight to <rental_host>
#   3. Install uv if missing on rental
#   4. Create vLLM venv + uv pip install 'vllm>=<min_ver>' if missing
#   5. Generate a per-rental API key (or re-use existing from state file)
#   6. Launch `vllm serve` in a tmux session bound to 127.0.0.1:8000 with
#      logs to /var/log/vllm.log on the rental
#   7. Open an SSH local-port-forward from harness:<local_port>
#      to rental:127.0.0.1:8000
#   8. Poll /v1/models until vLLM reports the model as served (timeout
#      defaults to 25 min — first-launch torch.compile can take ~10 min)
#   9. Write state JSON to /var/lib/harness/rentals/<rental_host>.json
#   10. Print endpoint + API key on stdout
#
# Why an SSH tunnel rather than a public bind:
#   The Pool runner scripts reject http:// URLs except localhost (Bearer
#   tokens leak over plaintext). Public-https with nginx+TLS is <CAMPAIGN>'s
#   stage-4 — at that point this script's stage 7 swaps to "configure nginx"
#   and the consumer URL becomes https://<rental>/v1. Until then, SSH tunnel.
#
# Spec format — see scripts/rental-specs/*.yaml for examples. Required:
#   model_id      (HF repo id)
#   rental_host   (hostname or IP — operator provisioned via Runcrate runbook)
# Optional:
#   rental_user (default root), tensor_parallel_size (1), quant ("",
#   meaning no --quantization), max_model_len (""), vllm_args (list),
#   vllm_min_version ("0.20"), local_port (8000), hf_token_ssm
#   ("/sandbox/api-keys/hf-token", "" to disable).
#
# Output format on stdout (one JSON line):
#   {"endpoint":"http://127.0.0.1:8000/v1","api_key":"sk-rental-...",
#    "model_id":"...","rental_host":"..."}
#
# Exit codes:
#   0  — endpoint up and serving
#   1  — fatal error (preflight, install, launch, or readiness timeout)
#
# Issue: benchmarks-<CAMPAIGN>

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit

# ============================================================
# Bootstrap
# ============================================================
RV_RUNNER_NAME="rental-vllm-up"
export RV_RUNNER_NAME
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

# shellcheck source=scripts/_rental-vllm-lib.sh
source "${SCRIPT_DIR}/_rental-vllm-lib.sh"

# ============================================================
# Args
# ============================================================
SPEC_PATH=""
READY_TIMEOUT_SEC="${RV_DEFAULT_READY_TIMEOUT_SEC}"
FORCE_RESTART="false"

usage() {
  awk '/^# /{print; next} /^[^#]/{exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^!'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ready-timeout) READY_TIMEOUT_SEC="$2"; shift 2 ;;
      --force-restart) FORCE_RESTART="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) rv_log_error "Unknown option: $1"; exit 1 ;;
      *)
        if [[ -n "${SPEC_PATH}" ]]; then
          rv_log_error "Multiple positional args (already have ${SPEC_PATH}, got $1)"
          exit 1
        fi
        SPEC_PATH="$1"; shift
        ;;
    esac
  done
  if [[ -z "${SPEC_PATH}" ]]; then
    rv_log_error "Missing required <spec.yaml> argument. Run with --help for usage."
    exit 1
  fi
  if [[ ! -f "${SPEC_PATH}" ]]; then
    rv_log_error "Spec file not found: ${SPEC_PATH}"
    exit 1
  fi
}

# ============================================================
# Preflight — tools available on the harness side.
# ============================================================
preflight_harness() {
  local required=("ssh" "jq" "python3" "openssl" "curl" "sha256sum")
  for t in "${required[@]}"; do
    if ! command -v "${t}" &>/dev/null; then
      rv_log_error "Missing required tool on harness: ${t}"
      exit 1
    fi
  done
  if [[ ! -r "${RV_GPU_RENTAL_KEY}" ]]; then
    rv_log_error "gpu-rental SSH key not readable at ${RV_GPU_RENTAL_KEY}. cloud-init bootstrap step ssm-gpu-rental-key may have failed."
    exit 1
  fi
}

# ============================================================
# uv install — checks `command -v uv`; if missing, installs via curl|sh.
# ============================================================
remote_install_uv() {
  rv_log_info "Stage 3: ensure uv on rental"
  if rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
       'command -v uv' >/dev/null 2>&1; then
    rv_log_info "uv already present on rental"
    return 0
  fi
  rv_log_info "Installing uv on rental (curl | sh)"
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    'curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --quiet'
  # uv installs to ~/.local/bin which may not be on the noninteractive PATH.
  # Add a stable symlink so subsequent SSH sessions find it without sourcing
  # ~/.bashrc.
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    'ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv'
  rv_log_info "uv installed and symlinked to /usr/local/bin/uv"
}

# ============================================================
# nvcc install — required at runtime by vLLM's flashinfer JIT path
# (Qwen FP8 + similar quantizations). Runcrate's stock Ubuntu image
# ships CUDA runtime libs but no nvcc compiler. Without this, vLLM
# engine init fails after model load with:
#   RuntimeError: Could not find nvcc and default cuda_home='/usr/local/cuda' doesn't exist
# Gemma-NVFP4 doesn't hit this (CUTLASS path, no JIT); Qwen-FP8 does.
# ~600 MB install via apt; idempotent (checks `command -v nvcc` first).
# ============================================================
remote_install_nvcc() {
  rv_log_info "Stage 3.5: ensure nvcc on rental (vLLM flashinfer JIT requirement)"
  # We deliberately check the canonical install path (/usr/local/cuda/bin/nvcc)
  # rather than `command -v nvcc`, because we no longer symlink onto
  # /usr/local/bin (the symlink confuses nvcc's argv[0]-based profile
  # discovery — it ends up looking for cuda_runtime.h next to /usr/local/bin
  # rather than at the real install). launch_vllm prepends /usr/local/cuda/bin
  # to PATH instead, so FlashInfer subprocesses find the real binary.
  if rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
       'test -x /usr/local/cuda/bin/nvcc' >/dev/null 2>&1; then
    # bd <ISSUE> (2026-05-21): existence check alone is insufficient on Blackwell.
    # B300 rentals ship pre-installed NVCC 12.8 from the OS image vendor;
    # 12.8 lacks 'compute_103a' (B300 SM103 arch-accelerated). Symptoms:
    #   - FlashInfer fp4_quantization_103 JIT: 'nvcc fatal: Unsupported gpu
    #     architecture compute_103a'
    #   - DeepGEMM UE8M0 JIT silently emits an empty kernel dir, then
    #     'Corrupted JIT cache directory' on the next launch
    # DeepGEMM emits 'please use at least NVCC 12.9' as a 'warning'; on
    # SM103+ it is actually a hard correctness requirement.
    # Minimum version: 12.9. We upgrade to 12-9 specifically (proven path
    # from <CAMPAIGN> V4-Flash debugging); 13-0 also works but we haven't
    # validated it on B300 SM103 so stick with what worked.
    local existing_ver
    existing_ver=$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
      '/usr/local/cuda/bin/nvcc --version 2>/dev/null | grep -oP "release \K[0-9]+\.[0-9]+"' \
      2>/dev/null || echo "")
    if [[ -n "${existing_ver}" ]] && \
         printf '%s\n12.9\n' "${existing_ver}" | sort -V -C 2>/dev/null && \
         [[ "${existing_ver}" != "12.9" ]]; then
      rv_log_info "nvcc ${existing_ver} detected at /usr/local/cuda/bin/nvcc; upgrading to 12.9 (Blackwell SM103 needs ≥12.9)"
      rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
        'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-9 && \
         ln -sfn /usr/local/cuda-12.9 /usr/local/cuda'
      rv_log_info "nvcc upgraded: $(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" '/usr/local/cuda/bin/nvcc --version | head -1' 2>/dev/null || echo 'unknown')"
    else
      rv_log_info "nvcc ${existing_ver:-unknown} present at /usr/local/cuda/bin/nvcc; ≥12.9, OK"
    fi
    # Defensive: remove any stale /usr/local/bin/nvcc symlink left by older
    # versions of this script — it breaks FlashInfer JIT compiles.
    rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
      'if [[ -L /usr/local/bin/nvcc ]]; then rm -f /usr/local/bin/nvcc; fi'
    return 0
  fi
  rv_log_info "Installing cuda-toolkit-13-0 via apt (~3-5 GB; pulls nvcc + cuRAND + cuBLAS + cuDNN dev headers)"
  # We install the full toolkit metapackage rather than just cuda-nvcc-13-0
  # because FlashInfer's NVFP4 CUTLASS template (used by Gemma-4-NVFP4 and
  # other <CAMPAIGN>+ candidates) #includes <curand_kernel.h> from CUTLASS's
  # tensor_fill helpers — that's cuda-curand-dev. The FP8 path on <CAMPAIGN>
  # didn't need it, so the older 'cuda-nvcc-13-0 only' install passed
  # silently. Install everything once and stop chasing missing headers.
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-13-0 || \
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-nvcc-13-0 cuda-curand-dev-13-0 cuda-cudart-dev-13-0 || \
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-cuda-toolkit'
  rv_log_info "nvcc installed: $(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" '/usr/local/cuda/bin/nvcc --version | head -1' 2>/dev/null || echo 'unknown')"
}

# ============================================================
# Build toolchain install — required at runtime by FlashInfer's JIT path
# (which vLLM uses for batch_prefill_with_kv_cache and other quant kernels).
# The chain is nvcc -> g++ -> cc1plus, orchestrated by ninja. Despite its
# name, Runcrate's "ubuntu-cuda-devel" image ships only the CUDA runtime
# libs + a stub gcc — it lacks ninja, g++ (cc1plus), and the rest of
# build-essential. Each missing tool surfaces as a different fatal error
# late in vLLM startup AFTER model load + torch.compile:
#   - missing ninja: "FileNotFoundError: ... 'ninja'"
#   - missing cc1plus / g++: "gcc: fatal error: cannot execute 'cc1plus'"
# The nvcc install lives in remote_install_nvcc above; this step covers
# everything else needed to drive nvcc end-to-end. Idempotent.
# ============================================================
remote_install_build_tools() {
  rv_log_info "Stage 3.6: ensure ninja + g++ on rental (vLLM/FlashInfer JIT requirement)"
  local need_install="false"
  if ! rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
       'command -v ninja >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && \
        ls /usr/lib/gcc/x86_64-linux-gnu/*/cc1plus >/dev/null 2>&1' >/dev/null 2>&1; then
    need_install="true"
  fi
  if [[ "${need_install}" == "false" ]]; then
    rv_log_info "ninja + g++ + cc1plus already present on rental"
    return 0
  fi
  rv_log_info "Installing ninja-build + build-essential + g++-12 via apt"
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ninja-build build-essential g++-12'
  rv_log_info "build tools installed: ninja=$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" 'ninja --version' 2>/dev/null || echo 'unknown') g++=$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" 'g++ --version | head -1' 2>/dev/null || echo 'unknown')"
}

# ============================================================
# vLLM venv install — creates ${RV_RENTAL_VENV} if missing; ensures the
# installed vllm version is >= the requested minimum.
# ============================================================
remote_install_vllm() {
  rv_log_info "Stage 4: ensure vLLM venv at ${RV_RENTAL_VENV}"

  # Check whether venv exists and what version it has.
  local current_ver
  current_ver="$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "${RV_RENTAL_VENV}/bin/python -c 'import vllm; print(vllm.__version__)'" 2>/dev/null || true)"

  if [[ -n "${current_ver}" ]]; then
    rv_log_info "vLLM already installed: ${current_ver} (required: >=${RV_SPEC_VLLM_MIN_VER})"
    # Compare semver-ish. Use sort -V; if the lowest is the required version,
    # current is >= required.
    local lowest
    lowest="$(printf '%s\n%s\n' "${RV_SPEC_VLLM_MIN_VER}" "${current_ver}" | sort -V | head -n 1)"
    if [[ "${lowest}" == "${RV_SPEC_VLLM_MIN_VER}" ]]; then
      rv_log_info "vLLM ${current_ver} >= ${RV_SPEC_VLLM_MIN_VER}; reusing"
      return 0
    fi
    rv_log_warn "vLLM ${current_ver} < ${RV_SPEC_VLLM_MIN_VER}; upgrading"
  else
    rv_log_info "vLLM venv missing or unreadable; creating fresh venv"
  fi

  # Create + install. uv venv handles "exists" gracefully.
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "uv venv ${RV_RENTAL_VENV}"
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "VIRTUAL_ENV=${RV_RENTAL_VENV} uv pip install --quiet 'vllm>=${RV_SPEC_VLLM_MIN_VER}'"

  current_ver="$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "${RV_RENTAL_VENV}/bin/python -c 'import vllm; print(vllm.__version__)'" 2>/dev/null)"
  rv_log_info "vLLM installed on rental: ${current_ver}"
}

# ============================================================
# API key generation. If the state file already has a key for this rental,
# reuse it; otherwise mint a 32-byte URL-safe random.
# ============================================================
ensure_api_key() {
  local existing
  if existing="$(rv_state_read "${RV_SPEC_RENTAL_HOST}" '.api_key' 2>/dev/null)" && \
     [[ -n "${existing}" ]]; then
    API_KEY="${existing}"
    rv_log_info "Reusing existing API key from state file (rental=${RV_SPEC_RENTAL_HOST})"
    return 0
  fi
  # 24 random bytes -> 32-char base64url. Prefix sk-rental for visual ID.
  API_KEY="sk-rental-$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')"
  rv_log_info "Minted fresh API key (rental=${RV_SPEC_RENTAL_HOST})"
}

# ============================================================
# vLLM serve launch. Idempotent: checks for a running tmux session and an
# alive `vllm serve` process; restarts only if --force-restart or args
# diverge from the persisted state.
# ============================================================
TMUX_SESSION=""
launch_vllm() {
  rv_log_info "Stage 6: launch vLLM (model=${RV_SPEC_MODEL_ID})"
  TMUX_SESSION="vllm-$(rv_short_hash "${RV_SPEC_MODEL_ID}-${RV_SPEC_RENTAL_HOST}")"

  # Idempotency check: tmux session exists AND vllm process is running AND
  # /v1/models on rental:8000 returns 200. If yes (and not --force-restart),
  # skip relaunch.
  if [[ "${FORCE_RESTART}" != "true" ]]; then
    if vllm_is_serving_remote; then
      rv_log_info "vLLM already serving on rental — skipping launch (use --force-restart to override)"
      return 0
    fi
    rv_log_info "vLLM not currently serving; launching fresh"
  else
    rv_log_warn "--force-restart: killing existing tmux session and relaunching"
    # Kill the prior harness-side SSH tunnel before relaunching (bd <CAMPAIGN>).
    # Without this, the tunnel from the previous up.sh run leaks when
    # local_port changes between runs; even when local_port is unchanged,
    # the same-port-reuse path at open_tunnel() means the leak is invisible
    # until rental-vllm-down.sh (which only reads the post-restart state
    # file) — at which point the prior tunnel survives the rental DELETE.
    local prev_tunnel_pid
    prev_tunnel_pid="$(rv_state_read "${RV_SPEC_RENTAL_HOST}" '.ssh_tunnel_pid' 2>/dev/null || true)"
    if [[ -n "${prev_tunnel_pid}" ]] && kill -0 "${prev_tunnel_pid}" 2>/dev/null; then
      rv_log_info "Killing previous SSH tunnel pid=${prev_tunnel_pid} before relaunch"
      kill "${prev_tunnel_pid}" 2>/dev/null || true
    fi
    rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
      "tmux kill-session -t ${TMUX_SESSION}" 2>/dev/null || true
  fi

  # HF token: best-effort fetch from harness SSM (already-validated path), then
  # injected via env to the tmux session. Empty string if disabled.
  local hf_token=""
  if [[ -n "${RV_SPEC_HF_TOKEN_SSM}" ]]; then
    if hf_token="$(aws ssm get-parameter \
        --region "${RV_AWS_REGION}" \
        --name "${RV_SPEC_HF_TOKEN_SSM}" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null)"; then
      rv_log_info "HF_TOKEN fetched from SSM ${RV_SPEC_HF_TOKEN_SSM}"
    else
      rv_log_warn "HF_TOKEN fetch from ${RV_SPEC_HF_TOKEN_SSM} failed; vLLM will run without HF auth"
      hf_token=""
    fi
  fi

  # Build per-spec env-export block from RV_SPEC_VLLM_ENV_JSON. Each entry
  # becomes a printf-%q-safe `export KEY=VALUE` line spliced into the launch
  # heredoc before `vllm serve`. Used for env-only knobs that have no CLI
  # flag — e.g. VLLM_USE_FLASHINFER_MOE_FP8=0 (vllm#34892 MoE accuracy bug)
  # on <CAMPAIGN>, VLLM_USE_FLASHINFER_MOE_FP4 + VLLM_FLASHINFER_MOE_BACKEND on
  # the FP4 MoE specs.
  local vllm_env_block=""
  if [[ "$(printf '%s' "${RV_SPEC_VLLM_ENV_JSON}" | jq 'length')" -gt 0 ]]; then
    while IFS=$'\t' read -r k v; do
      [[ -z "${k}" ]] && continue
      vllm_env_block+="export $(printf '%q' "${k}")=$(printf '%q' "${v}")"$'\n'
    done < <(printf '%s' "${RV_SPEC_VLLM_ENV_JSON}" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
    rv_log_info "Spec vllm_env will export: $(printf '%s' "${RV_SPEC_VLLM_ENV_JSON}" | jq -r 'keys | join(",")')"
  fi

  # Build the vllm-serve command. Quote-safe assembly via jq + bash array.
  local -a serve_args
  serve_args=("${RV_RENTAL_VENV}/bin/vllm" "serve" "${RV_SPEC_MODEL_ID}"
              "--host" "127.0.0.1"
              "--port" "${RV_RENTAL_VLLM_PORT}"
              "--api-key" "${API_KEY}"
              "--tensor-parallel-size" "${RV_SPEC_TP_SIZE}")
  [[ -n "${RV_SPEC_QUANT}" ]] && serve_args+=("--quantization" "${RV_SPEC_QUANT}")
  [[ -n "${RV_SPEC_MAX_MODEL_LEN}" ]] && serve_args+=("--max-model-len" "${RV_SPEC_MAX_MODEL_LEN}")

  # Append spec-supplied extra args. jq -r '.[]' yields one per line.
  while IFS= read -r extra; do
    [[ -n "${extra}" ]] && serve_args+=("${extra}")
  done < <(printf '%s' "${RV_SPEC_VLLM_ARGS_JSON}" | jq -r '.[]')

  # Render the argv as a printf-format-safe quoted string for the remote shell.
  local serve_cmdline
  serve_cmdline="$(printf ' %q' "${serve_args[@]}")"
  serve_cmdline="${serve_cmdline# }"  # drop leading space

  # Heredoc to the rental: prepares the env, opens the log, exec's vLLM.
  # Note we redirect stdout/stderr to RV_RENTAL_VLLM_LOG so tmux capture-pane
  # is not the only retrieval path — operators can `ssh ... tail -f /var/log/vllm.log`.
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" "bash -s" <<EOF
set -Eeuo pipefail

# Make sure tmux is present (Runcrate Ubuntu image typically ships it; install
# from apt as a safety net on first launch).
if ! command -v tmux >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux
fi

# Truncate prior log (operator can recover via 'journalctl' or saved tmux
# session output if needed; fresh launches start with a clean log).
: > ${RV_RENTAL_VLLM_LOG}
chmod 0644 ${RV_RENTAL_VLLM_LOG}

# Compose env so HF_TOKEN propagates to vLLM if set.
export HF_TOKEN='${hf_token}'
export HUGGING_FACE_HUB_TOKEN='${hf_token}'

# Spec-supplied vllm_env exports (zero or more lines, each printf-%q-encoded).
${vllm_env_block}
# Prepend /usr/local/cuda/bin to PATH so FlashInfer's JIT path invokes nvcc
# at its real install location (rather than via the /usr/local/bin/nvcc
# symlink). nvcc's profile-discovery uses argv[0]'s directory; via the
# symlink it resolves _HERE_=/usr/local/bin and can't find its toolchain
# (cuda_runtime.h, nvvm, etc.), failing with "fatal error: cuda_runtime.h:
# No such file or directory" deep in the FlashInfer compile. With cuda/bin
# first, nvcc resolves _HERE_=/usr/local/cuda-13.0/bin and finds includes.
export PATH=/usr/local/cuda/bin:\${PATH}
export CUDA_HOME=/usr/local/cuda

# tmux new-session -d  is idempotent-after-kill; the calling code handled
# --force-restart by sending kill-session above.
#
# 2026-05-11 (bd <ISSUE>): write serve_cmdline to a script file via a
# *quoted* nested heredoc, then exec the file. The previous form embedded
# \${serve_cmdline} inside double quotes for tmux, which forced the string
# through TWO rounds of bash parsing — the local heredoc (which strips
# \\" -> ") and the remote shell parse. printf %q is safe for ONE round
# only, so JSON-valued args like --default-chat-template-kwargs
# '{"enable_thinking": false}' arrived at vllm as {enable_thinking: false}
# (inner double quotes eaten), failing argparse's json.loads.
# Quoted-nested heredoc means the rental's bash parses serve_cmdline
# exactly once, preserving the printf %q escapes.
mkdir -p /var/lib/rental-vllm
cat > /var/lib/rental-vllm/serve.sh <<'_RV_SERVE_EOF'
#!/usr/bin/env bash
${serve_cmdline} >> ${RV_RENTAL_VLLM_LOG} 2>&1
_RV_SERVE_EOF
chmod +x /var/lib/rental-vllm/serve.sh

tmux new-session -d -s ${TMUX_SESSION} \
  "bash /var/lib/rental-vllm/serve.sh"

echo "tmux session ${TMUX_SESSION} started"
EOF
  rv_log_info "vLLM launched in tmux session ${TMUX_SESSION} on rental"
}

# Probes the rental's local /v1/models from the rental side (not via tunnel —
# the tunnel may not be up yet). Returns 0 if vLLM responds 200 and the spec's
# model_id appears in the response.
vllm_is_serving_remote() {
  local body http_code
  body="$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "curl -sS -o /tmp/.vllm-models.out -w '%{http_code}' \
       --max-time 5 \
       -H 'Authorization: Bearer ${API_KEY}' \
       http://127.0.0.1:${RV_RENTAL_VLLM_PORT}/v1/models 2>/dev/null; \
     cat /tmp/.vllm-models.out 2>/dev/null" 2>/dev/null || true)"
  # The trailing concatenation in the remote command means the http code is at
  # the front of body. Split it.
  http_code="${body:0:3}"
  body="${body:3}"
  if [[ "${http_code}" != "200" ]]; then
    return 1
  fi
  if printf '%s' "${body}" | jq -e --arg m "${RV_SPEC_MODEL_ID}" '.data[]?.id == $m' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ============================================================
# Wait for /v1/models to come up (rental side). Polls every 10s.
# ============================================================
wait_for_ready() {
  rv_log_info "Stage 8: wait for /v1/models on rental (timeout=${READY_TIMEOUT_SEC}s)"
  local start_ts deadline
  start_ts=$(date +%s)
  deadline=$(( start_ts + READY_TIMEOUT_SEC ))
  local checks=0
  while (( $(date +%s) < deadline )); do
    if vllm_is_serving_remote; then
      local elapsed=$(( $(date +%s) - start_ts ))
      rv_log_info "vLLM ready on rental after ${checks} probes / ${elapsed}s"
      return 0
    fi
    (( ++checks ))
    if (( checks % 6 == 0 )); then
      # Every minute, log the last few lines of the rental log so a stuck
      # launch is visible (most common: HF download in progress, torch.compile
      # cache miss).
      local tail_excerpt elapsed
      elapsed=$(( $(date +%s) - start_ts ))
      tail_excerpt="$(rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
        "tail -n 5 ${RV_RENTAL_VLLM_LOG} 2>/dev/null || true" | tr '\n' '|' | cut -c1-400)"
      rv_log_info "Still waiting (${elapsed}s elapsed); last log lines: ${tail_excerpt}"
    fi
    sleep 10
  done
  rv_log_error "Timed out after ${READY_TIMEOUT_SEC}s waiting for vLLM /v1/models"
  rv_log_error "Last 30 log lines from rental:"
  rv_ssh_run "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}" \
    "tail -n 30 ${RV_RENTAL_VLLM_LOG} 2>/dev/null" | sed 's/^/  /' >&2 || true
  return 1
}

# ============================================================
# Open SSH local-port-forward. Idempotent: if a tunnel is already alive on the
# requested local port for this rental, leave it. Otherwise start a backgrounded
# `ssh -fN -L`.
# ============================================================
SSH_TUNNEL_PID=""
open_tunnel() {
  rv_log_info "Stage 7: SSH tunnel harness:${RV_SPEC_LOCAL_PORT} -> rental:${RV_RENTAL_VLLM_PORT}"

  if rv_ssh_tunnel_alive "${RV_SPEC_LOCAL_PORT}" "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}"; then
    rv_log_info "Tunnel already alive for this rental on local port ${RV_SPEC_LOCAL_PORT}; reusing"
    SSH_TUNNEL_PID="$(pgrep -f "ssh.*-L ${RV_SPEC_LOCAL_PORT}:127.0.0.1:${RV_RENTAL_VLLM_PORT}.*${RV_SPEC_RENTAL_USER}@${RV_SPEC_RENTAL_HOST}" | head -1 || true)"
    return 0
  fi

  # Reject the launch if some *other* process is using the local port (e.g.
  # an unrelated tunnel from a previous campaign). Force-restart doesn't help
  # here — operator must clear it.
  if command -v ss &>/dev/null && ss -tln "sport = :${RV_SPEC_LOCAL_PORT}" 2>/dev/null | grep -q LISTEN; then
    rv_log_error "Local port ${RV_SPEC_LOCAL_PORT} is already in use by another process. Pick a different local_port in the spec, or kill the conflicting listener."
    return 1
  fi

  # -fN: background, no remote command. -L: forward. ExitOnForwardFailure
  # ensures we exit nonzero if the forward can't bind on either side.
  ssh \
    -i "${RV_GPU_RENTAL_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${RV_RENTED_KNOWN_HOSTS}" \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o BatchMode=yes \
    -fN -L "${RV_SPEC_LOCAL_PORT}:127.0.0.1:${RV_RENTAL_VLLM_PORT}" \
    "${RV_SPEC_RENTAL_USER}@${RV_SPEC_RENTAL_HOST}"

  # ssh -fN forks; capture the PID by re-pgrep'ing.
  SSH_TUNNEL_PID="$(pgrep -f "ssh.*-L ${RV_SPEC_LOCAL_PORT}:127.0.0.1:${RV_RENTAL_VLLM_PORT}.*${RV_SPEC_RENTAL_USER}@${RV_SPEC_RENTAL_HOST}" | head -1 || true)"
  if [[ -z "${SSH_TUNNEL_PID}" ]]; then
    rv_log_error "ssh -fN tunnel did not appear in process list after launch"
    return 1
  fi
  rv_log_info "SSH tunnel up (pid=${SSH_TUNNEL_PID})"
}

# ============================================================
# Verify the local endpoint via the tunnel (post-everything sanity check).
# ============================================================
verify_local_endpoint() {
  local endpoint="http://127.0.0.1:${RV_SPEC_LOCAL_PORT}/v1"
  rv_log_info "Stage 8b: verify ${endpoint}/models from harness side"
  local http_code
  local tmp
  tmp="$(mktemp)"
  http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    --max-time 15 \
    -H "Authorization: Bearer ${API_KEY}" \
    "${endpoint}/models" 2>/dev/null || printf '000')"
  if [[ "${http_code}" != "200" ]]; then
    rv_log_error "Local endpoint check FAILED: HTTP ${http_code} from ${endpoint}/models"
    rv_log_error "Body (first 300 chars): $(head -c 300 "${tmp}" 2>/dev/null | tr '\n' ' ')"
    rm -f "${tmp}"
    return 1
  fi
  if ! jq -e --arg m "${RV_SPEC_MODEL_ID}" '.data[]?.id == $m' < "${tmp}" >/dev/null 2>&1; then
    rv_log_warn "Local endpoint reachable but model_id '${RV_SPEC_MODEL_ID}' not in /models. Served: $(jq -r '[.data[]?.id] | join(",")' < "${tmp}" 2>/dev/null)"
  else
    rv_log_info "Local endpoint OK (model present)"
  fi
  rm -f "${tmp}"
}

# ============================================================
# Persist state to /var/lib/harness/rentals/<host>.json + emit stdout.
# ============================================================
write_state_and_emit() {
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local endpoint="http://127.0.0.1:${RV_SPEC_LOCAL_PORT}/v1"
  local spec_sha
  spec_sha="$(sha256sum "${SPEC_PATH}" | cut -c1-16)"

  local body
  body="$(jq -n \
    --arg rental_host    "${RV_SPEC_RENTAL_HOST}" \
    --arg rental_user    "${RV_SPEC_RENTAL_USER}" \
    --arg model_id       "${RV_SPEC_MODEL_ID}" \
    --arg spec_path      "${SPEC_PATH}" \
    --arg spec_sha256    "${spec_sha}" \
    --arg endpoint       "${endpoint}" \
    --argjson local_port "${RV_SPEC_LOCAL_PORT}" \
    --argjson rental_port "${RV_RENTAL_VLLM_PORT}" \
    --arg api_key        "${API_KEY}" \
    --arg tmux_session   "${TMUX_SESSION}" \
    --arg ssh_tunnel_pid "${SSH_TUNNEL_PID}" \
    --arg started_at     "${started_at}" \
    --argjson tp_size    "${RV_SPEC_TP_SIZE}" \
    --arg quant          "${RV_SPEC_QUANT}" \
    --argjson vllm_args  "${RV_SPEC_VLLM_ARGS_JSON}" \
    '{
      rental_host: $rental_host,
      rental_user: $rental_user,
      model_id: $model_id,
      spec_path: $spec_path,
      spec_sha256: $spec_sha256,
      endpoint: $endpoint,
      local_port: $local_port,
      rental_port: $rental_port,
      api_key: $api_key,
      tmux_session: $tmux_session,
      ssh_tunnel_pid: $ssh_tunnel_pid,
      started_at: $started_at,
      tensor_parallel_size: $tp_size,
      quantization: $quant,
      vllm_args: $vllm_args
    }')"

  rv_state_write "${RV_SPEC_RENTAL_HOST}" "${body}"

  # stdout: a concise one-line JSON for orchestrators to parse. Includes only
  # what runners need: endpoint, api_key, model_id, rental_host. Full state
  # is in the JSON file written above.
  jq -n \
    --arg endpoint    "${endpoint}" \
    --arg api_key     "${API_KEY}" \
    --arg model_id    "${RV_SPEC_MODEL_ID}" \
    --arg rental_host "${RV_SPEC_RENTAL_HOST}" \
    -c \
    '{
      endpoint: $endpoint,
      api_key: $api_key,
      model_id: $model_id,
      rental_host: $rental_host
    }'
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  preflight_harness
  rv_load_spec "${SPEC_PATH}"

  rv_log_info "Stage 1: spec validated"
  rv_log_info "Stage 2: SSH preflight"
  rv_ssh_test "${RV_SPEC_RENTAL_USER}" "${RV_SPEC_RENTAL_HOST}"

  remote_install_uv
  remote_install_nvcc
  remote_install_build_tools
  remote_install_vllm

  rv_log_info "Stage 5: ensure API key"
  ensure_api_key

  launch_vllm
  wait_for_ready
  open_tunnel
  verify_local_endpoint

  rv_log_info "Stage 9: persist state and emit"
  write_state_and_emit

  rv_log_info "rental-vllm-up complete: rental=${RV_SPEC_RENTAL_HOST} model=${RV_SPEC_MODEL_ID} endpoint=http://127.0.0.1:${RV_SPEC_LOCAL_PORT}/v1"
}

main "$@"
