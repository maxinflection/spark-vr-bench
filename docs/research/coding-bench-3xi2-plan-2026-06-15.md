# Agentic coding bench (Pool B expansion) — plan for `bd benchmarks-3xi.2` (2026-06-15)

**Status:** plan, awaiting operator sign-off before bd decomposition is filed.
**Issue:** `benchmarks-3xi.2` — "Expand Pool B with an agentic coding bench."
**Epic:** `benchmarks-3xi` (Benchmark science) → depends on `benchmarks-9g4` (powered/clean Pool A pipeline).
**Operator steers (2026-06-15):** primary bench research re-pointed at **SWE-bench Pro**; language-confound instrument = **SWE-rebench V2**.

`[M]` measured · `[E]` estimate · `[V]` web-research-verified (adversarial pass) · `[U]` unverified, confirm before relying.

---

## 0. TL;DR — the decision

Build the agentic coding bench around **two execution-graded, contamination-aware SWE-task benches**, run through the harness we already operate (OpenHands) plus the bench's canonical scaffold (SWE-agent), on the EC2 harness host:

1. **SWE-bench Pro (public 731-set)** — the **headline / canonical** coding cell. It is the field-consensus replacement for SWE-bench Verified (which OpenAI formally **deprecated 2026-02-23** for contamination + 59% flawed tests `[V]`). Contamination-resistant *by design* (copyleft/GPL public repos + held-out + private commercial splits), MIT, long-horizon, multi-language, with a standardized public leaderboard to anchor against.
2. **SWE-rebench V2** — the **rolling / recency** cell **and** the **language-confound instrument** for Track A (`3xi.1`). 20 languages incl. C/C++/Rust/Go/Java/TS (direct overlap with CyberGym's C/C++), per-model-training-cutoff decontamination, monthly refresh, CC-BY-4.0, **native OpenHands** integration (Nebius publishes OpenHands trajectories for it).

**Harness path (resolves the deferred Q2):** support **both scaffolds** — not either/or.
- **SWE-agent** is SWE-bench Pro's *canonical* scaffold; running Pro on it gives a number cross-comparable to Scale's SEAL leaderboard (a true canonical cell).
- **OpenHands** is *our* scaffold (CyberGym/CVE) and SWE-rebench's native one; it gives harness-consistency across the repo and is the path for the rebench cell.
- Running the **same Pro tasks through both** *is* the harness-uplift A/B that sibling `3xi.3` needs. So adding SWE-agent is not scope creep — it is the second arm of the uplift experiment.

**Demoted / dropped from primary:** SWE-bench Verified (deprecated, contaminated — keep one cell only as a *calibration anchor* to published OpenHands-matched numbers, clearly labelled legacy); Aider Polyglot (2-turn, not agentic, not OpenHands-native — cheap fallback only); Multi-SWE-bench Mini (strong fixed-snapshot multilingual alternative to rebench V2 — hold as the backup language instrument).

---

## 1. What the issue asks, and what's start-able now

`3xi.2` bundles two purposes:
- **(a) harness-uplift testbed** — a bench where the harness does real edit-run-test work + large public baselines (feeds `3xi.3`).
- **(b) a non-C/C++ contrast to CyberGym** for the language/pretraining analysis (feeds `3xi.1`, Track A).

Epic `3xi` **depends on `9g4`** (powered n≥40–50, loop detection, parallel harness, validated config). So *powered* coding-bench runs ride on 9g4. But the issue explicitly carves out work we can **start now, no GPU, cheap**:

> "Build it 'n-right' from the start. Validate the bench harness on a cheap model / small n before pointing frontier-API models at it. Verify prompt-caching for any long-horizon/API variant (O(turns²) cost otherwise)."

→ **Phase 0–2 below (wiring + small-n validation + prompt-cache proof) are not blocked by 9g4.** Only the powered/uplift phases (3–4) are.

---

## 2. Why this is executing a slot we already reserved (original-plan review)

- `docs/eval-battery.md` already lists **"SWE-bench Verified (subset of 50–100)"** as the agentic Pool B member, and the Screening profile already budgets **"SWE-bench Verified-50 (Pool B, agentic), 4–8 hr."** README's battery paragraph names "SWE-bench Verified-50" too. **We foresaw the slot.**
- `docs/research/methodology-overview.md` + `benchmark-canonical-protocols.md` already encode the scaffold caveat (OpenHands/SWE-agent/Aider) and treat **scaffold as a fixed property of how a bench is run**, not a swept axis — which is exactly the lens we need for the SWE-agent-vs-OpenHands distinction here.
- **What changed since those docs:** (i) SWE-bench Verified is now **contaminated + deprecated** (OpenAI, 2026-02-23 `[V]`); frontier scores 88–95% are contamination-inflated. (ii) A wave of **contamination-resistant** successors shipped (SWE-bench Pro 2025-09; SWE-rebench V1 2025-05 / V2 2026-02; SWE-bench Live; Multi-SWE-bench 2025-04). → The reserved slot should be **filled with Pro + rebench, not Verified.** This plan proposes editing `eval-battery.md` accordingly (Phase 5).

---

## 3. Candidate landscape (research-verified, recency-weighted)

| Bench | Scale / langs | Agentic depth | Contamination posture | Native scaffold | Anchors | Our role |
|---|---|---|---|---|---|---|
| **SWE-bench Pro** (Scale, 2509.16941) | 731 public / 858 held-out / 276 commercial; multi-lang, Python-dominant | full edit-run-test, **long-horizon** (multi-file, big diffs) | ✅✅ **by design** — copyleft public repos + held-out + private; MIT | **SWE-agent** (mini-swe-agent works) | SEAL public leaderboard (standardized scaffold) `[V/U]` | **Headline canonical cell** |
| **SWE-rebench V2** (Nebius, 2602.23866) | 32k pool, **20 langs** incl C/C++/Rust/Go/Java/TS; monthly slices | full | ✅✅ **strongest** — per-model-cutoff filtering, rolling; CC-BY-4.0 | **OpenHands-native** (Nebius pub. OH trajectories) | thinner; rolling-slice leaderboard | **Recency cell + Track-A language instrument** |
| SWE-bench Verified | 500 Python | full | ❌ **deprecated 2026-02-23**, leakage proven | OpenHands/SWE-agent | dense, incl. OpenHands-matched (Sonnet 4.5 ~72.8%) | **legacy calibration anchor only** |
| Multi-SWE-bench Mini (ByteDance, 2504.02605) | 400 = 8 langs ×50 (Py+Java/TS/JS/Go/Rust/C/C++) | full (MopenHands) | ❌ fixed 2025-04 | MopenHands / MSWE-agent | **per-language** Claude-3.7 #s published | **backup language instrument** |
| Aider Polyglot | 225, 6 langs | ⚠️ **2-turn, not agentic** | ⚠️ Exercism, difficulty-filtered | own harness (not OH) | dense | cheap fallback only |
| SWE-bench Live / SWE-PolyBench / Terminal-Bench / Commit0 / SWE-Lancer | various | mixed | Live=strong; others fixed | mixed | mixed | watch-list |

**Methodology guardrail — scaffold is load-bearing.** A bench's score depends 20–40 pts on scaffold `[V]` (xAI Grok-3 63.8% custom vs ~42% standardized is the cautionary tale). So:
- The **canonical** Pro cell uses **SWE-agent** (author scaffold) to be cross-comparable to the SEAL leaderboard.
- Any **OpenHands** Pro cell is a *cross-scaffold* cell (label it, like the SEC-bench smolagents note in `benchmark-canonical-protocols.md`), and is only compared to other OpenHands cells.
- Per `docs/eval-battery.md`/`methodology-overview.md`: **execution-graded only, pass@1 single-stream default, every row tagged with scaffold + max_turns + quant + date.**

---

## 4. The "n-right" build — phased, smoke-gated

Mirrors the stage-gate discipline of `openhands-v1-migration-plan-2026-05-14.md` (no stage advances until its gate is met). Cheap before expensive; cheap model before frontier API; small-n before powered.

### Phase 0 — Harness wiring + no-/cheap-LLM smoke  (start now; ~$ low; not blocked by 9g4)
- **0.a Pin the stack.** SWE-bench Pro: clone `scaleapi/SWE-bench_Pro-os`, pin commit + the `jefzda/sweap-images` Docker Hub tags (per the dataset's `dockerhub_tag` column). OpenHands path: pin the `OpenHands/benchmarks` (`swebench-infer`) version tuple (SDK + agent-server image digests), reusing the `m7v` V1-migration learnings (digest pinning, per-conversation secrets).
- **0.b Disk/host sizing.** Pro images are pre-built and **pulled, not built** (lighter than CyberGym's 130 GB build). Budget `/data` headroom on the EC2 harness (`harness-setup.md` already provisions a 1 TB `/data`; SWE-bench layers share base, unlike SEC-bench). Confirm `m6i.2xlarge`-class is adequate for N-concurrent pulls + agent runtimes; size EBS for the pulled image set `[E]`.
- **0.c No-LLM smoke.** Run one Pro instance end-to-end through SWE-agent's grader with a trivial/oracle patch → confirm the docker image pulls, the test harness applies the patch, and the pass/fail oracle fires. Repeat for the OpenHands `swebench-infer` path on one SWE-rebench-V2 instance.
- **Gate:** both scaffolds produce a correct pass/fail verdict on a known instance, with a clean grading-audit cross-check (server/exit-code/result.json triangulation, per `feedback_pool_a_grading_audit`).

### Phase 1 — Cheap-model small-n validation  (start now)
- Point each scaffold at a **cheap model**, in two steps (operator-confirmed 2026-06-15): **(1) Haiku-class via API** first — cheapest wiring smoke, and validates the exact Bedrock/Anthropic + prompt-caching path Phase 2 will use; **(2) a small open-weight on an existing rental (vLLM)** second — confirms the vLLM-target path the open-weight roster runs through. n = 5–10 instances each.
- Validate: trajectory capture, token-usage extraction, turn/step cap, wall-cap, and **loop/no-progress detection** — reuse the CyberGym detector from `tz5`/`cybergym-noprogress-detection-2026-06-14` (SWE agents loop too; this is a hard prereq for long-horizon Pro).
- **Gate:** non-trivial completion (>0 pass at n=10 on a cheap model), audit cross-check passes on every instance, loop-detector aborts a deliberately-stalled run.

### Phase 2 — Prompt-cache verification (ISSUE-MANDATED) + frontier-API smoke
- Long-horizon agents re-send a growing transcript every turn → **O(turns²)** token cost without prompt caching. Before any frontier-API Pro/rebench run: instrument cache-hit rate (Anthropic prompt caching on the Bedrock/Anthropic path; the OpenHands/litellm layer must pass cache breakpoints). Target the 90–95% APC-hit regime CyberGym already sees (`serving-strategy` §1).
- Frontier-API smoke: 1 model (e.g. an Opus-class) × n≈10 on Pro (SWE-agent) and rebench-V2 (OpenHands), **with caching verified**. Capture $ / task and project the powered-n cost.
- **Gate:** measured cache-hit ≥~90% on the API path (or a documented reason + cost ceiling); per-task $ within budget; a dated cost projection for Phase 3 exists.

### Phase 3 — Screening cells  (gated on `9g4` for *power*; can pilot at small-n earlier)
- **Canonical Pro cell:** SWE-bench Pro public-731 (or a fixed ≥50 stratified subset for screening), **SWE-agent**, pass@1, deployed quant, dual thinking-mode where applicable. Anchored to the SEAL public leaderboard.
- **Recency cell:** SWE-rebench V2 current monthly slice, **OpenHands**, logging the exact slice date + each model's training cutoff.
- Roster: the existing sweep models (open-weight vLLM via rentals + frontier API), per `rlp` epic. n per `9g4.3` power target (≥40–50 to rank).
- **Gate:** columns are honestly powered (Wilson CIs reported); every row tagged scaffold/turns/quant/slice/date.

### Phase 4 — Harness uplift (feeds `3xi.3`) + language strata (feeds `3xi.1`)
- **Uplift A/B:** same Pro task subset × {SWE-agent baseline, OpenHands} × models → `score(model+harness) − baseline`. Needs the most n (variance of a difference; n≥100–200) and the clean loop-detecting harness — hence gated on 9g4.
- **Language strata:** SWE-rebench V2 stratified by language (esp. C/C++ to mirror CyberGym, vs Python/TS/Go/Rust/Java) → join with Track-A per-task tags; test whether model rankings flip by language stratum and whether per-language pass-rate tracks pretraining-share.

### Phase 5 — Land it durably
- Update `docs/eval-battery.md` Pool B: replace "SWE-bench Verified-50" with **SWE-bench Pro (public, SWE-agent canonical) + SWE-rebench V2 (rolling, OpenHands)**; note Verified is legacy-anchor-only post-deprecation. Update README battery paragraph.
- Add `benches[]` board entries + `canonical_condition` for both (Pro: scaffold=SWE-agent, max_turns/step budget per paper; rebench: scaffold=OpenHands, slice-dated). Add frontier anchors (date-stamped, contamination-caveated) to `eval-battery.md`'s anchor table.
- Wire the runner(s): `scripts/runners/run-pool-b-swebench-pro.sh` (SWE-agent) and reuse `OpenHands/benchmarks` for the rebench/uplift path; integrate with `harness-up.sh` / spend-watchdog / sweep-status dashboard.

---

## 4b. Phase-0 execution log (2026-06-15, `bd 3xi.2.1`)

Run on the standing harness box `<HARNESS_INSTANCE_ID>` (idle; docker 29.1.3; docker-root on the 1 TB `/data`, 564 GB free) over SSH-over-SSM. A dedicated node was not launchable from the `benchmarks-sandbox-agent` identity (lacks `iam:PassRole` + `ec2:CreateTags`; `harness-up.sh` also reconciles IAM unconditionally — the open `<CAMPAIGN>` gap), so the standing box is used for small-n validation; a dedicated `--data-volume-size` node is reserved for powered `3xi.2.3`.

**Stack pinned:** `scaleapi/SWE-bench_Pro-os` @ `ca10a60a5fcae51e6948ffe1485d4153d421e6c5`, cloned to `/opt/harnesses/swebench-pro/repo`; venv at `/opt/harnesses/swebench-pro/.venv` (pandas 3.0.3, docker SDK, datasets 5.0.0). Public dataset `ScaleAI/SWE-bench_Pro` = **731 test rows**; images on Docker Hub `jefzda/sweap-images:<derived-tag>`.

**Grader contract (verified by reading source, not docs — the README docstring is stale):** `swe_bench_pro_eval.py` reads a sample CSV/JSONL using **lowercase** `fail_to_pass`/`pass_to_pass`/`selected_test_files_to_run` as `eval()`-able **string-reprs** of lists; patch JSON is a list of `{instance_id, patch}`; it reads `dockerfiles/{base,instance}_dockerfile/<id>/Dockerfile` **relative to CWD** (must run from the repo dir) for `ENV` extraction, runs `run_scripts/<id>/{run_script.sh,parser.py}` inside the pulled image, and marks **resolved iff `(fail_to_pass | pass_to_pass) ⊆ passed_tests`**. `--use_local_docker` avoids the Modal default.

**✅ No-LLM grading-path gate PASSED** on a minimal headless instance (`internetarchive/openlibrary`, 1 fail-to-pass / 0 pass-to-pass):
- Gold patch → **Overall accuracy 1.0 (resolved)**, EXIT 0, ~53 s incl. image pull.
- Empty patch → **Overall accuracy 0.0 (not resolved)** — grader discriminates, not rubber-stamps.
- Image footprint: **~3.94 GB disk / 960 MB content per instance** (731 instances would not all be pulled for screening — a stratified subset is).

Reproducible selector committed at `scripts/runners/_swebench_pro_smoke_build.py`.

**Cheap-model identity:** Haiku 4.5 (`claude-haiku-4-5-20251001`) via the **direct Anthropic API key** in SSM `/sandbox/api-keys/anthropic` (the box's instance role can read `/sandbox/*`; Bedrock grant is Opus-only). Live-pinged HTTP 200. *(Follow-up: widen the Opus-only Bedrock pin on `harness-driver-role` — `bd` it.)*

**SWE-agent patch-generator — installed + wired, but local-docker sandbox is blocked.** Pinned `scaleapi/SWE-agent` @ `402a7b8` (submodule), installed into `.venv-sweagent`, generated `data/instances.yaml` (731 entries, per-instance `image_name`). Filter must be the **full instance id** (anchored `re.match`). Two distinct SWE-Rex **local-docker** failures on the prebuilt Pro images (the fork blesses **Modal** and only patches `swerex/deployment/modal.py`):
1. Default `python_standalone_dir=/root` → SWE-Rex **builds CPython from source** in a builder stage → `fatal error: ffi.h` (image lacks `libffi-dev`). Persists on swe-rex 1.2.0→1.4.0.
2. `python_standalone_dir=""` (use container's own Python via `pipx run swe-rex`, per `batch_instances.py:136`) → runtime starts then bash session dies: `/bin/sh: cannot execute binary file`.

→ **Resolved without changing the experiment.** The scaffold stays SWE-agent (Pro's canonical, leaderboard-faithful scaffold); only the local-docker *substrate* needed three image-specific fixes (the Pro fork runs on Modal, which sidesteps all three — we don't have Modal creds, and local docker runs the identical image+agent+grader, so it is not a design change):
1. **`ffi.h`** — swe-rex's standalone-CPython builder apt-list omits `libffi-dev` → patched (`scripts/runners/_swerex_docker_libffi_patch.py`).
2. **pip hermetic mirror** — Pro images pin pip to `http://127.0.0.1:9876/` (`/root/.config/pip/pip.conf`, Scale's offline build proxy) → the same patch forces `--index-url https://pypi.org/simple` on swe-rex's install.
3. **`ENTRYPOINT=[/bin/bash]`** — turns swe-rex's `/bin/sh -c <cmd>` into `bash /bin/sh -c …` → neutralised at run time with `--instances.deployment.docker_args='["--entrypoint",""]'`.

**✅ Full agent→patch→grade loop validated on the cheap model.** SWE-agent + **Haiku 4.5** in a local-docker sandbox, 44 calls, produced a **3,810-char patch** → `swe_bench_pro_eval.py` **Overall accuracy 1.0 (resolved)** on the minimal openlibrary instance. (Combined with the gold/empty grading controls: 1.0 / 0.0.) Reproducible runner: `scripts/runners/run-swebench-pro-smoke.sh`. No containers leaked.

**SWE-bench Pro half of `3xi.2.1` is validated** (grading discriminates; cheap-model agent loop runs end-to-end on the canonical scaffold). **Remaining for `3xi.2.1`:** SWE-rebench V2 grading smoke via OpenHands `swebench-infer` (the rebench-native path); loop/no-progress-detector reuse demo. **Follow-up (separate):** widen the Opus-only Bedrock pin on `harness-driver-role`.

## 4c. Phase-1 execution log — SWE-rebench V2 / OpenHands half (2026-06-16, `bd 3xi.2.1`)

Run on the same standing box `<HARNESS_INSTANCE_ID>`. The OpenHands `swebench-infer` harness (`github.com/OpenHands/benchmarks` @ `4e0d5b2`) was stood up and retargeted at **`nebius/SWE-rebench-v2`**, validated grading + cheap-model loop + the ported loop detector. The premise held: because the DockerWorkspace path **builds its own agent-server image LOCALLY on top of the instance base image**, it sidesteps every swe-rex/Pro-image quirk the SWE-agent path needed (no libffi build, no `127.0.0.1:9876` pip mirror, no `[/bin/bash]` entrypoint fight). It needed its **own** substrate fixes instead.

**Stack pinned (m7v digest discipline):** OpenHands/benchmarks `@4e0d5b2`; **`vendor/software-agent-sdk @ c950fdb08abea040eebd0bb3d5ff63db293b9125`** (= SDK `v1.24.0-45`, `SDK_SHORT_SHA=c950fdb`) — the tested-together tuple `make build` (`uv sync --dev`) resolves. Agent-server base image `ghcr.io/openhands/eval-agent-server`; per-instance the layer is assembled locally (target `source-minimal`), e.g. `…:c950fdb-codezonediitj-pydatastructs-source-minimal`. Grading parser from `SWE-rebench/SWE-bench-fork @ e4907b7` (own venv). The chosen instance base image `docker.io/swerebenchv2/codezonediitj-pydatastructs:177-2ef83ae` is digest-pinned `sha256:d1a59c3cb997b3e9dc087b7530914076134b54a30ea09e87ba9cc74a6eae29cf`.

**Slice / recency metadata (operator-requested):** dataset `nebius/SWE-rebench-v2`, single config `default`, split `train`, **32 079 instances / 20 languages** (Python 898, Go 758, JS 528, TS 523, Rust 400, … in the first-4000 window). No separate monthly-slice configs — recency is the per-instance **`created_at`** field; the python ≤4-test pool spans `created_at` 2016-08 → 2025-07. Reproducible slice selector: `_rebench_slice_build.py` (writes a 12-row `slice.jsonl`; chosen `codezonediitj__pydatastructs-177`, `created_at 2020-03-19`). **Per-model training-cutoff note:** Haiku 4.5 (`claude-haiku-4-5-20251001`) cutoff is well before this slice was published, but several instances post-date typical pretraining cutoffs — when this cell is run powered, stratify pass-rate by `created_at` vs each model's stated cutoff (the rebench decontam premise).

**Substrate fixes (config/env, NOT scaffold swaps — OpenHands stays the rebench-native scaffold):**
1. `uv` installed to `$HOME/bin` (the box's `$HOME/.local` is root-owned).
2. `sudo chown -R ubuntu:ubuntu $HOME/.local` — else `uv build` (sdist of the agent-server for the image) fails writing `$HOME/.local/share/uv/python` (EACCES).
3. **`docker buildx` + a `docker-container` builder** — Docker 29 ships no buildx; the harness builds via `docker buildx build --load`, and the `docker`-driver fallback breaks its phased content-hash tag match.
4. **`IMAGE_TAG_PREFIX=c950fdb`** — `get_phased_image_tag_prefix()` returns `{sdk}-{dockerfile_content_hash}` (`c950fdb-93c33d0`) but `build_image` actually tags `{sdk}-{custom}` (no content hash), so `ensure_local_image` never finds its expected tag and loops attempts forever. The documented `IMAGE_TAG_PREFIX` override (= the SDK short sha) drops the content-hash segment so expected==built. *(Upstream tagging inconsistency in `4e0d5b2`; flagged for a follow-up bug report.)*
5. **rebench-v2 retarget = `SWERebenchEvaluation` subclass** (`_openhands_swerebench_infer.py`), the repo's OWN per-dataset idiom (cf. `benchmarks/swesmith` ADAPTATION-1): override `get_official_docker_image` → dataset `image_name`; `get_source_repo_path` → `/<reponame>` (rebench images lay the repo there with system python — **no `/testbed`, no conda**, unlike SWE-bench); `should_wrap_instance` → False. Plus a tiny event-JSONL sink callback for the detector.

**Grading — built a faithful direct grader (`_rebench_grade.py`).** The fork's `run_evaluation` LOCAL path can't grade the prebuilt `swerebenchv2` images: it assumes the legacy conda/`testbed` layout and crashes building an (unused-for-prebuilt) conda env — `KeyError: 'python'` in `make_env_script_list_py`. So we run the **canonical eval ourselves** inside the `image_name` container — exactly the fork's `make_eval_script_list_py` sequence (reset test files to base, apply `test_patch`, run `install_config.test_cmd` between markers) — and parse the captured log with the **fork's own canonical parser** (`MAP_REPO_TO_PARSER[install_config['log_parser']]`, e.g. `parse_log_pytest`). It emits the three signals the grading audit triangulates: candidate-patch git-apply, test_cmd exit, and per-test PASSED/FAILED → resolved.

**✅ No-LLM grading gate PASSED** (`codezonediitj__pydatastructs-177`, 1 F2P / 0 P2P, pytest): **gold → resolved=true** (F2P `test_merge_sort_parallel` PASSED, apply ok, test_exit 0); **empty → resolved=false** (F2P MISSING, test_exit 2 — without the fix the test can't even be collected). Grader discriminates, doesn't rubber-stamp.

**✅ Cheap-model loop validated end-to-end.** OpenHands `swebench-infer` + **Haiku 4.5** (DockerWorkspace, `max_iterations=100`) ran the full agent loop (224 events), produced a **4 946-char git patch** → grader **resolved=false** (patch applied cleanly but did not solve the parallel-merge-sort task). The grader thus distinguishes the **gold** solution (resolved) from **both** empty and Haiku's wrong patch — the discrimination the audit requires. *(At `max_iterations=60` Haiku hit `MaxIterationsReached` with no captured patch; 100 let it call `finish`.)*

**Small-n (n=5) cheap-model + grading-audit summary (honest):** ran 4 more python instances through the same loop (`altair-viz__altair-1539`, `abhinavsingh__proxy.py-321`, `qiskit-community__ecosystem-22`, `datadog__guarddog-176`) — Haiku produced applicable patches on every one (3 191–11 218 chars, all `git apply` ok). **Grading-audit cross-check passes on every instance** (server/exit-code/per-test triangulation internally consistent): **gold patches resolve 5/5** (every instance's gold → apply ok + test_exit 0 + F2P PASSED), empty/Haiku → not-resolved with the corresponding failing signals. **Cheap-model pass-rate: Haiku 4.5 = 0/5 resolved.** This is a property of the *model*, not the harness — Haiku (our cheapest wiring model) completes the loop with clean, applicable patches but doesn't *solve* these real SWE-bench-Pro-difficulty rebench tasks. The "n≈10 → >0 pass" gate is therefore **met for the Pro half** (Haiku resolved its minimal openlibrary instance, §4b) but **not for the rebench half at n=5 with Haiku**; the powered screening cell (`3xi.2.3`) runs the real roster (stronger models) where >0 is expected. The harness, execution-grading, audit triangulation, and loop detector are all validated regardless.

**✅ Loop / no-progress detector ported + demoed (`_swerebench_progress_watch.py`).** Port of the CyberGym tz5 detector ([[cybergym-noprogress-detection-2026-06-14]]) to the OpenHands **V1** event schema — **only the event source changed** (V0 `**/events/*.json` → V1 `<id>.events.jsonl`, keying loop on `ObservationEvent` content, stall on event/file timestamps); the two triggers, the case+whitespace-only normalization, the uncertainty-never-aborts discipline and the SIGTERM→SIGKILL-subtree kill are reused verbatim. Validated:
- `--mode analyze` over the **real healthy** Haiku run (163 events / 52 obs) → **ok** (no false-positive; max gap 8 s, modal-repeat 1) — the analog of V0 aborting 0/18 healthy ejv runs.
- `--mode analyze` over synthetic fixtures → **WOULD-ABORT[loop]** (modal obs 12× in window [12:24]) and **WOULD-ABORT[stall]** (max gap 700 s ≥ 600 s).
- `--mode watch` **live**: aborted a deliberately-**stalled** run (no event for 16 s ≥ 15 s → SIGTERM/SIGKILL the pid+subtree, `abort.json` written) and a deliberately-**looping** run (modal obs 12× ≥ 10 → killed). Both processes confirmed dead post-trigger.

**Footprint:** `swerebenchv2` base image ~3 GB + OpenHands agent-server layer ~3.3 GB = **~6.3 GB/instance** (base shared across instances with the same `install_config.base_image_name`, e.g. `python_base_310`); heavier than the Pro half's ~3.94 GB because of the agent-server layer. `/data` headroom comfortable (532 GB free).

**Reproducible artifacts (`scripts/runners/`):** `_rebench_slice_build.py` (slice+predictions), `_openhands_swerebench_infer.py` (rebench subclass + event sink, deployed as `benchmarks/swerebench/run_infer.py`), `_rebench_grade.py` (execution grader), `_swerebench_progress_watch.py` (V1 loop detector), `run-swerebench-smoke.sh` (end-to-end orchestrator + prereq doc).

**Both halves of `3xi.2.1` are now validated** (SWE-bench Pro via SWE-agent §4b; SWE-rebench V2 via OpenHands here). **Follow-ups (separate issues):** (i) widen the Opus-only Bedrock pin on `harness-driver-role` so cheap models run via Bedrock too; (ii) report the OpenHands/benchmarks `IMAGE_TAG_PREFIX` content-hash tag mismatch upstream; (iii) the cheap-model pass-rate at powered n + per-`created_at` decontam stratification rides on `3xi.2.3` (gated on `9g4`).

## 4d. Phase-2 execution log — prompt-cache verification + frontier-API smoke (2026-06-16, `bd 3xi.2.2`)

Run on the same standing box `<HARNESS_INSTANCE_ID>`. **The ISSUE-MANDATED O(turns²) guard**: long-horizon agents re-send a growing transcript every turn, so without Anthropic prompt caching the input cost is O(turns²). Phase 2 instruments the APC hit-rate on BOTH scaffolds, on BOTH the cheap (Haiku, direct Anthropic) and frontier (Opus 4.7, Bedrock) routes, then runs an n≈10 frontier smoke with caching verified and projects the powered-n cost. **APC hit-rate := cache_read / prompt_tokens** (litellm folds `cache_read`+`cache_write` into `prompt_tokens` for Anthropic, verified directly: a probe call showed `prompt_tokens 9983 = cache_read 9963 + uncached 20`).

**Cheapest-possible de-risk first — a direct litellm cache round-trip probe** (`_cache_probe.py`, no agent scaffold): send the same static ~10k-token system prefix twice with a `cache_control` breakpoint and read usage.
- **Bedrock `bedrock/us.anthropic.claude-opus-4-7`** (us-east-1, box instance role): call 1 `cache_creation=9963, cache_read=0`; call 2 `cache_creation=0, cache_read=9963` → **APC 0.998**. Confirms Opus 4.7 IS invokable from the box and `cache_control` round-trips on the litellm Bedrock-converse path.
- **Direct `anthropic/claude-haiku-4-5-20251001`** (SSM key): same shape → **APC 0.998**.

**OpenHands/rebench path — caches CORRECTLY by default; no scaffold change.** SDK `llm.py`: `caching_prompt` defaults `True`; `_apply_prompt_caching` marks the system block + the last user/tool message → a growing cached prefix; `PROMPT_CACHE_MODELS` substring-matches `claude-haiku-4-5` / `claude-opus-4-7` (case-insensitive, so the Bedrock `bedrock/...claude-opus-4-7` string matches too). Per-turn `cache_read_tokens` (=`prompt_tokens_details.cached_tokens`) and `cache_write_tokens` (=`_cache_creation_input_tokens`) are recorded by `telemetry.py` into `Metrics.token_usages`, serialized in `EvalOutput.metrics` (output.jsonl) — no extra wiring; just read & analyze. Substrate fixes for the **Bedrock** route: (i) `uv pip install boto3` into the eval venv (litellm Bedrock needs it; absent → `No module named 'boto3'`); (ii) the Opus llm config **omits `temperature`** — Opus 4.7 on Bedrock rejects `temperature`/`top_p` server-side ("X is deprecated for this model") and the SDK does NOT strip them for Opus (Opus is not in `EXTENDED_THINKING_MODELS`, the only branch that pops them); `temperature=None` is dropped by litellm `drop_params=True`, `temperature=0.0` is rejected (both verified directly).

**SWE-agent/Pro path — had ZERO caching; one substrate fix restores it.** `config/tool_use.yaml` (the Phase-1 smoke config) sets **no `history_processors`** → falls back to `DefaultHistoryProcessor`, a pass-through that adds **no `cache_control`** → the Pro/SWE-agent path was running with **0% prompt caching** (exactly the O(turns²) regime this gate exists to catch). Fix = restore the `cache_control` history processor that EVERY canonical SWE-agent Anthropic config ships (`config/default.yaml`, `config/benchmarks/250225_anthropic_filemap_simple_review.yaml`, …), passed as a second `--config` overlay (`_cache_overlay.yaml`: `history_processors: [{type: cache_control, last_n_messages: 2}]`); SWE-agent deep-merges it. A SUBSTRATE fix, not a scaffold swap (scaffold stays SWE-agent, Pro's leaderboard-faithful scaffold). SWE-agent's `InstanceStats` records only `tokens_sent/received/api_calls` (estimated, `response.usage` discarded), so per-call cache usage is captured by a litellm wrapper (`cache_probe/sitecustomize.py`, auto-imported via PYTHONPATH — the same call-time-rebind trick as `_litellm_patches.py`) into a JSONL. For the **Bedrock** route the same probe scrubs `temperature`/`top_p` at the litellm boundary (SWE-agent's model config defaults `top_p=1.0` and can't be nulled — that breaks its model-`id` property `f"{top_p:.2f}"` — and litellm `drop_params` does NOT gate it: the price-table entry lacks `supports_top_p:false`, so litellm passes it through and Bedrock 400s).

**✅ MEASURED APC hit-rate (analyzer `_cache_analyze.py`, gate = ≥~90% on the API path):**

| Scaffold | Model | Route | n | turns | APC hit | $/task | no-cache $ |
|---|---|---|---|---|---|---|---|
| OpenHands/rebench | Haiku 4.5 | Anthropic direct | 4 | 55–108 | **97.49%** | $0.65 (Haiku) | — |
| OpenHands/rebench | Opus 4.7 | **Bedrock** | 1 | 28 | **94.81%** | $1.09 | $5.36 (−79.7%) |
| SWE-agent/Pro | Haiku 4.5 | Anthropic direct | 1 | 57 | **95.68%** | — | — |
| SWE-agent/Pro | Opus 4.7 | **Bedrock** | 1 | 24 | **90.98%** | $0.52 | $1.72 (−69.9%) |

Per-turn shape (both scaffolds): turn 1 small/uncached → turn 2–3 the cache-creation spike → turns thereafter **95–99%** steady, with `uncached` flat at ~1–11 tokens/turn (the SDK/overlay extend the cached prefix each turn). Aggregate APC rises with run length (startup is amortized): the 57-turn Haiku Pro run hit 95.7%, the 24-turn Opus Pro run 91.0% — both ≥90%. **Gate MET on the API/Bedrock path for both scaffolds.** Caching cuts Opus input cost ~10× (cache_read $0.55/M vs uncached $5.50/M; output $27.50/M, cache_write $6.875/M — litellm cross-region table for `us.anthropic.claude-opus-4-7`).

**✅ Frontier-API n≈10 smoke (Opus 4.7 via Bedrock, caching VERIFIED), graded:**

| Cell | n | turns | overall APC | resolved | $/task (cached) | no-cache $ |
|---|---|---|---|---|---|---|
| **rebench / OpenHands** | 12 | 9–76 | **97.22%** | 4/12 | $1.71 ($0.24–4.74) | $124.35 total (−83.5%) |
| **Pro / SWE-agent** | 10 | ~17 avg | **89.47%** (batch-agg) | 3/10 (acc 0.30) | $0.48 | $15.28 total (−68.4%) |

- **rebench (OpenHands)**: every one of 12 instances individually ≥ 92.7% APC (92.7–98.1%); aggregate 97.22% (cache_read 21.14M / prompt 21.74M; uncached 9.6k total across 12 runs). Cost scales with turns: the 76-turn `spikeinterface` task = $4.74, the 9-turn `openmdao` = $0.24. **Graded 4/12 resolved** — a real Opus capability signal (vs Haiku 0/5 in `3xi.2.1`), grader discriminates.
- **Pro (SWE-agent)**: the n=10 batch shared one cache-probe label, so the 89.47% **aggregate** sums 10 instances' cache-creation startups (each ~3–5 sub-threshold turns) and 4 early-terminating instances (6/10 produced non-empty patches) — both pull the aggregate down. The **per-instance steady-state is ≥90%** as the single full-length runs show (Opus 90.98% @24 turns, Haiku 95.68% @57 turns, per-turn 94–97%). **Graded 3/10 resolved** (`swe_bench_pro_eval.py`, accuracy 0.30). The 10 instances were the smallest headless-Python set (openlibrary/ansible, 1–2 tests) for fast/reliable grading → their $/task ($0.48) is a **lower bound**; real stratified Pro tasks run far longer. *(Minor follow-up: 4/10 empty patches — investigate whether early Opus terminations are a call-limit or scaffold issue at powered n.)*

**Cost projection for Phase 3 (`3xi.2.3`, powered n≥40–50), dated 2026-06-16.** Driver is **turns** (transcript length): under caching, per-turn input ≈ the cached prefix (cache_read) + a small write, so cost grows ~linearly in cumulative prompt tokens, ~linearly in turns. Anchors (Opus 4.7 Bedrock cross-region, litellm table $5.50/$27.50/$0.55/$6.875 per-M in/out/cache-read/cache-write):
- **rebench cell** (OpenHands, diverse real-size tasks): measured $1.71/task → **n=50 ≈ $85/model**.
- **Pro cell** (SWE-agent): the n=10 here used minimal instances ($0.48); the powered run uses a **stratified** 50-set incl. large multi-file tasks. Using the rebench real-size envelope ($1.71 avg, up to ~$4.7 for 70–76-turn tasks) as the Pro analog → **n=50 ≈ $85–250/model** depending on stratum mix.
- **Without prompt caching** these are **~3–6× higher** (measured counterfactuals: rebench 6.05×, Pro 3.16×) — i.e. caching turns a ~$500–1500/model powered cell into ~$85–250/model. **This is the O(turns²) guard paying off**, and is why the gate blocks any powered API run until caching is verified.
- **Roster**: the above is **per frontier-API model per cell**; multiply by the API-model count in the `rlp` roster (Opus-class + any other API models). Open-weight models run on vLLM rentals (separate $, not Bedrock).

**GATE (Phase 2) — MET.** (i) APC ≥ ~90% on the API/Bedrock path for both scaffolds (rebench 97.22%; Pro per-instance/steady-state ≥ 90%, 89.47% batch-aggregate with the documented startup-amortization reason). (ii) Per-task $ within budget ($0.24–$4.74). (iii) Both scaffolds produce **graded** results with caching ON (rebench 4/12, Pro 3/10 resolved). (iv) Dated cost projection exists (above). Powered screening (`3xi.2.3`) remains gated on `9g4.3`/`9g4.4`/`b51`.



**Reproducible artifacts (`scripts/runners/`):** `_cache_probe.py` (litellm round-trip probe, both routes), `_cache_analyze.py` (APC + cost decomposition + no-cache counterfactual, `--source openhands|sweagent`, `--price opus47|haiku45`), `sitecustomize.py` (SWE-agent litellm cache-usage probe + Bedrock param scrub), `_sweagent_cache_overlay.yaml` (restores cache_control on the Pro path), `_swebench_pro_select_n.py` (n-instance Pro selector); `run-swebench-pro-smoke.sh` + `run-swerebench-smoke.sh` updated to drive caching + Bedrock Opus.

## 4e. Phase-3 execution log — powered SWE-bench Pro screening cell (2026-06-23, `bd 3xi.2.3`)

Run on the standing harness box `<HARNESS_INSTANCE_ID>` (campaign `frontier-poolb-2026-05`, m6i.2xlarge) over SSH-over-SSM. This is the **canonical Pro cell** of Phase 3: SWE-bench Pro public set, **SWE-agent** scaffold, **pass@1**, **single-stream** (`--num_workers 1`), frontier-API model via the box's Bedrock.

**Model.** `bedrock/us.anthropic.claude-opus-4-8` (Opus 4.8 — current frontier Opus on 2026-06-23; the Phase-2 smoke used 4.7). Both 4.7 and 4.8 are invokable on the box's harness-driver-role Bedrock grant (live-probed). Thinking: **off** — SWE-agent's model config sets no `thinking` param and Opus 4.8 runs without thinking when unset. Dual thinking-mode (thinking-on) is a follow-up (each mode is a ~4 h single-stream run) under the powered-roster expansion.

**Subset — stratified, not the easy-biased smallest-N.** New committed selector `_swebench_pro_select_stratified.py` draws a **difficulty-stratified, repo-balanced n=51** subset (global test-count terciles small ≤8 / medium ≤28 / large >28 tests × repo, ~8–9 per cell), replacing `_swebench_pro_select_n.py`'s N-smallest bias (the Phase-2 cost lower-bound sample). **Scope caveat (honest):** the SWE-agent local-docker substrate + grader were validated **Python-only** (Phase 0/1); within the Pro public set (Go 280 / Python 266 / JS 165 / TS 20) only **ansible + openlibrary** are headless Python (qutebrowser is GUI). So this is the **headless-Python stratum** of the public set — a screening approximation, **NOT** the full multi-language 731. Multi-language expansion (esp. the Go plurality) + per-language grading is the **`bd 3xi.2.4`** follow-up.

**Caching (Phase-2 gate, re-verified on Opus 4.8).** Aggregate **APC hit-rate 93.5%** over the full 631-call batch (cache_read 8.76 M / prompt 9.37 M; `uncached` 5.7 k total ≈ flat per turn) — gate (≥~90%) **met**. Cell cost **≈ $13.92** (Opus 4.8 Bedrock cross-region, cached) vs **$56.48** no-cache counterfactual → caching saved **75.4%**; the O(turns²) guard held. ≈ $0.27/task averaged over n=51.

**Loop / no-progress guard.** For the **Pro / SWE-agent** scaffold the bound is SWE-agent's native `per_instance_call_limit` (**75**, canonical loop budget) — the scaffold's own no-progress guard. (The event-based detectors `_swerebench_progress_watch.py` / `_cybergym_progress_watch.py` are OpenHands-V1 / CyberGym-V0 specific and do not apply to SWE-agent run-batch.)

**Wall-clock optimization (infra, not a scaffold change).** All 51 per-instance Pro images were pre-pulled concurrently (8-wide) before the agent run, removing image pulls from the single-stream critical path; the agent run stayed `--num_workers 1`.

**⚠️ Validity note — first run contaminated, discarded; this is a clean re-run.** During the first run, concurrent diagnostic `docker build`s (run to root-cause the build failures, below) plus a too-broad `pkill -f "docker build"` (which also matches swe-rex's per-instance deploy build) risked perturbing in-flight instances, and the CPU/memory pressure of those CPython-compile builds wedged the box's SSM agent (ConnectionLost) mid-run. The first run was **archived (`*.CONTAMINATED`) and NOT used.** The box was power-cycled (EBS `/data` + all 51 cached images preserved) and the **full 51-instance cell was re-run clean — eval only, no concurrent load, single-stream** (226 min, `SWEAGENT_EXIT=0`). All numbers below are from the clean re-run.

**Harness-health — swe-rex build-failure rate + ROOT CAUSE.** swe-rex builds a standalone-CPython layer on top of each Pro image (`swerex/deployment/docker.py:_build_image`). **12/51 instances** failed this build → no patch → counted **not-resolved** (honest pass@1). **Root cause (diagnosed):** the layer's Python 3.11.8 is compiled against `python:3.11.9-slim-bookworm` (glibc 2.36); ansible's older base image lacks those symbols (`/root/python3.11/bin/python3: version 'GLIBC_2.34' not found`), so the copied binary won't run. openlibrary's image is bookworm-based (newer glibc) → builds fine. **Candidate fix:** build the standalone Python against the **oldest** target glibc (`python:3.11.9-slim-bullseye`, glibc 2.31) so the binary runs on every base (glibc is backward- not forward-compatible) — to be validated + applied in `bd 3xi.2.4`. These build failures are a **harness substrate gap, not model incapability**; the cell reports raw pass@1 (n=51) AND a conditional pass@1 (over built instances).

**Grading — deterministic, audited.** Graded from the repo dir with `swe_bench_pro_eval.py --use_local_docker` (resolved iff `(fail_to_pass ∪ pass_to_pass) ⊆ passed_tests`). Per-instance grading-audit triangulation (server aggregate bool vs. per-test `workspace/output.json` recompute of the subset contract): **ok=39, mismatch=0, unverifiable=12** (the 12 build-fails have no test output to recompute). Grader fully self-consistent.

**✅ RESULT (tagged: scaffold=SWE-agent · max_turns/call_limit=75 · quant=none(frontier API) · thinking=off · 2026-06-23):**

| Cell | n | resolved | **pass@1** | Wilson 95% CI | predictions (non-empty) | build-fail | cond. pass@1 (on built) |
|---|---|---|---|---|---|---|---|
| **SWE-bench Pro (headless-Python stratum) · SWE-agent · Opus 4.8** | 51 | 13 | **0.255** | [0.156, 0.389] | 39 (17) | 12 | 13/39 = 0.333 |

- **By difficulty tercile:** small 7/18 (0.389 [0.203,0.614]) · medium 3/17 (0.176 [0.062,0.410]) · large 3/16 (0.188 [0.066,0.430]) — a clean difficulty gradient.
- **By repo:** ansible 9/26 (0.346 [0.194,0.538]) · openlibrary 4/25 (0.160 [0.064,0.347]).
- **Patch production:** 39/51 built + ran; of those, **17 produced a non-empty patch** (22 empty — agent built+ran but did not submit a diff; the early-termination pattern flagged in Phase-2 §4d). All 13 resolved are among the 17 non-empty → **13/17 = 0.76 when a patch was actually produced**. Whether the 22 empties are a call-limit or scaffold-config issue is a follow-up (`bd 3xi.2.4`).

**Anchor (date-stamped, contamination-caveated).** Scale **SEAL public SWE-bench-Pro leaderboard** is the cross-comparable anchor (SWE-agent is its canonical scaffold). Treat as indicative — confirm against the live SEAL leaderboard before citing; note (a) this cell is the headless-Python stratum, not the full 731, and (b) Pro's public set is GPL/copyleft by design (contamination deterrent), so leaderboard numbers carry the usual contamination caveat.

**Recorded into the dashboard pipeline.** Cell written to S3 as a Pool B `results.json` (`frontier-poolb-swebenchpro-3xi23-2026-06-23/opus48/swebench-pro/results.json`, the pipeline's source of truth), with `board-meta.json` registry entries added (a `swebench-pro` Pool-B bench + an `opus-4-8` frontier model; rev r23→r24); `board.json` + `sweep-status.md` + `criterion-matrix.html` + `sweep-explorer.html` regenerated from S3 (board.json is regenerated-only, never hand-edited).

**Reproducible artifacts (`scripts/runners/`):** `_swebench_pro_select_stratified.py` (difficulty-stratified subset selector); reuses `run-swebench-pro-smoke.sh` + `_sweagent_cache_overlay.yaml` + `sitecustomize.py` + `_cache_analyze.py` + `_swerex_docker_libffi_patch.py` from Phases 0–2.

**Follow-ups (`bd 3xi.2.4`, Phase 5):** wire the SWE-bench Pro stack into `install-harness.sh` (so fresh boxes self-provision it for the full open-weight roster screening); ~~apply + validate the bullseye glibc fix to cut the 12/51 build-failure rate~~ **(done — `bd 3xi.2.5`, §4f below)**; add Go/JS/TS coverage + per-language grading; investigate the empty-patch rate (call-limit vs scaffold config); add the dual thinking-mode + `canonical_condition`; update `eval-battery.md`/README.

## 4f. swe-rex glibc/OpenSSL harness fix — re-run of the 12 build-failed instances (2026-06-24, `bd 3xi.2.5`)

The 12/51 build failures in §4e were a **harness substrate** failure (swe-rex's standalone-CPython layer), not model incapability. Root-caused, fixed, validated, and the 12 instances re-deployed + re-run + re-graded on the same standing box `<HARNESS_INSTANCE_ID>`.

**Root cause (refined — the §4e candidate was incomplete).** The 12 failures were **not** ansible-clustered as first hypothesised; they were the **glibc-2.31 subset of BOTH repos** (4 ansible + 8 openlibrary). The Pro base images are a **mixed glibc population**: ~24% ship glibc 2.31 (ansible Ubuntu 20.04 Focal / openlibrary Debian 11 bullseye) and ~76% ship glibc 2.36 (bookworm-based, both repos). swe-rex compiles the standalone Python 3.11.8 in a `python:3.11.9-slim-bookworm` builder (glibc 2.36) and COPYs the binary into the base image; on the glibc-2.31 images the `RUN python3 --version` build step fails (`version 'GLIBC_2.34' not found`) → no deploy → no prediction.

**The §4e one-line candidate (builder → bullseye) is INSUFFICIENT alone — validated on the box.** Switching the builder to `python:3.11.9-slim-bullseye` (glibc 2.31) does fix the old-glibc images (glibc is backward- not forward-compatible, so a 2.31 binary runs everywhere). **But bullseye ships OpenSSL 1.1.1**, so the bullseye-built python's `_ssl.so` links `libssl.so.1.1`/`libcrypto.so.1.1`; the **bookworm** bases carry only OpenSSL 3 (`libssl.so.3`) → `import ssl` fails there → the production-stage `pip3 install swe-rex` errors with *"ssl module is not available"* → build fails. A naive bullseye swap would therefore have **traded** the 12 glibc failures on old bases for ~39 new ssl failures on the bookworm bases.

**Fix (delivered, idempotent, self-verifying — `scripts/runners/_swerex_docker_libffi_patch.py` Fixes 3+4).** (3) builder base `bookworm → bullseye` (oldest target glibc); (4) **bundle** the builder's `libssl.so.1.1` + `libcrypto.so.1.1` into the standalone lib dir `/root/python3.11/lib` (already on `LD_LIBRARY_PATH`), so ssl is base-image-independent — those 1.1 libs only need glibc 2.31, which every base satisfies. The patch re-renders `glibc_dockerfile` after patching and asserts the bullseye builder + bundled OpenSSL + libffi + pip-index are all present. **Validated on the box (idle)** against both strata via the real swerex code path: build OK + `python3 --version` (3.11.8) + `swerex-remote --version` (1.4.0) + `import ssl` (OpenSSL 1.1.1w) on an old-glibc ansible image AND a bookworm openlibrary image.

**Re-run (single-stream, identical config to §4e).** The 12 previously-build-failed instances re-run with `MODEL=bedrock/us.anthropic.claude-opus-4-8`, `CALL_LIMIT=75`, `--num_workers 1`, cache on (~87 min, `SWEAGENT_EXIT=0`). **All 12 deployed** (build-failure rate **12 → 0**); 3 produced non-empty patches; 2 resolved (both openlibrary). New 12-instance grades merged with the 39 from §4e into a unified 51-instance grade dir + `preds.json`; `strat_tally.py` re-run over the full 51.

**✅ RESULT — before → after (same tag: SWE-agent · call_limit=75 · thinking=off):**

| | n | resolved | **pass@1** | Wilson 95% CI | build-fail | predictions (non-empty) | grading audit |
|---|---|---|---|---|---|---|---|
| §4e (pre-fix) | 51 | 13 | 0.255 | [0.156, 0.389] | **12** | 39 deployed (17) | ok=39, unverifiable=12 |
| §4f (post-fix) | 51 | 15 | **0.294** | [0.187, 0.430] | **0** | **51 deployed (20)** | **ok=51, mismatch=0, unverifiable=0** |

- **Build-failure rate 23.5% → 0%**; raw and conditional pass@1 now **converge** (all 51 built ⇒ conditional-on-built = raw = 0.294), exactly as predicted in `bd 3xi.2.5`.
- By tier: small 9/18 (0.500) · medium 3/17 (0.176) · large 3/16 (0.188). By repo: ansible 9/26 (0.346) · openlibrary 6/25 (0.240).
- The remaining empty-patch rate (31/51 empty, incl. 9 of the 12 re-runs) is the **separate** scaffold/call-limit pattern flagged in §4d/§4e — a `bd 3xi.2.4` follow-up, **not** this harness bug.
- **Recorded:** S3 `…/opus48/swebench-pro/results.json` overwritten with post-fix numbers (`build_failures: 0`, `resolved: 15`, `post_fix_refill_3xi25` block; old object kept as `…results.json.prefix-glibc-13of51.bak`); dashboard regenerated from S3 (board-meta `r24 → r25`; `board.json` + `sweep-status.md` + `criterion-matrix.html` + `sweep-explorer.html`).

## 4g. Parallel Pro harness + vLLM wiring + install-harness Pro provisioning (2026-06-26, `bd 3xi.2.6` P1/P2 + `3xi.2.4` #1)

The SWE-bench Pro column is wall-prohibitive at the §4e single-stream config (226 min / 51 instances) and, for the open-weight roster bulk (served by ONE vLLM endpoint on ONE GPU), is **inference-bound** — the same `35u`/`9g4.2.2`/`b51` serving ceiling. `bd 3xi.2.6` makes the Pro/SWE-agent runner vLLM-capable + N-wide-safe; `bd 3xi.2.4` #1 wires the whole Pro stack into `install-harness.sh` so a fresh box self-provisions it (instead of reusing the hand-built standing box `<HARNESS_INSTANCE_ID>`). This session did the **box-free repo work (P1)** + the **read-only on-box stack confirmation (P2)**; the GPU-bound safe-N characterization + wall-cut demo (P3) is filed as remaining.

**P1 — repo-side (box-free).**
- **vLLM / OpenAI-compatible route added to `run-swebench-pro-smoke.sh`.** It previously branched only `bedrock/*` vs direct-Anthropic — no way to drive the open-weight column. Now three routes selected by `MODEL`: `bedrock/*` | `openai/*` (or `VLLM=1`) | direct-Anthropic. The vLLM route exports `OPENAI_API_BASE`/`OPENAI_API_KEY` (the **reliable** litellm channel — the Pool B finding in §4c-era `run-pool-b.sh` is that `api_base` passed via model-args is NOT forwarded by some litellm callers; we also pass `--agent.model.api_base` for SWE-agent), resolves the key literal/SSM/placeholder mirroring `_lib.sh`, enforces https-only (localhost exempt), and pre-flights the endpoint (`/models` → `chat/completions` fallback).
- **Caching gotcha closed.** The Anthropic `cache_control` overlay is now **skipped** on the vLLM route (vLLM does prefix caching server-side; `cache_control` is an Anthropic-schema-only message field an OpenAI endpoint can reject), while the per-call usage probe (`sitecustomize.py`) still loads on **all** routes to capture per-turn **output/decode** tokens — the input to safe-N. Confirmed the probe's `temperature`/`top_p` scrub is gated to Bedrock-Opus model ids, so it is a **no-op** on the vLLM path (vLLM accepts sampling params) — the exact gotcha the issue flagged.
- **Builder pre-warm (`_swebench_pro_prewarm.py` + runner step).** At `NUM_WORKERS>1`, N parallel swe-rex deploys would each kick off the identical standalone-CPython compile at once → the §4e/`3xi.2.5` OOM-wedge. The `builder` stage of the (3xi.2.5-patched) `glibc_dockerfile` is **image-independent**, so one throwaway `DOCKER_BUILDKIT=1 docker build --target builder` warms the shared BuildKit stage cache; every deploy then reuses it and runs only the cheap production stage. The helper applies the swe-rex patch (idempotent), renders the dockerfile via swe-rex's own API, builds, and verifies the re-build reports `CACHED`. Runs `auto` at N>1; non-fatal on failure.

**P2 — on-box stack confirmation (read-only; box started → captured → STOPPED).** Restarted `<HARNESS_INSTANCE_ID>`, captured `/opt/harnesses/swebench-pro`, stopped it. Findings (now baked into `install-harness.sh` as VERIFIED, replacing the drafted CONFIRM-ON-BOX markers):
- repo `scaleapi/SWE-bench_Pro-os` @ `ca10a60`; **SWE-agent is a git submodule** at path `SWE-agent` (url `scaleapi/SWE-agent`, branch `scale-customizations`, pinned `402a7b8` = `v1.1.0-42-g402a7b8` — a **non-tip** commit, so submodule init must **not** be `--depth 1`); a second `mini-swe-agent` submodule we don't need.
- grader venv `.venv`: `pandas 3.0.3 / docker 7.1.0 / datasets 5.0.0` (repo ships `requirements.txt`: pandas/tqdm/datasets/modal/docker/huggingface_hub); SWE-agent venv `.venv-sweagent`: `sweagent 1.1.0` installed **`-e`**, `swe-rex 1.4.0` (dep), **live-patched** (bullseye builder + bundled OpenSSL 1.1 + libffi + pip-index all present, builder stage named `builder`). Both venvs **python 3.12.3**; **Docker 29.1.3 with BuildKit default** — confirming the pre-warm's cross-`docker build` stage-cache-reuse assumption holds.
- `data/instances.yaml` (731 entries, per-instance `image_name: jefzda/sweap-images:<tag>` + `instance_id`) is **NOT git-tracked** — generated by `helper_code/generate_sweagent_instances.py --dockerhub_username jefzda`. The fork's own `patch.py` patches `swerex/deployment/modal.py` (Modal path) — we **don't** run it (local-docker is patched by `_swerex_docker_libffi_patch.py`).
- **`install-harness.sh --pool-b-pro`** now provisions all of the above (clone+submodule, both venvs, swe-rex patch, cache overlay + usage probe staging, instances.yaml generation), idempotent, FAIL-LOUD if the swe-rex patch can't apply.

**P3 — REMAINING (GPU-bound, filed).** Characterize SWE-agent per-turn decode volume on a target open-weight model (thinking off AND on) via the usage probe → place on the `9g4.2.2` safe-N curve (or a small N=2/4/6 contention smoke against a `gpu-rental-flow` rental) → pick safe-N (per-stream slowdown below the `per_instance_call_limit=75` timeout, watch vLLM `num_preemptions`) → demo wall-cut vs N=1 with pass@1 unchanged + the pre-warm demonstrably preventing concurrent CPython compiles in the N-wide deploy logs. Gated behind P1/P2 per the session plan; needs a vLLM endpoint, so deferred to a follow-up session.

## 4h. P3 contention smoke on a live Spark — ejv-harness → <SPARK_NODE_1> vLLM (2026-06-26, `bd 3xi.2.6` P3, `72m`)

P3 ran the same session against an **already-idle** internal Spark, not a fresh rental: **<SPARK_NODE_1>** (NVIDIA GB10 / Grace-Blackwell "DGX Spark", aarch64) was serving an idle vLLM endpoint `qwen3.6-27b-fp8` (`--max-model-len 262144 --max-num-seqs 8 --enable-prefix-caching --reasoning-parser qwen3`, i.e. **thinking-ON** by default), and **ejv-harness** (x86_64 internal VM, the idle CyberGym wall-anchor box, Docker 29) reaches it on the internal net. The Pro images are x86 + swe-rex compiles an x86 CPython, so the harness must be x86 (the dgx is ARM, LLM-server-only).

**Provisioning validated end-to-end (3xi.2.4 #1 / P2 in the real).** Stood up `/opt/harnesses/swebench-pro` on ejv from scratch via the same steps `install-harness.sh --pool-b-pro` runs; the generated `data/instances.yaml` came out **byte-identical to i-043** (2 998 409 B). This surfaced fixes the box-free P1/P2 work couldn't (all committed):
- **swe-rex must be pinned `==1.4.0` AFTER the editable install** — SWE-agent 1.1.0 pins `swe-rex==1.2.0`, whose `glibc_dockerfile` uses a different builder base the `_swerex_docker_libffi_patch.py` anchors don't match (fresh installs pulled 1.2.0 → patch FAILED). The i-043 stack was manually bumped to 1.4.0.
- **Docker buildx is required for the BuildKit path** — Docker 29 routes `docker build`+`DOCKER_BUILDKIT=1` through the buildx CLI plugin and ERRORS if it's absent (ejv had no buildx; i-043 did). Fixes: install buildx in provisioning; make the runner + pre-warm **backend-adaptive** (BuildKit iff buildx present, else the legacy builder, which also caches layers across builds) and set the choice ONCE so swe-rex + the pre-warm share one cache; pass `--build-arg BASE_IMAGE` so BuildKit can parse the production `FROM $BASE_IMAGE` under `--target builder`.
- **The vLLM endpoint is plaintext http on a private IP** (`http://10.61.0.21:8080/v1`) — relaxed the runner's TLS guard to allow RFC1918 / `*.internal` (not just localhost); public-IP plaintext still rejected.

**vLLM route — works.** `MODEL=openai/qwen3.6-27b-fp8 VLLM_API_BASE=http://10.61.0.21:8080/v1` ran the SWE-agent loop end-to-end (probe 200, `CACHE=probe-only` = overlay correctly skipped, usage probe on).

**Builder pre-warm — VERIFIED.** One `docker build --target builder` (BuildKit) compiled CPython once; the re-build reported **6 CACHED steps**; an N=4 run showed **0 "Building image" CPython recompiles** across the 4 concurrent deploys. The §4e/3xi.2.5 concurrent-compile OOM-wedge is removed.

**Decode volume — MEASURED, with a probe caveat (qwen3-parser-specific, do NOT over-generalize).** The `sitecustomize.py` litellm probe reported `completion_tokens` ≈ **57/call** (min 41, max 71 over 16 calls) — but on THIS endpoint that is **content-only and undercounts reasoning**, because the server runs vLLM `--reasoning-parser qwen3`, which moves reasoning into `reasoning_content` and out of `usage.completion_tokens`. vLLM's own `generation_tokens_total / requests` ≈ **312/call** (`request_generation_tokens` histogram ≈ 195/call) is the true decode. The undercount is a function of the **server's reasoning-parser config**, not a universal property of reasoning models — a model served WITHOUT a reasoning-parser (reasoning in-band in content) reports it in `completion_tokens`. **Practical rule: cross-check the probe against vLLM `/metrics` `generation_tokens` per endpoint** (and the probe should be extended to read it). The ~195–312 figure is **qwen3.6-27b-on-SWE-agent-specific**; every roster model is measured separately (the issue's own "characterize PER MODEL").

**Safe-N / contention — for THIS model+SKU the binding constraint is COMPUTE, not the queue (per-model; do NOT generalize the number).** A clean N=4 run (orphan removed — see lesson) held vLLM **`num_requests_running=4`, `num_requests_waiting=0`** (no queuing, no preemptions, GPU 95%): `--max-num-seqs 8` gives queue headroom to N=8. **But this single GB10 serving qwen3.6-27b-fp8 thinking-ON is compute-bound** — per-call latency rose ~45 s (N=1) → ~2 min (N=4) under 4 concurrent decode streams. So **here safe-N is a throughput-vs-N knee (the `35u` regime), below the max-num-seqs=8 queue ceiling**; the wall-cut is real but bounded by per-stream slowdown, not the free `N×` of a quota-bound API cell. This regime is **specific to this model size / quant / GPU / thinking-mode** — a terser or smaller roster model on the same Spark may sit in the "parallelizes ~freely" regime and reach a much higher safe-N; each must be re-measured. A precise wall-optimal N + wall-cut ratio needs a controlled throughput-vs-N sweep at matched context positions (probe reading vLLM-side generation tokens) — the remaining refinement on `72m`. Validity (pass@1 unchanged vs N=1) holds structurally: each instance is an isolated container with an independent conversation; N only schedules.

**Operational lessons (folded into the runbook).** (a) `pkill -f run-swebench-pro-smoke` does NOT kill the `sweagent run-batch` **child** — an orphan kept calling the endpoint for ~17 min and contaminated a measurement; kill `sweagent run-batch` explicitly and remove swe-rex containers by **id** (their `Config.Image` is the derived build sha256, not a `sweap` name). (b) Never `scp`-overwrite a **running** bash script (it corrupts the in-flight parse). (c) The dgx endpoint was pre-existing and left running (not ours to stop); ejv's Pro stack is left provisioned for the screening cell.

## 5. Environment notes / open questions for the operator
- **Disk:** Pro images are *pulled* from `jefzda/sweap-images` (not built) — lighter than CyberGym, but confirm the pulled-set size + EBS headroom on the EC2 harness `[E→ measure in Phase 0]`.
- **Second scaffold dependency:** adding **SWE-agent** to the repo is the one new dependency this plan introduces. It is justified (canonical Pro cell + uplift A/B partner). Veto path: OpenHands-only, bridging OH to Pro's pre-built images + `run_scripts` grader (more adapter work, and our Pro number then won't match the SEAL leaderboard).
- **Copyleft repos:** Pro's public set is GPL/copyleft *by design* (contamination deterrent). We only *run evals* against them (no redistribution), so no license issue — but worth noting in the methodology doc.
- **Frontier anchors are noisy:** several 2026 leaderboard numbers are third-party aggregators (some adversarially flagged as possibly SEO-fabricated). Treat all anchors as **indicative, date-stamped, confirm against the live SEAL/leaderboard before citing** — consistent with `eval-battery.md`'s existing guidance.

---

## 6. bd decomposition (filed 2026-06-15, operator-approved)

- **`3xi.2.1`** Phase 0–1: stand up SWE-bench Pro (SWE-agent) + SWE-rebench V2 (OpenHands) harnesses on the EC2 host; pin stack/images; no-LLM + cheap-model small-n validation incl. grading audit + loop-detector reuse. *(start now; not blocked by 9g4)*
- **`3xi.2.2`** Phase 2: verify prompt-caching on the API path (≥~90% hit) + frontier-API n≈10 smoke + cost projection. *(blocks any powered API run)*
- **`3xi.2.3`** Phase 3: screening cells — Pro public (SWE-agent) + rebench V2 slice (OpenHands) across the roster at powered n.
- **`3xi.2.4`** Phase 5 durability: `eval-battery.md` + README + board `benches[]`/`canonical_condition` + runner scripts + dashboard wiring.
- **(epic-level)** `3xi.3` consumes Phase 4 uplift A/B; `3xi.1` consumes Phase 4 language strata. File the uplift/strata runs under the siblings, cross-referenced.

**Dependencies (wired, cycle-checked clean):** `3xi.2.1 → 3xi.2.2 → 3xi.2.3 → 3xi.2.4`; `3xi.2.3` additionally blocked-by `9g4.3` (power), `9g4.4` (loop detector validated), `b51` (parallel harness). Net: **`3xi.2.1` is the only ready child today** — Phases 0–2 proceed independent of 9g4; powered screening (`.3`) waits on the 9g4 foundation.
