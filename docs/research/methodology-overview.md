# Methodology Overview

> This page explains how the [results board](../board/index.html) is built —
> what each score means, how it was produced, and where the numbers are and
> aren't comparable across models. For the full benchmark catalog (task
> counts, run profiles, wall-time budgets), see [eval-battery.md](../eval-battery.md).

---

## The two pools at a glance

Every column on the board belongs to one of two pools.

**Pool B — single-pass code quality.** The model gets a prompt and must
produce a correct, self-contained answer in one shot. HumanEval+,
BigCodeBench-Hard, and IFEval all work this way. Scores are measured as
pass@1: the fraction of tasks where the first (and only) attempt is
correct. These benchmarks are cheap to run (~20–45 minutes each) and
well-established — nearly every published model card reports them, so
comparisons across labs are reasonably meaningful.

**Pool A — agentic vulnerability research.** The model operates as an
autonomous agent over many turns: reading source code, writing exploit
code, running it against a live target, and observing whether it triggered
a vulnerability. CyberGym, SEC-bench, and CVE-Bench are all in this pool.
Scores reflect whether the agent actually produced a working proof-of-concept
(PoC) or patch — not whether its reasoning sounded plausible. These runs
take hours to days per model, and results are not directly comparable
across labs because the agent scaffold and turn budget matter.

Pool A is the primary axis of this project. Pool B numbers serve as a
control: if a model scores near zero on CyberGym but strong on HumanEval+,
the gap is almost certainly a capability-level issue, not a deployment
problem.

---

## How scores are produced

### Pool B

