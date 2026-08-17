#!/usr/bin/env python3
"""check-parity.py — <ISSUE> local dry-run / parity check.

Builds a full-roster board.json BY HAND from the numbers the pre-rewire static
page (docs/mockups/sweep-board.html @ 9f4737a^, the hard-coded table) displayed,
then confirms the rewired page (bd <ISSUE>) would render the SAME canonical
headline number for every cell — by replicating its selectMeasurement('canonical')
selection here in Python and comparing against the static table.

It writes the assembled fixture to tests/board/parity-board.json so a human can
do the final visual/pixel pass in a browser:
    python3 -m http.server -d docs/board   # then open
    http://localhost:8000/index.html?data=../../tests/board/parity-board.json
(or copy parity-board.json next to index.html and open ?data=parity-board.json).

INTENDED divergences from the old static page (design decisions locked in
bd <ISSUE> / docs/research/benchmark-canonical-protocols.md — NOT regressions;
asserted/【documented below, the parity check accounts for them):
  1. SEC-bench was TWO columns (stock | patched); it is now ONE bench with a
     `harness` condition (stock / <ISSUE>). Canonical headline = the stock
     measurement. The patched number lives in the cell's drilldown.
  2. The `ᵗ` (thinking-off) marker is DROPPED on the Pool B code benches
     (HumanEval+, IFEval, BCB-Hard): their canonical_condition is omitted
     (authors are silent on thinking), so thinking-off is a factual label, not
     a deviation — the page only marks deviations-from-canonical.

Exit 0 = every cell's canonical number matches the static page; 1 = a mismatch.
stdlib only; no S3.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
META = REPO / "docs" / "board" / "board-meta.json"
SCHEMA = REPO / "docs" / "board" / "schema.json"
VALIDATOR = REPO / "scripts" / "validate-board-json.py"
OUT = HERE / "parity-board.json"
# Authoritative reference: the numbers the pre-rewire static page displayed,
# MACHINE-PARSED from git (not hand-retyped) so it is independent of the STATIC
# table that drives build_scores below — that independence is what makes the
# value-parity assertion meaningful rather than circular. Regenerate with
# `python3 tests/board/check-parity.py --regen-expected`.
EXPECTED_FILE = HERE / "static-expected.json"
STATIC_PAGE_REF = "9f4737a^:docs/mockups/sweep-board.html"

# data-run cell id -> (board model id, board bench id). Prefixes are matched
# longest-first because some contain hyphens (q36-27, g4-31, ...).
_MODEL_KEY = {
    "q36-27": "qwen3.6-27b-fp8", "q36-35": "qwen3.6-35b-a3b-fp8",
    "g4-31": "gemma4-31b-nvfp4", "g4-26": "gemma4-26b-a4b-nvfp4",
    "nem-120": "nemotron3-super-120b-a12b-nvfp4", "q35-122": "qwen3.5-122b-a10b-nvfp4",
    "q3-235": "qwen3-235b-a22b-thinking-awq", "opus47": "opus-4-7", "gpt55": "gpt-5-5",
}
_BENCH_KEY = {
    "he": "humaneval-plus", "if": "ifeval", "bcb": "bigcodebench-hard",
    "cg": "cybergym", "sec": "sec-bench", "sec-stock": "sec-bench",
    "sec-patched": "sec-bench-patched", "eb": "exploitbench-14",
}


def parse_static_page() -> dict:
    """Extract every data-run cell's displayed value from the real pre-rewire
    static page in git. Returns {model_id: {bench_id: float|str}}; numeric cells
    -> float, tier cells -> the label string (e.g. 'T1'). This is the source of
    truth the rewired page's render is checked against."""
    html = subprocess.run(["git", "-C", str(REPO), "show", STATIC_PAGE_REF],
                          capture_output=True, text=True, check=True).stdout
    out: dict = {}
    cell_re = re.compile(r'data-run="([^"]+)"[^>]*>\s*<span class="v[^"]*">([^<]+)</span>')
    for run_id, raw in cell_re.findall(html):
        prefix = next((p for p in sorted(_MODEL_KEY, key=len, reverse=True)
                       if run_id == p or run_id.startswith(p + "-")), None)
        if prefix is None:
            raise ValueError(f"unmapped data-run model prefix: {run_id}")
        suffix = run_id[len(prefix) + 1:]
        bench = _BENCH_KEY.get(suffix)
        if bench is None:
            raise ValueError(f"unmapped data-run bench suffix: {run_id} -> {suffix!r}")
        raw = raw.strip()
        val: object = float(raw) if re.fullmatch(r"[0-9.]+", raw) else raw
        out.setdefault(_MODEL_KEY[prefix], {})[bench] = val
    return out

