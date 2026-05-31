#!/usr/bin/env python3
"""Generate a cybergym per-run workspace + agent_id, for run-pool-a-cybergym-v1.sh.

Wraps cybergym.task.gen_task.generate_task so the V1 bash runner can shell out
once to produce the per-task workspace (containing source, submit.sh,
mask_map.json) then docker cp the result into the agent-server's /workspace/project.

Stdout (one line, space-separated): <agent_id_hex32> <workspace_dir>

Run inside the cybergym venv: /opt/harnesses/cybergym/.venv/bin/python ...
"""

import argparse
import sys
import uuid
from pathlib import Path

from cybergym.task.gen_task import generate_task
from cybergym.task.types import TaskConfig


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--task_id", required=True, help="e.g. arvo:3938")
    ap.add_argument("--data_dir", required=True, type=Path,
                    help="cybergym raw data dir (contains arvo/, oss-fuzz/)")
    ap.add_argument("--out_dir", required=True, type=Path,
                    help="parent dir; generator creates out_dir/workspace inside")
    ap.add_argument("--server", required=True,
                    help="cybergym.server URL the generated submit.sh will POST to")
    ap.add_argument("--difficulty", default="level1",
                    choices=["level0", "level1", "level2", "level3"])
    ap.add_argument("--agent_id", default=None,
                    help="32-char hex; auto-generated if omitted")
    args = ap.parse_args()

    agent_id = args.agent_id or uuid.uuid4().hex
    if len(agent_id) != 32 or not all(c in "0123456789abcdefABCDEF" for c in agent_id):
        print(f"ERROR: agent_id must be 32 hex chars; got {agent_id!r}", file=sys.stderr)
        return 2

    workspace_dir = args.out_dir / "workspace"
    workspace_dir.mkdir(parents=True, exist_ok=True)

    config = TaskConfig(
        task_id=args.task_id,
        out_dir=workspace_dir,
        data_dir=args.data_dir,
        server=args.server,
        difficulty=args.difficulty,
        agent_id=agent_id,
    )
    generate_task(config)

    print(f"{agent_id} {workspace_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
