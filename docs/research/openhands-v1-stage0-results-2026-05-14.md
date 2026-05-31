# OpenHands V1 — Stage 0 Smoke Results (m7v)

**Date**: 2026-05-14
**Issue**: benchmarks-m7v (claimed)
**Spec**: `docs/research/openhands-v1-migration-plan-2026-05-14.md` §6 Stage 0
**Harness**: <HARNESS_INSTANCE_ID> (the bc7 harness, reused)
**Spend**: ~$0.14 total — Bedrock ~$0.13 (Opus 4.7 baseline + BS-8 docker cp spike with terminal tool) + OpenAI ~$0.016 (GPT-5.5 BS-2 probe).
**Wall**: ~3h
**Status**: **9/12 BS questions resolved or PASS** (BS-1, 2, 3, 4, 5, 7, 8, 9, 10, 12); 2 deferred (BS-6 design call, BS-11 minor); 0 remaining blockers for Stage 1 entry.

## Headline result

**Tier-2 direct (`POST agent-server:8000/api/conversations`) is the integration path, not app-server tier-1.** When you POST `StartConversationRequest` directly with a fully-specified `agent.llm` block, Opus 4.7 + Bedrock works end-to-end with V1 SDK 1.19.1, no patches needed. The app-server's settings deep-merge (R-new-1) is the actual problem and is sidestepped entirely by going to tier-2.

Working LLM-input override for Opus 4.7:
```json
"llm": {
  "model": "bedrock/us.anthropic.claude-opus-4-7",
  "aws_region_name": "us-east-1",
  "temperature": 0.0,
  "reasoning_effort": null,
  "extended_thinking_budget": 0,
  "enable_encrypted_reasoning": false,
  "drop_params": true,
  "max_output_tokens": 128,
  "usage_id": "agent"
}
```

The first three are critical: V1 SDK defaults `reasoning_effort='high'`, `extended_thinking_budget=200000`, `enable_encrypted_reasoning=True`. The first triggers select_chat_options branches that don't fire correctly for opus-4-7 (not in EXTENDED_THINKING_MODELS); the second causes litellm to inject `thinking.type.enabled` which Bedrock rejects (`"thinking.type.enabled" is not supported. Use "thinking.type.adaptive" and "output_config.effort"`). Zeroing these on the explicit LLM input bypasses both. **Temperature=0.0 was accepted** — so V0's bc7.3 patch surface (temperature strip) is NOT needed on V1 IF we zero the thinking config. BS-1 has a clean answer without any litellm patches.

This doc is the Stage 0 results + a working runbook for bringing V1 up. Save next session from re-discovering the four wiring gotchas below.

---

## Pinned digest tuple (Stage 0.a — RESOLVED)

```
openhands-sdk:           1.19.1
openhands-agent-server:  1.19.1
openhands-tools:         1.19.1
agent-server image:      ghcr.io/openhands/agent-server:1.19.1-python
                          @ sha256:c80c8b0108392f7457bd4cf33bb9917fd9e3bc09f45eeb01fb9ac0822468ffe6
app-server image:        ghcr.io/openhands/openhands:1.7.0
                          @ sha256:916abcb15cc451d96853bd41c55117bb2ff3de0b9914cdcd861d338055798dc6
```

**Anchor**: app-server 1.7.0's `pyproject.toml` pins all three SDK packages to `==1.19.1`, and `openhands/app_server/sandbox/sandbox_spec_service.py` hard-codes `AGENT_SERVER_IMAGE = 'ghcr.io/openhands/agent-server:1.19.1-python'`. No upstream "tested-together" matrix; this `pyproject.toml` pin **IS** our matrix.

Skip-list: don't bump just `openhands-sdk` to 1.20.x — agent-server:1.20.x-python tag is missing on GHCR (pipeline skip). SDK 1.22.0 exists but no paired app-server release yet (only PR #14409). Stick to 1.19.1 + 1.7.0.

Fallback if 1.19.1 fails: SDK 1.15.0 + app-server 1.6.0.

---

## Working V1 setup recipe (runbook)

