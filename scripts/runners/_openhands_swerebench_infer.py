"""SWE-rebench-v2 adaptation of the OpenHands `swebench-infer` harness.

bd benchmarks-3xi.2.1 — rebench/OpenHands half. This is NOT a scaffold swap: it
is the repo's OWN per-dataset subclass idiom (cf. benchmarks/swesmith/run_infer.py
"ADAPTATION 1"). SWE-rebench-v2 differs from princeton SWE-bench only in two
SUBSTRATE facts, so we override exactly those and inherit the entire OpenHands
agent loop, condenser, tool preset, event persistence and DockerWorkspace build
pipeline from benchmarks.swebench.run_infer.SWEBenchEvaluation:

  1. Base env image — rebench ships it in the dataset `image_name` column
     (docker.io/swerebenchv2/<repo>:<n>-<sha>); SWE-bench DERIVES the name from
     the instance_id. The DockerWorkspace path layers the pinned OpenHands
     agent-server (SDK c950fdb) ON TOP of this base LOCALLY — no ghcr pull — which
     is exactly why this sidesteps the swe-rex/Pro-image quirks.
  2. Source repo path — rebench lays the git repo at /<reponame> (verified:
     codezonediitj/pydatastructs -> /pydatastructs, WorkingDir set, .git present),
     NOT SWE-bench's /testbed, and there is NO conda/testbed env (python is the
     image's /usr/local/bin/python). SWE-bench hard-codes get_source_repo_path()
     -> "/testbed", so we override it.
  3. No docutils/roman wrap (that allowlist is sphinx-doc-specific to SWE-bench).

Deploy + invoke ON the harness box, inside the openhands-benchmarks repo:
    cp _openhands_swerebench_infer.py \
       /opt/harnesses/openhands-benchmarks/benchmarks/swerebench/run_infer.py
    uv run python -m benchmarks.swerebench.run_infer <llm_config.json> \
        --dataset _rebench/slice.jsonl --split train --workspace docker \
        --max-iterations 60 --num-workers 1 --n-limit 1
(see scripts/runners/run-swerebench-smoke.sh which wires the SSM Haiku key.)
"""

import json
import os

import benchmarks.swebench.run_infer as swe_ri
import benchmarks.utils.conversation as _conv
from benchmarks.swebench.run_infer import SWEBenchEvaluation
from benchmarks.swebench.config import INFER_DEFAULTS
from benchmarks.utils.args_parser import add_prompt_path_argument, get_parser
from benchmarks.utils.critics import create_critic
from benchmarks.utils.evaluation_utils import (
    construct_eval_output_dir,
    get_default_on_result_writer,
)
from benchmarks.utils.llm_config import load_llm_config
from benchmarks.utils.models import EvalInstance, EvalMetadata  # noqa: F401
from openhands.sdk import get_logger

logger = get_logger(__name__)


# --- V1 event-stream sink (for the loop/no-progress detector) ---------------
# The stock persistence callback only logs events to the python logger. We wrap
# it so every conversation Event is ALSO appended (one model_dump_json per line)
# to $REBENCH_EVENT_DIR/<instance_id>.events.jsonl — the faithful V1 analog of the
# V0 CyberGym per-event files that _swerebench_progress_watch.py tails. Patch the
# name already imported INTO benchmarks.swebench.run_infer (not just the source
# module), since that is the reference evaluate_instance() actually calls.
_orig_persist_builder = _conv.build_event_persistence_callback


def _persist_builder_with_jsonl(run_id, instance_id, attempt=1, show_trajectory=True):
    base = _orig_persist_builder(run_id, instance_id, attempt, show_trajectory)
    event_dir = os.environ.get("REBENCH_EVENT_DIR", "/tmp/rebench_events")
    path = os.path.join(event_dir, f"{instance_id}.events.jsonl")
    try:
        os.makedirs(event_dir, exist_ok=True)
    except OSError:
        pass

    def _cb(event):
        base(event)
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(event.model_dump_json(exclude_none=True) + "\n")
        except Exception:  # best-effort; never block the run
            pass

    return _cb


