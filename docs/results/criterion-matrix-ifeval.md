# ifeval — multi-criterion matrix

_76 rows across 18 (campaign, model) pairs._

| campaign | model | inst_level_loose_acc | inst_level_strict_acc | prompt_level_loose_acc | prompt_level_strict_acc |
|---|---|---|---|---|---|
| 0em-bump-opus47-ifeval-2026-05-14 | bedrock/us.anthropic.claude-opus-4-7 | 0.9667 | 0.9000 | 0.9500 ± 0.0500 | 0.8500 ± 0.0819 |
| 0em-restore-gpt55-ifeval-2026-05-14 | openai/gpt-5.5 | 0.9667 | 1.0000 | 0.9500 ± 0.0500 | 1.0000 ± 0.0000 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-6-v1 | 0.9436 | 0.9185 | 0.9168 ± 0.0119 | 0.8780 ± 0.0141 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-7 | 0.8993 | 0.8717 | 0.8669 ± 0.0146 | 0.8318 ± 0.0161 |
| gpt55-full-2026-05-12 | openai/gpt-5.5 | 0.8765 | 0.8693 | 0.8651 ± 0.0147 | 0.8558 ± 0.0151 |
| nemotron-3-super-nvfp4-2026-05-12 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 0.5048 | 0.4341 | 0.3826 ± 0.0209 | 0.2976 ± 0.0197 |
| nemotron-3-super-nvfp4-2026-05-12-v2 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 0.8945 | 0.8489 | 0.8466 ± 0.0155 | 0.7837 ± 0.0177 |
| qwen3-5-122b-a10b-nvfp4-2026-05-13 | openai/Sehyo/Qwen3.5-122B-A10B-NVFP4 | 0.9305 | 0.9053 | 0.8965 ± 0.0131 | 0.8614 ± 0.0149 |
| <CAMPAIGN>-2026-05-15-rerun | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | 0.8981 | 0.8765 | 0.8632 ± 0.0148 | 0.8299 ± 0.0162 |
| <CAMPAIGN>-thinking-on-smoke-2026-05-15 | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | 0.8333 | 0.8667 | 0.8000 ± 0.0918 | 0.8500 ± 0.0819 |
| <CAMPAIGN>-qwen36-27b-fp8 | openai/Qwen/Qwen3.6-27B-FP8 | 0.4341 | 0.4281 | 0.2957 ± 0.0196 | 0.2921 ± 0.0196 |
| <CAMPAIGN>-qwen36-62l-2026-05-11 | openai/Qwen/Qwen3.6-27B-FP8 | 1.0000 | 1.0000 | 1.0000 ± 0.0000 | 1.0000 ± 0.0000 |
| <CAMPAIGN>-retry | openai/Qwen/Qwen3.6-27B-FP8 | 0.9341 | 0.9065 | 0.8983 ± 0.0130 | 0.8614 ± 0.0149 |
| <CAMPAIGN>-retry-smoke | openai/Qwen/Qwen3.6-27B-FP8 | 1.0000 | 0.9444 | 1.0000 ± 0.0000 | 0.9000 ± 0.1000 |
| <CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12 | openai/Qwen/Qwen3.6-35B-A3B-FP8 | 0.9125 | 0.8813 | 0.8706 ± 0.0144 | 0.8262 ± 0.0163 |
| <CAMPAIGN>-gemma31-2026-05-11 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | 0.9436 | 0.9293 | 0.9150 ± 0.0120 | 0.8965 ± 0.0131 |
| <CAMPAIGN>-gemma4-31b-it-nvfp4 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | 0.9460 | 0.9317 | 0.9205 ± 0.0116 | 0.9002 ± 0.0129 |
| <CAMPAIGN>-gemma4-26b-a4b-nvfp4 | openai/nvidia/Gemma-4-26B-A4B-NVFP4 | 0.9376 | 0.9233 | 0.9076 ± 0.0125 | 0.8891 ± 0.0135 |

## Criterion spread per (campaign, model)

| campaign | model | min | max | spread |
|---|---|---|---|---|
| 0em-bump-opus47-ifeval-2026-05-14 | bedrock/us.anthropic.claude-opus-4-7 | 0.8500 | 0.9667 | +0.1167 |
| 0em-restore-gpt55-ifeval-2026-05-14 | openai/gpt-5.5 | 0.9500 | 1.0000 | +0.0500 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-6-v1 | 0.8780 | 0.9436 | +0.0656 |
| frontier-poolb-2026-05 | bedrock/us.anthropic.claude-opus-4-7 | 0.8318 | 0.8993 | +0.0675 |
| gpt55-full-2026-05-12 | openai/gpt-5.5 | 0.8558 | 0.8765 | +0.0207 |
| nemotron-3-super-nvfp4-2026-05-12 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 0.2976 | 0.5048 | +0.2072 |
| nemotron-3-super-nvfp4-2026-05-12-v2 | openai/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 0.7837 | 0.8945 | +0.1108 |
| qwen3-5-122b-a10b-nvfp4-2026-05-13 | openai/Sehyo/Qwen3.5-122B-A10B-NVFP4 | 0.8614 | 0.9305 | +0.0691 |
| <CAMPAIGN>-2026-05-15-rerun | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | 0.8299 | 0.8981 | +0.0681 |
| <CAMPAIGN>-thinking-on-smoke-2026-05-15 | openai/QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ | 0.8000 | 0.8667 | +0.0667 |
| <CAMPAIGN>-qwen36-27b-fp8 | openai/Qwen/Qwen3.6-27B-FP8 | 0.2921 | 0.4341 | +0.1420 |
| <CAMPAIGN>-qwen36-62l-2026-05-11 | openai/Qwen/Qwen3.6-27B-FP8 | 1.0000 | 1.0000 | +0.0000 |
| <CAMPAIGN>-retry | openai/Qwen/Qwen3.6-27B-FP8 | 0.8614 | 0.9341 | +0.0727 |
| <CAMPAIGN>-retry-smoke | openai/Qwen/Qwen3.6-27B-FP8 | 0.9000 | 1.0000 | +0.1000 |
| <CAMPAIGN>-qwen36-35b-a3b-fp8-2026-05-12 | openai/Qwen/Qwen3.6-35B-A3B-FP8 | 0.8262 | 0.9125 | +0.0862 |
| <CAMPAIGN>-gemma31-2026-05-11 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | 0.8965 | 0.9436 | +0.0472 |
| <CAMPAIGN>-gemma4-31b-it-nvfp4 | openai/nvidia/Gemma-4-31B-IT-NVFP4 | 0.9002 | 0.9460 | +0.0459 |
| <CAMPAIGN>-gemma4-26b-a4b-nvfp4 | openai/nvidia/Gemma-4-26B-A4B-NVFP4 | 0.8891 | 0.9376 | +0.0486 |