```bash
# 0. Pull pinned digests on the harness host
docker pull ghcr.io/openhands/agent-server@sha256:c80c8b0108392f7457bd4cf33bb9917fd9e3bc09f45eeb01fb9ac0822468ffe6
docker pull ghcr.io/openhands/openhands@sha256:916abcb15cc451d96853bd41c55117bb2ff3de0b9914cdcd861d338055798dc6

# 1. Start app-server. CRITICAL: --add-host host.docker.internal:host-gateway
#    is mandatory; without it, app-server can't reach the agent-server it spawns
#    and all conversations fail with "Sandbox server not running: ... Name or service not known".
docker run -d \
  --name oh-app-server \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AWS_REGION=us-east-1 \
  -e AWS_DEFAULT_REGION=us-east-1 \
  -e OH_AGENT_SERVER_ENV='{"AWS_REGION":"us-east-1","AWS_DEFAULT_REGION":"us-east-1"}' \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e AGENT_SERVER_IMAGE_TAG=1.19.1-python \
  ghcr.io/openhands/openhands@sha256:916abcb15cc451d96853bd41c55117bb2ff3de0b9914cdcd861d338055798dc6

# 2. Wait for /api/v1/health (≈17s on bc7 harness; returns HTML, not JSON)
# 3. POST /api/v1/settings — body MUST use *_diff keys, NOT legacy nested keys:
curl -X POST http://127.0.0.1:3000/api/v1/settings -H 'Content-Type: application/json' -d '{
  "agent_settings_diff": {
    "llm": {
      "model": "bedrock/us.anthropic.claude-opus-4-7",  -- NO -v1:0 suffix; see Gotcha #4
      "aws_region_name": "us-east-1"
    }
  }
}'
# Wrong keys produce HTTP 422 with body
#   {"error":"Use *_diff nested settings payloads instead of legacy keys","keys":["agent_settings"]}

# 4. POST a conversation:
curl -X POST http://127.0.0.1:3000/api/v1/app-conversations -H 'Content-Type: application/json' -d '{
  "title": "smoke",
  "agent_type": "default",
  "initial_message": {"role":"user","content":[{"type":"text","text":"say hello"}], "run": true}
}'
# Returns an AppConversationStartTask (status=WORKING), NOT a conversation.
# Poll /api/v1/app-conversations/start-tasks?ids=<task_id> — note returns a PLAIN ARRAY
# (jq: .[0]) — NOT a {items:[...]} envelope. Status transitions:
#   WORKING → WAITING_FOR_SANDBOX → READY (start-task lifecycle done; conversation lifecycle next)
# Once READY, .app_conversation_id is populated. Then poll
#   /api/v1/app-conversations?ids=<conv_id>  →  .[0].execution_status in {idle,running,finished,error,stuck}
# (lowercase; the v1-runtime-contract research said UPPERCASE which is wrong on 1.19.1)
```

### Four wiring gotchas (each one cost us 5–15 min)

1. **App-server can't resolve `host.docker.internal` without `--add-host host.docker.internal:host-gateway`.** The contract doc says docker-compose.yml uses `extra_hosts:`. Running with `docker run` standalone, you must add this manually or every conversation fails at sandbox-handshake. *Symptom*: app-server logs show `Sandbox server not running: http://host.docker.internal:NNNN : [Errno -2] Name or service not known`.

2. **Don't re-tag the agent-server image with a local repo name.** I did `docker tag ghcr.io/openhands/agent-server@... oh/agent-server:1.19.1-python` early on. The app-server's sandbox-spec service registered the spec under one repo path while the sandbox container reported its image as the other path, so `sandbox.sandbox_spec_id` lookup at `live_status_app_conversation_service.py:308` returned None → `AssertionError`. Pull by digest only; let the canonical tag form. *Symptom*: bare `AssertionError` with stack at `assert sandbox_spec is not None`.

3. **Settings POST schema requires `agent_settings_diff` / `conversation_settings_diff`, NOT `agent_settings` / `conversation_settings`.** The legacy keys are explicitly rejected. *Symptom*: HTTP 422 with `{"error":"Use *_diff nested settings payloads instead of legacy keys"}`.

4. **Opus 4.7 Bedrock model string has NO `-v1:0` suffix.** V0 worked with `bedrock/us.anthropic.claude-opus-4-7-v1:0`. V1 with that string returns `BedrockException: The provided model identifier is invalid`. Correct is `bedrock/us.anthropic.claude-opus-4-7`. This is documented in bd memory `bedrock-inference-profile-naming` from 2026-05-08 — **check that memory first** when introducing any new Bedrock model. The memory note is exactly: "Opus 4.7's profile is the bare 'us.anthropic.claude-opus-4-7' (no version)".

