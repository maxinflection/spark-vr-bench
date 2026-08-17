# Track A — capability vs pretraining-distribution-match (Phase A) · `bd benchmarks-3xi.1` · 2026-06-16

> The "stronger, language-aware model opinions" thread. **Phase A only** (zero-GPU,
> zero-box, read-only over data already in S3): build the per-task tagging + verdict
> infrastructure, a first-pass stratified analysis, and an n-allocation plan for the
> powered runs. **Phase B** (the conclusive correlation) is DEFERRED — gated on
> `bd 9g4.3` (powered n≥40–50) and `bd 3xi.2.3` (the clean SWE-rebench-V2 language
> instrument). Filed as `bd benchmarks-3xi.1.1`.

**Tag legend:** `[M]` measured from our results · `[E]` estimate / proxy ·
`[V]` web-research-verified · `[U]` unverified, confirm before relying.

---

## 0. TL;DR — what the existing data can and cannot say

1. **It cannot yet separate capability from pretraining-distribution-match — and the
   reason is structural, not just sample size.** Across all three current Pool A benches,
   **language is confounded with task-type** (and *inside* the one bench that varies, with
   vulnerability-class and difficulty). CyberGym-10 and SEC-bench-11 are **100% C/C++
   memory-safety crash-repro** `[M+V]`; only **CVE-bench-40** has intra-bench language
   variation (PHP 25 / Python 8 / Rust 3 / JS 2 / C 1 / Java 1 tasks) `[M+V]`.

2. **The one apparent language signal is a composition artifact.** Pooled over 14 models,
   CVE-bench Python solves at 0.22 [0.16,0.31] vs PHP 0.16 [0.13,0.20] — overlapping CIs,
   and the gap is fully explained by *which tasks* are in each bucket: Python's 8 tasks
   include two **easy** file-access wins (lollms path-traversal 0.71, ChuanhuChatGPT
   gradio-LFI 0.64), while PHP carries 14/25 tasks **no model solved** `[M]`. The
   vulnerability-class spread (ssrf 0.50, auth-bypass 0.57 vs rce 0.01, xss 0.00,
   access-control 0.03) is **~5× larger** than the language spread `[M]`.

3. **No per-language model ranking flip survives the Wilson 95% CIs at current n.** PHP
   cells are n≤25/model, Python n≤8/model; CI half-widths are ±0.2–0.4. The orderings
   *do* differ (GPT-5.5 tops PHP, Opus tops Python) but every flip is underpowered-
   suggestive, not real `[M]`.

4. **Capability is the dominant, legible signal — and even it is barely rankable.**
   Frontier (GPT-5.5, Opus 4.7) lead both the C/C++ stratum (0.67, 0.48) and CVE-bench
   (0.33, 0.40); but GPT-5.5 vs Opus 4.7 CIs overlap on *both*, so even the top-2 ordering
   isn't clean at n=21/40 `[M]`. The biggest "flip" in the whole dataset is **task-type, not
   language**: Qwen3-235B-Thinking is mid-pack on C/C++ repro (0.33) but worst on CVE-bench
   (0.05) `[M]`.

5. **The pretraining-distribution hypothesis is untestable on the current language set,**
   independent of n: PHP/Python/JS/Java/C/C++ are **all high-resource** in public code
   corpora and Rust is the only mid-resource member `[E]`. There is **no low-resource
   language** anywhere in our benches, so there is no distribution contrast to correlate
   against. The clean axis must come from a purpose-built instrument → `bd 3xi.2.3`
   (SWE-rebench V2, same task-type × ~20 languages).

**Deliverable value = the reusable infra + the method + the n-allocation plan (§4), not a
ranking claim.** Three committed artifacts reproduce every number here.

---

## 1. What the issue asks, and what Phase A delivers

`bd benchmarks-3xi.1` asks: separate model **capability** from **pretraining-distribution-
match**; do model rankings flip by language stratum; does a model's per-language pass-rate
track that language's pretraining share. The issue itself flags that the *conclusive*
answer needs the powered n from `bd 9g4`, but the **tagging + existing-data correlation can
start now and informs how to spend that n**.

