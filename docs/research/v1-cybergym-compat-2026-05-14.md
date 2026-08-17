# CyberGym x OpenHands V1 Compatibility Research
**Date:** 2026-05-14  
**Axis:** cybergym ↔ V1 compatibility (bd issue `of4`, subagent C)  
**Author:** Research sub-agent (claude-sonnet-4-6)  
**Sources:** GitHub repos, PyPI, OpenHands releases, WebSearch, local harness files

---

## Discipline note

Every claim below cites a primary source. Unverified claims are flagged `[UNVERIFIED]`. The matrix-doc track record (GPT-5.x temperature/max_tokens rows mis-classified) demands this discipline.

---

## 1. Upstream cybergym V1 path

### 1.1 cybergym-agent-examples repo

**Primary source:** https://github.com/sunblaze-ucb/cybergym-agent-examples

The repo has **4 total commits** on `main`:

| SHA | Date | Message |
|-----|------|---------|
| 6660f3f | 2026-02-02 | Fix typo ENiGMA→EnIGMA (cosmetic) |
| d1ef553 | 2025-06-23 | Add cybench privileged warning |
| b5cbe06 | 2025-06-03 | Add agents (primary scaffold commit) |
| 58b9c6a | 2025-06-03 | First commit |

There is **no V1 code path** in any branch of `cybergym-agent-examples`. The `openhands/run.py` at `b5cbe06` (and the `6660f3f` tip, which only changes a README typo) invokes OpenHands via `poetry run python -m openhands.core.main`. This is exclusively a V0 invocation pattern.

The `openhands/` directory contains:
- `openhands-repo/` (submodule pinned to V0 SHA)
- `template/` (config.toml for the runtime container)
- `run.py` (383 lines, V0 subprocess approach)
- `README.md` (references `docker.all-hands.dev/all-hands-ai/runtime:0.33-nikolaik`)

**Primary source for run.py content:** https://github.com/sunblaze-ucb/cybergym-agent-examples/blob/main/openhands/run.py (fetched 2026-05-14)

