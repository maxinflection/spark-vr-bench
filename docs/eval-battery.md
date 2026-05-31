# Eval Battery: Standard Benchmark Suite

A reference set of benchmarks for evaluating LLMs on coding and
vulnerability-research tasks. Built to answer one question cleanly:
**given a model and a deployed quantization, how does it stack up on
publicly-comparable axes — including the vulnerability-research axis?**

This is the standard battery. New models and new deployments should be run
through it before being declared "good" or "bad" relative to the existing
fleet, and before being compared against frontier API models.

## Why this exists

Two failure modes this battery is designed to avoid:

1. **Quant-confound.** Published frontier numbers (Anthropic system cards,
   Qwen leaderboards, etc.) are reported on BF16 or vendor APIs. Local
   deployments typically run FP8 / NVFP4 / Q4_K_XL / etc. A "Qwen3-235B
   beats Qwen3.6-27B on SWE-bench" claim using BF16 numbers tells us very
   little about an FP8 or NVFP4 deployment. Mitigation: always run the
   deployed quantization through the same harness, and where feasible,
   sweep at least two quants per model.

2. **Workload-myopia.** Workload-native tests are noisy and not comparable
   to anyone outside the team running them. They answer "did the model do
   the job?" but not "is this 27B vs 235B difference capability-bound or
   deployment-bound?" Mitigation: anchor on public benchmarks with
   published frontier numbers, then add the workload-native run at the end
   as a sanity gate.

This battery is also useful **outside** the local-inference context —
anywhere a model is being picked for an agentic security workflow.

---

## The pools

Three pools of benchmarks to sample from when constructing a run. A run
combines members across pools — an abbreviated pass might be one fast
generic benchmark plus one fast agentic vuln-bench, not the full battery.
The pools and per-bench tradeoffs are below; concrete run profiles are in
the next section.

Frontier numbers later in this doc are reference points for stratification,
not pass/fail criteria.

### Pool A — Vulnerability research (the primary axis)

