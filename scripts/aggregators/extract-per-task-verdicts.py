#!/usr/bin/env python3
"""Extract a PER-TASK verdict table for Pool A from the S3 results bucket.

bd benchmarks-3xi.1 (Track A — separate model CAPABILITY from
PRETRAINING-DISTRIBUTION-MATCH). The canonical aggregator
(scripts/update-sweep-status.sh) collapses Pool A per-task `result.json`
objects to BENCH-LEVEL pass-rates; it never emits a per-task table. This
script materialises that missing table so we can stratify pass/fail by
language / task-class / difficulty.

Pool A writes one `result.json` (singular) per (campaign, target, bench,
task) under
    s3://<bucket>/<campaign>/<target>/<bench>/<task>/result.json
with n_tasks=1 and pass_rate in {0,1}. (Pool B writes `results.json` —
plural — one per (model,bench); those are Python-homogeneous aggregates and
are deliberately NOT pulled here.)

This script is READ-ONLY against S3 and writes only data/per-task-verdicts.csv
(it does NOT touch board.json / criterion-matrix.csv / sweep-status.md).

Filtering mirrors update-sweep-status.sh so the per-task sums reconcile
against the dashboard:
  * exclude _deprecated*/ , lm-eval-raw/ , bcb-raw/ , logs/ S3 prefixes;
  * drop BOARD_JUNK_CAMPAIGN_RE campaigns (the "must never render" set);
  * keep smoke/probe/debug/test campaigns but flag them (is_smoke=1) so the
    reconciliation step can exclude them exactly as latest_per_pair does;
  * alias claude-opus-4-7 -> us.anthropic.claude-opus-4-7 (direct vs Bedrock).

Usage:
    extract-per-task-verdicts.py [--fixture-dir DIR] [--out PATH] [--meta PATH]

--fixture-dir : use a local mirror of the bucket (a tree of result.json) instead
                of hitting S3. Used for offline dev / reproducible re-runs. When
                omitted the script does ONE `aws s3 cp --recursive` (~20-40s).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import tempfile

# Mirrors update-sweep-status.sh:BOARD_JUNK_CAMPAIGN_RE (the anchored
# "must never render" set) and SMOKE_CAMPAIGN_RE. Keep in sync with the shell.
BOARD_JUNK_CAMPAIGN_RE = re.compile(
    r"^(<ISSUE>-<CAMPAIGN>-secbench11-2026-05-26"
    r"|<CAMPAIGN>-secbench-tp8-2026-05-27"
    r"|to4-nemotron120-cvebench-thinkingon-2026-05-30"
    r"|to4-qwen3-235b-cvebench-2026-05-31"
    r"|to4-qwen3-235b-cvebench-thinkingon-2026-05-31"
    r"|to4-qwen3-235b-cvebench-thinkingon-b300-2026-06-01)$"
)
SMOKE_CAMPAIGN_RE = re.compile(r"(smoke|probe|debug|test)", re.IGNORECASE)
THINK_ON_RE = re.compile(r"-think(ing)?-?on(-|$)", re.IGNORECASE)
THINK_OFF_RE = re.compile(r"-think(ing)?-?off(-|$)", re.IGNORECASE)

# A Pool A record is any whose bench name starts with one of these.
POOL_A_PREFIXES = ("cybergym", "sec-bench", "cve-bench", "exploitbench")

S3_BUCKET = os.environ.get("S3_BUCKET", "<RESULTS_BUCKET>")

# Opus runs land under two model_ids (direct API vs Bedrock); the roster keys
# on the Bedrock form. Mirror update-sweep-status.sh's aliasing.
MODEL_ALIASES = {"claude-opus-4-7": "us.anthropic.claude-opus-4-7"}

CSV_COLUMNS = [
    "model_id", "model", "family", "target", "bench", "campaign",
    "task_id", "pass", "wall_s", "tokens_in", "tokens_out",
    "task_type", "verdict", "reason", "thinking", "harness", "max_turns",
    "is_smoke", "started_at", "completed_at",
]


def load_model_roster(meta_path: str) -> dict:
    """model_id -> {name, family} from board-meta.json (the curated registry)."""
    roster = {}
    try:
        meta = json.load(open(meta_path))
    except Exception as exc:  # pragma: no cover - defensive
        sys.stderr.write(f"[warn] could not read {meta_path}: {exc}; "
                         "model/family columns will be blank\n")
        return roster
    for m in meta.get("models", []):
        mid = (m.get("match") or {}).get("model_id")
        if mid:
            roster[mid] = {"name": m.get("name", ""), "family": m.get("family", "")}
    return roster


def s3_mirror(dest: str) -> None:
    """One parallelised `aws s3 cp --recursive` of every result.json (perf:
    mirrors update-sweep-status.sh:fetch_all_results). result.json (singular)
    only — Pool B's results.json is excluded by the suffix."""
    cmd = [
        "aws", "s3", "cp", f"s3://{S3_BUCKET}/", dest + "/",
        "--recursive", "--no-progress", "--exclude", "*",
        "--include", "*result.json",
    ]
    sys.stderr.write("[info] mirroring result.json from S3 (one recursive cp)...\n")
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def iter_result_files(root: str):
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if fn != "result.json":
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if rel.startswith("_deprecated"):
                continue
            if any(seg in rel for seg in ("/lm-eval-raw/", "/bcb-raw/", "/logs/")):
                continue
            yield full


