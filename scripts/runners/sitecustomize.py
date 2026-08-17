"""litellm per-call cache-usage probe for the SWE-agent/Pro path (bd 3xi.2.2).

SWE-agent's InstanceStats records only tokens_sent/received/api_calls (estimated
via token_counter) — it discards response.usage, so the Anthropic prompt-cache
fields (cache_read_input_tokens / cache_creation_input_tokens) never surface.
This module wraps litellm.completion to append the REAL per-call usage (incl.
cache fields) to a JSONL, so the Phase-2 APC-hit guard can be measured on the
SWE-agent scaffold exactly as on OpenHands.

It is a `sitecustomize` module: Python auto-imports it at interpreter startup
when its directory is on PYTHONPATH, so it loads inside the `sweagent` process
before any litellm.completion call (the same call-time-rebind trick as
scripts/runners/_litellm_patches.py). No SWE-agent source edit.

Activate:
    PYTHONPATH=/path/to/this/dir:$PYTHONPATH \
    SWEAGENT_CACHE_USAGE_OUT=/path/usage.jsonl \
    SWEAGENT_CACHE_INSTANCE=<instance_id> \
    sweagent run-batch ...
"""
import json
import os
import threading

_OUT = os.environ.get("SWEAGENT_CACHE_USAGE_OUT")
_INSTANCE = os.environ.get("SWEAGENT_CACHE_INSTANCE", "sweagent-run")
_lock = threading.Lock()
_idx = {"n": 0}

# Bedrock cross-region Anthropic profiles (Opus 4.5-4.7) reject temperature AND
# top_p server-side ("X is deprecated for this model"); litellm's drop_params
# does NOT gate them (price-table entry lacks supports_*:false — verified). SWE-
# agent's model config defaults top_p=1.0 and sends it, so the run dies. We can't
# null top_p in config (it breaks SWE-agent's model-id property f"{top_p:.2f}"),
# so we scrub the sampling params at the litellm boundary instead — the same
# approach as scripts/runners/_litellm_patches.py for the Pool B openai path.
_SCRUB_MODELS = ("claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7",
                 "claude-opus-4-8")


def _scrub_sampling(kwargs):
    model = (kwargs.get("model") or "").lower()
    if any(t in model for t in _SCRUB_MODELS):
        for k in ("temperature", "top_p", "top_k"):
            kwargs.pop(k, None)
    return kwargs


def _extract_usage(resp):
    u = getattr(resp, "usage", None) or (
        resp.get("usage") if isinstance(resp, dict) else None)
    if u is None:
        return None
    g = (lambda k: u.get(k)) if isinstance(u, dict) else (lambda k: getattr(u, k, None))
    prompt = int(g("prompt_tokens") or 0)
    completion = int(g("completion_tokens") or 0)
    cw = int(g("cache_creation_input_tokens") or g("_cache_creation_input_tokens") or 0)
    cr = int(g("cache_read_input_tokens") or 0)
    if not cr:
        pdet = g("prompt_tokens_details")
        if pdet is not None:
            cr = int((pdet.get("cached_tokens") if isinstance(pdet, dict)
                      else getattr(pdet, "cached_tokens", 0)) or 0)
    return {"instance_id": _INSTANCE, "prompt_tokens": prompt,
            "completion_tokens": completion, "cache_read": cr, "cache_write": cw}


def _record(resp):
    if not _OUT:
        return
    try:
        rec = _extract_usage(resp)
        if rec is None:
            return
        with _lock:
            _idx["n"] += 1
            rec["call_idx"] = _idx["n"]
            with open(_OUT, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
    except Exception:
        pass  # never let metrics capture break the run


if _OUT:
    try:
        import litellm

        if not getattr(litellm.completion, "_cache_probe_wrapped", False):
            _orig = litellm.completion
            _orig_a = litellm.acompletion

            def _wrapped(*a, **k):
                r = _orig(*a, **_scrub_sampling(k))
                _record(r)
                return r

            async def _wrapped_a(*a, **k):
                r = await _orig_a(*a, **_scrub_sampling(k))
                _record(r)
                return r

            _wrapped._cache_probe_wrapped = True
            _wrapped_a._cache_probe_wrapped = True
            litellm.completion = _wrapped
            litellm.acompletion = _wrapped_a
    except Exception:
        pass
