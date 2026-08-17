#!/usr/bin/env python3
"""Minimal prompt-cache round-trip probe (bd benchmarks-3xi.2.2, Phase 2).

The CHEAPEST possible proof that Anthropic prompt caching is wired on a given
litellm route BEFORE spending a long agent run: send the SAME long, static
system prefix twice with a cache_control breakpoint and read usage. A working
cache shows cache_creation on call 1 and cache_read on call 2.

Used to de-risk the Bedrock Opus path (box role is Opus-only on Bedrock) and to
cross-check the direct-Anthropic Haiku path, independently of either agent
scaffold (SWE-agent / OpenHands).

Usage (on the harness box, in the openhands-benchmarks uv venv so litellm is present):
    uv run python _cache_probe.py \
        --model bedrock/us.anthropic.claude-opus-4-7 --region us-east-1
    uv run python _cache_probe.py \
        --model anthropic/claude-haiku-4-5-20251001 \
        --anthropic-key-ssm /sandbox/api-keys/anthropic

Reports per-call: prompt_tokens, completion_tokens, cache_creation_input_tokens,
cache_read_input_tokens (+ the litellm-normalized prompt_tokens_details.cached_tokens
and the _cache_creation_input_tokens hidden field), and the derived APC hit-rate.
"""
import argparse
import json
import subprocess
import sys

import litellm

# A long, STATIC prefix. Anthropic's minimum cacheable prefix is 1024 tokens
# (Opus/Sonnet) / 2048 (Haiku), so we pad well past that. Content is irrelevant
# as long as it's identical across the two calls and big enough to cache.
_PARA = (
    "You are a meticulous software engineering assistant. When you work on a "
    "repository you read the relevant code first, reproduce the failure, make "
    "the minimal change, and re-run the tests to confirm the fix. You never "
    "modify test files. You think step by step and keep your edits surgical. "
)
SYSTEM_PREFIX = _PARA * 120  # ~ a few thousand tokens of stable context


def _usage_dump(resp) -> dict:
    u = getattr(resp, "usage", None)
    if u is None:
        return {}
    try:
        d = u.model_dump()
    except Exception:
        d = dict(getattr(u, "__dict__", {}) or {})
    out = {
        "prompt_tokens": d.get("prompt_tokens"),
        "completion_tokens": d.get("completion_tokens"),
        "cache_creation_input_tokens": d.get("cache_creation_input_tokens"),
        "cache_read_input_tokens": d.get("cache_read_input_tokens"),
        "_cache_creation_input_tokens": getattr(u, "_cache_creation_input_tokens", None),
    }
    pdet = d.get("prompt_tokens_details") or {}
    if isinstance(pdet, dict):
        out["prompt_tokens_details.cached_tokens"] = pdet.get("cached_tokens")
    else:
        out["prompt_tokens_details.cached_tokens"] = getattr(pdet, "cached_tokens", None)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--anthropic-key-ssm", default=None,
                    help="SSM param name holding a direct Anthropic API key")
    ap.add_argument("--max-tokens", type=int, default=64)
    args = ap.parse_args()

    kwargs = {"model": args.model, "max_tokens": args.max_tokens}
    if args.model.startswith("bedrock/"):
        kwargs["aws_region_name"] = args.region
    if args.anthropic_key_ssm:
        key = subprocess.check_output(
            ["aws", "ssm", "get-parameter", "--region", args.region,
             "--name", args.anthropic_key_ssm, "--with-decryption",
             "--query", "Parameter.Value", "--output", "text"],
            text=True).strip()
        kwargs["api_key"] = key

    messages = [
        {"role": "system", "content": [
            {"type": "text", "text": SYSTEM_PREFIX,
             "cache_control": {"type": "ephemeral"}},
        ]},
        {"role": "user", "content": "Reply with the single word: ok"},
    ]

    print(f"# model={args.model} region={args.region}")
    print(f"# system_prefix_chars={len(SYSTEM_PREFIX)}")
    usages = []
    for i in (1, 2):
        resp = litellm.completion(messages=messages, **kwargs)
        u = _usage_dump(resp)
        usages.append(u)
        print(f"## call {i}: {json.dumps(u)}")

    # Derive APC hit on call 2 (steady state): cache_read / total_input.
    u2 = usages[1]
    cr = u2.get("cache_read_input_tokens") or u2.get("prompt_tokens_details.cached_tokens") or 0
    cw = u2.get("cache_creation_input_tokens") or u2.get("_cache_creation_input_tokens") or 0
    pt = u2.get("prompt_tokens") or 0
    # litellm folds cache_read+cache_creation into prompt_tokens for Anthropic;
    # uncached = prompt_tokens - cache_read - cache_write. APC hit = cr / prompt_tokens.
    total = pt if pt else (cr + cw)
    hit = (cr / total) if total else 0.0
    print(f"## call2 APC-hit = cache_read/{total} = {hit:.3f}")
    ok = cr > 0
    print(f"## CACHE_ACTIVE={'YES' if ok else 'NO'}")
    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
