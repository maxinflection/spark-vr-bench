# <CAMPAIGN> Pool A thinking-mode audit — 2026-05-19

Synthesis of four parallel Explore subagents (per-campaign mode evidence, vLLM parser matrix, rental spec compliance, per-turn token budget). Pool B audit deferred per operator direction; Pool A is the priority. Cross-references `bd memory thinking-mode-policy-2026-05-19`.

## Headline

**The cybergym runner caps OpenHands at 2048 output tokens per turn**, so every Pool A cybergym campaign — including the ones labeled "thinking-on" — was silently bandaged at the runner layer. The model literally couldn't fit reasoning + a tool call in 2K. This explains why `<CAMPAIGN>` Qwen3.6-27B cybergym scored 0.200 in BOTH spec-level modes: both were really measuring agentic capability at thinking-off-effective budget. The fix lives in `bd <ISSUE>` (cybergym `--max-output-tokens 16384`), which is the **hard prerequisite for every Pool A re-run under <CAMPAIGN>**.

## Per-cell actual mode (correcting Subagent 1's logic errors)

| Model | Pool A cell | Spec-level thinking | Runner-level cap | Effective mode |
|---|---|---|---|---|
| <CAMPAIGN> Qwen3.6-27B Dense | cybergym | dual-mode published (both 0.200) | 2K OH default | **runner-bandaged** regardless of spec |
| <CAMPAIGN> Qwen3.6-27B Dense | sec-bench | thinking-on | smolagents (no per-turn cap) | thinking-on, real |
| <CAMPAIGN> Qwen3.6-35B-A3B | cybergym | thinking-off (spec bandage) | 2K | thinking-off, runner-capped |
| <CAMPAIGN> Qwen3.6-35B-A3B | sec-bench | thinking-off (spec bandage) | smolagents | thinking-off, real |
| <CAMPAIGN> Gemma-4 31B | cybergym | thinking-off (Gemma chat-tpl default) | 2K | thinking-off, runner-capped |
| <CAMPAIGN> Gemma-4 31B | sec-bench | thinking-off | smolagents | thinking-off, real |
| <CAMPAIGN> Gemma-4 26B-A4B | cybergym | thinking-off | 2K | N/A (bd <ISSUE> — tool-call schema failure unrelated to thinking) |
| <CAMPAIGN> Gemma-4 26B-A4B | sec-bench | thinking-off | smolagents | thinking-off, real |
| <CAMPAIGN> Nemotron-3 Super | — | — | — | not yet run |
| <CAMPAIGN> Qwen3.5-122B | — | — | — | not yet run |
| <CAMPAIGN> Qwen3-235B-Thinking | — | — | — | not yet run |
| Opus 4.7 / GPT-5.5 (frontier) | cybergym 0.500 / 0.600 | reasoning-on (frontier default) | 2K | runner-bandaged — frontier cells also under-measured |

**Important corollary**: the frontier baselines (Opus 4.7, GPT-5.5) ALSO hit the 2K cap. Their reported cybergym cells under-measure them too. Re-running frontier post `bd <ISSUE>` is part of <CAMPAIGN> scope (frontier API spend ~$30-50 estimated).

## vLLM 0.21 parser matrix (verified by Subagent 2)

| Family | `--reasoning-parser` | `--tool-call-parser` | Confidence | Source |
|---|---|---|---|---|
| Qwen3.4 / 3.5 / 3.6 / 235B | `qwen3` | `qwen3_xml` | high | vLLM recipes + source; qwen3_xml is streaming-capable (preferred over qwen3_coder) |
| Gemma-4 (31B + 26B-A4B) | `gemma4` | `gemma4` | high | confirmed in `/opt/vllm-venv/lib/python3.10/site-packages/vllm/{reasoning,tool_parsers}/gemma4_*.py` on prior rental; reference template `scripts/rental-specs/gemma-4-26b-a4b-nvfp4.yaml` commit `4ae3508` |
| Nemotron-3 Super 120B-A12B | `nemotron_v3` | likely `qwen3_coder` (NVIDIA recipes) | **medium — needs live probe** | reasoning side confirmed (`docs/research/nemotron-thinking-template-2026-05-19.md`); tool-call side inferred from upstream NVIDIA Nemotron usage docs but not directly verified |
| DeepSeek-V4-Flash | `deepseek_v4` | `deepseek_v4` | medium (model not rented yet) | vLLM 0.21 source + DeepSeek-V4 blog post |
| Opus 4.7 / GPT-5.5 (frontier) | n/a | n/a | — | not served via vLLM |

## Spec compliance audit (Subagent 3, with my Nemotron correction)

Reference template: `scripts/rental-specs/gemma-4-26b-a4b-nvfp4.yaml` (commit `4ae3508`). Compliance against `bd memory thinking-mode-policy-2026-05-19`:

