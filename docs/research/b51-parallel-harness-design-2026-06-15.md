# b51 — Parallelize the CyberGym task harness (design v2)

**Issue:** `bd benchmarks-b51` (epic `9g4`). **Status:** design for review — no code yet.
**Date:** 2026-06-15. **Prereqs cleared:** H3 serving ceiling (`9g4.2` → one Spark serves N≈8–16 freely),
no-progress detector default-on (`9g4.4` → the `longest_task` floor is bounded).

## Changelog — v1 → v2 (after adversarial review, 2026-06-15)

A Codex adversarial review (grounded in the runner source + upstream CyberGym server + SQLite docs) found v1
treated **shared state, teardown, and resumability as minor fixes when they are the main failure surface**.
v2 reverses two v1 decisions:

- **v1 "one shared `cybergym.server` + one WAL `poc.db` for all N"  →  v2 per-task hermetic server + db.** WAL
  is single-writer serialization, *not* N-writer throughput, and the server blocks its request handlers while
  running a docker grading container — so one server under N submits risks `database is locked` /
  `no_poc_submitted` silent failures. Per-task state is also *simpler*, not just safer: it dissolves the
  concurrency question, narrows cleanup to one directory + container set, and makes S3 resumability natural.
- **v1 "bash `wait -n` bounded pool"  →  v2 small Python parent (or `xargs -P`).** The runner uses
  `set -Eeuo pipefail` + `inherit_errexit`; a nonzero worker fires the ERR trap / can kill the parent before
  its status file is written, and `wait -n` returns the worker's exit status into that trap. Robust signal
  fan-out + container reaping is the dominant requirement (below) and bash traps handle it poorly.

Net effect: **less** moving shared state than v1, and the teardown/resume correctness is designed in, not bolted on.

## 1. Goal & wall model

Today `run-pool-a-cybergym.sh` runs tasks in a **strictly sequential** `for` loop (`main()`, 1263–1291):
column wall = `Σ(task walls)`. Convert to a **bounded pool of N hermetic tasks** →

```
wall  →  max( longest_task , Σ(task walls) / N )
```

With 9g4.4 the `longest_task` term is bounded (staller aborts ~`stall_secs`+grace; looper at the loop
trigger). **N is harness-host-bound, not GPU-bound** (H3: one Spark served 16 concurrent 16K-ctx sessions,
zero preemptions, rising aggregate throughput). The binding constraint is the harness box — each task is a
C/C++ build + ASan + a docker-in-docker OpenHands runtime + (now) a task-local grading server.

