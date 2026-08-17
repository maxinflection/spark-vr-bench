#!/usr/bin/env python3
"""_swerebench_progress_watch.py — no-progress / loop detector for OpenHands V1
SWE-rebench runs (bd benchmarks-3xi.2.1). PORT of the CyberGym tz5 detector
(scripts/runners/_cybergym_progress_watch.py, bd memory
cybergym-noprogress-detection-2026-06-14) to the OpenHands V1 event schema.

WHY (same rationale as tz5/9g4.4): long-horizon SWE agents loop or wedge to the
max_iteration / wall cap, and that single capped task dominates the column wall
while being a guaranteed FAIL — so aborting it early is pure wall/budget savings
with no score cost (a run that solves the task finishes before any trigger).
OpenHands' built-in AgentStuckInLoopError only catches EXACT action repetition;
it misses (a) a wedged/hung tool call emitting nothing (STALL) and (b) a model
micro-varying its command while the environment returns identical output (LOOP).
A harness-side watcher catches both and survives an OpenHands/SDK reinstall.

WHAT CHANGED vs the V0 CyberGym detector: ONLY the event source. The two triggers
(stall, loop), the case+whitespace-only normalization (digits/hex preserved so
productive search isn't flagged), the uncertainty-never-aborts discipline, and
the SIGTERM->SIGKILL-subtree kill are reused verbatim. V0 read OpenHands-0.x
per-event files (**/events/*.json); V1/OpenHands-benchmarks emits one
model_dump_json per line to <instance>.events.jsonl (see the REBENCH_EVENT_DIR
sink in _openhands_swerebench_infer.py). V1 event kinds: ObservationEvent
(observation content -> loop signal), ActionEvent (timestamps -> stall), plus
SystemPrompt/Message/ConversationStateUpdate (ignored for loop).

MODES:
  --mode watch   : poll a live run; on a positive trigger write a JSON reason to
                   --abort-file and SIGTERM --agent-pid (then SIGKILL the subtree
                   if it ignores TERM), then exit 0. Exits 0 (no action) when the
                   agent pid is gone or the poll budget is exhausted.
  --mode analyze : offline; for each events.jsonl, report whether/which trigger
                   WOULD fire and at what event index / elapsed time. Never kills.

Stdlib only (matches the V0 detector + board conventions).
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import signal
import sys
import time
from collections import Counter
from dataclasses import dataclass, field

_WS = re.compile(r"\s+")
_EPOCH_FLOOR = 946684800.0  # 2000-01-01; reject 0/1/false masquerading as a ts


def _normalize(text: str) -> str:
    """Case+whitespace only; everything else verbatim (see V0 detector rationale:
    folding digits/hex would falsely flag a model making progress THROUGH numbers)."""
    if not text:
        return ""
    return _WS.sub(" ", text.lower()).strip()


def _hash(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:16]


def _parse_ts(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value >= _EPOCH_FLOOR else None
    if isinstance(value, str) and value.strip():
        s = value.strip()
        try:
            from datetime import datetime

            iso = s[:-1] + "+00:00" if s.endswith("Z") else s
            ts = datetime.fromisoformat(iso).timestamp()
            return ts if ts >= _EPOCH_FLOOR else None
        except (ValueError, OverflowError):
            return None
    return None


@dataclass
class Event:
    idx: int
    ts: float
    kind: str            # "action" | "obs" | "other"
    sig: str
    info: bool = True
    ts_ok: bool = True


def _obs_content(obj: dict) -> str:
    """Best-effort textual content of a V1 ObservationEvent for signature hashing.

    The `observation` field may be a string or a nested object; we serialize it
    deterministically (full string, no truncation) so two outputs differing only
    in the middle never collide, and we namespace by tool_name."""
    obs = obj.get("observation")
    if isinstance(obs, str):
        content = obs
    elif obs is None:
        content = ""
    else:
        content = json.dumps(obs, sort_keys=True, default=str)
    return content


def _event_from_obj(obj: dict, idx: int, mtime) -> Event | None:
    if not isinstance(obj, dict):
        return None
    eid = obj.get("id")
    eid = idx if not isinstance(eid, int) else idx  # event ids are uuids in V1 -> use file order
    parsed = _parse_ts(obj.get("timestamp"))
    if parsed is not None:
        ts, ts_ok = parsed, True
    elif isinstance(mtime, (int, float)) and mtime >= _EPOCH_FLOOR:
        ts, ts_ok = float(mtime), True
    else:
        ts, ts_ok = 0.0, False

    kind = obj.get("kind") or ""
    if kind == "ObservationEvent":
        content = _normalize(_obs_content(obj))
        sig = _hash(f"{obj.get('tool_name')}\x00{content}")
        return Event(idx=eid, ts=ts, kind="obs", sig=sig, info=bool(content), ts_ok=ts_ok)
    if kind in ("ActionEvent", "MessageEvent", "SystemPromptEvent"):
        return Event(idx=eid, ts=ts, kind="action", sig="", ts_ok=ts_ok)
    return Event(idx=eid, ts=ts, kind="other", sig="", ts_ok=ts_ok)


def load_events(events_file: str) -> list[Event]:
    """Load + order every parseable V1 event line. Defensive: unreadable/partial
    lines (e.g. a final line mid-write) are skipped, never fatal."""
    out: list[Event] = []
    try:
        mtime = os.path.getmtime(events_file)
    except OSError:
        mtime = None
    try:
        with open(events_file, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return out
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue  # partial trailing line mid-write -> skip (fail-open)
        ev = _event_from_obj(obj, i, mtime)
        if ev is not None:
            out.append(ev)
    out.sort(key=lambda e: e.idx)
    return out


def _latest_file_mtime(events_file: str) -> float:
    try:
        return os.path.getmtime(events_file)
    except OSError:
        return 0.0


def _informative_obs_sigs(events: list[Event]) -> list[str]:
    return [e.sig for e in events if e.kind == "obs" and e.info]


@dataclass
class Verdict:
    triggered: bool = False
    reason: str = ""
    detail: str = ""
    n_events: int = 0
    n_obs: int = 0
    last_event_ts: float = 0.0
    idle_secs: float = 0.0
    modal_repeat: int = 0
    evidence: dict = field(default_factory=dict)


@dataclass
class Config:
    stall_secs: float
    loop_window: int
    loop_threshold: int
    min_events: int


def evaluate(events: list[Event], cfg: Config, now: float, latest_activity_ts: float = 0.0) -> Verdict:
    """LIVE stall/loop decision as of `now`. Pure. (Identical logic to V0.)"""
    v = Verdict(n_events=len(events))
    if not events:
        return v
    reliable = [e.ts for e in events if e.ts_ok]
    last_seen = max(reliable) if reliable else 0.0
    last_seen = max(last_seen, latest_activity_ts)
    if last_seen > 0:
        v.last_event_ts = last_seen
        v.idle_secs = max(0.0, now - last_seen)
        if v.idle_secs >= cfg.stall_secs:
            v.triggered, v.reason = True, "stall"
            v.detail = f"no new event for {v.idle_secs:.0f}s >= stall_secs={cfg.stall_secs:.0f}"
            v.evidence = {"idle_secs": round(v.idle_secs, 1), "n_events": len(events)}
            return v
    obs_sigs = _informative_obs_sigs(events)
    v.n_obs = len(obs_sigs)
    if len(obs_sigs) >= cfg.min_events and len(obs_sigs) >= cfg.loop_window:
        window = obs_sigs[-cfg.loop_window:]
        _sig, count = Counter(window).most_common(1)[0]
        v.modal_repeat = count
        if count >= cfg.loop_threshold:
            v.triggered, v.reason = True, "loop"
            v.detail = (
                f"modal observation repeated {count}x in last {cfg.loop_window} "
                f"observations >= loop_threshold={cfg.loop_threshold}"
            )
            v.evidence = {
                "modal_obs_repeat": count, "loop_window": cfg.loop_window,
                "n_obs": len(obs_sigs), "distinct_in_window": len(set(window)),
            }
    return v


def analyze(events: list[Event], cfg: Config) -> Verdict:
    """Offline: would the watcher have fired, and from what? Stall here = largest
    inter-event gap (a mid-run hang); everything else mirrors evaluate()."""
    v = Verdict(n_events=len(events))
    if not events:
        return v
    reliable = sorted((e for e in events if e.ts_ok), key=lambda e: (e.ts, e.idx))
    if reliable:
        v.last_event_ts = reliable[-1].ts
    max_gap, gap_at = 0.0, -1
    for a, b in zip(reliable, reliable[1:]):
        gap = b.ts - a.ts
        if gap > max_gap:
            max_gap, gap_at = gap, b.idx
    v.idle_secs = max_gap
    obs_sigs = _informative_obs_sigs(events)
    v.n_obs = len(obs_sigs)
    v.modal_repeat = Counter(obs_sigs).most_common(1)[0][1] if obs_sigs else 0
    if max_gap >= cfg.stall_secs:
        v.triggered, v.reason = True, "stall"
        v.detail = f"max inter-event gap {max_gap:.0f}s (at event #{gap_at}) >= stall_secs={cfg.stall_secs:.0f}"
    elif len(obs_sigs) >= cfg.min_events and len(obs_sigs) >= cfg.loop_window:
        for end in range(max(cfg.loop_window, cfg.min_events), len(obs_sigs) + 1):
            window = obs_sigs[end - cfg.loop_window:end]
            _sig, count = Counter(window).most_common(1)[0]
            if count >= cfg.loop_threshold:
                v.triggered, v.reason, v.modal_repeat = True, "loop", count
                v.detail = (
                    f"loop after {end} observations: modal obs {count}x in window "
                    f"[{end - cfg.loop_window}:{end}] >= loop_threshold={cfg.loop_threshold}"
                )
                break
    v.evidence = {
        "n_events": v.n_events, "n_obs": v.n_obs,
        "max_inter_event_gap_secs": round(max_gap, 1),
        "modal_obs_repeat_overall": v.modal_repeat,
    }
    return v


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _descendants(pid: int) -> list[int]:
    """All transitive child pids (Linux /proc walk) — SIGKILL the whole subtree so
    an orphaned run.py child can't keep hitting the LLM endpoint (V0 rationale)."""
    children: dict[int, list[int]] = {}
    try:
        pids = [int(d) for d in os.listdir("/proc") if d.isdigit()]
    except OSError:
        return []
    for p in pids:
        try:
            with open(f"/proc/{p}/stat", "rb") as fh:
                data = fh.read()
            after = data[data.rfind(b")") + 2:].split()
            ppid = int(after[1])
        except (OSError, ValueError, IndexError):
            continue
        children.setdefault(ppid, []).append(p)
    out, stack = [], list(children.get(pid, []))
    while stack:
        c = stack.pop()
        out.append(c)
        stack.extend(children.get(c, []))
    return out


