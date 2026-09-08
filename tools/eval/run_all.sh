#!/bin/sh
# brosis M1 / T6：评估与月报一键复现。
#
# 建 1 个月合成库 → 造 100 题 → 第一阶段（--include-holdout，整套题都跑）→ 变异检验
# → 第二阶段（provider=none）→ 月报。M2 d / T17 起查询集是 100 题（文件名还叫 queryset_60.json），
# T17 那条更全的流水线在 run_t17_eval.sh 里。
# 全部产物落 $SCRATCH（默认 ~/Library/Caches/brosis-build/m1-eval/），**项目目录里不留任何东西**。
#
#   sh tools/eval/run_all.sh                    # 实测 124 / 146 / 153 / 153 s（M4 Air，含 release 构建）
#   SCRATCH=~/Library/Caches/brosis-build/verify-eval sh tools/eval/run_all.sh   # 验收者用自己的
#   PER_DAY=2880 sh tools/eval/run_all.sh       # 冒烟，实测 69 s（含构建）
#
# 冒烟只调 PER_DAY，**不要调 DAYS**：gen_synth_m1.py 的种植按「第 N 周」和「最近 7 天」分布，
# 少于 28 天就有查询词一条都种不出来，查询集自检会直接报「期望可答但真值为空」。
# PER_DAY 也别低于 2880：活动定位那 6 题是「某应用 + 3 小时窗口」，窗口里观察太少时
# 那个应用可能一次都没出现（实测 PER_DAY=720 时有 7 道活动定位题真值为空，
# 第 2 步会逐题列出来后报错退出，不会静默出坏题）。
#
# 需要 Xcode（core 是 SwiftPM 包）：所有 swift 命令前面加 DEVELOPER_DIR。
# SKIP_BUILD=1 可以跳过构建，直接用 $SCRATCH/release/brosis-store。
set -e

# 项目根目录从脚本自身位置推出来（本文件在 <项目目录>/tools/eval/ 下），不写死任何绝对路径
PROJECT="${PROJECT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/m1-eval}"
R="$SCRATCH/results"
W="$SCRATCH/m1"
BIN="$SCRATCH/release/brosis-store"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DAYS="${DAYS:-30}"
PER_DAY="${PER_DAY:-8640}"
SEED="${SEED:-20260907}"
E="$PROJECT/tools/eval"
PY="env PYTHONDONTWRITEBYTECODE=1 python3"

mkdir -p "$R" "$W"

echo "== 0. 构建 release =="
if [ -z "$SKIP_BUILD" ]; then
  DEVELOPER_DIR=$DEV swift build --package-path "$PROJECT/core" -c release \
    --scratch-path "$SCRATCH" > "$R/build_release.log" 2>&1
fi
ls -la "$BIN" > "$R/binary_size.txt"

echo "== 1. 生成 $DAYS 天合成流并建库（口径同 m1_r1_retrieval_ledger 的 collect.sh）=="
/usr/bin/time -l $PY "$PROJECT/tools/proto/gen_synth_m1.py" gen \
  --out "$W/synth_1m.jsonl" --queries "$W/queries_1m.json" \
  --days "$DAYS" --per-day "$PER_DAY" --seed "$SEED" \
  > "$R/gen_synth.json" 2> "$R/gen_synth.time"
ls -la "$W/synth_1m.jsonl" > "$R/jsonl_size.txt"
rm -rf "$W/db" "$W/db.key"
"$BIN" init --dir "$W/db" --key-file "$W/db.key" > "$R/init.json"
/usr/bin/time -l "$BIN" import-jsonl --dir "$W/db" --key-file "$W/db.key" \
  --file "$W/synth_1m.jsonl" --batch 500 > "$R/import.json" 2> "$R/import.time"
"$BIN" maintenance --dir "$W/db" --key-file "$W/db.key" > "$R/maintenance_1.json"
"$BIN" stats --dir "$W/db" --key-file "$W/db.key" --detail > "$R/stats_before_delete.json"

echo "== 2. 造 100 题查询集（真值对 JSONL 全量重算）=="
/usr/bin/time -l $PY "$E/make_synthetic_queryset.py" gen \
  --jsonl "$W/synth_1m.jsonl" --corpus "$W/queries_1m.json" \
  --out "$W/queryset_60.json" --seed "$SEED" \
  > "$R/queryset_gen.json" 2> "$R/queryset_gen.time"

# 确定性：再生成一次，去掉 generated_at 之后必须逐字节相同（脚本里没有随机数）
$PY "$E/make_synthetic_queryset.py" gen \
  --jsonl "$W/synth_1m.jsonl" --corpus "$W/queries_1m.json" \
  --out "$W/queryset_60_again.json" --seed "$SEED" > /dev/null
