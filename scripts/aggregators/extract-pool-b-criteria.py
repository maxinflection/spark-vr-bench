#!/usr/bin/env python3
"""extract-pool-b-criteria.py — Build the cross-campaign criterion matrix.

Walks every Pool B campaign in s3://<RESULTS_BUCKET>/ and pulls every
metric out of the raw lm-eval results.json and bigcodebench pass_at_k.json
files — not just the single pass_rate the runner stores in results.json.

For each (campaign, model, bench, criterion) it emits one row to a long-format
CSV. Per-bench wide pivots are then rendered to markdown for human reading.

Input layout (in S3):
  <campaign>/<target>/<bench>/lm-eval-raw/<adapter>__<owner>__<model>/results_*.json
    schema: {"results": {"<task_id>": {"<metric>,<filter>": float, ...}, ...}, ...}
    benches that use this: humaneval-plus, ifeval
  <campaign>/<target>/bigcodebench-hard/bcb-raw/bcb_results/*_sanitized_calibrated_pass_at_k.json
    schema: {"pass@1": float, "model": str, "split": str, "subset": str,
             "calibrated": bool, "gt_pass_rate": float, "failed_tasks": [str]}

Output:
  docs/results/criterion-matrix.csv               — long format, one row per metric
  docs/results/criterion-matrix-<bench>.md        — wide pivot per bench
  docs/results/criterion-matrix-INDEX.md          — overview + missing-data notes

The script is idempotent: re-runs overwrite the output files. Adding a new
campaign requires no code change — discovery is purely S3 prefix listing.

Issue: benchmarks-<CAMPAIGN>
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

BUCKET = "<RESULTS_BUCKET>"

# Campaigns whose name pattern is not a Pool B sweep. Skipped on listing.
SKIP_CAMPAIGN_PREFIXES = (
    "_deprecated",          # archive
    "_diagnostics",         # one-off probes
    "bc7-",                 # Pool A probes
    "opus47-cybergym",      # Pool A
    "pgf-stage1-",          # OpenHands V1 migration
    "smoke-",               # smoke-only campaigns
)

# Bench names as they appear in S3 paths (== the runner's bench id).
BENCH_LMEVAL = ("humaneval-plus", "ifeval")
BENCH_BCB = "bigcodebench-hard"

log = logging.getLogger("extract-pool-b-criteria")


# ============================================================
# S3 helpers (subprocess aws cli — boto3 not assumed)
# ============================================================
def s3_ls(prefix: str) -> list[str]:
    """Return immediate-child PREs (with trailing /) and keys under prefix.

    Non-recursive. Result strings include the bucket-relative key — they do
    NOT include the bucket name or s3:// scheme. Empty prefix = bucket root.
    """
    if prefix and not prefix.endswith("/"):
        prefix = prefix + "/"
    cmd = ["aws", "s3", "ls", f"s3://{BUCKET}/{prefix}"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        log.warning("s3 ls failed at %s: %s", prefix, e.stderr.strip())
        return []
    items = []
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "PRE":
            items.append(prefix + parts[1])
        else:
            # Date Time Size Key — but ls outputs key as last token relative to prefix.
            items.append(prefix + parts[-1])
    return items


def s3_ls_recursive(prefix: str) -> list[str]:
    """Return all keys (no PREs) under prefix, recursively."""
    if not prefix.endswith("/"):
        prefix = prefix + "/"
    cmd = ["aws", "s3", "ls", f"s3://{BUCKET}/{prefix}", "--recursive"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        log.warning("s3 ls --recursive failed at %s: %s", prefix, e.stderr.strip())
        return []
    keys = []
    for line in out.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) < 4:
            continue
        keys.append(parts[3])
    return keys


def s3_get_json(key: str) -> dict[str, Any] | None:
    cmd = ["aws", "s3", "cp", f"s3://{BUCKET}/{key}", "-"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
        return json.loads(out)
    except subprocess.CalledProcessError as e:
        log.warning("s3 cp failed for %s: %s", key, e.stderr.strip())
        return None
    except json.JSONDecodeError as e:
        log.warning("JSON parse failed for %s: %s", key, e)
        return None


# ============================================================
# Data shape
# ============================================================
@dataclass
class Row:
    campaign: str
    target: str
    bench: str
    model: str
    criterion: str
    value: float | None
    stderr: float | None = None
    extras: dict[str, Any] = field(default_factory=dict)


# ============================================================
# Per-bench extractors
# ============================================================
def parse_lmeval_results(payload: dict, campaign: str, target: str, bench: str, model: str) -> list[Row]:
    """lm-eval results.json has a 'results' map keyed by task; each task is a
    flat dict of '<metric>,<filter>' → value and '<metric>_stderr,<filter>'
    → stderr (or 'N/A')."""
    rows = []
    results = payload.get("results", {})
    for task_id, task_metrics in results.items():
        if not isinstance(task_metrics, dict):
            continue
        # Collect metric names (those without _stderr suffix).
        metric_keys = [
            k for k in task_metrics
            if not k.endswith("_stderr") and "_stderr," not in k and k not in ("name", "alias", "sample_len")
        ]
        for mk in metric_keys:
            value = task_metrics.get(mk)
            if not isinstance(value, (int, float)):
                continue
            # Find paired stderr if any. The key format is "<metric>,<filter>",
            # and stderr is "<metric>_stderr,<filter>".
            if "," in mk:
                base, flt = mk.split(",", 1)
                stderr_key = f"{base}_stderr,{flt}"
            else:
                stderr_key = f"{mk}_stderr"
            stderr_raw = task_metrics.get(stderr_key)
            stderr = stderr_raw if isinstance(stderr_raw, (int, float)) else None
            criterion = mk.replace(",none", "").replace(",", "/")
            rows.append(Row(
                campaign=campaign, target=target, bench=bench, model=model,
                criterion=criterion, value=float(value), stderr=stderr,
                extras={"n_samples": task_metrics.get("sample_len"), "task_id": task_id},
            ))
    return rows


def parse_bcb_pass_at_k(payload: dict, campaign: str, target: str, model: str) -> list[Row]:
    """bigcodebench's pass_at_k.json has a single pass@1 (the calibrated
    variant if filename contains 'calibrated'). We also capture
    failed_tasks-count as a sidecar metric."""
    rows = []
    pass_at_1 = payload.get("pass@1")
    if isinstance(pass_at_1, (int, float)):
        calibrated = bool(payload.get("calibrated"))
        criterion = "pass@1_calibrated" if calibrated else "pass@1"
        rows.append(Row(
            campaign=campaign, target=target, bench=BENCH_BCB, model=model,
            criterion=criterion, value=float(pass_at_1), stderr=None,
            extras={
                "split": payload.get("split"),
                "subset": payload.get("subset"),
                "failed_tasks_count": len(payload.get("failed_tasks", []) or []),
                "gt_pass_rate": payload.get("gt_pass_rate"),
            },
        ))
    return rows


# ============================================================
# Campaign walker
# ============================================================
def model_from_lmeval_dir(dir_name: str) -> str:
    """lm-eval flattens slashes to '__' in the adapter+model dir name, e.g.
    'openai__QuantTrio__Qwen3-235B-A22B-Thinking-2507-AWQ' or
    'bedrock__us.anthropic.claude-opus-4-7'. We collapse '__' → '/'."""
    return dir_name.replace("__", "/")


def model_from_bcb_filename(filename: str) -> str:
    """bcb writes one file per (model, subset) named
    '<model_with_slash_subbed>--main--bigcodebench-hard-<split>--openai-0-1-...json'.
    The model is the first '--' segment, with internal '--' meaning '/'."""
    base = filename.split("/")[-1]
    head = base.split("--main--")[0]
    return head.replace("--", "/")


def walk_campaign(campaign: str) -> list[Row]:
    """Walk one campaign and return all extracted rows."""
    rows: list[Row] = []
    # campaign/{target}/{bench}/ — find all (target, bench) pairs by listing.
    keys = s3_ls_recursive(campaign)
    if not keys:
        return rows
    # Group keys by (target, bench).
    bench_dirs: dict[tuple[str, str], list[str]] = defaultdict(list)
    for key in keys:
        # Expected: <campaign>/<target>/<bench>/...
        parts = key.split("/")
        if len(parts) < 4:
            continue
        target = parts[1]
        bench = parts[2]
        bench_dirs[(target, bench)].append(key)

    for (target, bench), keys_in_bench in bench_dirs.items():
        if bench in BENCH_LMEVAL:
            # Look for lm-eval-raw/<model_dir>/results_*.json
            for k in keys_in_bench:
                if "/lm-eval-raw/" not in k or not k.endswith(".json"):
                    continue
                if "/results_" not in k:
                    continue
                # extract model dir = path segment after lm-eval-raw/
                model_dir = k.split("/lm-eval-raw/", 1)[1].split("/", 1)[0]
                model = model_from_lmeval_dir(model_dir)
                payload = s3_get_json(k)
                if not payload:
                    continue
                rows.extend(parse_lmeval_results(payload, campaign, target, bench, model))
        elif bench == BENCH_BCB:
            for k in keys_in_bench:
                if not k.endswith("_pass_at_k.json"):
                    continue
                model = model_from_bcb_filename(k)
                payload = s3_get_json(k)
                if not payload:
                    continue
                rows.extend(parse_bcb_pass_at_k(payload, campaign, target, model))
        # else: bench unknown to us — skip silently.
    return rows


def list_campaigns() -> list[str]:
    """List the top-level campaign prefixes under the bucket."""
    items = s3_ls("")
    campaigns = []
    for item in items:
        # item is like "campaign-name/" — strip trailing /
        if not item.endswith("/"):
            continue
        name = item.rstrip("/")
        if any(name.startswith(p) for p in SKIP_CAMPAIGN_PREFIXES):
            continue
        campaigns.append(name)
    return sorted(campaigns)


# ============================================================
# Renderers
# ============================================================
def write_csv(rows: list[Row], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["campaign", "target", "bench", "model", "criterion", "value", "stderr", "n_samples", "extras_json"])
        for r in rows:
            w.writerow([
                r.campaign, r.target, r.bench, r.model, r.criterion,
                f"{r.value:.6f}" if r.value is not None else "",
                f"{r.stderr:.6f}" if r.stderr is not None else "",
                r.extras.get("n_samples") or "",
                json.dumps(r.extras, sort_keys=True),
            ])
    log.info("wrote %d rows → %s", len(rows), path)


def write_bench_pivot(rows: list[Row], bench: str, path: Path) -> None:
    """Write a markdown table: rows = (campaign, model), columns = criterion, cells = value (stderr)."""
    bench_rows = [r for r in rows if r.bench == bench]
    if not bench_rows:
        path.write_text(f"# {bench}: no data\n")
        return
    criteria = sorted({r.criterion for r in bench_rows})
    # Group by (campaign, model).
    by_key: dict[tuple[str, str], dict[str, Row]] = defaultdict(dict)
    for r in bench_rows:
        by_key[(r.campaign, r.model)][r.criterion] = r

    lines = [f"# {bench} — multi-criterion matrix", ""]
    lines.append(f"_{len(bench_rows)} rows across {len(by_key)} (campaign, model) pairs._")
    lines.append("")
    # Header
    header = ["campaign", "model"] + criteria
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for (camp, model), cmap in sorted(by_key.items()):
        cells = [camp, model]
        for crit in criteria:
            r = cmap.get(crit)
            if r is None or r.value is None:
                cells.append("—")
            elif r.stderr is not None:
                cells.append(f"{r.value:.4f} ± {r.stderr:.4f}")
            else:
                cells.append(f"{r.value:.4f}")
        lines.append("| " + " | ".join(cells) + " |")

    # Per-bench spread analysis: for each model, what's the max-min across criteria?
    lines.append("")
    lines.append("## Criterion spread per (campaign, model)")
    lines.append("")
    lines.append("| campaign | model | min | max | spread |")
    lines.append("|---|---|---|---|---|")
    for (camp, model), cmap in sorted(by_key.items()):
        vals = [r.value for r in cmap.values() if r.value is not None]
        if len(vals) < 2:
            continue
        lo, hi = min(vals), max(vals)
        lines.append(f"| {camp} | {model} | {lo:.4f} | {hi:.4f} | {hi-lo:+.4f} |")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    log.info("wrote pivot → %s (%d (campaign,model) pairs)", path, len(by_key))


def write_index(rows: list[Row], campaigns: list[str], missing: dict[str, list[str]], path: Path) -> None:
    by_camp = defaultdict(set)
    for r in rows:
        by_camp[r.campaign].add(r.bench)
    lines = [
        "# Pool B multi-criterion matrix — index",
        "",
        f"Generated by `scripts/aggregators/extract-pool-b-criteria.py` from s3://{BUCKET}/.",
        "",
        f"Total rows: **{len(rows)}** spanning **{len(by_camp)} campaigns** × benches.",
        "",
        "## Per-bench files",
        "",
        "- [humaneval-plus](criterion-matrix-humaneval-plus.md)",
        "- [ifeval](criterion-matrix-ifeval.md)",
        "- [bigcodebench-hard](criterion-matrix-bigcodebench-hard.md)",
        "",
        "## Per-campaign bench coverage",
        "",
        "| campaign | humaneval-plus | ifeval | bigcodebench-hard |",
        "|---|---|---|---|",
    ]
    for c in sorted(campaigns):
        present = by_camp.get(c, set())
        lines.append(
            f"| {c} | "
            f"{'✓' if 'humaneval-plus' in present else '—'} | "
            f"{'✓' if 'ifeval' in present else '—'} | "
            f"{'✓' if 'bigcodebench-hard' in present else '—'} |"
        )

    if missing:
        lines.append("")
        lines.append("## Campaigns with empty / malformed raw outputs")
        lines.append("")
        for c, reasons in missing.items():
            for r in reasons:
                lines.append(f"- `{c}` — {r}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    log.info("wrote index → %s", path)


# ============================================================
# HTML renderer — single self-contained file with embedded JSON
# data + Plotly.js (CDN) for heatmaps + vanilla JS for sortable tables.
# No build step. S3-hostable as a static page.
# ============================================================
_HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Pool B Criterion Matrix</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    margin: 1.5em auto; max-width: 1280px; padding: 0 1em;
    color: #222; background: #fafafa;
  }
  h1 { border-bottom: 2px solid #444; padding-bottom: 0.3em; }
  h2 { margin-top: 2.5em; border-bottom: 1px solid #ccc; padding-bottom: 0.2em; }
  .meta { color: #666; font-size: 13px; }
  .chart { height: 540px; margin: 1em 0; background: white; border: 1px solid #ddd; padding: 6px; }
  .table-wrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; font-variant-numeric: tabular-nums; }
  th, td { border: 1px solid #ddd; padding: 5px 9px; }
  th { background: #eee; cursor: pointer; user-select: none; white-space: nowrap; }
  th:hover { background: #ddd; }
  th[data-dir="asc"]::after  { content: " ▲"; color: #555; }
  th[data-dir="desc"]::after { content: " ▼"; color: #555; }
  td { text-align: right; white-space: nowrap; }
  td.s { text-align: left; }
  td.score { font-weight: 600; }
  tr.thinking-true td.s { font-style: italic; }
  tr.thinking-true td.s::after { content: " · thinking=true"; color: #c08000; font-weight: normal; font-size: 11px; }
  .footnote { font-size: 11px; color: #888; margin-top: 0.5em; }
  details { margin-top: 1em; }
  summary { cursor: pointer; font-weight: 600; }
  @media (prefers-color-scheme: dark) {
    body { color: #ddd; background: #1e1e1e; }
    th { background: #333; }
    th:hover { background: #444; }
    table, th, td { border-color: #444; }
    .chart { background: #2a2a2a; border-color: #444; }
    .meta, .footnote { color: #999; }
    h2 { border-color: #444; }
  }
</style>
</head>
<body>
<h1>Off-Spark Pool B — Criterion Matrix</h1>
<p class="meta">__META__</p>

__SECTIONS__

<script>
const DATA = __DATA_JSON__;

// ---------- table builder ----------
function buildTable(host, headers, rows, sortKey) {
  const wrap = document.createElement("div");
  wrap.className = "table-wrap";
  const table = document.createElement("table");
  const thead = document.createElement("thead");
  const tr = document.createElement("tr");
  headers.forEach((h, idx) => {
    const th = document.createElement("th");
    th.textContent = h.label;
    th.dataset.col = idx;
    th.dataset.type = h.type || "str";
    th.addEventListener("click", () => sortBy(table, idx, th));
    tr.appendChild(th);
  });
  thead.appendChild(tr);
  table.appendChild(thead);
  const tbody = document.createElement("tbody");
  rows.forEach(r => {
    const tr = document.createElement("tr");
    if (r.thinking === true) tr.className = "thinking-true";
    headers.forEach((h, idx) => {
      const td = document.createElement("td");
      const v = r.cells[idx];
      if (h.type === "num" && v != null && v !== "") {
        td.className = "score";
        td.textContent = (typeof v === "number") ? v.toFixed(4) : v;
        // colorize by score (0 = red, 1 = green); only for num cells.
        const score = (typeof v === "number") ? v : parseFloat(v);
        if (!isNaN(score) && score >= 0 && score <= 1) {
          const hue = Math.round(score * 120); // 0=red, 120=green
          td.style.backgroundColor = `hsl(${hue}, 65%, 78%)`;
          if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
            td.style.backgroundColor = `hsl(${hue}, 50%, 30%)`;
          }
        }
      } else {
        td.className = "s";
        td.textContent = (v == null) ? "—" : v;
      }
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
  host.appendChild(wrap);
  if (sortKey != null) {
    const ths = table.querySelectorAll("th");
    sortBy(table, sortKey, ths[sortKey]);
  }
}

function sortBy(table, colIdx, thEl) {
  const tbody = table.tBodies[0];
  const rows = Array.from(tbody.rows);
  const type = thEl.dataset.type;
  const prevDir = thEl.dataset.dir;
  const dir = (prevDir === "desc") ? "asc" : "desc";
  table.querySelectorAll("th").forEach(t => t.dataset.dir = "");
  thEl.dataset.dir = dir;
  rows.sort((a, b) => {
    let av = a.cells[colIdx].textContent;
    let bv = b.cells[colIdx].textContent;
    if (type === "num") {
      const aN = parseFloat(av); const bN = parseFloat(bv);
      av = isNaN(aN) ? -Infinity : aN;
      bv = isNaN(bN) ? -Infinity : bN;
    }
    if (av < bv) return dir === "asc" ? -1 :  1;
    if (av > bv) return dir === "asc" ?  1 : -1;
    return 0;
  });
  rows.forEach(r => tbody.appendChild(r));
}

// ---------- heatmap (Plotly) ----------
function buildHeatmap(divId, models, criteria, matrix) {
  const trace = {
    type: "heatmap",
    x: criteria,
    y: models,
    z: matrix,
    colorscale: [
      [0,    "rgb(180, 30, 30)"],
      [0.5,  "rgb(240, 220, 90)"],
      [1,    "rgb(40, 160, 40)"],
    ],
    zmin: 0, zmax: 1,
    hoverongaps: false,
    text: matrix.map(row => row.map(v => (v == null) ? "" : v.toFixed(4))),
    texttemplate: "%{text}",
    textfont: { size: 11 },
    colorbar: { thickness: 12, len: 0.6 }
  };
  const layout = {
    margin: { l: 320, r: 30, t: 30, b: 80 },
    xaxis: { tickangle: -25 },
    yaxis: { automargin: true, autorange: "reversed" },
    paper_bgcolor: "rgba(0,0,0,0)", plot_bgcolor: "rgba(0,0,0,0)"
  };
  Plotly.newPlot(divId, [trace], layout, { displayModeBar: false, responsive: true });
}

// ---------- per-bench section ----------
for (const bench of DATA.benches) {
  const tableHost = document.getElementById(`table-${bench.id}`);
  buildTable(tableHost, bench.headers, bench.rows, bench.defaultSortCol);
  buildHeatmap(`heat-${bench.id}`, bench.heatmap.models, bench.heatmap.criteria, bench.heatmap.z);
}
</script>
</body>
</html>
"""


