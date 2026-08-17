# <CAMPAIGN> Pool B post-mortem — Qwen3-235B-Thinking-AWQ on RTXPro6000x2

**Outcome**: 0/3 benches passed. ~$46 spent. **No bench numbers recovered.**

## Timeline (UTC, 2026-05-15)

| Time | Event | Note |
|---|---|---|
| 06:12 | Runcrate instance `837828ec-…` provisioned | RTXPro6000x2, KC, $3.94/hr |
| 06:25 | vLLM 0.21.0 starts (Stage 6) | model download + load |
| 06:33 | vLLM ready, /v1/models 200 | 11min total infra setup |
| 06:35 | Pool B attempt #1 starts (num_concurrent=1) | serial → ETA 3h for humaneval+ |
| 06:37 | Killed + hot-patched run-pool-b.sh to num_concurrent=8 | sed-patch on harness; **NOT committed** |
| 06:37 | Pool B attempt #2 starts; humaneval+ at 89.8 tok/s × 8 conc | |
| 07:07 | **humaneval+ FAILS** | filter NoneType crash; bumped max_gen_toks 2048→8192 |
| 07:10 | Pool B attempt #3 starts (--force, 8K humaneval+, 4K ifeval) | |
| 08:25 | **humaneval+ FAILS AGAIN** | same NoneType crash; avg 3844 toks/call, hard problems still trunc |
| 08:25 | ifeval starts (4K budget) | |
| 09:41 | **ifeval FAILS** | NoneType crash, but in **lm-eval upstream** tasks/ifeval/utils.py:43 |
| 09:42 | bcb-hard starts | **serial** — 285s/iter, ETA 12h |
| 09:something | Commit `5e7dcf1` (humaneval+ filter None-tolerance) | landed after both humaneval+ attempts failed; can't help in-flight |
| ~17:53 | **bcb-hard FAILS** after 8h 11min | bigcodebench sanitize.py crash on truncated `code_ext` |
| 17:55 | Pool B exits passed=0/3 | rental still up, no auto-teardown |
| 17:55 | I notice, DELETE rental | 11h 43min rental wall × $3.94 = **$46.10** |

## The actual root cause (corrected after operator review)

**This was my error in the spec, not a class-wide "reasoning models break Pool B" problem.** Other thinking-capable models we've run Pool B against (<CAMPAIGN> Qwen3.6-35B-A3B, <CAMPAIGN> Nemotron-3-Super, <CAMPAIGN> Qwen3.5-122B-A10B, opus47, gpt55) **all** passed Pool B because their vLLM serve config sets `'{"enable_thinking": false}'`. The reasoning training is in the model weights either way; that flag controls whether the model emits `<think>...</think>` sentinel structure.

For <CAMPAIGN> I set `'{"enable_thinking": true}'` because the model is named "Thinking" — that was the wrong call. The Thinking variant still scores well *without* emitting `<think>` blocks; the weights have the reasoning training baked in. The Qwen3 family convention across our other specs is `enable_thinking: false` regardless of the variant label.

**Mechanism of the failure when `enable_thinking=true` + `reasoning_parser=qwen3`**:
- Model emits `<think>...</think>` then the answer.
- vLLM splits at the sentinels: `response.reasoning` gets the think text, `response.content` gets the post-think answer.
- If `max_gen_toks` hits *during* the think section, the answer never gets emitted → **`response.content = None`**.
- Every Pool B scorer assumed `content` is always a non-None string.

When `enable_thinking=false` (the convention):
- Model still has its reasoning training (weights unchanged) but doesn't emit sentinels.
- `response.content` always has whatever the model produced — partial string on truncation, never None.
- Pool B scorers see a string and grade it (low score on truncation, but no crash).

So the proximate fix is one line in `scripts/rental-specs/qwen3-235b-thinking-awq.yaml`: flip `enable_thinking: true` → `false`. The None-tolerance defensive patches below are still worth landing for resilience, but they aren't blocking.

### Three blast zones (still real, less catastrophic with the spec fix)

| Layer | File | Line | Crash |
|---|---|---|---|
| Pool B humaneval+ filter (our code) | `scripts/runners/lm-eval-tasks/utils.py` | 52 | `_CODE_BLOCK_RE.search(None)` → `TypeError: expected string or bytes-like object, got NoneType` |
| Pool B ifeval scorer (lm-eval upstream, vendored) | `lm_eval/tasks/ifeval/utils.py` | 43 | `response.strip()` → `AttributeError: 'NoneType' object has no attribute 'strip'` |
| Pool B bcb-hard sanitize (bigcodebench upstream, pip) | `bigcodebench/sanitize.py` | 112 | `code = code_ext` after `extract_target_code_or_empty(None, ...)` — truncated/empty code → can't extract entrypoint |

**Single None response anywhere in the batch crashes the whole bench**, throwing away the other 99% of responses. This is the same V0-bug-shape we cataloged in `feedback_pool_a_grading_audit.md` (silent-failure-via-crash).

## Token data we DO have

| Bench | calls | prompt_tokens | completion_tokens | avg out | wall (gen) |
|---|---|---|---|---|---|
| humaneval+ #2 | 164 | 31,196 | 630,334 | **3844** | 1h 14min |
| ifeval | 541 | 29,426 | 683,714 | **1263** | 1h 16min |
| bcb-hard | unknown | unknown | unknown | n/a | 8h 11min (before crash) |

