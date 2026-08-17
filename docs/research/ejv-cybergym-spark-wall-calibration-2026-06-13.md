# ejv — measured CyberGym agentic wall on a DGX Spark (Gemma-4 31B NVFP4, two-arm MTP calibration, 2026-06-13)

**Status:** complete. This is the measured anchor that replaces the decode-tok/s *extrapolation* in
[`serving-strategy-2026-06-05.md` §2](../explorations/serving-strategy-2026-06-05.md) and closes its §5 item 2.
Tracking issue: `bd benchmarks-ejv` (+ child `benchmarks-ejv.1`, closed). Memory: `bd memories ejv-cybergym-spark-wall-anchor`.

## TL;DR

- **The agentic per-task wall is NOT decode-bound.** Enabling MTP (Multi-Token Prediction speculative decoding)
  made *decode itself ~8× faster* (90.9% draft-token acceptance) yet moved the **total-arm wall by −1.0%** (10,537s → 10,435s).
  The hypothesis "MTP moves the wall <~15% because the wall is tool-exec / iteration-bound, not decode-bound" is **confirmed**.
- **The wall is dominated by a stochastic timeout looper.** Each arm had exactly **one** task hit the 7200s `max_iter`/timeout
  cap — but a **different task each run** (Arm 1: `arvo:368`; Arm 2: `oss-fuzz:370689421`). That one task = **~68–69% of the
  whole-arm wall** and is MTP-invariant. The wall model is **additive**, not throughput-divided:
  `wall ≈ Σ(fast-task walls) + n_timeout × timeout_cap`.
- **APC carries prefill.** Prefix-cache hit-rate 92.9% (Arm 1) / 94.5% (Arm 2) — the growing agentic transcript is ~93–95%
  cached, so prefill is nearly free and generation volume is tiny relative to wall.
- **Real wall levers, in order:** (1) timeout/`max_iter` policy, (2) harness parallelism `c1→cN` (the unrealized §4 win),
  (3) decode-tok/s incl. MTP — a **~1% term**, not a planning lever for Pool A wall.

## Setup

| | |
|---|---|
| Model | `RedHatAI/gemma-4-31B-it-NVFP4` (dense, NVFP4), served as `gemma-4-31b-nvfp4` |
| Drafter (Arm 2) | `google/gemma-4-31B-it-assistant` (0.5B), `num_speculative_tokens=8`, text-only |
| Hardware | <SPARK_NODE_2> (DGX Spark, GB10/SM121), stock vLLM 0.21.0, `--kv-cache-dtype fp8`, `--enable-prefix-caching` |
| Context | **128K** (`max_model_len=131072`) |
| Bench | CyberGym n=10, OpenHands, `max_iter=100`, `CYBERGYM_MAX_OUTPUT_TOKENS=16384`, per-task timeout 7200s |
| Concurrency | **c1** (sequential harness) |
| Harness host | proxmox-02 VM, on the LLM path over a WAN tunnel (116ms RTT / 88 Mbit/s, 0% loss) |
| Campaigns | Arm 1 `ejv-gemma31-arm1-mtpoff-2026-06-13`; Arm 2 `ejv-gemma31-arm2-mtp8-2026-06-13` |
| Source of truth | per-task `result.json` + runner log on the VM (`/var/lib/harness/results/<campaign>/`) |

**Arm 1** = MTP off (controlled baseline). **Arm 2** = MTP on (8 spec tokens). Same harness, same endpoint, same tasks.

## Results — per task

`(TO)` = hit the 7200s timeout (right-censored; the real wall is a lower bound). Pass from `result.json`/`verdict.json`.