def _short_model_name(model: str) -> str:
    """Strip the redundant provider prefix for readability in the visual."""
    for prefix in ("openai/", "bedrock/", "gemini/"):
        if model.startswith(prefix):
            return model[len(prefix):]
    return model


def _enrich_with_thinking(all_rows: list[Row]) -> dict[tuple[str, str, str], dict]:
    """Best-effort: walk the runner's results.json per (campaign, target, bench)
    and pull diagnostic fields from `extra`. Returns
    dict[(campaign, target, bench) -> {thinking, bcb_null_rate}].
    Skips if results.json is unreachable (<CAMPAIGN> will land a proper readout).

    bd <ISSUE>: bcb_null_rate surfaces the [bcb-none-filter] truncation rate so
    future BCB-Hard cells carry the truncation caveat in the dashboard."""
    out: dict[tuple[str, str, str], dict] = {}
    seen: set[tuple[str, str, str]] = set()
    for r in all_rows:
        key = (r.campaign, r.target, r.bench)
        if key in seen:
            continue
        seen.add(key)
        rj_key = f"{r.campaign}/{r.target}/{r.bench}/results.json"
        payload = s3_get_json(rj_key)
        if not payload:
            out[key] = {"thinking": None, "bcb_null_rate": None}
            continue
        extra = payload.get("extra") or {}
        none_filter = extra.get("bcb_none_filter") or {}
        out[key] = {
            "thinking": extra.get("enable_thinking"),
            "bcb_null_rate": none_filter.get("null_rate"),
        }
    return out


