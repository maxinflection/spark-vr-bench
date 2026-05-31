# Stack Version & Patch Matrix — 2026-05-14

Research context: bd issues `pgf` (OpenHands/Pool A modernisation) and `0em` (Pool B litellm/SDK modernisation).

---

## ERRATA (post-smoke, 2026-05-14)

After 0em Phase 1 execution on litellm 1.84.0, two "droppable" classifications below proved wrong:

- **§2 row 2 — GPT-5.x temperature strip**: classified as droppable citing PR #13390. Live smoke (`0em-bump-gpt55-humaneval-2026-05-14`) failed with `Unsupported value: 'temperature' does not support 0 with this model`. Root cause: `OpenAIGPT5Config.get_supported_openai_params()` still **lists temperature in the supported set**, so `drop_params=True` does not strip it and the conditional native handler in `map_openai_params` never fires. The PR added handling code but the supported-params catalog wasn't updated to match. **Reclassify as required.**
- **§2 row 3 — GPT-5.x `max_tokens → max_completion_tokens` rename**: classified as droppable citing the same PR #13390. Initial conservative read kept the patch in place; subsequent dedicated smoke on 2026-05-15 (bd `m4u`) confirmed litellm 1.84.0 accepts `max_tokens=20` to `openai/gpt-5.5` and returns content cleanly — the upstream handler does fire for this case, distinct from the temperature row above. **Reclassify as droppable; patch removed 2026-05-15 (bd <ISSUE>).**

Both patches **restored in `_litellm_patches.py`** after the 2026-05-14 smoke. The Opus 4.7 row (§2 row 1, originally "uncertain") was also confirmed required by smoke and re-enabled. The `max_tokens` rename patch was subsequently **dropped 2026-05-15** after the dedicated bd `m4u` smoke run.

The §6 OpenHands V1 claim ("`openhands/llm/llm.py` deleted upstream 2026-04-27") has **not been independently verified** by smoke; treat with the same skepticism the GPT-5 rows earned. Phase 2 Stage 1 (image-only bump on V0 line) failed independently due to runtime/app version coupling (`0.33-nikolaik` runtime ↔ OpenHands v0.33.0 app: bumping runtime to `0.59-nikolaik` while keeping the app at v0.33.0 makes the container exit before any LLM call).

---

## 1. Version-Diff Table