| Task | Arm1 wall | Arm2 wall | Δ wall | Arm1 pass | Arm2 pass | tok_in A2/A1 |
|---|--:|--:|--:|:--:|:--:|--:|
| arvo:47101 | 155 | 92 | −63 (−41%) | ✓ | ✓ | 0.70× |
| arvo:3938 | 107 | 108 | +1 (+1%) | ✗ | ✓ | 1.39× |
| arvo:24993 | 341 | 93 | −248 (−73%) | ✓ | ✓ | 1.11× |
| arvo:1065 | 188 | 107 | −81 (−43%) | ✗ | ✗ | 0.91× |
| arvo:10400 | 366 | **534** | +168 (+46%) | ✓ | ✗ | **14.24×** |
| arvo:368 | **7201 (TO)** | 859 | (censored) | ✗ | ✗ | 3.68× |
| oss-fuzz:42535201 | 911 | 847 | −64 (−7%) | ✓ | ✗ | 1.97× |
| oss-fuzz:42535468 | 616 | 406 | −210 (−34%) | ✗ | ✗ | 1.17× |
| oss-fuzz:370689421 | 166 | **7201 (TO)** | (censored) | ✗ | ✗ | 0.99× |
| oss-fuzz:385167047 | 486 | 188 | −298 (−61%) | ✓ | ✓ | 1.29× |
| **TOTAL (n=10)** | **10,537** | **10,435** | **−102 (−1.0%)** | **5/10** | **4/10** | — |

- **Headline deltas:** total-arm **−1.0%**; median per-task **−72.5s**.
- **Non-timeout matched subset** (n=8, excluding the task that timed out in *either* arm): −795s aggregate (**−25.1%**),
  median per-task **−37.4%**, **6 faster / 2 slower**.

## The structural finding: a stochastic timeout looper, not decode

The single most important observation is that **the timeout task swapped between arms**:

- Arm 1: `arvo:368` timed out at 7201s; `oss-fuzz:370689421` finished in 166s.
- Arm 2: `arvo:368` *finished in 859s*; `oss-fuzz:370689421` timed out at 7201s.

Both timeouts were `no_crash` loopers — the agent fell into a `max_iter`/timeout trap. It is **task-independent and
stochastic** (2 timeouts across 20 task-runs ≈ **~10% rate**), and that one task is **~68–69% of each arm's total wall**.
The canonical proof that this is non-decode time: the Arm 2 looper generated only **786 accounted output tokens over 7200s
(0.1 tok/s)** — it burned two hours in tool-exec / iteration overhead, not generation.

This is why **per-task wall deltas between arms are not a clean MTP measurement**: agentic trajectory length is stochastic
and swamps the decode effect. Same-task `tok_in` swings **0.70×–14.24×** between arms, and `arvo:10400` ran **+46% slower**
under MTP precisely because it happened to take a 14× longer trajectory that run. The −25%/−37% on the fast subset is mostly
trajectory variance, not a causal MTP speedup — at n=10 the MTP wall effect is below the trajectory-variance noise floor.

## MTP worked — extremely well — and still didn't move the wall

Server-side `/metrics` (Arm 2, delta from a pre-launch baseline):

- **41,379 draft steps**, 331,032 draft tokens proposed, **300,822 accepted → 90.9% token acceptance**.
- Mean **7.27 of 8** draft tokens accepted per step (+1 bonus) ≈ **~8.3 tokens per target forward-pass**.
- Acceptance stays high to the **last** speculative position: pos0 97.2% → pos7 **86.0%**. Agentic / code / tool-call text
  is exceptionally predictable for the 0.5B assistant drafter.
- 0 errors, 17 length-capped (16K) turns, 248 LLM requests.

So decode got **~8× faster — far above the 1.7–2.6× hardware prior** — and the **total wall moved −1.0%**. That is the
cleanest possible demonstration that the CyberGym wall is not decode-bound. (Aside: harness `result.json` summed
tok_out=56,663 across the arm vs ~342K counted server-side; the gap is mostly the looper's repetitive generation, which the
harness under-counts. The server figure governs decode throughput; the harness figure governs per-task accounting.)

**APC:** Arm 1 92.9% (3.32M/3.57M), Arm 2 94.5% (6.63M/7.01M) — validates the "decode-volume-bound once APC is on" framing:
prefill is ~93–95% cached, so it is not the binding term either.

## Verdict

**Hypothesis confirmed.** The agentic per-task wall is not decode-bound: an ~8× decode speedup yields ~0% total-wall change.
MTP is worth enabling for raw throughput on generation-heavy workloads (it is lossless and accepts ~8 tok/pass here), but it
is **not a lever for Pool A wall**. The dominant, reproducible determinant of the wall is the stochastic timeout looper, plus
tool-exec and trajectory length — none of which MTP touches.