$PY - "$W/queryset_60.json" "$W/queryset_60_again.json" "$R/determinism.json" <<'PYEOF'
import json, sys, hashlib
def norm(p):
    d = json.load(open(p, encoding="utf-8")); d.pop("generated_at", None)
    return hashlib.sha256(json.dumps(d, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
a, b = norm(sys.argv[1]), norm(sys.argv[2])
out = {"queryset_sha256_run1": a, "queryset_sha256_run2": b, "identical": a == b,
       "note": "去掉 generated_at 时间戳后逐字节比较；查询集生成没有随机数"}
json.dump(out, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False))
if not out["identical"]:
    raise SystemExit("查询集不确定：两次生成不一样")
PYEOF

echo "== 3. 执行删除造「已删除」题，并与生成侧模拟对账 =="
$PY "$E/make_synthetic_queryset.py" apply-deletions \
  --queryset "$W/queryset_60.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --out "$R/deletions.json" > /dev/null
"$BIN" maintenance --dir "$W/db" --key-file "$W/db.key" > "$R/maintenance_2.json"
"$BIN" check --dir "$W/db" --key-file "$W/db.key" > "$R/check.json"
"$BIN" stats --dir "$W/db" --key-file "$W/db.key" --detail > "$R/stats.json"
"$BIN" ledger --dir "$W/db" --key-file "$W/db.key" --days --tz UTC > "$R/ledger_days.json"

echo "== 4. 第一阶段：检索能不能拿到证据 =="
# --include-holdout：本脚本要跑**整套题**（第 7 步的判分器自检要给每一道题造答案）。
# 日常调参用默认口径（留出题排除），月报用 --holdout-only，见 README §2.1b / §2.2。
/usr/bin/time -l $PY "$E/eval_stage1.py" --include-holdout \
  --queryset "$W/queryset_60.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --check-corpus \
  --batch-file "$W/stage1_batch.json" \
  --out-json "$R/stage1.json" --out-md "$R/stage1.md" \
  > "$R/stage1_stdout.json" 2> "$R/stage1.time"

echo "== 5. 变异检验：故意造四道注定失败的题，核对失败归因分类 =="
$PY "$E/make_synthetic_queryset.py" mutate \
  --queryset "$W/queryset_60.json" --stage1 "$R/stage1.json" \
  --deletions "$R/deletions.json" --out "$W/queryset_mut.json" > "$R/mutate.json"
$PY "$E/eval_stage1.py" --include-holdout --queryset "$W/queryset_mut.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --batch-file "$W/stage1_mut_batch.json" \
  --out-json "$R/stage1_mut.json" --out-md "$R/stage1_mut.md" > "$R/stage1_mut_stdout.json"
$PY "$E/make_synthetic_queryset.py" verify-mutations \
  --queryset "$W/queryset_mut.json" --stage1 "$R/stage1_mut.json" \
  --out "$R/mutation_check.json" > /dev/null

echo "== 6. 第二阶段：打包证据与判题提示（provider=none，不联网、不评分）=="
$PY "$E/eval_stage2.py" \
  --queryset "$W/queryset_60.json" --stage1 "$R/stage1.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --outdir "$R/stage2" \
  --out-json "$R/stage2.json" --out-md "$R/stage2.md" > "$R/stage2_stdout.json"

echo "== 7. 判分器自检：两套「已知答案」+ 真实题路径的引用判据 =="
# 好答案：抄标准答案 + 引真值 id；坏答案：可答题瞎编、不可答题硬答。100 题应当分别全过 / 全挂。
# 工具题（M2 d / T17）的 relevant 是空的，好答案改引第一阶段判定「满足期望证据」的 id
# （eval_stage2.py 的 citation_basis 会自动退到 evidence_match 那一档）。
$PY - "$W/queryset_60.json" "$R/stage1.json" "$W/answers_good.json" "$W/answers_bad.json" <<'PYEOF'
import json, sys
qs = json.load(open(sys.argv[1], encoding="utf-8"))
st = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))["per_query"]}
good, bad = {}, {}
for q in qs["queries"]:
    got = st[q["id"]]["evidence_ids"]
    if q["expect"] == "none":
        good[q["id"]] = {"answer": "无证据。", "unanswerable": True, "cited_evidence_ids": []}
        bad[q["id"]] = {"answer": "你当时在看一份季度报告。", "unanswerable": False,
                        "cited_evidence_ids": [123]}
    else:
        rel = set(q.get("relevant") or [])
        cited = ([i for i in got if i in rel][:3] if rel
                 else (st[q["id"]].get("evidence_matched_ids") or [])[:3])
        good[q["id"]] = {"answer": q["answer"], "unanswerable": False,
                         "cited_evidence_ids": cited}
        bad[q["id"]] = {"answer": "没有找到相关内容。", "unanswerable": True,
                        "cited_evidence_ids": []}