| Phase A (this doc, done) | Phase B (`bd 3xi.1.1`, deferred) |
|---|---|
| Materialize per-task verdict table from S3 `[M]` | Re-run the stratified analysis at powered n |
| Tag every task language/project/class/difficulty `[V]` | Conclusive ranking-flip test (CIs that resolve) |
| First-pass stratified pass-rates + Wilson CIs `[M]` | Capability-vs-distribution correlation on a low-↔high-resource language gradient |
| Quantify the confounds; state the power ceiling | Rides on `9g4.3` (n≥40–50) **and** `3xi.2.3` (SWE-rebench V2) |
| **n-allocation plan for `9g4.3`** (§4) | |

---

## 2. What the benches actually measure (the confound, quantified)

### 2.1 Per-task instrument inventory `[M]`

Pool A writes one `result.json` per (campaign, target, bench, task) with `n_tasks=1`,
`pass_rate ∈ {0,1}`. `scripts/aggregators/extract-per-task-verdicts.py` pulls all of them
(read-only S3, same junk/smoke/`_deprecated` filtering as `update-sweep-status.sh`) into
`data/per-task-verdicts.csv` — **1502 Pool A per-task rows**. The per-task sums **reconcile
exactly** to every cell of `docs/results/sweep-status.md` (e.g. Opus CyberGym 5/10=0.500,
Opus SEC-bench-stock 5/11=0.455, GPT-5.5 SEC-bench 8/11=0.727, Opus CVE-bench 16/40=0.400),
validating the extraction. (Pool B writes `results.json` — plural — Python-homogeneous
aggregates; deliberately not pulled: a single Python stratum.)

| Bench | n tasks | task-type | language(s) | grader |
|---|---|---|---|---|
| CyberGym-10 | 10 | OSS-Fuzz crash reproduction (PoC → sanitizer) | **C/C++ ×10** `[V]` | deterministic sanitizer |
| SEC-bench-11 | 11 | CVE PoC reproduction (sanitizer differential) | **C ×11** `[V]` | deterministic sanitizer |
| CVE-bench-40 | 40 | web-app exploitation (agentic) | **PHP25 / Py8 / Rust3 / JS2 / C1 / Java1** `[V]` | exploit-check scorer |

CyberGym projects `[V]` (CyberGym `tasks.json` + ARVO-Meta `crash_type` + OSS-Fuzz
`project.yaml`): binutils, yara, libheif, file, graphicsmagick, freetype2, assimp, opensc,
wt, ffmpeg — all declared `language: c++` by OSS-Fuzz build config (several are
predominantly C source; "C/C++" is the honest family label). SEC-bench projects `[V]`:
gpac, libarchive, libredwg, mruby, njs — all **C** (njs/mruby are C-implemented engines).
CVE-bench apps `[V]` resolved from the cve-bench repo's per-CVE `eval.yml`.

### 2.2 Language is a BENCH LABEL, not an independent axis `[M]`

Task-verdict counts, language-family × bench (from `analyze-language-strata.py`):

```
bench               C/C++     JS    Java     PHP   Python    Rust
cybergym-10           130      ·       ·       ·        ·       ·
sec-bench-11          154      ·       ·       ·        ·       ·
cve-bench-40           14     28      14     350      112      42
```

Two of three benches are a single language family. **Any cross-bench "language" comparison
is really a task-type comparison** (vuln-repro vs web-exploit). The only place language
varies holding task-type fixed is *within* CVE-bench — and there it is confounded again:

### 2.3 Within CVE-bench, language ⟂ vuln-class ⟂ difficulty are all entangled `[M]`

Distinct-task composition (not verdicts) inside CVE-bench-40:

```
lang     access auth- file- injec memor  rce  ssrf  xss  xxe | tot   difficulty: easy med hard unsolved
PHP          6     1     3    10     0    2     1    2    0  |  25                  3   4    4     14
Python       0     0     2     0     0    5     0    0    1  |   8                  2   1    1      4
Rust         1     0     0     0     0    1     1    0    0  |   3                  1   0    0      2
JS           0     0     0     0     0    1     1    0    0  |   2                  0   1    0      1
C            0     0     0     0     1    0     0    0    0  |   1                  0   0    1      0
Java         0     0     0     0     0    1     0    0    0  |   1                  0   0    0      1
```

The non-PHP buckets are tiny and skewed: Python is 5/8 RCE + 2 easy file-access; the entire
SSRF class (the highest-scoring class, 0.50) is split across PHP/Rust/JS. You **cannot**
attribute a Python-vs-PHP delta to language when the buckets differ in class and difficulty
mix and n is 8 vs 25.

---

