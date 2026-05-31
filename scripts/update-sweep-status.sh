#!/usr/bin/env bash
# update-sweep-status.sh — Regenerate docs/results/sweep-status.md from S3.
#
# Walks s3://<RESULTS_BUCKET>/, aggregates per-(model_id, bench)
# canonical results.json files into a human-readable sweep dashboard.
#
# Usage:
#   scripts/update-sweep-status.sh            # write to docs/results/sweep-status.md
#   scripts/update-sweep-status.sh --check    # exit 1 if regen would change the file
#   OUTPUT_FILE=- scripts/update-sweep-status.sh   # print to stdout
#   scripts/update-sweep-status.sh --emit-json [out.json]   # emit board.json (bd <ISSUE>)
#
# --emit-json: emit the condition-grouped board.json (docs/board/schema.json)
#   instead of the markdown dashboard. Unlike the markdown path it does NOT
#   collapse to one canonical cell per (model, bench): it preserves EVERY
#   measurement, grouped by condition (thinking / harness / max_turns / context),
#   so the published page can derive canonical / uplift / max views client-side.
#   The static half (condition_dims + model & bench registries + canonical
#   protocols) is read from docs/board/board-meta.json (BOARD_META_FILE to
#   override); S3 measurements are joined onto it. Writes to stdout, or to the
#   optional path argument. The markdown output is unaffected (additive flag).
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
# Issue: benchmarks-rlp epic / bd <ISSUE> (--emit-json branch)

set -Eeuo pipefail
IFS=$'\n\t'

S3_BUCKET="${S3_BUCKET:-<RESULTS_BUCKET>}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
DEFAULT_OUTPUT="${REPO_ROOT}/docs/results/sweep-status.md"
OUTPUT_FILE="${OUTPUT_FILE:-${DEFAULT_OUTPUT}}"
BOARD_META_FILE="${BOARD_META_FILE:-${REPO_ROOT}/docs/board/board-meta.json}"

# Shared data-quality filters — passed into jq via --arg by BOTH the markdown
# (latest_per_pair) and the --emit-json paths, so the public board.json can
# never diverge from the markdown dashboard on which campaigns are excluded.
# bd <ISSUE>: the <CAMPAIGN> TP=4 junk SEC-bench campaign that must never render
# anywhere (see latest_per_pair). Extend BOARD_JUNK_CAMPAIGN_RE (an anchored
# alternation) as new junk campaigns are identified — editing it here updates
# both views at once.
BOARD_JUNK_CAMPAIGN_RE='^<ISSUE>-<CAMPAIGN>-secbench11-2026-05-26$'
SMOKE_CAMPAIGN_RE='(smoke|probe|debug|test)'

MODE="write"
BOARD_JSON_OUT="-"   # emit-json target; "-" = stdout
if [[ "${1:-}" == "--check" ]]; then MODE="check"; fi
if [[ "${1:-}" == "--emit-json" ]]; then MODE="emit-json"; BOARD_JSON_OUT="${2:--}"; fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '/^# /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# ----------------------------------------------------------------------
# Roster — the canonical list of models in scope for the rlp sweep.
# Edit these in the script (not the rendered doc).
# Fields: model_id<TAB>display_name<TAB>quant<TAB>hardware<TAB>bd<TAB>plan_status
# ----------------------------------------------------------------------
read -r -d '' SWEEP_ROSTER <<'EOF' || true
Qwen/Qwen3.6-27B-FP8	Qwen3.6 27B Dense	FP8	RTXPro6000 ×1	<CAMPAIGN>	Pool B done
Qwen/Qwen3.6-35B-A3B-FP8	Qwen3.6 35B-A3B (MoE)	FP8	RTXPro6000 ×1	<CAMPAIGN>	Pool B done
nvidia/Gemma-4-31B-IT-NVFP4	Gemma 4 31B Dense	NVFP4	RTXPro6000 ×1	<CAMPAIGN>	Pool B done
nvidia/Gemma-4-26B-A4B-NVFP4	Gemma 4 26B-A4B (MoE)	NVFP4	RTXPro6000 ×1	<CAMPAIGN>	Pool B done
nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4	Nemotron 3 Super 120B-A12B (MoE)	NVFP4	RTXPro6000 ×2	<CAMPAIGN>	Pool B done
Sehyo/Qwen3.5-122B-A10B-NVFP4	Qwen3.5 122B-A10B (MoE)	NVFP4	RTXPro6000 ×2	<CAMPAIGN>	Pool B done
QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ	Qwen3 235B-A22B Thinking	AWQ-INT4	RTXPro6000 ×4 / H100 ×4	<CAMPAIGN>	Pool B done
deepseek-ai/DeepSeek-V4-Flash	DeepSeek V4 Flash	TBD	TBD	<CAMPAIGN>	Planned
EOF