| Spec | Compliant? | Required additions |
|---|---|---|
| `gemma-4-26b-a4b-nvfp4.yaml` | ✓ | reference template |
| `gemma-4-31b-it-nvfp4.yaml` | ✗ | `--tool-call-parser gemma4` + `--enable-auto-tool-choice` |
| `qwen3.6-27b-fp8.yaml` | ✗ | `--tool-call-parser qwen3_xml` + `--enable-auto-tool-choice` |
| `qwen3.6-35b-a3b-fp8.yaml` | ✗ | same |
| `qwen3.5-122b-a10b-nvfp4.yaml` | ✗ | same |
| `qwen3-235b-thinking-awq.yaml` | ✗ | same |
| `qwen3-235b-thinking-awq-thinking-on.yaml` | ✗ | same |
| `nemotron-3-super-120b-a12b-nvfp4.yaml` | ✗ | `--reasoning-parser nemotron_v3` + `--tool-call-parser qwen3_coder` (live-probe verify) + `--enable-auto-tool-choice`. **NOT yet** removing the `enable_thinking=false` bandage — separate `-thinking-on.yaml` variant per dual-spec convention. |

All landings batched in `bd <ISSUE>`.

## Per-turn budget audit (Subagent 4)

| Runner | Per-turn cap | Source | Fits reasoning (≥16K)? | Fix |
|---|---|---|---|---|
| `run-pool-a-cybergym.sh` (OpenHands) | 2048 (OH default — no flag passed) | `build_openhands_argv()` line ~534-544 | **NO** | `bd <ISSUE>` — add `--max-output-tokens 16384` |
| `run-pool-a-sec-bench.sh` (smolagents) | unbounded (no per-turn cap; `max_steps=30` gates iteration count, not tokens) | config.toml template, lines 524-558 | implicit OK | verify smolagents/litellm doesn't inject a hidden cap; smoke-test if doubtful |
| `run-pool-a-exploitbench.sh` (ExploitBench native) | unbounded per turn (turn_budget gates episode iteration) | `--turn-budget` flag | implicit OK | none (verified via spike artifacts) |

## Actionable plan (priority order)

1. **`bd <ISSUE>`** — cybergym `--max-output-tokens 16384`. HARD prerequisite. Land first.
2. **`bd <ISSUE>`** — Pool A spec parser additions (mechanical batch + one live probe for Nemotron qwen3_coder).
3. **`bd <ISSUE>`** — smolagents agent-switch for small-MoE cybergym (already filed). Pool A cybergym for Gemma-4 26B-A4B class can't move forward without this.
4. **Pool A paired-mode re-runs under <CAMPAIGN>** (one per model; file as sub-issues when 0fg + vkt land):
   - <CAMPAIGN> Qwen3.6-27B Pool A — cybergym (paired modes) + sec-bench (paired modes). 0fg fix is the variable being tested.
   - <CAMPAIGN> Qwen3.6-35B-A3B Pool A — paired modes.
   - <CAMPAIGN> Gemma-4 31B Pool A — paired modes (Gemma needs `enable_thinking: true` template kwarg, then `nemotron_v3`-style `-thinking-on.yaml` variant — current cell is the highest open-weight cybergym; thinking-on lift could push past frontier).
   - <CAMPAIGN> Gemma-4 26B-A4B Pool A — sec-bench paired modes; cybergym still gated on vo1.
   - <CAMPAIGN> Nemotron Pool A — initial (no prior cell). Direct paired-mode.
   - <CAMPAIGN> Qwen3.5-122B Pool A — initial paired-mode.
   - <CAMPAIGN> Qwen3-235B-Thinking Pool A — initial paired-mode (the "Thinking" variant is the highest-leverage cell).
   - Frontier (Opus 4.7, GPT-5.5) — re-run cybergym post-0fg. Their current cells are also 2K-capped.

## Sweep-status ᵗ marker update

Pre-audit: only Pool B cells had `ᵗ` markers. Post-audit: **every current Pool A cybergym cell** carries an effective runner-level thinking-off bandage (regardless of spec). Mark these too pending <CAMPAIGN> re-runs:

- <CAMPAIGN> cybergym, <CAMPAIGN> cybergym, <CAMPAIGN> cybergym → add `ᵗ`
- <CAMPAIGN> cybergym is already `N/A` (vo1); leaves no cell to mark
- Frontier cybergym cells (Opus 4.7, GPT-5.5) → add `ᵗ` too
- Sec-bench cells are smolagents-served and unbounded per turn — their thinking-mode reflects the spec faithfully. <CAMPAIGN> sec-bench is genuinely thinking-on; <CAMPAIGN>/.6/.7 are genuinely thinking-off (spec defaults), and stay `ᵗ` for that reason.

`THINKING_OFF_BANDAGED` in `scripts/update-sweep-status.sh` needs Pool A entries added covering the above.

## Refs

- `bd <ISSUE>` (P2, HARD blocker) — cybergym 16K bump
- `bd <ISSUE>` (P2, prereq) — Pool A spec parser additions
- `bd <ISSUE>` (P3) — smolagents agent-switch
- `bd <CAMPAIGN>` (P2 epic) — parent
- `bd memory thinking-mode-policy-2026-05-19` — policy lock
- `bd memory pool-a-exploitbench-methodology-2026-05-19` — Pool A ExploitBench-specific lock (300 turns, max context, GPU-fits-context — folds in with this audit)
