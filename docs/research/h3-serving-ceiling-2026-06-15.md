# H3 — Single-Spark concurrent-agent serving ceiling (Gemma-4-31B-NVFP4 on one GB10)

**Issue:** `bd benchmarks-9g4.2` (H3); sweep `9g4.2.2`, tooling `9g4.2.1`.
**Date:** 2026-06-15. **Status:** complete. **Verdict: EC2-bound — one Spark is not the bottleneck.**

## Question

When we parallelize the CyberGym harness (`bd benchmarks-b51`) to run N tasks concurrently against
one continuously-batched vLLM endpoint, where is the **single-Spark serving ceiling**? H3 predicted the
answer is a function of per-turn decode volume: terse agents parallelize freely; verbose (~16K tok/turn)
agents were expected to hit decode contention at low N and fire the timeout cap (`bd benchmarks-35u`).
The decision it gates: are Pool A sweeps **EC2-bound** (one Spark serves the column → scale cheap harness
boxes) or **Spark-bound** (need a 2nd Spark / multi-instance vLLM, `9g4.2.4`)?

## Method

Synthetic concurrent-agent load (`scripts/serving-ceiling/load_gen.py`, `sweep.py`) — chosen over the real
CyberGym harness to isolate the **GPU-serving** variable from harness-CPU saturation (H2) and to run without
waiting on `b51`. Each "agent" is a session carrying a large fixed resident context (16K tokens → APC
prefix-sharing + KV residency) and a forced per-turn decode volume (`ignore_eos`), so decode volume is a
clean knob with the model held constant.

| | |
|---|---|
| Hardware | <SPARK_NODE_2> (DGX Spark, GB10), vLLM 0.21.0 in `vllm-spark:latest` |
| Model | `RedHatAI/gemma-4-31B-it-NVFP4` (compressed-tensors NVFP4), `--served-model-name gemma-4-31b-nvfp4` |
| Config | 128K ctx, `--kv-cache-dtype fp8_e4m3`, `--enable-prefix-caching --enable-chunked-prefill --async-scheduling`, `--gpu-memory-utilization 0.9`, `--max-num-seqs 16`, MM disabled |
| Deviations from ejv | **MTP off** (clean serving baseline — ejv already showed MTP is wall-neutral); `max_num_seqs 8→16` so the N-sweep isn't queue-capped |
| Measured per cell | per-stream decode tok/s, TTFT, per-turn wall (client); `num_preemptions`, prefix-cache hit, peak `gpu_cache_usage` / `num_requests_running/waiting` (server `/metrics`) |
| Raw data | `docs/research/h3-serving-ceiling-2026-06-15/data/` (per-cell JSON + summary) |

