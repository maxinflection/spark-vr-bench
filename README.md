# benchmarks

Home for our local-model **measurement** work — methodology, harnesses,
shared tooling, and the results archive. Anything where the question is
*"give me a clean number for this model on this config"* lives here,
whether the number is a CyberGym score or a tok/s figure.

A "campaign" is a bounded sweep with a question to answer. Campaigns
come and go. The methodology docs, the harness wrappers, the rules for
what counts as a clean number — those persist.

The name `benchmarks` reads like it's quality-only; it isn't. Quality
campaigns and performance campaigns share too much (harness wiring,
OpenAI-compatible endpoint targeting, results conventions, rented-GPU
lifecycle) to live in different repos.

**Current state:** bootstrap. Quality battery written
(`docs/eval-battery.md`); first campaign planned but not yet running
(`bd show benchmarks-rlp`). No performance campaigns yet; methodology
doc for that axis is unwritten.

## Two flavors of campaign

Both belong here. They share tooling but answer different questions and
report different numbers.

| Flavor | Question | Default unit | Methodology home |
|---|---|---|---|
| **Quality** | Given a model + quant, how does it score on publicly-comparable axes (vuln research, coding, instruction-following)? | pass@1, single-stream | `docs/eval-battery.md` |
| **Performance** | Given a model + quant + hardware + concurrency, what does it cost to serve and how fast? | tok/s, TTFT, TPOT, decode @ N concurrency | *(coming — `docs/perf-methodology.md` or similar)* |

Quality is a property of weights. Performance is a property of weights
× silicon × serving config. Mixing the two on a single results row is
the most common way to ship a misleading number — *always* tag a result
with which axis it's measuring.

## How this repo is organized

| Path | Lifetime | What |
|---|---|---|
| `docs/eval-battery.md` | durable | The standard **quality** battery: pool definitions, run profiles, frontier reference points, contamination caveats. |
| `docs/` | durable | Methodology and conventions that outlive any one campaign. Performance methodology will land here too. |
| `harnesses/` *(coming)* | durable | Wrappers / configs / pinned versions for the quality harnesses (lm-eval-harness, CyberGym, SEC-bench, CVE-Bench) and the perf harnesses (vllm bench, sglang-bench, …) we standardize on. |
| `campaigns/<id>/` *(coming)* | per-campaign | Per-campaign README, run configs, raw outputs, write-up. Frozen when the campaign closes. |
| `results/` *(coming)* | durable | Aggregated results across campaigns — the queryable archive. |
| `AGENTS.md` / `CLAUDE.md` | durable | Agent operating rules (workflow, shell hygiene, session-close protocol). |

The "coming" rows are aspirational layout — when the first real run
lands, that's the layout it should land into.

## Boundary with `spark-deploy`

`spark-deploy` (sibling repo) owns **operating and serving** the local
fleet on <SPARK_NODE_1> / <SPARK_NODE_2>: deploy automation, vLLM/sglang configs, the
internal security workload production workload, day-to-day uptime.

`benchmarks` (here) owns **measuring** models — wherever they happen to
be hosted (rented GPU, local Spark, frontier API). Both quality and
perf measurement live here.

There's natural overlap: a perf campaign measuring tok/s on the local
Sparks reaches into `spark-deploy`-managed serving infra. The rule is
which side of the question you're answering, not which hardware is in
the picture: *what does this config measure at?* (here) vs *how do we
keep this config running in production?* (there).

The handoff is the production-model pick: campaigns here declare
quality + perf winners; `spark-deploy` runs the chosen config under
load.

## The quality battery, in one paragraph

Three pools (vulnerability research / generic correctness /
workload-native), execution-graded only — no LLM-judge slop. Pool A
primaries are CyberGym, SEC-bench, CVE-Bench; Pool B is HumanEval+,
BigCodeBench-Hard, IFEval, SWE-bench Verified-50, GPQA Diamond; Pool C
is an internal security workload replay as final-gate sanity. Profiles range from
~30 min (Smoke) to multi-week (Ceiling). Every fresh deploy → Smoke;
every model in a sweep → Screening (one quant, full Pool A coverage);
top candidates → decision-driven Post-screening depth options. Full
reasoning in `docs/eval-battery.md`; that doc overrides this paragraph
wherever they disagree.

The performance equivalent — pool of perf benchmarks, default sweep
shape, reporting conventions — is yet to be written. When a perf
campaign motivates it, that's where it lands.

## Current campaign: off-Spark quality sweep

Epic `benchmarks-rlp`. Goal: publicly-comparable quality numbers across
our deployed-quant model candidates, run on rented B200/H200 instances
rather than the local Sparks.

The harness host (`<HARNESS_HOST>` on `<PROXMOX_HOST>`)
is persistent across rental cycles and can target rented GPUs OR a
local Spark OR frontier APIs through the same configuration. That's
the methodology win — same harness, three classes of target,
comparable numbers.

```bash
bd show benchmarks-rlp     # the campaign
bd ready                   # tasks available to claim
```

## Future campaigns

The repo is intentionally not built around any single campaign.
Campaigns we expect to host over time:

**Quality**
- Standard-battery re-runs against new model releases.
- Quant-sweep studies (FP8 vs NVFP4 vs Q-something on the same weights).

**Performance**
- Throughput / latency sweeps on <SPARK_NODE_1> / <SPARK_NODE_2> across deployed-quant
  candidates (decode tok/s, TTFT, TPOT, prefill rate, sustained
  concurrency).
- Drafter / speculative-decode acceptance-rate + speedup studies.
- Rented-GPU vs local-Spark perf parity checks.

**Cross-axis**
- Quality-under-load — does sustained concurrent decoding move quality
  numbers (prefix-cache effects, scheduling artifacts)?

If a question fits the shape *given a model + config, what's the
number?*, it belongs here.

## Workflow

`bd` is the only task tracker (no TodoWrite, no markdown TODOs).
Standard loop:

```bash
bd ready                   # find work with no blockers
bd show <id>               # read the spec
bd update <id> --claim     # take it
bd close <id>              # finish it
```

Run `bd prime` for the full command reference and the session-close
protocol (commit + push is mandatory; `bd dolt push` syncs the issue
DB to the remote).

## Reporting conventions

Every reported number carries: model, quant, harness version + commit,
hardware (specific GPU SKU + count + TP/PP), date, and **the axis
being measured**.

- Quality default: pass@1, single-stream. Anything else (pass@10,
  best-of-N, majority vote) called out explicitly.
- Performance default: state the regime — single-stream TPOT,
  aggregate decode @ N concurrency, prefill tok/s — they are not the
  same number and a row that doesn't say which is being reported is
  an unusable row.

Vendor frontier numbers (system cards, leaderboards) are *anchor
points* for stratification, not pass/fail criteria.

## Out of scope

- Operating / serving the local fleet (→ `spark-deploy`)
- internal security workload workflow code itself (→ `spark-deploy`)
- CTF benchmarks, MMLU-Pro, MATH-500 (excluded by design — see eval-battery.md)
- Pure vendor-API perf claims with no measurement of our own (we don't
  run those endpoints, can't characterize their serving config)
