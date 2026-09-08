#!/bin/sh
# M2 d / T17 的评估半边，一条命令跑完并**逐项自检**（规模压测在 scale_test.py 里）。
#
#   建 1 个月库 → 造 100 题（含"原 60 题一个字没改"与"两次生成逐字节相同"两项核对）
#   → 执行删除并对账 → verify-tools 真跑 22 道工具题 → 第一阶段三档留出口径
#   → 变异检验（五个失败桶各一道）+ 六类归因核对 → 第二阶段（未评分 + 一道故意答错的）
#   → 100 题的六类归因分布 → 月报（把留出题的检索回归写进去）
#
# 用法：
#   sh tools/eval/run_t17_eval.sh
#   SCRATCH=~/Library/Caches/brosis-build/verify-t17 sh tools/eval/run_t17_eval.sh
#   SKIP_BUILD=1 sh tools/eval/run_t17_eval.sh          # 复用已有的 brosis-store
#   PER_DAY=2880 sh tools/eval/run_t17_eval.sh          # 冒烟（别调 DAYS，见 README §1）
#
# 项目目录里不留任何产物：全部落在 $SCRATCH 下。
set -e

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/m2-eval-scale}"
E="$REPO/tools/eval"
W="$SCRATCH/eval"
R="$SCRATCH/results"
PY="env PYTHONDONTWRITEBYTECODE=1 python3"
BIN="${BIN:-$SCRATCH-core/release/brosis-store}"
DAYS="${DAYS:-30}"
PER_DAY="${PER_DAY:-8640}"
AVG_CHARS="${AVG_CHARS:-1500}"
SEED="${SEED:-20260908}"
TZ_ARG="${TZ_ARG:-UTC}"
# 「原 60 题一个字没改」是拿哪一版脚本比出来的：M2 c 批的提交（8b732dc）
M1_REV="${M1_REV:-8b732dc}"

mkdir -p "$W" "$R"
echo "SCRATCH=$SCRATCH  BIN=$BIN"

if [ -z "$SKIP_BUILD" ]; then
  echo "== 0. 构建 brosis-store（release，零 warning）=="
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build --package-path "$REPO/core" -c release --scratch-path "$SCRATCH-core" \
    2>&1 | tee "$R/build.log" | tail -2
  grep -c "warning:" "$R/build.log" > "$R/build_warnings.txt" || true
fi

echo "== 1. 生成 1 个月合成流并建库（E7 口径：$DAYS 天 × $PER_DAY 条/天）=="
$PY "$REPO/tools/proto/gen_synth_m1.py" gen \
  --out "$W/synth_1m.jsonl" --queries "$W/queries_1m.json" \
  --days "$DAYS" --per-day "$PER_DAY" --avg-chars "$AVG_CHARS" --seed "$SEED" > "$R/eval_gen.json"
rm -rf "$W/db" "$W/db.key"
"$BIN" init --dir "$W/db" --key-file "$W/db.key" > "$R/eval_init.json"
/usr/bin/time -l "$BIN" import-jsonl --dir "$W/db" --key-file "$W/db.key" \
  --file "$W/synth_1m.jsonl" > "$R/eval_import.json" 2> "$R/eval_import.time"

echo "== 2. 造 100 题（六类 25/26/13/14/14/8，留出 30 题）=="
$PY "$E/make_synthetic_queryset.py" gen \
  --jsonl "$W/synth_1m.jsonl" --corpus "$W/queries_1m.json" \
  --out "$W/queryset_100.json" --seed "$SEED" > "$R/queryset_gen.json"
$PY "$E/make_synthetic_queryset.py" gen \
  --jsonl "$W/synth_1m.jsonl" --corpus "$W/queries_1m.json" \
  --out "$W/queryset_100_again.json" --seed "$SEED" > /dev/null

echo "== 2b. 核对：原 60 题一个字没改 + 两次生成逐字节相同 =="
git -C "$REPO" show "$M1_REV:tools/eval/make_synthetic_queryset.py" > "$W/make_queryset_m1.py"
$PY "$W/make_queryset_m1.py" gen \
  --jsonl "$W/synth_1m.jsonl" --corpus "$W/queries_1m.json" \
  --out "$W/queryset_60_m1.json" --seed "$SEED" > /dev/null
$PY - "$W/queryset_60_m1.json" "$W/queryset_100.json" "$W/queryset_100_again.json" \
      "$R/queryset_diff.json" <<'PYEOF'
import json, sys
old = json.load(open(sys.argv[1], encoding="utf-8"))
new = json.load(open(sys.argv[2], encoding="utf-8"))
again = json.load(open(sys.argv[3], encoding="utf-8"))
o = {q["id"]: q for q in old["queries"]}
n = {q["id"]: q for q in new["queries"]}
NEW = {"difficulty", "tool", "truth_mode", "holdout", "authored", "tool_call", "tool_check"}
diffs = [{"id": qid, "field": k, "old": str(v)[:120], "new": str(n.get(qid, {}).get(k))[:120]}
         for qid, oq in o.items() for k, v in oq.items()
         if k not in NEW and n.get(qid, {}).get(k) != v]