swe_ri.build_event_persistence_callback = _persist_builder_with_jsonl


# rebench-v2 is a single config; the local-jsonl slice path uses split "train"
# (datasets' json loader names its only split "train").
REBENCH_INFER_DEFAULTS = {
    **INFER_DEFAULTS,
    "dataset": "nebius/SWE-rebench-v2",
    "split": "train",
}


class SWERebenchEvaluation(SWEBenchEvaluation):
    """SWE-bench OpenHands eval, retargeted at SWE-rebench-v2 substrate."""

    def get_official_docker_image(self, instance: EvalInstance) -> str:
        img = str(instance.data["image_name"]).strip().lower()
        if not img.startswith("docker.io/"):
            img = "docker.io/" + img
        return img

    def extract_custom_tag(self, official_docker_image: str) -> str:
        # docker.io/swerebenchv2/dask-dask:5861-f0b8bd4 -> dask-dask
        name_tag = official_docker_image.split("/")[-1]
        return name_tag.split(":")[0]

    def should_wrap_instance(self, instance: EvalInstance) -> bool:
        return False

    def get_source_repo_path(self, instance: EvalInstance) -> str:
        return "/" + str(instance.data["repo"]).split("/")[-1]


def main() -> None:
    parser = get_parser()
    # Reuse SWE-bench's prompt template (its prompts/ dir) verbatim — the rebench
    # cell is a wiring smoke and matching the canonical OpenHands swebench prompt
    # keeps the only swept variable the dataset/substrate, not the prompt.
    add_prompt_path_argument(parser, swe_ri.__file__)
    parser.set_defaults(**REBENCH_INFER_DEFAULTS)
    args = parser.parse_args()

    if args.n_critic_runs < 1:
        raise ValueError(f"n_critic_runs must be >= 1, got {args.n_critic_runs}")

    llm = load_llm_config(args.llm_config_path)
    logger.info("Using LLM config: %s", llm.model_dump_json(indent=2))

    dataset_description = (
        args.dataset.replace("/", "__") + "-" + args.split.replace("/", "__")
    )
    structured_output_dir = construct_eval_output_dir(
        base_dir=args.output_dir,
        dataset_name=dataset_description,
        model_name=llm.model,
        max_iterations=args.max_iterations,
        eval_note=args.note,
    )

    critic = create_critic(args)
    logger.info(f"Using critic: {type(critic).__name__}")
    logger.info(f"Using tool preset: {args.tool_preset}")

    enable_condenser = args.enable_condenser
    if args.disable_condenser:
        enable_condenser = False

    metadata = EvalMetadata(
        llm=llm,
        dataset=args.dataset,
        dataset_split=args.split,
        max_iterations=args.max_iterations,
        eval_output_dir=structured_output_dir,
        details={},
        prompt_path=args.prompt_path,
        eval_limit=args.n_limit,
        env_setup_commands=["export PIP_CACHE_DIR=~/.cache/pip"],
        n_critic_runs=args.n_critic_runs,
        critic=critic,
        selected_instances_file=args.select,
        max_retries=args.max_retries,
        workspace_type=args.workspace,
        tool_preset=args.tool_preset,
        enable_delegation=args.enable_delegation,
        agent_type=args.agent_type,
        enable_condenser=enable_condenser,
        condenser_max_size=args.condenser_max_size,
        condenser_keep_first=args.condenser_keep_first,
    )

    evaluator = SWERebenchEvaluation(metadata=metadata, num_workers=args.num_workers)
    evaluator.run(on_result=get_default_on_result_writer(evaluator.output_path))

    logger.info("Evaluation completed!")
    print(json.dumps({"output_json": str(evaluator.output_path)}))


if __name__ == "__main__":
    main()