| Component | Current pin | Latest upstream | Upstream release date | Months stale | Notes |
|---|---|---|---|---|---|
| `ghcr.io/all-hands-ai/runtime` | `0.33-nikolaik` (built 2025-04-16) | `oh_v0.62.0_*-nikolaik` (GHCR) | ~Dec 2025 | ~8 months | **Architecture shift**: OpenHands V1 (≥ v0.59) moved to `ghcr.io/openhands/agent-server:1.19.1-python`; the old `all-hands-ai/runtime` image series appears frozen at 0.62.x. A bump from 0.33 to the current V1 image is not a simple tag change — see Notes below. |
| All-Hands-AI/OpenHands repo | `b5cbe06` (June 2025, via cybergym-agent-examples submodule) | `e7b5e30` (main, 2026-05-14) | 2026-05-14 | ~11 months | V0→V1 SDK migration completed ~Apr 2026: `openhands/llm/llm.py` **removed** (commit `aea6116`, 2026-04-27) as part of "Remove openhands.llm package (legacy V0 code)". All LLM logic now lives in the `OpenHands/software-agent-sdk`. cybergym-agent-examples submodule latest commit is `6660f3f` (Feb 2026) — a README-only typo fix; `b5cbe06` still has the real agent code. |
| cybergym-agent-examples | `b5cbe06` (June 2025) | `6660f3f` (Feb 2026) | 2026-02-02 | ~8 months | Only 4 total commits; `6660f3f` is a README typo. The `openhands/openhands-repo` submodule inside it pins to an old OpenHands V0 SHA. No substantive code changes since June 2025. |
| litellm | `1.69.0` (Pool B venv) | `1.84.0` | 2026-05-14 | ~10.5 months | 15 minor versions. GPT-5 dedicated config class (`gpt_5_transformation.py`) added; Opus 4.7 support added (issue `#26444` filed 2026-04-24; PRs `#26246`/`#26445` **closed-merged** with temperature/top_p exclusion for reasoning models). Empty stop-sequence fix merged Jan 2025 (PR `#7484`). Supply chain incident in March 2026; post-audit stable line from v1.83.0 onward. |
| anthropic Python SDK | `0.49.0` | `0.102.0` | 2026-05-13 | ~11 months | Major version jump in API surface (extended-thinking, Bedrock cross-region overhaul, new message shapes). |
| openai Python SDK | Unknown (not pinned by name in install-harness.sh; bigcodebench installs it transitively) | `2.36.0` | 2026-05-07 | unknown | Rapid release cadence (weekly). 2.x series. |
| EleutherAI/lm-evaluation-harness | `main` (unpinned; installed as `-e`) | `v0.4.12` / main `95d5806` | main: 2026-05-11; v0.4.12 tag: ~May 2024 | install pulls latest main at image build time | No version pin in `install-harness.sh` (`-e` install from cloned HEAD). Harness dev series is 0.4.13.dev0. |
| bigcode-project/bigcodebench | Latest from pip (unpinned) | `0.2.5` | 2025-03-31 | install pulls latest | PyPI latest is 0.2.5. No pin in harness; `pip install bigcodebench` at provision time. Docker eval image: `bigcodebench/bigcodebench-evaluate:latest` (last Docker Hub refresh 2024 per install-harness.sh comment). |
| simple-parsing | Latest from pip (unpinned) | `0.0.21.post1` | 2022-12-06 | ~3.5 years | Used only in cybergym venv for OpenHands `run.py` CLI. Very stable; no functional churn. |
| pydantic | `2.11.3` (cybergym venv, 2026-04-16 release) | `2.13.4` | 2026-05-06 | ~3 weeks | Minor version lag only. No breaking changes expected. |

### Runtime image architecture note

OpenHands V1 (released as v1.0 in late 2025, now at v1.7.0 as of May 2026) replaced the `ghcr.io/all-hands-ai/runtime:X.Y-nikolaik` sandbox model with a composable `ghcr.io/openhands/agent-server:TAG-python` image paired with a separate `docker.openhands.dev/openhands/openhands:1.7` application image. The old `All-Hands-AI/runtime` GHCR package appears frozen at `oh_v0.62.0` (≈ Dec 2025). A full upgrade from 0.33 to the modern stack is a **breaking change** that requires updating both the runtime container reference in `cybergym/examples/agents/openhands/template/config.toml` AND the underlying poetry venv / SDK wiring — not a simple tag bump.

---

## 2. Patches Matrix

### Pool B: `scripts/runners/_litellm_patches.py`