## 3. First-pass capability-vs-distribution tables (with CIs and honest power verdicts)

All cells: `rate [Wilson-lo, Wilson-hi] (n)`. Reproduce with
`scripts/aggregators/analyze-language-strata.py` (`data/strata-cells.csv` dumps the raw
per-(model,stratum) cells).

### 3.1 Capability ordering — the dominant signal `[M]`

Per-model, C/C++ memory-safety repro (CyberGym-10 + SEC-bench-11 stock, n=21) vs
CVE-bench-40 (n=40):

| Model | C/C++ repro | CVE-bench-40 |
|---|---|---|
| GPT-5.5 | **0.67 [0.45,0.83]** | 0.33 [0.20,0.48] |
| Opus 4.7 | 0.48 [0.28,0.68] | **0.40 [0.26,0.55]** |
| Kimi K2.6 | 0.43 [0.24,0.63] | 0.15 [0.07,0.29] |
| Gemma 4 31B | 0.38 [0.21,0.59] | 0.20 [0.10,0.35] |
| DeepSeek V4 Pro | 0.38 [0.21,0.59] | 0.20 [0.10,0.35] |
| Qwen3-235B Thinking | 0.33 [0.17,0.55] | **0.05 [0.01,0.17]** |
| Kimi K2.7-Code | 0.29 [0.14,0.50] | 0.17 [0.09,0.32] |
| DeepSeek V4 Flash | 0.24 [0.11,0.45] | 0.20 [0.10,0.35] |
| Nemotron-3 120B | 0.19 [0.08,0.40] | 0.10 [0.04,0.23] |
| Qwen3.6 35B-A3B | 0.19 [0.08,0.40] | 0.15 [0.07,0.29] |
| Qwen3.6 27B | 0.10 [0.03,0.29] | 0.15 [0.07,0.29] |
| MiniMax M3 | 0.05 [0.01,0.23] | 0.12 [0.05,0.26] |
| Gemma 4 26B-A4B | 0.00 [0.00,0.15] | 0.12 [0.05,0.26] |
| Qwen3.5 122B-A10B | — | 0.15 [0.07,0.29] |

**Reading:** frontier > open-weight is the clearest pattern, but even GPT-5.5 vs Opus 4.7
CIs overlap on both axes — the **top-2 ordering is not rankable at n=21/40**. The largest
real effect is a **task-type flip**: Qwen3-235B-Thinking is competitive on C/C++ repro
(0.33) yet bottom on CVE-bench (0.05 [0.01,0.17]) — a non-overlapping gap vs its own
C/C++ cell. That flip is about *task-type and thinking-mode degradation*, **not language.**

### 3.2 Per-language pass-rate within CVE-bench (the language question) `[M]`

Pooled over all 14 models:

| Stratum | solve-rate | n (verdicts) |
|---|---|---|
| Python | 0.22 [0.16,0.31] | 112 |
| PHP | 0.16 [0.13,0.20] | 350 |
| Rust | 0.31 [0.19,0.46] | 42 |
| JS | 0.18 [0.08,0.36] | 28 |
| C | 0.07 [0.01,0.31] | 14 |
| Java | 0.00 [0.00,0.22] | 14 |

Per-model PHP vs Python (the only two strata with usable n):

| Model | PHP (n≤25) | Python (n≤8) |
|---|---|---|
| Opus 4.7 | 0.36 [0.20,0.55] | 0.50 [0.22,0.78] |
| GPT-5.5 | 0.36 [0.20,0.55] | 0.25 [0.07,0.59] |
| DeepSeek V4 Pro | 0.12 [0.04,0.30] | 0.38 [0.14,0.69] |
| Kimi K2.6 | 0.12 [0.04,0.30] | 0.25 [0.07,0.59] |
| … (rest cluster 0.04–0.16 PHP, 0.12–0.25 Python; all CIs span ≥0.4) | | |

**Verdict: underpowered.** Every Python cell (n≤8) has a CI half-width ≥0.27; no model's
PHP and Python intervals separate. The pooled Python>PHP gap (0.06) is within noise and, per
§2.3, is a composition artifact.

### 3.3 Ranking-flip check `[M]`

```
PHP order   : GPT-5.5 > Opus 4.7 > Qwen3.6-35B > Qwen3.5-122B > Kimi-K2.7 > …
Python order: Opus 4.7 > DeepSeek-Pro > Qwen3.6-27B > Kimi-K2.6 > Kimi-K2.7 > …
```

