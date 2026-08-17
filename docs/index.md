---
title: DGX-Spark Open-Weight Benchmarks
---

# DGX-Spark Open-Weight Benchmarks

Coding and vulnerability-research benchmarks for open-weight LLMs that
fit on one or two DGX Sparks — held alongside frontier models for
reference.

- **[Results board](board/)** — the live score grid (canonical /
  deviation-uplift / max view modes; click any cell for the per-run
  drill-down).
- **[Methodology overview](research/methodology-overview.html)** —
  plain-English deep dive: pools, canonical conditions, how scores
  are produced, audit + replay, honest limitations.
- **[Benchmark catalog](eval-battery.html)** — per-benchmark detail,
  run profiles, wall-time budgets, contamination handling.

Results are replay-verified — each board cell has a deterministic trace
tied back to the run that produced it.

The source for this site (and the benchmark tooling) is on
[GitHub](https://github.com/maxinflection/spark-vr-bench).
