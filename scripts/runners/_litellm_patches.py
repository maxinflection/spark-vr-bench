"""Pre-call mutations + post-call usage capture for litellm.completion.

Patch status as of 2026-05-14 (bd <ISSUE>, stack-version-and-patch-matrix-2026-05-14.md):

KEPT AFTER SMOKE (matrix doc classified as droppable; smoke proved required):
  - GPT-5.x temperature/top_p/top_k strip: matrix doc cited PR #13390 (merged
    2025-08-07) adding OpenAIGPT5Config.map_openai_params. Smoke on
    litellm 1.84.0 (2026-05-14, campaign 0em-bump-gpt55-humaneval-2026-05-14)
    confirmed: gpt-5.5 still returns "Unsupported value: 'temperature' does
    not support 0 with this model" without our patch. Root cause: litellm's
    OpenAIGPT5Config.get_supported_openai_params() still LISTS temperature
    in the supported set, so drop_params=True does not strip it. The native
    map_openai_params path is conditional on the unsupported-list and never
    fires for temperature. Patch is required until litellm corrects the
    supported-params catalog.

HISTORICAL (dropped after smoke 2026-05-15, bd <ISSUE>):
  - GPT-5.x max_tokens→max_completion_tokens rename: PR #13390 handles this
    natively. Direct smoke 2026-05-15 (litellm 1.84.0, openai/gpt-5.5,
    max_tokens=20, no rename patch active) returned content cleanly without
    a "max_tokens not supported" error — confirming the rename is upstream.
    Distinct from the temperature gap above: that one stays because litellm's
    catalog still LISTS temperature; max_tokens rejection wasn't catalog-gated
    in the same way and the upstream PR's handler does fire.

KEPT AFTER SMOKE (uncertain → confirmed required):
  - Opus 4.7 temperature/top_p/top_k strip on Bedrock-converse: PRs #26246 and
    #26445 are merged into litellm, but smoke on litellm 1.84.0 (2026-05-14,
    bd <ISSUE>) confirmed: Bedrock still returns "temperature is deprecated for
    this model" without the patch. Root cause: model_prices_and_context_window.json
    entry for anthropic.claude-opus-4-7 lacks supports_temperature:false, so
    the Bedrock-converse path does NOT gate it under drop_params=True.
    Patch re-enabled after smoke failure on 0em-bump-opus47-humaneval-2026-05-14.
    (docs/research/stack-version-and-patch-matrix-2026-05-14.md §2, row 1)

KEPT (upstream gap confirmed):
  (1) Trailing-whitespace strip on Bedrock Anthropic assistant content (<CAMPAIGN>).
      litellm PR #15850 (2025-11-01) only replaces empty/whitespace-ONLY strings
      with "."; our patch rstrips trailing whitespace on non-empty content — a
      distinct case not covered upstream (converse_transformation.py has no
      rstrip on non-empty assistant content).
  (2) Drop empty/whitespace-only stop sequences (<CAMPAIGN>). litellm converse_
      transformation.py filters len==0 stops but NOT whitespace-only strings
      (e.g. "  " or "\n"). PR #7484 (2025-01-08) fixed the Anthropic-direct
      path, not Bedrock-converse.
  (3) Usage aggregation + vLLM extra-body injection — no upstream equivalent
      in lm-evaluation-harness litellm path.

Pre-call kwargs scrubs (active patches only):

(1) Strip trailing whitespace from the last assistant message for any Bedrock
    Anthropic model (<CAMPAIGN>). Anthropic's API rejects assistant content that
    ends with whitespace.

(2) Drop empty/whitespace-only stop sequences (<CAMPAIGN>). Bedrock rejects
    "inferenceConfig.stopSequences.0 is blank" which lm-eval can produce for
    chat tasks with no `until` and no resolvable EOS.

Post-call usage capture (added 2026-05-08):

Aggregates `prompt_tokens` and `completion_tokens` across every
`litellm.completion`/`acompletion` call in the process. lm-eval doesn't
aggregate API-backend usage, so the runner's results.json carried zeros.
Set env `LITELLM_PATCH_USAGE_OUT=/path/to/usage.json` before importing this
module (or before invoking the wrapper); on Python interpreter exit the
counters are flushed to that path. The runner reads them back and passes
to write_result_json.

Why a monkey-patch (vs callbacks / drop_params / subclassing):
- `drop_params=True` does nothing for (1) — catalog hasn't been updated.
- `additional_drop_params=[...]` is per-call only; we can't edit lm-eval call
  sites, and (2)/(3) are content / structural mutations not kwarg drops.
- `CustomLogger.log_pre_api_call` is observability-only in SDK mode; the
  mutating hook (`async_pre_call_hook`) is proxy-only.
- Subclassing `litellm.llms.bedrock.*` couples us to litellm's internals.
  The public name `litellm.completion` is the most stable surface.

Import this module ONCE at runner startup, before any litellm.completion()
call. The rebind is picked up by lm-evaluation-harness because the harness
resolves `litellm.completion` at call-time.
"""
import atexit
import json
import os
import threading