The open PR (#1, "Fix enigma reverse engineering commands", author Benzhang2004, Aug 2025) addresses EnIGMA — not OpenHands and not V1.

**Finding:** No V1 OpenHands code path exists in any branch or PR of `cybergym-agent-examples`.

### 1.2 Parent cybergym repo

**Primary source:** https://github.com/sunblaze-ucb/cybergym (fetched 2026-05-14)

The parent cybergym repo (`sunblaze-ucb/cybergym`) is the grading server and task-generation library (`cybergym.server`, `cybergym.task.gen_task`). It does not contain agent runner code — that lives in `cybergym-agent-examples`. The cybergym server is independent of the agent runtime; it is a standalone HTTP service. Recent commits (April 2026) include rate limiter, firewall/proxy config, and `mask_map_path` parameter — infrastructure work, not agent-runner work. **No V1 OpenHands references found** in any cybergym commit or issue.

0 open PRs on cybergym as of 2026-05-14.

---

## 2. Community forks

**Primary source:** https://github.com/sunblaze-ucb/cybergym-agent-examples/network/members (fetched 2026-05-14)

There are **8 forks** of cybergym-agent-examples:

| Fork | Notable activity |
|------|-----------------|
| sslab-gatech/cybergym-agent-examples | **6 commits** including `286cedf` (2026-02-26): "Local modifications for LiteLLM integration and reproduction experiments" |
| Benzhang2004/cybergym-agent-examples | Source of the open PR #1 (EnIGMA fix) |
| anubis770, Elfsong, nearKim, puneeshkhanna, winnsterx, z4z3x9 | No substantive public activity visible |

The sslab-gatech fork (Georgia Tech Systems Security Lab) is the most active. Commit `286cedf` (Feb 2026) modifies `codex/run.py`, `cybench/run.py`, and `enigma/run.py` to support LiteLLM proxy routing and additional Claude/GPT-5 models. **The `openhands/run.py` was not touched.** This fork does not introduce V1 OpenHands code.

**Finding:** No community fork has wired V1 OpenHands against cybergym. The sslab-gatech fork's LiteLLM proxy approach for Codex/Cybench/EnIGMA is notable as an independent validation that the other scaffolds need routing patches — but they went around OpenHands rather than modernizing it.

**Web search** for `cybergym OpenHands V1 "agent-server" OR "software-agent-sdk"` returned no relevant results beyond the OpenHands SDK documentation itself. No blog posts, papers, or external projects found that pair V1 OpenHands with CyberGym.

---

## 3. CyberGym project activity

**Primary source:** https://github.com/sunblaze-ucb/cybergym (commits page, fetched 2026-05-14)

The `sunblaze-ucb/cybergym` repo shows **consistent development activity through April 2026**:

- Apr 2026: rate limiter feature (PR #4), firewall/proxy config, `mask_map_path` parameter
- Feb 2026: `max_file_size_mb` config, README revision
- Jun 2025: initial commits (paper release)

Primary contributors: `wzunknown`, `stneng`. Stars: 308. Forks: 48. 1 open issue (PoC ground-truth access request, Apr 2026).

**The cybergym server/harness is actively maintained.** The cybergym-agent-examples repo, however, is essentially quiescent — only the cosmetic typo fix since June 2025. The sunblaze-ucb team appears to be developing the grading infrastructure but not updating agent scaffolds.

**Assessment for upstream PRs:** The grading server is actively developed by the cybergym team, but the agent-examples repo has had near-zero attention since the paper dropped. A V1 OpenHands PR to `cybergym-agent-examples` would likely not be rejected, but based on the 8-month silence it may sit unmerged indefinitely. We would be carrying the fork for an unknown period. **We should assume we maintain the adapter ourselves.**

---

## 4. Cybergym ↔ agent interface contract

This section documents the confirmed interface contract from our own harness + upstream code review.

### 4.1 What cybergym provides to the agent

`cybergym.task.gen_task.generate_task(TaskConfig)` populates a workspace directory with:
- The vulnerability-reproduction task files (binary artifacts in binary mode)
- A **`submit.sh`** script baked with the specific `agent_id` and the grading server URL, e.g.:
  `curl -s -X POST http://172.17.0.1:8666/submit-vul -F "agent_id=<32-hex>" -F "poc=@<poc_bytes>"`

**Primary source:** `cybergym-agent-examples/openhands/run.py` lines 210–250 (workspace setup), confirmed against our `run-pool-a-cybergym.sh` grading bug arc (bd <ISSUE>, 2026-05-14).

The `agent_id` is a 32-character hex UUID (no dashes) generated by `uuid4().hex` in `run.py` before `generate_task` is called. It is the key for grading server lookup in `poc_records`.

### 4.2 What the agent must do

The agent has free rein in the workspace. It must:
1. Analyze the vulnerability description and code
2. Construct a PoC (proof-of-concept bytes that trigger a crash or sanitizer exit)
3. Execute `bash submit.sh <poc-bytes>` (or pipe bytes to it) to post the PoC to the grading server

The grading server (`cybergym.server`) is an HTTP service running on the harness host — it is completely independent of the agent runtime. The agent runner (our `run.py` or its V1 replacement) does not need to interpret the result; it just needs to let the agent run and then query `poc_records` via `agent_id`.

### 4.3 Does V1's runtime support this workflow?

**V1 agent runtime model** (OpenHands v1.0.0, released 2025-12-16; current v1.7.0, May 2026):

Primary source: OpenHands releases page (https://github.com/All-Hands-AI/OpenHands/releases, fetched 2026-05-14).

The V1 SDK (`OpenHands/software-agent-sdk`, v1.22.0 as of 2026-05-11) exposes a Python API:

```python
from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool

llm = LLM(model="...", api_key="...", base_url=None)
agent = Agent(llm=llm, tools=[Tool(name=TerminalTool.name), ...])
conversation = Conversation(agent=agent, workspace="/path/to/workspace")
conversation.send_message("Your task here")
conversation.run()
```

**Primary source:** `OpenHands/software-agent-sdk` README + `examples/01_standalone_sdk/01_hello_world.py` (fetched 2026-05-14).

The key properties for cybergym compatibility:

| Requirement | V1 SDK support | Evidence |
|-------------|----------------|----------|
| Mount a pre-populated workspace directory | **Yes** — `Conversation(workspace=path)` | SDK README, hello_world.py example |
| Execute arbitrary shell commands (including `bash submit.sh`) | **Yes** — `TerminalTool` is built-in | SDK README: "execute arbitrary shell commands" |
| Run as a local process (no mandatory cloud) | **Yes** — standalone local mode supported | SDK README: "use the local machine as their workspace" |
| Docker sandbox option | **Yes** — Docker workspace supported | `02_remote_agent_server` examples |
| LLM routing (Bedrock, OpenAI, custom base_url) | **Yes** — `LLM(model=..., base_url=...)` | SDK hello_world.py |

**The V1 SDK's workspace-mount + free-exec model is directly compatible with the cybergym interface contract.** An agent given a workspace with `submit.sh` and equipped with `TerminalTool` can `bash submit.sh <poc>` exactly as cybergym expects.

**What is gone in V1:** The subprocess call `poetry run python -m openhands.core.main` is dead. Commit `aea6116` (2026-04-27) deleted `openhands/llm/llm.py` and the broader `openhands/llm/` package (6,873 lines removed). The `openhands.core.main` module is **not present** in V1 (confirmed: the `openhands/__init__.py` in V1 is a namespace package initializer that references only `openhands.app_server.version`, and the `openhands/core` path returned 404 from the GitHub API). **Primary source:** commit `aea6116` diff (fetched 2026-05-14); `openhands/__init__.py` content (fetched 2026-05-14).

The config.toml runtime configuration mechanism (workspace_base, LLM params in `[llm]` section) is also replaced — V1 uses the Python SDK constructor API instead.

---

## 5. Minimum maintenance surface if we go it alone

### 5.1 What the V0 run.py does (383 lines, current)

**Primary source:** https://github.com/sunblaze-ucb/cybergym-agent-examples/blob/main/openhands/run.py (fetched 2026-05-14)

Responsibilities:

| Responsibility | Approx. lines | V1 fate |
|---------------|---------------|---------|
| Dataclass CLI parsing (LLMArgs, OpenhandsArgs, TaskArgs) | ~50 | **Keep** — simple_parsing structure stays |
| `generate_task()` call (cybergym API) | ~30 | **Keep** — cybergym API unchanged |
| Config.toml generation (workspace_base, LLM params) | ~40 | **Replace** — V1 uses SDK constructor |
| `poetry run python -m openhands.core.main` subprocess | ~40 | **Replace** — V1 uses `Conversation.run()` |
| Docker container cleanup (`_cleanup_docker_container`) | ~25 | **Adapt** — V1 may auto-cleanup; verify |
| Environment variable threading (API keys, LOG_DIR) | ~20 | **Adapt** — V1 SDK takes `api_key=` param |
| Trajectory validation (`validate_output`) | ~10 | **Adapt** — V1 trajectory path may differ |
| Logging setup, UUID generation | ~15 | **Keep** |

**Total estimated rewrite surface:** ~105 lines of the 383 are V0-specific and need replacement or adaptation. The cybergym-interaction logic (~80 lines covering `generate_task`, agent_id generation, workspace setup) is unchanged.

### 5.2 V1 replacement architecture

A V1 `run.py` would:

1. Parse the same CLI args (simple_parsing + same dataclasses — no change)
2. Call `generate_task(TaskConfig)` with the same parameters — no change
3. Instantiate `LLM(model=..., api_key=..., base_url=...)` from the SDK
4. Create `Conversation(agent=agent, workspace=task_dir)` pointing at the cybergym workspace
5. Send the task prompt via `conversation.send_message(prompt_content)`
6. Call `conversation.run()` with `max_iterations=` and `timeout=` (SDK supports both `[UNVERIFIED: exact parameter names in SDK]`)
7. Extract `agent_id` (still generated by our code via `uuid4().hex` before `generate_task`)
8. Handle trajectory output path (V1 SDK may use different conventions — requires investigation)

The grading server side is completely unchanged.

**Key unknown (pre-flight required):** Does `Conversation.run()` support a `max_iterations` cap that maps to the V0 `--max-iterations` flag? The SDK examples show `conversation.run()` without iteration limits. The V1 SDK's `Agent` or `Conversation` constructor may accept this. This is a **blocking unknown** — if V1 doesn't support iteration caps, the per-task cost control breaks. `[UNVERIFIED]`

**Key unknown (pre-flight required):** What is the V1 SDK trajectory/log output format? Our runner extracts `agent_id` from a log directory subpath (`<task_id>-<agent_id>`). If V1 uses a different path convention, the verdict extraction in `run-pool-a-cybergym.sh` breaks silently (exactly like the bug we caught 2026-05-14 on the V0 path). `[UNVERIFIED]`

### 5.3 Estimated effort

| Item | Effort |
|------|--------|
| Write V1 `run.py` adapter | 1–2 days |
| Smoke cybergym-3 with V1 SDK locally | 0.5 day |
| Adapt `run-pool-a-cybergym.sh` trajectory/agent_id extraction | 0.5 day |
| Temperature/top_p scrub assessment (V1 SDK vs litellm) | 0.5 day |
| Total | 2–3 days |

This is **medium effort (scenario b)** — a self-written adapter, not a fundamental blocker.

---

## 6. Fallback signal

### 6.1 Is V1 fundamentally incompatible with cybergym?

**No.** The V1 SDK's `Conversation(workspace=path)` + `TerminalTool` model is directly compatible with the cybergym interface. The agent can mount the pre-populated workspace and `bash submit.sh` from inside it. The grading server is an HTTP endpoint independent of the agent runtime, so V1's container model doesn't affect it.

The compatibility gap is **purely at the integration layer**: the V0 subprocess invocation (`poetry run python -m openhands.core.main --config-file config.toml`) is gone, replaced by a Python SDK API. This requires a new `run.py` adapter — medium effort, not an architectural blocker.

### 6.2 Signals that would push toward EnIGMA pivot (bd <ISSUE> recommendation)

Flag any of the following as "push toward EnIGMA":

| Signal | Status | Assessment |
|--------|--------|------------|
| V1 SDK doesn't support iteration caps → unconstrained cost | `[UNVERIFIED]` — unknown from docs | **Pre-flight required before committing** |
| V1 SDK workspace mount fails with Docker-in-Docker or privilege requirements | `[UNVERIFIED]` — Docker sandbox requires investigation | Low concern; local workspace mode avoids DinD |
| V1 trajectory output format incompatible with agent_id extraction | `[UNVERIFIED]` | Pre-flight required; medium concern |
| V1 Bedrock temperature scrub is broken even with litellm 1.84+ | `[UNVERIFIED]` — matrix doc row is uncertain | Covered by 0em Phase 2 smoke |
| V1 SDK update velocity (v1.19.1 → v1.22.0 in two weeks) breaks our adapter | Active risk | Mitigate by pinning SDK at a tested SHA |

**No signal currently found that makes V1 ↔ cybergym fundamentally incompatible.** The strongest remaining uncertainty is whether `Conversation.run()` supports max_iterations. If it does not, we either add a monkey-patch or pivot the per-task loop to poll + cancel — still scenario (b), not (c).

### 6.3 EnIGMA pivot threshold

Per bd `0x1`, EnIGMA is the recommended fallback (LiteLLM native transport, lowest refactor cost among the three siblings). The sslab-gatech fork's February 2026 modifications confirm EnIGMA/SWE-agent can be wired to LiteLLM proxy without Docker image rebuilds. However: EnIGMA's CTF-specialization vs. cybergym's PoC-reproduction task type remains a performance uncertainty, and the per-task cost limit ($2.00 default) may be too low for frontier Bedrock calls on complex tasks.

**Threshold for recommending pivot:** If the V1 SDK's max_iterations gap proves un-patchable AND the standalone local workspace mode doesn't work without Docker privilege escalation, then scenario (c) is in play and EnIGMA pivot is warranted. Neither condition is confirmed yet.

---

## Headline Summary

The cybergym ↔ OpenHands V1 interface is **not fundamentally broken** — the V1 Software Agent SDK's `Conversation(workspace=path)` + `TerminalTool` model supports exactly the workspace-mount + arbitrary-bash execution that cybergym requires. The grading server (cybergym.server) is independent HTTP and is unaffected by the runtime change. The blocking gap is the integration layer: the V0 subprocess call (`poetry run python -m openhands.core.main`) is dead in V1 (confirmed: `openhands.core.main` is not present in V1), and no upstream or community code provides a V1 replacement. The cybergym-agent-examples repo is quiescent (one cosmetic commit in 8 months), no fork has written a V1 adapter, and cybergym itself has 0 open PRs. If we migrate to V1, **we write and own the adapter `run.py`** — an estimated 2–3 days of medium-effort integration work, not an architectural re-do.

---

## Three Scenarios

**(a) V1 works out of the box** — No. The `openhands.core.main` subprocess invocation is gone. Plugging in V1 requires a new `run.py` adapter. Nothing about V1 is drop-in for the current scaffold.

**(b) V1 needs a custom run.py adapter we write/maintain — SUPPORTED BY EVIDENCE.** The V1 SDK's Python API is documented and stable (weekly releases, 712 stars, active). The cybergym grading interface is unchanged. The adapter surface is ~105 lines of the current 383-line `run.py`. Two blocking unknowns (max_iterations support, trajectory path format) are resolvable via pre-flight smoke before committing implementation budget.

**(c) V1 ↔ cybergym fundamentally incompatible** — Not supported. No finding blocks the workspace-mount + free-exec model. No DinD or privilege requirements are forced by V1 in local mode.

**Evidence supports scenario (b).**

---

## Risks for the Plan

| Risk | Severity | Mitigation |
|------|----------|------------|
| `Conversation.run()` lacks max_iterations → runaway cost per task | High | Pre-flight smoke: inspect SDK source for iteration cap param; if absent, implement a wrapper with timeout+cancel |
| V1 SDK trajectory/log path differs from V0 → agent_id extraction breaks silently (exact same failure mode as bd <ISSUE>) | High | Validate agent_id extraction in pre-flight before any graded run |
| V1 SDK rapid release cadence (weekly) → adapter broken by SDK update | Medium | Pin SDK to a tested SHA in the submodule; add a "V1 SDK bump requires re-smoke" policy |
| Temperature scrub for Bedrock Opus 4.7 in V1 SDK + litellm 1.84 — is it needed? | Medium | Covered by 0em Phase 2; the `openhands_temp_patch.py` target (`llm.py`) is gone but litellm 1.84 may handle it natively |
| upstream cybergym-agent-examples never merges our V1 PR → we carry the fork indefinitely | Low-Medium | Accept this from the start; track as a maintenance item, not a blocker |
| V1 Docker sandbox model requires privilege escalation for cybergym binary tasks | Low | Use standalone local workspace mode; Docker sandbox is opt-in in V1, not mandatory |

---

## Recommended Pre-flight Verification

**Cheapest test that disambiguates (a)/(b)/(c):**

Run a **no-LLM container smoke** using the V1 SDK in standalone local mode:

1. Install `openhands-sdk` at a pinned SHA (e.g., v1.22.0)
2. Create a minimal workspace with a fake `submit.sh` that `echo SUBMITTED $@` and exits 0
3. Instantiate `Conversation(agent=agent, workspace=fake_workspace)` and send: `"Run: bash submit.sh hello"`
4. Verify the agent calls `bash submit.sh hello` and the fake script outputs `SUBMITTED hello`

This test costs ~$0.05 in LLM tokens (one or two turns), takes ~10 minutes to set up, and immediately answers:
- Does the local workspace mode work? (eliminates scenario c)
- Does `bash submit.sh` succeed from inside the agent's execution context?
- What does the trajectory/log output look like? (resolves the agent_id extraction unknown)
- Does `max_iterations` or `timeout` work as expected?

If this smoke passes, we are firmly in scenario (b). If it fails due to privilege requirements or sandbox restrictions that prevent `bash` execution, re-evaluate scenario (c) and file the EnIGMA pivot recommendation.

---

*Research completed 2026-05-14. No code modified. All V1 claims cite primary sources; unverified items flagged. Sources: GitHub repos (sunblaze-ucb/cybergym, sunblaze-ucb/cybergym-agent-examples, OpenHands/software-agent-sdk, All-Hands-AI/OpenHands, OpenHands/benchmarks, sslab-gatech/cybergym-agent-examples), OpenHands release page, WebSearch results, local harness file `/home/agent/work/benchmarks/scripts/runners/run-pool-a-cybergym.sh`.*