def _terminate(pid: int, grace: float, log_prefix: str) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    waited = 0.0
    while waited < max(0.0, grace):
        if not _pid_alive(pid):
            return
        time.sleep(1.0)
        waited += 1.0
    if _pid_alive(pid):
        kids = _descendants(pid)
        print(f"{log_prefix} pid {pid} survived {grace:.0f}s after SIGTERM — "
              f"SIGKILL {len(kids)} descendant(s) + pid", file=sys.stderr)
        for victim in [*kids, pid]:
            try:
                os.kill(victim, signal.SIGKILL)
            except ProcessLookupError:
                pass


def _write_abort_file(path: str, payload: dict) -> None:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        os.replace(tmp, path)
    except OSError as exc:
        print(f"[progress-watch] WARN could not write abort file {path}: {exc}", file=sys.stderr)


def run_watch(args, cfg: Config) -> int:
    deadline = time.monotonic() + args.max_watch_secs if args.max_watch_secs > 0 else None
    lp = "[progress-watch]"
    print(f"{lp} watching events_file={args.events_file} agent_pid={args.agent_pid} "
          f"stall_secs={cfg.stall_secs:.0f} loop_window={cfg.loop_window} "
          f"loop_threshold={cfg.loop_threshold} poll_secs={args.poll_secs}", file=sys.stderr)
    while True:
        if not _pid_alive(args.agent_pid):
            print(f"{lp} agent pid {args.agent_pid} gone — run finished, no action", file=sys.stderr)
            return 0
        if deadline is not None and time.monotonic() >= deadline:
            print(f"{lp} max_watch_secs reached — stopping watcher", file=sys.stderr)
            return 0
        events = load_events(args.events_file)
        verdict = evaluate(events, cfg, now=time.time(),
                           latest_activity_ts=_latest_file_mtime(args.events_file))
        if verdict.triggered:
            payload = {
                "aborted": True, "reason": verdict.reason, "detail": verdict.detail,
                "n_events": verdict.n_events, "n_obs": verdict.n_obs,
                "idle_secs": round(verdict.idle_secs, 1), "modal_repeat": verdict.modal_repeat,
                "evidence": verdict.evidence, "agent_pid": args.agent_pid,
                "aborted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            print(f"{lp} TRIGGER reason={verdict.reason} :: {verdict.detail} — "
                  f"SIGTERM agent pid {args.agent_pid}", file=sys.stderr)
            if args.abort_file:
                _write_abort_file(args.abort_file, payload)
            _terminate(args.agent_pid, args.term_grace, lp)
            return 0
        time.sleep(max(1.0, args.poll_secs))