import litellm

# Opus 4.7 temperature strip on Bedrock-converse — KEPT (confirmed by smoke).
# PRs BerriAI/litellm#26246 and #26445 are merged, but litellm 1.84.0 still
# returns "temperature is deprecated for this model" on Bedrock for Opus 4.7
# without this patch (smoke 0em-bump-opus47-humaneval-2026-05-14, 2026-05-14).
# Root cause: model_prices_and_context_window.json lacks supports_temperature:false
# for anthropic.claude-opus-4-7, so drop_params=True does NOT gate it on the
# Bedrock-converse path. Patch is required until litellm fixes the JSON entry.
# (docs/research/stack-version-and-patch-matrix-2026-05-14.md §2, row 1)
_TEMPERATURE_FORBIDDEN = (
    "claude-opus-4-7",
    "anthropic.claude-opus-4-7",
)

# GPT-5.x family is gated separately — both temperature AND max_tokens need
# scrubbing (temperature dropped; max_tokens renamed). Substring matches the
# openai-provider model arg ("openai/gpt-5.5", etc.) and bare model name.
# Covers gpt-5, gpt-5.1, ..., gpt-5.5 plus -pro/-codex/-mini/-nano/-chat-latest
# variants. Excludes non-reasoning OpenAI models (gpt-4o, gpt-4.1, etc.) by
# requiring the "gpt-5" prefix.
#
# KEPT (matrix doc was wrong): matrix-2026-05-14 classified this as droppable
# under PR #13390. Smoke on litellm 1.84.0 (0em-bump-gpt55-humaneval-2026-05-14)
# showed gpt-5.5 still rejects temperature even with drop_params=True, because
# OpenAIGPT5Config.get_supported_openai_params() still LISTS temperature in
# the supported set — so litellm's native conditional handler never fires.
# Restored 2026-05-14. (matrix doc §2 row 2; will be amended.)
_GPT5_REASONING_FAMILY = ("gpt-5",)


def _is_gpt5_reasoning(model: str) -> bool:
    """True if model is in the gpt-5.x reasoning family."""
    return any(tag in model for tag in _GPT5_REASONING_FAMILY)


def _scrub_temperature(kwargs: dict) -> None:
    """In-place: drop temperature/top_p/top_k for Opus 4.7 AND gpt-5.x.

    Both confirmed required on litellm 1.84.0 (smoke 2026-05-14, bd <ISSUE>):
      - Opus 4.7 on Bedrock: returns 'temperature is deprecated for this
        model' because anthropic.claude-opus-4-7 price-table entry lacks
        supports_temperature:false, so drop_params=True doesn't gate it.
      - gpt-5.x via OpenAI direct: returns 'temperature does not support 0
        with this model' because OpenAIGPT5Config.get_supported_openai_params
        still LISTS temperature, so drop_params=True doesn't strip it and
        the conditional native handler in map_openai_params never fires."""
    model = kwargs.get("model", "") or ""
    if any(tag in model for tag in _TEMPERATURE_FORBIDDEN) or _is_gpt5_reasoning(model):
        for k in ("temperature", "top_p", "top_k"):
            kwargs.pop(k, None)