def write_html(rows: list[Row], path: Path) -> None:
    import datetime as _dt

    # Build per-bench JSON payloads.
    # Headers: campaign, model, criterion, value, stderr, n, thinking
    thinking_map = _enrich_with_thinking(rows)

    benches_payload = []
    for bench in (*BENCH_LMEVAL, BENCH_BCB):
        bench_rows = [r for r in rows if r.bench == bench]
        if not bench_rows:
            continue
        # Table rows: one per (campaign, model, criterion) row from the long format.
        table_rows = []
        for r in sorted(bench_rows, key=lambda x: (x.campaign, x.model, x.criterion)):
            enrich = thinking_map.get((r.campaign, r.target, r.bench), {})
            table_rows.append({
                "thinking": enrich.get("thinking"),
                "bcb_null_rate": enrich.get("bcb_null_rate"),
                "cells": [
                    r.campaign,
                    _short_model_name(r.model),
                    r.criterion,
                    round(r.value, 4) if r.value is not None else None,
                    round(r.stderr, 4) if r.stderr is not None else None,
                    r.extras.get("n_samples") or "",
                ],
            })
        # Heatmap data: pivot to (model, criterion) -> mean value across campaigns
        # (use latest campaign per model — ranked by campaign-name reverse-string sort
        # which approximates date-ordering since our campaign ids are date-tagged).
        heatmap_models_set: set[str] = set()
        heatmap_criteria_set: set[str] = set()
        pivot: dict[tuple[str, str], list[Row]] = defaultdict(list)
        for r in bench_rows:
            short_model = _short_model_name(r.model)
            pivot[(short_model, r.criterion)].append(r)
            heatmap_models_set.add(short_model)
            heatmap_criteria_set.add(r.criterion)
        heatmap_models = sorted(heatmap_models_set)
        heatmap_criteria = sorted(heatmap_criteria_set)
        z = []
        for m in heatmap_models:
            row_z = []
            for c in heatmap_criteria:
                hits = pivot.get((m, c), [])
                if not hits:
                    row_z.append(None)
                else:
                    # Prefer the most-recent non-smoke campaign (n_samples larger).
                    chosen = max(hits, key=lambda x: (x.extras.get("n_samples") or 0, x.campaign))
                    row_z.append(round(chosen.value, 4) if chosen.value is not None else None)
            z.append(row_z)
        benches_payload.append({
            "id": bench,
            "headers": [
                {"label": "campaign",  "type": "str"},
                {"label": "model",     "type": "str"},
                {"label": "criterion", "type": "str"},
                {"label": "value",     "type": "num"},
                {"label": "stderr",    "type": "num"},
                {"label": "n",         "type": "num"},
            ],
            "rows": table_rows,
            "defaultSortCol": 3,  # value column
            "heatmap": {
                "models": heatmap_models,
                "criteria": heatmap_criteria,
                "z": z,
            },
        })

    # Build the HTML sections (heatmap + table per bench)
    sections_html: list[str] = []
    for b in benches_payload:
        bench_id = b["id"]
        sections_html.append(
            f'<h2>{bench_id}</h2>\n'
            f'<div class="chart" id="heat-{bench_id}"></div>\n'
            f'<details>\n'
            f'  <summary>Full long-format table ({len(b["rows"])} rows)</summary>\n'
            f'  <div id="table-{bench_id}"></div>\n'
            f'  <div class="footnote">Click a column header to sort. Italic rows ran with enable_thinking=true (<CAMPAIGN>). Score cells are color-graded 0→1 = red→green.</div>\n'
            f'</details>\n'
        )

    payload = {"benches": benches_payload}
    meta_line = (
        f"Generated {_dt.datetime.now(_dt.UTC).strftime('%Y-%m-%dT%H:%M:%S')}Z by "
        f"<code>scripts/aggregators/extract-pool-b-criteria.py --html</code>. "
        f"{len(rows)} rows from s3://{BUCKET}/. "
        f"Heatmap shows the highest-n campaign per (model, criterion). "
        f"Score color scale: red 0.0 → yellow 0.5 → green 1.0."
    )

    html = (
        _HTML_TEMPLATE
        .replace("__META__", meta_line)
        .replace("__SECTIONS__", "\n".join(sections_html))
        .replace("__DATA_JSON__", json.dumps(payload))
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html)
    log.info("wrote html → %s (%d benches, %d total rows in JSON)",
             path, len(benches_payload), sum(len(b["rows"]) for b in benches_payload))


