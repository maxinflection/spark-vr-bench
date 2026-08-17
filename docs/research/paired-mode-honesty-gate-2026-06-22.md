# Paired-mode honesty gate — headline-eligibility design (2026-06-22)

> Reference doc for `bd <CAMPAIGN>.1` (headline-eligibility gate) and `bd <CAMPAIGN>`
> (source.json data contract / provenance fields).  Written for a future
> engineer or operator who needs to understand why certain cells on the board
> render as a single number while others render as a paired view with
> diagnostics.  Ground truth: `docs/board/schema.json` (machine-readable
> contract), `scripts/finalize-board.py` (gate implementation).

---

## 1. The problem / motivation

### Worked example — bd 2lh (Gemma-4 26B-A4B IFEval, thinking on)

The canonical motivating cell is Gemma-4 26B-A4B on IFEval with
`thinking=on`, campaign `2lh-gemma26a4b-poolb-thinkon`.  The as-run score
is **0.7116**.  The thinking-off companion cell for the same model × bench is
**0.889**.

A naive "higher-of-paired" collapse would publish **0.889** as the reported
number, annotated only as "thinking-off" (ᵗ marker).  A reader scanning the
table would conclude "turning thinking on hurts IFEval by ~18pp" — the
**opposite** of the true interpretation.  The 0.7116 is degraded not because
thinking is harmful, but because **140 of 541 responses (25.9%) truncated at
the 16K token budget** before yielding a parseable answer.  The gemma4
reasoning parser, on a `finish_reason=length` truncation, discards the
unclosed `<think>` block, so those 140 samples land as near-empty parsed
content (validated: `compute-truncation.py` detected 140/541 near-empty
`filtered_resps` — fewer than 5 characters of flattened content — exactly
matching the 25.9% figure in `bd 2lh`).

Arithmetically:

- **0.712** — as-run score; a **lower bound** (penalises all truncated items)
- **~0.958** — conditional-on-answering upper bound (excludes the 140
  truncated items from both numerator and denominator); not publishable
  directly because it is selection-biased
- **0.889** — thinking-off score; a different measurement, not a ceiling for
  the thinking-on cell

No single number is honest.  Publishing 0.889 as "the" result misleads.
Publishing 0.712 as a headline implies it is a clean result when it is not.

### Why the ᵗ marker alone was insufficient

Before `bd <CAMPAIGN>.1`, the pipeline used a `ᵗ` superscript to denote
"measured at thinking=off."  That marker served two unrelated purposes at
the same time:

1. **Deviation label** — the measurement deviates from some author-intended
   or project-preferred condition (cf. `benchmark-canonical-protocols.md`).
2. **Honesty warning** — the measurement is degraded by a known artifact and
   should not be read as a clean result.