json.dump(good, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump(bad, open(sys.argv[4], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
$PY "$E/eval_stage2.py" --queryset "$W/queryset_60.json" --stage1 "$R/stage1.json" \
  --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" --outdir "$R/stage2_good" \
  --provider file --answers "$W/answers_good.json" \
  --out-json "$R/stage2_selftest_good.json" --out-md "$R/stage2_selftest_good.md" \
  > "$R/stage2_selftest_good_stdout.json"
$PY "$E/eval_stage2.py" --queryset "$W/queryset_60.json" --stage1 "$R/stage1.json" \
  --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" --outdir "$R/stage2_bad" \
  --provider file --answers "$W/answers_bad.json" \
  --out-json "$R/stage2_selftest_bad.json" --out-md "$R/stage2_selftest_bad.md" \
  > "$R/stage2_selftest_bad_stdout.json"

# 7b. 真实题（relevant 留空）那条路径：第一阶段按「返回的证据满不满足期望证据」判，
#     第二阶段跟着用那批 id 判「引用有没有效」。拿 queryset.example.json 当真实题样本，
#     构造两套答案：好答案引「满足期望证据」的 id；坏答案引「喂过但不满足期望证据」的 id
#     （没有这种 id 时退而引一个根本不存在的 id）。坏答案必须一题都不过——
#     第一次验收指出的「relevant 为空时引什么都算有效」就是在这里回归。
# 也要 --include-holdout：这份真实题样本只有 4 道，下面第 7b 步要给**每一道**造答案
$PY "$E/eval_stage1.py" --include-holdout --queryset "$E/queryset.example.json" --bin "$BIN" \
  --dir "$W/db" --key-file "$W/db.key" --check-corpus \
  --batch-file "$W/stage1_example_batch.json" \
  --out-json "$R/stage1_example.json" --out-md "$R/stage1_example.md" \
  > "$R/stage1_example_stdout.json"
$PY - "$E/queryset.example.json" "$R/stage1_example.json" \
     "$W/answers_real_good.json" "$W/answers_real_bad.json" "$R/citation_basis_probe.json" <<'PYEOF'
import json, sys
FAKE = 999999999                      # 库里不存在、也没喂给它看过的 id
qs = json.load(open(sys.argv[1], encoding="utf-8"))
st = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))["per_query"]}
good, bad, probe = {}, {}, []
for q in qs["queries"]:
    r = st[q["id"]]
    if q["expect"] == "none":
        good[q["id"]] = {"answer": "无证据。", "unanswerable": True, "cited_evidence_ids": []}
        bad[q["id"]] = {"answer": "你当时看过这件事。", "unanswerable": False,
                        "cited_evidence_ids": [FAKE]}
        continue
    matched = list(r.get("evidence_matched_ids") or [])
    packed = list(r["evidence_ids"])[:5]              # eval_stage2.py 默认 --evidence-top-k 5
    unmatched = [i for i in packed if i not in matched]
    bad_cited = (unmatched[:2] if matched else []) or [FAKE]
    ans = "、".join(q["answer_check"]["must_include"]) + "（自检构造的答案）"
    good[q["id"]] = {"answer": ans, "unanswerable": False,
                     "cited_evidence_ids": (matched or packed)[:3]}
    bad[q["id"]] = {"answer": ans, "unanswerable": False, "cited_evidence_ids": bad_cited}
    probe.append({"id": q["id"], "matched": len(matched), "packed": len(packed),
                  "bad_cited": bad_cited,
                  "bad_kind": "喂过但不满足期望证据" if bad_cited != [FAKE] else "根本不存在的 id"})
