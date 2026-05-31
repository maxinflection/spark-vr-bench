# Board parity dry-run

Before the auto-publishing board goes live, this confirms the rewired
data-driven page (`docs/board/index.html`) renders the same numbers
as the trusted pre-rewire static page — fed a `board.json` built **by hand from
the static page's numbers**.

## Run the automated check

```bash
python3 tests/board/check-parity.py
```

It (1) assembles `tests/board/parity-board.json` from the curated registry
(`docs/board/board-meta.json`) + the static page's numbers, (2) validates it
against `docs/board/schema.json`, (3) replicates the page's
`selectMeasurement('canonical')` in Python and asserts every cell's headline
equals the static value, and (4) — when `node` is present — re-runs the check
using the **actual** `selectMeasurement` extracted verbatim from `index.html`
(`tests/board/parity-realjs.js`), so the page's real logic is exercised, not a
reimplementation. All 41 canonical cells match (Python + real-JS).

**The reference is independent (not circular).** The expected values come from
`tests/board/static-expected.json`, which is **machine-parsed from the real
pre-rewire page** (`git show 9f4737a^:docs/mockups/sweep-board.html`) — not from
the same table that builds `parity-board.json`. So a transcription error in the
build table fails the check against the authoritative parse rather than passing
vacuously. Regenerate the reference with
`python3 tests/board/check-parity.py --regen-expected`.

**Coverage boundaries.** This harness verifies the headline VALUES + the
SEC-bench stock/patched consolidation + the N/A cell. The discriminating
canonical-vs-deviation SELECTION (e.g. IFEval reporting the lower thinking-on
number as canonical over the higher thinking-off bandage) is exercised
separately by the <ISSUE> Chrome verification against `board.sample.json`; the
static page had only one number per cell, so it can't exercise it here.

## Final visual pass (human, in a browser)

The automated check covers the data + selection logic; the pixel/layout/charts
pass needs a browser (the rendering mechanism was already Chrome-verified in
<ISSUE> against `board.sample.json`):

```bash
cp tests/board/parity-board.json docs/board/parity-board.json
python3 -m http.server -d docs/board 8000
# open http://localhost:8000/index.html?data=parity-board.json
```

Confirm the table, spark-group dividers, drilldowns, popovers, and the charts
render; compare against the old static layout.

## Intended differences from the old static page (NOT regressions)

These are deliberate, locked in bd <ISSUE> / `docs/research/benchmark-canonical-protocols.md`:

1. **SEC-bench: two columns → one.** The static page had separate `SEC-bench
   (stock)` and `SEC-bench (patched)` columns. The board models this as a single
   `sec-bench` bench with a `harness` condition (`stock` / `<ISSUE>`); the canonical
   headline is the **stock** measurement and the patched number is in the cell's
   drilldown. (The markdown dashboard keeps two columns; that's expected — the
   board's condition model is the richer representation.)
2. **`ᵗ` marker dropped on Pool B code benches** (HumanEval+, IFEval, BCB-Hard).
   Their `canonical_condition` is omitted (the authors are silent on thinking),
   so thinking-off is a factual label, not a deviation — and the page only marks
   deviations-from-canonical. The static page marked all open-weight Pool B cells
   `ᵗ`; the board does not.
