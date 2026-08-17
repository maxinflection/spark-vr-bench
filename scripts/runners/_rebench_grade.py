#!/usr/bin/env python3
"""_rebench_grade.py — execution grader for SWE-rebench-v2 (OpenHands half, bd 3xi.2.1).

WHY a thin grader instead of the fork's run_evaluation: SWE-rebench-v2's prebuilt
instance images (docker.io/swerebenchv2/<repo>:<n>-<sha>) lay the repo at
/<reponame> with the system python (NO conda, NO /testbed), whereas the
SWE-bench-fork local path assumes the legacy conda/testbed image layout and
crashes building an (unused) conda env (`KeyError: 'python'` in
make_env_script_list_py) for these prebuilt images. So we run the CANONICAL eval
ourselves — exactly the fork's make_eval_script_list_py sequence (reset test
files to base, apply test_patch, run install_config.test_cmd between markers) —
inside the prebuilt image, and parse the captured log with the fork's OWN
log-parser registry (MAP_REPO_TO_PARSER[install_config['log_parser']]). Faithful
(rebench image + rebench test_cmd + rebench parser), transparent, and it emits
the three independent signals the grading audit triangulates:
  (1) candidate-patch git-apply exit,  (2) test_cmd exit,
  (3) per-test PASSED/FAILED from the parsed log -> resolved verdict.

Run in the fork venv (so swebench.harness.log_parsers imports):
  /opt/harnesses/swe-rebench-fork/.venv/bin/python _rebench_grade.py \
    --dataset <slice.jsonl> --predictions <preds.jsonl> --out <report_dir>
Resolved iff every FAIL_TO_PASS test is PASSED AND every PASS_TO_PASS test is PASSED.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

from swebench.harness.log_parsers import MAP_REPO_TO_PARSER

START = ">>>RB_START_TEST<<<"
END = ">>>RB_END_TEST<<<"

EVAL_SH = r"""set +e
REPO_DIR="$RB_REPO_DIR"
if [ ! -d "$REPO_DIR/.git" ]; then
  REPO_DIR="$(dirname "$(find / -maxdepth 4 -name .git -type d 2>/dev/null | grep -v /rebench_grade | head -1)")"
fi
cd "$REPO_DIR" || { echo "RB_NO_REPO_DIR"; exit 3; }
echo "RB_REPO_DIR_USED=$REPO_DIR"
git config --global --add safe.directory "$REPO_DIR" >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1; git clean -fdq >/dev/null 2>&1
git checkout "$RB_BASE" >/dev/null 2>&1
echo "RB_HEAD=$(git rev-parse HEAD 2>&1)"
RB_MODEL_APPLY=skip
if [ -s /rebench_grade/model.patch ]; then
  if git apply -v /rebench_grade/model.patch >/rebench_grade/model_apply.log 2>&1; then
    RB_MODEL_APPLY=ok
  elif patch -p1 -i /rebench_grade/model.patch >>/rebench_grade/model_apply.log 2>&1; then
    RB_MODEL_APPLY=ok_patch
  else
    RB_MODEL_APPLY=fail
  fi
