# to4 session opening prompt (2026-05-29)

The exact text to drop into a **new** Claude Code session in
`/home/agent/work/benchmarks` as the very first message. Keeps the new
session's first turn deterministic — `bd prime` pulls the handoff memory,
and the prompt immediately routes to the shakedown.

## Prompt — copy from here

```
Read bd memory `to4-session-handoff-2026-05-29` in full — it's the operator
handoff for this session and contains the goal, priority order, cost envelope,
pre-flight gates, and read-list.

Goal: make tangible progress on bd to4 (CVE-Bench open-weight sweep). Minimum
success = one complete cell (bd to4.1 Gemma 4 31B Dense, all 40 CVEs run
end-to-end, results synced to S3, sweep-status.md regenerates with the cell).
Stretch = bd to4.2 (Qwen3.6 35B-A3B MoE) also complete. Best = 3-4 cells.

The 4 child issues are already filed: bd to4.1, to4.2, to4.3, to4.4. The Gemma
31B shakedown launcher is staged at `scripts/staged/to4-gemma31-cvebench-shakedown.sh`.

Plan:
1. Read the handoff memory + the read-list it specifies (10-min skim).
2. Pre-flight: SSH to the harness, verify the bd <ISSUE> fix is live (`/opt/harnesses/cve-bench/.venv/bin/python -c 'import openai, anthropic, boto3'`).
   Re-run install-harness.sh if absent. Verify no concurrent Pool A docker
   workload (`docker ps`).
3. Claim bd to4.1. Provision a Runcrate RTXPro6000 ×1 KC rental via
   `scripts/rental-vllm-up.sh scripts/rental-specs/gemma-4-31b-it-nvfp4.yaml`.
   Use the `gpu-rental-flow` skill — mandatory teardown discipline is
   non-negotiable.
4. Export VLLM_URL from the rental, then run the shakedown:
   `sudo -E /opt/benchmarks/scripts/staged/to4-gemma31-cvebench-shakedown.sh`.
   Expected: ~30-45 min wall, ~$2-5 spend, 1 CVE (CVE-2024-2624) gets a real
   result.json with a wall_time_seconds we can extrapolate from. Watch the
   max-messages=30 ceiling question (per the handoff watch-points).
5. If shakedown is healthy, fan out to the full 40 CVEs on the same rental
   (run-pool-a-cvebench.sh, full canonical CVE list). Per-CVE s3 sync streams
   partial results.
6. When the full cell completes, regenerate sweep-status.md
   (`scripts/update-sweep-status.sh` on the harness), confirm the Gemma row's
   CVE-Bench cell populates, and close bd to4.1.
7. If budget/time permit: bd to4.2 (Qwen3.6 35B-A3B), then bd to4.3 (DSv4 —
   verify B300 ×1 Helsinki availability first; if absent, promote bd to4.4).
8. End-of-session hygiene: ALL rentals torn down (verify on Runcrate dashboard,
   no idle GPUs). Update bd to4 epic with progress + a memory capturing the
   measured per-CVE wall (closes the to4 "NEEDS CONFIRMATION" gap). Push bd
   dolt + git per CLAUDE.md session-completion protocol.

Start by reading the handoff memory and the cve-bench-setup-gotchas-2026-05-21
memory. Report your pre-flight findings before provisioning anything.
```

## Why these specific bullets

- Step 1 forces the session to ingest the handoff before doing anything — the
  memory holds the cost envelope, watch-points, and `max-messages=30` decision
  framing that should shape every subsequent choice.
- Steps 2-3 are the gates that historically broke (`bd <ISSUE>` openai extra,
  `bd <ISSUE>` docker concurrency). Failing fast here saves a wasted rental.
- Step 4 is the smallest possible signal: real wall + real spend + real
  ceiling check, for ~$2-5. Don't commit the full $30-50 cell until this
  lands.
- Steps 5-6 are the actual deliverable.
- Step 7 is stretch.
- Step 8 is the non-negotiable teardown + push discipline (rentals burn
  hourly; an unmerged session is wasted work).

## After the prompt — operator decision points the session will surface

These come up mid-session and require an operator call rather than a default:

- **Max-messages bump.** If the shakedown shows the Gemma agent pegged at
  message-30 across the 1 CVE with no convergence, the session should ask
  whether to ship the full cell at 30 (paper-canonical) or bump to 60 (the
  SEC-bench `bd <ISSUE>` pattern). DO NOT silently bump.
- **DSv4 SKU fallback.** If B300 ×1 Helsinki is unavailable when bd to4.3 is
  next, the session should promote bd to4.4 (Qwen3.6 27B) and defer DSv4
  rather than escalate to RTXPro6000 ×8 (which is forbidden per the V4-Flash
  readiness memo).
- **Stop-after-N decision.** If the Gemma shakedown reveals per-CVE wall is
  way above the 30-45min estimate, the operator should be told before the
  fan-out fires the full 40-CVE batch.
