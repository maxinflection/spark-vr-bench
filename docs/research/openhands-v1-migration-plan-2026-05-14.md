# OpenHands V1 Migration Plan — 2026-05-14 (DRAFT, awaits operator review)

**Status**: operator-reviewed 2026-05-14 (§9 decisions resolved). Ready to close bd `of4` and unblock bd `m7v` for implementation in a subsequent session.

**Sources** — every load-bearing claim below traces to one of:
- `docs/research/v1-source-archaeology-2026-05-14.md` (A — V1 LLM module + patch-target mapping)
- `docs/research/v1-runtime-contract-2026-05-14.md` (B — agent-server container + HTTP API contract)
- `docs/research/v1-cybergym-compat-2026-05-14.md` (C — cybergym × V1 interface, upstream/fork survey)
- `docs/research/v1-wiring-gap-analysis-2026-05-14.md` (D — `run-pool-a-cybergym.sh` surface walk)
- `docs/research/stack-version-and-patch-matrix-2026-05-14.md` (matrix, with ERRATA section at top — treat its V1 claims as hypotheses; A/B/C/D either verified or refined each)

Claims that none of the above could verify are explicitly tagged `[UNVERIFIED — needs Stage-0 smoke]`.

---

## 1. Executive summary

V1 is not a tag bump. It is a **near-complete rewrite of Pool A's invocation layer**. Specifically:

