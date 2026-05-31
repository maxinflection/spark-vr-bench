# DeepSeek-V4-Flash vLLM Mainline Readiness — B200 vs RTXPro6000 vs Hopper (2026-05-21)

## 1. Summary

DeepSeek-V4-Flash (deepseek-ai/DeepSeek-V4-Flash, released 2026-04-24, MIT) **is officially supported in vLLM mainline since v0.20.0 (2026-04-27)** on **Hopper SM90 and datacenter Blackwell SM100/SM103** — these are listed as `verified` in the upstream vLLM Recipes file ([recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash), mirrored at [github.com/bsmr/vllm-project---recipes](https://github.com/bsmr/vllm-project---recipes/blob/main/models/deepseek-ai/DeepSeek-V4-Flash.yaml)). The merged feature PR is [vllm-project/vllm#40860 "DeepSeek V4 Rebased"](https://github.com/vllm-project/vllm/pull/40860) (merged 2026-04-27). The `deepseek_v4` tokenizer mode, tool-call parser and reasoning parser are all registered ([docs.vllm.ai .../deepseekv4_tool_parser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/deepseekv4_tool_parser/)).

**Consumer Blackwell (SM120, RTX Pro 6000 / RTX 50-series, and SM121 / GB10 / DGX Spark) is NOT supported on vLLM mainline today.** Mainline boots and immediately hits a DeepGEMM `Unsupported architecture` assertion on RTX Pro 6000 ([vllm#26211](https://github.com/vllm-project/vllm/issues/26211), [vllm#40821](https://github.com/vllm-project/vllm/issues/40821), [HF discussions/28](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/discussions/28)). The three PRs called out in <CAMPAIGN> ([#40923](https://github.com/vllm-project/vllm/pull/40923), [#41028](https://github.com/vllm-project/vllm/pull/41028), [#41062](https://github.com/vllm-project/vllm/pull/41062)) are **all still OPEN** as of 2026-05-21 and only widen capability gates / kernel arch lists for SM 12.x; the SM100/SM103 path was already in mainline at v0.20.0 and is unaffected by them. The tracking issue is [vllm#41063](https://github.com/vllm-project/vllm/issues/41063).

**Bottom line for <CAMPAIGN>:** **fire on B200 (SM100), not on RTXPro6000.** B200 is READY on stock vLLM 0.21.0; RTXPro6000 requires the `jasl/ds4-sm120` community fork, which we won't ship. Hopper (H100/H200) is an acceptable fallback for ×4/×8 configs.

## 2. vLLM Mainline State

### 2.1 Release timeline

Per [pypi.org/project/vllm](https://pypi.org/project/vllm/):

| Version | Date | V4-relevant content |
|---|---|---|
| 0.19.1 | 2026-04-18 | pre-V4 |
| **0.20.0** | **2026-04-27** | Initial DeepSeek V4 support, FlashAttention 4 default MLA prefill, MXFP4 W4A4 CUTLASS MoE for SM100, FlashInfer 0.6.8, "DSA + MTP IMA fix", silu clamp on shared experts |
| 0.20.1 | 2026-05-03 | "DeepSeek V4 base model support" cleanup, multi-stream pre-attn GEMM |
| 0.20.2 | 2026-05-10 | DeepSeek V4 sparse-attention stabilization |
| **0.21.0** | **2026-05-15** | DeepSeek V4 pipeline parallelism (#41694), `max` reasoning effort (#40982), disaggregated serving fixes (#41957), AMD/ROCm DeepSeek-V4 (#40871), GELU TRT-LLM NvFP4 MoE for Gemma4, FlashInfer CUTLASS MXFP4-MXFP8 MoE fix (#42089), torch 2.11 / CUDA 13.0 / Python 3.14 |

Source: [github.com/vllm-project/vllm/releases](https://github.com/vllm-project/vllm/releases), [v0.20.0 notes](https://github.com/vllm-project/vllm/releases/tag/v0.20.0), [v0.21.0 notes](https://github.com/vllm-project/vllm/releases/tag/v0.21.0). The vLLM Recipe pins `min_vllm_version: 0.20.0`; we should pin `>=0.21.0` to inherit the pipeline-parallel and disagg-serving fixes.

### 2.2 Roadmap status ([#40902](https://github.com/vllm-project/vllm/pull/40902))

Merged on the V4 roadmap as of 2026-05-21:
- #40860 core DeepSeek V4 support (FP4 Indexer, MegaMoE initial, Hopper)
- #41061 multi-stream 4-GEMM Pre-Attn
- #41326 faster FP8 group-quant kernel for Blackwell
- #41105 Indexer topk + page-table transform fusion
- #41263 norm + router fusion (low-latency decode)
- #40960 BF16/MXFP8 A2A via FlashInfer

Still open: #40833 DeepGEMM MegaMoE kernel integration, #39654 KV-cache CPU offload. None of these block B200 serving.

### 2.3 SM-arch dispatch matrix

| SM class | GPU | Mainline status |
|---|---|---|
| **SM100 / SM103** | **B200, GB200, B300, GB300** | **VERIFIED** in recipe; MXFP4 W4A4 CUTLASS MoE + FlashAttention-4 prefill landed in v0.20.0. The `blackwell` hardware override in the recipe sets `--attention_config.use_fp4_indexer_cache=True` and `--moe-backend deep_gemm_mega_moe`. |
| **SM120** | RTX Pro 6000, RTX 50-series | NOT supported on mainline. DeepGEMM `Unsupported architecture` assertion at `hyperconnection.hpp:56`; SM120-native CuTeDSL kernels exist in a fork but are not upstreamed ([#41063](https://github.com/vllm-project/vllm/issues/41063)). |
| **SM121** | GB10 (DGX Spark) | NOT supported. Gated on the 3 open PRs (#40923 Marlin MoE arch list, #41028 OAITriton MXFP4 device-range, #41062 DeepGEMM device gates). All three were still **open** as of the page snapshots captured 2026-04-27 – 2026-05-01 and remain open per the latest scan. |
| **SM90** | H100, H200 | VERIFIED. `hopper` hardware override caps spec-decoding at `num_speculative_tokens=1` (vs 2 on Blackwell). FlashAttention-4 head-dim-512 paged-KV landed in v0.20.0. |
| **SM80** | A100/A800 | **NOT supported**. [vllm#40851](https://github.com/vllm-project/vllm/issues/40851) is an open feature request — fails with the same `Unsupported architecture` assertion in `deepgemm-src/csrc/apis/hyperconnection.hpp:56`. FP4 MoE experts cannot be dispatched on Ampere. No workaround. |

### 2.4 Parsers

`deepseek_v4` is registered as tokenizer-mode, tool-call parser, AND reasoning parser ([docs.vllm.ai/.../deepseekv4_tool_parser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/deepseekv4_tool_parser/)). Known bugs:

- [#41240](https://github.com/vllm-project/vllm/issues/41240): the v4 tool parser is "mostly a thin wrapper around the DeepSeek V3.2 parser with different DSML tool-call boundary tokens"; misses DSML edge cases (numeric/bool/array/object args returned as strings).
- [#41132](https://github.com/vllm-project/vllm/issues/41132): structured output incorrect with thinking enabled (V3.2 + V4).

For our agentic Pool-A use (CyberGym, SEC-bench, ExploitBench), the deepseek_v4 parser is the right pin, but the tool-call edge cases may show up — flag for a sanity probe at rental bring-up. The previous policy memory `thinking-mode-policy-2026-05-19` listed `deepseek_v3, deepseek_r1` as the DeepSeek-family parsers; that list **must be updated** to add `deepseek_v4` (V4-Flash uses DSML, not V3 JSON tool boundaries).

## 3. HF Model Card State

Source: [huggingface.co/deepseek-ai/DeepSeek-V4-Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) and its `config.json`.

### 3.1 Shape and quant

- `model_type: "deepseek_v4"`, `architectures: ["DeepseekV4ForCausalLM"]`
- 284B total / 13B active, 43 layers, 64 attention heads, **`num_key_value_heads: 1`** (MLA-style)
- `n_routed_experts: 256`, `n_shared_experts: 1`, `num_experts_per_tok: 6`, `moe_intermediate_size: 2048`
- `scoring_func: "sqrtsoftplus"`, `topk_method: "noaux_tc"` (new vs V3)
- `head_dim: 512`, `qk_rope_head_dim: 64`, `sliding_window: 128`
- `max_position_embeddings: 1048576` (1M), YaRN scaling factor 16 from 65 536 base
- `num_nextn_predict_layers: 1` (MTP head present)
- Quant: `quant_method: "fp8"` with `weight_block_size: [128,128]`, `fmt: "e4m3"`, `scale_fmt: "ue8m0"`, `activation_scheme: "dynamic"`, **plus `expert_dtype: "fp4"`** — MoE experts in FP4, rest in FP8. `torch_dtype: bfloat16` for unquantized tensors.
- Card text confirms "158B in Safetensors format" (the "158 GB" weight number in <CAMPAIGN> was a serialized-size estimate, not a parameter count).

### 3.2 Serving guidance from the model card

The HF model card itself is sparse: it shows `pip install vllm; vllm serve "deepseek-ai/DeepSeek-V4-Flash"` and the curl chat completions example, with **no** TP/EP/max_model_len/parser recommendations. The detailed serving knobs live in the vLLM Recipe (§5 below). The card does say Think-Max mode needs `>= 384K` context.

Reasoning interface is a custom Python encoder (`encoding_dsv4`), not a Jinja chat template — three modes: Non-think, Think High, Think Max. vLLM 0.21 supports `max` reasoning effort via #40982.

## 4. What changed vs DeepSeek-V3-Flash

The V3-Flash dispatch path does **not** trivially adapt to V4-Flash. New machinery added in PR #40860 and follow-ons:

1. **Hybrid CSA + HCA + sliding-window attention** — Compressed Sparse Attention (CSA, the long-range global track) layered with Heavily Compressed Attention (HCA) and a 128-token sliding window. In vLLM this lives behind `DeepseekV4Indexer` + `sparse_swa.py` and requires `--no-disable-hybrid-kv-cache-manager` for the multi-track KV manager (per recipe). Card claims **10% of V3.2 KV-cache** at 1M context.
2. **FP4 indexer cache** — `--attention_config.use_fp4_indexer_cache=True` is a Blackwell-only override in the recipe (`hardware_overrides.blackwell`).
3. **MegaMoE / DeepGEMM mega-MoE backend** — `--moe-backend deep_gemm_mega_moe`. Different code path from V3's CUTLASS grouped-GEMM. The DeepGEMM dispatcher's `_supports_current_device()` is exactly the function the three open PRs widen for SM 12.x — on SM100 it is already accepted.
4. **Manifold-Constrained Hyper-Connections (mHC)** — replaces vanilla residual; this is what triggers the `hyperconnection.hpp:56 Unsupported architecture` assertion on SM80/SM120.
5. **MTP head** in checkpoint (`num_nextn_predict_layers: 1`) — drives the `--speculative_config '{"method":"mtp","num_speculative_tokens":2}'` recipe default. Per battery convention (<CAMPAIGN> ticket) we **disable native MTP** for the screening run.
6. **Tool-call DSML** — V4 uses DSML boundary tokens distinct from V3.2's JSON, hence the separate `deepseek_v4` parser registration.

The V3-vs-V4 dispatch surface is **largely disjoint** below the model_executor entry point. V3 paths do not load V4 weights.

## 5. B200 Recipe (canonical upstream)

From [the upstream YAML](https://github.com/bsmr/vllm-project---recipes/blob/main/models/deepseek-ai/DeepSeek-V4-Flash.yaml):

```yaml
hardware:
  h200: verified
  b200: verified
  gb200: verified
  b300: verified
  gb300: verified
  mi300x: unsupported
  mi325x: unsupported
  mi355x: unsupported
model:
  min_vllm_version: "0.20.0"
  flashinfer_autotune: true
  base_args: [--trust-remote-code, --kv-cache-dtype, fp8, --block-size, 256]
  base_env: { VLLM_ENGINE_READY_TIMEOUT_S: "3600" }
variants.default: { precision: fp8, vram_minimum_gb: 170 }
default_strategy: single_node_tep   # tensor + expert parallel
hardware_overrides.blackwell.extra_args:
  - --attention_config.use_fp4_indexer_cache=True
  - --moe-backend
  - deep_gemm_mega_moe
strategy_overrides.single_node_tp: { tp: 8, extra_args: [--no-enable-flashinfer-autotune] }
features.tool_calling.args:  [--tokenizer-mode, deepseek_v4, --tool-call-parser, deepseek_v4, --enable-auto-tool-choice]
features.reasoning.args:     [--reasoning-parser, deepseek_v4]
features.spec_decoding.args: [--speculative_config, '{"method":"mtp","num_speculative_tokens":2}']
features.spec_decoding.hardware_overrides.hopper.args:
                             [--speculative_config, '{"method":"mtp","num_speculative_tokens":1}']
```

Important notes from this recipe:

- `vram_minimum_gb: 170` — confirms the ~158 GB number is weights only; provisioned floor with KV is 170 GB. **2×B200 (192 GB ×2 = 384 GB) with TP=2 fits comfortably**; 1×B200 will not (no KV headroom for agentic budgets). 1×B300 (288 GB SXM7) fits with thin KV.
- `single_node_tep` (tensor + expert parallel) is the **default**. The Spheron writeup confirms: "shards attention/shared params 4-way and routes the 256 MoE experts across all 8 NVIDIA B200 GPUs" — i.e. `tensor-parallel-size 4 --enable-expert-parallel` on a B200 ×8 box.
- `--no-disable-hybrid-kv-cache-manager` is required for CSA+HCA (per Spheron + recipe pd_cluster sub-config).
- DeepGEMM kernels need a one-time `tools/install_deepgemm.sh` invocation post-install.

## 6. Quant strategy on B200

The FP8+FP4 mixed checkpoint is dispatched natively on SM100 — there are **no** `VLLM_NVFP4_GEMM_BACKEND` / `VLLM_USE_FLASHINFER_MOE_FP4` / `VLLM_FLASHINFER_MOE_BACKEND` overrides in the recipe. Those env vars exist to work around the SM120 NVFP4 CUTLASS JIT-vs-CUDA-13 mismatch that bit our `nemotron-3-super-120b-a12b-nvfp4.yaml` spec — they are **not relevant on B200**, because B200 has prebuilt SM100 CUTLASS+FlashInfer kernels in vLLM 0.20+.

What B200 DOES want, beyond the recipe baseline, is `--enable-prefix-caching` (our convention; not in recipe) and (in the disaggregated decode profile) `cudagraph_mode: FULL_DECODE_ONLY`. The `FULL_AND_PIECEWISE` cudagraph hang reported in [#40969](https://github.com/vllm-project/vllm/issues/40969) is SM 12.x-only — that's a `sparse_swa.py AttentionCGSupport.UNIFORM_BATCH` mismatch with chunked-prefill mixed-length batches on consumer Blackwell. Not observed on SM100.

## 7. Comparison with our existing spec patterns

- **`qwen3-235b-thinking-awq-256k-thinking-on.yaml`** is the closest large-MoE template — TP=N, no EP, AWQ quant. V4-Flash departs from this by **requiring** EP at the default strategy (`single_node_tep`); single-node TP is supported but the recipe explicitly disables FlashInfer autotune in that mode (`--no-enable-flashinfer-autotune`).
- **`nemotron-3-super-120b-a12b-nvfp4.yaml`** is our NVFP4 env-var template. V4-Flash on B200 **does not need** those env vars (no JIT path, FP8+FP4 native). We do reuse the `vllm_env:` map structure for `VLLM_ENGINE_READY_TIMEOUT_S: "3600"` (the 1M-context model takes well over the default 600 s to be ready).

## 8. Determination

- **B200 (SM100) / B300 (SM103) — READY.** Verified upstream, vLLM 0.21.0 mainline, prebuilt kernels, all roadmap blockers merged. Pin `vllm_min_version: "0.21.0"`. **This is the firing path for <CAMPAIGN>.**
- **RTXPro6000 / SM120 — WAIT-FOR-UPSTREAM (community fork only).** Mainline crashes at DeepGEMM `Unsupported architecture`. Open PRs #40923/#41028/#41062 widen gates but #41063 confirms additional SM120 FP4 GEMM/attention/einsum kernel-source gaps remain. The `jasl/ds4-sm120` community fork works (30–35 tok/s) but we will not ship a forked vLLM into the bench rentals. **Do NOT fire on Runcrate's $15.75/hr RTXPro6000 ×8 in-stock SKU for V4-Flash.**
- **H200 / H100 (SM90) — READY (fallback).** Verified upstream; recipe caps MTP at 1 speculative token; 4×H200 (141 GB ×4 = 564 GB) is the documented Hopper TEP layout. Useful fallback for ×4 if B200 inventory stays sold-out.
- **A100 (SM80) — WAIT-FOR-UPSTREAM** (likely indefinite). [vllm#40851](https://github.com/vllm-project/vllm/issues/40851) is open with no maintainer response; mHC kernels not implemented on Ampere.
- **DGX Spark / GB10 (SM121) — PATCH-NEEDED.** Gated on three open PRs above + the broader #41063 tracking issue. Out of scope for <CAMPAIGN>.

### 8.1 Recommended spec skeleton (for bd <ISSUE>)

```
model_id:               deepseek-ai/DeepSeek-V4-Flash
quant:                  fp8                  # MoE experts FP4 + rest FP8 native, no --quantization override
tensor_parallel_size:   2                    # on 2×B200 — default_strategy `single_node_tep`
                                             #   alternatively TP=4 + --enable-expert-parallel on 4×B200/H200
enable_expert_parallel: true                 # recipe default is `single_node_tep`
max_model_len:          262144               # 256K target per feedback_context_length_policy
                                             #   Think-Max wants ≥384K — bump per profile
vllm_min_version:       "0.21.0"
vllm_env:
  VLLM_ENGINE_READY_TIMEOUT_S: "3600"        # 1M-ctx engine init exceeds 600 s default
  # NO VLLM_NVFP4_GEMM_BACKEND / VLLM_USE_FLASHINFER_MOE_FP4 — those are SM120-only
vllm_args:
  - --trust-remote-code
  - --kv-cache-dtype, fp8
  - --block-size, "256"
  - --moe-backend, deep_gemm_mega_moe
  - --attention_config.use_fp4_indexer_cache=True
  - --no-disable-hybrid-kv-cache-manager      # required by CSA+HCA hybrid KV manager
  - --enable-prefix-caching                   # our convention
  - --tokenizer-mode,   deepseek_v4
  - --reasoning-parser, deepseek_v4           # NEW family — update thinking-mode-policy memory
  - --tool-call-parser, deepseek_v4
  - --enable-auto-tool-choice
  # MTP intentionally DISABLED per <CAMPAIGN> battery convention
  # If re-enabled for perf comparison cell:
  # - --speculative_config, '{"method":"mtp","num_speculative_tokens":2}'  # Blackwell
  # - --speculative_config, '{"method":"mtp","num_speculative_tokens":1}'  # Hopper
preinstall:
  - bash <(curl -fsSL https://raw.githubusercontent.com/vllm-project/vllm/main/tools/install_deepgemm.sh)
```

SKU candidates (per [runcrate-ai-inventory-snapshot-2026-05-15](#) memory and the <CAMPAIGN> ticket's "fit context, not minimize $/hr" rule):

| SKU | Status | Notes |
|---|---|---|
| Runcrate **B200 ×2** | watch — sold out as of last snapshot | minimum viable; TP=2, no EP |
| Runcrate **B200 ×4** or ×8 | watch | enables `single_node_tep` (TP=4 + EP) — recipe default |
| Runcrate **B300 ×1** ($8.14/hr Helsinki) | in-stock | fits at thin KV; Helsinki latency tolerable for screening |
| Runcrate **H200 ×4** | watch | Hopper fallback; MTP cap = 1 |
| Runcrate **RTXPro6000 ×8** ($15.75/hr in-stock) | **DO NOT USE** for V4-Flash | mainline crashes; would require forked vLLM |

## 9. Recommended next move

**File the rental spec (bd <ISSUE>) targeting B200 ×2 or B300 ×1**, gated on inventory appearing. Keep bd <ISSUE> (opportunistic B200 inventory monitoring) running. **Do not fire on RTXPro6000 today** — that path is a vLLM-fork detour with no upstream landing date. Update the `thinking-mode-policy-2026-05-19` memory to add `deepseek_v4` to the reasoning-parser family list. The three "Spark-side" PRs (#40923/#41028/#41062) and tracking #41063 can be revisited once we re-prioritize spark-deploy; they are **not** blockers for the rented-B200 screening run.

---

Sources:
- [huggingface.co/deepseek-ai/DeepSeek-V4-Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) (model card + config.json)
- [recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash) · [mirror YAML](https://github.com/bsmr/vllm-project---recipes/blob/main/models/deepseek-ai/DeepSeek-V4-Flash.yaml)
- vLLM PRs: [#40860 V4 Rebased (merged)](https://github.com/vllm-project/vllm/pull/40860) · [#40902 V4 roadmap](https://github.com/vllm-project/vllm/pull/40902) · [#40923 Marlin MoE SM12.x (open)](https://github.com/vllm-project/vllm/pull/40923) · [#41028 OAITriton MXFP4 (open)](https://github.com/vllm-project/vllm/pull/41028) · [#41062 DeepGEMM MoE SM12.x (open)](https://github.com/vllm-project/vllm/pull/41062)
- vLLM issues: [#40821 V4 RTX Pro 6000 load fail](https://github.com/vllm-project/vllm/issues/40821) · [#40851 SM80 A100 support](https://github.com/vllm-project/vllm/issues/40851) · [#40969 SM12.x cudagraph hang](https://github.com/vllm-project/vllm/issues/40969) · [#41063 DeepGEMM SM12.x tracking](https://github.com/vllm-project/vllm/issues/41063) · [#41132 V4 thinking structured output](https://github.com/vllm-project/vllm/issues/41132) · [#41240 V4 DSML tool parser bug](https://github.com/vllm-project/vllm/issues/41240) · [#26211 vLLM no DeepSeek on SM120](https://github.com/vllm-project/vllm/issues/26211)
- Releases: [v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) · [v0.21.0](https://github.com/vllm-project/vllm/releases/tag/v0.21.0) · [pypi.org/project/vllm](https://pypi.org/project/vllm/)
- [vllm.ai blog 2026-04-24 DeepSeek V4](https://vllm.ai/blog/2026-04-24-deepseek-v4) (referenced; HTTP-403 to direct fetch)
- [HF discussions/28 — RTX Pro 6000 / SM120 community workaround](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/discussions/28)
- [Spheron deploy-deepseek-v4 writeup](https://www.spheron.network/blog/deploy-deepseek-v4-gpu-cloud/)
- [docs.vllm.ai/.../deepseekv4_tool_parser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/deepseekv4_tool_parser/)