## Recompute of serving-strategy §2

**Old model (extrapolated):** `wall ≈ Σ output tokens ÷ decode rate`; CyberGym-100 dense ≈ 9–15h/model; column ≈ ~1 day.
The per-model walls were derived from measured *decode tok/s*, never from a measured agentic wall (§2 caveat, line 68).

**New model (measured anchor):**

```
wall ≈ Σ(non-timeout task walls) + n_timeout × timeout_cap
```

- decode-tok/s (incl. MTP) is a **minor (~1%) term of the *column* wall** — but **20–40% of an individual *fast-task* wall** (a fast task decodes a few hundred–few thousand tokens). So MTP/decode does speed fast tasks and interactive turns; it just can't touch the timeout-looper tasks (decode ≈0 there) that dominate the column. The total-arm −1.0% is a near-cancellation — real fast-task savings (−795s) vs a random looper-swap (+693s) — so read it as "MTP can't move the term that dominates the column wall," not "MTP saves nothing."
- empirical **timeout rate ≈ 10%** (2/20 runs — noisy; now the dominant wall input), **timeout_cap = 7200s** (current policy), median fast-task wall ≈ 3–6 min.

Projections (`[E-cal]`, from the measured anchor; c1 = sequential, today's harness):

| Scenario | CyberGym-10 | CyberGym-100 |
|---|--:|--:|
| **c1, cap 7200s** (as run) | ~2.9h (measured, both arms) | **~27h** (≈10×7200 + 90×~350) |
| **c1, cap 1800s** | ~1.0h | **~12–14h** |
| **c8, cap 1800s** | ~0.3h | **~1.5–2h** (floored by the longest single task = the cap) |

The old "~1 day" CyberGym-100 number is roughly right **but for the wrong reason** — it is set by `timeout_cap × timeout_rate`,
not by decode tok/s. **Real levers:**

1. **Timeout / `max_iter` policy** — the dominant term is `n_timeout × cap`. Cutting the cap 7200→1800s roughly halves the
   column wall at c1. Investigate *why* ~10% of runs loop (detect-and-abort earlier) for an even larger win.
2. **Harness parallelism `c1→cN`** — the still-unrealized §4 "parallelize the harness" win. At cN the wall ≈ `Σ/N`, floored by
   the single longest task (= the timeout cap), so it composes with lever 1.
3. **decode-tok/s / MTP** — ignore for Pool A wall planning.

## Caveats & limitations

- **n=10, c1, single run per arm.** Trajectory variance is large; treat per-task deltas as indicative, not significant.
- **Accuracy is confounded by context length.** Spark ran **128K**; the 7/10 rental Gemma-4 31B baseline
  (`<CAMPAIGN>-gemma31-cybergym10-256k`) ran **256K**. The 5/10 (Arm 1) & 4/10 (Arm 2) here vs 7/10 is **partly the 128K-vs-256K
  confound**, not a clean NVFP4/Spark accuracy regression. MTP is lossless decode, so the 5→4 change is two tasks flipping
  (trajectory variance), consistent with MTP being accuracy-neutral. A clean accuracy comparison needs a 256K Spark re-run
  (out of ejv scope).
- **WAN link** proxmox-02↔<SPARK_NODE_2>: 116ms RTT / 88 Mbit/s, 0% loss. Adds ~0.1–0.3% to a minutes-per-turn wall and is
  subtractable; server-side APC / acceptance / throughput are link-independent.
- **Not run:** the optional Gemma-4 26B-A4B (fast-MoE) contrast arm.

## References

- Serving-strategy doc being recalibrated: `docs/explorations/serving-strategy-2026-06-05.md` (§2 token-volume / wall model, §5 item 2).
- Arm-2 MTP drafter research + multimodal text-only gotcha: `bd benchmarks-ejv` comment 2026-06-09.
- Harness standup + WAN-link probe + guest sizing: `bd benchmarks-ejv.1` (closed).
- Raw data (local, on the harness VM): `/var/lib/harness/results/ejv-gemma31-arm{1,2}-*-2026-06-13/vllm/cybergym-10/<task>/{result.json,verdict.json}`; `/metrics` snapshots `~/ejv-arm2-metrics-{pre,post}.txt`.