- **Architecture (B)**: V1 is a two-container model — an *app-server* (port 3000) orchestrates and dynamically spins up *agent-server* containers (port 8000) per conversation. The CLI entrypoint (`python run.py --task_id ...`) is gone; tasks are launched by HTTP: `POST /api/v1/app-conversations` with `StartConversationRequest` JSON.
- **Cybergym integration (C)**: no upstream V1 example agent exists; the most-active community fork (sslab-gatech, Feb 2026) added LiteLLM proxy routing for Codex/Cybench/EnIGMA but **pointedly did not touch OpenHands**. We're first to wire cybergym × V1, and the adapter is ours to write and maintain.
- **Surfaces (D)**: 15 distinct surfaces in `scripts/runners/run-pool-a-cybergym.sh` touch OpenHands. Zero are confidently "same on V1." ~5 are critical-path. ~5 are silent-failure-risk (same shape as V0 bugs #1–#4).
- **Patches (A)**: bc7.3 (Opus 4.7 temperature) has a V1 equivalent inside the SDK (`select_chat_options` keys off litellm's `reasoning_effort` capability) but uses *the same litellm-catalog mechanism* that 0em just proved unreliable. 3wi (GPT-5 stop-word gate) **has less coverage on V1 than on V0** — the SDK does not list GPT-5 in `SUPPORTS_STOP_WORDS_FALSE_MODELS` and `disable_stop_word` exists as dead code.

**Headline implication**: this migration must be approached as a new integration project with smoke gates at every stage, not as an in-place modernization. The cheap pre-flight smoke (Stage 0 below) is the single most important risk-reducing investment.

**Effort estimate** (post-plan, execution-only): 2–4 days for adapter scaffolding + LLM threading + cybergym integration; +0.5–1 day for full validation. Estimate has high variance because of the unverified surfaces in §3.

**Fallback**: if Stage 0 or Stage 1 surfaces blockers that double the estimate, bd `0x1` recommends pivoting to EnIGMA — also paper-era stale but LiteLLM-native and architecturally simpler. Decision point at end of Stage 1.

---

## 2. Architecture delta (V0 → V1)

| Aspect | V0 | V1 | Source |
|---|---|---|---|
| Container topology | Single runtime container per task (`all-hands-ai/runtime:0.33-nikolaik`); auto-remove on task end | Two-container: app-server (`ghcr.io/openhands/openhands:1.x`) orchestrates, spins up agent-server (`ghcr.io/openhands/agent-server:1.21.1-python`) per conversation; **no auto-remove** | B |
| Invocation | `python examples/agents/openhands/run.py --task_id ... --model ...` | `POST /api/v1/app-conversations` with `StartConversationRequest` JSON body | B |
| Cleanup | Container auto-removes | Caller must explicitly `DELETE /api/v1/app-conversations/{id}` per task or containers accumulate | B |
| LLM config | argv flags (`--model`, `--base_url`) + env (`LLM_API_KEY`) | App-server auto-forwards `LLM_*` env to agent-server, but settings router does NOT read `LLM_API_KEY` directly — expects `POST /api/v1/settings` or per-conversation `secrets` dict | B |
| LLM module path | `openhands/llm/llm.py` (V0 patch target for bc7.3 + 3wi) | `OpenHands/software-agent-sdk` → `openhands-sdk/openhands/sdk/llm/` (file `llm.py` exists but different contract) | A, C |
| Version coupling | Runtime image + OpenHands app must match (pgf Stage 1 lesson) | `openhands-sdk` + `openhands-agent-server` + `openhands-tools` must be version-locked together; mismatched = "Runtime-ready then exit" | B |
| Token usage telemetry | Emitted via run.py to result.json | `GET /api/conversations/{id}` → `metrics.accumulated_token_usage`; not in any on-disk file; caller must extract | B |
| Cybergym `--server` URL | argv flag | No CLI equivalent on V1; must be threaded via task prompt or workspace file | B, D |
| max_iter / context | argv `--max_iter` + condenser config | `Conversation.run()` `max_iterations` param `[UNVERIFIED]`; condenser config in SDK | A, C |

---

## 3. Blind-spot register

Every `[UNVERIFIED]` finding from A/B/C/D, structured as questions Stage 0 must answer or that need follow-up smokes.

| # | Question | Why it matters | Resolution path |
|---|---|---|---|
| BS-1 | Does V1 SDK's `select_chat_options()` actually strip temperature for `bedrock/us.anthropic.claude-opus-4-7-v1:0`? The mechanism depends on litellm's `reasoning_effort` catalog being correct for the exact cross-region inference profile string. | Same class of failure as 0em's GPT-5 misclassification — silent param leak that the API rejects mid-run | Stage 0 smoke: invoke V1 SDK with that exact model string and temperature=0.0; observe whether the call body includes temperature |
| BS-2 | Does V1 SDK strip `stop` for GPT-5.x? GPT-5 is **not** in `SUPPORTS_STOP_WORDS_FALSE_MODELS` and the `disable_stop_word` field is dead code; only protection is litellm `drop_params` which 0em proved unreliable | gpt55 cybergym runs would fail mid-conversation with `Unsupported parameter: stop` | Stage 0 smoke: V1 SDK + `openai/gpt-5.5` + a request carrying `stop` |
| BS-3 | Does `Conversation.run()` support `max_iterations`? | Per-task cost control; current V0 path uses CYBERGYM_TASK_MAX_ITER | Stage 0: read `Conversation` source in `openhands-sdk`; if no, file as risk and identify alternative |
| BS-4 | V1 trajectory/log path format — is the `<task_id>-<agent_id>` subdir naming preserved? Or does V1 use a different convention? | bug #4 already burned us once on this exact surface | Stage 0 smoke: run a single conversation, inspect filesystem output structure |
| BS-5 | Is `cybergym.server` reachable from inside the agent-server container? V0 needed docker0 gateway IP (bd memory `feedback_cybergym_server_url`). V1's container network model may differ | Silent-failure shape of V0 bug #1 (URL routing); 0 POSTs to server | Stage 0 smoke: from a started V1 container, curl the cybergym.server URL we plan to use |
| BS-6 | How does cybergym's grading server URL get threaded into the agent? No CLI equivalent on V1; must be in task prompt or workspace file | If we get the threading wrong, agent never knows where to submit | Plan-time: choose prompt-thread vs workspace-file; Stage 0 verify the agent can access it |
| BS-7 | Are agent-server containers actually deleted on `DELETE /api/v1/app-conversations/{id}`, or do orphans accumulate? | Resource leak; could exhaust harness host between cybergym-10 tasks | Stage 0: spin up 3 conversations + delete + `docker ps` |
| BS-8 | Does V1 SDK's `Conversation` support workspace mount for arbitrary external paths (like cybergym's per-task workspace)? | C-finding says yes via `Conversation(agent=agent, workspace=path)` but [UNVERIFIED] on what mount-mechanism is used | Stage 0 smoke: mount a host dir with a mock submit.sh; verify agent can `bash submit.sh` |
| BS-9 | What does Bedrock cross-region inference profile (`us.anthropic.claude-opus-4-7-v1:0`) look like in V1's settings API? Is the model string the same shape we pass to litellm directly? | Wrong shape = wrong model selected, possibly silently | Stage 0 smoke: settings POST + verify a single inference call uses the right model |
| BS-10 | Pinned versions: which exact tuple of `openhands-sdk` + `openhands-agent-server` + `openhands-tools` + agent-server image is verified to work together? | Mismatched = pgf-Stage-1-style "Runtime-ready then exit" | Plan-time: pick from a known-released set, document in install-harness.sh; Stage 0 verifies handshake |
| BS-11 | Does V1 emit AgentStuckInLoopError or equivalent? How does the runner detect "agent gave up vs agent crashed"? | Failure-mode parity with V0 dashboard | Stage 0 (optional): induce a stuck-loop scenario; observe how V1 surfaces it |
| BS-12 | Bedrock IAM credential chain — does the app-server forward AWS instance-role creds to the agent-server cleanly, or is there an extra wiring step? | V0 just inherits via env; V1's two-container model adds a hop | Stage 0: opus47 single inference call from agent-server using instance role |

---

## 4. Wiring delta (V0 → V1, surface by surface)

Summarized from D's table. Critical-path = without it V1 doesn't run at all. Silent-failure = wrong state produces exit-code-0 with garbage results.

| # | Surface (V0 location) | V0 → V1 change | Class | Stage |
|---|---|---|---|---|
| W-1 | `CYBERGYM_AGENT_RUNNER = examples/agents/openhands/run.py` | **Delete**. No V1 equivalent upstream. We write our own adapter (~280 lines of new code per C's estimate, replacing ~105 of the 383-line V0 run.py) | Critical | 1 |
| W-2 | `CYBERGYM_OPENHANDS_RUNTIME_IMAGE = ghcr.io/all-hands-ai/runtime:0.33-nikolaik` | **Replace** with `ghcr.io/openhands/agent-server:1.x-python` AND add `ghcr.io/openhands/openhands:1.x` (app-server) | Critical | 1 |
| W-3 | `build_openhands_argv` (lines 519–576) — argv builder | **Delete**. Replace with `build_v1_conversation_request` that constructs the HTTP body. Model string format may change (BS-9) | Critical | 1 |
| W-4 | Direct `python run.py` subprocess invocation (lines 798–810) | **Rewrite** as HTTP client: start app-server, POST conversation, poll status, GET metrics, DELETE on completion | Critical | 1 |
| W-5 | bc7.3 + 3wi patches to OpenHands `llm.py` | **Re-locate**. bc7.3 may be redundant on V1 (BS-1); 3wi has no V1 equivalent (BS-2) — we re-implement at our litellm-patches layer or vendor a V1 SDK patch | Critical | 2 |
| W-6 | `LLM_API_KEY` env threading | **Rewire** via per-conversation `secrets` dict in StartConversationRequest (operator chose option (b) per §9 Q2). Env-forward option (a) rejected — unproven on our config and leaks key across all app-server conversations | Critical | 2 |
| W-7 | `extract_agent_id_from_log_dir` (post-bug-#4-fix) | **Re-verify**. V1 trajectory path format unknown (BS-4); regex `[0-9a-fA-F]{32}$` may or may not match | Silent-failure | 3 |
| W-8 | `poc_db_verdict` SQL (post-trim-fix) | **Likely unchanged**. Cybergym.server is independent; what matters is V1 emits the same `agent_id` value into submit.sh's curl. Verify in Stage 3 | Silent-failure | 3 |
| W-9 | `CYBERGYM_SERVER_URL_FOR_AGENT` (docker0 gateway) | **Verify** (BS-5). V1's network model may differ; might need explicit `--network host` or analogous wiring | Silent-failure | 0 |
| W-10 | `session_setup` (cybergym.server start) | **Unchanged**. Server-side is independent of agent runtime | Same | — |
| W-11 | Condenser max_model_len ≥ 16384 (bd memory `feedback_openhands_cybergym_ctx`) | **Unknown**. V1 condenser config exists in SDK but exposure surface differs; may need re-tuning | Risk | 3 |
| W-12 | Bedrock `AWS_REGION` env | **Likely same** but BS-12 — verify two-container forwarding works | Risk | 2 |
| W-13 | `--silent`, `--max_iter`, `--timeout`, `--difficulty` flags | **Unknown** which have V1 equivalents (BS-3 for max_iter); some may move into the HTTP request body | Risk | 1 |
| W-14 | Token usage extraction | **Rewrite**. V1 emits via API endpoint (BS metrics), not file. New extraction step required | Critical (for dashboard) | 2 |
| W-15 | `--data_dir`, `--log_dir`, `--tmp_dir` mounts | **Rewrite**. V1's workspace mount model is per-conversation; cybergym's per-task workspace must be mapped (BS-8) | Critical | 1 |

---

## 5. Risk register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-1 | Bedrock Opus 4.7 temperature leaks through V1 + litellm (BS-1) — silent rejection mid-run | High | Med (caught by audit; visible quickly) | Stage 0 smoke; if confirmed, port `_TEMPERATURE_FORBIDDEN` patch to V1's litellm config layer |
| R-2 | GPT-5 `stop` param leaks (BS-2) | High | Med | Stage 0 smoke; same mitigation as R-1 |
| R-3 | V1 agent-server cannot reach cybergym.server (BS-5) — exact V0 bug #1 shape | Med | High (0 POSTs = silently wrong pass rate) | Stage 0 smoke; if confirmed, network-mode patch (host-network or static route) |
| R-4 | Trajectory format change breaks `agent_id` extraction (BS-4) — exact V0 bug #4 shape | Med | High (silent 0/N) | Stage 0 smoke; update regex or extraction path |
| R-5 | Container accumulation if DELETE is missed (BS-7) | Med | Med (resource leak; cybergym-10 might exhaust) | Add explicit cleanup in `finally` block; verify with `docker ps` in Stage 0 |
| R-6 | `Conversation.run()` lacks `max_iterations` (BS-3) → no cost cap | Low | High ($$$) | Plan-time: read source; if confirmed missing, file SDK issue + add wall-clock timeout as proxy |
| R-7 | Version-lock mismatch between SDK/agent-server/tools (BS-10) → "Runtime-ready then exit" | Med (V1 moves fast) | High (catastrophic) | Pin all three to a known-tested tuple in install-harness.sh; document tuple + test date |
| R-8 | Settings/secrets routing wrong (W-6) — auth doesn't reach agent-server | Med | High | Stage 2 smoke gate explicitly tests a single API call against Bedrock |
| R-9 | Token-usage extraction code drifts from V1 API shape and dashboards report zeros | Med | Low (visible; not a correctness bug) | Stage 2 includes "verify metrics endpoint returns non-zero" as gate |
| R-10 | Cybergym workspace mount semantics on V1 incompatible with cybergym's expectations (BS-8) | Low | High | Stage 0 smoke specifically tests mock-submit.sh execution |
| R-11 | V1 release moves daily (A) — anything we pin breaks within weeks | Med | Low (we control bump cadence) | Pin commits + image digests, not tags; periodic re-bumps as separate work |
| R-12 | Scope ballooning if multiple BS-* questions return "needs deeper rework" | Med | High (timeline) | Hard decision point at end of Stage 1: if effort estimate doubles, escalate. The bd <ISSUE> EnIGMA fallback is **no longer a clean pivot** (EnIGMA upstream is ~2 years stale and team appears to have pivoted to SWE-agent — see §9 Q3). The realistic alternative if V1 stalls is to skip cybergym-class benches and move other Pool A benches forward earlier (<CAMPAIGN> CVE-Bench, <CAMPAIGN> SEC-bench, etc.). |

---

## 6. Decomposition (stages with smoke gates)

Each stage has explicit pass criteria. **No stage advances until its gate is met.** A failed gate triggers a defined re-plan or fallback.

### Stage 0 — Pre-flight no-LLM smoke (BS-1/2/4/5/7/8/12)

**Goal**: validate the architectural assumptions before writing adapter code. ~$0.05 if we use Bedrock at all (one or two cheap inference calls). ~1 hour wall.

**Stage 0.a — Digest tuple identification (per §9 Q1)**:
- Find the latest released `openhands-sdk` tag (e.g. v1.22.x). Inspect its `pyproject.toml` / release notes for the agent-server image it expects.
- Resolve image tags to digests: `docker buildx imagetools inspect ghcr.io/openhands/agent-server:<tag>` → digest. Same for the app-server image.
- Record the tuple: `openhands-sdk` version + `openhands-agent-server` version + `openhands-tools` version + agent-server image digest + app-server image digest. This is the pin we'll use through the rest of the migration.
- All subsequent Stage 0 sub-tests run against this exact tuple.

**Stage 0.b — Setup**:
- Pull the resolved digests on the harness host.
- Stand up app-server. POST `/api/v1/settings` with our Bedrock config (`us.anthropic.claude-opus-4-7-v1:0`, AWS region) using the **per-conversation `secrets` dict** routing chosen in §9 Q2 — verify it works before we commit adapter code to that path.

**Sub-tests**:
1. **Network reachability** (BS-5): from inside a freshly-launched agent-server container, `curl` to our cybergym.server URL using the docker0 gateway IP. Expect 200 / 4xx (anything-but-network-error).
2. **Parameter scrubbing** (BS-1, BS-2): single inference calls with temperature=0.0 against Opus 4.7 and `stop=["X"]` against gpt-5.5. Capture raw API response. If either rejects the param, R-1/R-2 are confirmed and the patches must port to V1.
3. **Workspace mount + submit.sh exec** (BS-8): create a host dir with a mock `submit.sh` that echoes "OK"; POST a conversation that runs `bash submit.sh`; verify the echo appears in trajectory.
4. **Trajectory layout** (BS-4): inspect the on-disk artifacts produced by the test conversation. Document the actual subdir naming and confirm whether `[0-9a-fA-F]{32}$` regex matches.
5. **Container lifecycle** (BS-7): start 3 conversations, DELETE each. Run `docker ps`; confirm zero leaked containers.
6. **Bedrock IAM forwarding** (BS-12): sub-test 2's Bedrock call from inside the agent-server container; confirm instance-role credentials reach the model.

**Pass gate**: all 6 sub-tests pass OR each failure has a documented mitigation in the risk register (R-1..R-12) that's been ack'd by operator.

**Fail handling**: if 2 or more sub-tests fail in unexpected ways (not the BS-1/BS-2 known-risks), STOP and re-evaluate. Possible re-plan, possible EnIGMA pivot.

### Stage 1 — Adapter scaffolding (no LLM yet)

**Goal**: write the V1 adapter — `scripts/runners/run-pool-a-cybergym-v1.sh` + a Python helper for the HTTP API contract. Mirror the V0 file's structure so we can side-by-side test. **The V0 path stays alive in main** — V1 lives in a new file under a feature flag.

**Includes**: W-1, W-2, W-3, W-4, W-13, W-15. Adapter handles:
- App-server lifecycle (start, healthcheck, stop).
- StartConversationRequest body construction from our existing target/task variables.
- Polling for conversation completion.
- Workspace mount mapping.
- DELETE cleanup (per R-5).

**Pass gate**: the adapter can complete a no-LLM conversation that runs `bash submit.sh OK` and verify the echo in trajectory. Same as Stage 0 sub-test 3 but now driven by our adapter, not curl. Effectively: the adapter replaces what curl proved.

### Stage 2 — LLM threading + Bedrock cross-region (W-5, W-6, W-12, W-14)

**Goal**: opus47 + gpt55 single-task smoke through the adapter. No cybergym integration yet — just verify the model talks.

**Includes**:
- Settings/secrets routing (W-6 option).
- Port bc7.3/3wi patches if BS-1/BS-2 surfaced gaps (R-1, R-2).
- Token usage extraction (W-14, R-9).

**Pass gate**: a single `Conversation.run()` against Opus 4.7 (and separately against gpt-5.5) produces a non-empty response AND `metrics.accumulated_token_usage` shows non-zero tokens. Bedrock-cross-region inference profile string verified to route correctly.

### Stage 3 — Cybergym integration (W-7, W-8, W-11)

**Goal**: opus47 single cybergym task end-to-end (e.g. arvo:3938, which we know is reliable on V0).

**Includes**:
- agent_id extraction adapted to V1 trajectory layout (R-4).
- Workspace mount with real cybergym data.
- max_model_len / condenser tuning if context overflows surface.

**Pass gate**: result.json matches poc.db ground truth for arvo:3938 (DB vul_exit_code=1 → result.json pass=1). Audit discipline from `feedback_pool_a_grading_audit.md` applied: server.log POST count, poc.db query, result.json cross-check.

**Critical**: this is where we re-validate the entire silent-failure surface against V1. If audit cross-check fails (DB says pass but result.json says fail, or vice versa), STOP — we have a V1 analog of bug #1/#3/#4.

### Stage 4 — Full validation

**Goal**: cybergym-3 then cybergym-10 against the V0 baseline floor.

**Acceptance criteria**:
- cybergym-3 opus47: arvo:3938 reliable (must pass); aggregate within 1–3/3 envelope across 2 runs.
- cybergym-10 opus47: produces a non-trivial pass rate (>0/10) with audit cross-check passing on every task.
- gpt55 cybergym-3 single run, same audit discipline.

**Pass gate**: above + dashboard math (token usage, costs) correctly populated for every task.

### Stage 5 — Cutover + close

- Retire V0 runner path. Update install-harness.sh to pin V1 versions.
- Update sweep-status doc.
- Close bd `of4`, claim and resolve bd `m7v` as completed.

---

## 7. Rollback procedure

V0 path stays alive throughout the migration in `scripts/runners/run-pool-a-cybergym.sh` (untouched). V1 lives in a new file (`run-pool-a-cybergym-v1.sh` or equivalent) and is opt-in via campaign flag or separate runner invocation until Stage 5.

If any stage gates fail catastrophically:
- Stage 0 fail → re-plan; possibly invoke EnIGMA fallback per bd `0x1`.
- Stage 1–3 fail → V1 code stays in branch, not retired. V0 continues serving sweeps. We file follow-up bd issues for the specific blockers and either fix them or escalate.
- Stage 4 fail (regression below floor) → V1 stays gated; revert to V0 for the canonical sweep; investigate the specific regression.

The "atomic cutover" pattern (Stage 5) is the only point where V0 is retired — and only after Stage 4 passes.

---

## 8. Measurable success criteria (for the migration as a whole)

1. **Floor parity**: opus47 cybergym-3 on V1 reproduces the V0 floor envelope (arvo:3938 reliable; aggregate 1–3/3 across ≥2 runs).
2. **Audit cross-check on every Stage 3–4 run**: result.json verdicts agree with poc.db ground truth natively (no manual reprocessing). Bug-#4-class silent failure ruled out.
3. **gpt55 path validated**: at least one successful cybergym-3 opus47-parity smoke through gpt55 with audit cross-check passing.
4. **No V0 patches carried forward without justification**: each of bc7.3, 3wi either confirmed unneeded on V1 (smoke evidence) or re-implemented at the V1 SDK/litellm-patches layer (with citation matching the new gap).
5. **Token usage + cost extraction works**: dashboard math is populated correctly for every V1 task.
6. **Version-lock documented**: `openhands-sdk` + `openhands-agent-server` + `openhands-tools` + agent-server image — exact tuple, exact pull date, exact smoke campaign that validated it — pinned in `install-harness.sh`.

---

## 9. Operator decisions (resolved 2026-05-14)

1. **Version tuple — digest pinning.** Digests over tags. **However**: identifying *which* digest tuple to pin is itself non-trivial since V1 has no published "tested-together" matrix and moves daily. Promoted to a **Stage 0 prerequisite** (§6 Stage 0 now has an explicit "identify the digest tuple" sub-task): start with the latest released `openhands-sdk` tag, pull its declared agent-server image digest, and use those exact digests as the pin. Document the tuple + pull date + the smoke campaign that validated it. Re-bumps are a separate work item per R-11.
2. **Auth routing — per-conversation `secrets` dict (W-6 option b).** Cleaner separation and avoids leaking LLM_API_KEY across all app-server conversations. Adapter takes the extra code cost. The env-forward path was attractive on simplicity but is unproven on our config (B's BS-12 noted it depends on settings router behavior we haven't smoked).
3. **EnIGMA pivot — defer the decision.** Additional research surfaced that EnIGMA is ~2 years stale and the upstream team appears to have pivoted to SWE-agent. The realistic Pool A fallback if V1 stalls is more likely **"skip cybergym-class benches, go to other Pool A benches earlier"** rather than pivoting to another cybergym-compatible scaffold. R-12 reframed accordingly. We hold the decision at the Stage 1 gate; if Stage 0/1 surfaces blockers that double the estimate, escalate rather than pre-commit to a specific pivot.
4. **gpt55 inline at Stage 4.** Keeps inline — $30/$60 spend is worth learning about gpt55-specific blockers before cutover rather than discovering them in a follow-up sweep.
5. **vllm Pool A — deferred.** Rentals stay out of scope for this migration. Treated as a follow-up sweep after V1 cycles green; tracked under existing Pool A rental issues, not under m7v.
6. **0em conflict surface — checked, none material.** 0em (closed) touched `scripts/install-harness.sh` (Pool B pip pins ~line 326 + V0 image-coupling comment ~line 440), `scripts/runners/_litellm_patches.py` (entire file), and `scripts/runners/run-pool-a-cybergym.sh` (comments only at line 134). V1 migration plan adds V1 image pulls/venv to install-harness.sh in a **different section** (no line conflict), keeps V0 runner file untouched until Stage 5 cutover (per §7), and may **add** patches to `_litellm_patches.py` if Stage 0 BS-1/BS-2 smokes confirm V1 retains the same litellm catalog gaps. The patches-file surface is additive, not conflicting. No cross-cutting block.

---

## 10. NOT in scope

- Pool B modernization (bd `0em`).
- Pool A scaffold pivot to EnIGMA (bd `0x1` fallback; invoked only if R-12 hits).
- Multi-agent scaffold work (depthfirst-style prompt/feedback enhancements).
- Sonnet 4.6 / future model onboarding (separate work after V1 cycles green).
- Rental-side vllm Pool A wiring (open Q-5).

---

## 11. Acceptance for bd `of4` (this issue)

- ✅ Plan doc landed (this file).
- ✅ Every load-bearing V1 claim cited (A/B/C/D research docs; matrix doc with errata).
- ⏳ Unverified claims explicitly flagged `[UNVERIFIED — Stage 0]` with resolution paths.
- ⏳ Operator review and sign-off.

Upon sign-off: close `of4`, unblock `m7v`, start Stage 0 in the implementation session.
