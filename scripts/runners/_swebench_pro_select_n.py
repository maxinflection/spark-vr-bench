# _swebench_pro_select_n.py — select N SWE-bench Pro instances for the n~10 smoke
# (bd benchmarks-3xi.2.2, Phase 2). Generalises _swebench_pro_smoke_build.py from
# 1 -> N: picks the N smallest headless-Python instances that have a local
# run_scripts/ dir (fast to grade, image pullable), and writes the grader inputs +
# the SWE-agent instance filter.
#
# Run from /opt/harnesses/swebench-pro (venv with pandas/datasets):
#   python _swebench_pro_select_n.py 10
# Writes (under smoke/):
#   sample_n.jsonl   — N rows for swe_bench_pro_eval.py (list cols as str()-reprs)
#   gold_n.json      — [{instance_id, patch}] gold patches (control)
#   select_n.txt     — N instance ids, one per line
#   filter_n.regex   — '(id1|id2|...)' anchored alternation for --instances.filter
# Grade FROM repo/ so dockerfiles/ + run_scripts/ resolve (CWD-relative).

import os, json, ast, re, sys

REPO = "/opt/harnesses/swebench-pro/repo"
RS = os.path.join(REPO, "run_scripts")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 10
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


cands = []
for r in ds:
    iid = r["instance_id"]
    if iid not in have:
        continue
    if str(r.get("repo_language") or "").strip().lower() != "python":
        continue
    if r["repo"] in GUI:
        continue
    f2p = L(r.get("fail_to_pass"))
    p2p = L(r.get("pass_to_pass"))
    stf = L(r.get("selected_test_files_to_run"))
    cands.append((len(f2p) + len(p2p), len(stf), iid, r))

cands.sort(key=lambda x: (x[0], x[1]))
chosen = cands[:N]
print(f"headless python candidates: {len(cands)}; choosing {len(chosen)}")

samples, gold, ids = [], [], []
for tot, nf, iid, r in chosen:
    print("  total_tests=%-4d files=%d %-30s %s" % (tot, nf, r["repo"], iid[-12:]))
    s = dict(r)
    for c in LIST_COLS:
        s[c] = repr(L(s.get(c)))
    samples.append(s)
    gold.append({"instance_id": iid, "patch": r["patch"]})
    ids.append(iid)

os.makedirs("smoke", exist_ok=True)
with open("smoke/sample_n.jsonl", "w") as f:
    for s in samples:
        f.write(json.dumps(s) + "\n")
with open("smoke/gold_n.json", "w") as f:
    json.dump(gold, f)
with open("smoke/select_n.txt", "w") as f:
    f.write("\n".join(ids) + "\n")
with open("smoke/filter_n.regex", "w") as f:
    f.write("(" + "|".join(re.escape(i) for i in ids) + ")")
print(f"wrote smoke/sample_n.jsonl ({len(samples)}), gold_n.json, select_n.txt, filter_n.regex")