json.dump(good, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump(bad, open(sys.argv[4], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump({"queries": probe}, open(sys.argv[5], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
for V in good bad; do
  $PY "$E/eval_stage2.py" --queryset "$E/queryset.example.json" \
    --stage1 "$R/stage1_example.json" --bin "$BIN" --dir "$W/db" --key-file "$W/db.key" \
    --outdir "$R/stage2_real_$V" --provider file --answers "$W/answers_real_$V.json" \
    --out-json "$R/stage2_real_$V.json" --out-md "$R/stage2_real_$V.md" \
    > "$R/stage2_real_${V}_stdout.json"
done
$PY - "$R/stage2_real_good.json" "$R/stage2_real_bad.json" "$R/citation_basis_probe.json" \
     "$R/citation_basis_check.json" <<'PYEOF'
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
p = json.load(open(sys.argv[3], encoding="utf-8"))
res = {
    "good_passed": g["passed"], "good_scored": g["scored"],
    "good_valid_citation_rate": g["valid_citation_rate"],
    "good_basis": g["citation_basis_counts"],
    "bad_passed": b["passed"], "bad_hit_passed": b["hit_passed"],
    "bad_valid_citation_rate": b["valid_citation_rate"],
    "bad_citations_total": sum(r.get("score_citation_total") or 0 for r in b["per_query"]),
    "bad_cited_kinds": [x["bad_kind"] for x in p["queries"]],
    "note": "好答案引「满足期望证据」的 id 应当全过；坏答案引「喂过但不满足」或不存在的 id"
            "应当一题都不过，有效引用率 0.0",
}
res["ok"] = (res["good_passed"] == res["good_scored"]
             and res["good_valid_citation_rate"] == 1.0
             and res["bad_passed"] == 0
             and res["bad_valid_citation_rate"] == 0.0)
json.dump(res, open(sys.argv[4], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False))
if not res["ok"]:
    raise SystemExit("真实题的引用判据自检没过：好答案该全过、坏答案该一题都不过")
PYEOF

echo "== 8. 月报（来源一：brosis-store stats）=="
$PY "$E/monthly_report.py" --stats "$R/stats.json" --ledger-days "$R/ledger_days.json" \
  --thumbs-dir "$W/db/brosis.db.thumbs" \
  --out-md "$R/monthly_report.md" --out-json "$R/monthly_report.json" \
  > "$R/monthly_report_stdout.json"

echo "== 9. 月报（来源二：app 导出的 stats-<日期>.json，验证解析容错）=="
# app 的「导出存储统计…」菜单（app/README.md 8.8）写的是 `store` 对象 + `dbstat` 数组，
# 字段名与 CLI 相同但嵌套不同、明细数组换了名字，而且**不含库内时间跨度**。
# 这里按那个形状造一份，字节数来自上面那份真 stats，只用来证明「换个结构照样解析」。
$PY - "$R/stats.json" "$W/stats-2026-09-07.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
keys = ["page_size", "page_count", "freelist_pages", "db_file_bytes", "wal_bytes", "shm_bytes",
        "content_bytes", "index_bytes", "fts_bytes", "metadata_bytes", "free_bytes",
        "text_payload_bytes", "observations", "live_observations", "tombstoned_observations",
        "text_versions", "occurrences", "fts_rows", "apps", "deletions"]
app = {
    "schema_version": 1, "generated_by": "0.0.0-mock", "device_id": "mock-device",
    "exported_at": "2026-09-07T00:00:00Z", "exported_at_ms": 1788739200000,
    "store": {k: s[k] for k in keys},
    "dbstat": s["detail"],
}
json.dump(app, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
# app 导出里没有 first / last 观察时间，所以跨度要另外给（--span-days 或 --ledger-days）。
# 缩略图与模型资产也不在导出里，用 --thumbs-bytes / --models-bytes 演示怎么补进来。
$PY "$E/monthly_report.py" --stats "$W/stats-2026-09-07.json" \
  --ledger-days "$R/ledger_days.json" \
  --thumbs-bytes 12582912 --models-bytes 3710852301 \
  --out-md "$R/monthly_report_appexport.md" --out-json "$R/monthly_report_appexport.json" \
  > "$R/monthly_report_appexport_stdout.json"

echo "== 10. 汇总 =="
$PY - "$R" <<'PYEOF'
import json, os, sys
R = sys.argv[1]
def j(n): return json.load(open(os.path.join(R, n), encoding="utf-8"))
s1, mut, s2 = j("stage1.json"), j("mutation_check.json"), j("stage2.json")
good, bad = j("stage2_selftest_good.json"), j("stage2_selftest_bad.json")
mr, dels = j("monthly_report.json"), j("deletions.json")
det = j("determinism.json")
print(json.dumps({
    "stage1": {"queries": s1["queries"], "recall@10": s1["overall"]["recall@10"],
               "precision@10": s1["overall"]["precision@10"], "mrr@10": s1["overall"]["mrr@10"],
               "buckets": s1["buckets"], "batch_elapsed_s": s1["batch_elapsed_s"],
               "batch_vs_single_mismatch": s1["batch_vs_single_mismatch"]},
    "queryset_deterministic": det["identical"],
    "deletions_reconciled": dels["all_match"],
    "mutation_check": mut["all_match"],
    "stage2": {"provider": s2["provider"], "graded": s2["graded"],
               "prompt_bytes_total": s2["evidence_packed"]["prompt_bytes_total"],
               "egress_bytes": s2["egress_bytes"]},
    "stage2_selftest": {"good_passed": good["passed"], "bad_passed": bad["passed"],
                        "scored": good["scored"]},
    "citation_basis_check": j("citation_basis_check.json")["ok"],
    "monthly": {"span_days": mr["span_days"],
                "gib_per_month": mr["growth"]["permanent_per_month_gib"],
                "meets_target": mr["growth"]["meets_target"],
                "dedup_rate": mr["ratios"]["dedup_rate"]},
}, ensure_ascii=False, indent=1))
PYEOF
echo "原始输出都在 $R"
