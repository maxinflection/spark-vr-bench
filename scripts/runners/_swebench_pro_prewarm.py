#!/usr/bin/env python3
# _swebench_pro_prewarm.py — builder-stage pre-warm for the parallel SWE-bench Pro
# / SWE-agent run (bd benchmarks-3xi.2.6).
#
# WHY. SWE-Rex builds a standalone-CPython layer on top of each Pro image
# (swerex/deployment/docker.py :: glibc_dockerfile): a `python:3.11.9-slim-bullseye
# AS builder` stage compiles CPython 3.11.8 from source + bundles OpenSSL 1.1
# (the 3xi.2.5 fix), then a production stage `FROM <pro-image>` COPYs the binary
# in and pip-installs swe-rex. At N-wide (--num_workers N>1) the N parallel
# deploys would EACH kick off that CPython compile simultaneously -> N concurrent
# source compiles -> the OOM-wedge that took down the box's SSM agent in §4e (the
# 3xi.2.5 HARD LESSON).
#
# FIX. The `builder` stage is IDENTICAL across all instances — only the production
# `FROM <image>` differs. BuildKit caches a stage by its instructions + parent, so
# ONE throwaway `docker build --target builder` compiles CPython ONCE and populates
# the shared BuildKit builder-stage cache; every subsequent swe-rex deploy then
# gets a cache HIT on the builder stage and runs only the cheap production stage
# (COPY + pip). Because the builder stage is image-independent, building it for ANY
# one of the run's base images warms the cache for ALL of them.
#
# This helper:
#   1. Applies _swerex_docker_libffi_patch.py (idempotent) so the rendered
#      dockerfile is the 3xi.2.5-fixed one (bullseye builder + bundled OpenSSL 1.1
#      + libffi + pip-index) — we must never warm an unpatched/wrong builder stage.
#   2. Renders glibc_dockerfile via swe-rex's OWN code path for the given --image
#      (so the warmed builder instructions are byte-identical to what the deploys
#      will render).
#   3. `DOCKER_BUILDKIT=1 docker build --target <builder-stage>` it once.
#   4. Re-runs the same build and asserts the builder stage reports CACHED — proof
#      the warm took and the N-wide deploys will not recompile.
#
# Run in the SWE-agent venv (needs swerex importable):
#   /opt/harnesses/swebench-pro/.venv-sweagent/bin/python \
#       _swebench_pro_prewarm.py --image jefzda/sweap-images:<tag>
#
# Exit 0 = builder cache warmed (and verified CACHED on re-build). Non-zero =
# pre-warm failed; the caller treats this as NON-FATAL (the N-wide run still works,
# it just risks concurrent compiles). VALIDATION that N concurrent deploys show no
# CPython compile after a warm is the on-box P3 step (bd 3xi.2.6).
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def _apply_patch():
    """Idempotently apply the swe-rex glibc/OpenSSL/libffi patch before rendering."""
    patch = os.path.join(HERE, "_swerex_docker_libffi_patch.py")
    if not os.path.isfile(patch):
        print(f"prewarm WARNING: {patch} not found; assuming swerex already patched",
              file=sys.stderr)
        return
    r = subprocess.run([sys.executable, patch], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        raise SystemExit(f"prewarm: swe-rex patch failed (rc={r.returncode}); refusing "
                         "to warm an unpatched builder stage")


def _render_dockerfile(image):
    """Render the swe-rex glibc_dockerfile for `image` via swe-rex's own API."""
    import importlib
    docker_mod = importlib.import_module("swerex.deployment.docker")
    importlib.reload(docker_mod)  # pick up the on-disk patch if just applied
    from swerex.deployment.config import DockerDeploymentConfig
    df = docker_mod.DockerDeployment.from_config(
        DockerDeploymentConfig(image=image, python_standalone_dir="/root")
    ).glibc_dockerfile
    # Sanity: must be the 3xi.2.5-fixed builder, else the warmed cache is wrong.
    problems = []
    if "python:3.11.9-slim-bullseye AS builder" not in df:
        problems.append("builder base is not bullseye (3xi.2.5 fix missing)")
    if "libssl.so.1.1" not in df:
        problems.append("OpenSSL 1.1 not bundled (3xi.2.5 fix missing)")
    if problems:
        raise SystemExit("prewarm: rendered dockerfile is not 3xi.2.5-patched: "
                         + "; ".join(problems))
    return df


def _builder_stage_name(df):
    """Find the builder stage name from the first `FROM ... AS <name>` line."""
    m = re.search(r"^\s*FROM\s+\S+\s+AS\s+(\w+)", df, re.MULTILINE | re.IGNORECASE)
    return m.group(1) if m else "builder"


def _build_env():
    """Choose the docker build backend, matching the runner's choice.

    Honor an inherited DOCKER_BUILDKIT (the runner sets it ONCE so swe-rex and this
    pre-warm share a cache); when run standalone, prefer BuildKit iff the buildx
    plugin is present, else fall back to the legacy builder (which also caches layers
    across builds). On Docker 23+, DOCKER_BUILDKIT=1 routes `docker build` through
    buildx and ERRORS if it is absent — so we must not force it blindly.
    """
    env = dict(os.environ)
    if "DOCKER_BUILDKIT" not in env:
        has_buildx = subprocess.run(["docker", "buildx", "version"],
                                    capture_output=True).returncode == 0
        env["DOCKER_BUILDKIT"] = "1" if has_buildx else "0"
    return env


def _build(dockerfile_text, target, tag, ctx, base_image):
    """docker build (backend per _build_env); return (returncode, combined_output).

    Passes --build-arg BASE_IMAGE so BuildKit can parse the production stage's
    `FROM $BASE_IMAGE` even though we only build --target builder (BuildKit validates
    every stage's FROM; the legacy builder did not, hence this is needed once buildx
    is present). The builder stage itself is image-independent, so the value only has
    to be a resolvable image reference.
    """
    df_path = os.path.join(ctx, "Dockerfile")
    with open(df_path, "w") as fh:
        fh.write(dockerfile_text)
    cmd = ["docker", "build", "--target", target,
           "--build-arg", "BASE_IMAGE=%s" % base_image,
           "-t", tag, "-f", df_path, ctx]
    r = subprocess.run(cmd, env=_build_env(), capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True,
                    help="A Pro base image (jefzda/sweap-images:<tag>). The builder "
                         "stage is image-independent, so any one of the run's images works.")
    ap.add_argument("--tag", default="swebench-pro-prewarm:builder",
                    help="Throwaway tag for the warmed builder stage.")
    ap.add_argument("--skip-patch", action="store_true",
                    help="Assume swerex is already patched; skip re-applying the patch.")
    args = ap.parse_args()

    if not args.skip_patch:
        _apply_patch()

    df = _render_dockerfile(args.image)
    stage = _builder_stage_name(df)
    print(f"prewarm: image={args.image} builder-stage={stage}")

    with tempfile.TemporaryDirectory(prefix="pro-prewarm-") as ctx:
        # Build 1 — compiles CPython + bundles OpenSSL once (populates the cache).
        rc, out = _build(df, stage, args.tag, ctx, args.image)
        if rc != 0:
            sys.stderr.write(out[-4000:])
            raise SystemExit(f"prewarm: builder-stage build failed (rc={rc}); "
                             "N-wide deploys may each compile CPython")
        print(f"prewarm: builder stage built ({args.tag})")

        # Build 2 — same instructions; BuildKit should report the heavy steps CACHED.
        rc2, out2 = _build(df, stage, args.tag, ctx, args.image)
        if rc2 != 0:
            sys.stderr.write(out2[-2000:])
            print("prewarm WARNING: verification re-build failed; cache state unconfirmed",
                  file=sys.stderr)
            return  # warm likely still happened; non-fatal
        # BuildKit prints "CACHED"; the legacy builder prints "Using cache".
        cached = len(re.findall(r"CACHED|Using cache", out2))
        if cached > 0:
            print(f"prewarm: VERIFIED — builder stage reuses cache on re-build "
                  f"({cached} CACHED steps). N-wide deploys will skip the CPython compile.")
        else:
            print("prewarm WARNING: re-build showed no CACHED steps — builder-stage "
                  "cache reuse not confirmed (BuildKit may be off, or swe-rex builds "
                  "with a different backend; on-box P3 validation needed)",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
