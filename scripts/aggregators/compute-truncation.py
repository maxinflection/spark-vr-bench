#!/usr/bin/env python3
"""compute-truncation.py — retroactive thinking-on truncation diagnostic (bd <CAMPAIGN>.1.1).

For every Pool B lm-eval cell (humaneval-plus, ifeval) referenced by board.json,
fetch the per-sample log (`samples_<task>_*.jsonl`) from S3 and compute the
TRUNCATION RATE: the fraction of generations that hit the token budget without
yielding a usable answer.

Why this works retroactively (validated 2026-06-22, memory
gemma-truncation-retroactively-computable-2026-06-22): on a finish_reason=length
truncation the gemma4 reasoning parser DISCARDS the unclosed <think> block, so a
budget-truncated sample lands as near-empty parsed CONTENT (e.g. a 2-char stub).
We detect it as: flattened `filtered_resps` text length < --empty-threshold chars.
On 2lh-gemma26a4b-poolb-thinkon ifeval this yields 140/541 = 0.259 — exactly the
25.9% in bd 2lh.

What this CANNOT do retroactively: split truncation into degenerate-loop vs
productive-overflow. That needs the raw pre-parser completion, which these
campaigns already discarded. loop_rate / overflow_rate therefore stay null until
the harness captures raw completions on FUTURE runs (the other half of <CAMPAIGN>.1.1).

BCB-Hard truncation is NOT computed here — it is the runner's
extra.bcb_none_filter.null_rate (bd <ISSUE>), already stitched onto the measurement
by the jq emitter and copied to truncation_rate by finalize-board.py.

Output: a cache JSON keyed by "<campaign>|<target>|<bench>" ->
  {truncation_rate, n_truncated, n_total, method, samples_key}
consumed by scripts/finalize-board.py. Idempotent + incremental: cached keys are
not re-fetched unless --refresh.

Issue: benchmarks-<CAMPAIGN>.1.1
"""
from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from pathlib import Path
from typing import Any

BUCKET = "<RESULTS_BUCKET>"
# Pool B benches whose truncation is sample-derived (lm-eval). BCB uses null_rate.
LMEVAL_BENCHES = ("humaneval-plus", "ifeval")
EMPTY_THRESHOLD = 5  # chars; a parsed response shorter than this == truncated/empty

log = logging.getLogger("compute-truncation")


def s3_ls_recursive(bucket: str, prefix: str) -> list[str]:
    if not prefix.endswith("/"):
        prefix += "/"
    cmd = ["aws", "s3", "ls", f"s3://{bucket}/{prefix}", "--recursive"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("s3 ls failed at %s: %s", prefix, getattr(e, "stderr", e))
        return []
    return [ln.split(maxsplit=3)[3] for ln in out.splitlines() if len(ln.split(maxsplit=3)) >= 4]


def s3_cat(bucket: str, key: str) -> str | None:
    cmd = ["aws", "s3", "cp", f"s3://{bucket}/{key}", "-"]
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=300).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("s3 cp failed for %s: %s", key, getattr(e, "stderr", e))
        return None


def _resp_text(rec: dict[str, Any]) -> str:
    """Flatten a sample record's filtered_resps (list[str] | list[list[str]]) to text."""
    def walk(x: Any) -> list[str]:
        if isinstance(x, str):
            return [x]
        if isinstance(x, list):
            return [s for e in x for s in walk(e)]
        return []
    fr = rec.get("filtered_resps")
    if fr is None:
        fr = rec.get("resps")
    return "".join(walk(fr))


def truncation_for_samples(jsonl: str, threshold: int) -> tuple[int, int]:
    """Return (n_truncated, n_total) from a samples JSONL blob."""
    n_total = n_trunc = 0
    for line in jsonl.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        n_total += 1
        if len(_resp_text(rec).strip()) < threshold:
            n_trunc += 1
    return n_trunc, n_total


def cells_from_board(board: dict[str, Any]) -> list[tuple[str, str, str]]:
    """Distinct (campaign, target, bench_id) lm-eval cells to scan, from board.json."""
    seen: set[tuple[str, str, str]] = set()
    for score in board.get("scores", []):
        bench = score.get("bench_id")
        if bench not in LMEVAL_BENCHES:
            continue
        for m in score.get("measurements", []):
            camp = m.get("campaign")
            tgt = m.get("target")
            if camp and tgt:
                seen.add((camp, tgt, bench))
    return sorted(seen)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--board", default="docs/board/board.json", help="board.json to read cells from")
    p.add_argument("--cache", default="data/truncation-cache.json", help="truncation cache to update")
    p.add_argument("--bucket", default=BUCKET)
    p.add_argument("--empty-threshold", type=int, default=EMPTY_THRESHOLD)
    p.add_argument("--refresh", action="store_true", help="recompute cached keys instead of skipping them")
    p.add_argument("--only", action="append", default=[], help="restrict to campaigns containing this substring")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    board = json.loads(Path(args.board).read_text())
    cache_path = Path(args.cache)
    cache: dict[str, Any] = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    cells = cells_from_board(board)
    if args.only:
        cells = [c for c in cells if any(sub in c[0] for sub in args.only)]
    log.info("%d lm-eval cells in board.json", len(cells))

    scanned = skipped = failed = 0
    for camp, tgt, bench in cells:
        key = f"{camp}|{tgt}|{bench}"
        if key in cache and not args.refresh:
            skipped += 1
            continue
        prefix = f"{camp}/{tgt}/{bench}/lm-eval-raw/"
        samples = [k for k in s3_ls_recursive(args.bucket, prefix)
                   if "/samples_" in k and k.endswith(".jsonl")]
        if not samples:
            log.warning("no samples jsonl under %s", prefix)
            failed += 1
            continue
        samples_key = sorted(samples)[-1]  # latest if multiple
        blob = s3_cat(args.bucket, samples_key)
        if blob is None:
            failed += 1
            continue
        n_trunc, n_total = truncation_for_samples(blob, args.empty_threshold)
        if n_total == 0:
            failed += 1
            continue
        rate = round(n_trunc / n_total, 4)
        cache[key] = {
            "truncation_rate": rate,
            "n_truncated": n_trunc,
            "n_total": n_total,
            "method": f"near-empty-content<{args.empty_threshold}chars",
            "samples_key": samples_key,
        }
        scanned += 1
        log.info("  %s -> %d/%d = %.4f", key, n_trunc, n_total, rate)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(cache, indent=2, sort_keys=True) + "\n")
    log.info("cache %s: %d scanned, %d cached-skip, %d failed, %d total keys",
             cache_path, scanned, skipped, failed, len(cache))
    return 0


if __name__ == "__main__":
    sys.exit(main())
