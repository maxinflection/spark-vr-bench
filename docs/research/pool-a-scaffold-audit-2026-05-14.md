# Pool A Scaffold Audit — 2026-05-14

**Scope:** Research-only audit of the three non-OpenHands Pool A agent scaffolds bundled in
`cybergym-agent-examples` (pinned at `b5cbe06`, June 3 2025). OpenHands modernization is tracked
separately in `bd <ISSUE>`. This doc answers the question: if pgf stalls, which sibling is the least
expensive pivot?

**Audit date:** 2026-05-14  
**Author:** Research sub-agent (claude-sonnet-4-6)  
**Source materials:** GitHub repos, CyberGym paper (arXiv 2506.02548 v1/v2), harness scripts

---

## Background

`cybergym-agent-examples` has four commits:

| Commit   | Date        | Message |
|----------|-------------|---------|
| 6660f3f  | 2026-02-02  | Fix typo ENiGMA→EnIGMA (cosmetic) |
| d1ef553  | 2025-06-23  | Add cybench privileged warning |
| b5cbe06  | 2025-06-03  | Add agents (primary scaffold commit) |
| 58b9c6a  | 2025-06-03  | First commit |

**Pinned submodule commit is `b5cbe06` (June 3 2025).** The cosmetic fix `6660f3f` is the only
subsequent change; all four scaffolds are substantively paper-era.

---

## 1. Codex

### 1.1 Pinned vs current upstream — staleness

