#!/usr/bin/env python3
"""_cybergym_progress_watch.py — no-progress / loop detector for CyberGym runs.

WHY (bd benchmarks-tz5, H1; epic benchmarks-9g4):
  The Pool A CyberGym column wall is ORCHESTRATION-bound, not decode-bound
  (memory: pool-a-wall-is-orchestration-bound / ejv-cybergym-spark-wall-anchor).
  ~10% of task-runs loop to the 7200s max_iter/timeout cap and that single
  task is ~68% of the column wall — and both observed loopers were no_crash
  FAILs, so aborting them early is pure wall (and budget) savings with no
  score cost: a real PASS submits its PoC well before any of these triggers.

  The ejv loopers generated only ~786 output tokens over 7200s (~0.1 tok/s) —
  i.e. they are STALLS (the agent wedged on a hung tool call, or re-issuing the
  same command that keeps hitting OpenHands' per-command timeout), NOT the
  verbose ballooning loop OpenHands' own AgentStuckInLoopError catches (that
  one fired ~step 73 for MiniMax-M3, see minimax-m3-poolA-stuck-loop-finding).
  So OpenHands' built-in stuck detector misses exactly this failure mode, and a
  harness-side watcher is the right place to catch it (and it survives a
  cybergym/OpenHands reinstall, unlike an upstream run.py patch).

WHAT:
  Reads the OpenHands event stream a CyberGym task writes under its --log_dir
  ( <log_dir>/<task>-<agent_id>/file/sessions/<sid>/events/<n>.json ) and
  decides whether the run is making progress, using two INDEPENDENT triggers:

    stall : the newest event is older than --stall-secs. Catches the agent
            fully wedged inside one long/hung tool execution, or a dead model
            connection — the 0.1-tok/s ejv mode's backstop.
    loop  : within the trailing --loop-window action/observation PAIRS, one
            observation signature occurs >= --loop-threshold times. Catches
            no-information-gain repetition (the environment keeps returning the
            same output) that OpenHands' EXACT-match action-pair detector lets
            through when the model micro-varies the command each turn.

  Observation signatures are normalized for CASE + WHITESPACE ONLY (the full
  string is hashed, no truncation). We deliberately do NOT fold digits or hex/0x
  values, so a model making progress THROUGH numbers ("offset 0x40 -> 0x80",
  "reached 100 -> 200") keeps producing fresh signatures and does NOT trip the
  loop trigger. GENUINE PoC refinement (a DIFFERENT observation each turn) stays
  diverse for the same reason. Uncertainty never aborts: any parse error,
  empty/short stream, or unrecognized schema is treated as "progress".

MODES:
  --mode watch   : poll a live run; on a positive trigger write a JSON reason to
                   --abort-file and SIGTERM --agent-pid, then exit 0. Exits 0
                   (no action) when the agent pid is gone (run finished) or the
                   poll budget is exhausted.
  --mode analyze : offline; for each --log-dir, print whether/which trigger
                   WOULD fire and at what event index / elapsed time. Used to
                   characterize the two known ejv loopers on the harness VM and
                   to tune thresholds before the watcher is enabled. Never kills.

This script is invoked by run-pool-a-cybergym.sh only when CYBERGYM_NOPROGRESS_ABORT
is set; it is default-OFF so existing/paired campaigns reproduce byte-identically.
Stdlib only (matches tests/board + _cybergym_gen_workspace.py conventions).
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


def _normalize(text: str) -> str:
    """Normalize ONLY case and whitespace; everything else is preserved verbatim.

    We deliberately fold nothing else. In particular we do NOT collapse hex/0x
    values or decimal numbers: a model homing in on a target shows progress
    THROUGH those numbers ("offset 0x40 → 0x80 → 0xc0", "reached 100 → 200 →
    300", "12 → 13 bytes"), and normalizing them away would falsely flag that
    productive search as a loop — the one thing the detector must never do.
    Measured over 18 real CyberGym traces, folding 0x pointers changed the
    windowed modal count on EXACTLY ZERO of them, so it bought nothing and only
    added false-positive risk. Real loopers repeat byte-identical output (verified
    on the MiniMax-M3 / Gemma-26B-A4B / Kimi-K2.6 / Nemotron traces), and the
    FULL normalized string is hashed (no truncation), so two long outputs that
    differ only in the middle never collide into a false repeat."""
    if not text:
        return ""
    return _WS.sub(" ", text.lower()).strip()


def _hash(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:16]


# Reject epochs before this (2000-01-01) as garbage — a 0.0/1.0 ts (from a
# missing field or a bool leaking into the timestamp) must NEVER be treated as a
# real event time, or `now - 0` manufactures an ~epoch-sized idle and the stall
# trigger fires instantly on a healthy run.
_EPOCH_FLOOR = 946684800.0


@dataclass
class Event:
    idx: int            # event id (sort key); falls back to file order
    ts: float           # epoch seconds (event timestamp, else file mtime); 0.0 if unknown
    kind: str           # "action" | "obs" | "other"
    sig: str            # normalized signature hash
    info: bool = True   # obs only: did the observation carry non-empty content?
    ts_ok: bool = True  # is ts a real, trustworthy timestamp? (else excluded from stall)
    raw_path: str = ""


def _parse_ts(value):
    """Parse an OpenHands event timestamp (ISO-8601, possibly 'Z') to epoch.

    Returns a float epoch, or None if the value is missing/garbage. Bools are
    rejected (isinstance(True, int) is True) and sub-2000 epochs are rejected so
    a stray 0/1/false can't masquerade as a real event time.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value >= _EPOCH_FLOOR else None
    if isinstance(value, str) and value.strip():
        s = value.strip()
        # datetime.fromisoformat in 3.11+ accepts most ISO forms; be defensive.
        try:
            from datetime import datetime

            iso = s[:-1] + "+00:00" if s.endswith("Z") else s
            ts = datetime.fromisoformat(iso).timestamp()
            return ts if ts >= _EPOCH_FLOOR else None
        except (ValueError, OverflowError):
            return None
    return None


def _event_from_obj(obj: dict, idx: int, mtime, path: str) -> Event | None:
    """Map a parsed OpenHands event object to an Event, or None to skip it.

    NB: every OpenHands event carries BOTH `action` and `observation` keys with
    one set to null (verified against real 0.33 events: an action event is
    {"action":"run","observation":null,...}; an observation is
    {"action":null,"observation":"run",...}). So classify on the VALUE being
    truthy, not on key presence.

    `mtime` is the file mtime (or None if unavailable). Timestamp resolution
    prefers the event's own ISO timestamp, falls back to mtime, and marks the
    event ts_ok=False if neither yields a real (>= 2000) epoch — such events are
    excluded from stall computation so they can't manufacture a false idle gap.
    """
    if not isinstance(obj, dict):
        return None
    eid = obj.get("id")
    eid = eid if isinstance(eid, int) else idx

    parsed = _parse_ts(obj.get("timestamp"))
    if parsed is not None:
        ts, ts_ok = parsed, True
    elif isinstance(mtime, (int, float)) and mtime >= _EPOCH_FLOOR:
        ts, ts_ok = float(mtime), True
    else:
        ts, ts_ok = 0.0, False

    action = obj.get("action")
    observation = obj.get("observation")
    if observation:
        content = obj.get("content")
        if not isinstance(content, str):
            content = json.dumps(content, sort_keys=True, default=str) if content else ""
        norm = _normalize(content)
        sig = _hash(f"{observation}\x00{norm}")
        return Event(idx=eid, ts=ts, kind="obs", sig=sig, info=bool(norm), ts_ok=ts_ok, raw_path=path)
    if action:
        # Action events are kept only for their timestamp (stall computation);
        # loop detection keys purely on observations, so the action sig is unused.
        return Event(idx=eid, ts=ts, kind="action", sig="", ts_ok=ts_ok, raw_path=path)
    return Event(idx=eid, ts=ts, kind="other", sig="", ts_ok=ts_ok, raw_path=path)


def _find_event_files(log_dir: str, since: float = 0.0) -> list[str]:
    """All event json files under a task log dir, in any OpenHands nesting.

    OpenHands writes <log_dir>/<task>-<agent_id>/file/sessions/<sid>/events/<n>.json,
    but we glob loosely (**/events/*.json) so the watcher needs no agent_id up
    front (run.py mints it after launch) and analyze mode works on any subtree.

    `since` (epoch) excludes STALE event files written by a PRIOR run — e.g. a
    --force rerun or a retry leaves the previous run's events in place, and
    without this filter the watcher would load that old looper stream and abort
    the fresh agent before it produces any output. The caller captures `since`
    (whole-second `date +%s`) BEFORE launching the agent, so every fresh event
    file has mtime >= since while a prior run's files (written when it finished,
    earlier) are strictly older — we compare against `since` exactly, with no
    negative skew, so a run that JUST finished can't have its tail re-ingested.
    An unstattable file is kept (fail-open). since<=0 (analyze) disables it.
    """
    files = glob.glob(os.path.join(log_dir, "**", "events", "*.json"), recursive=True)
    if since <= 0:
        return files
    kept = []
    for p in files:
        try:
            if os.path.getmtime(p) >= since:
                kept.append(p)
        except OSError:
            kept.append(p)  # can't stat -> keep (fail-open); ts_ok still guards stall
    return kept


def load_events(log_dir: str, since: float = 0.0) -> list[Event]:
    """Load + chronologically order every parseable event under log_dir.

    `since` excludes stale prior-run event files (see _find_event_files).
    Defensive: unreadable / malformed files are skipped, never fatal."""
    out: list[Event] = []
    for fi, path in enumerate(_find_event_files(log_dir, since)):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = None  # unavailable -> event ts is unreliable, excluded from stall
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                obj = json.load(fh)
        except (OSError, ValueError):
            continue
        ev = _event_from_obj(obj, fi, mtime, path)
        if ev is not None:
            out.append(ev)
    # Order by event id when present (monotonic in OpenHands), mtime as tiebreak.
    out.sort(key=lambda e: (e.idx, e.ts))
    return out


def _latest_file_mtime(log_dir: str, since: float = 0.0) -> float:
    """Freshest event-FILE mtime (incl. files mid-write / unparseable JSON).

    Used as a stall activity floor: a large observation being written right now
    is an incomplete JSON file that load_events skips, which could otherwise make
    the newest PARSEABLE event look stale. The file's recent mtime proves the
    agent is active, so we never trigger a stall while output is being written."""
    latest = 0.0
    for p in _find_event_files(log_dir, since):
        try:
            latest = max(latest, os.path.getmtime(p))
        except OSError:
            continue
    return latest


def _latest_any_file_mtime(log_dir: str) -> float:
    """Freshest mtime of ANY file under log_dir (not just event JSONs).

    Used by analyze mode as a per-run END proxy: a finished/killed CyberGym task
    writes result.json / verdict.json / openhands-run.log at teardown (verified
    on the ejv VM: arvo_368 last event 02:29:45 but result.json mtime 04:18:08 —
    the 7200s-cap kill), so this captures the TERMINAL idle the live watcher sees
    via now-last_event but the inter-event-gap scan is blind to. A normal PASS
    writes teardown ~2 min after its last event, well under stall_secs, so this
    never manufactures a false stall."""
    latest = 0.0
    for root, _dirs, files in os.walk(log_dir):
        for f in files:
            try:
                latest = max(latest, os.path.getmtime(os.path.join(root, f)))
            except OSError:
                continue
    return latest


def _informative_obs_sigs(events: list[Event]) -> list[str]:
    """Signatures of the informative (non-empty) environment observations, in order.

    A no-progress loop is one where the environment keeps returning the SAME
    information. Keying on the OBSERVATION (not the action) is what catches the
    real failure mode seen in production: the model micro-varies the command
    each turn (so action signatures differ) but the resulting output is
    byte-identical (verified on the MiniMax-M3 arvo:368 looper — 98 `run` turns,
    a near-identical grep with an IDENTICAL result repeated at the tail).
    Genuine PoC refinement instead yields a DIFFERENT observation each turn
    (a new error / crash / output), so its observations stay diverse and never
    trip the modal-count threshold. Empty observations carry no information
    either way (silent `cd`/`echo >file` successes), so they're excluded.
    """
    return [e.sig for e in events if e.kind == "obs" and e.info]


@dataclass
class Verdict:
    triggered: bool = False
    reason: str = ""           # "stall" | "loop" | ""
    detail: str = ""
    n_events: int = 0
    n_pairs: int = 0
    last_event_ts: float = 0.0
    idle_secs: float = 0.0     # now - last_event_ts (watch) or max inter-event gap (analyze)
    modal_repeat: int = 0      # max occurrences of one pair sig in the trailing window
    evidence: dict = field(default_factory=dict)


@dataclass
class Config:
    stall_secs: float
    loop_window: int
    loop_threshold: int
    min_events: int


def evaluate(events: list[Event], cfg: Config, now: float, latest_activity_ts: float = 0.0) -> Verdict:
    """Decide stall/loop for a LIVE run as of `now`. Pure; no side effects.

    `latest_activity_ts` is the freshest event-FILE mtime (incl. a file being
    written right now whose JSON doesn't parse yet); it floors "last activity"
    so a slow large-observation write can't be mistaken for a stall."""
    v = Verdict(n_events=len(events))
    if not events:
        return v

    # STALL: no activity for the stall budget. "Activity" = the newest RELIABLE-
    # timestamp event OR the freshest event-file mtime (so an in-progress write
    # counts). Events with no trustworthy ts are excluded so a ts=0 can't
    # manufacture a (now - 0) ~epoch idle and false-abort a healthy run.
    reliable = [e.ts for e in events if e.ts_ok]
    last_seen = max(reliable) if reliable else 0.0
    last_seen = max(last_seen, latest_activity_ts)
    if last_seen > 0:
        v.last_event_ts = last_seen
        v.idle_secs = max(0.0, now - last_seen)
        if v.idle_secs >= cfg.stall_secs:
            v.triggered = True
            v.reason = "stall"
            v.detail = f"no new event for {v.idle_secs:.0f}s >= stall_secs={cfg.stall_secs:.0f}"
            v.evidence = {"idle_secs": round(v.idle_secs, 1), "n_events": len(events)}
            return v

    # LOOP: the modal informative-observation signature dominates the trailing
    # window — the environment keeps returning the same information => no gain.
    obs_sigs = _informative_obs_sigs(events)
    v.n_pairs = len(obs_sigs)
    if len(obs_sigs) >= cfg.min_events and len(obs_sigs) >= cfg.loop_window:
        window = obs_sigs[-cfg.loop_window:]
        _sig, count = Counter(window).most_common(1)[0]
        v.modal_repeat = count
        if count >= cfg.loop_threshold:
            v.triggered = True
            v.reason = "loop"
            v.detail = (
                f"modal observation repeated {count}x in last "
                f"{cfg.loop_window} observations >= loop_threshold={cfg.loop_threshold}"
            )
            v.evidence = {
                "modal_obs_repeat": count,
                "loop_window": cfg.loop_window,
                "n_obs": len(obs_sigs),
                "distinct_in_window": len(set(window)),
            }
    return v


def analyze(events: list[Event], cfg: Config, run_end_ts: float = 0.0) -> Verdict:
    """Offline characterization: would the watcher have fired, and from what?

    Two stall paths, matching what the LIVE watcher catches:
      * mid-run gap  : the largest gap between consecutive events (agent hung
                       mid-trajectory).
      * terminal hang: run_end_ts - last_event_ts. The live watcher fires on
                       `now - last_event`, so a run that wedges on its FINAL tool
                       call (no further events, then the cap kills it) is a stall
                       the inter-event scan alone CANNOT see — there is no later
                       event to form a gap. `run_end_ts` (latest file mtime under
                       the task dir, or an explicit override) supplies that end so
                       offline characterization matches live behavior. The ejv
                       Arm1 looper arvo_368 is exactly this case (~6500s terminal
                       hang invisible to the gap scan).
    Everything else mirrors evaluate(). run_end_ts<=0 disables the terminal check
    (preserves the original gap-only behavior)."""
    v = Verdict(n_events=len(events))
    if not events:
        return v

    # Largest inter-event gap (a mid-run hang the live stall trigger would catch),
    # over RELIABLE-timestamp events only so a ts=0 event can't fabricate a gap.
    reliable = sorted((e for e in events if e.ts_ok), key=lambda e: (e.ts, e.idx))
    if reliable:
        v.last_event_ts = reliable[-1].ts
    max_gap = 0.0
    gap_at = -1
    for a, b in zip(reliable, reliable[1:]):
        gap = b.ts - a.ts
        if gap > max_gap:
            max_gap, gap_at = gap, b.idx

    # Terminal hang: run end minus last reliable event (the live watcher's view).
    terminal_idle = 0.0
    if run_end_ts > 0 and v.last_event_ts > 0:
        terminal_idle = max(0.0, run_end_ts - v.last_event_ts)
    v.idle_secs = max(max_gap, terminal_idle)

    obs_sigs = _informative_obs_sigs(events)
    v.n_pairs = len(obs_sigs)
    modal = Counter(obs_sigs).most_common(1)[0][1] if obs_sigs else 0
    v.modal_repeat = modal

    if terminal_idle >= cfg.stall_secs and terminal_idle >= max_gap:
        v.triggered = True
        v.reason = "stall"
        v.detail = (
            f"terminal hang: no events for {terminal_idle:.0f}s before run end "
            f">= stall_secs={cfg.stall_secs:.0f} (last event #{reliable[-1].idx})"
        )
    elif max_gap >= cfg.stall_secs:
        v.triggered = True
        v.reason = "stall"
        v.detail = f"max inter-event gap {max_gap:.0f}s (at event #{gap_at}) >= stall_secs={cfg.stall_secs:.0f}"
    elif len(obs_sigs) >= cfg.min_events and len(obs_sigs) >= cfg.loop_window:
        # Scan every trailing-window position; report the FIRST that trips
        # (the obs index where the watcher would have aborted live). Start at
        # max(loop_window, min_events) so the reported point matches the live
        # evaluate() gate (which won't fire before min_events obs accumulate).
        for end in range(max(cfg.loop_window, cfg.min_events), len(obs_sigs) + 1):
            window = obs_sigs[end - cfg.loop_window:end]
            _sig, count = Counter(window).most_common(1)[0]
            if count >= cfg.loop_threshold:
                v.triggered = True
                v.reason = "loop"
                v.modal_repeat = count
                v.detail = (
                    f"loop after {end} observations: modal obs {count}x in window "
                    f"[{end - cfg.loop_window}:{end}] >= loop_threshold={cfg.loop_threshold}"
                )
                break
    v.evidence = {
        "n_events": v.n_events,
        "n_obs": v.n_pairs,
        "max_inter_event_gap_secs": round(max_gap, 1),
        "terminal_idle_secs": round(terminal_idle, 1),
        "modal_obs_repeat_overall": modal,
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


def _write_abort_file(path: str, payload: dict) -> None:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        os.replace(tmp, path)
    except OSError as exc:  # pragma: no cover - disk-full / perms edge
        print(f"[progress-watch] WARN could not write abort file {path}: {exc}", file=sys.stderr)


def run_watch(args, cfg: Config) -> int:
    """Poll a live run; SIGTERM the agent on a positive trigger. Returns 0 always
    (the watcher is advisory — never the thing that fails a run)."""
    deadline = None
    if args.max_watch_secs > 0:
        deadline = time.monotonic() + args.max_watch_secs
    log_prefix = "[progress-watch]"
    print(f"{log_prefix} watching log_dir={args.log_dir} agent_pid={args.agent_pid} "
          f"stall_secs={cfg.stall_secs:.0f} loop_window={cfg.loop_window} "
          f"loop_threshold={cfg.loop_threshold} poll_secs={args.poll_secs}", file=sys.stderr)
    while True:
        if not _pid_alive(args.agent_pid):
            print(f"{log_prefix} agent pid {args.agent_pid} gone — run finished, no action", file=sys.stderr)
            return 0
        if deadline is not None and time.monotonic() >= deadline:
            print(f"{log_prefix} max_watch_secs reached — stopping watcher", file=sys.stderr)
            return 0

        since = getattr(args, "since", 0.0) or 0.0
        events = load_events(args.log_dir, since)
        latest_activity = _latest_file_mtime(args.log_dir, since)
        verdict = evaluate(events, cfg, now=time.time(), latest_activity_ts=latest_activity)
        if verdict.triggered:
            payload = {
                "aborted": True,
                "reason": verdict.reason,
                "detail": verdict.detail,
                "n_events": verdict.n_events,
                "n_pairs": verdict.n_pairs,
                "idle_secs": round(verdict.idle_secs, 1),
                "modal_repeat": verdict.modal_repeat,
                "evidence": verdict.evidence,
                "agent_pid": args.agent_pid,
                "aborted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            print(f"{log_prefix} TRIGGER reason={verdict.reason} :: {verdict.detail} — "
                  f"SIGTERM agent pid {args.agent_pid}", file=sys.stderr)
            if args.abort_file:
                _write_abort_file(args.abort_file, payload)
            _terminate(args.agent_pid, args.term_grace, log_prefix)
            return 0
        time.sleep(max(1.0, args.poll_secs))


def _descendants(pid: int) -> list[int]:
    """All transitive child pids of `pid` (Linux /proc walk), deepest-last.

    The agent pid we hold is the GNU `timeout` wrapper; the real work is its
    child `run.py` (and run.py's own children). `timeout` forwards a SIGTERM it
    receives, but SIGKILL is uncatchable and can't be forwarded — so SIGKILLing
    only the timeout pid leaves run.py orphaned and STILL HITTING THE LLM
    ENDPOINT (verified). We therefore SIGKILL the whole subtree."""
    children: dict[int, list[int]] = {}
    try:
        pids = [int(d) for d in os.listdir("/proc") if d.isdigit()]
    except OSError:
        return []
    for p in pids:
        try:
            with open(f"/proc/{p}/stat", "rb") as fh:
                data = fh.read()
            # field 4 (PPID) follows the comm field, which is parenthesized and
            # may contain spaces/parens — split on the LAST ')'.
            after = data[data.rfind(b")") + 2:].split()
            ppid = int(after[1])
        except (OSError, ValueError, IndexError):
            continue
        children.setdefault(ppid, []).append(p)
    out: list[int] = []
    stack = list(children.get(pid, []))
    while stack:
        c = stack.pop()
        out.append(c)
        stack.extend(children.get(c, []))
    return out


def _terminate(pid: int, grace: float, log_prefix: str) -> None:
    """SIGTERM the agent, then SIGKILL the whole subtree if it doesn't exit.

    SIGTERM lets OpenHands' run.py trap it (timeout forwards the signal) and tear
    down its docker runtime container cleanly. The SIGKILL backstop targets the
    timeout pid AND every descendant, so an agent that ignores TERM still dies
    promptly (rather than orphaning run.py to keep burning the LLM endpoint until
    the hard cap).
    """
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
        print(f"{log_prefix} agent pid {pid} survived {grace:.0f}s after SIGTERM — "
              f"SIGKILL {len(kids)} descendant(s) + pid", file=sys.stderr)
        # Kill DESCENDANTS FIRST, the timeout pid LAST. The runner is blocked in
        # `wait <pid>` and unblocks the instant `pid` is reaped; killing the
        # children first guarantees that by the time it unblocks (and may then
        # stop this watcher) every descendant is already dead — no TERM-ignoring
        # run.py child is left orphaned in the gap.
        for victim in [*kids, pid]:
            try:
                os.kill(victim, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run_kill_tree(args) -> int:
    """SIGKILL the whole process subtree rooted at --pid (descendants first).

    Exposes the same `_descendants` /proc walk the no-progress watcher uses, as a
    one-shot reaper for run-one-cybergym-task.sh's self-cleanup trap: on abort the
    task wrapper hands us the agent pid (the GNU `timeout` wrapper) and we SIGKILL
    its entire subtree so no orphaned run.py keeps hitting the LLM endpoint. Unlike
    `_terminate` there is no SIGTERM grace — the caller has already decided to hard
    kill. Descendants are killed before the root for the same reason as _terminate
    (whoever is `wait`ing on the root unblocks the instant it dies). Returns 0
    always (best-effort reap; a missing pid is success)."""
    pid = args.pid
    if not pid:
        print("kill-tree mode requires --pid", file=sys.stderr)
        return 2
    kids = _descendants(pid)
    victims = list(kids) if args.descendants_only else [*kids, pid]
    killed = 0
    for victim in victims:
        try:
            os.kill(victim, signal.SIGKILL)
            killed += 1
        except ProcessLookupError:
            pass
        except PermissionError:
            print(f"[kill-tree] no permission to kill pid {victim}", file=sys.stderr)
    print(f"[kill-tree] root={pid} descendants={len(kids)} "
          f"signalled={killed} (descendants_only={args.descendants_only})",
          file=sys.stderr)
    return 0


def run_analyze(args, cfg: Config) -> int:
    """Offline report over one or more task log dirs. Returns 0 always."""
    results = []
    # With --json, stdout is reserved for pure JSON; the human report goes to
    # stderr so the JSON can be piped/parsed cleanly.
    out = sys.stderr if args.json else sys.stdout
    for log_dir in args.log_dir_list:
        events = load_events(log_dir)
        # Run-end proxy for the terminal-hang stall: explicit override, else the
        # latest file mtime under the task dir (teardown artifacts mark the kill).
        run_end_ts = args.run_end_ts if args.run_end_ts > 0 else _latest_any_file_mtime(log_dir)
        v = analyze(events, cfg, run_end_ts=run_end_ts)
        results.append((log_dir, v))
        status = f"WOULD-ABORT[{v.reason}]" if v.triggered else "ok"
        term = v.evidence.get("terminal_idle_secs", 0.0)
        gap = v.evidence.get("max_inter_event_gap_secs", 0.0)
        print(f"== {log_dir}", file=out)
        print(f"   verdict           : {status}", file=out)
        if v.detail:
            print(f"   detail            : {v.detail}", file=out)
        print(f"   events / infm-obs : {v.n_events} / {v.n_pairs}", file=out)
        print(f"   max gap / terminal: {gap:.0f}s / {term:.0f}s (stall_secs={cfg.stall_secs:.0f})", file=out)
        print(f"   modal obs repeat  : {v.modal_repeat} (loop_window={cfg.loop_window}, "
              f"loop_threshold={cfg.loop_threshold})", file=out)
    if args.json:
        print(json.dumps(
            [{"log_dir": d, "triggered": v.triggered, "reason": v.reason,
              "detail": v.detail, **v.evidence} for d, v in results],
            indent=2,
        ))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=("watch", "analyze", "kill-tree"), default="watch")
    # Thresholds (env-overridable defaults are applied by the bash caller).
    p.add_argument("--stall-secs", type=float, default=600.0,
                   help="abort if no new event for this many seconds (default 600)")
    p.add_argument("--loop-window", type=int, default=12,
                   help="trailing observation window for loop detection (default 12)")
    p.add_argument("--loop-threshold", type=int, default=10,
                   help="modal observation occurrences within the window that trip loop (default 10). "
                        "Validated: real loopers saturate to 12/12, healthy runs peak at 2/12.")
    p.add_argument("--min-events", type=int, default=24,
                   help="minimum informative observations before a loop can trigger (default 24)")
    # watch mode
    p.add_argument("--log-dir", help="task --log_dir to watch (watch mode)")
    p.add_argument("--agent-pid", type=int, help="pid to SIGTERM on trigger (watch mode)")
    p.add_argument("--abort-file", help="JSON reason written here on trigger (watch mode)")
    p.add_argument("--poll-secs", type=float, default=30.0, help="poll interval (watch mode, default 30)")
    p.add_argument("--since", type=float, default=0.0,
                   help="epoch; ignore event files older than this (watch mode — excludes a prior "
                        "run's stale events on a --force rerun/retry). 0 = no filter.")
    p.add_argument("--term-grace", type=float, default=30.0,
                   help="seconds to wait after SIGTERM before SIGKILL (watch mode, default 30)")
    # kill-tree mode (self-cleanup reaper for run-one-cybergym-task.sh)
    p.add_argument("--pid", type=int, default=0,
                   help="root pid whose subtree to SIGKILL (kill-tree mode)")
    p.add_argument("--descendants-only", action="store_true",
                   help="kill only the descendants, leave the root pid (kill-tree mode)")
    p.add_argument("--max-watch-secs", type=float, default=0.0,
                   help="hard stop for the watcher itself (0 = until agent exits)")
    # analyze mode
    p.add_argument("log_dir_list", nargs="*", help="task log dirs to characterize (analyze mode)")
    p.add_argument("--json", action="store_true", help="also emit machine-readable JSON (analyze mode)")
    p.add_argument("--run-end-ts", type=float, default=0.0,
                   help="epoch run-end for the terminal-hang stall (analyze mode); "
                        "0 = infer from the latest file mtime under each log dir")
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    # Clamp to sane floors: loop_window>=1 avoids the obs_sigs[-0:]=="whole list"
    # negative-zero slice; the others guard against a misconfigured 0/negative.
    cfg = Config(
        stall_secs=max(1.0, args.stall_secs),
        loop_window=max(1, args.loop_window),
        loop_threshold=max(1, args.loop_threshold),
        min_events=max(1, args.min_events),
    )
    if args.mode == "kill-tree":
        return run_kill_tree(args)
    if args.mode == "watch":
        if not args.log_dir or not args.agent_pid:
            print("watch mode requires --log-dir and --agent-pid", file=sys.stderr)
            return 2
        return run_watch(args, cfg)
    # analyze
    if not args.log_dir_list:
        if args.log_dir:
            args.log_dir_list = [args.log_dir]
        else:
            print("analyze mode requires at least one log dir (positional)", file=sys.stderr)
            return 2
    return run_analyze(args, cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
