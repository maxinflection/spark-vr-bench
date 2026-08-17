#!/usr/bin/env python3
"""_cybergym_pool.py — bounded-pool parent for the hermetic CyberGym harness.

bd benchmarks-b51 Phase 2. This is the dependency-free, stdlib-only orchestrator
that replaces the sequential bash loop in run-pool-a-cybergym.sh. It runs up to
CYBERGYM_POOL_N hermetic per-task entrypoints (run-one-cybergym-task.sh) at once
against the one continuously-batched vLLM/Spark endpoint, and owns exactly three
things (design §3):

  1. DISPATCH — bounded concurrency over the task list, in list order. N=1 runs
     tasks strictly one-at-a-time → byte-identical to today's sequential path.
  2. SIGNAL FAN-OUT + TEARDOWN (§5) — on SIGTERM/SIGINT (the shell forwards the
     spend-cap / Ctrl-C signal here) it stops dispatching, SIGTERMs each running
     worker's PROCESS GROUP so the worker's own self-cleanup trap reaps its
     task-local server + labelled container + agent subtree, waits a grace, then
     SIGKILLs stragglers and does a backstop `docker rm -f` by cg_campaign label.
  3. TALLY — after the pool joins it reads each task's status.json (harness_rc +
     pass + sanitizer_verdict) and exits 0 iff there were no harness failures,
     else 1. (The entrypoint owns ALL per-task file writes, success AND failure.)

Why stdlib + system python3 (no uv/pip/venv): this script imports only the
standard library, so there is nothing to install and no environment to fight —
the operator's uv preference was about avoiding this host's pip/venv pain, which
a dependency-free script sidesteps entirely.

The secret LLM key is NEVER on argv: workers inherit it from this process's
environment (VLLM_API_KEY / OPENAI_API_KEY), exported by the dispatcher shell.

Usage (invoked by run-pool-a-cybergym.sh):
  python3 _cybergym_pool.py --pool-n N --entrypoint <run-one-cybergym-task.sh> \
      --campaign C --target T --bench B --n-total M --results-base DIR \
      [--force] [--reasoning-effort none|minimal|low|medium|high] \
      [--vllm-url URL --vllm-model MODEL] -- <task_id> [<task_id> ...]

Exit codes:
  0   — every task ran to a terminal record with harness_rc == 0
  1   — at least one task had a harness failure (or no terminal record)
  130 — aborted by SIGINT after teardown
  143 — aborted by SIGTERM after teardown
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# Seconds to let a SIGTERM'd worker run its own cleanup trap (server stop +
# docker rm -f + agent-subtree kill) before we SIGKILL its group. The dispatcher
# shell waits longer than this before SIGKILLing the whole pool parent.
WORKER_GRACE_SECS = 15.0
POLL_SECS = 0.5

# Set by the signal handler (the signum); the dispatch loop checks it each tick.
_aborted_signum = None


def _ts():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(msg):
    print(f"[pool][{_ts()}] {msg}", file=sys.stderr, flush=True)


def _on_signal(signum, _frame):
    global _aborted_signum
    if _aborted_signum is None:
        _aborted_signum = signum
        log(f"received signal {signum} — will stop dispatching and tear down running workers")


def parse_args(argv):
    p = argparse.ArgumentParser(description="Bounded pool parent for hermetic CyberGym tasks")
    p.add_argument("--pool-n", type=int, required=True, help="max tasks running at once (N=1 == sequential)")
    p.add_argument("--entrypoint", required=True, help="path to run-one-cybergym-task.sh")
    p.add_argument("--campaign", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--bench", required=True)
    p.add_argument("--n-total", type=int, required=True, help="column task count (for per-task progress)")
    p.add_argument("--results-base", required=True, help="LIB_RESULTS_BASE (to read each task's status.json)")
    p.add_argument("--force", action="store_true")
    p.add_argument("--reasoning-effort", default="",
                   help="reasoning_effort tier (none|minimal|low|medium|high); "
                        "passed verbatim to each worker, empty = unset (default path)")
    p.add_argument("--vllm-url", default="")
    p.add_argument("--vllm-model", default="")
    p.add_argument("tasks", nargs="+", help="task ids, in dispatch order")
    return p.parse_args(argv)


def build_worker_argv(args, task_id, task_index):
    """The per-task entrypoint invocation — mirrors the Phase-1 dispatcher's
    common_task_args exactly (no secret key on argv; inherited via env)."""
    argv = [
        args.entrypoint,
        "--target", args.target,
        "--campaign", args.campaign,
        "--bench", args.bench,
        "--n-total", str(args.n_total),
        "--task-id", task_id,
        "--task-index", str(task_index),
    ]
    if args.force:
        argv.append("--force")
    # bd amh: only forward --reasoning-effort when set so the default path stays
    # byte-identical (the worker exports no env ⇒ no reasoning_effort in config.toml).
    if args.reasoning_effort:
        argv += ["--reasoning-effort", args.reasoning_effort]
    if args.target == "vllm":
        argv += ["--vllm-url", args.vllm_url, "--vllm-model", args.vllm_model]
    return argv


def launch_worker(args, task_id, task_index):
    argv = build_worker_argv(args, task_id, task_index)
    # start_new_session=True -> the worker is a session+group leader (pgid == pid),
    # so we can signal its whole subtree (bash + agent + watcher + task server) via
    # killpg, and the signal never reaches this parent or the dispatcher shell.
    # Environment (incl. the resolved LLM key) is inherited by default.
    proc = subprocess.Popen(argv, start_new_session=True)
    return proc


def sig_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    except OSError as exc:
        log(f"killpg(pgid={pgid}, sig={sig}) failed (non-fatal): {exc}")


def backstop_reap(campaign):
    """Defensive final sweep: force-remove any container still carrying this
    campaign's label, whatever its task. The per-worker traps normally beat us to
    it; this catches a container whose worker was SIGKILLed before its trap ran."""
    try:
        out = subprocess.run(
            ["docker", "ps", "-aq", "--filter", f"label=cg_campaign={campaign}"],
            capture_output=True, text=True, timeout=30,
        )
        ids = out.stdout.split()
        if ids:
            log(f"backstop reap: docker rm -f {len(ids)} cg_campaign={campaign} container(s): {' '.join(ids)}")
            subprocess.run(["docker", "rm", "-f", *ids], capture_output=True, text=True, timeout=180)
    except FileNotFoundError:
        pass  # no docker on an offline harness — nothing to reap
    except Exception as exc:  # noqa: BLE001 — teardown must never raise
        log(f"backstop reap error (non-fatal): {exc}")


def teardown(running, signum, campaign):
    """SIGTERM each running worker's group, grace, SIGKILL stragglers, then a
    docker reap backstop by campaign label."""
    log(f"teardown: signalling {len(running)} running worker(s) (signal {signum})")
    for info in list(running.values()):
        sig_group(info["pgid"], signal.SIGTERM)

    deadline = time.monotonic() + WORKER_GRACE_SECS
    while running and time.monotonic() < deadline:
        for pid in [p for p, i in running.items() if i["proc"].poll() is not None]:
            info = running.pop(pid)
            log(f"teardown: worker task={info['task_id']} pid={pid} exited cleanly")
        time.sleep(0.25)

    for pid, info in list(running.items()):
        log(f"teardown: worker task={info['task_id']} pid={pid} did not exit in {WORKER_GRACE_SECS:g}s — SIGKILL group")
        sig_group(info["pgid"], signal.SIGKILL)
    for pid, info in list(running.items()):
        try:
            info["proc"].wait(timeout=5)
        except Exception:  # noqa: BLE001
            pass
        running.pop(pid, None)

    backstop_reap(campaign)
    log("teardown: complete")


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001 — missing/partial/unreadable -> no record
        return None


def terminal_record(results_base, campaign, target, bench, task_id, sub_rc):
    """Resolve a task's terminal outcome. Prefer status.json (written on BOTH the
    success and harness-error paths, and the prior run's copy when the task was
    skipped on resume); fall back to result.json, then to this run's subprocess rc.
    Returns (harness_rc, passed, verdict)."""
    tid_path = task_id.replace(":", "_")
    base = Path(results_base) / campaign / target / bench / tid_path

    st = read_json(base / "status.json")
    if st is not None:
        hrc = st.get("harness_rc", 0)
        return (hrc if isinstance(hrc, int) else 1,
                st.get("pass") is True,
                st.get("sanitizer_verdict", "unknown"))

    res = read_json(base / "result.json")
    if res is not None:
        if res.get("status") == "failed":
            ec = res.get("exit_code")
            return (ec if isinstance(ec, int) and ec != 0 else 1, False, "harness_error")
        passed = (res.get("pass_rate") or 0) > 0
        verdict = (res.get("extra") or {}).get("sanitizer_verdict", "unknown")
        return (0, passed, verdict)

    # No terminal record at all — trust this run's subprocess rc (nonzero -> fail;
    # a 0 rc with no record is an anomaly we still flag, so nothing slips through).
    if sub_rc == 0:
        return (1, False, "no_record")
    return (sub_rc if isinstance(sub_rc, int) else 1, False, "no_record")


def main(argv):
    args = parse_args(argv)
    tasks = args.tasks
    n = max(1, args.pool_n)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    log(f"start pool_n={n} n_tasks={len(tasks)} campaign={args.campaign} target={args.target} bench={args.bench}")

    running = {}   # pid -> {task_id, idx, proc, pgid}
    results = {}   # task_id -> subprocess returncode
    next_i = 0     # 0-based index into tasks

    while _aborted_signum is None and (next_i < len(tasks) or running):
        # Launch up to N concurrent workers, in list order.
        while _aborted_signum is None and len(running) < n and next_i < len(tasks):
            task_id = tasks[next_i]
            idx1 = next_i + 1
            proc = launch_worker(args, task_id, idx1)
            running[proc.pid] = {"task_id": task_id, "idx": idx1, "proc": proc, "pgid": proc.pid}
            next_i += 1
            log(f"launch task={task_id} ({idx1}/{len(tasks)}) pid={proc.pid} running={len(running)}/{n}")

        # Reap any finished workers.
        finished = [pid for pid, i in running.items() if i["proc"].poll() is not None]
        for pid in finished:
            info = running.pop(pid)
            rc = info["proc"].returncode
            results[info["task_id"]] = rc
            log(f"done  task={info['task_id']} rc={rc} running={len(running)}/{n} dispatched={next_i}/{len(tasks)}")

        if not finished and (running or next_i < len(tasks)):
            time.sleep(POLL_SECS)

    if _aborted_signum is not None:
        # Tasks not yet launched are simply left undone — a resume run picks them
        # up (their result.json was never written). Tear down what is running.
        teardown(running, _aborted_signum, args.campaign)
        log(f"aborted by signal {_aborted_signum} after teardown "
            f"(dispatched={next_i}/{len(tasks)}, done={len(results)})")
        return 128 + _aborted_signum

    # ---- Tally (no abort): read each task's terminal record. ----
    harness_failures = []
    vuln_pass = 0
    verdicts = {}
    for task_id in tasks:
        sub_rc = results.get(task_id)
        hrc, passed, verdict = terminal_record(
            args.results_base, args.campaign, args.target, args.bench, task_id, sub_rc)
        verdicts[verdict] = verdicts.get(verdict, 0) + 1
        if passed:
            vuln_pass += 1
        # A nonzero subprocess rc is always a harness failure even if a stale
        # status.json says otherwise; a nonzero harness_rc record is too.
        if hrc != 0 or (sub_rc is not None and sub_rc != 0):
            harness_failures.append({"task": task_id, "harness_rc": hrc, "subprocess_rc": sub_rc})

    summary = {
        "n_tasks": len(tasks),
        "harness_ok": len(tasks) - len(harness_failures),
        "harness_failures": harness_failures,
        "vuln_pass": vuln_pass,
        "verdicts": verdicts,
        "pool_n": n,
    }
    log("SUMMARY " + json.dumps(summary, sort_keys=True))
    # Machine-readable summary on stdout for any caller that wants to parse it.
    print(json.dumps({"pool_summary": summary}), flush=True)

    return 1 if harness_failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
