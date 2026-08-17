# _swebench_pro_smoke_build.py — build no-LLM grading-smoke inputs for SWE-bench Pro
#
# Part of bd benchmarks-3xi.2.1 (agentic coding bench standup, Phase 0).
# Selects a minimal headless-Python instance from ScaleAI/SWE-bench_Pro that has
# a run_scripts/ dir, then writes one-row sample.jsonl (list cols as str()-reprs,
# since swe_bench_pro_eval.py eval()s them), gold_patches.json, empty_patches.json.
#
# Run from /opt/harnesses/swebench-pro (venv with: pandas docker datasets).
# Grade FROM the repo dir so dockerfiles/ resolves (CWD-relative in the grader):
#   cd repo && python swe_bench_pro_eval.py \
#     --raw_sample_path=../smoke/sample.jsonl --patch_path=../smoke/gold_patches.json \
#     --output_dir=../smoke/out_gold --scripts_dir=run_scripts \
#     --dockerhub_username=jefzda --use_local_docker --num_workers=1
# Validated 2026-06-15: gold -> accuracy 1.0, empty -> 0.0 (commit ca10a60).

import os, json, ast
from datasets import load_dataset

REPO = "/opt/harnesses/swebench-pro/repo"
RS = os.path.join(REPO, "run_scripts")
have = set(os.listdir(RS))
ds = load_dataset("ScaleAI/SWE-bench_Pro", split="test")
LIST_COLS = ["fail_to_pass", "pass_to_pass", "selected_test_files_to_run"]


def L(v):
    if isinstance(v, (list, tuple)):
        return list(v)
    try:
        return list(ast.literal_eval(v))
    except Exception:
        return []


GUI = {"qutebrowser/qutebrowser"}
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
print("headless python candidates:", len(cands))
for tot, nf, iid, r in cands[:10]:
    print("  total_tests=%-4d files=%d %-28s %s" % (tot, nf, r["repo"], iid[-12:]))

_, _, iid, row = cands[0]
print("CHOSEN:", iid, "| repo:", row["repo"])

s = dict(row)
for c in LIST_COLS:
    s[c] = repr(L(s.get(c)))
with open("smoke/sample.jsonl", "w") as f:
    f.write(json.dumps(s) + "\n")
with open("smoke/gold_patches.json", "w") as f:
    json.dump([{"instance_id": iid, "patch": row["patch"]}], f)
with open("smoke/empty_patches.json", "w") as f:
    json.dump([{"instance_id": iid, "patch": ""}], f)
open("smoke/CHOSEN_ID", "w").write(iid + "\n")
print("f2p:", L(row.get("fail_to_pass")))
print("p2p_count:", len(L(row.get("pass_to_pass"))))
print("selected_test_files:", L(row.get("selected_test_files_to_run")))
print("image: jefzda/sweap-images:" + row["dockerhub_tag"])
