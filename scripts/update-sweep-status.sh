#!/usr/bin/env bash
# update-sweep-status.sh — regenerate the unified, honest benchmark dashboard.
#
# board.json is the SINGLE SOURCE OF TRUTH (dtu / <CAMPAIGN>.1). Pipeline (write mode):
#   S3 -> emit_board_json (condition-grouped provenance, docs/board/schema.json)
#      -> finalize-board.py (<CAMPAIGN>.1 honesty gate + canonical/superseded + footnotes)
#      -> validate-board-json.py (schema gate)
#      -> render-sweep-status.py (board.json -> docs/results/sweep-status.md)
# sweep-status.md, criterion-matrix.html and sweep-explorer.html ALL render from
# board.json — none re-aggregates S3, so the views can never diverge. The old
# higher-of-paired collapse and the overloaded ᵗ marker are RETIRED (bd ceq/opy):
# a cell shows one clean number only when score.headline_eligible, else it renders
# transparently (paired on/off + truncation diagnostic).
#
# Usage:
#   scripts/update-sweep-status.sh            # full pipeline -> docs/board/board.json + sweep-status.md
#   scripts/update-sweep-status.sh --check    # exit 1 if a regen would change sweep-status.md (uses temps)
#   OUTPUT_FILE=- scripts/update-sweep-status.sh   # print markdown to stdout
#   scripts/update-sweep-status.sh --emit-json [out.json]   # ONLY the raw condition-grouped board.json
#   REFRESH_TRUNCATION=1 scripts/update-sweep-status.sh     # also rescan lm-eval samples (slow, <CAMPAIGN>.1.1)
#
# --emit-json: emit the raw condition-grouped board.json and stop (no finalize,
#   no markdown). Preserves EVERY measurement grouped by condition (thinking /
#   harness / max_turns / context). The static half (condition_dims + model &
#   bench registries + canonical protocols + footnote registry) is read from
#   docs/board/board-meta.json (BOARD_META_FILE to override); S3 measurements are
#   joined onto it. Writes to stdout, or to the optional path argument.
#
# Requires: awscli with s3:Get + s3:List on the bucket, jq, bash 4+.
#
# Where to run: the harness EC2 has the IAM role baked in; the sandbox does not
# (proxy blocks s3.amazonaws.com). Run on harness via SSH-over-SSM:
#   ssh ubuntu@<harness-instance> sudo bash /opt/benchmarks/scripts/update-sweep-status.sh
#
# Offline testing: set RESULTS_FIXTURE=<file> to feed a newline-separated stream
# of result.json objects (the same shape S3 holds) instead of querying S3 — used
# by the <ISSUE> parity dry-run and the bd <ISSUE> self-test. The aliasing/cleanup
# jq still runs, so the fixture path exercises the real aggregation pipeline.
#
# Issues: benchmarks-rlp epic / <ISSUE> (--emit-json) / dtu + <CAMPAIGN>.1 (unified
#   honest pipeline) / <CAMPAIGN>.1.2 (retire ᵗ marker, resolves ceq + opy) / <CAMPAIGN>
#   (provenance) / <CAMPAIGN>.1.1 (truncation diagnostics).

set -Eeuo pipefail
IFS=$'\n\t'

S3_BUCKET="${S3_BUCKET:-<RESULTS_BUCKET>}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
DEFAULT_OUTPUT="${REPO_ROOT}/docs/results/sweep-status.md"
OUTPUT_FILE="${OUTPUT_FILE:-${DEFAULT_OUTPUT}}"
BOARD_META_FILE="${BOARD_META_FILE:-${REPO_ROOT}/docs/board/board-meta.json}"