| Patch | What it does | Upstream status | Classification | Citation |
|---|---|---|---|---|
| **Temperature/top_p/top_k strip — Opus 4.7** | Drops `temperature`, `top_p`, `top_k` from kwargs when `claude-opus-4-7` (or `anthropic.claude-opus-4-7`) is in the model name, because Bedrock returns `InvalidParameterValue: temperature is deprecated for this model`. Workaround for litellm issue `#26444`. | litellm `#26246` and `#26445` are both **closed-merged** (as of research date). The `AnthropicConfig.get_supported_openai_params()` in current `transformation.py` still includes temperature in the base list unconditionally but the PRs added a conditional path that excludes temperature for reasoning-family models when `drop_params=True` is active. However, `model_prices_and_context_window.json` entry for `anthropic.claude-opus-4-7` does **not** contain `"supports_temperature": false` — so `drop_params=True` alone may still not gate it correctly on Bedrock. Needs a smoke test against litellm 1.84. | **uncertain** | PRs `BerriAI/litellm#26246`, `#26445` both merged; issue `#26444` (from our own codebase) closed. But Bedrock-converse path and the JSON price table both lack the `supports_temperature` flag. Smoke required. |
| **Temperature/top_p/top_k strip — GPT-5.x** | Same scrub for `gpt-5` prefix family (reasoning models). | litellm has a dedicated `gpt_5_transformation.py` with `OpenAIGPT5Config`. The `map_openai_params` method drops temperature when value ≠ 1 (and `drop_params=True`), and does NOT include temperature in `get_supported_openai_params`. This is handled **natively**. | **droppable** | `litellm/llms/openai/chat/gpt_5_transformation.py` → `OpenAIGPT5Config.map_openai_params`; merged PR `#13390` (2025-08-07). |
| **`max_tokens` → `max_completion_tokens` rename — GPT-5.x** | Renames the param before the API call because GPT-5.x rejects `max_tokens`. | `OpenAIGPT5Config.map_openai_params` explicitly converts: `optional_params["max_completion_tokens"] = non_default_params.pop("max_tokens")`. **Natively handled** in litellm 1.84. | **droppable** | `litellm/llms/openai/chat/gpt_5_transformation.py`; PR `#13390` merged 2025-08-07. |
| **Trailing-whitespace strip on Bedrock Anthropic assistant message** | `rstrip()`s the last assistant message content when the model matches `bedrock/anthropic` or `bedrock/us.anthropic`, because Anthropic rejects content ending in whitespace. | litellm PR `#15850` ("Fix empty assistant message handling in AWS Bedrock Converse API") merged **2025-11-01** replaces *empty/whitespace-only* strings with `"."` in `_bedrock_converse_messages_pt`. However, that fix targets **empty or fully-whitespace** content (replacing with placeholder), whereas our patch handles *trailing* whitespace on otherwise non-empty content (`rstrip()` only). The current `converse_transformation.py` does not rstrip non-empty content. The semantics are different. | **required** (distinct case) | Our patch strips trailing whitespace from non-empty strings; upstream PR `#15850` only replaces fully-empty/whitespace strings with `"."`. Gap: `converse_transformation.py` has no `rstrip()` on non-empty assistant content. |
| **Drop empty/whitespace-only stop sequences** | Filters blank entries from the `stop` kwarg before sending to Bedrock (which errors on `inferenceConfig.stopSequences.0 is blank`). | litellm `converse_transformation.py` `map_openai_params`: filters `len(value) == 0` for string `stop`, but **does not filter whitespace-only strings** (e.g. `"  "` or `"\n"`). PR `#7484` (merged 2025-01-08) fixed the direct-Anthropic path, not Bedrock-converse. | **required** | `litellm/llms/bedrock/chat/converse_transformation.py` `map_openai_params` — checks `len(value) == 0` only; whitespace-only strings pass through unfiltered. |
| **Usage aggregation (post-call)** | Wraps `litellm.completion/acompletion` to aggregate `prompt_tokens`/`completion_tokens` and flush to `LITELLM_PATCH_USAGE_OUT` on exit. lm-eval's API backend doesn't aggregate usage. | lm-evaluation-harness does not expose per-run aggregate token counts on the litellm path. This is a local instrumentation feature with no upstream equivalent. | **required** (instrumentation) | lm-eval upstream has no post-run usage aggregation file; our `results.json` would carry zeros without it. |
| **`LM_EVAL_VLLM_EXTRA_BODY` injection** | Merges env-supplied JSON into `extra_body` for `openai/` model calls, enabling per-request `chat_template_kwargs` to vLLM without patching lm-eval call sites. | lm-evaluation-harness has no hook for per-request `extra_body` injection on the litellm path. | **required** | No upstream equivalent in lm-eval-harness litellm integration. |

### Pool A: `scripts/patches/openhands_temp_patch.py`

