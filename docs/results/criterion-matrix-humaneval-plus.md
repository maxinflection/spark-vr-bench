# humaneval-plus — multi-criterion matrix

_23 rows across 20 (campaign, model) pairs._

| campaign | model | pass@1/create_test | pass@1/extract_code |
|---|---|---|---|
| 0em-bump-opus47-humaneval-v2-2026-05-14 | bedrock/us.anthropic.claude-opus-4-7 | — | 1.0000 ± 0.0000 |
| 0em-restore-gpt55-humaneval-2026-05-14 | openai/gpt-5.5 | — | 1.0000 ± 0.0000 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-6-v1 | — | 0.9268 ± 0.0204 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-7 | 0.0000 ± 0.0000 | 0.9390 ± 0.0187 |
| gpt55-full-2026-05-12 | openai/gpt-5.5 | — | 0.9390 ± 0.0187 |
| gpt55-smoke-2026-05-12 | openai/gpt-5.5 | — | 0.2000 ± 0.2000 |
| gpt55-smoke2-2026-05-12 | openai/gpt-5.5 | — | 1.0000 ± 0.0000 |
| nemotron-3-super-nvfp4-2026-05-12 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | — | 0.9085 ± 0.0226 |
| nemotron-3-super-nvfp4-2026-05-12-v2 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | — | 0.9024 ± 0.0232 |
| qwen3-5-122b-a10b-nvfp4-2026-05-13 | openai/Sehyo/Qwen3.5-122B-A10B-NVFP4 | — | 0.8720 ± 0.0262 |
| <CAMPAIGN>-2026-05-15-rerun | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | — | 0.8110 ± 0.0307 |
| <CAMPAIGN>-thinking-on-smoke-2026-05-15 | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | — | 0.9500 ± 0.0500 |
| <CAMPAIGN>-qwen36-27b-fp8 | openai/Qwen/Qwen3.6-27B-FP8 | — | 0.6951 ± 0.0361 |
| <CAMPAIGN>-qwen36-62l-2026-05-11 | openai/Qwen/Qwen3.6-27B-FP8 | — | 1.0000 ± 0.0000 |
| <CAMPAIGN>-retry | openai/Qwen/Qwen3.6-27B-FP8 | — | 0.8780 ± 0.0256 |
| <CAMPAIGN>-retry-smoke | openai/Qwen/Qwen3.6-27B-FP8 | — | 1.0000 ± 0.0000 |
| <CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12 | openai/Qwen/Qwen3.6-35B-A3B-FP8 | — | 0.8720 ± 0.0262 |
| <CAMPAIGN>-gemma31-2026-05-11 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | — | 0.9146 ± 0.0219 |
| <CAMPAIGN>-gemma4-31b-it-nvfp4 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | — | 0.9146 ± 0.0219 |
| <CAMPAIGN>-gemma4-26b-a4b-nvfp4 | openai/nvidia/Gemma-4-26B-A4B-NVFP4 | — | 0.9146 ± 0.0219 |

## Criterion spread per (campaign, model)

| campaign | model | min | max | spread |
|---|---|---|---|---|
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-7 | 0.0000 | 0.9390 | +0.9390 |
