# _rebench_slice_build.py — build the SWE-rebench-v2 small-n slice + grading inputs
#
# bd benchmarks-3xi.2.1 (rebench/OpenHands half, Phase 0/1). Analog of
# _swebench_pro_smoke_build.py for the OpenHands-native cell. Streams
# nebius/SWE-rebench-v2 (single config `default`, split `train`; 32k rows, 20
# langs), keeps the smallest-test python instances, writes a reproducible local
# slice.jsonl (get_dataset() in OpenHands/benchmarks loads a local jsonl directly
# as split=train), picks a CHOSEN instance, and writes gold/empty predictions in
# SWE-bench prediction format. The slice + predictions feed both run_infer
# (inference) and _rebench_grade.py (grading) downstream.
#
# rebench-v2 instance schema (verified by streaming, 2026-06-16):
#   instance_id, repo, base_commit, patch, test_patch, problem_statement,
#   pr_description, created_at, image_name (docker.io/swerebenchv2/<repo>:<n>-<sha>),
#   language, interface, license, FAIL_TO_PASS, PASS_TO_PASS,
#   install_config={base_image_name,docker_specs,install,log_parser,test_cmd}, meta
# The prebuilt image lays the repo at /<reponame> with system python (NO conda,
# NO /testbed) -> see the SWERebenchEvaluation overrides + _rebench_grade.py.
#
# Run from /opt/harnesses/openhands-benchmarks via the OpenHands uv env (datasets):
#   uv run python _rebench_slice_build.py
# Validated 2026-06-16: CHOSEN=codezonediitj__pydatastructs-177 (1 F2P, pytest).

import itertools
import json
import os

from datasets import load_dataset

DS = "nebius/SWE-rebench-v2"
OUT = "/opt/harnesses/openhands-benchmarks/_rebench"
PREFER = ["pydatastructs", "altair", "proxy.py", "cfn-lint", "cfn-python-lint", "litellm"]
MODEL = "rebench-smoke"


def asl(v):
    if isinstance(v, list):
        return v
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return []
    return v or []


def main():
    os.makedirs(OUT, exist_ok=True)
    ds = load_dataset(DS, split="train", streaming=True)
    cands = []
    for row in itertools.islice(ds, 0, 6000):
        if str(row.get("language") or "").lower() != "python":
            continue
        f2p, p2p = asl(row.get("FAIL_TO_PASS")), asl(row.get("PASS_TO_PASS"))
        tot = len(f2p) + len(p2p)
        if len(f2p) < 1 or tot > 4:
            continue
        cands.append((tot, len(f2p), row))
    cands.sort(key=lambda x: (x[0], x[1]))

    chosen = None
    for _, _, row in cands:
        if any(p in row["instance_id"] for p in PREFER):
            chosen = row
            break
    if chosen is None and cands:
        chosen = cands[0][2]

    slice_rows = [r for _, _, r in cands[:12]]
    with open(f"{OUT}/slice.jsonl", "w") as f:
        for r in slice_rows:
            f.write(json.dumps(r, default=str) + "\n")

    cid = chosen["instance_id"]
    open(f"{OUT}/CHOSEN_ID", "w").write(cid + "\n")
    with open(f"{OUT}/predictions_gold.jsonl", "w") as f:
        f.write(json.dumps({"instance_id": cid, "model_patch": chosen["patch"], "model_name_or_path": MODEL}) + "\n")
    with open(f"{OUT}/predictions_empty.jsonl", "w") as f:
        f.write(json.dumps({"instance_id": cid, "model_patch": "", "model_name_or_path": MODEL}) + "\n")

    cts = [r["created_at"] for _, _, r in cands]
    print(f"dataset={DS} config=default split=train | python<=4test candidates={len(cands)} slice={len(slice_rows)}")
    print(f"created_at range (slice pool): {min(cts)} -> {max(cts)}")
    print(f"CHOSEN={cid} repo={chosen['repo']} image={chosen['image_name']} created_at={chosen['created_at']}")
    print(f"  F2P={asl(chosen.get('FAIL_TO_PASS'))} P2P_n={len(asl(chosen.get('PASS_TO_PASS')))}")
    print(f"  test_cmd={(chosen.get('install_config') or {}).get('test_cmd')}")


if __name__ == "__main__":
    main()
