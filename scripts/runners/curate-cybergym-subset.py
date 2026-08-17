#!/usr/bin/env python3
"""Curate the CyberGym n=40/50 POWERED task subsets (bd benchmarks-9g4.3.1).

The runner run-pool-a-cybergym.sh hard-codes CYBERGYM_TASKS_40 / CYBERGYM_TASKS_50.
This script REGENERATES those exact lists from the CyberGym task universe so the
curation is auditable and reproducible — it is the provenance for the hard-coded
arrays, not a runtime dependency.

WHY a seeded random sample (and not a stratified-by-language/difficulty pick):
  * The CyberGym universe (mask_map.json) is ENTIRELY C/C++ arvo:* / oss-fuzz:*
    crash-repro tasks -> stratify-by-language is moot (one stratum).
  * Difficulty is only known for the ~13 tasks already run (data/task-manifest.csv
    from bd 3xi.1); it cannot be known a priori for unseen tasks, so we cannot
    stratify the broader pool by difficulty.
  * The existing hand-picked 10-set is "5 solvable + 5 not" -- deliberately
    BALANCED, hence a biased pass-rate estimator. To honestly RANK the models
    (bd 9g4.3) we want an UNBIASED sample.
  => documented seeded random sample, stratified only by SOURCE (arvo vs oss-fuzz)
     to preserve the universe's 1368:139 (~90.8:9.2) proportion.

Nesting: 40 is a strict subset of 50, in list order, so a 40-run's per-task S3
results are reused when a later 50-run resumes (the b51 pool skips valid results).

Reproducibility: random.Random(seed).sample over the mask_map.json key order is
stable across CPython 3.x; mask_map.json is pinned (cybergym repo @ commit 3ae9067).

Usage:
  curate-cybergym-subset.py [--mask-map PATH] [--seed N] [--format bash|plain]
"""
import argparse
import json
import os
import random
import sys

DEFAULT_SEED = 20260617
# Stratum sizes for the 50-set; 40-set takes the first FORTY_* of each stratum.
ARVO_50, OSS_50 = 45, 5
ARVO_40, OSS_40 = 36, 4

# Search order for the pinned universe file (sandbox clone, then on-box install).
DEFAULT_MASK_MAP_CANDIDATES = (
    "/tmp/cybergym-src/mask_map.json",
    "/data/harnesses/cybergym/mask_map.json",
    "/opt/harnesses/cybergym/mask_map.json",
)


def find_mask_map(explicit):
    if explicit:
        return explicit
    for c in DEFAULT_MASK_MAP_CANDIDATES:
        if os.path.exists(c):
            return c
    sys.exit(
        "ERROR: mask_map.json not found in any default location; pass --mask-map. "
        "Tried: " + ", ".join(DEFAULT_MASK_MAP_CANDIDATES)
    )


def curate(mask_map_path, seed):
    with open(mask_map_path) as f:
        ids = list(json.load(f).keys())  # stable insertion order
    arvo = [i for i in ids if i.startswith("arvo:")]
    oss = [i for i in ids if i.startswith("oss-fuzz:")]
    if len(arvo) < ARVO_50 or len(oss) < OSS_50:
        sys.exit(
            f"ERROR: universe too small (arvo={len(arvo)}, oss-fuzz={len(oss)}); "
            f"need >= {ARVO_50}/{OSS_50}"
        )
    # Independent seeded draws per stratum (seed+1 for oss-fuzz so the two streams
    # don't share state). sample() preserves no order guarantee beyond determinism.
    arvo_s = random.Random(seed).sample(arvo, ARVO_50)
    oss_s = random.Random(seed + 1).sample(oss, OSS_50)
    forty = arvo_s[:ARVO_40] + oss_s[:OSS_40]
    fifty = forty + arvo_s[ARVO_40:ARVO_50] + oss_s[OSS_40:OSS_50]
    assert set(forty).issubset(set(fifty)), "40 must be a subset of 50"
    assert len(set(fifty)) == 50 and len(set(forty)) == 40, "no duplicates allowed"
    return forty, fifty, (len(arvo), len(oss))


def emit(name, lst, fmt):
    if fmt == "bash":
        print(f"readonly -a {name}=(")
        for t in lst:
            print(f'  "{t}"')
        print(")")
    else:
        print(f"# {name} (n={len(lst)})")
        for t in lst:
            print(t)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mask-map", default=None, help="path to cybergym mask_map.json")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--format", choices=("bash", "plain"), default="bash")
    ap.add_argument("--only", type=int, choices=(40, 50), default=None,
                    help="emit ONLY this subset's bare task IDs (one per line); "
                         "for install-time consumption")
    args = ap.parse_args()

    path = find_mask_map(args.mask_map)
    forty, fifty, (n_arvo, n_oss) = curate(path, args.seed)
    sys.stderr.write(
        f"[curate] mask_map={path} seed={args.seed} universe={n_arvo}arvo+{n_oss}oss-fuzz "
        f"-> n40 (36arvo+4oss) subset-of n50 (45arvo+5oss)\n"
    )
    if args.only is not None:
        for t in (forty if args.only == 40 else fifty):
            print(t)
        return
    emit("CYBERGYM_TASKS_40", forty, args.format)
    print()
    emit("CYBERGYM_TASKS_50", fifty, args.format)


if __name__ == "__main__":
    main()
