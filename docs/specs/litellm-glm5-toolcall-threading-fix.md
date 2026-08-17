# Spec: Fix tool-call ID threading for glm-5-2 (Tinfoil) through LiteLLM

**Audience:** infra agent owning the self-hosted LiteLLM proxy + Tinfoil inference path.
**Status:** mitigation and validation procedure prepared; live apply is **ON HOLD**
until the concurrent `eb5-4-mtx5-*` evaluation driver is explicitly finished. Root
localization still requires a raw enclave response or Tinfoil serving details.
**Owning repo:** `~/internal-network-stuff/dreadnode` (deploy) + the LiteLLM model
registration in the `litellm` Postgres schema (Admin UI, `store_model_in_db=true`).
**Tracking:** benchmarks-eb5.13 (this bug, **P3 serving hygiene**). Root-cause notes on
eb5.10.

> ## SEVERITY / SCOPE CORRECTION — read first
> This is **P3 serving hygiene, not a run blocker.** A sonnet-5 control on the identical
> task/runtime/cap (eval `16628238`) **failed the same way** (early stop at 16/50, empty
> final turn, no PoC) with **perfectly clean tool-call threading — 0 orphans.** So the
> *run failure* is a **model-agnostic agent-loop early-stop** (no solver stopping-gate),
> tracked separately as **benchmarks-eb5.12 (P1)** — NOT this tool-call issue. The
> orphaning described below is **real and glm-serving-specific** (sonnet's Anthropic path
> had zero), but it did **not** cause the failure and is **not** the eb5.4 blocker. Fix
> this to keep open-weight tool-heavy runs honest; do **not** treat it as the thing
> standing between you and valid uplift numbers (that's eb5.12).

---

## 1. Symptom (reproducible from artifacts)

SEC-bench eval run `b545a826` (model `dn/ipnts-tinfoil-glm-5-2`, njs-cve-2022-32414,
50-step cap) ended at **13 generation steps** with `stop_reason: finished` and no
final answer. Trace analysis (ATIF session export) shows:

- The **final agent turn** recorded **1 threaded tool call (`think`)** but **3 tool
  results**, of which **2 had `source_call_id: null`** — orphaned results whose
  originating tool calls were not linked.
- The 12 preceding turns (many of them 2-call parallel turns) threaded **cleanly**:
  every `tool_call.id` matched a `tool_result.source_call_id`.

So the defect is **intermittent**, not "all glm parallel calls break." A minority of
tool calls emitted by the glm-5-2 endpoint reach the agent with a **missing/duplicate/
unparseable `id` and/or `function.name`**, so their results cannot be paired.

**Contrast control (same task/runtime/cap):** `dn/claude-sonnet-5` (eval `16628238`)
did parallel multi-tool turns with **0 orphans, 0 mismatches**. The break is specific
to the glm-5-2 serving path, not the Dreadnode agent loop.

### Why it ends the run — NOT this issue (corrected)

The Dreadnode agent loop stops when a generation yields an assistant turn with no
*actionable* tool calls (`dreadnode/agents/agent.py:985`; no stop-conditions → `break`).
Both glm-5-2 and the sonnet-5 control hit this — and **sonnet had 0 orphaned tool
calls**, so the early stop is **independent of the threading defect**. The run-ending
behavior is the **solver stopping-gate** problem (**benchmarks-eb5.12, P1**), not this.
This spec is scoped strictly to the **tool-call ID threading** at the glm serving layer,
which is hygiene (eb5.13, P3). Do not conflate them.

---

## 2. Topology (where the parsing actually happens)

```
Dreadnode SDK (non-streaming litellm.acompletion, tools=[...])
  → generators/proxy.py  →  LiteLLMGenerator (custom_llm_provider = "litellm_proxy")
  → self-hosted LiteLLM proxy (deploy/k8s/litellm, DHI image, model_list=[] — models
      registered at runtime in the `litellm` Postgres schema via Admin UI)
  → api_base → tinfoil-proxy (attestation-verifying reverse proxy, :3301,
      allowed-host tinfoil-proxy.dreadnode.svc.cluster.local)
  → Tinfoil confidential-model-router enclave (OpenAI-compatible /v1, vLLM-style
      serving of glm-5-2)
```

Key facts that constrain the fix:

- **The SDK calls are non-streaming.** LiteLLM returns a single `ModelResponse`; the
  SDK reads `choice.message.tool_calls` as `ChatCompletionMessageToolCall` objects and
  requires each to have a stable, unique `id` plus `function.name` +
  `function.arguments` (`generators/generator/litellm_.py::_parse_model_response`).
  Streaming-delta reassembly is therefore **not** in the path — rule it out.
- **The tinfoil-proxy is a pass-through** for `Authorization` and body; it does not
  transform tool calls. It is not the parser. (It *can* 400/403 on Host/Origin — not
  our symptom.)
- **The enclave serves an OpenAI-compatible API.** If glm-5-2 is served by vLLM inside
  the enclave, the model's *native* tool-call syntax (GLM/Hermes-style) is parsed into
  OpenAI `tool_calls[]` by **vLLM's `--tool-call-parser` + the model chat template**,
  *before* LiteLLM ever sees it. LiteLLM for an `openai/*`-class provider largely
  **passes those through**. This is the crux for fix localization.

---

## Step 1 — PARTIAL RESULT (§3A done, read-only, 2026-07-19)

The LiteLLM-registration half of Step 1 (§3A) has been captured read-only from the
running proxy (`kubectl -n dreadnode exec dreadnode-litellm-… -- python3` →
`localhost:4000/v1/model/info` with `$LITELLM_MASTER_KEY`; the DHI image has no
curl/wget). Findings for `dn/ipnts-tinfoil-glm-5-2`:

| field | value |
|-------|-------|
| `model` | `openai/glm-5-2` (OpenAI-compatible pass-through adapter — correct) |
| `api_base` | `http://tinfoil-proxy.dreadnode.svc.cluster.local:3301/v1` |
| `parallel_tool_calls` | **unset** |
| `additional_drop_params` | **unset** |
| `supports_parallel_function_calling` | **unset** |
| `merge_reasoning_content_in_choices` | `true` |

`kimi-k2-6` has the identical shape. `model_list: []` + `turn_off_message_logging:
true` confirmed on the configmap, matching §2.

**Interpretation:** the §4B-i mitigation lever is genuinely un-applied and the
adapter is a clean pass-through, so the orphaned `source_call_id: null` results
arrive through LiteLLM **unmodified** — consistent with §4A (enclave vLLM parser on
parallel batches) as root cause, not a LiteLLM double-transform. **Still owed:** the
§3B raw enclave capture (needs a canary proxy / in-cluster write access — not done
from the benchmarks runtime) to decide §4A vs §4B definitively.

### Prepared-resolution facts (read-only, 2026-07-20)

- The running proxy is LiteLLM `v1.91.0`, one replica, with a `RollingUpdate`
  deployment strategy.
- The GLM deployment is DB-backed with model id
  `3e355ba9-7bda-4867-8518-76bdb2986c5c` and named credential
  `tinfoil-api-key`. Re-resolve the id immediately before any change; do not extract
  or print the credential value.
- LiteLLM `v1.91.0` accepts deployment extras in `litellm_params`. Its completion
  path merges deployment params first and request params second, so
  `parallel_tool_calls: false` becomes a per-model default while preserving an
  explicit request override. The current Dreadnode path omits the field, so the
  deployment default applies.
- The supported partial-update endpoint is
  `PATCH /model/{model_id}/update`. It deep-merges the supplied `litellm_params`,
  writes the DB row, clears the router cache, and deletes/re-adds **all DB-backed
  model registrations in-process**. It does not require a pod restart, but that
  all-model reload is still a shared inference hazard.
- At the time of inspection, two `eb5-4-mtx5-*` evaluations were running. The
  coordination comment promises a later `MATRIX_DONE` update. A momentary zero in
  `dn evaluation list` is not enough because the driver can launch the next pair.

Therefore: **do not apply §4B, reload LiteLLM, restart the proxy/API, run Helm, or
start a heavy sandbox until the matrix owner posts `MATRIX_DONE` and both running and
queued evaluation lists are empty.** Read-only inspection and document preparation
remain safe.

---

## 3. Step 1 — Localize the defect (do this first; decides the fix branch)

The orphan can originate in one of two layers. Determine which:

**A. Check how glm-5-2 is registered in LiteLLM** (Admin UI → Model Deployments, or
the `litellm` Postgres `model_list`/`LiteLLM_ProxyModelTable`):
- `litellm_params.model` prefix (`openai/…`, `hosted_vllm/…`, or custom),
- `api_base` (should be the tinfoil-proxy Service FQDN),
- any `additional_drop_params`, `supports_parallel_function_calling`, or tool-related
  flags currently set.

**B. Capture one raw enclave response with tool calls.** `turn_off_message_logging:
true` is set on the proxy (configmap.yaml) so bodies are scrubbed — you must capture
out-of-band. Options:
- temporarily set `litellm_settings.turn_off_message_logging: false` on a
  throwaway/canary proxy (NOT the security-traffic proxy) and replay a tool-using
  request, **or**
- `curl` the tinfoil-proxy `/v1/chat/completions` directly (in-cluster, with a tools
  payload that induces a parallel call) and inspect the raw JSON.

**Decision:**
- If the **raw enclave JSON already has malformed `tool_calls`** (missing/blank `id`,
  blank `function.name`, or duplicate ids across a parallel batch) → root cause is the
  **enclave vLLM tool-call parser / chat template** (§4A). LiteLLM can only mitigate.
- If the **raw enclave JSON is well-formed** but the object LiteLLM hands back has null
  ids → root cause is **LiteLLM's provider transformation** for this model class (§4B).

Given the intermittency + parallel-batch correlation, **§4A (enclave parser) is the
most likely root cause.** The official vLLM GLM-5/5.1 serving recipe currently uses
`--tool-call-parser glm47`, `--reasoning-parser glm45`,
`--chat-template-content-format=string`, and recommends current vLLM main when MTP
is enabled. Adjacent upstream defects make the serving flags/version especially
important here:

- vLLM issue [#34449](https://github.com/vllm-project/vllm/issues/34449) reports
  MTP speculative decoding duplicating/mangling structured tool-call JSON for GLM-5;
  disabling MTP was the working comparison.
- vLLM issue [#39614](https://github.com/vllm-project/vllm/issues/39614) reports
  multi-turn GLM-5.1 tool-result corruption when chat-template content format is
  `auto`; `string` is the documented workaround.
- vLLM issue [#42400](https://github.com/vllm-project/vllm/issues/42400) reports
  intermittent GLM-5.1 tool parsing with the `glm47`/`glm45` parser combination.
  Its streaming/Anthropic path is not identical to this non-streaming/OpenAI path,
  so treat it as supporting evidence, not proof of the same bug.

Confirm the raw payload and serving flags before declaring a root cause.

---

## 4. Fix

### 4A. If the enclave emits malformed tool calls (most likely) — root fix at serving

The GLM tool-call format is not being parsed into unique, complete OpenAI
`tool_calls` for at least one parallel batch. Ask Tinfoil for the raw response and
the exact confidential-router serving tuple:

1. vLLM/router image version and commit;
2. `--tool-call-parser`, `--reasoning-parser`, and
   `--chat-template-content-format` values;
3. whether MTP/speculative decoding is enabled, including token count/config;
4. the raw OpenAI response for a failing parallel tool batch.

If MTP is enabled, first reproduce with MTP disabled or with a vLLM revision that
contains the current GLM-5 tool fixes. Independently require the official GLM pairing
(`glm47` tool parser, `glm45` reasoning parser, content format `string`) unless
Tinfoil documents a GLM-5.2-specific replacement. Verify that every emitted call has
a non-empty, batch-unique `id`, non-empty function name, and valid arguments.

If the enclave image is fixed/opaque and cannot be reconfigured, ship §4B as the
bounded mitigation and file the upstream ticket with Tinfoil. Do not describe §4B as
the root fix.

### 4B. LiteLLM-side fix / mitigation (what you asked to ship)

Two independent changes, both at the LiteLLM registration for `dn/ipnts-tinfoil-glm-5-2`:

**(i) Disable parallel tool calls for this model (primary mitigation).**
Force one tool call per turn, which removes the parallel-batch id-collision source
entirely. On the model's `litellm_params`:
```yaml
# model deployment: dn/ipnts-tinfoil-glm-5-2
litellm_params:
  model: openai/glm-5-2          # confirm actual prefix in Step 1
  api_base: http://tinfoil-proxy.dreadnode.svc.cluster.local:3301/v1
  # New:
  parallel_tool_calls: false
```
Notes:
- `parallel_tool_calls: false` must be **sent to the endpoint** to take effect — if the
  enclave ignores or rejects it, this mitigation is unavailable and you must do 4A.
  Verify in the raw capture or probe trajectory that the model emits at most one call
  per assistant turn.
- **Do not add `parallel_tool_calls` to `additional_drop_params`.** LiteLLM would strip
  the field before forwarding it, which restores the upstream default and defeats the
  mitigation.
- The Dreadnode SDK also has a `GenerateParams.parallel_tool_calls` field
  (`generators/generator/base.py:230`) but it is **not currently plumbed** to any eval/
  runtime/CLI knob, so setting it at the LiteLLM deployment is the only lever available
  without an SDK code change. (An SDK change to thread it per-model is a possible
  parallel track — out of scope for this spec.)

**(i-b) "Behaves like" in the LiteLLM model-deployment UI — a §4B lever ONLY.**
The Admin-UI "behaves like `<provider>`" selects which LiteLLM **provider adapter** does
the request/response transform (equivalent to the `model:` prefix). It governs how the
raw response is parsed into `tool_calls[]` with `id`/`name`/`arguments`.
- First, **verify the current setting matches an OpenAI-compatible endpoint** — the
  Tinfoil enclave speaks plain OpenAI `/v1`, so the intended setting is "behaves like
  OpenAI" (pass-through) with `api_base` at the tinfoil-proxy. A mismatched adapter that
  double-transforms can itself mangle tool calls.
- Trying an alternate "behaves like" is a **fast §4B probe**, but it **cannot fix a
  payload that is already malformed at the enclave (§4A)** — no adapter can reconstruct
  ids the enclave never assigned. If you switch it and orphans persist, that is a useful
  **negative result** that confirms §4A (enclave parser) and redirects effort there.

**(ii) Guarantee complete tool-call objects out of LiteLLM.**
If Step 1 shows LiteLLM (not the enclave) is nulling `id`/`function.name`, the fix is in
LiteLLM's transformation for this provider class:
- Ensure every returned `tool_calls[i]` has a non-empty `id` (synthesize a stable
  `call_<n>` if the provider omitted it) and a non-empty `function.name`.
- Ensure ids are **unique within a message** (the parallel-batch collision case).
- This is a LiteLLM provider-adapter change; prefer upstreaming to BerriAI/litellm for
  the specific provider rather than a local monkeypatch, unless you already carry a
  LiteLLM overlay.

---

## 5. Post-matrix apply and rollback procedure

### 5.1 Hard coordination gate

Proceed only after the matrix owner has posted a **new** `MATRIX_DONE` comment on
`benchmarks-eb5.13`. Then require both commands to print `0`:

```bash
dn evaluation list --status running --limit 100 --json | jq 'length'
dn evaluation list --status queued --limit 100 --json | jq 'length'
```

Also coordinate the window with the platform owner: LiteLLM is shared beyond the
visible project, and the PATCH reloads every DB model registration in-process.

### 5.2 Snapshot and re-resolve the target

Fetch `/v1/model/info` from localhost inside the LiteLLM pod and retain only this
deployment's non-secret record. Confirm the id, `model`, `api_base`, and named
credential before patching. The 2026-07-20 id is shown above only as a cross-check,
not a forever-stable identifier.

```bash
kubectl -n dreadnode exec deploy/dreadnode-litellm -- python3 -c '
import os, urllib.request
request = urllib.request.Request(
    "http://localhost:4000/v1/model/info",
    headers={"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"]},
)
print(urllib.request.urlopen(request, timeout=30).read().decode())
' | jq '
.data[]
| select(.model_name == "dn/ipnts-tinfoil-glm-5-2")
| {
    model_id: .model_info.id,
    model_name,
    model: .litellm_params.model,
    api_base: .litellm_params.api_base,
    credential: .litellm_params.litellm_credential_name,
    parallel_tool_calls: .litellm_params.parallel_tool_calls,
    additional_drop_params: .litellm_params.additional_drop_params
  }'
```

### 5.3 Apply the minimal partial PATCH

Send only this body to `PATCH /model/{fresh-model-id}/update`:

```json
{"litellm_params":{"parallel_tool_calls":false}}
```

The endpoint's partial-merge implementation preserves the existing model, base URL,
credential reference, pricing, and model info. Do not use the older full-record
`POST /model/update`, the Admin UI's broad save payload, or a Helm rollout for this
change.

After substituting the freshly resolved id, the exact write is:

```bash
eb513_model_id='<fresh-model-id-from-5.2>'
jq -cn '{litellm_params:{parallel_tool_calls:false}}' \
  | kubectl -n dreadnode exec -i deploy/dreadnode-litellm -- python3 -c '
import os, sys, urllib.request
request = urllib.request.Request(
    "http://localhost:4000/model/" + sys.argv[1] + "/update",
    data=sys.stdin.buffer.read(),
    headers={
        "Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
        "Content-Type": "application/json",
    },
    method="PATCH",
)
print(urllib.request.urlopen(request, timeout=30).read().decode())
' "$eb513_model_id" \
  | jq '{model_id,model_name,parallel_tool_calls:.litellm_params.parallel_tool_calls}'
```

Immediately re-read `/v1/model/info` and require:

```json
{"parallel_tool_calls":false,"additional_drop_params":null}
```

If the PATCH errors, the upstream rejects the forwarded field, or the probe still
emits parallel batches, stop and use §4A. Do not hide the failure by dropping the
parameter.

### 5.4 Rollback

The same partial PATCH with `parallel_tool_calls: true` restores the prior effective
upstream behavior without touching other fields. This leaves an explicit `true`
rather than returning to the prior "unset" representation; exact field removal
requires an operator-reviewed full-record update. Re-run the model-info read after
rollback.

---

## 6. Validation (must pass before declaring fixed)

Re-run the exact probe and assert on the trace, not on pass/fail:

```
dn evaluation create \
  --capability ipnts/benchmark-solvers@0.5.0 \
  --task secbench-njs-cve-2022-32414 \
  --model dn/ipnts-tinfoil-glm-5-2 \
  --runtime-id 2ab0ecb0-3d14-41b4-aeab-3a63a6c60bd3 \
  --max-steps 50
```

Then export the session (`dn session export <sid>`) and run this ATIF checker:

```bash
dn session export <sid> --json | jq '
[
  .steps[]
  | [(.tool_calls // [])[] | (.tool_call_id // .id)] as $calls
  | [(.observation.results // [])[] | .source_call_id] as $results
  | {
      step_id,
      call_count: ($calls | length),
      result_count: ($results | length),
      null_call_ids: ([$calls[] | select(. == null)] | length),
      null_result_ids: ([$results[] | select(. == null)] | length),
      duplicate_call_ids:
        ([$calls | sort | group_by(.)[] | select(length > 1) | .[0]]),
      orphan_result_ids:
        ([$results[] | . as $rid
          | select($rid != null and ($calls | index($rid) | not))])
    }
  | select(
      .call_count != .result_count
      or .null_call_ids > 0
      or .null_result_ids > 0
      or (.duplicate_call_ids | length) > 0
      or (.orphan_result_ids | length) > 0
    )
]'
```

`[]` is the only passing result. The checker was regression-tested against the
existing artifacts: GLM session `3e814e1b` reports step 15 with 1 call, 3 results,
and 2 null result ids; sonnet session `f1d4bf1f` reports `[]`.

Assert:
1. **Zero orphaned results:** every `observation.results[].source_call_id` is non-null
   and matches a `tool_calls[].tool_call_id` in the same step. (This is the direct
   defect — the primary gate.)
2. **Per-step call/result parity:** `len(tool_calls) == len(results)` for every agent
   step.
3. **No premature stop attributable to threading:** run reaches a real terminal state
   (writes/does-not-write a PoC on its own merits), not a `finished` at a low step count
   with an empty final turn caused by dropped calls.
4. Run it **2–3×** — the defect is intermittent, so a single clean run is necessary but
   not sufficient.
5. With the mitigation active, confirm every assistant step has at most one tool call;
   otherwise the upstream ignored `parallel_tool_calls: false`.

**Cross-model regression:** confirm `dn/claude-sonnet-5` on the same task still shows 0
orphans (it does today — don't regress the Anthropic path if you touch shared LiteLLM
config).

**Generalize:** the DGX-served open-weight models (`hosted_vllm` Qwen3.6, Gemma-4 on
8080–8089) use the same vLLM-parser mechanism and are likely to have the same class of
bug. Apply the same Step-1 check + 4A parser pinning to them before the eb5.4 open-weight
matrix, or the uplift numbers will be silently corrupted by early truncation.

---

## 7. Scope boundaries

- **In scope:** tool-call ID threading for glm-5-2 (and, by extension, the other
  vLLM-served open-weight models) so parallel tool batches thread cleanly.
- **Out of scope (separate issues, already tracked on eb5.10):**
  - the agent-loop early-stop on an empty assistant turn (wants a solver stopping-gate),
  - the runtime capability version-precedence surprise,
  - network isolation of eval sandboxes (anti-cheat).
- **Open question to resolve in Step 1:** enclave-parser (4A) vs LiteLLM-transform (4B)
  as root cause. The evidence (intermittent, parallel-batch-correlated, OpenAI-compatible
  vLLM serving) points to 4A; confirm before shipping so you fix the root, not just the
  symptom.
