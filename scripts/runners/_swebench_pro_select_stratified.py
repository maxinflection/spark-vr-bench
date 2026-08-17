#!/usr/bin/env python3
# _swebench_pro_select_stratified.py — stratified SWE-bench Pro screening subset
# (bd benchmarks-3xi.2.3, Phase 3). Unlike _swebench_pro_select_n.py (which picks
# the N *smallest* headless-python instances — a deliberately easy/minimal sample
# used for the Phase-2 cost lower-bound), this draws a DIFFICULTY-STRATIFIED,
# repo-balanced subset so the screening pass@1 is not biased toward trivial tasks.
#
# SCOPE CAVEAT (honest): the SWE-agent local-docker substrate + grader were
# validated Python-only in Phase 0 (3xi.2.1: openlibrary/ansible). The Pro public
# set is Go 280 / Python 266 / JS 165 / TS 20, but within Python only ansible (96)
# and openlibrary (91) are headless (qutebrowser is GUI). So this subset is the
# HEADLESS-PYTHON STRATUM of the public set — a screening approximation, NOT the
# full multi-language 731. Multi-language expansion (esp. the Go plurality) +
# per-language grading validation is the bd 3xi.2.4 / install-harness follow-up.
#
# Stratification: global test-count terciles (small/medium/large) over the
# headless-python pool; within each tercile draw evenly-spaced (by instance_id)
# from BOTH repos, balanced, to hit N. Fully deterministic (no RNG) -> reproducible.
#
# Run from /opt/harnesses/swebench-pro (venv with pandas/datasets):
#   python _swebench_pro_select_stratified.py 51
# Writes (under smoke/):
#   strat_sample.jsonl  — rows for swe_bench_pro_eval.py (list cols as str()-reprs)
#   strat_gold.json     — [{instance_id, patch}] gold patches (grading control)
#   strat_select.txt     — chosen instance ids + tercile/repo tags, one per line
#   strat_filter.regex   — '(id1|id2|...)' anchored alternation for --instances.filter
#   strat_manifest.json  — full per-instance metadata + stratification summary

import os, json, ast, re, sys

REPO = "/opt/harnesses/swebench-pro/repo"
RS = os.path.join(REPO, "run_scripts")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 51
have = set(os.listdir(RS))

from datasets import load_dataset
ds = load_dataset("ScaleAI/SWE-bench_Pro", split="test")
LIST_COLS = ["fail_to_pass", "pass_to_pass", "selected_test_files_to_run"]
GUI = {"qutebrowser/qutebrowser"}


def L(v):
    if isinstance(v, (list, tuple)):
        return list(v)
    try:
        return list(ast.literal_eval(v))
    except Exception:
        return []


# Candidate pool: headless python with a local run_scripts dir.
cands = []
for r in ds:
    iid = r["instance_id"]
    if iid not in have:
        continue
    if str(r.get("repo_language") or "").strip().lower() != "python":
        continue
    if r["repo"] in GUI:
        continue
    tot = len(L(r.get("fail_to_pass"))) + len(L(r.get("pass_to_pass")))
    cands.append({"iid": iid, "repo": r["repo"], "tests": tot, "row": r})

cands.sort(key=lambda c: c["tests"])
M = len(cands)
print(f"headless-python pool: {M} across repos { {c['repo'] for c in cands} }")

# Global test-count terciles over the pool.
t1 = cands[M // 3]["tests"]
t2 = cands[2 * M // 3]["tests"]


def tier(t):
    if t <= t1:
        return "small"
    if t <= t2:
        return "medium"
    return "large"


# Bucket by (tier, repo).
buckets = {}
for c in cands:
    buckets.setdefault((tier(c["tests"]), c["repo"]), []).append(c)
for b in buckets.values():
    b.sort(key=lambda c: c["iid"])  # deterministic order within bucket

tiers = ["small", "medium", "large"]
repos = sorted({c["repo"] for c in cands})
ncells = len(tiers) * len(repos)
base = N // ncells          # per-cell quota
extra = N - base * ncells   # distribute remainder

# Evenly-spaced pick of k items from a sorted list (deterministic, spread across difficulty within the cell).
def pick(lst, k):
    if k <= 0 or not lst:
        return []
    if k >= len(lst):
        return list(lst)
    step = len(lst) / k
    return [lst[int(i * step)] for i in range(k)]


chosen = []
cell_order = [(t, rp) for t in tiers for rp in repos]
for idx, cell in enumerate(cell_order):
    k = base + (1 if idx < extra else 0)
    chosen.extend(pick(buckets.get(cell, []), k))

# If a sparse cell under-filled, top up from the largest remaining cells (deterministic).
chosen_ids = {c["iid"] for c in chosen}
if len(chosen) < N:
    leftovers = [c for c in cands if c["iid"] not in chosen_ids]
    leftovers.sort(key=lambda c: c["iid"])
    for c in leftovers[: N - len(chosen)]:
        chosen.append(c)
        chosen_ids.add(c["iid"])

chosen.sort(key=lambda c: (c["tests"], c["iid"]))
print(f"terciles: small<= {t1}, medium<= {t2}, large> {t2}; chose {len(chosen)}")

from collections import Counter
summ = Counter((tier(c["tests"]), c["repo"]) for c in chosen)
for cell in cell_order:
    print(f"  {cell[0]:6s} {cell[1]:28s} {summ.get(cell,0)}")

samples, gold, ids, manifest = [], [], [], []
for c in chosen:
    r = c["row"]
    s = dict(r)
    for col in LIST_COLS:
        s[col] = repr(L(s.get(col)))
    samples.append(s)
    gold.append({"instance_id": c["iid"], "patch": r["patch"]})
    ids.append(c["iid"])
    manifest.append({"instance_id": c["iid"], "repo": c["repo"], "tests": c["tests"], "tier": tier(c["tests"])})

os.makedirs("smoke", exist_ok=True)
with open("smoke/strat_sample.jsonl", "w") as f:
    for s in samples:
        f.write(json.dumps(s) + "\n")
with open("smoke/strat_gold.json", "w") as f:
    json.dump(gold, f)
with open("smoke/strat_select.txt", "w") as f:
    for m in manifest:
        f.write(f"{m['instance_id']}\t{m['tier']}\t{m['tests']}\t{m['repo']}\n")
with open("smoke/strat_filter.regex", "w") as f:
    f.write("(" + "|".join(re.escape(i) for i in ids) + ")")
with open("smoke/strat_manifest.json", "w") as f:
    json.dump({"n": len(ids), "terciles": {"small_le": t1, "medium_le": t2},
               "pool": M, "repos": repos, "cells": {f"{k[0]}|{k[1]}": v for k, v in summ.items()},
               "instances": manifest}, f, indent=2)
print(f"wrote smoke/strat_sample.jsonl ({len(samples)}), strat_gold.json, strat_select.txt, strat_filter.regex, strat_manifest.json")