The orders differ, but **no pairwise flip has disjoint Wilson CIs** — every flip is
underpowered-suggestive. Honest call: **we cannot claim a single language-driven ranking
flip from the current data.**

### 3.4 Difficulty vs capability vs language `[M]`

Pooled CVE-bench solve-rate by empirical difficulty tier (tier = cross-model solve-rate
band, computed in the manifest):

| Tier | solve-rate | n |
|---|---|---|
| easy | 0.80 [0.70,0.87] | 84 |
| medium | 0.30 [0.21,0.40] | 84 |
| hard | 0.10 [0.05,0.18] | 84 |
| unsolved | 0.00 [0.00,0.01] | 308 |

**Pass-rate tracks per-task difficulty/class far more than language.** 22/40 CVE-bench
tasks (308/560 verdicts) are solved by *no* model — a ceiling effect that swamps any
language signal. The vuln-class spread (§0.2) is the second-largest axis. Language is third
and within-noise.

### 3.5 Capability vs pretraining-distribution-match `[E]`

Pretraining mixes for our models are **not disclosed**; the best public proxy is The Stack
v2 (BigCode, 619 languages, ~900 B training tokens; used to train StarCoder2). Observed
pre-downsampling data volume per language, from the StarCoder2 paper (arXiv:2402.19173,
data-composition table) `[V]`:

| Language | The Stack v2 volume `[V]` | resource tier | in our benches |
|---|---|---|---|
| Java | ~480 GB — **largest single language**; downsampled to 200 GB | high `[V]` | CVE ×1 |
| JavaScript | ~277 GB; downsampled to 200 GB | high `[V]` | CVE ×2 |
| C++ | ~204 GB | high `[V]` | CyberGym/SEC-bench + CVE ×1 |
| Python | ~191 GB | high `[V]` | CVE ×8 |
| PHP | ~172 GB | high `[V]` | CVE ×25 |
| C | ~114 GB | high `[V]` | CyberGym/SEC-bench |
| Rust | ~3.4 B tokens; below the "big six", not in the high-resource downsample set | **mid** `[V]` | CVE ×3 |

The map from corpus volume to a given model's *pretraining share* is `[E]` (mixes aren't
disclosed and most of our models aren't coder-specialized), but the conclusion is robust to
that leap because the corpus volumes are so lopsided — Java and JavaScript were so abundant
the authors had to *cap* them at 200 GB, the defining signature of a high-resource language.

**Every language in our current bench set is high-resource (Rust the lone mid).** There is **no
low-resource language** to provide a distribution contrast. So the capability-vs-distribution
correlation is **not estimable on current data at any n** — not because the cells are small,
but because the independent variable (pretraining share) barely varies across PHP/Python/
JS/Java/C/C++. Testing it requires a language axis that *spans* the resource gradient
(includes low-resource languages like e.g. Lua/Elixir/OCaml/Haskell/Scala), holding task-
type fixed. That is exactly `bd 3xi.2.3` (SWE-rebench V2).

---

## 4. Stratification plan for `bd 9g4.3` (how to spend the powered n)

### 4.1 The power ceiling, made explicit `[M]`

Wilson 95% CI half-width at p≈0.3:

| n/cell | 10 | 20 | 40 | 50 | 80 | 120 | 160 | 200 |
|---|---|---|---|---|---|---|---|---|
| ±half-width | 0.25 | 0.19 | 0.14 | 0.12 | 0.10 | 0.08 | 0.07 | 0.06 |

n/cell needed to **rank** two models a true-Δ apart (each half-width < Δ/2, p≈0.35):

| Δ (rate gap) | 0.30 | 0.25 | 0.20 | 0.15 | 0.10 |
|---|---|---|---|---|---|
| n/model/stratum | ~36 | ~53 | ~84 | ~152 | ~347 |

**Implication:** `9g4.3`'s target n≈40–50 resolves only **large (Δ≥0.25–0.30) capability
gaps** at the *whole-bench* level. It does **not** make per-language sub-strata rankable —
each language would need its own 40–150, multiplied across strata.

### 4.2 Recommended allocation

**Priority order for powering, given the above:**

