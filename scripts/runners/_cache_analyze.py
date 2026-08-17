#!/usr/bin/env python3
"""Prompt-cache (APC) hit-rate analyzer (bd benchmarks-3xi.2.2, Phase 2).

Computes the Anthropic-prompt-cache hit-rate per the issue-mandated O(turns^2)
cost guard, over a long-horizon agent run, from either scaffold:

  - OpenHands/rebench: --source openhands <output.jsonl>
      reads EvalOutput.metrics.token_usages (per-turn TokenUsage written by the
      SDK telemetry: cache_read_tokens=prompt_tokens_details.cached_tokens,
      cache_write_tokens=_cache_creation_input_tokens).
  - SWE-agent/Pro: --source sweagent <usage.jsonl>
      reads the per-call usage JSONL emitted by the litellm cache probe
      (_sweagent_cache_probe.py): one {prompt_tokens, cache_read, cache_write,...}
      per litellm.completion call.

APC hit-rate definition (matches CyberGym serving-strategy s1):
    For Anthropic, litellm folds cache tokens INTO prompt_tokens, i.e.
    prompt_tokens = cache_read + cache_write + uncached_input.
    APC_hit = sum(cache_read) / sum(prompt_tokens)
            = sum(cache_read) / sum(cache_read + cache_write + uncached_input).
This is read tokens as a fraction of ALL input tokens over the run; turn 1 (the
cache-creation turn) and every condenser reset count against it (real regime).
"""
import argparse
import json
import sys


def _turns_from_openhands(path):
    """Yield (instance_id, [per-turn dicts]) from an OpenHands output.jsonl."""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        iid = rec.get("instance_id", "?")
        m = rec.get("metrics") or {}
        turns = []
        for tu in m.get("token_usages") or []:
            turns.append({
                "prompt_tokens": int(tu.get("prompt_tokens") or 0),
                "completion_tokens": int(tu.get("completion_tokens") or 0),
                "cache_read": int(tu.get("cache_read_tokens") or 0),
                "cache_write": int(tu.get("cache_write_tokens") or 0),
            })
        yield iid, turns, m.get("accumulated_token_usage"), m.get("accumulated_cost")


def _turns_from_sweagent(path):
    """Yield (instance_id, [per-turn dicts]) from a sweagent probe usage.jsonl."""
    by_inst = {}
    order = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        iid = rec.get("instance_id") or "sweagent-run"
        if iid not in by_inst:
            by_inst[iid] = []
            order.append(iid)
        by_inst[iid].append({
            "prompt_tokens": int(rec.get("prompt_tokens") or 0),
            "completion_tokens": int(rec.get("completion_tokens") or 0),
            "cache_read": int(rec.get("cache_read") or 0),
            "cache_write": int(rec.get("cache_write") or 0),
        })
    for iid in order:
        yield iid, by_inst[iid], None, None


def _agg(turns):
    pt = sum(t["prompt_tokens"] for t in turns)
    cr = sum(t["cache_read"] for t in turns)
    cw = sum(t["cache_write"] for t in turns)
    ct = sum(t["completion_tokens"] for t in turns)
    # total input = prompt_tokens (litellm folds cache into prompt_tokens for
    # Anthropic). uncached = prompt_tokens - cache_read - cache_write.
    uncached = pt - cr - cw
    total_input = pt if pt else (cr + cw)
    apc = (cr / total_input) if total_input else 0.0
    return dict(prompt_tokens=pt, cache_read=cr, cache_write=cw,
               completion_tokens=ct, uncached_input=uncached,
               total_input=total_input, apc_hit=apc, n_turns=len(turns))