All Pool B benchmarks run through
[lm-evaluation-harness](https://github.com/EleutherAI/lm-evaluation-harness)
pointed at the model's OpenAI-compatible endpoint. Decoding is greedy
(temperature 0, single sample). The reported metric matches each
benchmark's canonical definition:

- **HumanEval+**: pass@1 using the EvalPlus extended test suite
- **IFEval**: prompt-level strict accuracy (every instruction in the prompt
  must be followed exactly)
- **BigCodeBench-Hard**: calibrated pass@1 on the Instruct split

### Pool A

Each Pool A benchmark runs through its own harness, which launches a
containerized target environment and gives the agent a multi-turn loop to
attack it:

- **CyberGym**: the agent works through the OpenHands framework with up to
  100 turns. A run passes if the agent's PoC reproduces the expected
  sanitizer crash on the target binary.
- **CVE-Bench**: the agent uses an Inspect AI + ReAct loop with up to 30
  turns (the benchmark authors' specified budget). A run passes if the
  agent's exploit is confirmed by the evaluator running it against the live
  container stack.
- **SEC-bench**: the agent uses a smolagents loop with up to 30 turns — a
  project default, not an authors' budget (the SEC-bench authors don't pin a
  turn count, unlike CVE-Bench above). A run passes if the PoC triggers a
  memory-safety sanitizer on the vulnerable build but not on the patched
  build (differential grading).

None of the Pool A benchmarks use an LLM judge. Grading is deterministic:
either the sanitizer fired, or it didn't; either the exploit connected, or
it didn't.

---

## What "canonical condition" means

For each benchmark, the authors have an intended reference protocol —
the specific settings under which published numbers were measured. The
board tracks whether each measurement matches that protocol.

A measurement that matches the authors' protocol on every relevant axis
is called **canonical** and shown without markers. A measurement that
deviates on one or more axes is shown with a small superscript marker per
deviation — for example, `ᵗ` for thinking-off when the board is displaying
a run where extended reasoning was disabled.

**What counts as an axis:**

- *thinking* — whether the model's extended chain-of-thought reasoning was
  enabled
- *max_turns* — the agent turn budget for Pool A runs
- *harness* — stock upstream harness vs. a patched variant
- *quant* — the quantization level used for serving

**Per-benchmark canonical protocols:**

- *HumanEval+, IFEval, BigCodeBench-Hard*: the benchmark authors wrote
  these before reasoning-capable models existed, so they say nothing about
  whether thinking should be on or off. That axis is unpinned — running
  with or without extended reasoning is neither canonical nor a deviation
  by the authors' standards. The `ᵗ` marker, when it appears on Pool B
  rows, is a factual label ("this run used thinking-off") rather than a
  claim that it diverges from what the authors intended.
- *CVE-Bench*: the authors specify 30 turns. Runs at 30 turns are
  canonical; any other budget is a deviation.
- *CyberGym*: the authors' documentation is ambiguous between 10 and 100
  turns at different points. The board uses 100 turns as the working
  canonical, and notes the ambiguity per cell.
- *SEC-bench*: the authors do not specify a turn budget or agent framework.
  All cells in the board use a smolagents scaffold, which differs from the
  OpenHands / SWE-agent / Aider scaffolds the paper authors used — meaning
  all SEC-bench cells are cross-harness and not directly comparable to
  leaderboard baselines. See the section on SEC-bench below.

---

## The thinking-on / thinking-off distinction

Modern reasoning models can run in two modes: standard mode (a direct
answer) and extended-thinking mode (a long chain of reasoning before the
answer). The two modes can produce different scores on the same benchmark.

For Pool A runs, thinking is typically left on for models that support it —
that is the more capable mode, and the task is hard enough to benefit from
it.

For Pool B runs, thinking is disabled for open-weight models. Why? Several
of the Pool B benchmarks involve strict output-format constraints (IFEval
requires exact formatting; BCB requires the harness to parse the response).
Thinking mode sometimes breaks these constraints, producing lower scores
despite more reasoning — a harness incompatibility, not a capability drop.
Frontier models on the board have thinking enabled where natively supported.

This asymmetry is marked clearly: rows with thinking disabled carry `ᵗ`.
The board also offers a thinking-uplift view showing the delta between
on and off where both have been measured.

---

## How SEC-bench results are reported

SEC-bench is the trickiest benchmark in the set for comparability, and it
deserves a plain explanation.

The benchmark authors used three agent frameworks (OpenHands, SWE-agent,
Aider) in their published results. We run all open-weight models through a
smolagents framework instead, because it is more practical to operate at
scale. That means our numbers are not directly comparable to the leaderboard.
We report them anyway because the grading criterion is identical (did the
PoC trigger the sanitizer?), and they are the first published smolagents-harness
results for these models.

Additionally, we identified three issues in the stock smolagents harness
that caused agents to fail not because their reasoning was wrong, but
because the framework blocked them from expressing their solution:

1. The Python sandbox blocked standard binary-encoding libraries
   (`struct`, `base64`, `binascii`), which are needed to construct binary
   PoC payloads. Shell access was already available, so this restriction
   served no purpose.
2. The final-answer tool accepted free-form text, so agents sometimes
   submitted prose instead of a file path, and the harness silently
   discarded their work.
3. Agents had no way to check whether their PoC actually triggered the
   sanitizer before submitting — equivalent to a pen-tester who can't
   test their exploit.

We patched all three and report two numbers for SEC-bench: **stock**
(unmodified smolagents, comparable to anyone who runs the harness as-is)
and **patched** (with fixes applied). The patched score is our primary
number, with the stock score shown alongside so the effect of the fixes
is transparent.

These fixes do not change what counts as a pass. They remove framework
limitations that prevented agents from expressing correct solutions.
The benchmark's grading criterion — does the PoC trigger the sanitizer?
— is unchanged.

---

## Audit and replay verification

Each measured cell on the board carries an audit state. "Replay-verified"
means the run result has been cross-checked: the grading artifacts (sanitizer
output, exploit connection log, or harness verdict file) have been replayed
against the stored inputs to confirm the score was not a fluke of timing or
environment.

Results are stored in a results bucket and associated with a campaign
identifier, so any cell can be traced back to the exact run that produced it.

---

## Honest limitations

**Not all numbers are cross-comparable.** The main sources of
incomparability:

- *Harness divergence on SEC-bench.* As described above, all our SEC-bench
  cells use a different agent framework than the leaderboard baselines.
- *Quantization.* Published frontier scores (from Anthropic and OpenAI
  system cards) are typically measured on full-precision or near-full-precision
  models. Open-weight models on this board run at reduced precision
  (typically FP8 or NVFP4), which costs a few percentage points. Where we
  have measured the same model at two quant levels, that delta is shown.
- *Small-N Pool A cells.* Some cells are measured on subsets (CyberGym
  10-task, SEC-bench 11- or 50-instance). Small samples have wide variance;
  treat these as screening estimates, not final numbers.
- *Cost-gated rows.* Some rows and benchmarks are marked TBD because the
  compute cost at the required settings (e.g., ExploitBench-14 requires
  300 turns per instance with images up to 70 GB each) is prohibitive for
  an open-weight sweep right now. Those cells will fill in as costs allow.
- *Contamination.* CVE-Bench's 40 CVEs are from May–Jun 2024, within
  training window for any model with a mid-2024 or later cutoff. CyberGym
  has a known pre/post-cutoff effect (GPT-4.1 dropped from 9.7% to 5.6%
  on post-cutoff instances). All scores are reported against the full set;
  where per-disclosure-date splits are available, they are noted.

**What these benchmarks do and don't measure.** All three Pool A benchmarks
grade by sanitizer trigger or exploit connection — they measure whether a
model can construct a working PoC, not whether it can weaponize that PoC
into an arbitrary-code-execution chain. That next step (full exploit
development, memory-layout control, sandbox escape) is measured by
ExploitBench-14 but that benchmark is not yet in the board's measured
columns. The current Pool A scores are best read as "can the model find
and express the vulnerability?" rather than "can it build a full exploit?"

---

## Further reading

- [Benchmark catalog and run profiles](../eval-battery.md) — full details
  on each benchmark, run profiles, wall-time estimates, and contamination
  handling
- [Canonical protocols per benchmark](benchmark-canonical-protocols.md) —
  the per-benchmark canonical condition decisions and the research behind
  them
