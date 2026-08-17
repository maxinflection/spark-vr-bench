# BCB-Hard truncation audit under stale 8K/16K max_model_len rentals

**Issue**: `benchmarks-7ch` — Audit Pool B BCB-Hard scores for mid-code truncation under stale 8K/16K max_model_len specs.

**Date**: 2026-05-18

**Auditor sandbox constraint**: The agent runs as IAM user `benchmarks-sandbox-agent`, which has **no S3 permissions on `<RESULTS_BUCKET>`** (no ListBucket, no GetObject), and no path to assume the harness-driver role. Direct sampling of per-task generations was therefore impossible from inside this sandbox. The audit below is built from:

1. **Per-spec git history** — exact `max_model_len`, presence/absence of `--default-chat-template-kwargs '{"enable_thinking": false}'`, and other server-side flags as they were at each campaign date.
2. **Runner history** — `VLLM_BCB_MAX_TOKENS` evolution and the load-bearing fact that `bigcodebench.generate` uses its own openai client (NOT litellm), so `--vllm-extra-body` does **not** reach BCB-Hard generations.
3. **Documented failure mode** in `bd <ISSUE>` (<CAMPAIGN> third attempt) and `docs/research/<CAMPAIGN>-pool-b-postmortem-2026-05-15.md` — the canonical evidence that thinking-mode + reasoning-parser + insufficient output budget produces `response.content = None`, which the `[bcb-none-filter]` (run-pool-b.sh:1035) converts to empty string → task fails.
4. **Cross-campaign score ratios** in `docs/results/criterion-matrix-bigcodebench-hard.md` and `docs/results/sweep-status.md`.

A follow-up sample-level audit on S3 (or via the harness driver) is the only way to compute exact per-task truncation rates; see "Re-audit recommendation" at the bottom.

## Key control: how BCB-Hard reaches the model

| Setting | Source | Reaches BCB? | Notes |
|---|---|---|---|
| `--default-chat-template-kwargs '{"enable_thinking": false}'` | rental spec yaml (`vllm_args`) | **YES** (server-side, every request) | Only way to suppress thinking-mode on BCB |
| `--reasoning-parser qwen3` (or similar) | rental spec yaml | **YES** (server-side) | Splits `<think>` into `reasoning_content`, leaving `content` empty if truncation occurs inside the think block — becomes `None` |
| `LM_EVAL_VLLM_EXTRA_BODY={...}` env (per-request `extra_body`) | runner `--vllm-extra-body` flag, threaded via `_litellm_patches._inject_extra_body` | **NO** for BCB | bigcodebench bypasses litellm; this only applies to humaneval-plus / ifeval (lm-eval path) |
| `--max_new_tokens N` | runner `VLLM_BCB_MAX_TOKENS` (default `4096` since 2026-05-10; **1280** before that) | YES | bigcodebench-side cap on output tokens |
| Server `max_model_len` | rental spec yaml | YES | Hard upper bound on prompt + completion. Below this, vLLM rejects requests or truncates. |

**Implication**: For BCB-Hard, thinking-mode is governed by the server-side flag ONLY. If the spec lacks it (Nemotron <CAMPAIGN>, both Gemma <CAMPAIGN>/.7 specs at the time, and the first two <CAMPAIGN> attempts), the model emits `<think>...</think>` AND the parser separates it, leaving `content=None` whenever the think block is the part that hit `max_new_tokens`.

## Per-campaign state at run time

Reconstructed from `git show <spec-commit>:scripts/rental-specs/<spec>.yaml`.

