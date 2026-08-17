#!/usr/bin/env bash
# validate-board.sh — board.json schema gate (bd <ISSUE>).
#
# One entrypoint for both the pre-commit hook (.pre-commit-config.yaml) and the
# GitHub Actions workflow (.github/workflows/board-schema.yml). Fails (exit 1)
# if the board data contract is violated, so accidental schema drift — someone
# editing scripts/update-sweep-status.sh --emit-json, docs/board/board-meta.json,
# or docs/board/schema.json — is caught before it can reach the public board.
#
# Checks:
#   1. docs/board/board.sample.json validates against docs/board/schema.json
#      (the committed reference artifact <ISSUE>'s page is wired against).
#   2. The --emit-json aggregator, run against the committed fixture via the
#      RESULTS_FIXTURE seam, emits a schema-valid board.json AND its
#      condition-tagging/filtering invariants hold (tests/board/test-emit-json.sh).
#      This is the actual drift catch for edits to update-sweep-status.sh.
#
# Deps: bash 4+, jq, python3 (stdlib only — no pip). No network, no S3.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
cd "${REPO_ROOT}"

VALIDATOR="scripts/validate-board-json.py"
SCHEMA="docs/board/schema.json"
SAMPLE="docs/board/board.sample.json"
SELFTEST="tests/board/test-emit-json.sh"

rc=0

echo "[1/2] validating ${SAMPLE} against schema..."
if ! python3 "${VALIDATOR}" "${SAMPLE}" --schema "${SCHEMA}"; then rc=1; fi

echo "[2/2] running --emit-json drift self-test..."
if ! bash "${SELFTEST}"; then rc=1; fi

if [[ "${rc}" -eq 0 ]]; then
  echo "board-schema gate: PASS"
else
  echo "board-schema gate: FAIL — board.json contract violated (see above)" >&2
fi
exit "${rc}"