---

## Sub-test outcomes (BS-1..BS-12)

| BS | Question | Outcome | Detail |
|---|---|---|---|
| BS-1 | Does V1 SDK strip temperature for Opus 4.7? | **✅ RESOLVED (different shape than V0)** | V0's specific failure (temperature rejection) does NOT fire on V1 *if* you zero the thinking config. Tier-2 conversation 050b3454 completed cleanly with `temperature=0.0` against Opus 4.7. The real V1 hazard is the *thinking-block leak* (default `extended_thinking_budget=200000` + `enable_encrypted_reasoning=True` → litellm sends `thinking.type.enabled` → Bedrock 400 with new-API guidance). Zeroing those at the LLM-input level fixes it cleanly — no SDK or litellm patches required. |
| BS-2 | GPT-5.5 + V1 SDK works? | **✅ RESOLVED** | Tier-2 conversation ffa51c94 completed in 5s with `openai/gpt-5.5`: prompt=3083, completion=10, cost=$0.0157. Required LLM-input overrides: `temperature=null` (V1 SDK default is None, so leave it; setting 0.0 would be rejected per GPT-5 quirks memory), `reasoning_effort=null`, `extended_thinking_budget=0` (irrelevant for OpenAI but consistent), `drop_params=true`, `max_output_tokens=512` (V1's max_output_tokens routes correctly without needing the V0 max_tokens→max_completion_tokens rename — litellm 1.84.x or V1 SDK handles it). The 3wi patch surface (V0 stop-word gate) is NOT needed because we don't pass `stop` in our request. API key threaded via `agent.llm.api_key` directly (NOT via secrets dict — secrets dict path remains untested but Stage 1 can revisit if needed for keys-rotation reasons). |
| BS-3 | Does `Conversation.run()` support max_iterations? | **✅ YES** | First-class field on StartConversationRequest (tier-2); default 500, configurable per-conversation. Confirmed: `max_iterations: 3` honored in the smoke conversation. |
| BS-4 | Trajectory layout — does V0 regex match? | **✅ YES** | Path: `/workspace/conversations/<32-char-hex>/`. Conv ID is UUID stripped of dashes, exactly matching the V0 regex `[0-9a-fA-F]{32}$`. Per-conversation files: `owner_lease.json`, `base_state.json`, `meta.json`, `.owner_lease.lock`, `events/` subdir. W-7 in the plan (post-bug-#4 regex) keeps the same shape. |
| BS-5 | Can agent-server reach docker0 cybergym.server? | **✅ YES** | From inside a live agent-server container: `curl http://172.17.0.1:8666/_probe` → HTTP 404 in 6ms. `curl http://host.docker.internal:8666/_probe` → HTTP 404. Both routing paths (docker0 IP and the named-host alias) reach the host's cybergym.server. The 404 is the cybergym route validating — transport works. V0's `CYBERGYM_SERVER_URL_FOR_AGENT` pattern carries over unchanged. |
| BS-6 | How does cybergym.server URL get into the agent task? | **DEFERRED** to Stage 1 design (prompt-thread vs workspace-file vs secrets). |
| BS-7 | Are containers reaped on DELETE? | **✅ YES (with caveat — TWO deletes needed)** | The two-step lifecycle: `DELETE /api/v1/app-conversations/{conv_id}` returns success but **does NOT reap the sandbox container**. `DELETE /api/v1/sandboxes/{id}?sandbox_id={id}` (yes, the id appears as BOTH path param AND query param — quirky) properly tears down the container + named workspace volume. Tested: 3 sandboxes → DELETE one → 2 sandboxes; container was reaped. R-5 in the plan needs an update: cybergym runner must explicitly call both endpoints in `finally`. |
| BS-8 | Workspace injection for external paths? | **✅ RESOLVED — use `docker cp`** | Spike confirmed: spawn sandbox via app-server (sets up `/workspace/project` as an empty git repo owned by `openhands` UID), then `docker cp <host-task-dir>/. <sandbox>:/workspace/project/` BEFORE starting the conversation. Files land world-readable; agent's terminal tool reads + executes them cleanly. Verified end-to-end with Opus 4.7: spike conversation finished (cost=$0.085, prompt=22973, completion=786 — real work happened across multiple turns). Cleanup also clean: two-step DELETE (conversation + sandbox) brought containers to 0. **Caveat**: `/workspace/project` is initialized as a `.git` repo by the app-server; cybergym integration should be aware (don't blow it away unless intentional). The other two options — file-upload API and sandbox-spec `mounts` field — remain untested but no longer block Stage 1 since docker cp works. |
| BS-9 | Bedrock cross-region profile string? | **✅ RESOLVED (and was in bd memory)** | Correct: `bedrock/us.anthropic.claude-opus-4-7` (NO `-v1:0` suffix). bd memory `bedrock-inference-profile-naming` from 2026-05-08 had this — check that memory first when introducing any new Bedrock model. |
| BS-10 | Pinned tuple verified? | **✅ YES** | App-server 1.7.0 + agent-server 1.19.1-python boots clean. Sandbox <10s to RUNNING; exposes 8000/8001/8011/8012; all health probes return 200. Tier-2 LLM call succeeds. Tuple holds end-to-end. |
| BS-11 | Stuck-loop detection? | **DEFERRED** — not exercised. SDK has `stuck_detection=true` default per StartConversationRequest. |
| BS-12 | Bedrock IAM forwarding works? | **✅ YES** | Instance-role creds flow cleanly through app-server (`AWS_REGION` env) → agent-server (`OH_AGENT_SERVER_ENV` JSON) → litellm boto3 client. Proven by the successful conversation reaching Bedrock's Converse API and returning real tokens (cost=$0.0424, prompt_tokens=5699). No extra wiring needed. |

---

## Newly-discovered risks

| ID | Risk | Likelihood | Impact | Status / Mitigation |
|---|---|---|---|---|
| **R-new-1** | **Settings-to-agent propagation gap (app-server tier).** `POST /api/v1/settings` with `agent_settings_diff.llm.extended_thinking_budget=0` etc. is reflected in `GET /api/v1/settings`, but the conversation/agent that gets spawned receives the SDK defaults instead. App-server's settings deep-merge → agent factory hop drops our values somewhere. | HIGH | LOW (with workaround) | **Workaround = tier-2 direct.** Going to `agent-server:8000/api/conversations` with a fully-specified `agent.llm` bypasses the propagation. This is the cybergym integration path anyway (and BS-8 favors tier-2 since app-server has no clean workspace-mount surface). The propagation gap itself is left unfixed — file as an upstream bug if/when our adapter outgrows tier-2 direct. |
| **R-new-2** | **Extended-thinking-block leak.** V1 SDK defaults `extended_thinking_budget=200000` and `enable_encrypted_reasoning=True`. For Anthropic models (Bedrock or direct), this causes litellm to inject `thinking: {type: enabled, budget_tokens: 200000}` into the Converse body. Bedrock-Opus-4.7 rejects this with new-API guidance (`use thinking.type.adaptive`). | HIGH | LOW (with override) | **Workaround**: set `extended_thinking_budget=0` + `enable_encrypted_reasoning=false` on the LLM input. No litellm patch needed. The V0 `_litellm_patches.py` route is also available as a fallback if the tier-2 path doesn't carry the override cleanly to GPT-5.x in Stage 2. |
| **R-new-3** | **Sandbox lifecycle requires TWO deletes.** `DELETE app-conversations/{id}` only removes the conversation; the sandbox + container live on. Caller must additionally `DELETE sandboxes/{id}?sandbox_id={id}` to reap. Without this, containers accumulate. | HIGH (without explicit cleanup) | MEDIUM (resource leak on cybergym-10) | **Mitigation**: cybergym runner's `finally` block must call both endpoints per task. R-5 in §5 of the plan needs updating to reflect the two-step lifecycle. |
| **R-new-4** | **No host bind mount on V1 sandboxes.** `docker inspect` shows empty `Mounts` and `Binds` — V1 sandbox FS is fully internal. Cybergym's per-task workspace (≥100MB of source/binaries) cannot be mounted via volume; must be uploaded via API or pushed via `docker cp`. | MEDIUM | MEDIUM | **Mitigation**: Stage 1 picks between file-upload API (`POST app-conversations/{id}/file`) and host-side `docker cp` post-spawn. The second is cheaper but couples to docker-CLI access; the first is cleaner but requires per-file POSTs. Decide at Stage 1 entry. |

---

## Concrete actions for next session (Stage 1 entry)

Stage 0 is **complete enough to unblock Stage 1**. The remaining items (BS-2, BS-6, BS-8 strategy, BS-11) are best resolved as Stage 1 design decisions or Stage 2 LLM-threading work.

1. **Stage 1 adapter shape — confirmed**: harness host runs app-server (for sandbox lifecycle: `POST /api/v1/app-conversations` to spawn, `DELETE /api/v1/sandboxes/{id}?sandbox_id=...` to reap). Then for each cybergym task:
   - Spawn sandbox (placeholder app-conversation; just need the sandbox to come up)
   - Wait for sandbox status RUNNING + session_api_key available
   - `docker cp <task-data-dir>/. <sandbox_id>:/workspace/project/` to inject cybergym task files (BS-8 confirmed)
   - `POST <agent-server>:8000/api/conversations` with full `StartConversationRequest` carrying the right LLM-input overrides for the target model
   - `POST .../run`, then poll `GET .../api/conversations/{id}` for `execution_status` in `{finished,error,stuck}`
   - Extract events, token usage, trajectory from `/workspace/conversations/<conv_id_no_dashes>/`
   - DELETE conversation, DELETE sandbox (both calls required — R-new-3)
2. **Thread cybergym.server URL via initial_message** (BS-6). The agent reaches `http://172.17.0.1:8666` natively (BS-5 confirmed); just put the URL in the prompt: "When you have a PoC, submit via `bash submit.sh <agent_id>` which curls to http://172.17.0.1:8666." The submit.sh comes with cybergym task data and is injected by step 3.
3. **LLM-input override defaults to bake into the adapter** (BS-1, BS-2): for ALL models, set `reasoning_effort=null`, `extended_thinking_budget=0`, `enable_encrypted_reasoning=false`, `drop_params=true`. Per-model: Opus 4.7 → `model=bedrock/us.anthropic.claude-opus-4-7`, `aws_region_name=us-east-1`, `temperature=0.0` (accepted). GPT-5.5 → `model=openai/gpt-5.5`, `api_key=<from secrets-dict or direct>`, `temperature=null` (default rejects 0.0).
4. **No litellm patches required for V1.** This is a clean break from V0 where bc7.3 + 3wi were needed. The V1 path uses the LLM-input override mechanism instead. `_litellm_patches.py` stays for the V0 path until Stage 5 cutover.
5. **BS-11 (stuck detection)** deferred — `stuck_detection=true` is the default on StartConversationRequest. The execution_status terminal value `stuck` is what gets returned; runner just needs to handle it like `error`.

### Cleanup TODO

- 3 leftover agent-server containers on harness `<HARNESS_INSTANCE_ID>` (from initial broken attempts) — reap via:
  ```bash
  ssh <HARNESS_INSTANCE_ID> 'for s in $(curl -s http://127.0.0.1:3000/api/v1/sandboxes/search | jq -r .items[].id); do curl -s -X DELETE "http://127.0.0.1:3000/api/v1/sandboxes/$s?sandbox_id=$s"; done'
  ```
- Cybergym sidecar server (pid in `/home/ubuntu/m7v-stage0/server_poc/cybergym-server.pid`) still running on port 8666 — fine to leave for next session, or kill.

---

## Process retrospective (1h spend on a "1h" plan)

What burned time:
- **Re-derivation rather than checking prior work.** The Bedrock model-string fix was in bd memory `bedrock-inference-profile-naming` from 2026-05-08. I didn't check it before sending the wrong string. Cost: ~10 min.
- **Sequential iteration through unrelated failure modes.** Each gotcha (DNS, re-tag, settings schema, model string) compounded into the next via "fix one, retry, see next error". Most could not be parallelized because they're a chain.
- **One genuine mistake**: typed `bd remember <key>` thinking it was a read, which clobbered the body. `bd recall <key>` is the read. Saved as bd memory `bd-recall-vs-remember-confusion-2026-05-14`.

What sped things up:
- Subagent for Stage 0.a digest research ran concurrently with my probing of the harness — saved ~5 min.
- Reading OpenAPI spec on the running app-server (`/openapi.json`) was faster than reading SDK source.
- Direct `ssh i-...` (proxied through SSM) faster than `ssm send-command` for iterative probes — operator hint.

For next session: **before writing fresh integration code, check (a) bd memories for the topic, (b) prior commit messages on the same surface, (c) the running app-server's OpenAPI**.