# Data-quality filters — passed into the emit_board_json jq via --arg. board.json
# is now the SINGLE source of truth (sweep-status.md, criterion-matrix.html and
# sweep-explorer.html all render from it), so excluding a junk campaign here
# excludes it from every view at once.
# bd <ISSUE>: the <CAMPAIGN> TP=4 junk SEC-bench campaign that must never render anywhere.
# Extend BOARD_JUNK_CAMPAIGN_RE (an anchored alternation) as new junk campaigns
# are identified — editing it here updates every view.
BOARD_JUNK_CAMPAIGN_RE='^(<ISSUE>-<CAMPAIGN>-secbench11-2026-05-26|<CAMPAIGN>-secbench-tp8-2026-05-27|to4-nemotron120-cvebench-thinkingon-2026-05-30|to4-qwen3-235b-cvebench-2026-05-31|to4-qwen3-235b-cvebench-thinkingon-2026-05-31|to4-qwen3-235b-cvebench-thinkingon-b300-2026-06-01)$'
SMOKE_CAMPAIGN_RE='(smoke|probe|debug|test)'
# Cell-level junk (bd 483): drops a SINGLE (campaign, bench) cell rather than a
# whole campaign — for a campaign that is valid for most benches but produced one
# known-bad cell. Match string is "<campaign>@@<raw S3 bench alias>", anchored
# alternation. Current entry: DeepSeek-V4-Flash-0731 poolb-thinkon BCB-Hard is a
# non-thinking DUPLICATE (thinking never engaged; value byte-identical to the
# thinkoff run); the valid thinking-on BCB is the -bcb483/-bcbfix re-run. Dropping
# only this cell keeps that campaign's valid HumanEval+/IFEval thinking-on cells.
BOARD_JUNK_CELL_RE='^(dsv4flash0731-poolb-thinkon@@bigcodebench-hard)$'