# ── The static page's displayed numbers, by board model id → bench id → cell.
# A float = canonical headline ratio. "TBD"/"NA"/None encode non-numeric cells.
# Tier cells carry a (label, note). Absent (model,bench) keys = blank "—".
STATIC = {
    "qwen3.6-27b-fp8":        {"humaneval-plus":0.878,"ifeval":0.861,"bigcodebench-hard":0.304,"cybergym":0.200,"sec-bench":0.000},
    "qwen3.6-35b-a3b-fp8":    {"humaneval-plus":0.872,"ifeval":0.826,"bigcodebench-hard":0.324,"cybergym":0.400,"sec-bench":0.000},
    "gemma4-31b-nvfp4":       {"humaneval-plus":0.915,"ifeval":0.896,"bigcodebench-hard":0.291,"cybergym":0.700,"sec-bench":0.091,"sec-bench-patched":0.091},
    "gemma4-26b-a4b-nvfp4":   {"humaneval-plus":0.915,"ifeval":0.889,"bigcodebench-hard":0.264,"cybergym":"NA","sec-bench":0.000},
    "nemotron3-super-120b-a12b-nvfp4": {"humaneval-plus":0.902,"ifeval":0.784,"bigcodebench-hard":0.318},
    "qwen3.5-122b-a10b-nvfp4":{"humaneval-plus":0.872,"ifeval":0.861,"bigcodebench-hard":0.297},
    "qwen3-235b-a22b-thinking-awq": {"humaneval-plus":0.811,"ifeval":0.830,"bigcodebench-hard":0.284,"sec-bench":0.000,"exploitbench-14":("T1","1/14 · disc.")},
    "deepseek-v4-flash":      {},
    "opus-4-7":               {"humaneval-plus":0.939,"ifeval":0.832,"bigcodebench-hard":0.480,"cybergym":0.500,"sec-bench":0.455},
    "gpt-5-5":                {"humaneval-plus":0.939,"ifeval":0.856,"bigcodebench-hard":0.351,"cybergym":0.600,"sec-bench":0.727},
}

POOL_B = {"humaneval-plus": 164, "ifeval": 541, "bigcodebench-hard": 148}
FRONTIER = {"opus-4-7", "gpt-5-5"}


def build_scores() -> list[dict]:
    """Turn the static table into condition-tagged measurements, mirroring what
    --emit-json would produce from real result.json files for these cells."""
    scores = []
    for mid, cells in STATIC.items():
        for bench, val in cells.items():
            if bench == "sec-bench-patched":
                continue  # folded into the sec-bench cell below
            meas = []
            if bench in POOL_B:
                # code bench: single greedy pass; frontier is native thinking-on,
                # open-weight is the thinking-off bandage. Either way canonical
                # headline = this value (canonical_condition omitted).
                thinking = "on" if mid in FRONTIER else "off"
                meas.append({"condition": {"thinking": thinking}, "value": val, "n": POOL_B[bench], "status": "measured"})
            elif bench == "cybergym":
                if val == "NA":
                    meas.append({"condition": {"max_turns": "100"}, "value": None, "n": 10, "status": "na"})
                else:
                    meas.append({"condition": {"max_turns": "100"}, "value": val, "n": 10, "status": "measured"})
            elif bench == "sec-bench":
                meas.append({"condition": {"harness": "stock"}, "value": val, "n": 11, "status": "measured"})
                patched = cells.get("sec-bench-patched")
                if patched is not None:
                    meas.append({"condition": {"harness": "<ISSUE>"}, "value": patched, "n": 11, "status": "measured"})
            elif bench == "exploitbench-14":
                label, note = val
                meas.append({"condition": {"max_turns": "300", "context": "128k"},
                             "value": 1, "label": label, "n": 14, "status": "measured", "notes": note})
            scores.append({"model_id": mid, "bench_id": bench, "measurements": meas})
    return scores


# ── selectMeasurement('canonical') — faithful port of docs/board/index.html ──
def effective(cond, dim, dims):
    if cond and cond.get(dim) is not None:
        return cond[dim]
    d = dims.get(dim)
    return d.get("default") if d else None


def deviating_axes(cond, canonical, dims):
    if not canonical:
        return []
    return [dim for dim in canonical if effective(cond, dim, dims) != canonical[dim]]


def select_canonical(measurements, bench, dims):
    canonical = bench.get("canonical_condition")
    measured = [(i, m) for i, m in enumerate(measurements)
                if (m.get("status", "measured") == "measured") and m.get("value") is not None]
    if not measured:
        return None
    # sort key mirrors the JS: fewest deviating axes, then highest n, then latest
    # completed_at, then last-listed (higher index wins) — encode as a max-key.
    def key(item):
        i, m = item
        dev = len(deviating_axes(m.get("condition", {}), canonical, dims))
        return (-dev, m.get("n") or 0, m.get("completed_at") or "", i)
    i, m = max(measured, key=key)
    return m, deviating_axes(m.get("condition", {}), canonical, dims)


def _patched_value(measurements):
    for m in measurements:
        if m.get("condition", {}).get("harness") == "<ISSUE>":
            return m.get("value")
    return None


