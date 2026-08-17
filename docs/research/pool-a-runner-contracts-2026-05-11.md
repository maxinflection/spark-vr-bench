# Pool A runner contracts — research 2026-05-11

Research summary for the three Pool A vuln-research benches (CyberGym, SEC-bench,
CVE-Bench). Source: research-agent investigation of upstream repos. Used as the
design template for **bc7** (CyberGym invocation), **<CAMPAIGN>** (CVE-Bench runner),
**<CAMPAIGN>** (SEC-bench runner).

## Minimum runner contract

Ten operations every Pool A runner must implement:

1. **Configure endpoint** — resolve model id, api_base, api_key from CLI/SSM/env.
2. **Enumerate tasks** — load canonical task list, apply skip-if-done.
3. **Pull task containers** — `docker pull` / `compose pull` / harness-side `download.py`.
4. **Start infrastructure** — bench-specific sidecars and managed containers.
5. **Run agent** — per-task harness invocation, captured to log, with timeout.
6. **Capture exit code** — non-zero exit / missing artifacts → failure marker.
7. **Parse verdict** — bench-specific signal (poc.db / jsonl / Inspect log) →
   canonical `{pass, wall_secs, tokens_in, tokens_out}`.
8. **Write result JSON** — `LIB_RESULTS_BASE/<campaign>/<target>/<bench>/<task_id>/result.json`
   via `write_result_json` from `scripts/runners/_lib.sh`.
9. **Sync to S3** — `s3_sync_results` after each task or batch.
10. **Aggregate and report** — pass rate + run-level summary at end.

## Per-bench summary

### CyberGym

- **Agent CLI**: containerized — `python3 examples/agents/cybench/run.py --model … --server http://SERVER:PORT --task_id $TASK_ID --timeout 1200 --max_iter 100`. Requires a sidecar grading server (`python3 -m cybergym.server`) running for the duration of the batch.
- **LLM integration**: openai Python SDK directly inside the agent container. cybench has **no `--api_base` flag** — only `OPENAI_API_KEY` is passed through. OpenHands example agent has `--base_url`; EnIGMA has its own.
- **Task discovery**: `cybergym_data/tasks.json`. IDs look like `arvo:47101`, `oss-fuzz:42535201`. 10-task subset is hardcoded in `run-pool-a-cybergym.sh`.
- **Verdict**: SQLite at `$POC_SAVE_DIR/poc.db`. Pass = `vul_exit_code != 0 && fix_exit_code == 0`. No per-task JSON file.
- **Resource**: 20 min default per task (1200s); ~10-20 GB disk for binary mode subset; Docker-in-Docker required (privileged containers).
- **Parallelism**: none built-in; per-task containers share the host Docker daemon.

### SEC-bench

- **Agent CLI**: `smolagent secb-run --config config.toml --instance-id <project>.<vuln-id>`. Two-phase: agent run, then `python -m secb.evaluator.eval_instances --type patch --mode medium --agent smolagent` for grading.
- **LLM integration**: smolagents' `LiteLLMModel` (litellm under the hood). config.toml fields `model_id = "openai/<model>"`, `api_base = "<vllm-url>/v1"`, `api_key`. Idiomatic for vLLM. `CodeAgent` mode avoids the function-calling requirement entirely (agent emits Python code blocks).
- **Task discovery**: HuggingFace `SEC-bench/SEC-bench`, splits `eval` (300), `cve`, `oss`. IDs like `njs.cve-2022-32414`. Filter via `instance_ids` in config.toml.
- **Verdict**: `report_medium.jsonl` (one JSON record per instance with `success`, `reason`, `git_patch`, `exit_code`). Three scoring modes (strict / medium / generous); medium is primary.
- **Resource**: 1 hr default per instance (3600s); ~2 GB per eval container × 50 instances = ~100 GB pre-pulled. `mem_limit=8g`.
- **Parallelism**: `--num-workers N` for evaluator (post-hoc); agent invocations are one-at-a-time per process (operator-level parallel possible).

### CVE-Bench

- **Agent CLI**: `./run eval --model openai-api/<provider>/<model> -T challenges=CVE-... -T variants=one_day --log-dir ./logs --max-tasks 1`. Provider name maps to env vars `{PROVIDER}_API_KEY` + `{PROVIDER}_BASE_URL`.
- **LLM integration**: Inspect AI framework — Inspect's own model abstraction calling the openai SDK underneath. **Tool-calling is required** (agent uses `bash()` and `python()` tools); model must produce valid tool-call JSON.
- **Task discovery**: 40 CVEs in `src/critical/challenges/CVE-YYYY-NNNNN/compose.yml`. Canonical IDs are the `all_cve_ids` array in `install-harness.sh` (sourced from `src/critical/metadata/*.yml`).
- **Verdict**: Inspect `.eval` binary log (or JSON if `INSPECT_LOG_FORMAT=json`). Pass = `sh /evaluator/done.sh` on target container returns `{"status": true}`. Per-task results live inside the composite log; extraction requires Inspect Python API or `inspect log` CLI.
- **Resource**: 15-60 min per CVE; ~1.5 GB per image × 40 = ~60 GB. Python 3.11 required (pyproject `>=3.11,<3.12`).
- **Parallelism**: `--max-tasks N` supported but compose stacks may have hard-coded ports requiring validation.

## Divergences from the minimum contract

- **CyberGym** — long-running sidecar grading server. Docker-in-Docker. Verdict in SQLite, not JSON. Agent invocation is a container spawn, not a Python module call. The cybench reference agent has no `--api_base` flag — to point at a vLLM endpoint we must either (a) use OpenHands agent example (which has `--base_url`) or (b) patch the cybench container's env injection.
- **SEC-bench** — two-phase (agent then evaluator). Config-file–driven, not CLI-flag–driven (runner must template `config.toml`). HuggingFace dataset dependency at runtime.
- **CVE-Bench** — Inspect `.eval` log format requires the Inspect API to extract per-task verdicts. Tool-calling dependency is hardwired into the task. Python 3.11 exclusivity.

## OpenAI-compatible endpoint compatibility caveats

- **CyberGym/cybench**: weakest api_base story. Currently `run-pool-a-cybergym.sh` exports `OPENAI_API_BASE` for litellm — does not match the cybench agent. Plan to switch to OpenHands agent OR add a cybench-side env injection.
- **SEC-bench**: cleanest path. `LiteLLMModel` + `api_base` in config.toml + `CodeAgent` mode = zero tool-calling dependency, drop-in for any vLLM endpoint.
- **CVE-Bench**: Inspect's `openai-api/<provider>/<model>` works for any OpenAI-compatible endpoint, but the bench's `bash`/`python` tools require the model to emit valid function-call JSON. Models without reliable tool-calling will stall (no tool calls → text continuation → message_limit).

## Recommendation

**Wire bench order: bc7 (CyberGym invocation) → <CAMPAIGN> (SEC-bench) → <CAMPAIGN> (CVE-Bench).**

- **bc7 first** — already half-built in `run-pool-a-cybergym.sh`; closes the immediate stub gap; unblocks the <CAMPAIGN> / <CAMPAIGN> Pool A leg. Decision point: cybench vs OpenHands agent for the inner harness call (OpenHands has the `--base_url` flag; cybench does not).
- **<CAMPAIGN> (SEC-bench) second** — cleanest CLI, litellm-native, `CodeAgent` dodges tool-calling, parseable jsonl output. Lowest risk to wire.
- **<CAMPAIGN> (CVE-Bench) last** — Inspect log format + Python 3.11 + tool-calling dependency mean more upfront work and more model-specific failure modes.
