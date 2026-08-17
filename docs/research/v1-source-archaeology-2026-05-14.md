# V1 Source Archaeology — 2026-05-14

Research axis: V1 LLM source structure & patch surface mapping.
Deliverable for bd issue `of4` (OpenHands V1 migration planning).

Discipline: every substantive claim below cites a primary source. Claims not reachable by direct WebFetch are marked `[UNVERIFIED]` and flagged for smoke.

---

## 1. Verification of `openhands/llm/llm.py` Deletion

**Confirmed. The deletion is real.**

- PR #14154 ["Remove openhands.llm package (legacy V0 code)"](https://github.com/All-Hands-AI/OpenHands/pull/14154) merged **2026-04-27**.
  - Commit SHA: `aea6116` [commit:aea6116]
  - The PR diff (fetched directly) shows `deleted file mode 100644` for `openhands/llm/llm.py`.
  - Full list of deleted files: `openhands/llm/__init__.py`, `openhands/llm/async_llm.py`, `openhands/llm/debug_mixin.py`, `openhands/llm/fn_call_converter.py`, `openhands/llm/llm.py`, `openhands/llm/llm_registry.py`, `openhands/llm/llm_utils.py`, `openhands/llm/model_features.py` (plus router subdirectory). Total deletion: ~6,800 lines. [PR #14154]
  - The `openhands/llm/metrics.py` was *relocated* (not deleted) → `openhands/events/metrics.py`, because Cost/Metrics/ResponseLatency/TokenUsage classes were still used by the event system.
- The current `openhands/` directory (as of HEAD `e7b5e30`, 2026-05-14) contains subdirectories `analytics/`, `app_server/`, `server/` — no `llm/` directory. [github.com/All-Hands-AI/OpenHands/tree/main/openhands]
- PR #14239 "Remove legacy LLMConfig and all related code" (closed 2026-04-30) and PR #14252 "Remove openhands.core package" (closed 2026-05-01) represent the broader V0-cleanup sweep in the same window. [github.com/All-Hands-AI/OpenHands/pulls]

**Matrix doc claim status: CONFIRMED.** The deletion happened exactly as described.

---

## 2. V1 LLM Module Structure

### Package location

All LLM logic migrated to the `openhands-sdk` package (PyPI: `openhands-sdk`; GitHub: [OpenHands/software-agent-sdk](https://github.com/OpenHands/software-agent-sdk)).

- The main `openhands-sdk` source tree lives at `openhands-sdk/openhands/sdk/`. [github.com/OpenHands/software-agent-sdk/tree/main/openhands-sdk]
- The `llm/` subdirectory at `openhands-sdk/openhands/sdk/llm/` contains: [github.com/OpenHands/software-agent-sdk/tree/main/openhands-sdk/openhands/sdk/llm]

```
llm/
  __init__.py
  fallback_strategy.py
  llm.py                    ← main LLM class (1,726 lines)
  llm_profile_store.py
  llm_registry.py
  llm_response.py
  message.py
  streaming.py
  auth/
  exceptions/
  mixins/
    fn_call_converter.py    ← STOP_WORDS constant + _fix_stopword()
    fn_call_examples.py
    non_native_fc.py
  options/
    __init__.py
    chat_options.py         ← select_chat_options() — parameter scrubbing
    common.py               ← apply_defaults_if_absent()
    responses_options.py
  router/
  utils/
    image_resize.py
    litellm_provider.py
    metrics.py
    model_features.py       ← get_features(), SUPPORTS_STOP_WORDS_FALSE_MODELS
    model_info.py
    model_prompt_spec.py
    responses_serialization.py
    retry_mixin.py
    telemetry.py
    unverified_models.py
    verified_models.py      ← VERIFIED_OPENHANDS_MODELS list
```

### Key functions for parameter scrubbing

**`select_chat_options(llm, user_kwargs, has_tools)`** in `openhands-sdk/openhands/sdk/llm/options/chat_options.py`:

This is the V1 equivalent of V0's pre-call parameter mutation block in `llm.py`. It is called inside `completion()` before `_transport_call()`. Full source verified via raw GitHub fetch.

Key behaviors:
1. Applies defaults from LLM config (top_k, top_p, temperature, max_completion_tokens).
2. Azure path: renames `max_completion_tokens` → `max_tokens`.
3. **Reasoning model path**: calls `get_features(llm.model).supports_reasoning_effort`. If true AND model is not Gemini: **pops `temperature` and `top_p` from kwargs**. [chat_options.py, lines ~50-60]
4. Extended thinking path (Anthropic): pops temperature and top_p when `supports_extended_thinking` is true.
5. Tool stripping: removes `tools`/`tool_choice` when `has_tools=False`.
6. No explicit stop-word injection occurs here.

**`get_features(model)`** in `openhands-sdk/openhands/sdk/llm/utils/model_features.py`:

Returns a `ModelFeatures` dataclass. Key fields:

```python
supports_stop_words = not model_matches(model, SUPPORTS_STOP_WORDS_FALSE_MODELS)
supports_reasoning_effort = _supports_reasoning_effort(model)
```

`SUPPORTS_STOP_WORDS_FALSE_MODELS` list (full, as of HEAD `5a31572`, 2026-05-14):
```python
["o1", "o3", "grok-4-0709", "grok-code-fast-1", "deepseek-r1-0528"]
```
**GPT-5 is NOT in this list.** [model_features.py, fetched raw]

`_supports_reasoning_effort(model)` delegates entirely to:
```python
"reasoning_effort" in litellm.get_supported_openai_params(model=normalized)
```
[model_features.py, _normalized_supported_openai_params()]

**`_transport_call()`** in `openhands-sdk/openhands/sdk/llm/llm.py`:

Calls `litellm_completion` with `drop_params=self.drop_params` (default True). The `disable_stop_word` field (line ~374) is defined but **never referenced** in the `_transport_call` or `completion()` methods — it is dead configuration at time of research. [llm.py raw fetch, lines 1079-1135]

**`STOP_WORDS`** in `openhands-sdk/openhands/sdk/llm/mixins/fn_call_converter.py`:

Defined as `STOP_WORDS = ["</function>"]` — this is the V1 stop word constant. Used to detect truncated function-call output, not injected into the litellm call as a `stop` parameter. The `disable_stop_word` and `supports_stop_words` from `model_features.py` do not appear to be wired into the `completion()` call path in any visible code. [fn_call_converter.py]

**Version note:** `openhands-sdk` is at v1.22.0 (PyPI latest as of 2026-05-14); the OpenHands main repo (`All-Hands-AI/OpenHands`) pins `openhands-sdk==1.21.1` in its `pyproject.toml`. [pyproject.toml, github.com/All-Hands-AI/OpenHands]. The SDK itself requires `litellm>=1.83.7`. [openhands-sdk/pyproject.toml]

---

## 3. V1 Equivalents of V0 Local Patches

### bc7.3 patch: temperature/top_p strip for Opus 4.7 and GPT-5.x

**V0 behavior**: `openhands_temp_patch.py` injected a block in `llm.py` that explicitly popped `temperature` and nulled `top_p` for `claude-opus-4-5/4-6/4-7` and `gpt-5.x` model names.

**V1 mechanism**: `select_chat_options()` strips temperature/top_p for any model where `_supports_reasoning_effort()` returns True (and model is not Gemini). This function queries `litellm.get_supported_openai_params()` to detect reasoning_effort support.

**For claude-opus-4-7 (Bedrock path)**:
- Litellm's `AnthropicConfig.get_supported_openai_params()` includes `reasoning_effort` when `_is_claude_4_7_model(model)` is true (checks for "opus-4-7", "opus_4_7", "opus-4.7", "opus_4.7"). [litellm/llms/anthropic/chat/transformation.py]
- However, **temperature is NOT excluded from `get_supported_openai_params()` for Anthropic models** — it remains in the unconditional base list. [litellm/llms/anthropic/chat/transformation.py]
- The V1 SDK strips temperature via the `supports_reasoning_effort` → `select_chat_options` path, NOT via litellm's `drop_params`.
- The V1 SDK added `"claude-opus-4-7"` to `model_features.py` reasoning_effort support in commit `a234670` (2026-04-16), PR #2852. [github.com/OpenHands/software-agent-sdk/commit/a234670]
- **Conclusion**: For the `anthropic/claude-opus-4-7` model string (direct Anthropic), V1 SDK should strip temperature/top_p via the reasoning_effort path IF litellm reports reasoning_effort in supported params. For `bedrock/anthropic.claude-opus-4-7` (Bedrock converse), the Bedrock converse transformation also adds reasoning_effort when "claude-opus-4" is in the model name. [litellm/llms/bedrock/chat/converse_transformation.py]
- **Risk flag**: The entire temperature-strip gate depends on litellm correctly reporting `reasoning_effort` for the exact model string used. The 0em smoke proved litellm 1.84 still has the Anthropic temperature gap for `drop_params` alone. The V1 SDK works around this by gating on `reasoning_effort` presence rather than `drop_params` — but this only works if litellm actually returns `reasoning_effort` for the model. **[REQUIRES SMOKE]**: verify litellm 1.83.7+ reports `reasoning_effort` in `get_supported_openai_params("bedrock/anthropic.claude-opus-4-7")`.

**For gpt-5.x (OpenAI path)**:
- Litellm's `OpenAIGPT5Config.get_supported_openai_params()` includes `reasoning_effort` and explicitly excludes `stop`. [litellm/llms/openai/chat/gpt_5_transformation.py]
- V1 SDK `_supports_reasoning_effort()` will detect gpt-5 as a reasoning model via litellm.
- `select_chat_options()` will strip temperature/top_p for gpt-5.
- **Conclusion**: GPT-5 temperature/top_p stripping is likely handled by V1 SDK via the reasoning_effort detection path.

**V1 gap vs V0 patch**: The V0 patch was explicit model-name string matching. V1 relies on litellm's `get_supported_openai_params()` being accurate. If litellm's catalog is wrong or the model string format doesn't match (e.g. prefixed with `bedrock/`), the strip silently fails.

---

### 3wi patch: stop-word gating for GPT-5.x

**V0 behavior**: A regex around `MODELS_WITHOUT_STOP_WORDS` blocked the `stop` kwarg for GPT-5.x.

**V1 mechanism**:
- V1 SDK's `SUPPORTS_STOP_WORDS_FALSE_MODELS` does NOT include GPT-5. GPT-5 models are treated as supporting stop words by the SDK. [model_features.py, verified raw]
- The `disable_stop_word` LLM config field (default False) exists but is **not wired** into the `completion()` or `_transport_call()` call paths at time of research. [llm.py raw search, no usage found]
- HOWEVER: litellm's `OpenAIGPT5Config.get_supported_openai_params()` explicitly excludes `stop` from GPT-5's supported parameters. [litellm/llms/openai/chat/gpt_5_transformation.py]
- With `drop_params=True` (the V1 SDK default), litellm would strip `stop` for GPT-5 calls if litellm's supported-params catalog correctly excludes it.
- The 0em smoke proved GPT-5 temperature was NOT stripped by `drop_params` despite `get_supported_openai_params()` excluding it — because of how `map_openai_params` vs the supported-params catalog interact. The same risk applies to `stop`.
- **[UNVERIFIED]**: Whether `drop_params=True` + litellm 1.83.7+ actually strips `stop` for GPT-5.x without our explicit guard. The errata track record demands a smoke: send a request to GPT-5.x with a `stop` kwarg and verify it does not reach the API.

**Is the underlying gap inherited?**: Partially. The V0 patch's purpose was to prevent `stop` from reaching GPT-5. The V1 path *should* handle this via litellm's `drop_params` + the GPT-5 config excluding `stop` — but this is a different mechanism, and the 0em errata demonstrates the litellm catalog/handling distinction. **This needs a dedicated smoke before committing to drop the 3wi guard.**

---

### Summary: do V1's mechanisms close the gaps?

| Patch | V0 mechanism | V1 mechanism | Confidence | Action |
|---|---|---|---|---|
| bc7.3: Opus 4.7 temp/top_p (Bedrock) | Explicit pop in patched llm.py | `supports_reasoning_effort` → `select_chat_options` pops temp/top_p | Medium | Smoke required: test bedrock/anthropic.claude-opus-4-7 temperature strip |
| bc7.3: GPT-5 temp/top_p | Explicit pop in patched llm.py | `supports_reasoning_effort` → `select_chat_options` pops temp/top_p | Medium-High | Smoke recommended: confirm gpt-5 string hits reasoning_effort path |
| 3wi: GPT-5 stop word gate | Explicit `MODELS_WITHOUT_STOP_WORDS` regex | litellm `drop_params` + GPT-5 config excludes `stop` | Low-Medium | Smoke required: errata precedent demands verification |

---

## 4. V0 → V1 Migration Documentation

**No formal migration guide found.**

Searched:
- `CHANGELOG.md` at repo root → 404 (does not exist) [github.com/All-Hands-AI/OpenHands/blob/main/CHANGELOG.md]
- `MIGRATION.md` → 404 [github.com/All-Hands-AI/OpenHands/blob/main/MIGRATION.md]
- `docs/usage/llms/llms.md` → 404
- `docs/usage/llms/about-llm-config.md` → 404
- `README.md` → no migration content mentioned [github.com/All-Hands-AI/OpenHands/blob/main/README.md]
- V1.0.0 release notes (2025-12-16): mention "new software-agent-sdk" but provide no user-facing migration instructions beyond a docs link. [github.com/All-Hands-AI/OpenHands/releases/tag/1.0.0]
- V1.7.0 release notes (2026-05-01): no breaking changes or LLM config migration notes. [github.com/All-Hands-AI/OpenHands/releases/tag/1.7.0]

The `docs.openhands.dev/sdk` documentation URL referenced in the SDK's PyPI page returned 403. [docs.openhands.dev/sdk]

**Practical implication**: No documented upgrade path exists. The migration from cybergym's `b5cbe06`-era V0 pin to V1 is uncharted territory for harness integrators — there is no community guide to lean on.

---

## 5. V1 Release Cadence and Stability

**Release history** (fetched from [github.com/All-Hands-AI/OpenHands/releases]):

| Tag | Date |
|---|---|
| 1.7.0 | 2026-05-01 |
| 1.6.0 | 2026-03-30 |
| 1.5.0 | 2026-03-11 |
| 1.4.0 | 2026-02-17 |
| 1.3.0 | 2026-02-02 |
| 1.2.1 | 2026-01-16 |
| 1.2.0 | 2026-01-15 |
| 1.1.0 | 2025-12-30 |
| 1.0.0 | 2025-12-16 |

**SDK cadence** (github.com/OpenHands/software-agent-sdk):
- HEAD: `5a31572` (2026-05-14) — daily commits, active development
- v1.22.0 released 2026-05-11; OpenHands main pins 1.21.1 (pinned 2026-05-13 in PR #14409)
- SDK minor-version bumps occur roughly every 2 weeks; patch bumps more frequently.

**Stability assessment**: V1 is **a moving target**. The main `openhands/` repository is undergoing active package removal (PR #14239 "Remove legacy LLMConfig" merged Apr 30; PR #14252 "Remove openhands.core" merged May 1). The SDK itself sees daily commits. The `pyproject.toml` pins `openhands-sdk==1.21.1` exactly (not a range) — meaning OpenHands mainline is deliberately coupling to a specific SDK point release and bumping explicitly.

**Breaking-change pattern**: The V0→V1 transition involved deleting entire packages (`openhands.llm`, `openhands.core`, `LLMConfig`). There is no evidence of deprecation windows; code is deleted once the SDK absorbs it. Integrators consuming `openhands` as a library (as cybergym-agent-examples does via submodule) will experience hard import failures on upgrade.

---

## Headline Summary: Matrix Doc V1 Claims

| Claim | Status |
|---|---|
| `openhands/llm/llm.py` deleted in commit `aea6116` (2026-04-27) | **CONFIRMED** — diff and PR #14154 verified |
| LLM logic now lives in `OpenHands/software-agent-sdk` | **CONFIRMED** — PyPI `openhands-sdk` at `OpenHands/software-agent-sdk`; `openhands-sdk/openhands/sdk/llm/` is the new home |
| V1 SDK sets default temperature to None (PR #1989, 2026-03-02) | **CONFIRMED in spirit** — `temperature: float | None = Field(default=None)` in llm.py; PR not independently verified by number |
| V1 SDK has no explicit temperature scrub for Opus 4.7 | **PARTIALLY REFUTED** — V1 SDK *does* strip temp/top_p for Opus 4.7 via `select_chat_options()` + `supports_reasoning_effort` path (model added in SDK commit a234670) |
| V1 migration: the patch `openhands_temp_patch.py` target no longer exists | **CONFIRMED** — llm.py deleted; patch target is gone |

---

## Risks for the Plan

1. **Temperature stripping mechanism changed, not eliminated.** V0 used explicit model-name matching; V1 uses litellm capability detection. The mechanism is more fragile — if the model string format doesn't match what litellm expects (e.g. `bedrock/anthropic.claude-opus-4-7` vs `anthropic.claude-opus-4-7`), the strip silently fails. The 0em errata (litellm 1.84 temperature gap for GPT-5 via `drop_params`) demonstrates exactly this failure mode.

2. **Stop-word gate for GPT-5 is unverified.** `SUPPORTS_STOP_WORDS_FALSE_MODELS` in the V1 SDK does not include GPT-5. The guard relies on litellm `drop_params` stripping `stop` for GPT-5 — but `drop_params` reliability is precisely what 0em proved is insufficient for this model family. This is the same gap as the errata.

3. **`disable_stop_word` field is dead code.** Defined in `llm.py` but not wired into the call path. Any cybergym/harness code that tries to set `disable_stop_word=True` to gate stop words will silently have no effect.

4. **No migration guide.** Every aspect of the V0→V1 interface change must be discovered experimentally. The cybergym submodule's `run.py` CLI, `config.toml`, and agent invocation surface all need to be reverse-engineered from V1 source.

5. **SDK is actively moving.** Pinning `openhands-sdk==1.21.1` is the right strategy, but the SDK sees breaking changes at minor version bumps (package deletions). The harness must pin exactly and test any bump explicitly.

6. **V1 requires the `agent-server` container** (`ghcr.io/openhands/agent-server:TAG-python`), not the old `all-hands-ai/runtime` image. These are entirely different container architectures. The old runtime sandbox model is gone.

7. **Bedrock Opus 4.7 temperature strip depends on model string format.** The SDK commit a234670 registers `"claude-opus-4-7"` in `verified_models.py`, but Bedrock model strings typically include provider prefixes (e.g. `bedrock/anthropic.claude-opus-4-7`). The `_is_claude_4_7_model()` check in litellm looks for `"opus-4-7"` as a substring — this should match, but the exact Bedrock inference profile string used in our config needs verification.

---

## Recommended Pre-flight Smokes

1. **Bedrock Opus 4.7 temperature smoke**: Instantiate V1 SDK `LLM(model="bedrock/anthropic.claude-opus-4-7", ...)` with `temperature=0.5`, call `select_chat_options()`, assert temperature is NOT in the returned dict. Then make a live call and verify no InvalidParameterValue error. This validates the `supports_reasoning_effort` detection path for Bedrock.

2. **GPT-5 stop smoke**: Instantiate V1 SDK `LLM(model="gpt-5.2", ...)` and call it with a `stop=["</function>"]` kwarg. Verify that litellm's `drop_params=True` actually strips the stop param before the OpenAI API call. If it does not, the 3wi-equivalent guard must be reimplemented in the harness.

3. **GPT-5 temperature smoke**: Same setup — verify temperature is stripped by the `supports_reasoning_effort` path, not silently passed through. Cross-check against the 0em errata: the fix in V1 SDK is a different code path than litellm's `drop_params`, so this may actually work, but needs live confirmation.

4. **Bedrock model-string format smoke**: Confirm what model string cybergym's V1 `config.toml` should use for Opus 4.7 Bedrock, and that the `_is_claude_4_7_model()` substring check in litellm matches it.

5. **Container healthcheck smoke**: Stand up `ghcr.io/openhands/agent-server:1.7.0-python` (or equivalent) with a minimal config, verify the container responds to its healthcheck endpoint without any LLM call. This gates out the image-coupling failure mode that killed pgf Stage 1.

---

*Research completed 2026-05-14. No code modified. Sources: GitHub WebFetch (primary), PyPI JSON APIs, raw.githubusercontent.com source files. All claims cite primary sources as specified.*