def infer_thinking(rec: dict) -> str:
    extra = rec.get("extra") or {}
    if extra.get("enable_thinking") is True:
        return "on"
    if extra.get("enable_thinking") is False:
        return "off"
    campaign = rec.get("campaign") or ""
    if THINK_ON_RE.search(campaign):
        return "on"
    if THINK_OFF_RE.search(campaign):
        return "off"
    return "unknown"


def harness_class(extra: dict) -> str:
    """Raw harness_variant -> condition value. Mirrors the board's harness_variants
    rule (<ISSUE>/<ISSUE> substrings -> '<ISSUE>'; absent -> 'stock')."""
    hv = extra.get("harness_variant")
    if hv is None:
        return "stock"
    variant = hv.get("variant", "") if isinstance(hv, dict) else str(hv)
    if not variant:
        return "stock"
    if "<ISSUE>" in variant or "<ISSUE>" in variant or "bd-227" in variant:
        return "<ISSUE>"
    if variant == "stock" or variant.startswith("stock"):
        return "stock"
    return variant  # surface verbatim so an undeclared value is visible


def verdict_of(rec: dict) -> str:
    """Compact per-bench outcome signal beyond pass/fail."""
    extra = rec.get("extra") or {}
    if "sanitizer_verdict" in extra:        # cybergym, cve-bench
        return str(extra.get("sanitizer_verdict"))
    if "sanitizer_triggered" in extra:      # sec-bench
        return "triggered" if extra.get("sanitizer_triggered") else "not_triggered"
    if "score_value" in extra:              # cve-bench fallback
        return f"score={extra.get('score_value')}"
    return ""


