#!/usr/bin/env bash
# _phase2_finalize.sh — bd 3xi.2.2: wait for both Opus n-batches to finish, then
# analyze APC + cost and grade both, writing everything to a results file. Runs
# ON the box in its own tmux session so it is immune to SSH-over-SSM drops.
set -uo pipefail
OHB=/opt/harnesses/openhands-benchmarks
PRO=/opt/harnesses/swebench-pro
FORK=/opt/harnesses/swe-rebench-fork
OUTF=/opt/harnesses/phase2_results.txt
export PATH="$HOME/bin:$PATH"
: > "$OUTF"
log(){ echo "$@" | tee -a "$OUTF"; }

log "=== PHASE2 FINALIZE start $(date -u +%FT%TZ) ==="
while tmux has-session -t opusrbn 2>/dev/null || tmux has-session -t opuspron 2>/dev/null; do sleep 15; done
log "=== both batches ended $(date -u +%T) ==="

# ---- rebench (OpenHands) ----
log ""; log "########## REBENCH (OpenHands) Opus n ##########"
OJ=$(find "$OHB/_rebench/eval_opus_n" -name output.jsonl | head -1)
log "output.jsonl records=$(wc -l < "$OJ")"
python3 "$OHB/_rebench/_cache_analyze.py" --source openhands "$OJ" --price opus47 2>/dev/null | tee -a "$OUTF"
python3 - "$OJ" "$OHB/_rebench/predictions_opus_n.jsonl" <<'PY' | tee -a "$OUTF"
import json,sys
recs=[json.loads(l) for l in open(sys.argv[1])]
with open(sys.argv[2],"w") as f:
    for d in recs:
        gp=(d.get("test_result") or {}).get("git_patch","")
        f.write(json.dumps({"instance_id":d["instance_id"],"model_patch":gp,"model_name_or_path":"opus47-rebench"})+"\n")
print("predictions:",len(recs),"nonempty:",sum(1 for d in recs if (d.get("test_result") or {}).get("git_patch","")))
PY
( cd "$FORK" && .venv/bin/python _rebench_grade.py --dataset "$OHB/_rebench/slice.jsonl" \
   --predictions "$OHB/_rebench/predictions_opus_n.jsonl" --out "$OHB/_rebench/grade_opus_n" \
   --timeout 1800 2>&1 | grep -iE "GRADE SUMMARY|resolved=" | tee -a "$OUTF" )

# ---- Pro (SWE-agent) ----
log ""; log "########## PRO (SWE-agent) Opus n ##########"
OUT="$PRO/smoke/sweagent_out_bedrock_us_anthropic_claude-opus-4-7"
python3 "$PRO/cache_probe/_cache_analyze.py" --source sweagent "$OUT/cache_usage.jsonl" --price opus47 2>/dev/null | tee -a "$OUTF"
python3 - "$OUT/preds.json" "$PRO/smoke/preds_n_patches.json" <<'PY' | tee -a "$OUTF"
import json,sys
d=json.load(open(sys.argv[1]))
out=[{"instance_id":k,"patch":v.get("model_patch","")} for k,v in d.items()]
json.dump(out,open(sys.argv[2],"w"))
print("predictions:",len(out),"nonempty:",sum(1 for x in out if x["patch"]))
PY
( cd "$PRO/repo" && source "$PRO/.venv/bin/activate" && \
  python swe_bench_pro_eval.py --raw_sample_path=../smoke/sample_n.jsonl \
    --patch_path=../smoke/preds_n_patches.json --output_dir=../smoke/grade_opus_n \
    --scripts_dir=run_scripts --dockerhub_username=jefzda --use_local_docker --num_workers=2 \
    2>&1 | grep -iE "accuracy|resolved|overall" | tail -20 | tee -a "$OUTF" )

log ""; log "=== PHASE2 FINALIZE done $(date -u +%FT%TZ) ==="
