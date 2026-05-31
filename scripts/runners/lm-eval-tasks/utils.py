"""Filter helpers for our local Pool B humaneval_plus_chat task (<CAMPAIGN>).

Why this exists: lm-eval's upstream humaneval_instruct uses `gen_prefix` to
preload the assistant turn so the model continues a partially-typed code
block. That mechanism requires assistant-message prefill, which Bedrock
Anthropic Opus 4.7 explicitly rejects ("This model does not support
assistant message prefill"). So we run a no-prefill, single-user-message
prompt and extract the code from whatever the model returns.

This file lives alongside humaneval_plus_chat.yaml and is loaded by lm-eval
via `!function utils.build_predictions_extract_code` (relative to the yaml).
"""
import re

# Re-export upstream's pass_at_k so the yaml can reference it as
# `!function utils.pass_at_k` without us re-implementing the metric.
from lm_eval.tasks.humaneval.utils import pass_at_k  # noqa: F401  (used by yaml)


# Match the first ```python (or ``` or ```py) ... ``` block. DOTALL so
# multi-line code is captured. Tolerant of optional 'python'/'py' tag and
# optional newline after the opener.
_CODE_BLOCK_RE = re.compile(r"```(?:python|py)?\s*\n?(.*?)```", re.DOTALL)


def build_predictions_extract_code(
    resps: list[list[str]],
    docs: list[dict],
) -> list[list[str]]:
    """Extract a Python function from each model response.

    We prepend doc["prompt"] (imports + signature) to the extracted code
    block so the executed program has the imports the prompt declared,
    even if the model omitted them from its code block.

    Local instruct-tuned models (Qwen3.6, Gemma 4) tend to repeat imports
    inside their code block, so the duplication is harmless — Python lets
    the second `def` win. Frontier reasoning models (GPT-5.x) often omit
    imports, which previously caused NameError at exec on typing-annotated
    tasks (e.g. `from typing import List`). Prepending the prompt fixes the
    reasoning-model case without penalising locals. Matches the bigcode-
    evaluation-harness pattern.

    Falls back to the raw response if no code block is found — the test
    framework will produce a SyntaxError verdict, which is honest about
    the model's output shape.
    """
    out: list[list[str]] = []
    for resp_list, doc in zip(resps, docs):
        extracted: list[str] = []
        for r in resp_list:
            # Reasoning models (Qwen3-235B-Thinking) can exhaust the gen
            # budget on the <think> channel and return content=None. The
            # OpenAI client surfaces that as None, not "". Treat None / empty
            # as "no answer" — append the prompt unchanged so the executed
            # program will raise (honest SyntaxError verdict) instead of
            # crashing the whole bench. Caught 2026-05-15 on <CAMPAIGN>.
            if not r:
                extracted.append(doc["prompt"])
                continue
            m = _CODE_BLOCK_RE.search(r)
            code = m.group(1).rstrip() if m else r
            extracted.append(doc["prompt"] + code)
        out.append(extracted)
    return out
