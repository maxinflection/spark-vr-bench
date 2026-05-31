# Nemotron-3 Super 120B-A12B NVFP4 — thinking tags + chat template archaeology (bd <ISSUE> / t7p support)

Verified 2026-05-19 against `chat_template.jinja` pulled from
`https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/raw/main/chat_template.jinja`
(10,771 bytes; the model's `tokenizer_config.json` has the `chat_template` field empty —
HF's newer convention is to store the template in a separate file).

Parser availability verified 2026-05-19 against vLLM 0.21 module listing on
Runcrate RTXPro6000 ×1 rental (now torn down). Re-verify at next provision.

## 1. Tag shape

Identical to Qwen3: **`<think>...</think>`**. Quoting `chat_template.jinja`:

```jinja
# line 109
{%- set content = "<think>\n" ~ message.reasoning_content ~ "\n</think>\n" ~ (message.content | default('', true)) %}
```

```jinja
# lines 204-208 — generation prompt
{%- if add_generation_prompt %}
    {%- if enable_thinking %}
        {{- '<|im_start|>assistant\n<think>\n' }}
    {%- else %}
        {{- '<|im_start|>assistant\n<think></think>' }}
    {%- endif %}
{%- endif %}
```

**Key delta from Qwen3**: even when `enable_thinking=false`, Nemotron's template *still emits* an empty `<think></think>` pair at the start of every assistant turn (line 207). Qwen3's templates omit the opening tag entirely when off. This shape is also enforced in history-rewriting branches (lines 115, 137, 143, 167) — wherever an assistant message lacks the wrapper, the template synthesizes one.

## 2. Template kwargs (three, not one)

Top-level defaults at the start of the template:

```jinja
# lines 12-14
{%- set enable_thinking          = enable_thinking          if enable_thinking          is defined else True %}
{%- set low_effort               = low_effort               if low_effort               is defined else False %}
{%- set truncate_history_thinking = truncate_history_thinking if truncate_history_thinking is defined else True %}
```

| Kwarg | Default | Behavior |
|---|---|---|
| `enable_thinking` | **True** | Controls whether the generation prompt opens with `<think>\n` (model thinks) or `<think></think>` (suppressed). |
| `low_effort` | False | When True, appends `\n\n{reasoning effort: low}` to the last user message (line 181). Nudge for brief reasoning; useful if you want thinking-on but bounded. |
| `truncate_history_thinking` | True | Drops `<think>...</think>` blocks from past assistant turns *before* the last user turn (lines 124, 162). Keeps context manageable in multi-turn conversations. |

**Critical operational note**: Nemotron's `enable_thinking` default is **True** — opposite of much of the Qwen3 family. A Pool B spec that omits `--default-chat-template-kwargs '{"enable_thinking": false}'` silently runs thinking-on. This is the mechanism behind the bd <ISSUE> BCB-Hard contamination (<CAMPAIGN> Nemotron = 0.318 with thinking-on artifacts). The bd <ISSUE> fix added the explicit kwarg — correct.

## 3. vLLM `nemotron_v3` reasoning parser

**Confirmed available in vLLM 0.21** via earlier session probe of
`/opt/vllm-venv/lib/python3.10/site-packages/vllm/reasoning/nemotron_v3_reasoning_parser.py`
on the Runcrate rental. Registered name for `--reasoning-parser` is
`nemotron_v3` (verbatim — not `nemotron`, not `nv_v3`, not the qwen3 parser).

The subagent's report (full details in conversation history) claims the parser:
- Inherits from `DeepSeekR1ReasoningParser` (same `<think>...</think>` tag handling).
- Overrides `extract_reasoning()` with a defensive content-swap: if final `content` is empty/whitespace while `enable_thinking=false` is in effect, swaps `reasoning_content` and `content` positions so callers don't get a `None` response from a spurious empty `<think></think>` wrapper.

The swap behavior is consistent with the template's mandatory wrapper at line 207 — without the parser-side swap, every `enable_thinking=false` response would arrive with `content=None` and the reasoning string in `reasoning_content`, which would break callers that read `choices[0].message.content`.

**Implication**: when running thinking-off (bd <ISSUE> spec for BCB-Hard), the `nemotron_v3` parser **is functionally useful** even though "no reasoning blocks to parse" might suggest otherwise — its content-swap rescues empty wrappers. The ddw close note's "the parser is moot" claim is wrong; recommend adding `--reasoning-parser nemotron_v3` to the Pool B spec as well.

Caveat: I did not re-read the parser file on a fresh rental this session. Operator should re-verify the swap-logic claim against
`/opt/vllm-venv/lib/python3.10/site-packages/vllm/reasoning/nemotron_v3_reasoning_parser.py`
on the next Nemotron rental before treating the recommendation as locked.

## 4. Recommended Pool A (thinking-on) spec

`scripts/rental-specs/nemotron-3-super-120b-a12b-nvfp4-thinking-on.yaml` (new — does not exist yet):

```yaml
vllm_args:
  - --enable-prefix-caching
  - --default-chat-template-kwargs
  - '{"enable_thinking": true, "low_effort": false, "truncate_history_thinking": true}'
  - --reasoning-parser
  - nemotron_v3
```

Rationale:
- `enable_thinking: true` — matches default but explicit for reproducibility (mirror of `qwen3-family-enable-thinking-false-convention` memory's "always set the flag explicitly" rule).
- `low_effort: false` — explicit; we want full reasoning capability on Pool A cybergym / sec-bench.
- `truncate_history_thinking: true` — explicit; the agent's multi-turn context will accumulate without it.
- `--reasoning-parser nemotron_v3` — required for vLLM to split `<think>` blocks into `reasoning_content` and `content` fields properly. Without it, the agent's `choices[0].message.content` may contain the entire `<think>...</think>` block raw, polluting downstream tool-call parsers.

## 5. Recommended bd <ISSUE> (BCB-Hard thinking-off) update

Current ddw spec is correct on the `enable_thinking=false` kwarg. **Recommended addition**: append `--reasoning-parser nemotron_v3` (despite the ddw note saying it's moot). Rationale: the parser's content-swap logic salvages the case where Nemotron's mandatory empty `<think></think>` wrapper would otherwise yield `content=None` for a thinking-off response. Without the parser, BCB-Hard's openai client receives `content=None` for some fraction of turns and produces garbage scores.

Need a fresh smoke against the patched spec before re-publishing the BCB-Hard cell. ~$10 / ~1 hr on RTXPro6000 ×2.

## 6. Operational quirks summary (vs Qwen3)

| Aspect | Qwen3 | Nemotron-3 Super |
|---|---|---|
| Reasoning tag | `<think>...</think>` | `<think>...</think>` (identical) |
| `--reasoning-parser` value | `qwen3` | **`nemotron_v3`** (NOT interchangeable) |
| Default `enable_thinking` | Varies by variant; often False | **True** |
| Empty wrapper when off | Omitted entirely | Always `<think></think>` |
| Truncation safety | Parser-only | Parser + template `truncate_history_thinking` kwarg |
| Additional template kwargs | None used in our sweep | `low_effort`, `truncate_history_thinking` |
| EOS token | `<|im_end|>` | `<|im_end|>` (identical ChatML) |

## Refs

- `bd <ISSUE>` (closed) — thinking-off spec for Pool B.
- `bd <ISSUE>` (open) — BCB-Hard redo at 128K + thinking-off. This doc recommends adding `--reasoning-parser nemotron_v3` to the t7p re-run spec.
- `bd <ISSUE>` (closed) — BCB-Hard truncation audit that surfaced the original thinking-on contamination.
- `bd memory feedback_context_length_policy_2026-05-18` — broader Pool A/B context floor/target.
- `bd memory qwen3-family-enable-thinking-false-convention` — parallel discipline for Qwen3.
- Chat template raw URL: https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/raw/main/chat_template.jinja