fi
echo "RB_MODEL_APPLY=$RB_MODEL_APPLY"
# reset test files to base, then apply the gold test patch
if [ -n "$RB_TEST_FILES" ]; then git checkout "$RB_BASE" -- $RB_TEST_FILES >/dev/null 2>&1; fi
git apply -v /rebench_grade/test.patch >/rebench_grade/test_apply.log 2>&1
echo "RB_TEST_APPLY_EXIT=$?"
echo "%s"
eval "$RB_TEST_CMD"
echo "RB_TEST_EXIT=$?"
echo "%s"
""" % (START, END)


def modified_files(patch_text: str):
    files = []
    for line in patch_text.splitlines():
        m = re.match(r"^\+\+\+\s+b/(.+)$", line)
        if m:
            files.append(m.group(1).strip())
    return files


def grade_one(inst: dict, model_patch: str, image: str, repo_dir: str, timeout: int):
    ic = inst.get("install_config") or {}
    test_cmd = ic.get("test_cmd")
    if isinstance(test_cmd, list):
        test_cmd = " ".join(test_cmd)
    parser_name = ic.get("log_parser")
    test_patch = inst.get("test_patch") or ""
    f2p = inst.get("FAIL_TO_PASS") or []
    p2p = inst.get("PASS_TO_PASS") or []
    if isinstance(f2p, str):
        f2p = json.loads(f2p)
    if isinstance(p2p, str):
        p2p = json.loads(p2p)

    workdir = tempfile.mkdtemp(prefix="rbg_")
    with open(os.path.join(workdir, "model.patch"), "w") as f:
        f.write(model_patch or "")
    with open(os.path.join(workdir, "test.patch"), "w") as f:
        f.write(test_patch)
    with open(os.path.join(workdir, "eval.sh"), "w") as f:
        f.write(EVAL_SH)

    cmd = [
        "docker", "run", "--rm",
        "-v", f"{workdir}:/rebench_grade:rw",
        "-e", f"RB_REPO_DIR={repo_dir}",
        "-e", f"RB_BASE={inst['base_commit']}",
        "-e", f"RB_TEST_CMD={test_cmd}",
        "-e", f"RB_TEST_FILES={' '.join(modified_files(test_patch))}",
        "--entrypoint", "bash", image, "/rebench_grade/eval.sh",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    log = proc.stdout + "\n" + proc.stderr

    def _grab(key):
        m = re.search(rf"^{key}=(.*)$", log, re.MULTILINE)
        return m.group(1).strip() if m else None

    model_apply = _grab("RB_MODEL_APPLY")
    test_apply_exit = _grab("RB_TEST_APPLY_EXIT")
    test_exit = _grab("RB_TEST_EXIT")

    section = log
    if START in log and END in log:
        section = log.split(START, 1)[1].split(END, 1)[0]

    parser = MAP_REPO_TO_PARSER.get(parser_name)
    if parser is None:
        raise SystemExit(f"no parser named {parser_name!r} in fork registry")
    parsed = parser(section, None)  # pytest-family parsers ignore test_spec

    f2p_status = {t: parsed.get(t, "MISSING") for t in f2p}
    p2p_status = {t: parsed.get(t, "MISSING") for t in p2p}
    f2p_ok = all(v == "PASSED" for v in f2p_status.values())
    p2p_ok = all(v == "PASSED" for v in p2p_status.values()) if p2p else True
    resolved = bool(f2p) and f2p_ok and p2p_ok

    return {
        "instance_id": inst["instance_id"],
        "image": image,
        "repo_dir": repo_dir,
        "resolved": resolved,
        "model_patch_apply": model_apply,
        "model_patch_chars": len(model_patch or ""),
        "test_patch_apply_exit": test_apply_exit,
        "test_cmd_exit": test_exit,
        "docker_exit": proc.returncode,
        "FAIL_TO_PASS": f2p_status,
        "PASS_TO_PASS_n": len(p2p),
        "PASS_TO_PASS_failed": [t for t, v in p2p_status.items() if v != "PASSED"],
        "n_parsed_tests": len(parsed),
        "log_parser": parser_name,
        "_log": log,
        "_workdir": workdir,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True, help="local jsonl slice")
    ap.add_argument("--predictions", required=True, help="jsonl: {instance_id, model_patch}")
    ap.add_argument("--out", required=True, help="report dir")
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    ds = {}
    with open(args.dataset) as f:
        for line in f:
            line = line.strip()
            if line:
                r = json.loads(line)
                ds[r["instance_id"]] = r
    preds = []
    with open(args.predictions) as f:
        for line in f:
            line = line.strip()
            if line:
                preds.append(json.loads(line))

    os.makedirs(args.out, exist_ok=True)
    reports = []
    for p in preds:
        iid = p["instance_id"]
        if iid not in ds:
            print(f"SKIP {iid}: not in dataset", file=sys.stderr)
            continue
        inst = ds[iid]
        repo_dir = "/" + str(inst["repo"]).split("/")[-1]
        rep = grade_one(inst, p.get("model_patch", ""), inst["image_name"], repo_dir, args.timeout)
        log = rep.pop("_log")
        with open(os.path.join(args.out, f"{iid}.testlog.txt"), "w") as lf:
            lf.write(log)
        reports.append(rep)
        print(json.dumps(rep, indent=2))

    with open(os.path.join(args.out, "report.json"), "w") as f:
        json.dump(reports, f, indent=2)
    n_res = sum(1 for r in reports if r["resolved"])
    print(f"\n=== REBENCH GRADE SUMMARY: {n_res}/{len(reports)} resolved ===")


if __name__ == "__main__":
    main()
