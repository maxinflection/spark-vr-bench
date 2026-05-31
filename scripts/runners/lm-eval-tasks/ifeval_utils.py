"""Vendored ifeval grading utils with None-content tolerance for reasoning
models (<CAMPAIGN>).

What's different from upstream `lm_eval/tasks/ifeval/utils.py`:
  - `process_results` guards `response is None` at function entry and
    substitutes the empty string. This matches the convention proposed in
    EleutherAI/lm-evaluation-harness PR #3709 (open as of 2026-05-15):
    score the missing response as a failed prompt rather than crashing the
    whole bench. None comes from vLLM when reasoning_parser=qwen3 +
    enable_thinking=true + max_gen_toks hits inside the <think> block,
    which is the codified behavior after vLLM PR #35230 (merged 2026-02-26).
  - Adds a process-global truncation counter — increments whenever we
    substitute "" for None. Registers its own atexit hook that prints stats
    to stderr at process exit (unconditional; the bench log captures stderr
    so it shows up next to the lm-eval summary line). Diagnostic only;
    doesn't affect grading.

Everything else is a verbatim copy from upstream lm_eval/tasks/ifeval/utils.py
(version 4.0 as of 2026-05-15). Re-vendor when the upstream PR #3709 lands
so we're not carrying drift indefinitely.
"""
import dataclasses
import os
import threading
from typing import Dict, Optional, Union

from lm_eval.tasks.ifeval import instructions_registry


@dataclasses.dataclass
class InputExample:
    key: int
    instruction_id_list: list[str]
    prompt: str
    kwargs: list[Dict[str, Optional[Union[str, int]]]]


@dataclasses.dataclass
class OutputExample:
    instruction_id_list: list[str]
    prompt: str
    response: str
    follow_all_instructions: bool
    follow_instruction_list: list[bool]


# ---------------------------------------------------------------
# Truncation diagnostic — counts how many doc-level responses were None.
# Not a metric; lm-eval aggregates `metric_list` only. We log to stderr
# at process exit so the runner picks it up in the bench log.
# ---------------------------------------------------------------
_trunc_lock = threading.Lock()
_trunc_count = 0
_total_count = 0


def _record_response(response) -> str:
    """Coerce a response into a non-None string + record truncations."""
    global _trunc_count, _total_count
    with _trunc_lock:
        _total_count += 1
        if response is None:
            _trunc_count += 1
            return ""
    return response if isinstance(response, str) else ""


def _emit_truncation_summary() -> None:
    """atexit hook (registered below): print truncation stats to stderr.
    Cheap diagnostic; the bench log captures stderr."""
    if _total_count == 0:
        return
    import sys as _sys
    pct = 100.0 * _trunc_count / max(_total_count, 1)
    print(
        f"[ifeval_utils] truncation stats: {_trunc_count}/{_total_count} "
        f"responses were None ({pct:.1f}%) — replaced with empty string for grading.",
        file=_sys.stderr,
    )


import atexit as _atexit
_atexit.register(_emit_truncation_summary)


# ---------------------------------------------------------------
# Strict / loose graders (verbatim from upstream).
# ---------------------------------------------------------------
def test_instruction_following_strict(
    inp,
    response,
):
    """Tests response to see if instructions are followed."""
    instruction_list = inp.instruction_id_list
    is_following_list = []

    for index, instruction_id in enumerate(instruction_list):
        instruction_cls = instructions_registry.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)

        # Remove None values from kwargs to avoid unexpected keyword argument errors in build_description method.
        kwargs = {k: v for k, v in inp.kwargs[index].items() if v}
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=inp.prompt)

        if response.strip() and instruction.check_following(response):
            is_following_list.append(True)
        else:
            is_following_list.append(False)

    return OutputExample(
        instruction_id_list=inp.instruction_id_list,
        prompt=inp.prompt,
        response=response,
        follow_all_instructions=all(is_following_list),
        follow_instruction_list=is_following_list,
    )


def test_instruction_following_loose(
    inp,
    response,
):
    """Tests response for an upper bound for following instructions."""
    r = response.split("\n")
    response_remove_first = "\n".join(r[1:]).strip()
    response_remove_last = "\n".join(r[:-1]).strip()
    response_remove_both = "\n".join(r[1:-1]).strip()
    revised_response = response.replace("*", "")
    revised_response_remove_first = response_remove_first.replace("*", "")
    revised_response_remove_last = response_remove_last.replace("*", "")
    revised_response_remove_both = response_remove_both.replace("*", "")
    all_responses = [
        response,
        revised_response,
        response_remove_first,
        response_remove_last,
        response_remove_both,
        revised_response_remove_first,
        revised_response_remove_last,
        revised_response_remove_both,
    ]
    instruction_list = inp.instruction_id_list
    is_following_list = []

    for index, instruction_id in enumerate(instruction_list):
        instruction_cls = instructions_registry.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)

        # Remove None values from kwargs to avoid unexpected keyword argument errors in build_description method.
        kwargs = {k: v for k, v in inp.kwargs[index].items() if v}
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=inp.prompt)

        is_following = False
        for r in all_responses:
            if r.strip() and instruction.check_following(r):
                is_following = True
                break

        is_following_list.append(is_following)

    return OutputExample(
        instruction_id_list=inp.instruction_id_list,
        prompt=inp.prompt,
        response=response,
        follow_all_instructions=all(is_following_list),
        follow_instruction_list=is_following_list,
    )


def process_results(doc, results):
    inp = InputExample(
        key=doc["key"],
        instruction_id_list=doc["instruction_id_list"],
        prompt=doc["prompt"],
        kwargs=doc["kwargs"],
    )
    # <CAMPAIGN> None-tolerance: vLLM emits content=None when a reasoning model
    # truncates inside the <think> block (codified by vLLM PR #35230,
    # 2026-02-26). Substitute empty string and record the truncation — the
    # strict/loose graders will both score the prompt as failed, but the
    # bench completes instead of crashing on the first None response.
    response = _record_response(results[0])

    out_strict = test_instruction_following_strict(inp, response)
    out_loose = test_instruction_following_loose(inp, response)

    return {
        "prompt_level_strict_acc": out_strict.follow_all_instructions,
        "inst_level_strict_acc": out_strict.follow_instruction_list,
        "prompt_level_loose_acc": out_loose.follow_all_instructions,
        "inst_level_loose_acc": out_loose.follow_instruction_list,
    }


def agg_inst_level_acc(items):
    flat_items = [item for sublist in items for item in sublist]
    inst_level_acc = sum(flat_items) / len(flat_items)
    return inst_level_acc