# Models where the last assistant message must not end in whitespace.
# All Bedrock Anthropic routes share the restriction; substring match keeps
# the gate broad without enumerating every claude-* variant.
# KEPT: litellm PR #15850 only fixes empty/fully-whitespace strings; our patch
# handles trailing whitespace on otherwise non-empty content (distinct case).
# (docs/research/stack-version-and-patch-matrix-2026-05-14.md §2, row 4)
_ANTHROPIC_NO_TRAILING_WS = ("bedrock/anthropic", "bedrock/us.anthropic")


def _strip_trailing_assistant_ws(kwargs: dict) -> None:
    """In-place: rstrip the last message's content if (a) it's an assistant
    role and (b) we're talking to a Bedrock Anthropic model. Other providers
    are untouched."""
    model = kwargs.get("model", "") or ""
    if not any(tag in model for tag in _ANTHROPIC_NO_TRAILING_WS):
        return
    msgs = kwargs.get("messages") or []
    if not msgs:
        return
    last = msgs[-1]
    if not isinstance(last, dict) or last.get("role") != "assistant":
        return
    content = last.get("content")
    if isinstance(content, str) and content != content.rstrip():
        last["content"] = content.rstrip()


# JSON parsed once on first import; we don't expect the value to change
# inside a single runner process. None means "no extra body to inject".
_EXTRA_BODY_INJECT: dict | None = None
try:
    _eb_raw = os.environ.get("LM_EVAL_VLLM_EXTRA_BODY", "").strip()
    if _eb_raw:
        _eb_parsed = json.loads(_eb_raw)
        if isinstance(_eb_parsed, dict):
            _EXTRA_BODY_INJECT = _eb_parsed
except (json.JSONDecodeError, ValueError):
    # Bad JSON — silently ignore so a typo in the runner doesn't kill the
    # whole eval. The runner logs the env var value separately for debug.
    _EXTRA_BODY_INJECT = None


def _inject_extra_body(kwargs: dict) -> None:
    """In-place: merge LM_EVAL_VLLM_EXTRA_BODY env JSON into kwargs.extra_body
    for openai-provider calls. Used to forward chat_template_kwargs (e.g.
    {"enable_thinking": false}) per-request to vLLM's OpenAI-compatible
    endpoint, since lm-evaluation-harness's litellm path doesn't expose a
    hook to set extra_body. No-op when the env var is unset/empty/invalid.

    Scoping: we only inject for openai-provider models (matches our vllm
    target) — Bedrock and Gemini paths get untouched. The 'openai/' model
    prefix is what lm-eval's litellm setup uses for our vllm target.
    """
    if _EXTRA_BODY_INJECT is None:
        return
    model = kwargs.get("model", "") or ""
    if not model.startswith("openai/"):
        return
    existing = kwargs.get("extra_body")
    if existing is None:
        kwargs["extra_body"] = dict(_EXTRA_BODY_INJECT)
        return
    if not isinstance(existing, dict):
        # Defensive: don't merge into a non-dict — overwrite, but log via
        # the error counter so we notice during debugging.
        kwargs["extra_body"] = dict(_EXTRA_BODY_INJECT)
        return
    # Shallow merge — env-supplied values win on key conflict (caller
    # explicitly asked for them; existing values are usually inferred).
    merged = dict(existing)
    merged.update(_EXTRA_BODY_INJECT)
    kwargs["extra_body"] = merged