# ============================================================
# Main
# ============================================================
def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default="docs/results", help="Where to write the markdown + CSV (default: docs/results)")
    p.add_argument("--only-campaign", action="append", default=[], help="Restrict to listed campaigns (debug)")
    p.add_argument("--html", action="store_true",
                   help="Also emit a single-file interactive HTML report (Plotly via CDN, S3-hostable)")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    campaigns = list_campaigns()
    if args.only_campaign:
        campaigns = [c for c in campaigns if c in args.only_campaign]
    log.info("discovered %d campaigns", len(campaigns))

    all_rows: list[Row] = []
    missing: dict[str, list[str]] = defaultdict(list)
    for c in campaigns:
        rows = walk_campaign(c)
        if not rows:
            missing[c].append("no raw outputs parsed")
            continue
        all_rows.extend(rows)
        log.info("  %s → %d rows", c, len(rows))

    out_dir = Path(args.out_dir)
    write_csv(all_rows, out_dir / "criterion-matrix.csv")
    for bench in (*BENCH_LMEVAL, BENCH_BCB):
        write_bench_pivot(all_rows, bench, out_dir / f"criterion-matrix-{bench}.md")
    write_index(all_rows, campaigns, dict(missing), out_dir / "criterion-matrix-INDEX.md")
    if args.html:
        write_html(all_rows, out_dir / "criterion-matrix.html")

    print(f"wrote {len(all_rows)} rows from {len(campaigns)} campaigns → {out_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