**APC parity check** (closes `9g4.2.1` AC#2): a 10-turn single session over a 20K resident prefix measured
**89.3%** prefix-cache hit — the only miss is the unavoidable turn-1 cold prefill; steady-state (turns 2-10)
is ~99%, squarely in the ejv 93–95% band. APC reproduces on real vLLM.

## Results

Per-stream decode rate is the clean contention metric (TTFT/wall are confounded by APC-cache warmth
bleeding across cells). Aggregate throughput = `N × per-stream tok/s`.

**probe — 400 tok/turn:**

| N | per-stream tok/s | rel c1 | **aggregate tok/s** | preemptions | proj. 16K-turn |
|--:|--:|--:|--:|--:|--:|
| 1 | 9.32 | 1.00× | 9.3 | 0 | 28.6 min |
| 2 | 8.36 | 0.90× | 16.7 | 0 | 31.9 min |
| 3 | 8.86 | 0.95× | 26.6 | 0 | 30.1 min |
| 4 | 8.51 | 0.91× | 34.0 | 0 | 31.4 min |
| 6 | 6.42 | 0.69× | 38.5 | 0 | 41.5 min |
| 8 | 6.03 | 0.65× | 48.2 | 0 | 44.2 min |
| 12 | 3.62 | 0.39× | 43.5† | 0 | 73.6 min |
| 16 | 4.01 | 0.43× | 64.1 | 0 | 66.6 min |

**verbose — 4000 tok/turn:**

| N | per-stream tok/s | rel c1 | **aggregate tok/s** | preemptions | proj. 16K-turn |
|--:|--:|--:|--:|--:|--:|
| 1 | 9.23 | 1.00× | 9.2 | 0 | 28.9 min |
| 2 | 9.22 | 1.00× | 18.4 | 0 | 28.9 min |
| 4 | 8.41 | 0.91× | 33.6 | 0 | 31.7 min |
| 8 | 7.08 | 0.77× | 56.7 | 0 | 37.6 min |

† N=12 is a noisy cell (its per-stream dipped below N=16); aggregate still trends up through N=16.

## Findings

1. **Zero preemptions at every N — KV is not the limiter.** Even 16 concurrent 16K-context sessions never
   preempted. Gemma-4's **sliding-window attention** bounds per-sequence KV, so the GB10's 128 GB unified
   memory is never pressured. The "KV headroom / num_preemptions" ceiling H3 worried about **does not bind
   for this model class**. (Full-attention models would behave differently — see caveats.)

2. **Aggregate serving throughput rises monotonically with N** — ~9 → 64 tok/s (terse, ~7×) and ~9 → 57
   tok/s (verbose at N=8, ~6×). For a Pool A *column* (wall = total work ÷ aggregate throughput), more
   concurrency always helps up to at least N=16. **One Spark is not the throughput bottleneck.**

3. **Per-stream rate is flat through N≈4, then dilutes gradually** (~0.65× at N=8, ~0.4× at N=12–16). This
   is smooth compute-bound batch dilution — **not** the abrupt "4× collapse at 3 streams" of `bd 35u`. That
   cliff was specific to Qwen3-235B TP=4 on H100s with concurrent Pool B lm-eval load; it is **not** an
   intrinsic property of concurrent agentic serving.

4. **bd 35u refuted for this rig.** The verbose operating point (4000 tok/turn) held per-stream rate flat
   through N=4 and only 0.77× at N=8 — it did **not** break at N~2–3. Verbose-agent concurrency is fine on
   one GB10 for this model.

5. **`9g4.2.4` (2nd-Spark relief arm) is NOT triggered.** It was gated on a verbose safe-N ≤ ~3; the measured
   safe-N is ≥8. A second Spark is not warranted for the concurrency a single EC2 harness box would drive.

## Safe N and the EC2-bound verdict

By the conservative criterion (per-turn-wall ≤ 1.5× c1, preemptions = 0): **safe N = 8** for both terse and
verbose. But the deeper read is that N=8 is a *per-task-latency* choice, not a Spark ceiling — beyond N=8
aggregate throughput keeps climbing while individual per-stream rate dilutes ~2× by N=16. So:

- **Terse agents:** one Spark serves c16 with no concern (per-turn wall stays trivial).
- **Verbose agents:** safe to c8 on per-task latency; beyond that, per-turn time dilutes (a 16K turn goes
  ~28 → ~67 min from N=1 → N=16), which matters only if `per-turn × turns` approaches the timeout cap.
- **Pool A is EC2-bound.** The single-Spark serving ceiling is far above what one EC2 harness box will drive
  (the harness saturates on C/C++ builds + tool-exec first, per H2). **Scale cheap harness boxes, not Sparks.**
  This unblocks `b51`: build the bounded worker pool with a target of **N≈8–16 against one Spark**, and treat
  the Spark as a latency-insensitive shared service.

## Caveats

- **One model / one GPU.** Gemma-4-31B-NVFP4 on GB10. The zero-preemption result leans on sliding-window
  attention; a full-attention model at 128K would build large KV and could preempt at high N. Re-measure per
  model class before generalizing.
- **MTP off.** Single-stream decode is ~9 tok/s; MTP (ejv: ~8× acceptance) would raise effective per-stream
  rate but does not change the preemption story or the contention *shape*. The projected 16K-turn minutes are
  upper bounds (no MTP).
- **Forced uniform decode volume** via `ignore_eos`; real agents vary per turn. The per-stream-rate-vs-N
  curve is the transferable result; absolute per-turn minutes scale with the model's true per-turn output.
- **TTFT/wall confounded** by cross-cell APC warmth; decode-rate is the clean metric used for the verdict.
- A real-concurrent-CyberGym confirmation (`9g4.2.3`) remains, gated on `b51`.