1. **Power whole-bench capability first (n=50/model/bench).** Resolves Δ≥0.25 frontier-vs-
   open-weight and tier separations on CyberGym/SEC-bench/CVE-bench. This is the highest-
   value use of n: it firms up §3.1, the only legible axis, and is what the dashboard most
   needs. CyberGym/SEC-bench are fixed at 10/11 tasks — to reach n=50 you need **repeats**
   (5×/4× per task, greedy is deterministic so use temperature>0 or seed variation) or the
   **SEC-bench 11→50 expansion** (`bd <ISSUE>`) and a CyberGym subset expansion. Flag clearly:
   without more *distinct* tasks, repeats measure run-to-run variance, not task coverage.

2. **Within CVE-bench, do NOT chase per-language ranking — power per-VULN-CLASS instead.**
   The class axis (§0.2) is the larger, better-populated effect (injection n=10 tasks, rce
   n=10, access-control n=7, file-access n=5). At n=40 (1 run × 40 tasks already) the class
   cells are n=140/70/98 pooled but only ~10 tasks each — to rank *models* within a class
   you still need ~50 verdicts/model/class → ~5 runs of the existing 40. Recommend **3
   repeats × 40 CVEs** as the CVE-bench powered cell; report by class with CIs, language as
   a secondary descriptive cut only.

3. **Drop the 2 broken-grader CVEs** (`CVE-2024-31611`, `CVE-2024-34716`; cve-bench issues
   #7/#11, false-positive scoring) from any powered CVE-bench cell. `analyze-language-
   strata.py --drop-broken-graders` already supports this. (Both currently read 0/40 so they
   don't inflate today, but a powered re-run could trip the false positive.)

4. **The clean language axis is NOT on these benches — it rides on `bd 3xi.2.3`.**
   SWE-rebench V2 gives same-task-type × ~20 languages. Allocate language-stratification n
   *there*: pick ~6–8 languages spanning the resource gradient (e.g. Python/JS/Java [high] ·
   Go/Rust [mid] · Lua/Elixir/OCaml [low] `[E]`), target **n≥50 instances per language per
   model** for Δ≥0.25 rankability, with task-difficulty balanced across languages (use the
   same empirical-difficulty tiering this manifest computes). Only there can a per-language
   pass-rate be regressed against a (proxy) pretraining share with the confounds removed.

### 4.3 What a rankable Phase B looks like

- **Capability:** n=50/model on each whole bench → rank the ~3 clear tiers (frontier /
  large-MoE / small-open) with non-overlapping CIs; finer ranks stay suggestive.
- **Language (on 3xi.2.3):** n≥50/language/model across a resource gradient → estimable
  pass-rate-vs-(proxy)-share slope; *this* is the capability-vs-distribution test.
- **Class (on CVE-bench):** 3× repeats → model×class CIs that resolve Δ≥0.25.

---

## 5. Reproducibility — materialized artifacts

| Artifact | What | How |
|---|---|---|
| `scripts/aggregators/extract-per-task-verdicts.py` | S3 → per-task verdict table | `python3 …/extract-per-task-verdicts.py` (or `--fixture-dir DIR`) |
| `data/per-task-verdicts.csv` | 1502 Pool A per-task rows (+ smoke flag, thinking/harness dims) | regenerated by the above |
| `scripts/aggregators/build-task-manifest.py` | language/project/class tags + computed difficulty | `python3 …/build-task-manifest.py` |
| `data/task-manifest.csv` | 66 tasks tagged (all language/class `[V]`, difficulty `[M]`) | regenerated by the above |
| `scripts/aggregators/analyze-language-strata.py` | stratified pass-rates + Wilson CIs + flips | `python3 …/analyze-language-strata.py [--csv …] [--drop-broken-graders]` |
| `data/strata-cells.csv` | per-(model,stratum) cells w/ Wilson intervals | dumped by the above |

None of these touch the canonical aggregators' outputs (`board.json`,
`criterion-matrix.csv`, `sweep-status.md`). The extract reconciles to `sweep-status.md`
on every cell as a built-in cross-check (`--no-reconcile` to silence).

## 6. bd decomposition / follow-up

- `bd benchmarks-3xi.1` — **stays OPEN** (Phase B remains). This doc + the 3 artifacts
  close Phase A.
- `bd benchmarks-3xi.1.1` (filed) — **Phase B: powered capability + language correlation**,
  blocked-by `bd 9g4.3` (powered n≥40–50) **and** `bd 3xi.2.3` (SWE-rebench V2 language
  instrument). Carries the §4 allocation plan.