# litellm price table (USD per token) for the Bedrock cross-region profiles we
# run; lets the analyzer report the cost decomposition AND the no-cache
# counterfactual (the O(turns^2) cost the cache gate guards against) directly
# from the token breakdown, identically for both scaffolds.
PRICES = {
    # us.anthropic.claude-opus-4-7 cross-region inference profile (litellm table)
    "opus47": dict(inp=5.5e-6, out=2.75e-5, cr=5.5e-7, cw=6.875e-6),
    # claude-haiku-4-5 direct Anthropic (litellm table)
    "haiku45": dict(inp=1.0e-6, out=5.0e-6, cr=1.0e-7, cw=1.25e-6),
}


def _cost(pt, cr, cw, ct, p):
    uncached = max(pt - cr - cw, 0)
    cost = uncached * p["inp"] + cr * p["cr"] + cw * p["cw"] + ct * p["out"]
    # No-cache counterfactual: every input token billed at the uncached rate
    # (what the run WOULD cost without prompt caching — O(turns^2) regime).
    nocache = pt * p["inp"] + ct * p["out"]
    return cost, nocache


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=["openhands", "sweagent"], required=True)
    ap.add_argument("path")
    ap.add_argument("--show-turns", action="store_true",
                    help="print per-turn cache_read/write/prompt for the first instance")
    ap.add_argument("--price", choices=list(PRICES), default=None,
                    help="compute cost decomposition + no-cache counterfactual")
    args = ap.parse_args()
    price = PRICES.get(args.price) if args.price else None

    reader = _turns_from_openhands if args.source == "openhands" else _turns_from_sweagent
    grand = dict(prompt_tokens=0, cache_read=0, cache_write=0, completion_tokens=0)
    n_inst = 0
    first_turns = None
    for iid, turns, acc, cost in reader(args.path):
        n_inst += 1
        a = _agg(turns)
        if first_turns is None:
            first_turns = (iid, turns)
        for k in grand:
            grand[k] += a[k]
        costs = f" cost=${cost:.4f}" if isinstance(cost, (int, float)) else ""
        print(f"[{iid}] turns={a['n_turns']:>3} "
              f"prompt={a['prompt_tokens']:>9,} read={a['cache_read']:>9,} "
              f"write={a['cache_write']:>8,} uncached={a['uncached_input']:>7,} "
              f"APC={a['apc_hit']*100:5.1f}%{costs}")

    gt = grand["prompt_tokens"]
    gr = grand["cache_read"]
    gw = grand["cache_write"]
    gct = grand["completion_tokens"]
    gunc = gt - gr - gw
    gapc = (gr / gt) if gt else 0.0
    print("-" * 96)
    print(f"OVERALL instances={n_inst} prompt_tokens={gt:,} cache_read={gr:,} "
          f"cache_write={gw:,} uncached={gunc:,} completion={gct:,}")
    print(f"OVERALL APC hit-rate = cache_read / prompt_tokens = {gr:,} / {gt:,} = {gapc*100:.2f}%")
    if price and n_inst:
        cost, nocache = _cost(gt, gr, gw, gct, price)
        per = cost / n_inst
        save = (1 - cost / nocache) * 100 if nocache else 0.0
        print(f"OVERALL cost(${args.price}) = ${cost:.4f}  (${per:.4f}/task)  "
              f"no-cache counterfactual = ${nocache:.4f}  -> cache saves {save:.1f}%")

    if args.show_turns and first_turns:
        iid, turns = first_turns
        print(f"\n--- per-turn (first instance {iid}) ---")
        print(f"{'turn':>4} {'prompt':>8} {'read':>8} {'write':>8} {'uncached':>8} {'APC%':>6}")
        for i, t in enumerate(turns, 1):
            pt = t["prompt_tokens"]; cr = t["cache_read"]; cw = t["cache_write"]
            unc = pt - cr - cw
            apc = (cr / pt * 100) if pt else 0.0
            print(f"{i:>4} {pt:>8,} {cr:>8,} {cw:>8,} {unc:>8,} {apc:>6.1f}")

    sys.exit(0 if gapc >= 0.90 else 3)


if __name__ == "__main__":
    main()