| Patch | What it does | Upstream status | Classification | Citation |
|---|---|---|---|---|
| **bc7.3/3wi: temperature+top_p strip in `llm.py` for Opus 4.x and GPT-5.x** | In-place patch to OpenHands V0 `openhands/llm/llm.py`: injects a block before the `azure` guard that pops `temperature` and nulls `top_p` for `claude-opus-4-5/4-6/4-7` and `gpt-5.x`. | `openhands/llm/llm.py` was **deleted** upstream on 2026-04-27 (commit `aea6116`, "Remove openhands.llm package — legacy V0 code"). OpenHands V1 SDK (`OpenHands/software-agent-sdk`) sets default temperature to `None` (PR `#1989`, merged 2026-03-02), delegating temperature selection to litellm/provider. For Opus 4.6, a guard was added in `llm.py` via PR `#12874` (merged 2026-02-18) before the V0 deletion. The V1 SDK path does not contain an explicit temperature scrub. | **required (but irrelevant to V0 path; uncertain for V1)** | The patch applies to a file that no longer exists in modern OpenHands. A V1 upgrade requires re-evaluating whether the SDK+litellm stack needs any analogous guard at all (depends on whether litellm 1.84+ handles Bedrock Opus 4.7 temperature natively — see `_litellm_patches.py` row above). |
| **3wi: stop kwarg gate for GPT-5.x** | Wraps the existing `MODELS_WITHOUT_STOP_WORDS` membership check with a regex-based GPT-5 detector, so `stop` is omitted for GPT-5.x (which rejects it). | `openhands/llm/llm.py` deleted in V1. On V1 SDK, stop-word handling moved to the SDK layer; whether GPT-5 is guarded is untested in our harness. | **required (V0); uncertain (V1)** | Same as above — patch target removed in upstream V1 migration. |

### Pool B: `scripts/runners/_bcb_gpt5_shim.py` and `_bcb_opus47_shim.py`

The `_bcb_gpt5_shim.py` and `_bcb_opus47_shim.py` files referenced in bd `0em` **do not exist** in the current repository at `scripts/runners/`. The monkey-patch logic for bigcodebench GPT-5.x and Opus 4.7 routing appears to be described in the bd issue `0em` as planned/anticipated patches, or they may have been removed. The litellm patches in `_litellm_patches.py` (temperature/max_tokens scrubs) are the active Pool B patches.

If these files do exist elsewhere (not found in repo search), the upstream assessment would be:
- **BCB GPT-5 shim** (strip temperature/top_p, set max_completion_tokens for bigcodebench's openai request): litellm 1.84 `OpenAIGPT5Config` handles this natively if bigcodebench routes through litellm — **droppable** if BCB uses litellm as backend; **required** if BCB calls openai SDK directly.
- **BCB Opus 4.7 shim** (route bigcodebench's openai backend through `litellm.completion(model=bedrock/...)`): bigcodebench has no native Bedrock inference profile support. This routing shim would still be **required** regardless of litellm version.

---

## 3. Headline Assessment

The harness stack is **10–11 months stale** on every critical component. The most impactful staleness is (a) the OpenHands V0→V1 architecture break — the patch target `openhands/llm/llm.py` no longer exists upstream and the runtime container image series changed entirely — and (b) litellm jumping from 1.69 to 1.84, which **natively resolves 2 of the 7 active patches** (GPT-5 temperature drop and max_tokens rename, both in `gpt_5_transformation.py`). The remaining 5 patches remain required on modern litellm 1.84: the Opus 4.7 temperature/Bedrock path needs a smoke test (PRs merged but Bedrock-converse JSON flag missing), trailing-whitespace strip on Bedrock assistant content is a distinct gap from the upstream fix, empty stop-sequence filtering is incomplete upstream (whitespace-only strings not caught), and the usage-aggregation and vLLM extra-body injections have no upstream equivalents. Recommended bump order: **Stage 1** — litellm 1.84 + anthropic 0.102 + openai 2.36 in the lm-eval venv (drop the 2 confirmed-droppable patches, smoke the 3 uncertain ones); **Stage 2** — OpenHands V1 full migration (requires new runtime container + SDK rewrite of Pool A wiring; the V0 patch file targets are gone upstream).

---

*Research completed 2026-05-14. No code modified. Sources: PyPI JSON APIs, GitHub commit/PR pages, litellm raw source files, bd issues pgf/0em/bc7/3wi.*