**Insight**: humaneval+'s 3844 avg means *some* problems used FAR more than 3844 — likely 6-8K, which still hit even our bumped 8K cap. Reasoning models can blow through any fixed token budget; the right solution is graceful None-handling, not bigger budgets.

## Secondary findings

1. **Pool B num_concurrent hardcoded to 1.** vLLM was idle 7/8 of the time during attempt #1. Hot-patch (`num_concurrent=8` in `build_model_args`) gave 3x speedup. **Not committed** — sed-patched on harness only. Reverts on next install-harness boot. Needs a `--vllm-num-concurrent` CLI knob.
2. **bigcodebench openai backend is serial** (no `--parallel` flag in the installed version). At 285s/iter × 148 problems = 12h. This is the dominant rental cost for reasoning models. Options for future: vendor a forked bcb with parallelism, skip bcb-hard for reasoning models, or use bcb's local backend pointing at the vLLM rental.
3. **No watchdog on Pool B total failure.** When all 3 benches return exit 1, run-pool-b.sh records markers and returns 1, but the rental keeps running. The rental burned ~9h ($35) after Pool B exited the first bench. **Need either**: (a) `rental-vllm-down.sh` auto-call on Pool B exit, (b) operator monitoring discipline.
4. **lm-eval default `max_gen_toks` values are too tight for reasoning models**. humaneval_plus_chat=2048, ifeval=1280. Both should be ≥4K (better 8-16K) for any model that emits reasoning chains. The hot-patches I applied on the harness aren't in the repo yet.
5. **Hot-patches DON'T survive install-harness re-run.** Three patches (num_concurrent, humaneval+ max_gen_toks, ifeval max_gen_toks) were sed'd onto harness disk. Only the humaneval+ filter fix made it into a git commit. Everything else is gone if the harness re-boots.

## What's recoverable

**Nothing for benchmark numbers.** All three raw output dirs are empty:
- `bcb-raw/bcb_results/` — 0 files (sanitize crashed mid-loop; no atomic write)
- `humaneval-plus/lm-eval-raw/` — 0 files (lm-eval crashed during filter)
- `ifeval/lm-eval-raw/` — 0 files (lm-eval crashed during scoring)

Only artifacts: `usage.json` (token counts), `results.json` (failure stacks), and `/var/log/harness-runner.log` (58 <CAMPAIGN> lines). All pulled to `/tmp/<CAMPAIGN>-postmortem/`.

## Spend accounting

| Phase | Cost |
|---|---|
| Provision + vLLM cold start (06:12 → 06:33) | $1.40 |
| Useful Pool B time (humaneval+ #1, #2, ifeval, partial bcb-hard) — model produced real outputs, scorers just couldn't consume them | ~$32 |
| Idle after Pool B exit at 17:55 (no auto-teardown — I caught it 0min later but PRIOR Pool B exit happened at 17:53) | negligible |
| **Total** | **~$46** |

The headline framing — "we paid $46 for 0 bench results" — is technically true but misleading. The model DID produce ~1.3M completion tokens of real output, just spread across 3 different scorers all of which crashed on the FIRST None response. With the patches below applied, the same generate cost would have yielded 3 valid Pool B scores.

## Next-session priorities

In order of leverage:

1. **[BLOCKING] Flip `enable_thinking: true` → `false` in `scripts/rental-specs/qwen3-235b-thinking-awq.yaml`.** One-line fix; matches Qwen3 family convention across <CAMPAIGN>/.8/.9. Without this, every retry hits the same failure mode regardless of how many defensive patches we ship.
2. **Add `--rental-down-on-failure` to `run-pool-b.sh`.** Currently Pool B's EXIT trap only syncs to S3. The rental burned ~$35 of idle time *after* Pool B exited the first failed bench. This is the single biggest source of operator-monitoring tax. Lands cleanly.
3. **Convert `num_concurrent=8` hot-patch into a proper `--vllm-num-concurrent N` CLI knob on `run-pool-b.sh`.** Default 1 for backwards compat. The hot-patch isn't committed and reverts on install-harness re-run.
4. **None-tolerance defensive patches** — copy/vendor `lm_eval/tasks/ifeval/utils.py` to `scripts/runners/lm-eval-tasks/` with a None check at line 43. Wrap `bigcodebench/sanitize.py` calls to skip None inputs. These prevent a single truncated response from killing the whole bench even on non-reasoning-mode runs.
5. **Bump `max_gen_toks` defaults** in `scripts/runners/lm-eval-tasks/humaneval_plus_chat.yaml` to 4096 (current 2048 is tight for any modern model). Vendor a copy of ifeval.yaml with `max_gen_toks: 4096`.
6. **bcb-hard parallelism** — bigger work item; might be skipped for the Thinking variant entirely. Decide once (1)-(5) are landed.

After (1) alone, re-run <CAMPAIGN> should produce real Pool B numbers. Estimated cost: ~$8-12 (vLLM cold start cached, model weights cached in HF cache on next provision if same region, but new rental = redownload — call it $12-15 for the new rental's full life-cycle). (2)-(5) reduce the *next* unexpected failure's tax; (1) is the only thing blocking actual numbers from this model.
