# Benchmark canonical protocols — author intent vs. this project

> Source of truth for `benches[].canonical_condition` in the board (`docs/board/schema.json`)
> and for the `--emit-json` aggregator (`benchmarks-<ISSUE>`). "Canonical" = the benchmark
> **authors' intended reference protocol**, NOT this project's preferred display default.
> Where authors are silent on one of our condition axes, that axis is **unpinned** in
> `canonical_condition` — a house default may still drive display, but it is labeled as a
> house choice, never as canonical.
>
> Researched 2026-05-25 (bd <ISSUE>). Condition axes: `thinking`, `harness`, `quant`,
> `max_turns`, `context`, `wall_cap`.

## Pool B — single-pass code quality

For all three, authors pin **greedy / pass@1** (a *metric*, already in `bench.metric`, not a
condition axis) and say **nothing** about reasoning/thinking (all predate reasoning models).
→ **`canonical_condition` is omitted** (no condition axis is author-pinned). `max_turns`/`context`
are N/A (single-pass). The `ᵗ` marker stays a *factual* label of `thinking=off`, not a
claim of deviation-from-canonical.

| Bench | Metric (canonical) | n | Decoding | Thinking | House note |
|---|---|---|---|---|---|
| **HumanEval+** | plus pass@1, unbiased estimator | 164 | greedy, temp 0, n=1 | unspecified | run native; gen budget must fit think-block |
| **IFEval** | prompt-level **strict** accuracy | 541 | greedy, n=1 | unspecified | thinking-on can *lower* strict-acc (format violations) |
| **BCB-Hard** | **calibrated** pass@1, **Instruct** split | 148 | greedy, temp 0, n=1 | unspecified | server-side `enable_thinking=false` only path (BCB bypasses litellm) |

Citations: EvalPlus — Liu et al., NeurIPS 2023, arXiv:2305.01210 (§3–4). IFEval — Zhou et al.,
arXiv:2311.07911 (§2.2, Table 1). BigCodeBench — Zhuo et al., ICLR 2025, arXiv:2406.15877 (§3 + calibration appendix).

**Project agreement**: n, greedy/pass@1, Instruct-split, calibrated BCB all match `docs/eval-battery.md`.
**Action**: BCB-Hard currently has **no `benches[]` entry** in the board — add one (Instruct split, calibrated pass@1, `canonical_condition` omitted).

## Pool A — agentic vulnerability research

Here `max_turns` is the load-bearing canonical axis and it **differs per bench**. The scaffold
(OpenHands / smolagents / Inspect / native) is a *fixed property of how each bench is run*, not a
condition you sweep — do **not** fold it into the `harness` axis (which means stock-vs-<ISSUE> patch).

| Bench | Metric | n (full / project subset) | **Author max_turns** | Project max_turns | Scaffold (author) | Deviation to model |
|---|---|---|---|---|---|---|
| **CyberGym** | PoC reproduces sanitizer crash (no judge) | 1507 / 10 | **10 or 100 (upstream conflict)** | 100 | OpenHands | wall-time 7200s vs author 1200s; max_iter ambiguous |
| **SEC-bench** | differential sanitizer on patch | 300 / 11→50 | **unspecified** | 30 (smolagents) | SWE-agent/OpenHands/Aider | **harness=smolagents ≠ authors' scaffold → all cells cross-harness** |
| **CVE-Bench** | live exploit, 8-outcome `/done` oracle | 40 / ~10 | **30 (canonical)** | 30 ✓ | Inspect AI + ReAct | **none on budget — cleanest cell** |
| **ExploitBench-14** | 16-flag capability bitmap, ≥T1 | 41 / 14 | **300 (canonical)** | **100 (screening)** | native + LiteLLM + MCP | **100 → structurally all-zero (no `grade()` call); 300 REQUIRED for any published cell** |

Citations: CyberGym — Wang et al., arXiv:2506.02548, cybergym.io. SEC-bench — Li et al.,
NeurIPS 2025 D&B, arXiv:2506.11791. CVE-Bench — Zhu et al., ICML 2025, arXiv:2503.17332,
uiuc-kang-lab/cve-bench v2.1.0. ExploitBench — Lee & Brumley, CMU+Bugcrowd, arXiv:2605.14153, exploitbench.ai.

### ExploitBench vs ExploitGym — distinct companion benchmarks (both DEFERRED)

These are **two different papers**, not one (correcting an earlier research conflation):

- **ExploitBench-14** (arXiv:2605.14153) — capability-ladder *bitmap* (16 flags, T1–T5), V8-focused,
  14-bug subset. Canonical = **300 turns / ≥128K ctx**.
- **ExploitGym** (arXiv:2605.11086, "Can AI Agents Turn Security Vulnerabilities into Real Attacks?")
  — **pass/fail** exploitation at scale: **898 instances** across userspace, V8, and Linux kernel;
  agents extend a vuln-triggering input into a working exploit. Frontier reference: **Claude Mythos
  Preview = 157**, GPT-5.5 = 120 working exploits. Concurrent with ExploitBench.

**Both are deferred indefinitely.** The 300-turn (ExploitBench) / long-horizon (ExploitGym, 898
instances) budgets make wall-time on a rental GPU prohibitive — a full open-weight batch would take
far too long to be worth the rental burn right now. Consequence for the board: the ExploitBench-14
column stays **TBD** for the foreseeable future, and ExploitGym is not yet a board column at all.
Both are **acknowledged follow-on work** (the LinkedIn post frames them as "next, and the open-weight
results will likely be ~all-negative"), not near-term measurements. Do not block any board work on them.

**Recommended `canonical_condition`:**
- CyberGym → `{ "max_turns": "100" }` (matches documented CLI + current project; flag 10-vs-100 upstream ambiguity in the cell note).
- SEC-bench → **omit `max_turns`** (author unspecified); add a bench-level note that the project's smolagents scaffold is not the authors' — all cells are harness-divergent and not comparable to upstream baselines.
- CVE-Bench → `{ "max_turns": "30" }` (author default; project matches — the one no-deviation Pool A cell).
- ExploitBench-14 → `{ "max_turns": "300", "context": "128k" }` (author canonical). The current 100-turn screening data is a deviation **and** structurally zero — exclude it from the published canonical view; show it only under the deviation/screening view, clearly marked.

## Open decisions (need operator sign-off)

1. **House default for `thinking` on code benches** — authors are silent. Do we (a) leave the
   display tiebreak neutral (latest measured) and rely on the uplift toggle to show on/off, or
   (b) add a *clearly-labeled* `house_default` (thinking=on) that drives display + the `ᵗ` marker
   without claiming author authority? Recommend (a) for now; (b) is a cheap additive field later.
2. **Scaffold modeling** — promote scaffold (OpenHands/smolagents/Inspect/native) to a fixed
   `bench` attribute (recommended) rather than overloading the `harness` condition axis.
3. **SEC-bench comparability** — accept that current cells are cross-harness (label loudly), or
   stand up an OpenHands/SWE-agent run to get an author-canonical comparator.
4. **ExploitBench 100→300** — the published board should only carry 300-turn cells; the 100-turn
   screening runs are non-canonical and (per the spike) all-zero. Confirm we hold publication of
   ExploitBench cells until a 300-turn batch exists.
