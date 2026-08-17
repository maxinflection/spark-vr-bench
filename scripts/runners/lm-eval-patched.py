#!/usr/bin/env python3
"""Entry-point wrapper around lm-evaluation-harness that applies our litellm
patches before resolving the lm_eval CLI.

The patch (scripts/runners/_litellm_patches.py) rebinds `litellm.completion`
to a version that strips `temperature`/`top_p`/`top_k` for Opus 4.7 calls.
lm-evaluation-harness resolves `litellm.completion` at call-time so the
rebind takes effect — but only if our patch module is imported BEFORE the
harness's first model call. This wrapper guarantees that order.

Usage (from a bash runner):
    /opt/harnesses/lm-evaluation-harness/.venv/bin/python \
      /opt/benchmarks/scripts/runners/lm-eval-patched.py run \
      --model litellm \
      --model_args 'model=bedrock/us.anthropic.claude-opus-4-7,aws_region_name=us-east-1' \
      --tasks ifeval --output_path /tmp/results/

The args after this script's name pass straight through to `lm-eval`.
"""
import os
import sys

# Import the patch first. Side-effect: rebinds litellm.completion.
# Make the runners directory importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import _litellm_patches  # noqa: F401  -- side-effect import, intentional

# Now resolve the lm-eval CLI. cli_evaluate() reads sys.argv[1:].
from lm_eval.__main__ import cli_evaluate  # type: ignore[import-not-found]

if __name__ == "__main__":
    sys.exit(cli_evaluate())