hold = [qid for qid in o if qid in n and o[qid]["holdout"] != n[qid]["holdout"]]
a, b = dict(again), dict(new)
a.pop("generated_at"); b.pop("generated_at")
det = json.dumps(a, sort_keys=True, ensure_ascii=False) == json.dumps(b, sort_keys=True,
                                                                     ensure_ascii=False)
out = {"m1_queries": len(o), "m2_queries": len(n),
       "m1_ids_all_present": all(q in n for q in o),
       "field_diffs_on_m1_60": diffs, "m1_60_unchanged": not diffs,
       "holdout_flag_changed_on_m1_60": hold, "deterministic_two_runs": det,
       "ok": (not diffs) and (not hold) and det and all(q in n for q in o)}
json.dump(out, open(sys.argv[4], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(json.dumps({k: out[k] for k in ("m1_60_unchanged", "holdout_flag_changed_on_m1_60",
                                      "deterministic_two_runs", "ok")}, ensure_ascii=False))
if not out["ok"]:
    raise SystemExit("原 60 题被改动了，或者生成不确定")
PYEOF

echo "== 3. 执行删除并对账 + 建会话 =="
$PY "$E/make_synthetic_queryset.py" apply-deletions \
  --queryset "$W/queryset_100.json" --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" \
  --out "$R/deletions.json" > /dev/null
"$BIN" sessions --dir "$W/db" --key-file "$W/db.key" --tz "$TZ_ARG" --build > "$R/sessions.json"

echo "== 4. verify-tools：22 道工具题真的调 brosis-store 跑一遍 =="
$PY "$E/make_synthetic_queryset.py" verify-tools \
  --queryset "$W/queryset_100.json" --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" \
  --out "$R/tool_checks.json"

echo "== 5. 第一阶段：三档留出口径 =="
for MODE in default include only; do
  FLAG=""
  [ "$MODE" = include ] && FLAG="--include-holdout"
  [ "$MODE" = only ] && FLAG="--holdout-only"
  $PY "$E/eval_stage1.py" $FLAG --queryset "$W/queryset_100.json" --bin "$BIN" \
    --dir "$W/db" --key-file "$W/db.key" --tz "$TZ_ARG" --check-corpus \
    --batch-file "$W/batch_$MODE.json" \
    --out-json "$R/stage1_$MODE.json" --out-md "$R/stage1_$MODE.md" \
    > "$R/stage1_${MODE}_stdout.json"
done

echo "== 6. 变异检验：五个失败桶各一道 + 六类归因核对 =="
$PY "$E/make_synthetic_queryset.py" mutate \
  --queryset "$W/queryset_100.json" --stage1 "$R/stage1_include.json" \
  --deletions "$R/deletions.json" --out "$W/queryset_mut.json" > "$R/mutate.json"
$PY "$E/eval_stage1.py" --include-holdout --queryset "$W/queryset_mut.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --tz "$TZ_ARG" --batch-file "$W/batch_mut.json" \
  --out-json "$R/stage1_mut.json" --out-md "$R/stage1_mut.md" > "$R/stage1_mut_stdout.json"
$PY "$E/triage_failures.py" --queryset "$W/queryset_mut.json" --stage1 "$R/stage1_mut.json" \
  --out-json "$R/triage_mut.json" --out-md "$R/triage_mut.md" > "$R/triage_mut_stdout.json"
$PY "$E/make_synthetic_queryset.py" verify-mutations \
  --queryset "$W/queryset_mut.json" --stage1 "$R/stage1_mut.json" \
  --triage "$R/triage_mut.json" --out "$R/mutation_check.json"

echo "== 7. 第二阶段：打包（未评分）+ 一道故意答错的（造「推理错误」）=="
$PY "$E/eval_stage2.py" --queryset "$W/queryset_100.json" --stage1 "$R/stage1_include.json" \
  --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" --outdir "$R/stage2" \
  --out-json "$R/stage2.json" --out-md "$R/stage2.md" > "$R/stage2_stdout.json"
$PY - "$W/queryset_100.json" "$R/stage1_include.json" "$W/answers_one_wrong.json" <<'PYEOF'
import json, sys
qs = json.load(open(sys.argv[1], encoding="utf-8"))
st = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))["per_query"]}
WRONG = "det-01"          # 证据齐、没被裁，答案却驴唇不对马嘴 => 只能是「推理错误」
ans = {}
for q in qs["queries"]:
    row = st[q["id"]]
    if q["expect"] == "none":
        ans[q["id"]] = {"answer": "无证据。", "unanswerable": True, "cited_evidence_ids": []}
        continue
    rel = set(q.get("relevant") or [])
    cited = ([i for i in row["evidence_ids"] if i in rel][:3] if rel
             else (row.get("evidence_matched_ids") or [])[:3])
    if q["id"] == WRONG:
        ans[q["id"]] = {"answer": "你当时在看一份季度报告。", "unanswerable": False,
                        "cited_evidence_ids": cited}
    else:
        ans[q["id"]] = {"answer": q["answer"], "unanswerable": False,
                        "cited_evidence_ids": cited}