MODE="write"
BOARD_JSON_OUT="-"   # emit-json target; "-" = stdout
if [[ "${1:-}" == "--check" ]]; then MODE="check"; fi
if [[ "${1:-}" == "--emit-json" ]]; then MODE="emit-json"; BOARD_JSON_OUT="${2:--}"; fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '/^# /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# ----------------------------------------------------------------------
# Fetch every canonical result(s).json from S3 as a single jq array.
# Pool B writes one results.json per (model_id, bench). Pool A writes one
# result.json (singular) per (model_id, bench, task) under <bench>/<task>/.
# Exclude:
#   - lm-eval-raw / bcb-raw nested files (Pool B raw outputs)
#   - logs/  (Pool A agent traces — events/, sessions/, etc.)
#   - _deprecated/ (Gemini-era artifacts kept for history)
# ----------------------------------------------------------------------
fetch_all_results() {
  local tmp
  tmp="$(mktemp)"
  if [[ -n "${RESULTS_FIXTURE:-}" ]]; then
    # Offline seam (<ISSUE> self-test / <ISSUE> parity dry-run): read a local
    # newline-separated stream of result.json objects instead of S3. The
    # aliasing + cleanup jq below still runs, so the same pipeline is exercised.
    cat -- "${RESULTS_FIXTURE}" > "${tmp}"
  else
    # Bulk fetch (perf, 2026-06-04): ONE parallelized `aws s3 cp --recursive`
    # instead of a per-file `aws s3 cp` loop. The old loop spawned one aws
    # process per object (~1-2s of cold snap-aws startup each); at ~1300+
    # objects that was an hour-plus crawl. --recursive does all GETs inside a
    # single process (~10 concurrent requests) — ~40s for the same set. Files
    # land under a temp dir mirroring the key layout; we then concatenate the
    # kept ones into the newline-separated stream the jq slurp below wants.
    local dldir
    dldir="$(mktemp -d)"
    # Two includes: "*result.json" does NOT match "results.json" (different
    # suffix), so both patterns are required. Over-broad matches (e.g. a stray
    # foo-result.json) are harmless — the find -name below keeps only exact
    # result.json / results.json basenames.
    aws s3 cp "s3://${S3_BUCKET}/" "${dldir}/" \
      --recursive --no-progress \
      --exclude "*" --include "*result.json" --include "*results.json" \
      >/dev/null 2>&1 || true
    # Same exclusions as the old list-filter: raw Pool B outputs (lm-eval-raw /
    # bcb-raw), Pool A agent logs, and the _deprecated/ (Gemini-era) campaign
    # prefix. `^_deprecated` was anchored on the S3 key; here it maps to a
    # top-level campaign dir, i.e. "${dldir}/_deprecated...".
    find "${dldir}" -type f \( -name 'result.json' -o -name 'results.json' \) \
      | grep -v -E "/lm-eval-raw/|/bcb-raw/|/logs/|^${dldir}/_deprecated" \
      | while IFS= read -r f; do
          cat -- "${f}" 2>/dev/null || true
          printf '\n'
        done > "${tmp}"
    rm -rf "${dldir}"
  fi
  # Model-id aliasing: direct-API runs (opus47-direct, target=opus47-direct in
  # runners) write .model_id = "claude-opus-4-7" while Bedrock runs (target=
  # opus47) write .model_id = "us.anthropic.claude-opus-4-7". The roster keys
  # the Opus row on the Bedrock form, so direct-API result.json files were
  # invisible to the aggregator (Opus SEC-bench <CAMPAIGN>+<CAMPAIGN> post-CVP cell
  # 5/11 + CVE-Bench <CAMPAIGN> cell 16/40 both showed "—" pre-fix). Rewrite to
  # canonical Bedrock form so all Opus runs land in the same row.
  jq -s '
    map(
      if (.model_id // "") == "claude-opus-4-7" then .model_id = "us.anthropic.claude-opus-4-7"
      else . end
    ) | map(select((.model_id // "") != "" and (.bench // "") != ""))
  ' < "${tmp}"
  rm -f "${tmp}"
}

# Aggregate per (model_id, bench, campaign). Pool B records are already
# aggregated (one record per bench), so this is a no-op for them. Pool A
# records are per-task; this sums pass_rate weighted by n_tasks and counts
# how many task records contributed.
aggregate_per_campaign() {
  jq '
    group_by([.model_id, .bench, .campaign]) | map(
      (map(.n_tasks // 0) | add // 0) as $n_total
      | (map((.pass_rate // 0) * (.n_tasks // 0)) | add // 0) as $passes
      | (
          # variant_class derivation (bd <ISSUE>, 2026-05-26): classify each
          # campaign by SEC-bench harness variant so the (s) stock column and
          # (p) patched column render from distinct buckets. "patched" = the
          # uniform <ISSUE>+<ISSUE> set; "exclude" = the superseded bd-227-only
          # runs (old Gemma @30) which belong in NEITHER column; "stock" =
          # everything else (no patches; this is also the default for non-
          # SEC-bench benches, which never carry a harness_variant).
          (.[0].extra.harness_variant) as $hv
          | (if ($hv | type) == "object" then ($hv.variant // "")
             elif ($hv | type) == "string" then $hv
             else "" end) as $v
          | (if ($v | test("<ISSUE>")) then "patched"
             elif ($v | test("<ISSUE>")) then "exclude"
             else "stock" end)
        ) as $variant_class
      | {
          model_id:     .[0].model_id,
          bench:        .[0].bench,
          target:       .[0].target,
          campaign:     .[0].campaign,
          model_args:   (.[0].extra.model_args // null),
          completed_at: (map(.completed_at // "") | max),
          n_tasks:      $n_total,
          n_records:    length,
          pass_rate:    (if $n_total > 0 then ($passes / $n_total) else 0 end),
          variant_class: $variant_class,
          tokens_out:   (map(.tokens_out // 0) | add),
          extra:        .[0].extra
        }
    )
  '
}


# ----------------------------------------------------------------------
# --emit-json (bd <ISSUE>): join aggregated S3 measurements onto the curated
# board-meta registry and emit a schema-conformant board.json. Reads the
# aggregated per-campaign rows (output of aggregate_per_campaign) on stdin;
# $1 is the board-meta path. Unlike the retired higher-of-paired collapse, this
# one canonical cell — it keeps EVERY measurement, tagged by condition.
# ----------------------------------------------------------------------
emit_board_json() {
  local meta="$1"
  local generated_at
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --slurpfile meta "${meta}" \
    --slurpfile data /dev/stdin \
    --arg generated_at "${generated_at}" \
    --arg junk "${BOARD_JUNK_CAMPAIGN_RE}" \
    --arg cell_junk "${BOARD_JUNK_CELL_RE}" \
    --arg smoke_re "${SMOKE_CAMPAIGN_RE}" \
    '
    ($meta[0]) as $m
    | ($data[0] // []) as $rows
    | ($m.harness_variants // []) as $hvrules
    # registries: S3 model_id -> board id slug; bench alias -> {id, default cond, derive, harness_axis}.
    | ($m.models | map({ (.match.model_id): .id }) | add) as $model_map
    | ( reduce $m.benches[] as $b ({};
          reduce ($b.emit.aliases // [])[] as $a (.;
            . + { ($a): { id: $b.id, dc: ($b.emit.default_condition // {}),
                          derive: ($b.emit.derive // {}), harness_axis: ($b.emit.harness_axis // false),
                          n: $b.n } })
        ) ) as $bench_map
    | ($m.models  | to_entries | map({ (.value.id): .key }) | add) as $model_rank
    # Per-model frontier flag, keyed by board model id — used to pick the
    # default thinking value for unmarked campaigns: open-weight unmarked =
    # thinking-off (the harness bandage default), frontier unmarked =
    # thinking-on (the natively-reasoning baseline).
    | ($m.models | map({ (.id): (.frontier == true) }) | add) as $is_frontier
    # Per-model "thinking-only" flag for open-weight models we choose not
    # to run with enable_thinking=false (e.g. Qwen3-235B-Thinking, where
    # the off mode produces floor scores). These default to thinking=on
    # for unmarked campaigns — same treatment as frontier.
    | ($m.models | map({ (.id): (.thinking_only == true) }) | add) as $is_thinking_only
    | ($m.benches | to_entries | map({ (.value.id): .key }) | add) as $bench_order
    | ( $rows
        # Publishability gate (shared junk/exclude filters):
        # drop superseded bd-227-only SEC-bench runs (variant_class=exclude) and
        # the bd <ISSUE> junk campaign ($junk). (We do NOT collapse or drop smoke
        # here: smoke rows are kept and tagged status=smoke for the drilldown.)
        | map(select(.variant_class != "exclude"))
        | map(select((.campaign // "") | test($junk) | not))
        # bd 483: drop specific known-bad single cells (campaign valid elsewhere).
        | map(select((((.campaign // "") + "@@" + (.bench // "")) | test($cell_junk)) | not))
        | map(
            ($model_map[.model_id]) as $mid
            | ($bench_map[.bench]) as $b
            | select($mid != null and $b != null)
            | . as $r | ($b.dc) as $dc | ($r.extra // {}) as $x
            | ( {}
                # thinking: prefer the structured field, fall back to a
                # campaign-name marker because Pool A/B runs do not always
                # stamp enable_thinking into result.json extras (the value
                # lives in the rental spec, which the drivers do not
                # currently propagate). Two campaign-name styles are in
                # use: hyphenated "-thinking-on-" (Pool A canonical), and
                # concatenated "-thinkingon-" / "-thinkon-" (Pool B). The
                # regex tolerates either.
                | (if ($x.enable_thinking == true) then .thinking = "on"
                   elif ($x.enable_thinking == false) then .thinking = "off"
                   elif (($r.campaign // "") | test("-think(ing)?-?on(-|$)"; "i")) then .thinking = "on"
                   elif (($r.campaign // "") | test("-think(ing)?-?off(-|$)"; "i")) then .thinking = "off"
                   elif ($dc.thinking != null) then .thinking = $dc.thinking
                   elif ($is_frontier[$mid] == true) or ($is_thinking_only[$mid] == true) then .thinking = "on"
                   else .thinking = "off" end)
                # harness: pin only for benches that actually have a harness axis
                # (emit.harness_axis) or a run that carries a non-stock variant.
                # The VALUE is data-driven from $m.harness_variants (raw
                # harness_variant string -> clean condition value; first regex
                # match wins; no variant -> "stock"; unmatched -> verbatim so the
                # <ISSUE> gate flags an undeclared value). Adding a new harness is
                # config-only. Non-harness benches omit the dim (defaults to
                # stock per condition_dims) per the schema "pin only relevant
                # dims" rule. exclude-class runs were already dropped above.
                | ( ( ($x.harness_variant) as $hv
                      | (if   ($hv | type) == "object" then ($hv.variant // "")
                         elif ($hv | type) == "string" then $hv
                         else "" end) ) as $hvar
                    | (if $hvar == "" then "stock"
                       else ([ $hvrules[] | select(.match as $mre | ($hvar | test($mre))) ][0].value) // $hvar
                       end) ) as $harness
                | (if ($b.harness_axis == true) or ($harness != "stock")
                     then .harness = $harness else . end)
                | ( ($b.derive.max_turns // null) as $p
                    | (if ($p != null) and (($r | getpath($p)) != null)
                         then .max_turns = (($r | getpath($p)) | tostring)
                       elif ($dc.max_turns != null) then .max_turns = $dc.max_turns else . end) )
                | (if ($dc.context != null) then .context = $dc.context else . end)
              ) as $cond
            # Partial-N detection: any run where measured n_tasks is less
            # than half the canonical bench size also gets tagged as smoke.
            # Catches crashed or incomplete runs (e.g. nemotron 120b
            # thinking-on n=9 against CVE-Bench n=40) so they stay visible
            # in the drilldown but do not drive canonical or max headlines.
            | ( ($x.smoke == true)
                or (($r.campaign // "") | test($smoke_re; "i"))
                or (($b.n // null) != null and ($r.n_tasks // null) != null and ($r.n_tasks < ($b.n * 0.5)))
              ) as $is_smoke
            # <CAMPAIGN> provenance stitched onto every measurement: target, the
            # vllm concurrency, total output tokens, and the bd <ISSUE> BCB
            # null-content rate. truncation_rate / loop_rate / overflow_rate /
            # canonical / superseded / headline_eligible are NOT set here — they
            # are filled by the Python finalize pass (scripts/finalize-board.py,
            # <CAMPAIGN>.1.1 + <CAMPAIGN>.1 gate), which needs the per-sample logs and
            # cross-measurement selection this jq cannot cheaply do.
            | ( ($x.bcb_none_filter.null_rate) as $nullr
                | ($x.vllm_num_concurrent) as $nconc
                | { model_id: $mid, bench_id: $b.id,
                    _m: ( { condition: $cond, value: $r.pass_rate, n: $r.n_tasks,
                            status: (if $is_smoke then "smoke" else "measured" end) }
                          + (if ($r.target // "") != ""       then { target: $r.target } else {} end)
                          + (if ($nconc != null)              then { num_concurrent: $nconc } else {} end)
                          + (if (($r.tokens_out // 0) > 0)    then { tokens_out: $r.tokens_out } else {} end)
                          + (if ($nullr != null)              then { null_rate: $nullr } else {} end)
                          + (if ($r.campaign // "") != ""     then { campaign: $r.campaign } else {} end)
                          + (if ($r.completed_at // "") != "" then { completed_at: $r.completed_at } else {} end) ) } )
          )
      ) as $built
    | ( $built
        | group_by([.model_id, .bench_id])
        | map({ model_id: .[0].model_id, bench_id: .[0].bench_id,
                measurements: ( map(._m) | sort_by([ (.condition.thinking // ""), (.condition.harness // ""),
                                                     (.condition.max_turns // ""), (.campaign // "") ]) ) })
        | sort_by([ ($model_rank[.model_id]), ($bench_order[.bench_id]) ])
      ) as $scores
    | { schema_version: $m.schema_version,
        generated_at:   $generated_at,
        rev:            $m.rev,
        condition_dims: $m.condition_dims,
        models:  ($m.models  | map(del(.match))),
        benches: ($m.benches | map(del(.emit))),
        scores:  $scores }
    '
}

emit_board_main() {
  if [[ ! -f "${BOARD_META_FILE}" ]]; then
    printf 'board-meta not found: %s\n' "${BOARD_META_FILE}" >&2
    exit 1
  fi
  local board
  board="$(fetch_all_results | aggregate_per_campaign | emit_board_json "${BOARD_META_FILE}")"
  if [[ "${BOARD_JSON_OUT}" == "-" ]]; then
    printf '%s\n' "${board}"
  else
    mkdir -p "$(dirname "${BOARD_JSON_OUT}")"
    printf '%s\n' "${board}" > "${BOARD_JSON_OUT}"
    printf 'Wrote %s (%s score cells)\n' "${BOARD_JSON_OUT}" "$(printf '%s' "${board}" | jq '.scores | length')" >&2
  fi
}


# ----------------------------------------------------------------------
# Main — orchestrate the unified, honest dashboard pipeline (dtu / <CAMPAIGN>.1).
#   1. emit raw board.json   (S3 -> condition-grouped provenance)
#   2. [optional] compute-truncation.py  (slow lm-eval per-sample scan -> cache)
#   3. finalize-board.py     (<CAMPAIGN>.1 gate + canonical/superseded + footnotes)
#   4. validate-board-json.py (schema gate)
#   5. render-sweep-status.py (board.json -> sweep-status.md)
# board.json is the SINGLE source of truth; sweep-status.md, criterion-matrix.html
# and sweep-explorer.html all render FROM it. The old higher-of-paired collapse and
# the overloaded ᵗ marker are RETIRED (bd <ISSUE> / <CAMPAIGN>.1.2 / ceq / opy).
#
# Env knobs:
#   REFRESH_TRUNCATION=1  also (re)scan lm-eval samples for truncation_rate (slow).
#   PYTHON='uv run python3'  interpreter (default).
# ----------------------------------------------------------------------
# Build the interpreter as an array: the script sets IFS=$'\n\t' (no space), so a
# bare ${PYTHON} would not word-split "uv run python3" into argv. `IFS=' ' read`
# scopes the space-split to this one builtin.
IFS=' ' read -r -a PY <<< "${PYTHON:-uv run python3}"
BOARD_JSON="${BOARD_JSON:-${REPO_ROOT}/docs/board/board.json}"
SCHEMA_FILE="${SCHEMA_FILE:-${REPO_ROOT}/docs/board/schema.json}"
TRUNCATION_CACHE="${TRUNCATION_CACHE:-${REPO_ROOT}/data/truncation-cache.json}"
REFRESH_TRUNCATION="${REFRESH_TRUNCATION:-0}"

# ExploitBench cells cannot be computed by the per-record emit_board_json jq:
# the paper-native headline is avg-flags/16 (not pass_rate), the tier ladder is
# derived from the 16-flag bitmap, and a wall-capped model's flags must be
# SALVAGED from the sibling eb_artifacts/grade_calls.jsonl (a cross-file union
# jq cannot do cheaply). So we DELEGATE EB cell computation to the canonical
# aggregator (extract-pool-a-exploitbench.py --emit-board-json), the one
# truth-computer, and merge its rows into board.json — replacing any naive
# exploitbench-41 rows emit_board_json may have produced. bd <ISSUE>.10.3.
#
# EB_RESULTS_FIXTURE (offline seam): point at a local results-root tree
# (<campaign>/<target>/exploitbench-*/<task>/result.json + eb_artifacts/) to
# skip the S3 mirror, mirroring RESULTS_FIXTURE for the main pipeline.
merge_exploitbench() {
  local board_out="$1"
  local agg="${SCRIPT_DIR}/aggregators/extract-pool-a-exploitbench.py"
  local root rows merged
  local cleanup_root=""

  if [[ -n "${EB_RESULTS_FIXTURE:-}" ]]; then
    root="${EB_RESULTS_FIXTURE}"
  else
    root="$(mktemp -d)"; cleanup_root="${root}"
    # Mirror ONLY the exploitbench-41 campaigns (result.json + grade_calls.jsonl
    # for salvage). Discover them by S3 prefix so new EB-41 campaigns are picked
    # up without editing this script.
    local camp
    while IFS= read -r camp; do
      [[ -z "${camp}" ]] && continue
      aws s3 cp "s3://${S3_BUCKET}/${camp}" "${root}/${camp}" \
        --recursive --no-progress \
        --exclude "*" --include "*/result.json" --include "*/grade_calls.jsonl" \
        >/dev/null 2>&1 || true
    done < <(aws s3 ls "s3://${S3_BUCKET}/" 2>/dev/null \
               | awk '{print $2}' | sed 's#/$##' \
               | grep -E 'exploitbench-?41' | grep -E 'nudge')
  fi

  # Capture stderr so the aggregator's own diagnostics surface if it fails
  # (2>/dev/null would hide a real error behind the exit-0 merge path).
  local errfile; errfile="$(mktemp)"
  if ! rows="$("${PY[@]}" "${agg}" --results-root "${root}" \
                 --emit-board-json --board-meta "${BOARD_META_FILE}" \
                 --bench-id exploitbench-41 2>"${errfile}")"; then
    echo "WARN: ExploitBench aggregator emit failed; leaving board EB cells as-is" >&2
    sed 's/^/  [eb-agg] /' "${errfile}" >&2 || true
    rm -f "${errfile}"
    [[ -n "${cleanup_root}" ]] && rm -rf "${cleanup_root}"
    return 0
  fi
  rm -f "${errfile}"
  [[ -n "${cleanup_root}" ]] && rm -rf "${cleanup_root}"

  # Guard against silently wiping the EB column: if the aggregator matched no
  # models (rows == [] — e.g. board-meta match strings drifted) or produced
  # non-array output, do NOT replace; keep whatever EB cells already exist and
  # WARN loudly. A replace here would drop the cells with no error.
  local n_rows
  n_rows="$(printf '%s' "${rows}" | jq 'if type=="array" then length else -1 end' 2>/dev/null || echo -1)"
  if [[ "${n_rows}" -le 0 ]]; then
    echo "WARN: ExploitBench aggregator emitted ${n_rows} row(s) (0 models matched or bad output);" \
         "NOT replacing board EB cells — check board-meta models[].match.model_id" >&2
    return 0
  fi

  # Replace: drop existing exploitbench-41 scores, append the aggregator's.
  merged="$(jq --slurpfile eb <(printf '%s' "${rows}") '
    .scores = ((.scores | map(select(.bench_id != "exploitbench-41"))) + $eb[0])
  ' "${board_out}")" || {
    echo "WARN: EB merge jq failed; board EB cells unchanged" >&2
    return 0
  }
  printf '%s\n' "${merged}" > "${board_out}"
}

build_board() {
  # raw board.json (provenance) -> merge EB (delegated) -> finalize (gate) -> validate. Writes $1.
  local board_out="$1"
  fetch_all_results | aggregate_per_campaign | emit_board_json "${BOARD_META_FILE}" > "${board_out}"
  merge_exploitbench "${board_out}"
  if [[ "${REFRESH_TRUNCATION}" == "1" ]]; then
    "${PY[@]}" "${SCRIPT_DIR}/aggregators/compute-truncation.py" \
      --board "${board_out}" --cache "${TRUNCATION_CACHE}" >&2
  fi
  "${PY[@]}" "${SCRIPT_DIR}/finalize-board.py" \
    --in "${board_out}" --out "${board_out}" \
    --meta "${BOARD_META_FILE}" --truncation-cache "${TRUNCATION_CACHE}" >&2
  "${PY[@]}" "${SCRIPT_DIR}/validate-board-json.py" "${board_out}" --schema "${SCHEMA_FILE}" >&2
}

main() {
  if [[ "${MODE}" == "emit-json" ]]; then
    emit_board_main
    return
  fi

  if [[ "${MODE}" == "check" ]]; then
    # Regenerate to temps so a --check never clobbers the committed board.json,
    # then diff the rendered markdown against OUTPUT_FILE.
    local tmp_board tmp_md
    tmp_board="$(mktemp)"; tmp_md="$(mktemp)"
    build_board "${tmp_board}"
    "${PY[@]}" "${SCRIPT_DIR}/render-sweep-status.py" --board "${tmp_board}" --out - > "${tmp_md}"
    if [[ -f "${OUTPUT_FILE}" ]] && diff -q "${tmp_md}" "${OUTPUT_FILE}" >/dev/null 2>&1; then
      echo "sweep-status.md is up to date"
      rm -f "${tmp_board}" "${tmp_md}"; exit 0
    fi
    echo "sweep-status.md would change; re-run scripts/update-sweep-status.sh" >&2
    rm -f "${tmp_board}" "${tmp_md}"; exit 1
  fi

  # write mode: board.json is the durable source of truth; every view renders from it.
  build_board "${BOARD_JSON}"
  "${PY[@]}" "${SCRIPT_DIR}/render-sweep-status.py" --board "${BOARD_JSON}" --out "${OUTPUT_FILE}"
  # criterion-matrix.html + sweep-explorer.html (dark-mode WCAG, lenses, per-cell
  # diagnostics) — skipped only when streaming markdown to stdout.
  if [[ "${OUTPUT_FILE}" != "-" ]]; then
    "${PY[@]}" "${SCRIPT_DIR}/render-html-views.py" \
      --board "${BOARD_JSON}" --out-dir "$(dirname "${OUTPUT_FILE}")"
  fi
}

main "$@"
