# SEC-bench: vendor-published numbers? (2026-05-19)

Scope: did any frontier-model vendor (Anthropic, OpenAI, Google DeepMind,
NVIDIA, others) publish their *own* SEC-bench scores for Opus 4.7, Mythos,
GPT-5.5, Gemini 3.x, Gemma-4, Nemotron-3, or similar models? Compare to
our stock-smolagents measurements.

## 1. Top finding

**No frontier-model vendor has published its own SEC-bench numbers.**
The only published SEC-bench numbers come from the paper authors (Li et
al., arXiv 2506.11791, NeurIPS 2025 D&B). Searches of Anthropic system
cards (Opus 4.7, Mythos Preview), the OpenAI GPT-5.5 system card,
DeepMind's Gemini 3 / 3.1 Pro model cards, Sec-Gemini v1 launch, and
NVIDIA Nemotron-3 launch material returned **zero** SEC-bench mentions.
Vendors report on adjacent cyber benches instead — CyberGym, CVE-Bench,
CTF/cyber-range, CTI-MCQ, VulnLMP — never SEC-bench.

## 2. Vendor / source table

| Model | Source | Score | Harness | Subset | Date | URL |
|---|---|---|---|---|---|---|
| Claude 3.7 Sonnet | SEC-bench paper (authors) | PoC 12.5% / Patch 33.8% (best) | SWE-agent | 80-instance subset | Jun 2025 | huggingface.co/papers/2506.11791 |
| Claude 3.7 Sonnet | SEC-bench paper (authors) | PoC 18.0% / Patch 34.0% (best agent) | OpenHands | full 200 | Jun 2025 | arxiv.org/abs/2506.11791 |
| GPT-4o | SEC-bench paper (authors) | PoC 3.8% / Patch 26.2% (SWE-agent) | SWE-agent | 80-instance | Jun 2025 | huggingface.co/papers/2506.11791 |
| o3-mini | SEC-bench paper (authors) | PoC 10.0% / Patch 31.2% (SWE-agent) | SWE-agent | 80-instance | Jun 2025 | huggingface.co/papers/2506.11791 |
| Opus 4.7 | Anthropic system card | **not reported** (CyberGym 73.1% instead) | n/a | n/a | Apr 2026 | helpnetsecurity.com / allthings.how summaries |
| Mythos Preview | Anthropic system card | **not reported** (CyberGym 83.1%) | n/a | n/a | Apr 2026 | hugobowne.github.io/mythos-preview-model-card |
| GPT-5.5 | OpenAI system card | **not reported** (CTF 96%, CVE-Bench 93%, VulnLMP cited) | n/a | n/a | Apr 2026 | deploymentsafety.openai.com/gpt-5-5/cybersecurity |
| Gemini 3 / 3.1 Pro | DeepMind model card | **not reported** (FSF cyber: 11/12 v1 hard, 0/13 v2) | n/a | n/a | Dec 2025 / 2026 | storage.googleapis.com/deepmind-media/Model-Cards/Gemini-3-Pro-Model-Card.pdf |
| Sec-Gemini v1 | Google Security Blog | **not reported** (CTI-MCQ, CTI-RCM only) | n/a | n/a | Apr 2025 | security.googleblog.com/2025/04/google-launches-sec-gemini-v1-new.html |
| Nemotron-3 Super / Nano | NVIDIA launch + NeMo Evaluator recipe | **not reported** (PinchBench 85.6%, agentic-coding) | n/a | n/a | 2026 | huggingface.co/blog/nvidia/nemotron-3-nano-evaluation-recipe |

