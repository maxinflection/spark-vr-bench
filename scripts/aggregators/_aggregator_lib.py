"""_aggregator_lib.py — shared helpers for the scripts/aggregators/ family.

The Python side mirrors the shell side's shared-lib pattern
(scripts/runners/_lib.sh + scripts/_harness_registry.sh): one place for the
S3 bucket constant, the S3 mirror, the result.json tree walkers, model-id
aliasing, and the junk-campaign filter, so the individual aggregators stop
re-implementing them 3x with subtle drift.

Fork + shared lib (bd <ISSUE>.2 decision): the aggregators stay SEPARATE tools
(pool-a is filesystem+bitmap-specific; pool-b is S3+metric-generic) and share
only these generic helpers — they are NOT merged into one mega-aggregator.

Consumers:
  - extract-pool-a-exploitbench.py  → load_result + the tree walkers (du8.10.2)
  - extract-pool-b-criteria.py      → S3 helpers (migration pending)
  - extract-per-task-verdicts.py    → S3 mirror + MODEL_ALIASES (migration pending)
  - compute-truncation.py           → S3 helpers (migration pending)

Stdlib only (no boto3): S3 access shells out to the `aws` CLI, matching the
existing aggregators and avoiding a pip dependency.
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
from pathlib import Path
from typing import Any, Iterator

log = logging.getLogger("aggregator")

# ============================================================
# S3 configuration
# ============================================================
# Canonical results bucket. Overridable by callers that read S3_BUCKET from the
# environment (extract-per-task-verdicts.py already does os.environ.get).
S3_BUCKET = "<RESULTS_BUCKET>"


def s3_mirror(dest: str, bucket: str = S3_BUCKET) -> None:
    """Mirror s3://<bucket>/ to a local dir via `aws s3 cp --recursive`.

    Raises subprocess.CalledProcessError on failure (callers decide how loud).
    """
    Path(dest).mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["aws", "s3", "cp", f"s3://{bucket}/", dest + "/", "--recursive"],
        check=True,
    )


# ============================================================
# Model-id aliasing + campaign hygiene
# ============================================================
# Map short/legacy model ids onto their canonical form. Kept here so every
# aggregator agrees (previously only extract-per-task-verdicts.py had it).
MODEL_ALIASES: dict[str, str] = {
    "claude-opus-4-7": "us.anthropic.claude-opus-4-7",
}


def canonical_model_id(model_id: str) -> str:
    """Return the canonical model id for aliasing (identity if unknown)."""
    return MODEL_ALIASES.get(model_id, model_id)


# Anchored "must never render" campaign allowlist. Mirrors
# update-sweep-status.sh:BOARD_JUNK_CAMPAIGN_RE and the copy in
# extract-per-task-verdicts.py — KEEP IN SYNC with the shell. This is an exact
# full-name match set (not a substring heuristic): only these specific broken
# campaigns are dropped, so a legitimately-named campaign is never filtered.
BOARD_JUNK_CAMPAIGN_RE = re.compile(
    r"^(<ISSUE>-<CAMPAIGN>-secbench11-2026-05-26"
    r"|<CAMPAIGN>-secbench-tp8-2026-05-27"
    r"|to4-nemotron120-cvebench-thinkingon-2026-05-30"
    r"|to4-qwen3-235b-cvebench-2026-05-31"
    r"|to4-qwen3-235b-cvebench-thinkingon-2026-05-31"
    r"|to4-qwen3-235b-cvebench-thinkingon-b300-2026-06-01)$"
)

# Smoke/validation campaigns — a marker (not full-drop), matched as a substring.
SMOKE_CAMPAIGN_RE = re.compile(r"(smoke|probe|debug|test)", re.IGNORECASE)


def is_junk_campaign(campaign: str | None) -> bool:
    """True only for the anchored 'must never render' campaign set.

    Exact full-name match (BOARD_JUNK_CAMPAIGN_RE), NOT a substring heuristic:
    a campaign named e.g. 'exploitbench-41-...' is never dropped.
    """
    if not campaign:
        return False
    return bool(BOARD_JUNK_CAMPAIGN_RE.match(campaign))


def is_smoke_campaign(campaign: str | None) -> bool:
    """True for smoke/probe/debug/test campaigns (a display marker, not a drop)."""
    if not campaign:
        return False
    return bool(SMOKE_CAMPAIGN_RE.search(campaign))


# ============================================================
# result.json loading + tree walking
# ============================================================
def load_result(path: Path) -> dict[str, Any] | None:
    """Load one result.json, returning None (with a warning) on any failure."""
    try:
        with path.open() as f:
            return json.load(f)
    except Exception as exc:
        log.warning("failed to read %s: %s", path, exc)
        return None


def iter_result_files_flat(root: Path) -> Iterator[Path]:
    """Walk a flat bench subtree: <root>/<task_id_safe>/result.json.

    Used for --from-dir mode where the caller already points at the bench dir
    (e.g. exploitbench-41/).
    """
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        result = child / "result.json"
        if result.is_file():
            yield result
        else:
            log.warning("missing result.json: %s", result)


def iter_result_files_campaign(
    campaign_root: Path,
    bench_prefixes: tuple[str, ...] = ("exploitbench",),
) -> Iterator[tuple[Path, str, str, str]]:
    """Walk a campaign tree: <campaign>/<target>/<bench>/<task>/result.json.

    Yields (result_path, campaign_name, target, bench).
    """
    campaign_name = campaign_root.name
    if not campaign_root.is_dir():
        log.warning("campaign dir not found: %s", campaign_root)
        return
    for target_dir in sorted(campaign_root.iterdir()):
        if not target_dir.is_dir():
            continue
        for bench_dir in sorted(target_dir.iterdir()):
            if not bench_dir.is_dir():
                continue
            if not any(bench_dir.name.startswith(p) for p in bench_prefixes):
                continue
            found_any = False
            for task_dir in sorted(bench_dir.iterdir()):
                if not task_dir.is_dir():
                    continue
                result = task_dir / "result.json"
                if result.is_file():
                    found_any = True
                    yield result, campaign_name, target_dir.name, bench_dir.name
                else:
                    log.warning("missing result.json: %s", result)
            if not found_any:
                log.warning("bench dir has no task subdirs with result.json: %s", bench_dir)
