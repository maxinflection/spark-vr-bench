# bd 2lh — Gemma Pool B thinking-on on the local <SPARK_NODE_2> Spark (2026-06-17)

First time Pool B (quality battery) runs on our own hardware instead of a rented
GPU. Driven from the proxmox-02 ejv VM against the <SPARK_NODE_2> Spark.

## Topology
```
run-pool-b.sh (proxmox-02 / ejv-cybergym-harness, 10.80.0.145)
  -> http://127.0.0.1:8080/v1
  -> socat `spark-fwd` tmux (127.0.0.1:8080 -> 10.61.0.22:8080 over the site WAN)
  -> <SPARK_NODE_2> (10.61.0.22, GB10): sudo docker `vllm-poolb` (vllm-spark:latest 0.21.0)
       serving nvidia/Gemma-4-31B-IT-NVFP4 (NVFP4 modelopt), thinking-ON.
```

## Parity with the rental <CAMPAIGN> thinking-off cell (HE+ 0.915 / IFEval 0.900 / BCB-H 0.304)
- **Checkpoint**: pulled `nvidia/Gemma-4-31B-IT-NVFP4` fresh onto <SPARK_NODE_2>
  (`/opt/models/gemma-4-31b-it-nvidia-nvfp4`). <SPARK_NODE_2> previously served the
  **RedHatAI** NVFP4 (a different vendor quant) — would have been a variation.
- **Serve config** (`serve-gemma-poolb-thinking-on.sh`): matches the rental
  launcher exactly — `--quantization nvfp4 --max-model-len 131072 (output-neutral
  vs rental 262144; Pool B seqs <~18K) --attention-backend TRITON_ATTN`,
  `VLLM_NVFP4_GEMM_BACKEND=marlin`, model-default chat template, NO fp8 KV cache.
  Only thinking delta: `--reasoning-parser gemma4` + `--default-chat-template-kwargs
  '{"enable_thinking": true}'`. `--language-model-only` (text-only; output-neutral,
  required to skip the GB10 MM encoder-budget check).
- **Harness** (`provision-poolb-harness.sh`): lm-eval 0.4.13.dev0 pinned to the
  late-May companion era, litellm==1.84.0, anthropic==0.102.0, bigcodebench 0.2.5,
  bd <ISSUE> sanitize patch, bcb grading docker image. Same `run-pool-b.sh` + flags as
  the rental thinking-on companions: `--vllm-num-concurrent 8`, `--vllm-bcb-max-tokens
  16384`, greedy, `--vllm-eos-string '<end_of_turn>'`.
- RUNNER_LOG / RESULTS_BASE set to /home/max paths (EC2 defaults are root-owned here).

## Findings
- Thinking-on is genuinely active (~3x completion tokens vs off) but Gemma reasons
  in **prose in .content**, not a parser-separable channel → `reasoning_content`
  empty, `--reasoning-parser gemma4` a no-op. Faithful model behavior; higher-of-pair
  canonical handles any IFEval format penalty. HE+ smoke 2/2 pass=1.0 (code extracts).
- `enable_thinking` records as null in result.json (<CAMPAIGN> metadata gap) — same as
  the rental thinking-off cells; thinking-mode is conveyed by campaign name.

## Walltime
HE+ ~15-65s/task (~50min). IFEval thinking-on up to ~500s/task → the long pole
(~2-9h). Full 31B run est ~6-13h (overnight). Campaign:
`2lh-gemma31-poolb-thinkon-2026-06-17`.

## ⚠ S3 upload BLOCKER
`benchmarks-sandbox-agent` creds are READ-ONLY on `<RESULTS_BUCKET>`
(s3:PutObject denied; sts:AssumeRole + SSM also denied). run-pool-b's per-bench
sync no-ops; **results stay LOCAL at `/home/max/harness-results/<campaign>/vllm/<bench>/`
on proxmox-02**. To publish (acceptance = "6 result.json on S3"): upload from a box
holding `harness-driver-role` (any EC2 harness box), or grant the sandbox-agent user
s3:PutObject on this bucket prefix, then `aws s3 sync` the local tree up.

## Monitoring commands
```
ssh ejv-harness 'tmux ls; grep -oE "[0-9]+/[0-9]+ \[" ~/poolb-full.log | tail -1'
ssh ejv-harness 'cat ~/harness-results/2lh-gemma31-poolb-thinkon-2026-06-17/vllm/*/results.json | jq "{bench,pass_rate,n_tasks,wall:.wall_time_seconds}"'
ssh <SPARK_NODE_2> 'sudo docker ps --filter name=vllm-poolb; tail -3 /tmp/gemma26-dl.log'
```

## 26B-A4B swap (when 31B run finishes, if time/context)
1. Confirm 26B download done: `ssh <SPARK_NODE_2> 'cat /opt/models/gemma-4-26b-a4b-nvidia-nvfp4/.manifest.env'`
2. Stop 31B serve: `ssh <SPARK_NODE_2> 'sudo docker rm -f vllm-poolb'`
3. Serve 26B: `ssh <SPARK_NODE_2> 'DOCKER="sudo docker" MODEL_DIR=/opt/models/gemma-4-26b-a4b-nvidia-nvfp4 MODEL_ALIAS=nvidia/Gemma-4-26B-A4B-NVFP4 bash /tmp/serve-gemma-poolb.sh'`
   (socat forward unchanged — same port 8080)
4. Run: `ssh ejv-harness 'tmux new -d -s poolb-full26 "bash ~/run-2lh-poolb-spark.sh 2lh-gemma26a4b-poolb-thinkon-2026-06-17 nvidia/Gemma-4-26B-A4B-NVFP4 > ~/poolb-full26.log 2>&1"'`

## Teardown when fully done
`ssh <SPARK_NODE_2> 'sudo docker rm -f vllm-poolb'`; `ssh ejv-harness 'tmux kill-session -t spark-fwd'`.
(<SPARK_NODE_2> returns to idle for the spark-deploy throughput track.)