| Campaign | Date | Spec used (commit) | `max_model_len` | `enable_thinking` flag in spec? | `reasoning-parser` flag? | `VLLM_BCB_MAX_TOKENS` |
|---|---|---|---|---|---|---|
| `<CAMPAIGN>-qwen36-27b-fp8` | 2026-05-09 to -10 (pre-`62l`) | `70fc699` / `941d958` | 16384 | **NO** | NO | **1280** (default; flag added 2026-05-10) |
| `<CAMPAIGN>-retry` | 2026-05-10 (post-`941d958`, pre-`62l`) | `941d958` | 16384 | **NO** | NO | 4096 |
| `<CAMPAIGN>-qwen36-62l-2026-05-11` | 2026-05-11 | `ece2a29` (62l fix) | 16384 | **YES** | YES (`qwen3`) | 4096 |
| `<CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12` | 2026-05-12 | `d2849b0` | 16384 | YES | YES (`qwen3`) | 4096 |
| `<CAMPAIGN>-gemma31-2026-05-11` | 2026-05-11 | `88342eb` | **8192** | NO (Gemma defaults thinking-off per `rlp.1vp`) | NO | 4096 |
| `<CAMPAIGN>-gemma4-31b-it-nvfp4` | 2026-05-11 (duplicate?) | `88342eb` | **8192** | NO (Gemma default off) | NO | 4096 |
| `<CAMPAIGN>-gemma4-26b-a4b-nvfp4` | 2026-05-12 | `88a5d38` (initial) | **8192** | NO (Gemma default off) | NO | 4096 |
| `nemotron-3-super-nvfp4-2026-05-12` (v1) | 2026-05-12 | `5bc3986` | **8192** | **NO** (defaults to TRUE per ChatML template) | NO | 4096 |
| `nemotron-3-super-nvfp4-2026-05-12-v2` | 2026-05-12 | `5bc3986` | **8192** | **NO** (defaults to TRUE — v2 fixed only the lm-eval path) | NO | 4096 |

Spec-level `max_model_len` was bumped 8192/16384 → 65536 in commit `33169f7` (2026-05-14), AFTER every campaign in this table. The 65536 → 131072 (128K) bump happened in `1293125` (2026-05-17).

## Per-campaign truncation risk assessment