json.dump(ans, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
$PY "$E/eval_stage2.py" --queryset "$W/queryset_100.json" --stage1 "$R/stage1_include.json" \
  --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" --outdir "$R/stage2_one_wrong" \
  --provider file --answers "$W/answers_one_wrong.json" \
  --out-json "$R/stage2_one_wrong.json" --out-md "$R/stage2_one_wrong.md" \
  > "$R/stage2_one_wrong_stdout.json"

echo "== 8. 六类归因：100 题（含第二阶段那一道错的）=="
$PY "$E/triage_failures.py" --queryset "$W/queryset_100.json" \
  --stage1 "$R/stage1_include.json" --stage2 "$R/stage2_one_wrong.json" \
  --write-annotations "$W/triage_annotations.jsonl" \
  --out-json "$R/triage_100.json" --out-md "$R/triage_100.md" > "$R/triage_100_stdout.json"
$PY "$E/triage_failures.py" --queryset "$W/queryset_100.json" \
  --stage1 "$R/stage1_include.json" \
  --out-json "$R/triage_100_stage1_only.json" --out-md "$R/triage_100_stage1_only.md" \
  > "$R/triage_100_stage1_only_stdout.json"
$PY "$E/triage_failures.py" --queryset "$W/queryset_100.json" --stage1 "$R/stage1_only.json" \
  --out-json "$R/triage_holdout.json" --out-md "$R/triage_holdout.md" \
  > "$R/triage_holdout_stdout.json"

echo "== 9. 月报（把留出题的检索回归写进去）=="
"$BIN" stats --dir "$W/db" --key-file "$W/db.key" --detail > "$R/stats.json"
"$BIN" ledger --dir "$W/db" --key-file "$W/db.key" --tz "$TZ_ARG" --days > "$R/ledger_days.json"
$PY "$E/monthly_report.py" --stats "$R/stats.json" --ledger-days "$R/ledger_days.json" \
  --stage1 "$R/stage1_only.json" --triage "$R/triage_holdout.json" \
  --out-json "$R/monthly.json" --out-md "$R/monthly.md" > "$R/monthly_stdout.json"

echo "== 10. 汇总自检 =="
$PY - "$R" <<'PYEOF'
import json, os, sys
R = sys.argv[1]
def j(n): return json.load(open(os.path.join(R, n), encoding="utf-8"))
checks = []
def ck(name, ok, detail): checks.append({"检查": name, "通过": bool(ok), "实测": detail})

d = j("queryset_diff.json"); ck("原 60 题一个字没改 + 两次生成一致", d["ok"], d["m1_60_unchanged"])
g = j("queryset_gen.json")
ck("100 题、六类配额", g["queries"] == 100, g["by_class"])
ck("留出 30 题", g["holdout_count"] == 30, g["holdout_by_class"])
t = j("tool_checks.json"); ck("22 道工具题的 %d 条断言全过" % t["checks"], t["all_ok"], t["failed"])
dl = j("deletions.json"); ck("删除条数与生成侧模拟对账", dl["all_match"], dl["observations_deleted_total"])
for m, want in (("default", 70), ("include", 100), ("only", 30)):
    s = j("stage1_%s.json" % m)
    ck("第一阶段 %s：跑了 %d 题" % (m, want), s["queries"] == want, s["queries"])
    ck("第一阶段 %s：Recall@10 >= 0.90（2.4）" % m, s["target_2_4"]["met"],
       s["overall"]["recall@10"])
    ck("第一阶段 %s：负例零误报" % m, s["overall"]["none_with_false_positives"] == 0,
       s["overall"]["none_with_false_positives"])
    ck("第一阶段 %s：批量与逐题结果一致" % m, not s["batch_vs_single_mismatch"],
       s["batch_vs_single_mismatch"])
mc = j("mutation_check.json")
ck("变异检验：五道题的第一阶段归因与六类归因都对", mc["all_match"],
   [{r["id"]: (r["bucket"], r.get("triage_bucket"))} for r in mc["rows"]])
tr = j("triage_100.json")
ck("六类归因：100 题里只有故意答错的那一道挂", tr["failures"] == 1, tr["six_class_counts"])
ck("那一道归到「推理错误」", tr["six_class_counts"]["推理错误"] == 1, tr["six_class_counts"])
mo = j("monthly.json")
ck("月报带上了留出题的检索回归", mo["retrieval"]["provided"] and mo["retrieval"]["holdout_mode"] == "only",
   mo["retrieval"].get("holdout_mode"))
out = {"checks": checks, "all_ok": all(c["通过"] for c in checks),
       "failed": [c["检查"] for c in checks if not c["通过"]]}
json.dump(out, open(os.path.join(R, "t17_eval_summary.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=1)
for c in checks:
    print(("  [ok] " if c["通过"] else "  [!!] ") + c["检查"] + " -> " + json.dumps(c["实测"], ensure_ascii=False)[:110])
print("all_ok =", out["all_ok"])
if not out["all_ok"]:
    raise SystemExit("自检没全过：" + ", ".join(out["failed"]))
PYEOF

echo "全部原始输出在 $R"