The `codex/codex-repo/` subdirectory is a snapshot of the OpenAI Codex CLI at version
`0.1.2504301751` — the version numbering encodes an approximate date of **April 30, 2025**
(~2 weeks after the CLI's public launch on 2025-04-16).

**Current upstream as of 2026-05-14:** stable release `0.130.0` (May 8, 2026), with
`0.131.0-alpha.*` builds in flight.

**Gap:** ~13 months and ~129+ release increments stale. This is architecturally significant:
OpenAI rewrote the CLI from TypeScript/Node to **Rust** in June 2025 (version 0.2.0+), making the
pinned snapshot a dead branch of a fundamentally different tool. The pinned version is the
pre-Rust TypeScript edition; current is Rust.

### 1.2 Model API support

| Target | Support in pinned v0.1.x |
|--------|--------------------------|
| OpenAI direct (gpt55) | Native — `OPENAI_API_KEY` + `MODEL` env vars |
| Custom base URL (vLLM) | Partial — `LLM_BASE_URL` env var passed into container; no `--base_url` CLI flag at v0.1.x |
| Anthropic direct | Not supported natively in v0.1.x |
| Bedrock | Not supported in v0.1.x |
| LiteLLM | Not in the scaffold layer; would require proxy |

**Current upstream (0.130+):** Added built-in Bedrock provider (PR #18744, merged 2026-04-21).
Supports `OPENAI_BASE_URL` for any OpenAI-compatible endpoint. The upstream modernization is
substantial, but requires re-pinning from the Rust era.

**Verdict for our targets:**
- `gpt55` (OpenAI direct): works with pinned version via `OPENAI_API_KEY`
- `opus47` (Bedrock): **does not work** with pinned v0.1.x; would need upgrade to ≥0.130.0
- `vLLM rentals`: partially — `LLM_BASE_URL` is forwarded into the container, but whether the
  inner `codex` CLI honours it as a base URL replacement depends on v0.1.x internals; untested
  and undocumented in the scaffold README

### 1.3 Documented foot-guns

- **Rust rewrite gap:** The pinned TypeScript code and current Rust code are architecturally
  different. Any patch applied to the pinned version cannot be upstreamed or reused without
  re-doing it on Rust.
- **No `--base_url` flag at the run.py layer:** The cybench scaffold's run.py exposes `LLM_BASE_URL`
  env but there is no equivalent of OpenHands' `--base_url` argument, making it harder to point
  at a vLLM endpoint from the harness without undocumented env injection.
- **Node ≥22 required** for the pinned TypeScript version; current Rust CLI has zero Node dependency.
- **No cost tracking / loop detection** analogous to OpenHands' `AgentStuckInLoopError`; Codex CLI
  has iteration limits but no structured stuck-detection.

### 1.4 Build / install cost

The `install.sh` script:
1. Requires **Node + pnpm** (no version pinning — risk of incompatibility with future Node)
2. Runs `pnpm install` + `pnpm run build` inside `codex-repo/codex-cli/`
3. Packages the build output into a Docker image: `cybergym/codex:latest`

Cost estimate: ~5–15 min one-time build, moderate disk (~500 MB Node deps + Docker layer).
No Python venv needed for the scaffold layer itself, but the outer `run.py` is Python.

### 1.5 Local-patch surface

The scaffold calls the Codex CLI inside a Docker container; the CLI's model config is internal to
the container. Because it is OpenAI-native, **there is no temperature scrubbing problem** for
OpenAI models. However, for Bedrock/Opus targets, a model-routing patch equivalent to our
`openhands_temp_patch.py` would be needed _inside the Docker container_, making it more invasive
than the OpenHands llm.py case (container rebuild required).

For vLLM targets, the `LLM_BASE_URL` env injection is the patch point; whether v0.1.x honours it
reliably is unverified.

### 1.6 CyberGym paper pass rates

Paper (arXiv 2506.02548, 300-instance Level 1 subset, GPT-4.1 backbone):
- All four agents (OpenHands, Codex, EnIGMA, Cybench) achieved **similar individual pass rates**
  around the ~9–12% range
- Best single-agent result: OpenHands + Claude-3.7-Sonnet at **11.9%**
- GPT-4.1 across scaffolds: approximately **9.4%** pass@1
- Union of all four agents: **18.4%** (complementary failures across scaffolds)

Per-scaffold breakdown is not individually reported in publicly accessible summaries; the paper
describes all four as achieving "similar success rates" on GPT-4.1. Current leaderboard (May 2026)
shows Claude Mythos at 83.1%, opus47 likely in the 60–70% range (OpenHands + Sonnet-4 = 17.9%
without thinking; GPT-5 + thinking = 22.0%).

---

## 2. EnIGMA

### 2.1 Pinned vs current upstream — staleness

EnIGMA is the cybersecurity CTF fork of SWE-agent. The scaffold in cybergym-agent-examples uses:
- `enigma-repo/` pinned at SWE-agent **v0.7.0** era (September 2023 release)
- Docker image: `sweagent/enigma:latest` (pulled at runtime, not pinned; latest push is the `0.1.0`
  tagged image on Docker Hub)
- **Current SWE-agent upstream:** v1.1.0 (May 22, 2024) — no releases since then through 2025

**Gap for SWE-agent core:** ~6–7 months from v0.7.0 (Sep 2023) to v1.1.0 (May 2024). The
cybergym pinning at June 2025 post-dates v1.1.0; the submodule presumably froze on a commit
between v0.7.0 and v1.1.0 or post-v1.1.0.

The `sweagent/enigma:latest` Docker image is pulled fresh at runtime (not version-locked in
install.sh), which is a staleness mitigation but also a **reproducibility risk** — the image
could change under the harness.

**Months stale:** The cybergym scaffold commit is June 2025. The Docker image is `latest`-based,
so runtime behavior tracks Docker Hub push schedule (unknown cadence; no versioned tag).

### 2.2 Model API support

SWE-agent (EnIGMA's base) uses **LiteLLM** as its model abstraction layer (pyproject: `litellm`
dependency). This gives it the most capable model-routing story of the three siblings:

| Target | Support |
|--------|---------|
| OpenAI direct (gpt55) | Native via `OPENAI_API_KEY` → litellm |
| Anthropic direct | Native via `ANTHROPIC_API_KEY` → litellm |
| Bedrock | litellm supports `bedrock/` prefix; env var pass-through needed |
| Custom base URL (vLLM) | litellm supports `api_base` config; `--agent.model.api_base` CLI flag exists |
| LiteLLM proxy | Works natively — litellm is the internal transport |

**The scaffold's run.py passes `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` into the Docker subprocess
env.** This is the most complete API-routing story of the three.

**Caveat for Bedrock:** litellm's Bedrock support requires `AWS_*` credential env vars. The
EnIGMA run.py does not explicitly forward `AWS_REGION`, `AWS_ACCESS_KEY_ID`, etc. — would need
a run.py patch analogous to what we did for OpenHands' config.toml region injection.

**Caveat for vLLM:** SWE-agent's `--agent.model.api_base` CLI flag exists but is not surfaced in
the cybergym EnIGMA run.py. A run.py patch to pass it through would be needed.

### 2.3 Documented foot-guns

- **Max output tokens hardcoded to 2048** in the scaffold: `CYBERGYM_HOOK_MAX_OUTPUT_TOKENS=2048`.
  This is very low for complex PoC generation tasks; may cause premature truncation.
- **Cost limit $2.00 default:** `--cost_limit 2.0` per task. This is a per-task dollar cap that
  terminates the agent. For expensive Bedrock frontier calls (Opus at ~$75/MTok out), a complex
  task could hit the cap after ~26K output tokens, well before solving.
- **SWE-agent infinite loop issues** (GitHub issues #971, #1235): Known cases where the agent
  repeats actions without making progress, analogous to OpenHands' AgentStuckInLoopError.
  Manifests as "agent not doing tool calls" and retrying same commands.
- **Docker image `latest` is unpinned**: pulling at install time means runs may differ across
  harness reinstalls.
- **config/ctf_pwn.yaml is CTF-optimized**: hardcoded for pwn-style CTF challenges (radare2,
  pwntools); not the vulnerability reproduction (PoC triggering) task CyberGym requires.
  Cybergym ships a separate config but its coverage of non-CTF tasks is uncertain.

### 2.4 Build / install cost

1. `docker pull sweagent/enigma:latest` — Docker pull (~few GB)
2. `python3 -m venv venv && venv/bin/pip3 install -r requirements.txt` — Python venv setup
3. No poetry or complex build step; simpler than OpenHands

Install cost: ~10–20 min (mostly Docker pull). Venv is lightweight.
No Docker-in-Docker required (unlike cybench).

### 2.5 Local-patch surface

SWE-agent (EnIGMA's base) passes `temperature: float = 0.0` to litellm's completion call. Bedrock
cross-region inference profiles for Opus 4.x reject `temperature` (as we discovered with
OpenHands). **The same temperature scrub patch would be needed** inside the sweagent/enigma Docker
image or by monkey-patching the litellm invocation. Since the code runs inside the Docker
container, patching requires either:
- Rebuilding the Docker image with the patch applied, or
- Mounting a patched source file into the container

This is more invasive than our OpenHands case (where `openhands_temp_patch.py` edits a host-side
file in the poetry venv before the subprocess is spawned).

### 2.6 CyberGym paper pass rates

Same paper figures apply — all four agents achieved similar pass rates on GPT-4.1 (~9–12%).
EnIGMA's design is CTF-specialized (NYU CTF benchmark: 13.5% solve rate, 3.3× over prior agents),
but CyberGym's tasks are vulnerability reproduction (PoC crash generation), not flag capture —
EnIGMA's CTF advantages may not transfer cleanly.

---

## 3. Cybench

### 3.1 Pinned vs current upstream — staleness

The `cybench/cybench-repo/` is a snapshot of `andyzorigin/cybench`. The upstream repo's most
recent substantive commits:
- `88d6893` (Apr 22, 2026): fix flag metadata typo
- `199bdcc` (Apr 22, 2026): CI — pin Python 3.11
- `d494f24` (Jun 12, 2025): README pointer to bountybench
- Prior commits: Nov 2024, Sep 2024

The submodule pinned at June 2025 (`b5cbe06`) aligns with the README update; substantive code
is from Sep–Nov 2024. **Months stale: ~8–13 months** from the pinned June 2025 commit to today.
The 2026 commits are metadata-only and do not affect agent behavior.

**No formal versioning** — cybench has no releases, no semantic version tags.

### 3.2 Model API support

Cybench's agent uses two pathways:
1. **HELM (Stanford CRFM):** HTTP calls to `crfm-models.stanford.edu` — irrelevant for our targets
2. **Non-HELM:** native API clients for OpenAI, Anthropic, Google, Together AI

From `requirements.txt`: `openai==1.37.0`, `anthropic==0.31.2`, `google-generativeai==0.7.2`.

The `model_map()` function in `run.py` (the cybergym scaffold wrapper) **explicitly raises
ValueError for non-OpenAI models** — mapping only `gpt-*`, `o3-*`, `o4-*` prefixes to
`openai/<model>` format. Despite importing `ANTHROPIC_API_KEY`, the wrapper layer rejects
non-OpenAI model names at entry.

| Target | Support |
|--------|---------|
| OpenAI direct (gpt55) | Works — `gpt-*` prefix mapped |
| Anthropic direct (non-Bedrock) | Blocked at scaffold wrapper; inner agent has anthropic client |
| Bedrock | Not supported |
| Custom base URL (vLLM) | No `base_url` / `api_base` support in wrapper or inner agent |
| LiteLLM | Not used |

**For our targets:**
- `gpt55`: works
- `opus47` (Bedrock): **does not work** — no Bedrock pathway anywhere
- `vLLM`: **does not work** — no base URL override

### 3.3 Documented foot-guns

- **Requires Docker privileged mode (docker-in-docker):** README explicitly warns: "Cybench agent
  requires docker privileged mode to enable docker-in-docker and special network configs, please
  be careful about directly running on your host server." Recommends isolated VMs.
  This is a **hard harness requirement** — our EC2-based harness would need `--privileged` Docker
  invocations, creating security exposure.
- **Token limits are very low:** `max_input_tokens=6000`, `max_output_tokens=2000` hardcoded as
  dataclass defaults. For 128K-context frontier models this is far below capability; for complex
  CyberGym PoC tasks this truncation likely degrades performance significantly.
- **OpenAI SDK pinned at 1.37.0:** Current is ≥1.75+. Bedrock / Responses API changes in later
  SDK versions are absent.
- **HELM dependency:** Requires HELM token at Stanford for that pathway; not relevant but
  indicates research-environment orientation.
- **No base URL / endpoint flexibility:** No mechanism to target vLLM or Bedrock endpoints.

### 3.4 Build / install cost

1. `docker build -t cybergym/cybench:latest .` — Docker image build from Dockerfile
2. No Node, no pnpm, no poetry; simpler build than Codex
3. **Docker-in-Docker (privileged)** required at runtime — escalated privileges on the harness host

Install cost: ~5–15 min Docker build. Privileged mode requirement is the significant operational
cost.

### 3.5 Local-patch surface

Cybench calls OpenAI's API natively (`openai==1.37.0`) inside the Docker container. For OpenAI
direct targets, no temperature scrub is needed. For Bedrock/Anthropic targets, patching would
require rebuilding the Docker image. The `model_map()` rejection of non-gpt models is a
**code-level gate in run.py** (the cybergym scaffold layer, not inside Docker) — easier to patch
than the Docker-internal code.

Minimum patches needed for Bedrock/opus47:
1. Patch `run.py` to not reject non-OpenAI model names
2. Add a Bedrock pathway inside the Docker image (or route through LiteLLM proxy)
3. Temperature scrub for Opus 4.x

### 3.6 CyberGym paper pass rates

Same paper figures as above. Cybench was the reference agent for the CyberGym paper's
benchmarking; all four scaffolds had similar GPT-4.1 pass rates (~9–12%) on Level 1. Cybench is
the "native" agent for this benchmark in the paper, so its performance with OpenAI models is
representative of the benchmark's intended usage.

---

## 4. Comparative Summary

| Dimension | Codex | EnIGMA | Cybench |
|-----------|-------|--------|---------|
| Upstream staleness | 13 months + Rust rewrite chasm | ~12 months (Docker image is `latest`) | ~13 months (code), 2 months (metadata) |
| opus47/Bedrock support | No (pinned); yes in upstream 0.130+ | Partial (litellm has path; env patch needed) | No (hard) |
| gpt55/OpenAI | Yes | Yes | Yes |
| vLLM rental | Partial (unverified LLM_BASE_URL) | Partial (api_base flag exists; run.py patch needed) | No |
| LiteLLM abstraction | No (OpenAI-only at v0.1.x) | Yes (native) | No |
| Build complexity | Medium (Node+pnpm+Docker) | Low (Docker pull + venv) | Low (Docker build) |
| Privileged Docker | No | No | **Yes (required)** |
| Temperature patch risk | Low (OpenAI only, no issue) | High (same issue as OpenHands; in-container) | Low (OpenAI only) |
| Loop detection | None visible | litellm cost limits; SWE-agent loop issues known | max_iter only |
| Per-task cost control | Iteration cap only | `--cost_limit $2.00` (may be too low) | `max_iter` + token limits |
| Paper pass rate (GPT-4.1, Level 1) | ~9–12% (similar to all four) | ~9–12% (CTF-specialized, may not transfer) | ~9–12% (native CyberGym agent) |

---

## 5. Recommendation

**prefer-modernizing-OpenHands**

Rationale:

1. **OpenHands is the path of least resistance for all three model targets.** It already has
   `--base_url` (vLLM), `bedrock/` prefix routing through litellm (Bedrock/opus47), and we have
   working patches for temperature scrubbing, base_url-empty guard, and docker0 server URL. Three
   confirmed Pool A task runs are already passing. The pgf modernization work is incremental.

2. **Codex is the highest-effort pivot:** The Rust rewrite makes the pinned v0.1.x a dead branch.
   Upgrading to current would require adapting the entire install.sh + run.py to the Rust CLI's
   configuration model (which is substantially different). Bedrock support only arrived in the
   Rust era (April 2026, PR #18744). vLLM support is plausible but untested. Estimated pivot cost:
   2–4 days of integration + testing.

3. **EnIGMA is the most viable fallback.** LiteLLM as internal transport means all three targets
   are mechanically possible; the blocking issues (Bedrock env forwarding, api_base passthrough,
   in-container temperature patch) are patches rather than architectural re-dos. The Docker image
   being `latest`-pinned is a reproducibility concern but keeps the image relatively fresh. The
   CTF-vs-PoC mismatch is a performance uncertainty, not a correctness blocker. Estimated pivot
   cost: 1–2 days to wire Bedrock/vLLM env forwarding into run.py + in-container temp patch.

4. **Cybench is the least viable pivot** for our target mix: no Bedrock, no vLLM, docker-in-docker
   privileged requirement, hard-coded OpenAI-only model_map(). It is the benchmark's native agent
   for GPT-4.1 and fine for gpt55-only runs, but adding Bedrock/vLLM support requires
   reconstructing its API layer from scratch.

5. **run-multiple-in-parallel is not recommended** for a fallback scenario. If pgf is blocked,
   picking one scaffold to invest in is more cost-effective than fragmenting effort. If pgf
   succeeds (expected), running EnIGMA in parallel as a complementarity test (the union result of
   18.4% vs 11.9% best-single is compelling) would be worth filing as a separate issue.

**If pgf fails and a pivot is forced:** pivot to EnIGMA. File a follow-up issue covering:
- Wire `AWS_REGION` / Bedrock credentials into EnIGMA run.py env forwarding
- Wire `--agent.model.api_base` for vLLM targets
- Patch in-container temperature scrub (or route through litellm proxy with scrub at the proxy layer)
- Raise `CYBERGYM_HOOK_MAX_OUTPUT_TOKENS` from 2048 to at least 8192
- Raise `--cost_limit` to match our per-task budget

---

*Sources: cybergym-agent-examples commits (GitHub), CyberGym paper arXiv:2506.02548, openai/codex
releases, SWE-agent/SWE-agent releases, andyzorigin/cybench commits, OpenAI Codex PR #18744.*