> **N (pool concurrency) ≠ n (task count).** `N` = `CYBERGYM_POOL_N`, how many tasks run *at once* (this
> issue's lever). `n` = how many tasks in the column (the *powered* axis: 10 → 40–50, tracked in `9g4.3`).
> They are independent — n=50 at N=8 runs 50 tasks 8-at-a-time. **b51 is what makes a bigger `n` feasible**, by
> raising `N` so the column wall stays bounded; the bigger-`n` run itself is `9g4.3`, which b51 unblocks.

## 2. Current architecture (what we change)

- **Sequential loop (1263–1291):** `for task_id; do (run_cybergym_task) ; tally ; markers ; s3 sync ; done`.
- **`run_cybergym_task`** already isolates per-task `log_dir`/`tmp_dir`/workspace/`agent_id`/docker container/
  `abort_file`, launches the agent in the background with a per-task no-progress watcher, waits, extracts the
  verdict. **But it is NOT fully self-contained** (the v1 blind spot): it writes to a **global** runner log, a
  **global** S3 prefix, the **shared** `cybergym.server`/`poc.db` (`session_setup` 697–760, one server on
  `CYBERGYM_SERVER_PORT`), the shared docker daemon, and a global `BENCH`.
- **Teardown today is parent-only:** the spend watchdog SIGTERMs *the parent* on cap (`watchdog_loop` 588);
  `_exit_handler` (312) stops the one server, kills the watchdog, does a final whole-tree S3 sync — it does
  **not** kill background workers or their docker containers. In a pool that orphans live work against a dead
  server.
- **Resume today:** skip iff `result.json` exists (868) — no validity check; `write_result_json` (`_lib.sh`
  476) writes the final path directly (no temp+rename); `s3_sync_results` (`_lib.sh` 392) syncs the **whole
  bench tree**.

## 3. Architecture: hermetic tasks (the core of v2)

Each task runs as a **self-contained unit** owning all of its state:

- **Task-local grading server + db.** The `cybergym.server` CLI already takes `--port`, `--db_path`,
  `--log_dir` (728–736). Each task allocates a free port (bind `:0` / scan; reuse `bd benchmarks-l11`'s
  auto-pick), starts its own server with `--db_path <task_dir>/poc.db` and `--log_dir <task_dir>/server/`, and
  points `CYBERGYM_SERVER_URL_FOR_AGENT` at that port. **No shared SQLite, no cross-task contention.** Cost: N
  lightweight uvicorn processes — modest, well within the host budget that the build/ASan already dominates.
- **Atomic result writes.** `result.json` / `status.json` / verdict written via **temp + `mv` (rename)** so a
  crash never leaves a truncated file a later run would skip. (Fix `write_result_json` to temp+rename.)
- **Per-subtree S3 upload, after completion.** Each task uploads **only its own** `…/<task_id>/` subtree, and
  only once the task is fully done — never the whole bench tree mid-write (kills the concurrent-overwrite race).
- **Self-cleanup.** On task end *or* abort, the task tears down its own server + docker runtime container
  (labelled at launch, below) + workspace.

The **parent** then owns only three things: **bounded-concurrency dispatch**, **signal fan-out / teardown**
(§5), and a **final tally** from the per-task `status.json` files (§6). This is the whole reason hermetic
tasks are simpler — the parent holds no shared mutable state.

## 4. Dispatch

Recommended: a **small Python parent, run via `uv`** (`uv run`, PEP-723 inline deps or a tiny pyproject — no
global installs, reproducible), that shells out to a per-task entrypoint (the existing `run_cybergym_task`
logic, extracted to a callable `run-one-cybergym-task.sh <task_id>` made hermetic per §3). Python gives robust
**signal fan-out + container reaping** (§5) and a clean status tally, with no errexit/ERR footgun. Minimal
alternative: `xargs -P N` (simple, but crude signal handling — it won't reap docker containers, so §5 teardown
would have to live in each task's own trap). **Rejected:** bash `wait -n` pool (the errexit/ERR-trap hazard
above). Knob `CYBERGYM_POOL_N` (**N=1 calls the per-task entrypoint once → byte-identical to today**,
preserving paired-baseline reproducibility; default + target discussed in §8).

## 5. Teardown & abort safety (top failure mode)

The dominant risk is leaking live workers + docker containers + task servers on abort (spend cap, Ctrl-C,
error). Design:

- **Label every task container at launch** (e.g. `--label cg_campaign=<campaign> --label cg_task=<id>`) so the
  parent can reap by label even if it loses the pid.
- **Each task wrapper** runs in its own **process group** (`setsid`), and traps SIGTERM/EXIT to: SIGKILL its
  process subtree (reuse the no-progress watcher's `_descendants` sweep), `docker rm -f` its labelled
  container(s), stop its task server.
- **The parent** on SIGTERM/spend-cap: stop dispatching, signal every worker process group, then a **backstop
  reap** `docker rm -f $(docker ps -q --filter label=cg_campaign=<campaign>)`, then exit. The spend watchdog
  must target the **pool** (process group), not just the parent pid (current 588 behavior).
- `_exit_handler` (312) becomes pool-aware: drain/kill workers + reap containers **before** the final S3 sync.

## 6. Resumability & idempotency

For a 40–50 task run on an **ephemeral** EC2 box:

- **Skip only a VALID completed result** — `result.json` exists *and* parses *and* carries a terminal status
  (not a truncated/in-flight file). Combined with temp+rename (§3), this is crash-safe.
- **Pull-back before run.** On startup, if results may live in S3 (fresh host), `aws s3 sync
  s3://…/<campaign>/<target>/<bench>/ <local>` first, so completed tasks are seen and skipped. (Today nothing
  repopulates the local tree on a replacement host.)
- Task-local `poc.db` + server logs live **under the task subtree**, so they sync to S3 with the task (today
  they sit outside the synced tree and are lost).

## 7. Concurrency-safety audit (v2 — most of v1's table disappears)

| Resource | v1 concern | v2 |
|---|---|---|
| `cybergym.server` / `poc.db` | one server, N submits, WAL throughput | **gone** — per-task server + db |
| result / status / verdict writes | races / truncation | temp+rename, per-task path |
| S3 upload | whole-tree concurrent sync mid-write | per-task subtree, post-completion |
| `write_progress` key | 1 s granularity collision | key += `task_id` + nanoseconds/UUID |
| pass/fail tally | parent-shell locals unusable from workers | per-task `status.json` (harness rc **and** pass/fail, distinct), tallied after join |
| docker daemon | shared | shared — **the real N ceiling** (§8); contained via labels + reaping (§5) |
| host disk / CPU | understated | §8 |

## 8. N policy, disk & CPU (was understated in v1)

- **Disk is the first wall.** Per task: OpenHands runtime image + grader images + CyberGym binary data +
  workspace + overlay2 churn + logs. Budget **≥ ~15 GB transient per concurrent task**; at N=16 that is
  240+ GB *before* base images. The current preflight only checks `/` ≥ 30 GB (452) — **raise it to a
  function of N** and put docker data-root + workspaces on a sized `/data` volume.
- **Build CPU + docker daemon contention is the real N ceiling**, not the Spark (H3). Measure host load vs N to
  find the knee (this *is* the H2 "harness-CPU-bound at cN" data point).
- **N is a floor-then-target, not a constant, and is set by the HOST.** `CYBERGYM_POOL_N=4` is only a
  **conservative validation floor** (N=1 = today). Dev + small-N validation run on the **current proxmox-02 VM
  (8 cores → N≤4)** — no AWS. The **powered run targets N≈16–24 on a beefy EC2 node** (`~c7i.24xlarge`, 96
  vCPU; operator decision 2026-06-16 — see §9). H3 proved the Spark serves that freely, so the cap is the
  harness-host CPU/disk knee. At N=4 a 50-task column barely beats sequential; at N≈16–24 it collapses toward
  the ~1.5–2h serving-strategy target. Ramp N to the measured knee for `9g4.3`, watching disk/CPU and (a
  guardrail for full-attention models later) Spark `num_preemptions`. **Per-`n`/per-host knob — never bake one
  N in.**

## 9. EC2 host — size *per harness*, not one-size-fits-all (ref `docs/research/ec2-harness-design.md`)

Big **on-demand** box, provisioned per-run (harness↔GPU decoupling; ejv ran clean over a 116 ms/88 Mbit
tunnel). **Not spot** (operator 2026-06-16): a powered run is ~1.5–3 h and a spot box would very likely be
reclaimed mid-run; b51's per-task S3 resume mitigates but on-demand removes the risk for the cost of a few
dollars on a one-off run.

**Host decision (operator, 2026-06-16): a beefy EC2 node, NOT a proxmox-02 resize.** proxmox-02 has only 16
physical cores total; since CyberGym is CPU-bound on the build+ASan, an on-prem resize tops out at N≈6–8 and
would consume most of the box — not worth it. EC2 (`~c7i.24xlarge`, 96 vCPU) is the powered-run host; the
current proxmox-02 VM stays the dev / small-N (N≤4) box (no AWS needed there). **IAM gate for the powered run
(your laptop, not the sandbox):** run the updated `harness-up.sh` with IAM-admin creds (reconciles
`harness-driver-role` + instance profile + SG, launches the box — needs `iam:CreateRole`/`PassRole`/
`ec2:RunInstances` etc. the sandbox lacks); check/raise the EC2 *On-Demand* vCPU quota for `c7i`; the role *policy*
itself needs no change (b51 adds no new AWS service). Bump `harness-up.sh`'s SKU/storage (m6i+100 GB →
`c7i.24xlarge` + N-sized `/data`) before that run.

**Different harnesses have different resource profiles → different host sizes. Do not impose one SKU on all
of them.** This section sizes the host **for the CyberGym hermetic pool specifically**, whose profile is the
heavy end: per concurrent task = a C/C++ build + ASan + a docker-in-docker OpenHands runtime + a task-local
grading server + grader containers. For *that* profile at N≈8–16, the host needs `~c7i.24xlarge`-class CPU
**and** a sized `/data` volume (docker data-root + workspaces, ≈ N × 15 GB + base images). Other harnesses are
not the same and must be sized on their own profile — e.g. the 3xi.2 agentic-coding bench (different runtime
images, different build cost), or Pool B's lm-eval (decode-bound, near-nil per-task disk). **Action:** stop
treating `ec2-harness-design.md` as a single universal spec — give it a small per-bench sizing table (CPU /
RAM / `/data`), with the CyberGym pool row set here; let cheaper benches pick smaller boxes.

Fargate out (no privileged docker-in-docker); ECS/Batch premature (H3: one Spark serves far more than one box
drives).

## 10. Testing plan

1. **N=1 byte-identical** check: the per-task entrypoint at N=1 reproduces today's single-task path.
2. **Small-N on the VM (N=2):** two tasks concurrent against one Spark; each with its own server/db/port;
   verdicts correct; atomic results; per-subtree S3 upload; correct tally; **kill -SIGTERM the parent mid-run →
   confirm zero orphaned containers/servers** (the §5 teardown); a forced looper aborts without touching its
   sibling.
3. **Resume:** kill mid-run, rerun → completed tasks skipped (valid-result check), partials redone; repeat on
   a *fresh* local tree with S3 pull-back.
4. **Scaled on EC2** (10-task subset, N ∈ {4,8,16}): wall vs c1, **disk/CPU knee (H2 data)**, Spark
   `num_preemptions`.
5. **Powered run** (`9g4.3`) at n=40–50 once the knee + safe N are set.

## 11. Rollout phases

1. **✅ DONE (bd benchmarks-b51.1, 2026-06-16).** Extract `run-one-cybergym-task.sh` (hermetic per §3:
   task-local server/db on an allocated free port, atomic result/status/verdict writes, labelled OpenHands
   container via the install-harness.sh run.py patch, self-cleanup trap reusing the watcher `_descendants`
   sweep). `run-pool-a-cybergym.sh` rewired to dispatch to it; `CYBERGYM_POOL_N=1` = today's sequential path.
   Shared bits in `_cybergym_common.sh`; `lib_write_atomic` in `_lib.sh`. `harness-up.sh` SKU/storage bumped to
   the §9 CyberGym row. Validated N=1 on the proxmox-02 VM against the Gemma Spark (server-per-task, labels,
   atomic writes, clean teardown all confirmed). The no-progress detector (9g4.4) is preserved.
2. **✅ DONE (bd benchmarks-b51.2, 2026-06-16).** Per-task teardown trap [✅ landed in Phase 1] + the §6
   valid-result skip (`lib_result_is_terminal`) + S3 pull-back (`s3_pull_results`).
3. **✅ DONE (bd benchmarks-b51.2, 2026-06-16).** Python parent (`scripts/runners/_cybergym_pool.py` — stdlib,
   system `python3`, see §12 amendment): dispatch + signal fan-out to worker process groups + docker reap
   backstop by label + tally from per-task `status.json`. Plus the per-task `write_progress` key fix, per-task
   subtree S3 upload, and N-aware disk preflight. The entrypoint now writes its own failure marker/status.json on
   a harness error so the parent only tallies. (NOTE: the prompt's "Phase 2" folds design-doc phases 2+3.)
4. **Small-N VM validation (§10.1–3) — IN PROGRESS (b51.2, 2026-06-16):** on the on-prem `ejv-harness` VM at N=2
   against the <SPARK_NODE_2> Gemma Spark. Confirmed: per-task server/db/port isolation, N-aware preflight, SIGTERM mid-run
   → zero orphaned containers/servers/agents, resume.
5. EC2 SKU/volume update [harness-up.sh defaults done in Phase 1] + scaled validation (§10.4) — yields the H2 knee.
6. Powered run (`9g4.3`).

## 12. Decisions

- **Hermetic per-task server + db** (vs one shared) — **APPROVED 2026-06-16.** Safer and simpler.
- **Dispatch via a small Python parent, run with `uv`** (vs `xargs -P` minimal / vs bash `wait -n` rejected) —
  **APPROVED 2026-06-16** (operator: prefer `uv` over bare python). Thin orchestrator that shells the per-task
  bash entrypoint.
  - **Implementation amendment (operator, 2026-06-16, Phase 2):** run the parent with the **system `python3`**, not
    `uv`. The operator clarified the `uv` preference was only to avoid this Ubuntu host's pip/venv pain (PEP-668
    externally-managed-env); the dispatcher (`scripts/runners/_cybergym_pool.py`) imports **only the standard
    library** (subprocess + signal + json + pathlib), so there is nothing to pip/venv-install and nothing for `uv`
    to provision — it runs directly under the `python3` already present on every host. `install-harness.sh` is
    therefore untouched (no `uv` dependency added). The dispatch design is otherwise exactly as approved: a thin
    parent that shells the per-task bash entrypoint, with N=1 routed through it at concurrency 1 (byte-identical).
- **Host = beefy EC2 node** (operator 2026-06-16; proxmox-02 resize rejected — 16-core ceiling → only N≈6–8,
  not worth consuming the box). Powered run on `~c7i.24xlarge`; dev/small-N on the current proxmox-02 VM (no
  AWS). IAM gate (your laptop): run `harness-up.sh` w/ IAM-admin + check `c7i` On-Demand vCPU quota; policy unchanged.
- **Per-harness host sizing** (operator 2026-06-16: stop treating all harnesses as one size) — refactor
  `ec2-harness-design.md` into a per-bench sizing table rather than one universal SKU. The CyberGym pool row is
  the beefy node above; other benches (3xi.2 coding, Pool B) size on their own profiles.
- **N is a floor→target, not a constant** (operator 2026-06-16): `CYBERGYM_POOL_N=4` is the conservative
  validation *floor* only; powered `9g4.3` runs ramp N→≈8–16 at the measured host disk/CPU knee (H3 says the
  Spark allows it). N is a per-`n`/per-host knob; do not bake one value in. Remaining open question: the exact
  knee — answered empirically in §10.4.