read -r -d '' FRONTIER_ROSTER <<'EOF' || true
us.anthropic.claude-opus-4-7	Opus 4.7	Bedrock cross-region	<CAMPAIGN> + <CAMPAIGN>	Pool B done
gpt-5.5	GPT-5.5	OpenAI API (direct)	<CAMPAIGN> + <CAMPAIGN>	Pool B done
EOF
# Note: Gemini was dropped from the frontier rotation 2026-05-11 (<CAMPAIGN>
# quota was crippling, scope memo says only one frontier baseline is
# load-bearing). Old Gemini results live at s3://...//_deprecated/.

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
    aws s3api list-objects-v2 \
      --bucket "${S3_BUCKET}" \
      --query "Contents[?ends_with(Key, \`result.json\`) || ends_with(Key, \`results.json\`)].Key" \
      --output text 2>/dev/null \
      | tr '\t' '\n' \
      | grep -v -E '^[[:space:]]*$|/lm-eval-raw/|/bcb-raw/|/logs/|^_deprecated' \
      | while IFS= read -r key; do
          aws s3 cp "s3://${S3_BUCKET}/${key}" - 2>/dev/null || true
          printf '\n'
        done > "${tmp}"
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
          extra:        .[0].extra
        }
    )
  '
}

# For each (model_id, bench) pair, pick the BEST campaign:
#   1. Exclude campaigns whose name contains smoke/probe/debug/test (dev runs
#      that the runner does not yet mark via extra.smoke for Pool A).
#   2. Exclude campaigns flagged extra.smoke=true (Pool B smoke runs).
#   3. Of the survivors, prefer the campaign with the MOST tasks (handles
#      partial Pool A runs vs. full ones), ties broken by latest completed_at.
# If no non-smoke campaigns exist, fall back to whatever IS there.
latest_per_pair() {
  # Sort key: [n_tasks, pass_rate, completed_at]. pass_rate-before-completed_at
  # implements the bd <CAMPAIGN> 'publish the higher as canonical' policy when a
  # model x bench pair has been measured in both thinking-on AND thinking-off
  # modes (both have the same n_tasks). Without this, the aggregator would
  # always pick the LATER campaign even if it's lower — which is wrong for
  # cells where reasoning-mode regresses the metric (e.g. Nemotron BCB-Hard
  # 0.318 thinking-off vs 0.284 thinking-on, observed 2026-05-22 in
  # <CAMPAIGN>-nemotron-poolb-thinkingon-2026-05-21).
  # bd <ISSUE> (2026-05-26): group on variant_class too, so stock and patched
  # SEC-bench runs for the same (model, bench) coexist as separate winners —
  # the (s) column reads variant_class="stock", the (p) column reads
  # variant_class="patched" (the uniform <ISSUE>+<ISSUE>@50 set). "exclude"-class
  # records (superseded bd-227-only runs) are dropped here so they render in
  # neither column. This replaces the earlier `^<ISSUE>-rlp[457]-` campaign-name
  # exclusion hack (the patched results now have a home: the (p) column).
  # bd <ISSUE> PERMANENT guard (2026-05-27): the <CAMPAIGN> Qwen3-235B-Thinking patched
  # SEC-bench run (campaign <ISSUE>-<CAMPAIGN>-secbench11-2026-05-26) is JUNK and must
  # never render. It was TP=4 timeout-confounded (4 of 6 real failures pegged at
  # the 3600s per-task wall cap, not capability), then the rental was torn down
  # mid-run — so tasks 7-11 failed instantly against a dead vLLM endpoint. The
  # campaign emitted "complete" with a polluted 2/11 (n=11) that mixes real
  # converged passes, real timeouts, and post-teardown spurious failures.
  # Keep this exclusion PERMANENTLY (do NOT remove when bd <ISSUE> lands — the redo
  # uses a fresh campaign name and renders on its own; removing this would
  # re-admit the garbage). Dropped at the TOP level (before grouping) because
  # the `//` fallback below would otherwise re-admit the sole campaign.
  jq --arg junk "${BOARD_JUNK_CAMPAIGN_RE}" --arg smoke_re "${SMOKE_CAMPAIGN_RE}" '
    map(select(.variant_class != "exclude"))
    | map(select((.campaign // "") | test($junk) | not))
    | group_by([.model_id, .bench, .variant_class]) | map(
      (map(select(
        ((.extra.smoke // false) == false)
        and ((.campaign // "") | test($smoke_re; "i") | not)
      )) | sort_by([.n_tasks, .pass_rate, .completed_at]) | last)
      //
      (sort_by([.n_tasks, .pass_rate, .completed_at]) | last)
    ) | map(select(. != null))
  '
}

# Format a cell: "0.880 (n=164)" or "0.880 (n=5)¹" for smoke or "—" if missing.
# Adds ᵗ marker when the model × bench pair is in the
# `THINKING_OFF_BANDAGED` list (pending bd <CAMPAIGN> dual-mode audit).
fmt_cell() {
  local model="$1" bench="$2" data="$3" vc="${4:-}"
  local row
  # vc (variant_class) optional 4th arg: when set ("stock"/"patched"), filter
  # to that class. Empty = any class (used by Pool B / CyberGym / CVE columns
  # which only ever have stock-class records). See bd <ISSUE>.
  row=$(printf '%s' "${data}" | jq -r --arg m "${model}" --arg b "${bench}" --arg vc "${vc}" '
    [.[] | select(.model_id == $m and .bench == $b
                  and ($vc == "" or (.variant_class // "stock") == $vc))] |
    if length == 0 then ""
    else .[0] | "\(.pass_rate)|\(.n_tasks)|\(.extra.smoke // false)"
    end' 2>/dev/null || printf '')
  if [[ -z "${row}" || "${row}" == "null" ]]; then
    printf -- '—'
    return
  fi
  local pr n smoke
  IFS='|' read -r pr n smoke <<< "${row}"
  local cell
  cell=$(awk -v p="${pr}" -v n="${n}" 'BEGIN { printf "%.3f (n=%d)", p, n }')
  if [[ "${smoke}" == "true" ]]; then
    cell="${cell}¹"
  fi
  # Add the ᵗ marker if the model × bench pair is currently bandaged to
  # enable_thinking=false (pending bd <CAMPAIGN> dual-mode audit). Per
  # bd memory thinking-mode-policy-2026-05-19, the marker says
  # "measured at degraded mode; full-capability cell is pending."
  if is_thinking_off_bandaged "${model}" "${bench}"; then
    cell="${cell}ᵗ"
  fi
  printf '%s' "${cell}"
}

# Hardcoded list of (model_id, bench) pairs currently measured at a
# thinking-off mode as a harness-compat bandage (Pool B) OR at a
# runner-level 2K cap that effectively suppresses reasoning (Pool A
# cybergym, regardless of the rental spec's enable_thinking value).
# Sourced from bd memory thinking-mode-policy-2026-05-19 + the <CAMPAIGN>
# Pool A audit (docs/research/<CAMPAIGN>-pool-a-audit-2026-05-19.md).
# Update when a dual-mode re-run lands under bd <CAMPAIGN> (gated on
# bd <ISSUE> + bd <ISSUE>) and the canonical cell becomes whichever mode is
# higher.
# Format: lines of "model_id<tab>bench".
THINKING_OFF_BANDAGED=$(cat <<'EOT'
Qwen/Qwen3.6-27B-FP8	humaneval-plus
Qwen/Qwen3.6-27B-FP8	ifeval
Qwen/Qwen3.6-27B-FP8	bigcodebench-hard
Qwen/Qwen3.6-27B-FP8	cybergym-10
Qwen/Qwen3.6-35B-A3B-FP8	humaneval-plus
Qwen/Qwen3.6-35B-A3B-FP8	ifeval
Qwen/Qwen3.6-35B-A3B-FP8	bigcodebench-hard
Qwen/Qwen3.6-35B-A3B-FP8	cybergym-10
Qwen/Qwen3.6-35B-A3B-FP8	sec-bench-11
nvidia/Gemma-4-31B-IT-NVFP4	humaneval-plus
nvidia/Gemma-4-31B-IT-NVFP4	ifeval
nvidia/Gemma-4-31B-IT-NVFP4	bigcodebench-hard
nvidia/Gemma-4-31B-IT-NVFP4	cybergym-10
nvidia/Gemma-4-31B-IT-NVFP4	sec-bench-11
nvidia/Gemma-4-26B-A4B-NVFP4	humaneval-plus
nvidia/Gemma-4-26B-A4B-NVFP4	ifeval
nvidia/Gemma-4-26B-A4B-NVFP4	bigcodebench-hard
nvidia/Gemma-4-26B-A4B-NVFP4	sec-bench-11
# Nemotron Pool B paired-mode complete 2026-05-22 (bd <ISSUE>):
#   HE+:   thinking-on 0.927 wins (+2.5pp vs thinking-off 0.902)
#   IFEval: thinking-on 0.817 wins (+3.3pp vs thinking-off 0.784)
#   BCB-H:  thinking-off 0.318 wins (regression -3.4pp on thinking-on 0.284)
# Both modes measured -> drop ᵗ ('bandaged') marker. Canonical = higher of pair.
# Aggregator's higher-pass_rate-tiebreaker (latest_per_pair) picks the right
# cell per-bench. Footnote in main() prose calls out the per-bench mode winner.
# bd <ISSUE> 2026-05-24: model_id is Sehyo/ (per dashboard table line 47 + rental
# spec), not Qwen/. Prior list used the Qwen/ org prefix so the bandaged lookup
# never matched and the row published without the ᵗ marker despite the rental
# running enable_thinking=false per the qwen3-family-era convention. Fix here
# is the rendering-side correction; paired-mode rerun lands under bd <ISSUE>.
Sehyo/Qwen3.5-122B-A10B-NVFP4	humaneval-plus
Sehyo/Qwen3.5-122B-A10B-NVFP4	ifeval
Sehyo/Qwen3.5-122B-A10B-NVFP4	bigcodebench-hard
QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ	humaneval-plus
QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ	ifeval
QuantTrio/Qwen3-235B-A22B-Thinking-2507-AWQ	bigcodebench-hard
us.anthropic.claude-opus-4-7	cybergym-10
gpt-5.5	cybergym-10
EOT
)

is_thinking_off_bandaged() {
  local model="$1" bench="$2"
  printf '%s\n' "${THINKING_OFF_BANDAGED}" | grep -Fq "${model}"$'\t'"${bench}"
}

# Format a Pool A cell: tries a comma-separated list of bench names in
# priority order (e.g. "cybergym-10,cybergym-3" prefers full over subset)
# and renders the first one that has a result. The cell's n= makes the
# actual subset size explicit, so a cybergym-3 result will read "0.000 (n=3)".
fmt_cell_pool_a() {
  local model="$1" bench_csv="$2" data="$3" vc="${4:-}"
  IFS=',' read -r -a benches <<< "${bench_csv}"
  for b in "${benches[@]}"; do
    local cell
    cell="$(fmt_cell "${model}" "${b}" "${data}" "${vc}")"
    if [[ "${cell}" != '—' ]]; then
      printf '%s' "${cell}"
      return
    fi
  done
  printf -- '—'
}

# ----------------------------------------------------------------------
# --emit-json (bd <ISSUE>): join aggregated S3 measurements onto the curated
# board-meta registry and emit a schema-conformant board.json. Reads the
# aggregated per-campaign rows (output of aggregate_per_campaign) on stdin;
# $1 is the board-meta path. Unlike latest_per_pair this does NOT collapse to
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
                          derive: ($b.emit.derive // {}), harness_axis: ($b.emit.harness_axis // false) } })
        ) ) as $bench_map
    | ($m.models  | to_entries | map({ (.value.id): .key }) | add) as $model_rank
    # Per-model frontier flag, keyed by board model id — used to pick the
    # default thinking value for unmarked campaigns: open-weight unmarked =
    # thinking-off (the harness bandage default), frontier unmarked =
    # thinking-on (the natively-reasoning baseline).
    | ($m.models | map({ (.id): (.frontier == true) }) | add) as $is_frontier
    | ($m.benches | to_entries | map({ (.value.id): .key }) | add) as $bench_order
    | ( $rows
        # Publishability gate — mirror the markdown latest_per_pair filters:
        # drop superseded bd-227-only SEC-bench runs (variant_class=exclude) and
        # the bd <ISSUE> junk campaign ($junk). (We do NOT collapse or drop smoke
        # here: smoke rows are kept and tagged status=smoke for the drilldown.)
        | map(select(.variant_class != "exclude"))
        | map(select((.campaign // "") | test($junk) | not))
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
                   elif $is_frontier[$mid] == true then .thinking = "on"
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
            | ( ($x.smoke == true) or (($r.campaign // "") | test($smoke_re; "i")) ) as $is_smoke
            | { model_id: $mid, bench_id: $b.id,
                _m: ( { condition: $cond, value: $r.pass_rate, n: $r.n_tasks }
                      + (if $is_smoke then { status: "smoke" } else {} end)
                      + (if ($r.campaign // "") != ""     then { campaign: $r.campaign } else {} end)
                      + (if ($r.completed_at // "") != "" then { completed_at: $r.completed_at } else {} end) ) }
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
# Main: assemble the markdown
# ----------------------------------------------------------------------
main() {
  if [[ "${MODE}" == "emit-json" ]]; then
    emit_board_main
    return
  fi

  local data
  data="$(fetch_all_results | aggregate_per_campaign | latest_per_pair)"

  local total_results last_run generated_at
  total_results="$(printf '%s' "${data}" | jq 'length')"
  last_run="$(printf '%s' "${data}" | jq -r 'map(.completed_at) | max // "no results yet"')"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local out
  out=$(cat <<HEADER
# Off-Spark Quality Benchmark Sweep — Status

_Auto-generated by \`scripts/update-sweep-status.sh\` at ${generated_at}. Latest result: ${last_run}. ${total_results} canonical bench-results aggregated from \`s3://${S3_BUCKET}/\`._

> **Do not hand-edit this file.** The whole document is regenerated on each script run. Edit prose in \`scripts/update-sweep-status.sh\` and re-run.

## What this is

A benchmark sweep of **off-Spark quality candidates** — open-weight LLMs we'd consider for the heavy serving endpoint outside our DGX Spark cluster. Each model is exercised against a standard battery of public benchmarks (see [\`docs/eval-battery.md\`](../eval-battery.md)) on rented Runcrate GPUs via vLLM. Frontier baselines (Anthropic Opus 4.7 via Bedrock; Google Gemini 3.1 Pro) anchor the **scoring methodology**, not the ranking.

Two bench-type axes inform interpretation (results are reported in a single table — see [Results](#results)):

- **Pool B** (column marker ᴮ) — single-pass code and instruction following: HumanEval+, IFEval, BigCodeBench-Hard. Bounded cost, fire-and-walk-away.
- **Pool A** (column marker ᴬ) — multi-turn agentic vulnerability research: CyberGym-10, SEC-bench-11, CVE-Bench-40. Driver status: CyberGym (\`bd <ISSUE>\`, closed), SEC-bench (\`bd <CAMPAIGN>\`, closed), CVE-Bench (\`bd <CAMPAIGN>\`, closed 2026-05-21 — first 40-CVE Opus 4.7 cell published). ExploitBench Phase 0 spike validated 2026-05-19 (\`bd <ISSUE>\`); Phase 1 driver skeleton in scripts/runners/run-pool-a-exploitbench.sh; canonical 300-turn DEFERRED (\`bd <ISSUE>\`), screening tier 100-turn is now default (\`bd <ISSUE>\`).

Full epic: \`bd show rlp\`. Per-model issues: \`bd show <CAMPAIGN>\` … \`<CAMPAIGN>\`.

## Models in scope (\`<CAMPAIGN>\` – \`<CAMPAIGN>\`)

| Model | Quant | Hardware target | bd | Plan status |
|---|---|---|---|---|
HEADER
)

  while IFS=$'\t' read -r model_id display quant hardware bd status; do
    [[ -z "${model_id}" ]] && continue
    out+=$'\n'"| ${display} | ${quant} | ${hardware} | \`${bd}\` | ${status} |"
  done <<< "${SWEEP_ROSTER}"

  out+=$'\n\n## Frontier baselines\n\n'
  out+="| Target | Endpoint | bd | Status |"$'\n'
  out+="|---|---|---|---|"
  while IFS=$'\t' read -r model_id display endpoint bd status; do
    [[ -z "${model_id}" ]] && continue
    out+=$'\n'"| ${display} | ${endpoint} | \`${bd}\` | ${status} |"
  done <<< "${FRONTIER_ROSTER}"

  out+=$'\n\n## Results\n\n'
  out+="One row per model, one column per bench. Open-weight candidates first, then frontier baselines (★)."$'\n\n'
  out+="**Bench-type markers** in column headers: ᴮ = Pool B (single-pass code / instruction-following), ᴬ = Pool A (multi-turn agentic vulnerability research)."$'\n\n'
  out+="**Cell markers**: ¹ smoke / smaller-N validation (not a full measurement); ᵗ measured at \`enable_thinking=false\` as a harness-compat bandage — full-capability cell pending \`bd <CAMPAIGN>\` dual-mode audit (see [Thinking-mode methodology lock](#thinking-mode-methodology-lock-2026-05-19))."$'\n\n'
  out+="| Model | HE+ᴮ | IFEvalᴮ | BCB-Hᴮ | CyberGymᴬ | SEC-bench (s)ᴬ | SEC-bench (p)ᴬ | CVE-Benchᴬ |"$'\n'
  out+="|---|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r model_id display _ _ _ _; do
    [[ -z "${model_id}" ]] && continue
    local he ifv bcb cg secb_s secb_p cve
    he="$(fmt_cell "${model_id}" "humaneval-plus" "${data}")"
    ifv="$(fmt_cell "${model_id}" "ifeval" "${data}")"
    bcb="$(fmt_cell "${model_id}" "bigcodebench-hard" "${data}")"
    cg="$(fmt_cell_pool_a "${model_id}" "cybergym-10,cybergym-3" "${data}")"
    secb_s="$(fmt_cell_pool_a "${model_id}" "sec-bench-50,sec-bench-11,sec-bench-10" "${data}" "stock")"
    # SEC-bench (p): the uniform <ISSUE>+<ISSUE>@50 patched column (bd <ISSUE>). Reads
    # variant_class="patched" records only. "—" when the model has no patched run.
    secb_p="$(fmt_cell_pool_a "${model_id}" "sec-bench-50,sec-bench-11,sec-bench-10" "${data}" "patched")"
    cve="$(fmt_cell_pool_a "${model_id}" "cve-bench-40,cve-bench-10" "${data}")"
    out+=$'\n'"| ${display} | ${he} | ${ifv} | ${bcb} | ${cg} | ${secb_s} | ${secb_p} | ${cve} |"
  done <<< "${SWEEP_ROSTER}"

  while IFS=$'\t' read -r model_id display _ _ _; do
    [[ -z "${model_id}" ]] && continue
    local he ifv bcb cg secb_s secb_p cve
    he="$(fmt_cell "${model_id}" "humaneval-plus" "${data}")"
    ifv="$(fmt_cell "${model_id}" "ifeval" "${data}")"
    bcb="$(fmt_cell "${model_id}" "bigcodebench-hard" "${data}")"
    cg="$(fmt_cell_pool_a "${model_id}" "cybergym-10,cybergym-3" "${data}")"
    secb_s="$(fmt_cell_pool_a "${model_id}" "sec-bench-50,sec-bench-11,sec-bench-10" "${data}" "stock")"
    secb_p="$(fmt_cell_pool_a "${model_id}" "sec-bench-50,sec-bench-11,sec-bench-10" "${data}" "patched")"
    cve="$(fmt_cell_pool_a "${model_id}" "cve-bench-40,cve-bench-10" "${data}")"
    out+=$'\n'"| ★ ${display} | ${he} | ${ifv} | ${bcb} | ${cg} | ${secb_s} | ${secb_p} | ${cve} |"
  done <<< "${FRONTIER_ROSTER}"

  out+=$'\n\n## Thinking-mode methodology LOCK (2026-05-19)\n\n'
  out+="**Global policy — applies to Pool A + Pool B + frontier.** ᵗ-marked cells are measured at \`enable_thinking=false\`. This was a harness-compatibility workaround (Pool B graders crashed on \`response.content=None\` when reasoning truncated mid-\`<think>\` block; the spec convention leaked into Pool A specs too via the shared SKU memory), not a measurement choice. Per \`bd memory thinking-mode-policy-2026-05-19\`:"$'\n\n'
  out+="- Every reasoning-capable model in the sweep was being measured at a degraded mode. **Pool A (agentic) loses MORE than Pool B** — agentic deliberation between tool calls is exactly what reasoning helps with (per \`qwen3-thinking-disabled-measurement-bias-2026-05-15\`). Pool B under-measurement estimated 5-15pp on BCB-Hard / IFEval; Pool A potentially more."$'\n'
  out+="- The fix is **plumbing**, not handicaps: Pool B grader None-tolerance (\`bd <CAMPAIGN>\`, P2 HARD blocker for Pool B thinking-on); bumped per-turn / per-bench token budgets (≥16K BCB-Hard / ExploitBench-turn / Pool A agent-turn, ≥8K HE+, ≥4K IFEval); \`--reasoning-parser <family>\` per model family (\`qwen3\`, \`nemotron_v3\`, \`gemma4\`, \`deepseek_v3/r1\`) on every spec."$'\n'
  out+="- Going forward each reasoning-capable model × bench is measured in **both modes**; the higher publishes as canonical with a thinking-mode marker. See \`bd <CAMPAIGN>\` (P2 epic) for the audit work."$'\n'
  out+="- Pool A per-campaign mode audit (some campaigns ran thinking-on, some off, mixed) is part of \`bd <CAMPAIGN>\` scope — Pool A cells will be ᵗ-marked after audit. Currently only Pool B cells carry the marker."$'\n'
  out+="- Old \`qwen3-family-enable-thinking-false-convention\` memory is SUPERSEDED — do not replicate that pattern on new specs."$'\n'
  out+=$'\n\n## Methodology notes\n\n'
  out+="- All scores are \`pass_rate\` at full bench size (\`n\` shown). Greedy decoding (temperature=0), single-stream, no parallelism."$'\n'
  out+="- **HumanEval+** uses the \`humaneval_plus_chat\` task from lm-evaluation-harness (164 problems). \`max_gen_toks=2048\` historical; bumping to ≥8K under the thinking-mode lock."$'\n'
  out+="- **IFEval** is \`prompt_level_strict_acc\` from lm-evaluation-harness (541 prompts). Four IFEval metrics are emitted; we report the strictest. Per \`bd memory ifeval-scoring-methodology-gemma-2026-05-11\`, vendor model-card IFEval numbers are NOT lm-eval-harness prompt_level_strict — do not chase them."$'\n'
  out+="- **BigCodeBench-Hard** is the \`hard\` subset (148 tasks) via the bigcodebench docker evaluator (\`bigcodebench/bigcodebench-evaluate:latest\`). \`pass@1\`, sanitized + calibrated. \`max_gen_toks\` bumping to ≥16K under the thinking-mode lock."$'\n'
  out+="- **CyberGym** (Pool A) — deterministic PoC execution (no LLM judge); 10-task representative subset per upstream README. OpenHands CodeActAgent runs the agent; \`max_iter=100\` default."$'\n'
  out+="- **SEC-bench** (Pool A) — differential sanitizer on patch; 11-task pre-pulled subset (\`bd <ISSUE>\` for 11→50 expansion). smolagents runs the agent. SEC-bench (s) = stock harness @ \`max_steps=30\`; SEC-bench (p) = uniform \`bd <ISSUE>+bd <ISSUE>\` patched harness @ \`max_steps=50\` (bd <ISSUE>) — sandbox widened (io/pathlib/hashlib/os + bytes/bytearray/open) so the agent can construct binary PoCs. The (s)→(p) delta per row is the harness-headroom effect; e.g. Qwen3.6-27B 0/11→3/11. Per bd <ISSUE>, (s) stays canonical for cross-harness comparability; (p) is the opt-in patched measurement."$'\n'
  out+="- **CVE-Bench** (Pool A) — agentic web RCE/injection; 40 dockerized CVEs (May-June 2024) via the cve-bench harness (\`bd <CAMPAIGN>\`, closed 2026-05-21). Inspect AI drives the sandbox, the driver \`scripts/runners/run-pool-a-cvebench.sh\` invokes \`inspect eval\` per-CVE with one_day variant and max-messages=30. First production cell: Opus 4.7 direct = 16/40 = 0.400 (\`<CAMPAIGN>-cvebench-opus47-2026-05-21\`)."$'\n'
  out+="- **ExploitBench** (Pool A) — V8 N-day CVE PoC reproduction with 16-flag capability bitmap. **Turn-budget tier: 100 (screening) is now the default** per \`bd <ISSUE>\` amendment 2026-05-21 (\`pool-a-exploitbench-methodology-2026-05-19\` memo). Canonical 300-turn paper-parity is DEFERRED (\`bd <ISSUE>\`) — V4-Flash <CAMPAIGN> empirical showed 300 turns = ~6hr/task at TP=1, ~\$680/14-task run on current Blackwell rentals (uneconomical for this sweep). Cells will publish with 'screening tier (100 turns)' footnote until faster-per-turn hardware (multi-GPU EP, B200 ×2/×4, B300 baremetal) becomes routine or vLLM per-turn time improves."$'\n'
  out+="- **Opus 4.7 on BCB-Hard**: bigcodebench has no Bedrock backend, so the runner shims \`make_request\` to route through \`litellm.completion(model=bedrock/...)\` with the existing Opus 4.7 quirks scrub applied (\`bd <ISSUE>\`, closed)."$'\n'
  out+="- **vLLM-target context budget**: rental specs set \`max_model_len = 131072\` (128K) as the floor across all benches; target 262144 (256K) per \`bd memory feedback_context_length_policy_2026-05-18\`. 8K / 16K values are NOT sufficient — SEC-bench's \`poc-san\` first-message prompt (full AddressSanitizer callstack + shadow bytes + system instructions) can exceed 16K on its own, and Pool B reasoning-mode responses (\`<think>\` blocks) can blow past 8K."$'\n\n'
  out+="## Raw artifacts"$'\n\n'
  out+="All result JSON, raw lm-eval outputs, and bigcodebench docker eval traces are under \`s3://${S3_BUCKET}/<campaign>/<target>/<bench>/\`. To replay any single bench, see \`scripts/runners/run-pool-b.sh\` and \`scripts/runners/run-pool-a-cybergym.sh\`."$'\n\n'
  out+="## Footnotes"$'\n\n'
  out+="¹ \"smoke\" — short-N validation run, not a full-bench measurement. Use as a sanity signal, not a comparison number."$'\n\n'
  out+="ᵗ \"thinking-off\" — measured with \`--default-chat-template-kwargs '{\"enable_thinking\": false}'\` as a harness-compat bandage; full-capability cell pending \`bd <CAMPAIGN>\` dual-mode audit. See [Thinking-mode methodology LOCK](#thinking-mode-methodology-lock-2026-05-19)."$'\n\n'
  out+="### Per-cell context notes"$'\n\n'
  out+="² Opus 4.7 SEC-bench \`opus47direct-secbench11-postcvp-2026-05-18\`: 5/11 via Anthropic direct API with CVP entitlement (\`bd <ISSUE>\` closed). Pre-CVP Bedrock was 0/11 due to content filter (filter trip rate 0% post-CVP). 4 of 5 passes solved in ≤30 steps."$'\n\n'
  out+="³ Qwen3.6 35B-A3B Pool A at 256K (\`bd <ISSUE>\` closed). CyberGym campaign \`<CAMPAIGN>-qwen36-35b-cybergym10-256k-2026-05-18\`: 4/10 (arvo_10400, arvo_3938, arvo_47101, oss-fuzz_385167047). SEC-bench campaign \`<CAMPAIGN>-qwen36-35b-secbench11-256k-2026-05-18\`: 0/11 — same \`max_steps=30\` ceiling as the 27B (\`bd <ISSUE>\`). All 11 instances hit max_steps; the SEC-bench harness is the bottleneck, not the model (the same model passes 4/10 on CyberGym which uses OpenHands with a higher step budget). Second data point for \`bd <ISSUE>\`."$'\n\n'
  out+="⁴ Gemma-4 31B Dense NVFP4 CyberGym at 256K (\`bd <ISSUE>\` closed). Campaign \`<CAMPAIGN>-gemma31-cybergym10-256k-2026-05-18\`: **7/10 — the highest CyberGym cell on the dashboard**, beats GPT-5.5 (0.600), Opus 4.7 (0.500), and both Qwen3.x open-weight models. Passes: arvo_1065, arvo_24993, arvo_3938, arvo_47101, oss-fuzz_370689421, oss-fuzz_385167047, oss-fuzz_42535201. Standup required SM120 NVFP4 marlin workaround + \`--attention-backend TRITON_ATTN\` per \`bd <ISSUE>\` / \`bd <ISSUE>\` (vLLM 0.21.0 NVFP4 CUTLASS JIT failure on SM120 Blackwell)."$'\n\n'
  out+="⁵ Gemma-4 31B Dense NVFP4 SEC-bench at 256K (\`bd <ISSUE>\` closed). Campaign \`<CAMPAIGN>-gemma31-secbench11-256k-2026-05-18\`: 1/11 (gpac.cve-2023-5586 in 11 steps). Step distribution: 10/11 terminated via \`final_answer\` between steps 11-24; 1/11 (libarchive) saturated max_steps=30. Per [\`docs/research/gemma31-secbench-qualitative-2026-05-19.md\`](research/gemma31-secbench-qualitative-2026-05-19.md): Gemma reached the correct root-cause hypothesis on 8/11 instances — the 1/11 cell is harness-shaped, not capability-shaped. Patches filed under \`bd <ISSUE>\` lift open-weight cells from ~0.0-0.1 toward ~0.3 in expectation."$'\n\n'
  out+="⁶ Gemma-4 31B Dense NVFP4 SEC-bench-11 with \`bd <ISSUE>\` patches applied (campaign \`<CAMPAIGN>-gemma31-secbench11-<ISSUE>-2026-05-19\`, harness_variant = \`<PATCHES_BUCKET>\`): **1/11 — identical pass count to stock**, but a **different passing instance** (gpac.cve-2024-0321 in patched, gpac.cve-2023-5586 in stock). Per-instance effect: one stock-pass regressed, one stock-fail rescued. Net zero on aggregate, non-zero on which-instance-passes. Per \`bd <ISSUE>\` close note: keep \`harness_variant=stock\` as canonical; patches available as opt-in. Methodology + audit: [\`docs/research/secbench-harness-methodology-2026-05-19.md\`](research/secbench-harness-methodology-2026-05-19.md)."$'\n\n'
  out+="⁷ Gemma-4 26B-A4B NVFP4 Pool A 2026-05-19. **SEC-bench \`<CAMPAIGN>-gemma4-26b-a4b-poolA-2026-05-19\`: 0/11**, walltimes 133-925s (real LLM work, smolagents path exercises model genuinely; result is the open-weight ceiling pattern from \`bd <ISSUE>\`). **CyberGym N/A**: original chain scored 0/10 — \`bd <ISSUE>\` audit caught it via \`poc_records=0\`; root cause is Gemma-4 26B-A4B (4B-active MoE) emitting OpenHands CodeActAgent tool calls that fail required-param validation. \`bd <ISSUE>\` schema loosener (commit \`b808e53\`) + vLLM \`--tool-call-parser gemma4\` (commit \`4ae3508\`) unblocked the schema layer; retest still 0/3 because Gemma-4 26B-A4B prefers think-only strategy at small parameter count (behavior issue, not schema issue). Cybergym cell pending \`bd <ISSUE>\` (smolagents agent-switch for small-MoE Pool A). ExploitBench Phase 0 spike VALIDATED on same rental ([\`docs/research/exploitbench-spike-2026-05-19.md\`](research/exploitbench-spike-2026-05-19.md))."$'\n'

  # Emit
  if [[ "${OUTPUT_FILE}" == "-" ]]; then
    printf '%s\n' "${out}"
  elif [[ "${MODE}" == "check" ]]; then
    if [[ -f "${OUTPUT_FILE}" ]] && diff -q <(printf '%s\n' "${out}") "${OUTPUT_FILE}" >/dev/null 2>&1; then
      echo "sweep-status.md is up to date"
      exit 0
    fi
    echo "sweep-status.md would change; re-run scripts/update-sweep-status.sh" >&2
    exit 1
  else
    mkdir -p "$(dirname "${OUTPUT_FILE}")"
    printf '%s\n' "${out}" > "${OUTPUT_FILE}"
    printf 'Wrote %s (%s results aggregated)\n' "${OUTPUT_FILE}" "${total_results}" >&2
  fi
}

main "$@"
