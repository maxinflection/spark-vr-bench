# VibeThinker-3B tiny-model floor experiment (2026-06-24)

**bd:** `benchmarks-sqa` · **branch:** `benchmarks-sqa-vibethinker-poolb` · **operator:** max

Off-roster probe of the *lower bound* of a tiny reasoning model:
[WeiboAI/VibeThinker-3B](https://huggingface.co/WeiboAI/VibeThinker-3B)
([paper](https://arxiv.org/abs/2606.16140)). Not an rlp candidate; deliberately
kept off the main `sweep-status.md` board (this note is the record).

## Model

- 3B params, **Qwen2.5-3B / Qwen2.5-Coder-3B** base (`model_type=qwen2`), **BF16**.
- `max_position_embeddings=131072`, `rope_scaling=null` → native 128K context, no
  scaling needed.
- Reasoning model: emits literal `<think>…</think>` then the answer (DeepSeek-R1
  shape), even though its chat template adds no reasoning markers.
- Reported strengths: AIME-2026 94.3%, LeetCode contests 96.1% — a contest-style
  math/code specialist.

## Setup

- **Serve:** full-precision **BF16, no quantization** on an idle <SPARK_NODE_2> GB10
  (`vllm-spark:latest`, `--max-model-len 131072`, `--max-num-seqs 16`,
  `--reasoning-parser deepseek_r1`), served as `WeiboAI/VibeThinker-3B`.
  Script: `scripts/serve-vibethinker-poolb.sh`.
- **Drive:** `run-pool-b.sh` on the ejv harness VM → `socat` localhost hop →
  <SPARK_NODE_2>:8080. Greedy / board profile, `--vllm-eos-string '<|im_end|>'`,
  concurrency 16. Wrapper: `scripts/run-vibethinker-poolb-spark.sh`.
- The `deepseek_r1` parser yields clean `.content` for graders, matching how the
  board's other reasoning models are served (apples-to-apples) — this removed the
  IFEval reasoning-pollution risk that an un-parsed run would have had.

## Pool B results (16K budget, n as noted)

| Bench | VibeThinker-3B | Board context |
|---|---|---|
| HumanEval+ | **0.878** (n=164) | ≈ Qwen3.5-122B (0.884); > DeepSeek V4 Flash (0.835) |
| IFEval (prompt-strict) | **0.734** (n=541) | low; board pack ≈ 0.82–0.94 |
| BigCodeBench-Hard | **0.047** (n=148) | floor; board pack ≈ 0.26–0.51 |

Campaign `vibethinker3b-poolb-16k-2026-06-24` (in S3 `<RESULTS_BUCKET>`).
Walls: HE+ 1151s, IFEval 9724s, BCB 2167s (~3h40m). Decode-slow long-CoT on one
Spark.

**Caveats:** greedy decoding vs the card's recommended temp=1.0/top_p=0.95 (kept
greedy for board comparability); BF16 (no quant).

### Finding 1 — 16K is the true capability; the 40K cell is redundant
A 40K "true-ceiling" cell was planned to rule out truncation of the long CoT.
It was **deferred and is unnecessary**: BCB-Hard `null_rate = 0.0` (zero
truncated/None solutions at 16K) and HE+/IFEval are healthy, so the model
finishes its reasoning well within 16K on these benches. The 16K numbers are not
truncation-deflated. (The 40K path remains built — `run-vibethinker-poolb-spark.sh
40k` — if ever wanted for completeness.)

### Capability profile
A 3B that **rivals 100B+ models on self-contained, contest-style coding
(HumanEval+)** but **collapses on the harder, more realistic BigCodeBench-Hard**,
and trails mid-pack on instruction-following (IFEval). Strong where problems are
closed-form; weak where they require broader engineering.

## Pool A / CyberGym-10 → N/A (not 0/10)

Campaign `vibethinker3b-cybergym10-2026-06-24`. All 10 tasks terminated with
OpenHands **`AgentStuckInLoopError`** (`agent_state=error`), not a genuine
attempt-and-fail.

### Finding 2 — agentic-incompatible
VibeThinker emits **only chat `MessageAction`s (reasoning prose), never
tool/command actions**. OpenHands' stuck-detector kills each task after repeated
message-only turns. Per-task audit: ~75–168s wall, `tokens_in` pinned ~19,125
(no tool output ever varied the context), `no_poc_submitted`, `poc.db` 0 rows.
The runtime container started fine (the `404 No such container` in the wrapper log
is a benign post-run teardown query). A no-parser re-run would not help — the
turns are message-only either way. It is a math/code *completion* reasoner, not
agent/tool-trained, so **Pool A is N/A rather than a comparable `0.00` cell.**

## Takeaways

1. Tiny reasoning models can be shockingly strong on closed-form coding yet floor
   on realistic/hard tasks — capability is narrow, not uniformly low.
2. Reasoning-parser choice is task-dependent: `deepseek_r1` is correct for Pool B
   (clean graded `.content`) but irrelevant for agentic Pool A, where the real
   blocker is the absence of tool-action output.
3. Audit before reporting: the CyberGym `0/10` was an agent-error artifact, not a
   score — reporting it as a board cell would have been misleading.

## Reproduce / teardown

Serve `scripts/serve-vibethinker-poolb.sh` on <SPARK_NODE_2> (model cached at
`/opt/models/vibethinker-3b`), start the `socat` spark-fwd on ejv, run
`scripts/run-vibethinker-poolb-spark.sh 16k`. Teardown: `docker stop
vllm-poolb-vibethinker` on <SPARK_NODE_2> + kill the `spark-fwd`/`vibe-*` tmux on ejv.
(All torn down as of 2026-06-24; Spark idle.)