| Benchmark | Year | Task | Grading | Scale | Storage | License |
|---|---|---|---|---|---|---|
| **CyberGym** | June 2025 (v2 late 2025) | PoC reproduction + open-ended discovery against real OSS-Fuzz CVEs | Sanitizer-verified, no LLM-judge | 1,507 tasks, 188 projects (OpenSSL, FFmpeg, libxml2, …) | ~130 GB binary mode / ~10 TB full | Apache-2.0 |
| **SEC-bench / SEC-bench Pro** | June 2025; Pro Dec 2025 | PoC generation + patching, **agentic** (tool use) | Differential sanitizer (crashes pre-patch, doesn't crash post-patch) | C/C++ + 103 V8 (JS/Wasm) in Pro | Per-instance docker | Open |
| **CVE-Bench (UIUC Kang lab)** | March 2025 (ICML 25 spotlight) | Web-app exploit generation against live containers | Harness *fires* the exploit against a running stack, observes RCE/exfil/etc. | 40 dockerized CVEs (May–Jun 2024) | 40 docker images | Apache-2.0 |

These three were chosen because:

- All grade by **executing the model's output against a real artifact** —
  no "did the answer look plausible" LLM judge.
- They cover the three buckets that matter: **memory-safety C/C++ PoCs**
  (CyberGym), **agentic patch+PoC loops** (SEC-bench), **web-stack
  RCE/injection PoCs** (CVE-Bench).
- All have **published frontier-model numbers** from 2025–2026 to cite
  against. Anthropic's own system cards report CyberGym scores by Opus
  version.
- The corresponding training-dataset-style benchmarks (BigVul, DiverseVul,
  CrossVul) and pure-classification ones (PrimeVul, SecVulEval) are *not*
  the primary axis — they're contamination-prone and don't measure PoC
  generation. Use only as smoke tests.

### Pool B — Generic correctness (control variables)

| Benchmark | Why it's in the pool |
|---|---|
| **HumanEval+** | Function-level coding, fast, comparable to nearly every model card. Plus version (EvalPlus) catches more bugs than original. The cheapest first look at "does the model code at all". |
| **BigCodeBench-Hard** | Function-level with non-trivial library use; harder than HumanEval. Distinguishes "can write a function" from "can use an ecosystem". |
| **IFEval** | **Instruction-following / format-correctness.** Closest published proxy to the "can this model produce well-formed structured output reliably" question. Single-turn, fast. |
| **SWE-bench Verified (subset of 50–100)** | Industry-standard *agentic* coding eval — multi-turn, repo-level. Full set is expensive; subset is the de-facto fast-eval mode. Slow. |
| **GPQA Diamond** | Knowledge + reasoning, hard. Standard frontier comparison. Optional. |

This pool isolates capability axes that vuln benchmarks alone obscure: a
"0% on CyberGym" could mean low coding skill, low instruction-following,
both, or neither. Sampling one or two members from this pool tells us
which.

### Pool C — Workload-native sanity

A single replay of the team's own workload against a known-vulnerable
target. This answers "does it solve the actual job" — which Pools A and B
can't answer because no one outside the team runs those workloads.

Not a primary measurement (noisy, not comparable to anyone else). Used as
the final-gate sanity check on whichever config wins the public-benchmark
comparison.

---

## Run profiles

Concrete combinations to use depending on how much wall-clock time the
candidate is worth. Wall-time estimates are at single-node Qwen3.6-27B-FP8
throughput (~14 tok/s sustained); larger models will be slower per token.

### Smoke (~30–60 min)

- HumanEval+ only.

"Did this deployment basically work?" Confirms the endpoint is alive, the
model decodes coherent code, the harness wires through. Run this every
time a model is freshly deployed, before committing real benchmarking time.

### Screening (~24–40 hr per model, 1–2 days on faster hardware)

- HumanEval+ (Pool B) — basic coding sanity
- BigCodeBench-Hard (Pool B) — library-aware coding
- IFEval (Pool B) — format / instruction compliance
- CyberGym 10-task subset (Pool A) — agentic memory-safety vuln research
- CVE-Bench full, ~40 instances (Pool A) — agentic web-stack RCE / injection
- SEC-bench subset, ~50 instances (Pool A) — agentic patch+PoC C/C++ + JS/Wasm
- SWE-bench Verified-50 (Pool B, agentic) — standard agentic coding eval

The screening profile prioritizes Pool A coverage at the deployed quant.
Three independent vuln-bench shapes (memory safety, web RCE, patch+PoC)
beat one slice on a single axis when deciding which models earn deeper
investigation. Non-agentic Pool B benches run first as a smoke gate — if
a model can't clear roughly 40% on HumanEval+, abort before spending
agentic hours on it. Run this once per model in the sweep, deployed
quant only.

### Post-screening depth options (decision-driven)

After screening data lands, scope additional work to the top 1–3
candidates. Which lever to pull depends on what the data leaves
unanswered, not on a fixed sequence:

- **+1 quant comparison** — same Screening profile run at one step higher
  on the quant ladder (FP8 → BF16, NVFP4 → FP8) where it fits in memory.
  Bounds the quantization confound. Use when winners look surprising or
  candidates are clustered close together.
- **Deeper agentic** — SEC-bench full, CyberGym expanded subset
  (50 / 100 tasks), or CVE-Bench second-pass for variance bounds. Use
  when a candidate's Pool A numbers feel screen-noise-bound.
- **Tiebreakers** — GPQA Diamond (knowledge / reasoning), workload-native
  replay (Pool C, sanity check). Use when two candidates are effectively
  tied on the primary axis.

### Ceiling (multi-week per model)

- CyberGym full 1,507 tasks
- SWE-bench Verified full
- SEC-bench full

Reserved for the production pick. Do not run speculatively.

### Profile selection guidance

- **Every fresh deployment** → Smoke (~1 hr)
- **Every model in the sweep** → Screening, deployed quant only (~1–2 days
  per model on rented GPU hardware; longer on lower-throughput nodes)
- **Top 1–3 candidates from Screening** → one or more Post-screening depth
  options, chosen based on what the data leaves open
- **The chosen production model, after deploy decisions are settled** → Ceiling

The ratchet runs in one direction. Don't use Post-screening options for
first-pass evaluation — that's what Screening is for. Don't skip Smoke
just because you're in a hurry; a broken endpoint discovered hours into
a CyberGym run is expensive.

---

## Methodology

### Harness layer

- **Pool B (generic):** [`lm-evaluation-harness`][lm-eval] points at the
  OpenAI-compatible `:8080` endpoint. Model-agnostic, quant-agnostic.
- **CyberGym:** native harness, runs from the [GitHub repo][cybergym-gh].
  Docker-based. Start with the published 10-task representative subset
  before committing to the full 1,507.
- **SEC-bench:** native harness from the [project page][secbench]. Agentic.
- **CVE-Bench:** native harness from the [GitHub repo][cvebench]. Each
  CVE is a docker target.

All four harnesses target an OpenAI-compatible endpoint. A standard vLLM
deployment on `:8080` works directly. For models not hosted locally,
they can target Anthropic / OpenAI / OpenRouter for a frontier baseline.

### Quantization sweep

Where feasible, run each model at two quants:

- **Deployed quant** (the one that would actually be served)
- **One step higher** (closest to "what the published number was measured at")

This bounds the quantization confound. If the deployed-quant score is
within ~2 points of the higher-quant score, quant isn't the story. If it's
5+ points off, the cost of the deployment choice is now quantified.

Hardware constraint: available GPU memory often makes BF16 impractical
for large models. The highest reachable quant is typically FP8 or
UD-Q6_K_XL depending on the serving node.

### Contamination handling

Per-benchmark, in order of risk:

- **CVE-Bench** — all 40 CVEs from May–Jun 2024, in-window for any 2024+
  cutoff model. Mitigation: harness requires a *working payload*, not a
  description, so memorization carries less than it would on a
  classification eval. Still: report as a known caveat.
- **CyberGym** — authors published a pre/post-cutoff split. Effect was
  minimal on Claude 3.7 Sonnet (11.9% vs 12.1%), moderate on GPT-4.1
  (9.7% → 5.6%). The 139-CVE late-2025 refresh is post-cutoff for current
  open-weight models. Report scores split by disclosure date.
- **SEC-bench** — PoC generation requires producing a sanitizer-tripping
  byte string; recall doesn't help much. Pro's V8 slice (Dec 2025) is
  mostly post-cutoff for current open-weight models.
- **SWE-bench Verified** — well-known contamination, especially for any
  model trained on GitHub issues. Treated as a relative metric, not
  absolute.

### Always quote which axis you're measuring

Single-stream TPOT vs aggregate decode at N concurrency vs prefill tok/s
are not the same number. Same applies to pass@1 vs pass@10 on coding
benches. Default to **pass@1, single-stream** unless explicitly noting
otherwise.

---

## Frontier numbers (anchor points)

These are the numbers local deployments can be benchmarked against.
Treat as approximate and confirm against the most recent system card before
citing.

| Bench | Frontier model | Score | Source |
|---|---|---|---|
| CyberGym | Opus 4.5 | 50.6 | Anthropic system card |
| CyberGym | Opus 4.6 | ~66 | Anthropic system card |
| CyberGym | Opus 4.7 | 73.1 | Anthropic system card |
| CyberGym | GPT-5 (high-thinking, older harness) | 22.0 | Authors |
| CyberGym | GPT-5 (newer harness) | 81.8 | Authors |
| SEC-bench (PoC) | Opus 4.6 | 27.2 | Leaderboard |
| SEC-bench (PoC) | Codex + GPT-5.4 | 38.8 | Leaderboard |
| SEC-bench (Patch) | AgenticRepair + GPT-5.2 | 75 | Leaderboard |
| CVE-Bench | SOTA agent (paper) | ~13% | UIUC ICML paper |
| BountyBench (Exploit) | Claude 3.7 Thinking | 67.5 | Stanford paper |

For open-weight candidates in the sweep (Qwen3.6-27B, Qwen3.5-122B-A10B,
Qwen3-235B-A22B, DeepSeek-V4-Flash, and others), no public
CyberGym/SEC-bench/CVE-Bench numbers have been published. These runs
would be first-known results on those benchmarks.

---

## Storage and runtime budget

| Component | Disk |
|---|---|
| CyberGym binary mode (subset) | ~10–20 GB |
| CyberGym binary mode (full) | ~130 GB |
| CyberGym full compilation | ~10 TB (skip in memory-constrained environments) |
| SEC-bench harness containers | per-instance, ~tens of GB total |
| CVE-Bench (40 docker targets) | ~tens of GB |
| Total budget on the test node | plan ~150–200 GB |

Runtime cost is the bigger constraint and is the reason for the
profile-based ratchet above. Per-bench wall-time at ~14 tok/s sustained:

| Bench | Subset | Wall time |
|---|---|---|
| HumanEval+ | full 164 problems | 15–25 min |
| BigCodeBench-Hard | full 148 problems | 30–45 min |
| IFEval | full 541 prompts | 25–40 min |
| GPQA Diamond | 198 MCQ | 10–20 min |
| SWE-bench Verified-50 | 50 instances, agentic | 4–8 hr |
| CyberGym 10-task | 10 tasks, agentic | 6–10 hr |
| CyberGym full | 1,507 tasks, agentic | days–weeks |
| SEC-bench subset | ~50 instances, agentic | 6–12 hr |
| CVE-Bench full | 40 instances, agentic | 6–10 hr |
| Workload-native replay | 1 target, agentic | 4–8 hr |

Agentic budget per task is the dominant variance. A 30-turn agent on a
hard SWE-bench instance can spend 50K tokens; at 14 tok/s that's an hour
on a single problem. Cap turns/tokens conservatively when configuring
harnesses.

---

## Watch list (not yet ready, revisit periodically)

- **AIxCC turn-key artifacts** — DARPA's full CRS competition (August 2025)
  was the highest-fidelity vuln-research eval ever published. Trail of
  Bits / DARPA are releasing artifacts, but as of May 2026 there's no
  drop-in `pip install`. Re-check Q3 2026.
- **Project Naptime / Big Sleep** — Google's internal harness has the most
  real-world wins (20+ CVEs in 2025). Not a public benchmark and unlikely
  to become one. Track for context, not for running.
- **Cross-language realism** — the field is 90% C/C++. Coverage of Rust
  unsafe-block bugs, Go/Java/Python concurrency bugs, and OWASP-Top-10 on
  PHP/Node is thin. Watch for new releases.
- **Weaponization beyond crash** — nothing public grades whether a model
  produced a *control-flow-hijacking* exploit, only whether it tripped
  a sanitizer. Big Sleep does this internally; the field hasn't caught up.

## Excluded by design

These appear in the literature but are not in the standard battery, and
why:

- **CTF benchmarks** (NYU CTF Bench, Cybench, XBOW) — synthetic challenges,
  not the threat model we care about.
- **BigVul / CrossVul / DiverseVul** — older training datasets repurposed
  as benchmarks; heavy contamination, classification-only.
- **PrimeVul, SecVulEval** — useful as smoke tests for *classification*
  capability but neither requires PoC generation. Optional, not primary.
- **CyberSecEval 2/3 buffer-overflow / autocomplete-vuln** — CTF-flavored,
  user-excluded. AutoPatchBench (within CSE 4) is a real-bug eval and
  worth running as a Pool-B complement, not Pool-A.
- **A.S.E (Tencent AICGSecEval)** — defender-side (secure code generation),
  orthogonal axis. Track separately.
- **MMLU-Pro** — broad knowledge eval. Doesn't map to the vuln-research
  workload; trivia recall isn't the bottleneck on any model in this sweep.
  High token cost for low signal. Skip.
- **MATH-500** — math reasoning. Useful for math-tutor models, irrelevant
  to vuln research. Token-expensive (reasoning chains expand outputs).
  Skip.

---

## Sources

- CyberGym: <https://www.cybergym.io/> · [paper](https://arxiv.org/abs/2506.02548) · [GitHub][cybergym-gh] · [Berkeley RDI blog](https://rdi.berkeley.edu/blog/cybergym/)
- SEC-bench: [paper](https://arxiv.org/abs/2506.11791) · [leaderboard][secbench] · [NeurIPS 2025 poster](https://neurips.cc/virtual/2025/poster/118134)
- CVE-Bench (UIUC): [paper](https://arxiv.org/abs/2503.17332) · [GitHub][cvebench]
- BountyBench: <https://bountybench.github.io/> · [paper](https://arxiv.org/abs/2505.15216)
- AutoPatchBench (Meta): <https://engineering.fb.com/2025/04/29/ai-research/autopatchbench-benchmark-ai-powered-security-fixes/>
- CyberSecEval 4 docs: <https://meta-llama.github.io/PurpleLlama/CyberSecEval/>
- PrimeVul: [paper](https://arxiv.org/abs/2403.18624) · [GitHub](https://github.com/DLVulDet/PrimeVul)
- SecVulEval: [paper](https://arxiv.org/abs/2505.19828)
- A.S.E: [paper](https://arxiv.org/abs/2508.18106) · [Tencent GitHub](https://github.com/Tencent/AICGSecEval)
- ARVO (substrate under AutoPatchBench/CyberGym): [paper](https://arxiv.org/abs/2408.02153)
- AIxCC: [DARPA results](https://www.darpa.mil/news/2025/aixcc-results) · [scoring guide](https://www.darpa.mil/news/2025/ai-cyber-challenge-scoring) · [Trail of Bits Buttercup post-mortem](https://blog.trailofbits.com/2025/08/09/trail-of-bits-buttercup-wins-2nd-place-in-aixcc-challenge/)
- Project Naptime: <https://projectzero.google/2024/06/project-naptime.html> · [Big Sleep / SQLite finding](https://projectzero.google/2024/10/from-naptime-to-big-sleep.html)
- Anthropic Opus 4.5/4.6/4.7 system cards (CyberGym scores cited above)
- lm-evaluation-harness: <https://github.com/EleutherAI/lm-evaluation-harness>

[lm-eval]: https://github.com/EleutherAI/lm-evaluation-harness
[cybergym-gh]: https://github.com/sunblaze-ucb/cybergym
[secbench]: https://sec-bench.github.io/
[cvebench]: https://github.com/uiuc-kang-lab/cve-bench