def _drop_empty_stops(kwargs: dict) -> None:
    """In-place: filter empty/whitespace-only entries out of `stop`, dropping
    the key entirely if nothing's left. Bedrock rejects requests with an
    empty stop-sequence value ("inferenceConfig.stopSequences.0 is blank"),
    which lm-evaluation-harness can produce for chat tasks that omit
    `gen_kwargs.until` and have no resolvable EOS string. See <CAMPAIGN>.

    KEPT: litellm converse_transformation.py checks len(value)==0 only;
    whitespace-only strings (e.g. "  " or "\\n") are not filtered upstream.
    PR #7484 (2025-01-08) fixed Anthropic-direct path but not Bedrock-converse.
    (docs/research/stack-version-and-patch-matrix-2026-05-14.md §2, row 5)"""
    stop = kwargs.get("stop")
    if stop is None:
        return
    if isinstance(stop, str):
        if not stop.strip():
            kwargs.pop("stop", None)
        return
    if isinstance(stop, (list, tuple)):
        cleaned = [s for s in stop if isinstance(s, str) and s.strip()]
        if cleaned:
            kwargs["stop"] = cleaned
        else:
            kwargs.pop("stop", None)


def _scrub(kwargs: dict) -> dict:
    # _scrub_temperature: strips temp/top_p/top_k for Opus 4.7 (Bedrock)
    #   AND gpt-5.x (OpenAI direct). Both confirmed still required on
    #   litellm 1.84.0 via 0em smoke 2026-05-14.
    # GPT-5.x max_tokens rename: handled natively by litellm 1.84 per
    #   PR #13390; our shim was dropped 2026-05-15 (bd <ISSUE>) after smoke.
    _scrub_temperature(kwargs)
    _strip_trailing_assistant_ws(kwargs)
    _drop_empty_stops(kwargs)
    _inject_extra_body(kwargs)
    return kwargs


# ============================================================
# Usage aggregation
# ============================================================
_USAGE_OUT_PATH = os.environ.get("LITELLM_PATCH_USAGE_OUT")
_usage_lock = threading.Lock()
_usage_counters: dict[str, int] = {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "calls": 0,
    "errors": 0,
}


def _record_usage(response) -> None:
    """Best-effort: extract usage from a litellm response and add to counters.
    Never raises — this runs after a successful API call and a metrics
    failure must not surface as a model failure."""
    try:
        usage = getattr(response, "usage", None) or (
            response.get("usage") if isinstance(response, dict) else None
        )
        if usage is None:
            return
        get = (
            (lambda k: getattr(usage, k, 0))
            if not isinstance(usage, dict)
            else (lambda k: usage.get(k, 0))
        )
        prompt = int(get("prompt_tokens") or 0)
        completion = int(get("completion_tokens") or 0)
        with _usage_lock:
            _usage_counters["prompt_tokens"] += prompt
            _usage_counters["completion_tokens"] += completion
            _usage_counters["calls"] += 1
    except Exception:
        with _usage_lock:
            _usage_counters["errors"] += 1


def _flush_usage() -> None:
    """atexit: write counters to LITELLM_PATCH_USAGE_OUT if set. Fail
    silently — the test framework already has its own results."""
    if not _USAGE_OUT_PATH:
        return
    try:
        with _usage_lock:
            snapshot = dict(_usage_counters)
        # Atomic-enough: write to .tmp then rename
        tmp = f"{_USAGE_OUT_PATH}.tmp"
        with open(tmp, "w") as f:
            json.dump(snapshot, f)
        os.replace(tmp, _USAGE_OUT_PATH)
    except Exception:
        pass


if _USAGE_OUT_PATH:
    atexit.register(_flush_usage)


# Idempotency guard so re-imports / hot-reloads don't double-wrap.
# Flag name retained for backward compat with any live process checking it.
if not getattr(litellm.completion, "_opus47_patched", False):
    _orig_completion = litellm.completion
    _orig_acompletion = litellm.acompletion

    def _patched_completion(*args, **kwargs):
        response = _orig_completion(*args, **_scrub(kwargs))
        _record_usage(response)
        return response

    async def _patched_acompletion(*args, **kwargs):
        response = await _orig_acompletion(*args, **_scrub(kwargs))
        _record_usage(response)
        return response

    _patched_completion._opus47_patched = True  # type: ignore[attr-defined]
    _patched_acompletion._opus47_patched = True  # type: ignore[attr-defined]

    litellm.completion = _patched_completion
    litellm.acompletion = _patched_acompletion
