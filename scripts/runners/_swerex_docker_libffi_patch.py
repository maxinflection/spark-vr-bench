#!/usr/bin/env python3
# _swerex_docker_libffi_patch.py — make SWE-Rex's local-docker standalone-python
# build work on SWE-bench Pro images (bd benchmarks-3xi.2.1 Phase 0/1; glibc/ssl
# fix bd benchmarks-3xi.2.5).
#
# SWE-Rex's DockerDeployment builds a standalone CPython from source in a builder
# stage then pip-installs swe-rex in a production stage `FROM <pro-image>`
# (swerex/deployment/docker.py :: glibc_dockerfile). Four image-specific quirks
# break this on the Pro images; all are patched here, idempotently:
#   1. ffi.h — the builder apt-get list omits libffi-dev, so CPython's _ctypes
#      build fails. We clone the libssl-dev line as libffi-dev.
#   2. pip index — the Pro images pin pip to a local hermetic mirror
#      (/root/.config/pip/pip.conf -> http://127.0.0.1:9876/, Scale's offline
#      build proxy, absent at our runtime), so the production-stage
#      `pip3 install swe-rex` cannot resolve. We force --index-url pypi.
#   3. glibc — the builder is `python:3.11.9-slim-bookworm` (glibc 2.36); the
#      compiled python3 binary is COPYed into the instance base image. The Pro
#      base images are a MIXED population: ~24% are glibc-2.31 (ansible Ubuntu
#      20.04 / openlibrary Debian 11 bullseye) and the binary won't run there
#      (`/root/python3.11/bin/python3: version 'GLIBC_2.34' not found`) → the
#      `RUN python3 --version` build step exits 1 → deploy fails, no prediction.
#      Fix: build against the OLDEST target glibc — `python:3.11.9-slim-bullseye`
#      (glibc 2.31). glibc is backward- not forward-compatible, so a 2.31 binary
#      runs on both the old (2.31) and new (2.36/bookworm) bases.
#   4. OpenSSL soname — bullseye ships OpenSSL 1.1.1, so the bullseye-built
#      python's `_ssl.so` links `libssl.so.1.1`/`libcrypto.so.1.1`. The bookworm
#      Pro bases only carry OpenSSL 3 (`libssl.so.3`), so on them `import ssl`
#      fails → the production-stage `pip3 install swe-rex` errors with
#      "ssl module is not available" → build fails. (Fix 3 alone would just
#      TRADE the glibc failures on old bases for ssl failures on new bases.)
#      Fix: bundle the builder's libssl.so.1.1 + libcrypto.so.1.1 into the
#      standalone lib dir (/root/python3.11/lib, already on LD_LIBRARY_PATH), so
#      ssl is base-image-independent; those 1.1 libs only need glibc 2.31, which
#      every base satisfies. Fixes 3+4 together build AND run (python3 --version
#      + swerex-remote --version + import ssl) on BOTH strata — validated on the
#      eval box against old-glibc + bookworm ansible/openlibrary images.
#
# The fifth required fix (Pro images' ENTRYPOINT=[/bin/bash], which turns
# swe-rex's `/bin/sh -c <cmd>` into `bash /bin/sh -c ...`) is handled at RUN time
# via `--instances.deployment.docker_args='["--entrypoint",""]'`, not here.
# The Pro fork itself runs on Modal, which sidesteps all of these; this patch lets
# the leaderboard-faithful SWE-agent scaffold run on local docker instead.
#
# Usage (in the SWE-agent venv):  python _swerex_docker_libffi_patch.py
import importlib.util

PYPI = "https://pypi.org/simple"
spec = importlib.util.find_spec("swerex.deployment.docker")
if spec is None or not spec.origin:
    raise SystemExit("swerex.deployment.docker not found in this environment")
path = spec.origin
src = open(path).read()
changed = []

# Fix 1: libffi-dev
if "libffi-dev" not in src:
    lines, out, done = src.split("\n"), [], False
    for ln in lines:
        out.append(ln)
        if "libssl-dev" in ln and not done:
            out.append(ln.replace("libssl", "libffi"))
            done = True
    if not done:
        raise SystemExit("could not find libssl-dev anchor; swerex layout changed")
    src = "\n".join(out)
    changed.append("libffi-dev")

# Fix 2: force a reachable pip index on the production-stage swe-rex install
if "pip3 install --no-cache-dir --index-url" not in src:
    needle = "pip3 install --no-cache-dir "
    if needle not in src:
        raise SystemExit("could not find the pip3 install line; swerex layout changed")
    src = src.replace(needle, f"pip3 install --no-cache-dir --index-url {PYPI} ", 1)
    changed.append("pip-index-url")

# Fix 3: build the standalone python against the OLDEST target glibc (bullseye)
if "slim-bullseye AS builder" not in src:
    needle = "python:3.11.9-slim-bookworm AS builder"
    if needle not in src:
        raise SystemExit("could not find the bookworm builder base; swerex layout changed")
    src = src.replace(needle, "python:3.11.9-slim-bullseye AS builder", 1)
    changed.append("glibc-bullseye-builder")

# Fix 4: bundle the builder's OpenSSL 1.1 libs into the standalone lib dir so
# `import ssl` works on bookworm bases too. Inserted as a builder RUN right after
# the `ldconfig` install step (the last builder instruction before the
# production `FROM $BASE_IMAGE`), so the libs land in /root/python3.11/lib before
# the COPY --from=builder pulls that tree into the production image.
if "libssl.so.1.1" not in src:
    # The source text contains the literal `    ldconfig\n\n"` (the \n here are
    # the two backslash-n characters of the f-string literal, not real newlines),
    # followed by a real newline. Match that and append a new builder RUN literal.
    anchor = '    ldconfig\\n\\n"\n'
    if anchor not in src:
        raise SystemExit("could not find the ldconfig builder step; swerex layout changed")
    cp_line = (
        '            "RUN cp -a /usr/lib/x86_64-linux-gnu/libssl.so.1.1 '
        '/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 /root/python3.11/lib/\\n\\n"\n'
    )
    src = src.replace(anchor, anchor + cp_line, 1)
    changed.append("openssl-bundle")

if not changed:
    print(f"already patched: {path}")
else:
    open(path, "w").write(src)
    print(f"patched ({', '.join(changed)}): {path}")

# Self-verify: re-render the dockerfile from the (now-patched) source and assert
# the glibc + ssl fixes are present and the bookworm builder is gone. Importing
# fresh picks up the on-disk edit (this process had not imported swerex yet).
import importlib

docker_mod = importlib.import_module("swerex.deployment.docker")
importlib.reload(docker_mod)
from swerex.deployment.config import DockerDeploymentConfig  # noqa: E402

df = docker_mod.DockerDeployment.from_config(
    DockerDeploymentConfig(image="VERIFY", python_standalone_dir="/root")
).glibc_dockerfile
problems = []
if "python:3.11.9-slim-bullseye AS builder" not in df:
    problems.append("builder base is not bullseye")
if "python:3.11.9-slim-bookworm" in df:
    problems.append("bookworm builder still present")
if "libssl.so.1.1" not in df or "libcrypto.so.1.1" not in df:
    problems.append("OpenSSL 1.1 libs not bundled")
if "libffi-dev" not in df:
    problems.append("libffi-dev missing")
if f"--index-url {PYPI}" not in df:
    problems.append("pip index-url not forced")
if problems:
    raise SystemExit("SELF-VERIFY FAILED: " + "; ".join(problems))
print("self-verify OK: bullseye builder + bundled OpenSSL 1.1 + libffi + pip-index all present")