| Campaign | Model | Pass@1 | Risk score | Mechanism |
|---|---|---|---|---|
| `<CAMPAIGN>-qwen36-27b-fp8` | Qwen3.6-27B FP8 | **0.0338** | **CONFIRMED truncation** | thinking-on + reasoning-parser + 1280-token cap. `bd <ISSUE>` close-notes document this exact regression. Score is so low precisely because nearly all responses had `content=None`. |
| `<CAMPAIGN>-retry` | Qwen3.6-27B FP8 | **0.1351** | **CONFIRMED truncation** | thinking-on + reasoning-parser + 4096-token cap. Still routinely truncates inside think blocks. `bd <ISSUE>` ROOT-CAUSE section names this run explicitly: *"Qwen3.6's thinking-mode preamble still consumes the generation budget on bigcodebench codegen, truncating code mid-function."* |
| `<CAMPAIGN>-qwen36-62l-2026-05-11` | Qwen3.6-27B FP8 | 0.3041 | LOW (already re-run) | This is the post-fix run. Spec has `enable_thinking=false` server-side + 16K context. Use this as the canonical <CAMPAIGN> number. |
| `<CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12` | Qwen3.6-35B-A3B | 0.3243 | LOW | Spec had `enable_thinking=false` server-side from day 1 (`d2849b0`). 16K context, 4K output, ~1-3K prompts — comfortable. |
| `<CAMPAIGN>-gemma31-2026-05-11` | Gemma 4 31B | 0.2905 | **MODERATE** | 8K context, 4K output. Gemma chat template defaults thinking-off (per `bd <ISSUE>`), so no thinking blowup, BUT 8192 - 4096 = 4096 tokens of prompt headroom. BCB-Hard prompts ~1-3K plus chat template wrapper ~200-400 tokens — fits, but no slack for the longest prompts. Probable mid-code truncation on a tail of tasks. |
| `<CAMPAIGN>-gemma4-31b-it-nvfp4` | Gemma 4 31B | 0.3041 | MODERATE | Same as <CAMPAIGN>-gemma31; results overlap within noise. |
| `<CAMPAIGN>-gemma4-26b-a4b-nvfp4` | Gemma 4 26B-A4B | 0.2635 | **MODERATE-HIGH** | Same 8K/4K setup. The lower headline score (0.264 vs Gemma 31B 0.290–0.304, and 0.115pp lower than <CAMPAIGN>'s own HumanEval+ vs <CAMPAIGN>) suggests the smaller model may have generated longer code on average, exceeding the budget more often. |
| `nemotron-3-super-nvfp4-2026-05-12` (v1) | Nemotron 120B-A12B | **0.3311** | **HIGH — confirmed thinking-on contamination** | The v1 campaign was the one where the tmux-quoting bug stripped `enable_thinking=false` from the extra_body. Per <CAMPAIGN> close-notes: humaneval+ samples had 95% `</think>` traces, ifeval 75%. BUT extra_body doesn't reach BCB anyway, so even the v2 run is contaminated for BCB-Hard. |
| `nemotron-3-super-nvfp4-2026-05-12-v2` | Nemotron 120B-A12B | **0.3176** | **HIGH — same root cause as v1 on BCB** | v2 fixed the lm-eval-path extra_body but NOT the BCB path. Spec still lacks `--default-chat-template-kwargs`, so the Nemotron ChatML default (`enable_thinking=true`) burns the 4K output budget inside `<think>...</think>` for any task where the think block exceeds ~3.5K tokens. Note that BCB-Hard 0.32 ≈ same as gpt55 (0.32), which is suspiciously coincidental and may mean: *the surviving 32% are the tasks where Nemotron's think block was short enough to fit*. |

## Example truncation excerpts

Direct excerpts from per-task `samples.jsonl` are not retrievable from this sandbox (no S3 GetObject permission). The `bd <ISSUE>` close-notes contain the canonical example of the failure mode for Qwen3.6-27B:

> The 941d958 thinking-mode fix forwarded `chat_template_kwargs` via per-request `extra_body` through a litellm monkey-patch. That covers lm-eval / litellm paths. But bigcodebench has its OWN openai client (`python -m bigcodebench.generate --backend openai`), bypassing litellm entirely. Our extra_body patch is never seen by bigcodebench. So Qwen3.6's thinking-mode preamble still consumes the generation budget on bigcodebench codegen, truncating code mid-function. Result: <CAMPAIGN> retry BCB-Hard = 0.1351, vs Gemma's 0.3041 and Qwen3.6's public LiveCodeBench pass@1 of 0.89.

And the <CAMPAIGN> post-mortem (2026-05-15) documents the exact mechanism for Qwen3 thinking-on + reasoning-parser + truncation:

> When `max_gen_toks` hits *during* the think section, the answer never gets emitted → `response.content = None`. Every Pool B scorer assumed `content` is always a non-None string.

The `[bcb-none-filter]` block in `scripts/runners/run-pool-b.sh:1035-1054` confirms this is the BCB-Hard symptom: per-task `null_solutions` are counted and replaced with empty string, which the docker eval grades as `SyntaxError` (failure). The actual count per campaign is logged only to `harness-runner.log` on the rental host — long discarded — not to S3 `result.json`. **This is itself a gap to fix**; see "Follow-up items" below.

## Verdict per model (BCB-Hard only)

| Model | Best-of campaign on dashboard | Verdict | Recommended action |
|---|---|---|---|
| Qwen3.6-27B FP8 (<CAMPAIGN>) | `<CAMPAIGN>-qwen36-62l-2026-05-11` (0.3041) | **KEEP best-of as canonical** — the 0.034 / 0.135 runs are documented thinking-on regressions, already superseded by the post-62l run | Already re-run; sweep-status uses 0.304. No action. |
| Qwen3.6-35B-A3B FP8 (<CAMPAIGN>) | `<CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12` (0.3243) | **KEEP** | Spec had the right flags from day 1; 16K context comfortable. No re-run. |
| Gemma 4 31B (<CAMPAIGN>) | `<CAMPAIGN>-gemma4-31b-it-nvfp4` (0.3041) | **INCONCLUSIVE — re-run advised at 128K** | 8K context with no slack is a plausible source of tail-truncation. Realistic uplift estimate: +1 to +3pp. Cost: ~$5. |
| Gemma 4 26B-A4B (<CAMPAIGN>) | `<CAMPAIGN>-gemma4-26b-a4b-nvfp4` (0.2635) | **REDO at 128K** | Same 8K/4K setup as <CAMPAIGN>. Lower score + smaller model → larger tail of mid-code truncations more likely. Realistic uplift estimate: +1 to +5pp. Cost: ~$5. |
| Nemotron 3 Super 120B-A12B (<CAMPAIGN>) | `nemotron-3-super-nvfp4-2026-05-12-v2` (0.3176) | **REDO at 128K with `--default-chat-template-kwargs '{"enable_thinking": false}'` in spec** | The current score is contaminated by thinking-on on BCB-Hard. Same fix as `bd <ISSUE>` applied to Qwen3.6-27B; expect symmetric uplift (Qwen3.6-27B went 0.135 → 0.304 with the fix — a +17pp delta). Realistic uplift estimate: **+5 to +15pp**. Cost: ~$16 (Nemotron is the most expensive of the five). |

## Final recommendation

**Two campaigns clearly need a re-run, one is borderline:**

1. **MUST REDO — `nemotron-3-super-nvfp4-2026-05-12-v2`** (<CAMPAIGN>): The spec is missing `--default-chat-template-kwargs '{"enable_thinking": false}'` and `--reasoning-parser` (if applicable for Nemotron — its `<think>` sentinels are emitted via the ChatML template, not Qwen's reasoning-parser, so vLLM's `--reasoning-parser deepseek_r1` or similar may be needed; verify before re-run). BCB-Hard is currently scoring against tasks where the model's think block happened to fit in <4K tokens. The fix is the same shape as `bd <ISSUE>`. **Filing this as a high-priority re-run.**

2. **SHOULD REDO — `<CAMPAIGN>-gemma4-26b-a4b-nvfp4`** (<CAMPAIGN>): 8K total context with 4K output cap leaves only ~4K for prompts that can run 3K + 200-token chat template overhead. A bcb-none-filter sample would confirm in <1 minute on the harness driver; without that, the 0.264 score is suspect.

3. **NICE-TO-HAVE — `<CAMPAIGN>-gemma4-31b-it-nvfp4`** (<CAMPAIGN>): Same setup, slightly less concerning. If the Gemma 26B-A4B re-run shows non-trivial uplift, do this one in parallel.

**Do NOT redo:**
- <CAMPAIGN> (already has the canonical 62l run).
- <CAMPAIGN> (clean spec from day 1).
- <CAMPAIGN>-qwen36-27b-fp8 and <CAMPAIGN>-retry (historical; superseded).

**Cost estimate for re-runs**: $5 (<CAMPAIGN>) + $5 (<CAMPAIGN>) + $16 (<CAMPAIGN>) = ~$26 to settle the question. All single-bench BCB-Hard runs; HumanEval+ and IFEval do not need re-running (they were on the lm-eval path and got the extra_body fix where applicable).

## Follow-up items (for the parent agent to file as bd issues)

These were observed during the audit but are out of scope for `benchmarks-7ch`:

1. **Telemetry gap**: the `[bcb-none-filter]` `null_solutions / total` counts are logged only to `harness-runner.log` on the rental host and are lost at teardown. They should be persisted to `result.json` so future audits don't need to re-fetch sample JSONL. File against <CAMPAIGN> family.

2. **Sandbox IAM gap**: the `benchmarks-sandbox-agent` IAM user has no `GetObject` on `s3://<RESULTS_BUCKET>/*`. This blocks every audit task from being completable in-sandbox. A read-only `s3:GetObject` policy on the results bucket (scoped to the agent user) would unblock this without giving up bucket isolation. File against rlp tooling.

3. **Nemotron BCB-Hard thinking-off**: the spec needs `--default-chat-template-kwargs '{"enable_thinking": false}'` (and possibly `--reasoning-parser`) added regardless of the re-run decision — for the next time someone benches it. This is a clean spec fix, no rental needed.

## Re-audit recommendation

If a sample-level re-audit is desired (cheap to do from the harness EC2 box where the driver role IS available), the exact procedure is:

```bash
# From an instance with harness-driver-role (or any identity that can GetObject on the bucket):
for campaign in <CAMPAIGN>-gemma31-2026-05-11 <CAMPAIGN>-gemma4-31b-it-nvfp4 <CAMPAIGN>-gemma4-26b-a4b-nvfp4 \
                nemotron-3-super-nvfp4-2026-05-12 nemotron-3-super-nvfp4-2026-05-12-v2 \
                <CAMPAIGN>-qwen36-27b-fp8 <CAMPAIGN>-retry <CAMPAIGN>-qwen36-62l-2026-05-11; do
  echo "=== $campaign ==="
  aws s3 sync "s3://<RESULTS_BUCKET>/$campaign/vllm/bigcodebench-hard/bcb-raw/bcb_results/" \
              "/tmp/bcb-audit/$campaign/" --exclude "*" --include "*sanitized_calibrated.jsonl"
done
# Then per-jsonl:
python3 - <<'PY'
import json, pathlib
for jsonl in pathlib.Path("/tmp/bcb-audit").rglob("*sanitized_calibrated.jsonl"):
    n_none, n_short, n_total = 0, 0, 0
    for line in jsonl.open():
        rec = json.loads(line)
        n_total += 1
        sol = rec.get("solution")
        if sol is None or sol == "":
            n_none += 1
        elif isinstance(sol, str) and not sol.rstrip().endswith(("pass", "return", "}", ")")) and len(sol) > 200:
            # Heuristic for mid-function truncation: long string ending in mid-statement.
            n_short += 1
    print(f"{jsonl.parent.parent.parent.name}: none={n_none}/{n_total} truncated={n_short}/{n_total}")
PY
```

This would produce the exact truncation rates that this sandbox-based audit could only estimate.