def build_rows(root: str, roster: dict):
    rows, n_junk, n_total = [], 0, 0
    for path in iter_result_files(root):
        try:
            rec = json.load(open(path))
        except Exception:
            continue
        bench = rec.get("bench") or ""
        if not bench.startswith(POOL_A_PREFIXES):
            continue
        n_total += 1
        campaign = rec.get("campaign") or ""
        if BOARD_JUNK_CAMPAIGN_RE.match(campaign):
            n_junk += 1
            continue
        model_id = rec.get("model_id") or ""
        model_id = MODEL_ALIASES.get(model_id, model_id)
        if not model_id:
            continue
        extra = rec.get("extra") or {}
        task_id = extra.get("task_id") or extra.get("instance_id") or ""
        meta = roster.get(model_id, {})
        pr = rec.get("pass_rate")
        is_smoke = bool(extra.get("smoke")) or bool(SMOKE_CAMPAIGN_RE.search(campaign))
        rows.append({
            "model_id": model_id,
            "model": meta.get("name", ""),
            "family": meta.get("family", ""),
            "target": rec.get("target") or "",
            "bench": bench,
            "campaign": campaign,
            "task_id": task_id,
            "pass": "" if pr is None else int(round(float(pr))),
            "wall_s": rec.get("wall_time_seconds", ""),
            "tokens_in": rec.get("tokens_in", ""),
            "tokens_out": rec.get("tokens_out", ""),
            "task_type": extra.get("task_type", ""),
            "verdict": verdict_of(rec),
            "reason": (extra.get("reason") or "").replace("\n", " ").strip(),
            "thinking": infer_thinking(rec),
            "harness": harness_class(extra),
            "max_turns": extra.get("max_messages", ""),  # only cve-bench stamps it
            "is_smoke": int(is_smoke),
            "started_at": rec.get("started_at", ""),
            "completed_at": rec.get("completed_at", ""),
        })
    return rows, n_total, n_junk


def reconcile(rows):
    """Replicate latest_per_pair selection on the non-smoke per-task rows and
    print the resulting (model, bench, harness) canonical pass-rates to stderr,
    so they can be eyeballed against docs/results/sweep-status.md."""
    from collections import defaultdict
    # group by (model_id, bench, harness); within a group choose the campaign the
    # board would pick: most tasks, then highest pass-rate, then latest completed.
    by_cell = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r["is_smoke"]:
            continue
        by_cell[(r["model_id"], r["bench"], r["harness"])][r["campaign"]].append(r)
    sys.stderr.write("\n[reconcile] canonical per-cell pass-rates "
                     "(board-selected campaign; non-smoke):\n")
    sys.stderr.write(f"  {'model_id':46s} {'bench':14s} {'harn':6s} "
                     f"{'pass/n':>8s}  rate   campaign\n")
    for (mid, bench, harn) in sorted(by_cell):
        camps = by_cell[(mid, bench, harn)]
        # board sort key: [n_tasks, pass_rate, completed_at] then last
        def camp_key(item):
            _camp, recs = item
            n = len(recs)
            rate = sum(x["pass"] for x in recs if x["pass"] != "") / n if n else 0
            last = max((x["completed_at"] or "") for x in recs)
            return (n, rate, last)
        camp, recs = max(camps.items(), key=camp_key)
        n = len(recs)
        passes = sum(x["pass"] for x in recs if x["pass"] != "")
        rate = passes / n if n else 0
        sys.stderr.write(f"  {mid:46s} {bench:14s} {harn:6s} "
                         f"{f'{passes}/{n}':>8s}  {rate:.3f}  {camp}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    ap.add_argument("--fixture-dir", default=os.environ.get("RESULTS_FIXTURE_DIR"),
                    help="local mirror of the bucket (skip S3 fetch)")
    ap.add_argument("--out", default=os.path.join(repo, "data", "per-task-verdicts.csv"))
    ap.add_argument("--meta", default=os.path.join(repo, "docs", "board", "board-meta.json"))
    ap.add_argument("--no-reconcile", action="store_true")
    args = ap.parse_args()

    roster = load_model_roster(args.meta)

    tmp = None
    root = args.fixture_dir
    if not root:
        tmp = tempfile.mkdtemp(prefix="per-task-")
        s3_mirror(tmp)
        root = tmp
    try:
        rows, n_total, n_junk = build_rows(root, roster)
    finally:
        if tmp:
            subprocess.run(["rm", "-rf", tmp], check=False)

    rows.sort(key=lambda r: (r["bench"], r["model_id"], r["campaign"], r["task_id"]))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows)

    n_smoke = sum(r["is_smoke"] for r in rows)
    sys.stderr.write(
        f"\n[done] {len(rows)} Pool A per-task rows -> {args.out}\n"
        f"       (scanned {n_total} Pool A records; dropped {n_junk} junk-campaign; "
        f"{n_smoke} rows flagged is_smoke)\n")
    if not args.no_reconcile:
        reconcile(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