def run_analyze(args, cfg: Config) -> int:
    out = sys.stderr if args.json else sys.stdout
    results = []
    for ef in args.events_file_list:
        events = load_events(ef)
        v = analyze(events, cfg)
        results.append((ef, v))
        status = f"WOULD-ABORT[{v.reason}]" if v.triggered else "ok"
        print(f"== {ef}", file=out)
        print(f"   verdict           : {status}", file=out)
        if v.detail:
            print(f"   detail            : {v.detail}", file=out)
        print(f"   events / infm-obs : {v.n_events} / {v.n_obs}", file=out)
        print(f"   max inter-evt gap : {v.idle_secs:.0f}s (stall_secs={cfg.stall_secs:.0f})", file=out)
        print(f"   modal obs repeat  : {v.modal_repeat} (loop_window={cfg.loop_window}, "
              f"loop_threshold={cfg.loop_threshold})", file=out)
    if args.json:
        print(json.dumps(
            [{"events_file": d, "triggered": v.triggered, "reason": v.reason,
              "detail": v.detail, **v.evidence} for d, v in results], indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=("watch", "analyze"), default="watch")
    p.add_argument("--stall-secs", type=float, default=600.0)
    p.add_argument("--loop-window", type=int, default=12)
    p.add_argument("--loop-threshold", type=int, default=10)
    p.add_argument("--min-events", type=int, default=24)
    p.add_argument("--events-file", help="watch: the <instance>.events.jsonl to tail")
    p.add_argument("--agent-pid", type=int, help="watch: pid to SIGTERM on trigger")
    p.add_argument("--abort-file", help="watch: JSON reason written here on trigger")
    p.add_argument("--poll-secs", type=float, default=15.0)
    p.add_argument("--term-grace", type=float, default=20.0)
    p.add_argument("--max-watch-secs", type=float, default=0.0)
    p.add_argument("events_file_list", nargs="*", help="analyze: events.jsonl files")
    p.add_argument("--json", action="store_true")
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    cfg = Config(
        stall_secs=max(1.0, args.stall_secs),
        loop_window=max(1, args.loop_window),
        loop_threshold=max(1, args.loop_threshold),
        min_events=max(1, args.min_events),
    )
    if args.mode == "watch":
        if not args.events_file or not args.agent_pid:
            print("watch mode requires --events-file and --agent-pid", file=sys.stderr)
            return 2
        return run_watch(args, cfg)
    if not args.events_file_list:
        if args.events_file:
            args.events_file_list = [args.events_file]
        else:
            print("analyze mode requires at least one events.jsonl (positional)", file=sys.stderr)
            return 2
    return run_analyze(args, cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
