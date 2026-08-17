# vLLM release impact — 2026-05-18 sweep audit

**Author:** research subagent · **Date:** 2026-05-18 · **Scope:** <CAMPAIGN>–.11 rental specs (Qwen3.6 FP8, Qwen3.5/Gemma-4/Nemotron-3 NVFP4, Qwen3-235B AWQ, DeepSeek-V4-Flash).

## Latest release

**vLLM v0.21.0** — released **2026-05-15**, 3 days before this audit. 367 commits / 202 contributors. PyPI confirms (`pip index versions vllm` would show 0.21.0, 0.20.2, 0.20.1, 0.20.0 …). Patch releases since 0.20.0 (Apr 27): 0.20.1 (May 3) and 0.20.2 (May 10), both DeepSeek-V4 hardening drops. ([vLLM releases](https://github.com/vllm-project/vllm/releases), [PyPI](https://pypi.org/project/vllm/))

## Primary tier — correctness / unblockers

### TOP FINDING — SM120 NVFP4 MoE on RTX PRO 6000 is **still not fully working out-of-box in v0.21.0**

The Helsinki provisioning failure (`No supported CUDA architectures found for major versions [12]` while JIT-compiling `flashinfer.gemm.gemm_base.get_gemm_sm120_module_cutlass_fp4`) is the FlashInfer-side half of a known stack of bugs. State of play:

- **vLLM side**: PR [#33417](https://github.com/vllm-project/vllm/pull/33417) (merged 2026-01-31, shipped in v0.15.1) added `is_device_capability_family(120)` to four MoE backend selectors. Follow-up [#33516](https://github.com/vllm-project/vllm/pull/33516) was closed unmerged after maintainer review; replacement PRs landed during v0.16–v0.18. Backend *selection* on SM120 works in v0.20+.
- **FlashInfer side**: issue [#2577](https://github.com/flashinfer-ai/flashinfer/issues/2577) (mm_fp4 GEMM broken — all backends) and [#2723](https://github.com/flashinfer-ai/flashinfer/issues/2723) (CUTLASS grouped block-scaled GEMM invalid output, **10+ files need patching**) are **both still open as of 2026-05-09 last activity**. The breakthrough config — CUDA 13.0 + `compute_120f` arch flag (vs broken `compute_120a`) — is documented in NVIDIA CUTLASS issue [#3096](https://github.com/NVIDIA/cutlass/issues/3096) but the FlashInfer 0.6.5 patches are **not in any released wheel**.
- **Active fresh issues against v0.20.x / v0.21**: [#35065](https://github.com/vllm-project/vllm/issues/35065) (Nemotron-3-Nano NVFP4 "No NvFp4 MoE backend supports the deployment configuration"), [#35566](https://github.com/vllm-project/vllm/issues/35566) (CUDA illegal-memory-access on RTX PRO 6000 with `VLLM_NVFP4_GEMM_BACKEND=cutlass|marlin`, reproduces v0.15.1 → v0.16.0 → nightly cu130), [#38718](https://github.com/vllm-project/vllm/issues/38718) (garbage output when CPU offload enabled), [#40677](https://github.com/vllm-project/vllm/issues/40677) (Gemma-4 31B `head_size not supported` when FLASHINFER attention is forced on SM120 — workaround: `--attention-backend TRITON_ATTN`).

**Implication for our sweep:** <CAMPAIGN> (Gemma-4-31B-NVFP4), <CAMPAIGN> (Gemma-4-26B-A4B-NVFP4), <CAMPAIGN> (Nemotron-3-Super-120B-NVFP4), <CAMPAIGN> (Qwen3.5-122B-A10B-NVFP4) are **all at risk on RTXPro6000**. v0.21.0 does not change this. Recommended H200/H100/GH200 fallback (SM100 datacenter Blackwell or Hopper) for these four.

### DeepSeek-V4 (<CAMPAIGN>) is genuinely unblocked

Initial native support landed in v0.20.0 (2026-04-27). v0.20.1/.2 added stabilization (multi-stream pre-attention GEMM, persistent topk deadlock fix, sparse-attention correctness, FP4 indexer cache). v0.21.0 adds ROCm support ([#40871](https://github.com/vllm-project/vllm/pull/40871)), pipeline parallelism ([#41694](https://github.com/vllm-project/vllm/pull/41694)), max-reasoning-effort knob ([#40982](https://github.com/vllm-project/vllm/pull/40982)), disagg fixes ([#41957](https://github.com/vllm-project/vllm/pull/41957)). V4-Flash recipe ([recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash)) confirms 4×B200/B300 target with `--kv-cache-dtype fp8 --block-size 256 --attention_config.use_fp4_indexer_cache=True --trust-remote-code`. Architecture: shared KV + inverse RoPE, hybrid `c4a`/`c128a` compressed KV (1/4 and 1/128), 128-token sliding window, DeepSeek Sparse Attention top-k. ([vLLM blog post 2026-04-24](https://github.com/vllm-project/vllm-project.github.io/blob/main/_posts/2026-04-24-deepseek-v4.md))

### Gemma-4 (<CAMPAIGN>/.7) is "supported" but multimodal-heavy

Architecture lands via PR [#38826](https://github.com/vllm-project/vllm/pull/38826) — MoE + multimodal (vision/audio) + reasoning + tool-use. Reasoning parser `gemma4` and tool parser `gemma4` exist in v0.21.0 docs. **Known bug**: `--reasoning-parser gemma4 --default-chat-template-kwargs '{"enable_thinking": false}'` silently disables xgrammar structured output ([#39130](https://github.com/vllm-project/vllm/issues/39130)). Also [#38855](https://github.com/vllm-project/vllm/issues/38855): `<|channel>` tokens stripped before parsing. We need to defensively assert `reasoning_content` is populated in our Pool A traces.

### Qwen3.5 / Qwen3.6 — reasoning parser `qwen3` is stable; chat templates need care

[vLLM Qwen recipes](https://docs.vllm.ai/projects/recipes/en/latest/Qwen/Qwen3.5.html) document `--reasoning-parser qwen3 --tool-call-parser qwen3_xml`. The community chat-template fix repo ([allanchan339/vLLM-Qwen3-3.5-3.6-chat-template-fix](https://github.com/allanchan339/vLLM-Qwen3-3.5-3.6-chat-template-fix)) confirms agentic-task chat template bugs persisted through early-2026 vLLM. The `--default-chat-template-kwargs '{"enable_thinking": false}'` flag (bd <ISSUE>) remains the correct knob in v0.21.0.

### Quantization paths

- **NVFP4 KV cache** ([#40177](https://github.com/vllm-project/vllm/pull/40177)) lands in v0.21.0 — relevant if we run V4-Flash on capable HW.
- **FP8 group-quant packed kernel** ([#41326](https://github.com/vllm-project/vllm/pull/41326)) — faster prefill for <CAMPAIGN>/.5.
- **AWQ-INT4 / Marlin** — no breaking changes; <CAMPAIGN> path unchanged.

## Secondary tier — efficiency

- **TurboQuant** KV-cache 2–6× compression (PR [#38479](https://github.com/vllm-project/vllm/pull/38479), merged 2026-04-15, shipped v0.20). `--kv-cache-dtype turboquant_3bit_nc|k8v4|4bit_nc|k3v4_nc`. **MLA models unsupported** → no win for DeepSeek-V4. Useful for long-context Qwen3.5/Qwen3.6 GQA prefills.
- **TOKENSPEED_MLA** ([#41778](https://github.com/vllm-project/vllm/pull/41778)) — Blackwell MLA prefill+decode; helps V4-Flash on B200, not RTXPro6000.
- **Speculative decoding now respects reasoning/thinking budgets** — fixes silent bugs we'd otherwise hit on <CAMPAIGN> / Pool B.
- **FlashInfer top-k/top-p sampler default-on** ([#40376](https://github.com/vllm-project/vllm/pull/40376)).
- **Docker image −2.5 GB** via deferred cubin download (faster rental cold-start).

## Recommendation

**Bump `vllm_min_version: "0.20"` → `"0.21.0"` across all 8 rental specs.** Wins:

1. DeepSeek-V4 (<CAMPAIGN>) gets pipeline-parallel + max-reasoning-effort + disagg fixes.
2. Spec-decode honors thinking budgets (correctness for <CAMPAIGN> Pool B).
3. FP8 group-quant kernel speeds up <CAMPAIGN>/<CAMPAIGN>.
4. TurboQuant available for GQA/MHA long-context experiments.

**What 0.21.0 does NOT fix:** the SM120 NVFP4 FlashInfer JIT failure. **Mitigation for <CAMPAIGN>/.7/.8/.9 today**:

- Prefer **H200 / H100 / GH200 fallback** for NVFP4 specs until FlashInfer ships SM120 patches (track [flashinfer #2577](https://github.com/flashinfer-ai/flashinfer/issues/2577), [#2723](https://github.com/flashinfer-ai/flashinfer/issues/2723)).
- If RTXPro6000 is the only option: pin `VLLM_NVFP4_GEMM_BACKEND=marlin`, set `--attention-backend TRITON_ATTN`, and ensure CUDA toolkit is 13.0 with `compute_120f` available in `TORCH_CUDA_ARCH_LIST` (our `rental-vllm-up.sh` already installs `cuda-toolkit-13-0`; verify the arch flag explicitly).
- File a `bd` issue to monitor [vllm#31085](https://github.com/vllm-project/vllm/issues/31085) and [#35065](https://github.com/vllm-project/vllm/issues/35065) for upstream resolution before re-attempting RTXPro6000 for NVFP4 MoE.

Sources are linked inline above. Word count ~790.