Overloading one symbol for both meanings (discussed as the "bd ceq marker
ambiguity") made it impossible for a reader to distinguish "this is the
thinking-off number, here for comparison" from "this number has a known
quality problem."  Separately, the markdown aggregator's `latest_per_pair`
used a `pass_rate`-before-`completed_at` tiebreaker to publish the
higher-of-paired score — a code path with a documented SIGPIPE race (bd opy)
that the new pipeline retires entirely.

### Truncation taxonomy: loop vs overflow

Not all truncations are equal.  Two failure modes produce near-empty content
at budget exhaustion:

- **Budget overflow** (`overflow_rate`): the model is reasoning productively
  but runs out of token budget mid-thought.  More budget likely fixes it.
  Example: `bd <ISSUE>` documented a recoverable overflow case where increasing
  `max_tokens` raised the score.
- **Degenerate thinking loop** (`loop_rate`): the model enters a repetitive
  or circular reasoning trace that never converges.  More budget does NOT fix
  it; the model just loops longer.  Example: MiniMax M3 exhibited degenerate
  loop behaviour on several Pool B cells (documented in `bd minimax-m3`
  context).

For the 26B/31B `2lh` cells, this split **cannot be recovered retroactively**
because the gemma4 parser discards the raw `<think>` content before
`result.json` is written.  `loop_rate` and `overflow_rate` are therefore
`null` for those cells — "unclassified truncation."  Only future harness
runs that preserve the pre-parser completion can populate both fields.

---

## 2. The gate rule — exact implementation

The gate is implemented as the `gate()` function in
`scripts/finalize-board.py` (lines 132–166).  It takes the canonical
measurement for a cell (or `None` if nothing is measured) and returns
`(headline_eligible: bool, headline_reason: str)`.

**Two conditions must BOTH hold for `headline_eligible=True`:**

### Condition 1: ROBUST

```python
ROBUST_MAX = 0.02  # 2%

robust = (trunc is None or trunc < ROBUST_MAX) and (nullr is None or nullr < ROBUST_MAX)
```

The reported (canonical-or-closest) measurement's `truncation_rate` AND
`null_rate` must each be below 2%.  A `null` rate is treated as "not
measured / unknown" and passes the threshold (benefit of doubt).  Any rate
at or above 2% fails.

If not robust:
- `truncation_rate >= ROBUST_MAX` and `thinking=on` → reason `thinking-on-truncation`
- `truncation_rate >= ROBUST_MAX` and other → reason `reported-truncation`
- `null_rate >= ROBUST_MAX` (not truncation) → reason `null-content`

### Condition 2: UNAMBIGUOUS MODE

Once robust is satisfied, the gate checks whether the reported mode is
unambiguous — i.e. there is no reasonable alternative-mode result that could
mislead a reader into a wrong comparative conclusion:

```
if model.frontier:          → eligible, reason "frontier-single-mode"
if model.thinking_only:     → eligible, reason "thinking-only-single-mode"
if bench.pool == "A":       → eligible, reason "pool-a-single-mode"

# open-weight Pool B:
modes = {thinking-dim value for all measured measurements}
if len(modes) >= 2:         → eligible, reason "paired-clean"
if reported_mode == "off":  → eligible, reason "single-mode-off-clean"
else:                       → NOT eligible, reason "single-on-unpaired"
```

**Eligible by construction:**
- Frontier API models (Opus, GPT) — single-mode-by-design, no open-weight
  budget constraint.
- `thinking_only` models (e.g. Qwen3-235B-Thinking) — running off mode
  produces floor scores; single mode is not a choice.
- Pool A cells — agentic multi-turn runs do not have a thinking-pair problem
  (though they may be ineligible via the `loop_cells` registry below).

**Ineligible by construction:**
- Open-weight Pool B thinking-on runs under a fixed token budget (the 26B and
  31B models at 16K), if no off-mode companion exists or if the reported mode
  fails robustness.
- Pool A cells registered in `board-meta.json`'s `loop_cells[]` list
  (analysis-paralysis / loop-detected cells) → reason `pool-a-loop`,
  `headline_eligible=False` regardless of robustness.

### Early exits

Before robustness is checked, two conditions short-circuit:

```python
if canonical is None:
    return False, "no-measured"   # nothing in the cell

if cell in loop_cells:
    return False, "pool-a-loop"   # registered analysis-paralysis cell
```

### Complete `headline_reason` slug vocabulary

| Slug | Meaning |
|---|---|
| `no-measured` | Cell has no `status=measured` measurement at all |
| `pool-a-loop` | Cell is in the `loop_cells` registry (Pool A analysis-paralysis) |
| `thinking-on-truncation` | `truncation_rate >= 0.02`, thinking=on (the 2lh pattern) |
| `reported-truncation` | `truncation_rate >= 0.02`, thinking=off or unspecified |
| `null-content` | `null_rate >= 0.02` (BCB none-filter, harness parsing failure) |
| `frontier-single-mode` | Model is `frontier=true`; single mode by design |
| `thinking-only-single-mode` | Model is `thinking_only=true`; off mode not run |
| `pool-a-single-mode` | Pool A cell, robust, no paired-mode ambiguity |
| `paired-clean` | Both thinking modes measured, reported mode robust |
| `single-mode-off-clean` | Only off mode measured, robust |
| `single-on-unpaired` | Only on mode measured, robust, but no off companion — ambiguous |

---

## 3. Vocabulary discipline

The following terms have precise meanings in this project and must not be
used interchangeably:

**CANONICAL** — the measurement (or condition) that matches the benchmark
**authors'** intended reference protocol, as declared in
`benches[].canonical_condition` (see `docs/research/benchmark-canonical-protocols.md`
for the per-bench decisions).  For all three Pool B benches (HumanEval+,
IFEval, BCB-Hard), the authors predate reasoning models and do not pin the
thinking axis — `canonical_condition` is therefore omitted, and the thinking
axis is unpinned.  Canonical is **not** "higher-of-paired" and is **not**
necessarily the displayed cell.

The flag `measurement.canonical=True` is set by `annotate_canonical_superseded()`
in `finalize-board.py` and identifies the single measurement selected as
this cell's headline — the one matching `canonical_condition` on every pinned
dimension, or the closest-to-canonical by the ranking: (1) fewest deviating
axes, (2) highest `n`, (3) latest `completed_at`.

**as-run** — a lens over the data; the score as actually measured under the
run conditions, without adjustment.  For a truncated cell, this is a lower
bound.

**conditional / upper bound** — a lens; the score recomputed over the subset
of samples that produced non-truncated responses.  Not a publishable headline
(selection bias), but useful for bounding the true capability.

**higher-of / max** — a lens; the maximum value over all measured conditions
in a cell, labelled as a ceiling.  The schema documents this as a valid
consumer-side view but explicitly notes it is NOT cross-comparable when
different conditions achieved different model highs.  The old markdown
pipeline's `pass_rate`-tiebreaker collapse to higher-of is **retired** by
`bd <CAMPAIGN>.1`.

**uplift** — a lens; the delta between two conditions (e.g. thinking-on minus
thinking-off) measured against `condition_dims[dim].default` as the
reference.  Stored nowhere; derived at render time.

**SUPERSEDED** — a measurement flagged `superseded=True` by
`annotate_canonical_superseded()` because a later or larger run on the same
exact condition has replaced it.  Retained in the data for journey visibility
rather than silently dropped.

See also: the memory key `kimi-k26-canonical-vs-reported-2026-06-04` for the
specific case of Kimi K2.6 where the canonical condition and the reported
cell diverge, and `docs/research/benchmark-canonical-protocols.md` for the
full per-bench decisions.

---

## 4. Architecture — pipeline and the single source of truth

`docs/board/board.json` is the **single source of truth** for the published
dashboard.  Every rendered view reads from it; nothing re-aggregates S3
independently:

- `docs/board/index.html` (sweep-explorer) — fetches `board.json`, hydrates
  the interactive table and charts
- `docs/results/sweep-status.md` — regenerated by
  `scripts/render-sweep-status.py` reading `board.json`
- `docs/board/criterion-matrix.html` — renders from `board.json`

### Pipeline stages

```
update-sweep-status.sh --emit-json
    ↓
compute-truncation.py
    ↓
finalize-board.py
    ↓
validate-board-json.py   (schema conformance check)
    ↓
board.json (published)
```

**Stage 1 — `update-sweep-status.sh --emit-json` (the jq emitter)**

The `emit_board_json()` function in `update-sweep-status.sh` (lines 404–534)
performs a bulk S3 fetch of all `result.json` / `results.json` files, applies
the `aggregate_per_campaign` grouping (summing per-task Pool A records into
per-campaign weighted pass rates), applies junk-campaign exclusions
(`BOARD_JUNK_CAMPAIGN_RE`), then joins the aggregated measurements onto the
curated `board-meta.json` registry.

The jq emitter sets per-measurement provenance fields introduced by
`bd <CAMPAIGN>`: `target` (runner target slug, e.g. `vllm`, `opus47-direct`),
`num_concurrent` (vLLM concurrency at run time), `tokens_out` (total output
tokens), and `null_rate` (BCB none-filter rate from
`extra.bcb_none_filter.null_rate`).

The emitter deliberately **does NOT set** `truncation_rate`, `loop_rate`,
`overflow_rate`, `canonical`, `superseded`, `headline_eligible`, or
`headline_reason` — those require cross-measurement reasoning or S3 log
access that jq cannot cheaply do.  They are left to the Python finalize pass.

Thinking condition inference (in the jq, lines 459–465): the emitter prefers
`extra.enable_thinking` if present; falls back to a campaign-name regex
(`-think(ing)?-?on(-|$)` / `-think(ing)?-?off(-|$)`); then to the bench's
`emit.default_condition.thinking`; then to `thinking=on` for frontier/
thinking-only models and `thinking=off` for all other open-weight models.

**Stage 2 — `compute-truncation.py`**

For each `(campaign, target, bench_id)` tuple that references a Pool B
lm-eval bench (`humaneval-plus` or `ifeval`), fetches the
`samples_<task>_*.jsonl` file from S3 under
`<campaign>/<target>/<bench>/lm-eval-raw/` and counts responses where the
flattened `filtered_resps` text is shorter than 5 characters
(`EMPTY_THRESHOLD = 5`).  Returns `(n_truncated, n_total)` and emits a rate
to `data/truncation-cache.json` keyed as `<campaign>|<target>|<bench_id>`.

BCB-Hard truncation is **not** computed here — it is already present in the
emitter output as `null_rate` from `extra.bcb_none_filter.null_rate`.
`finalize-board.py` copies it to `truncation_rate` for BCB cells directly
(line 119: `rate = m.get("null_rate")`).

The cache is idempotent and incremental: existing keys are not re-fetched
unless `--refresh` is passed.

**Stage 3 — `finalize-board.py`**

Reads the raw `board.json` from Stage 1, the truncation cache from Stage 2,
and `board-meta.json`, then writes back to `board.json` (in-place by
default).  Four operations:

1. **Truncation application** (`apply_truncation()`): for lm-eval cells,
   looks up `<campaign>|<target>|<bench_id>` in the cache and sets
   `measurement.truncation_rate`.  For BCB, copies `null_rate` to
   `truncation_rate`.  When a non-zero truncation rate is set, also emits
   `loop_rate=null` and `overflow_rate=null` (unclassified; retroactively
   unrecoverable for the 26B/31B cells).

2. **Canonical / superseded annotation** (`annotate_canonical_superseded()`):
   within each cell, groups `status=measured` measurements by exact condition
   key (JSON-sorted), marks non-best same-condition entries `superseded=True`,
   then selects the canonical measurement (fewest deviating axes from
   `benches[].canonical_condition`, then highest `n`, then latest
   `completed_at`) and sets `canonical=True` on it.  Exactly one `canonical`
   flag per cell when any measured measurement exists.

3. **Headline-eligibility gate** (`gate()`): described in detail in Section 2
   above.  Sets `score.headline_eligible` and `score.headline_reason`.

4. **Footnote registry passthrough**: attaches the verbatim `footnotes[]`
   registry from `board-meta.json` to the output, and joins per-cell
   `footnote_ids` from `board-meta.json`'s `cell_footnotes[]` list onto each
   `score.footnote_ids`.  Footnote ids follow the `note-<bd-id-or-slug>`
   convention (e.g. `note-ga2`, `note-b9i-cvp`).

### The source.json schema contract

The machine-readable contract is `docs/board/schema.json` (v1.1).  Key
shapes:

**Top level**

| Field | Type | Description |
|---|---|---|
| `schema_version` | string | Semver, bump major on breaking changes |
| `generated_at` | datetime | UTC timestamp of last aggregation |
| `condition_dims` | object | Registry of condition axes (thinking, harness, max_turns, …) with `default` values |
| `models` | array | Model registry — id, name, `frontier`, `thinking_only`, `spark_group`, `rank` |
| `benches` | array | Bench registry — id, pool, `canonical_condition`, `value_kind` |
| `scores` | array | One entry per (model, bench) cell |
| `footnotes` | array | Verbatim footnote registry; stable `id` anchors |

**Score (one cell)**

| Field | Type | Description |
|---|---|---|
| `model_id` | string | |
| `bench_id` | string | |
| `measurements` | array | All measured conditions for this cell |
| `headline_eligible` | boolean | Gate output: may render as one clean number |
| `headline_reason` | string | Gate slug (see vocabulary table in Section 2) |
| `footnote_ids` | array | Cell-wide footnote anchors |

**Measurement (one condition within a cell)**

| Field | Type | Description |
|---|---|---|
| `condition` | object | dim→value map (only pinned dims) |
| `value` | number\|null | Score (0..1 for ratio benches) |
| `n` | integer | Sample/task count |
| `status` | enum | `measured` / `tbd` / `na` / `smoke` |
| `campaign` | string | Source campaign id (provenance) |
| `target` | string | Runner target slug (<CAMPAIGN>) |
| `completed_at` | datetime | |
| `canonical` | boolean | Aggregator-selected headline measurement for this cell |
| `superseded` | boolean | This run was outranked by a later same-condition run |
| `truncation_rate` | number\|null | Fraction of generations that produced near-empty content |
| `null_rate` | number\|null | BCB none-filter null rate (coincides with truncation_rate for BCB) |
| `loop_rate` | number\|null | Of truncations: fraction classified as degenerate loops (null = unclassified) |
| `overflow_rate` | number\|null | Of truncations: fraction classified as productive budget overflow (null = unclassified) |
| `num_concurrent` | integer\|null | vLLM concurrency at run time (<CAMPAIGN>) |
| `tokens_out` | integer\|null | Total output tokens for this measurement (<CAMPAIGN>) |
| `footnote_ids` | array | Measurement-level footnote anchors |

---

## 5. What was retired

### Higher-of-paired collapse

The old markdown aggregator's `latest_per_pair()` used a sort key of
`[n_tasks, pass_rate, completed_at]` — the `pass_rate`-before-`completed_at`
ordering was an intentional "publish the higher of paired modes" policy (see
inline comments in `update-sweep-status.sh` lines 224–231).  This policy is
**retired** by `bd <CAMPAIGN>.1`.

The new pipeline retains ALL measurements in `board.json`'s `measurements[]`
array.  The `canonical` flag identifies the benchmark-authors'-intended
headline, not the maximum.  Higher-of is still available as a consumer-side
lens (take `max(value)` over `status=measured` rows) but is no longer the
default published view and is explicitly documented in `schema.json` as not
cross-comparable when different conditions achieved different model highs.

### The overloaded ᵗ marker

The old markdown path attached a `ᵗ` superscript in two logically distinct
cases:

1. The measurement uses `thinking=off` as a deviation from a project display
   preference (label function).
2. The measurement is degraded by truncation or another quality issue (warning
   function).

This conflation was tracked as "bd ceq marker ambiguity."  The new schema
separates the concerns cleanly:

- Condition deviations are encoded structurally in `measurement.condition`
  and in the `canonical` flag with its `deviating_axes` count.  Renderers
  derive deviation markers per-axis from first principles; no hardcoded marker
  list.
- Quality problems are communicated via `headline_eligible=False` and the
  `headline_reason` slug, plus the `truncation_rate` / `null_rate` /
  `loop_rate` / `overflow_rate` diagnostic fields.

A secondary technical issue: the old ᵗ lookup used a hardcoded
`THINKING_OFF_BANDAGED` list in `update-sweep-status.sh` (lines 329–371).
That list required manual updates as models were re-run paired, and was
subject to `model_id` prefix bugs (e.g. `bd <ISSUE>` documented a `Sehyo/` vs
`Qwen/` mismatch that caused the ᵗ marker to silently drop for Qwen3.5-122B).
The new approach has no such list.

The SIGPIPE-race code path mentioned as `bd opy` lived in the markdown
aggregation pipeline's compound `jq | awk` construction.  Retiring
`latest_per_pair` as the collapse mechanism eliminates that code path.

---

## 6. Retroactive limits on diagnostic fields

`truncation_rate` **is** retroactively computable for existing lm-eval cells
(humaneval-plus, ifeval), because:

- The per-sample `samples_<task>_*.jsonl` files are retained in S3 under
  `<campaign>/<target>/<bench>/lm-eval-raw/`.
- On a `finish_reason=length` truncation, the gemma4 reasoning parser
  discards the unclosed `<think>` block, leaving near-empty `filtered_resps`.
- The empty-content heuristic (`len(text.strip()) < 5`) correctly identifies
  these cases without access to `finish_reason` directly.
- Validated: the rate computed for `2lh-gemma26a4b-poolb-thinkon | vllm | ifeval`
  is 0.2588 (140/541), exactly matching `bd 2lh`'s 25.9% figure.

`loop_rate` and `overflow_rate` **cannot** be recovered retroactively for the
existing 26B / 31B cells from the `2lh` campaign family.  The raw completion
(the full `<think>...</think>` block before the reasoning parser runs) was
never written to S3 — only the parsed `filtered_resps` output survives.
Distinguishing a productive overrun from a degenerate loop requires access to
the raw think block for n-gram / repetition analysis.

Future harness work (`bd <CAMPAIGN>.1.1`) is to capture the pre-parser completion
in the sample logs so that `compute-truncation.py` can populate both fields
on new runs.  Until that lands, `loop_rate=null` and `overflow_rate=null`
mean "there is truncation, but the split is unclassified."

BCB-Hard does not have this problem: the BCB runner writes
`extra.bcb_none_filter.null_rate` into `result.json`, which the jq emitter
picks up directly.  BCB truncation is not a thinking-loop issue (BCB bypasses
litellm and uses server-side `enable_thinking=false`).

---

## Related resources

- `docs/board/schema.json` — machine-readable contract (v1.1)
- `scripts/finalize-board.py` — gate, canonical/superseded, footnote join
- `scripts/aggregators/compute-truncation.py` — retroactive truncation cache
- `scripts/update-sweep-status.sh` — raw board.json emitter (jq)
- `docs/research/benchmark-canonical-protocols.md` — per-bench canonical
  condition decisions
- `docs/research/methodology-overview.md` — operator-facing methodology prose
- `bd <CAMPAIGN>.1` — headline-eligibility gate issue
- `bd <CAMPAIGN>.1.1` — truncation diagnostic fields
- `bd <CAMPAIGN>` — provenance / source.json data contract
- `bd 2lh` — original Gemma-4 26B-A4B IFEval truncation discovery
- Memory: `kimi-k26-canonical-vs-reported-2026-06-04`
- Memory: `gemma-truncation-retroactively-computable-2026-06-22`