Independent third-party SEC-bench leaderboards: **none found.** No
re-runs on Vellum, Vals AI, Artificial Analysis, Epoch AI, HAL
(Princeton), or SWE-rebench. The official leaderboard at
sec-bench.github.io carries a verification badge ("results verified by
the SEC-bench team") and an OSS badge for open-source submissions, but
search snippets surfaced no vendor entries — submissions appear to be
research-group driven, not vendor self-reports. (Direct fetches of
sec-bench.github.io returned 403; HF dataset card shows 600-row split
eval/cve/oss with no leaderboard content; this gap should be re-verified
manually.)

## 3. Implication for our dual-track reporting

Because **no vendor has shipped its own SEC-bench number**, there is no
vendor harness to cite, no vendor-tuned vs vendor-stock comparison
available, and no upstream methodology disclosure to lean on. The only
prior art is the SEC-bench paper's own baselines, which used three
scaffolds (SWE-agent, OpenHands, Aider) — *not* smolagents — even though
the SEC-bench repo now ships smolagents as the primary runner. Our
stock-smolagents numbers therefore stand as the first public smolagents
results on this bench.

This strengthens the case for our dual-track plan:

- **Stock-smolagents** numbers — directly comparable to nothing yet
  vendor-published, but methodologically faithful to the upstream runner
  and a useful "out of the box" baseline.
- **Patched-smolagents** numbers — close the gap to SWE-agent /
  OpenHands paper baselines (Claude 3.7 hit Patch 34%, PoC 18% there; we
  hit 0/11 on open-weights and 5–8/11 on closed under stock), which
  suggests the stock smolagents harness is leaving large amounts of
  capability on the table. Publishing both forces the conversation about
  harness sensitivity that vendors have so far avoided on this bench.

Recommend we cite the paper's three-scaffold baselines explicitly in
the methodology doc, flag that no vendor self-report exists, and frame
our patched numbers against the paper's SWE-agent column rather than
against any vendor system card.

## 4. Open questions to escalate

1. The sec-bench.github.io leaderboard kept returning 403 to WebFetch.
   Confirm manually whether any vendor or third-party entry has landed
   there since the NeurIPS 2025 acceptance.
2. Sec-bench HF dataset has splits `eval` (300), `cve` (200), `oss`
   (100) — no `sec-bench-11` or `sec-bench-50` upstream. Our 11- and
   50-task slices are our own — worth documenting their provenance and
   how they map to the upstream `eval` split.
3. Anthropic and OpenAI both used `VulnLMP` / `CyberGym` as their
   end-to-end cyber benches. Worth asking whether SEC-bench was
   considered and rejected (signal/noise? contamination?) or simply
   not on their radar.
4. The paper's Claude 3.7 Sonnet PoC=12.5% (SWE-agent, 80 subset) is
   our nearest comparable. Our Opus 4.7 stock-smolagents 5/11 = 45.5%
   on a different subset is hard to align directly — worth running the
   same 11 tasks under OpenHands or SWE-agent to triangulate harness
   delta vs model delta.

Sources:
- [SEC-bench paper (HF mirror with full baseline table)](https://huggingface.co/papers/2506.11791)
- [SEC-bench arXiv abstract](https://arxiv.org/abs/2506.11791)
- [SEC-bench NeurIPS 2025 poster page](https://neurips.cc/virtual/2025/poster/118134)
- [SEC-bench HF dataset card](https://huggingface.co/datasets/SEC-bench/SEC-bench)
- [SEC-bench leaderboard (403 to WebFetch — verify manually)](https://sec-bench.github.io/)
- [Opus 4.7 system card coverage (Help Net Security)](https://www.helpnetsecurity.com/2026/04/16/claude-opus-4-7-released/)
- [Mythos Preview model card overview](https://hugobowne.github.io/mythos-preview-model-card/overview)
- [GPT-5.5 cybersecurity deployment safety hub](https://deploymentsafety.openai.com/gpt-5-5/cybersecurity)
- [Gemini 3 Pro model card PDF](https://storage.googleapis.com/deepmind-media/Model-Cards/Gemini-3-Pro-Model-Card.pdf)
- [Sec-Gemini v1 launch (Google Security Blog)](https://security.googleblog.com/2025/04/google-launches-sec-gemini-v1-new.html)
- [Nemotron-3 Nano evaluation recipe](https://huggingface.co/blog/nvidia/nemotron-3-nano-evaluation-recipe)