def main() -> int:
    if "--regen-expected" in sys.argv[1:]:
        exp = parse_static_page()
        EXPECTED_FILE.write_text(json.dumps(exp, indent=2, sort_keys=True) + "\n")
        n = sum(len(v) for v in exp.values())
        print(f"[regen] wrote {EXPECTED_FILE.relative_to(REPO)} from {STATIC_PAGE_REF} "
              f"({n} static cells across {len(exp)} models)")
        return 0

    meta = json.loads(META.read_text())
    dims = meta["condition_dims"]
    board = {
        "schema_version": meta["schema_version"],
        "generated_at": "2026-05-27T00:00:00Z",
        "rev": meta.get("rev", "") + "-parity",
        "condition_dims": dims,
        "models": [{k: v for k, v in m.items() if k != "match"} for m in meta["models"]],
        "benches": [{k: v for k, v in b.items() if k != "emit"} for b in meta["benches"]],
        "scores": build_scores(),
    }
    OUT.write_text(json.dumps(board, indent=2) + "\n")
    print(f"[build] wrote {OUT.relative_to(REPO)} ({len(board['scores'])} cells) from the STATIC table")

    # 1. schema-valid
    r = subprocess.run([sys.executable, str(VALIDATOR), str(OUT), "--schema", str(SCHEMA)])
    if r.returncode != 0:
        print("PARITY FAIL: fixture is not schema-valid", file=sys.stderr)
        return 1

    # 2. canonical-view numbers match the AUTHORITATIVE static-page values
    # (static-expected.json, machine-parsed from the real pre-rewire page —
    # independent of the STATIC table that built the board, so a transcription
    # error in STATIC surfaces here instead of comparing STATIC to itself).
    if not EXPECTED_FILE.exists():
        print(f"missing {EXPECTED_FILE}; run: python3 {Path(__file__).name} --regen-expected",
              file=sys.stderr)
        return 2
    expected = json.loads(EXPECTED_FILE.read_text())
    benches = {b["id"]: b for b in board["benches"]}
    score_map = {(s["model_id"], s["bench_id"]): s for s in board["scores"]}
    fails = 0
    checked = 0
    for mid, cells in expected.items():
        for bench_id, exp_val in cells.items():
            checked += 1
            # sec-bench (patched) is a board condition, not a separate cell:
            # check the <ISSUE> measurement value (drilldown), not the headline.
            if bench_id == "sec-bench-patched":
                got = _patched_value(score_map.get((mid, "sec-bench"), {}).get("measurements", []))
                if got is None or abs(got - exp_val) > 1e-9:
                    print(f"  ✗ {mid}/sec-bench[patched]: expected {exp_val}, got {got}")
                    fails += 1
                continue
            entry = score_map.get((mid, bench_id))
            sel = select_canonical(entry["measurements"], benches[bench_id], dims) if entry else None
            if sel is None:
                print(f"  ✗ {mid}/{bench_id}: expected {exp_val}, got blank")
                fails += 1
                continue
            m = sel[0]
            if isinstance(exp_val, str):  # tier cell (e.g. 'T1')
                if m.get("label") != exp_val:
                    print(f"  ✗ {mid}/{bench_id}: expected tier {exp_val}, got {m.get('label')}")
                    fails += 1
            else:
                got = m.get("value")
                if got is None or abs(got - exp_val) > 1e-9:
                    print(f"  ✗ {mid}/{bench_id}: expected {exp_val}, got {got}")
                    fails += 1

    # 3. structural checks the static values don't cover:
    #    (a) N/A cell yields no canonical headline (Gemma-4 26B-A4B CyberGym);
    #    (b) the SEC-bench 2-col->1 consolidation actually carries both variants.
    na = select_canonical(score_map[("gemma4-26b-a4b-nvfp4", "cybergym")]["measurements"],
                          benches["cybergym"], dims)
    if na is not None:
        print(f"  ✗ Gemma26 CyberGym: expected N/A (no headline), got {na[0].get('value')}")
        fails += 1
    harnesses = sorted(m["condition"].get("harness")
                       for m in score_map[("gemma4-31b-nvfp4", "sec-bench")]["measurements"])
    if harnesses != ["<ISSUE>", "stock"]:
        print(f"  ✗ SEC-bench consolidation: expected stock+<ISSUE>, got {harnesses}")
        fails += 1

    print(f"[parity/python] {checked} authoritative cells checked, {fails} mismatch(es)")

    # 4. Cross-check against the ACTUAL index.html JS (not this Python port) when
    # node is available — catches drift between the page logic and the port.
    # Feeds the SAME authoritative static-expected.json (not STATIC).
    import shutil
    node = shutil.which("node")
    if node:
        r = subprocess.run([node, str(HERE / "parity-realjs.js"), str(OUT), str(EXPECTED_FILE)])
        if r.returncode != 0:
            fails += 1
    else:
        print("[parity/real-js] node not found — skipping (run with node for the "
              "actual-page-JS cross-check; the Python port above is a faithful translation)")

    if fails:
        print("PARITY FAIL", file=sys.stderr)
        return 1
    print("PARITY OK — canonical numbers reproduce the static page (checked vs the "
          "machine-parsed static-expected.json); only the documented SEC-bench(2→1 col) "
          "+ Pool-B ᵗ-marker changes differ (by design).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
