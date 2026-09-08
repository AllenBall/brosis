#!/bin/sh
# brosis M2 c / T11：D8 裁决一键复现（计划 D8 / 3.4 / 4.3）。
#
# 建合成库 → 造 60 题 → 派生改写题 → 分块 → 用**真实模型**建向量索引 →
# 在同一条产品检索路径上跑「FTS-only」与「混合检索」两遍 → 出 Recall@10 / MRR@10 与提升幅度。
#
#   sh tools/eval/run_d8.sh
#   SCRATCH=~/Library/Caches/brosis-build/verify-d8 sh tools/eval/run_d8.sh   # 验收者用自己的
#   SKIP_BUILD=1 sh tools/eval/run_d8.sh                                     # 复用已有的二进制
#   SKIP_CORPUS=1 sh tools/eval/run_d8.sh                                    # 复用已有的库与索引
#
# **语料规模的选择（必读）**：默认 `--days 30 --per-day 2880 --avg-chars 500`，
# 不是 run_all.sh 的 `--per-day 8640 --avg-chars 1500`。理由是本机（M4 Air 16 GiB、无风扇）
# 的嵌入吞吐：满档语料切出 310,411 块，冷机探针 11.4 块/s（1,849 token/s，与 D27 给 M1 排期用的
# 「降频后约 1,850 token/s」一致），但整轮跑下来全程降频、实测只有 7.29 块/s，
# 建完整索引要 7.6–11.8 小时。缩到 2880 / 500 之后是 46,545 块、**实测 1 小时 32 分**，
# 一次会话跑得完。**两条通道跑的是同一个库、同一套题**，
# 所以比较仍然成立；绝对值会比满档语料乐观（干扰项少了约 3 倍），结果文件里写明了这一点。
#
# 需要：Xcode（core 与 app 都是 SwiftPM 包）+ Metal Toolchain（app 要现编 mlx.metallib）
#      + 已安装的嵌入模型（D30 起默认 Qwen3-Embedding-4B-4bit-DWQ；
#        脚本会从 --model-source 目录导入并重新校验 sha256）。
set -e

PROJECT="${PROJECT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/m2-vectors}"
CORE_SCRATCH="${CORE_SCRATCH:-${SCRATCH%/}-core}"
APP_SCRATCH="${APP_SCRATCH:-${SCRATCH%/}-app}"
W="$SCRATCH/d8s"
R="$W/results"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DAYS="${DAYS:-30}"
PER_DAY="${PER_DAY:-2880}"
AVG_CHARS="${AVG_CHARS:-500}"
SEED="${SEED:-20260907}"
MODEL_ID="${MODEL_ID:-Qwen3-Embedding-4B-4bit-DWQ}"   # D30：多尺寸，用 MODEL_ID 换
MODEL_SOURCE="${MODEL_SOURCE:-$HOME/Library/Application Support/brosis-m0/models/$MODEL_ID}"
E="$PROJECT/tools/eval"
PY="env PYTHONDONTWRITEBYTECODE=1 python3"

mkdir -p "$R" "$W"

echo "== 0. 构建 release =="
if [ -z "${SKIP_BUILD:-}" ]; then
  DEVELOPER_DIR=$DEV swift build --package-path "$PROJECT/core" -c release \
    --scratch-path "$CORE_SCRATCH" > "$R/build_core.log" 2>&1
  DEVELOPER_DIR=$DEV swift build --package-path "$PROJECT/app" -c release \
    --scratch-path "$APP_SCRATCH" --product brosis-embed > "$R/build_embed.log" 2>&1
  # SwiftPM 命令行不编 .metal，要自己编一份 mlx.metallib 放在可执行文件旁边
  SCRATCH="$APP_SCRATCH" bash "$PROJECT/app/Support/build_metallib.sh" \
    "$APP_SCRATCH/mlx.metallib" > "$R/build_metallib.log" 2>&1
fi
STORE="$(DEVELOPER_DIR=$DEV swift build --package-path "$PROJECT/core" -c release \
          --scratch-path "$CORE_SCRATCH" --show-bin-path)/brosis-store"
EMBED_DIR="$(DEVELOPER_DIR=$DEV swift build --package-path "$PROJECT/app" -c release \
              --scratch-path "$APP_SCRATCH" --show-bin-path)"
cp -f "$APP_SCRATCH/mlx.metallib" "$EMBED_DIR/mlx.metallib"
EMBED="$EMBED_DIR/brosis-embed"
"$EMBED" env > "$R/embed_env.json"
$PY "$PROJECT/app/Support/check_embed_env.py" "$R/embed_env.json"

if [ -z "${SKIP_CORPUS:-}" ]; then
  echo "== 1. 生成 $DAYS 天合成流（per-day $PER_DAY、avg-chars $AVG_CHARS）并建库 =="
  rm -rf "$W/data" "$W/data.key" "$W/synth.jsonl" "$W/queries.json"
  /usr/bin/time -l $PY "$PROJECT/tools/proto/gen_synth_m1.py" gen \
    --out "$W/synth.jsonl" --queries "$W/queries.json" \
    --days "$DAYS" --per-day "$PER_DAY" --avg-chars "$AVG_CHARS" --seed "$SEED" \
    > "$R/gen_synth.json" 2> "$R/gen_synth.time"
  mkdir -p "$W/data"
  "$STORE" init --dir "$W/data" --key-file "$W/data.key" > "$R/init.json"
  /usr/bin/time -l "$STORE" import-jsonl --dir "$W/data" --key-file "$W/data.key" \
    --file "$W/synth.jsonl" --batch 500 > "$R/import.json" 2> "$R/import.time"
  "$STORE" maintenance --dir "$W/data" --key-file "$W/data.key" > "$R/maintenance_1.json"

  echo "== 2. 造 60 题查询集 + 执行删除 =="
  $PY "$E/make_synthetic_queryset.py" gen \
    --jsonl "$W/synth.jsonl" --corpus "$W/queries.json" \
    --out "$W/queryset_60.json" --seed "$SEED" > "$R/queryset_gen.json"
  $PY "$E/make_synthetic_queryset.py" apply-deletions \
    --queryset "$W/queryset_60.json" --bin "$STORE" \
    --dir "$W/data" --key-file "$W/data.key" --out "$R/deletions.json" > /dev/null
  "$STORE" maintenance --dir "$W/data" --key-file "$W/data.key" > "$R/maintenance_2.json"
  "$STORE" stats --dir "$W/data" --key-file "$W/data.key" --detail > "$R/stats_before_vectors.json"

  echo "== 3. 派生改写题（≥ 40 题，标准答案与原题相同）=="
  $PY "$E/make_paraphrase_queryset.py" gen \
    --queryset "$W/queryset_60.json" --out "$W/queryset_paraphrase.json" \
    > "$R/paraphrase_gen.json"
  # 确定性：再生成一次必须逐字节相同
  $PY "$E/make_paraphrase_queryset.py" gen \
    --queryset "$W/queryset_60.json" --out "$W/queryset_paraphrase_again.json" > /dev/null
  cmp "$W/queryset_paraphrase.json" "$W/queryset_paraphrase_again.json" \
    && echo "改写题两次生成逐字节相同" | tee "$R/paraphrase_determinism.txt"

  echo "== 4. 导入嵌入模型（本地导入 + 重新校验 sha256）=="
  mkdir -p "$W/models"
  /usr/bin/time -l "$EMBED" models --models-dir "$W/models" --import --id "$MODEL_ID" \
    --from "$MODEL_SOURCE" > "$R/model_import.json" 2> "$R/model_import.time"
  "$EMBED" models --models-dir "$W/models" --list > "$R/model_list.json"

  echo "== 4b. 真实模型的自检（模型没装时会 skip）=="
  "$EMBED" models --models-dir "$W/models" --list > /dev/null
  "$EMBED" selftest --models-dir "$W/models" | tee "$R/embed_selftest.json"

  echo "== 5. 分块 + 建向量索引（真实模型；这一步最慢）=="
  "$STORE" vec-plan --dir "$W/data" --key-file "$W/data.key" > "$R/vec_plan.json"
  /usr/bin/time -l "$EMBED" embed --dir "$W/data" --key-file "$W/data.key" \
    --models-dir "$W/models" --batch 16 --out "$R/embed_full.json" \
    > "$R/embed_full_stdout.json" 2> "$R/embed_full.time"
fi
"$STORE" vec-status --dir "$W/data" --key-file "$W/data.key" > "$R/vec_status.json"
"$STORE" check --dir "$W/data" --key-file "$W/data.key" > "$R/check_after_vectors.json"
"$STORE" stats --dir "$W/data" --key-file "$W/data.key" --detail > "$R/stats_after_vectors.json"

echo "== 6. 算两套题的查询向量 =="
for set in 60 paraphrase; do
  case "$set" in
    60) QS="$W/queryset_60.json" ;;
    paraphrase) QS="$W/queryset_paraphrase.json" ;;
  esac
  $PY - "$QS" "$W/qbatch_$set.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
out = []
for q in d["queries"]:
    row = {"id": q["id"], "q": q["search"]["q"]}
    if q.get("embed_text"):
        row["embed_text"] = q["embed_text"]
    out.append(row)
json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
  /usr/bin/time -l "$EMBED" queries --file "$W/qbatch_$set.json" --out "$W/qvec_$set.json" \
    --models-dir "$W/models" --dir "$W/data" \
    > "$R/queries_$set.json" 2> "$R/queries_$set.time"
done

echo "== 7. FTS-only vs 混合检索 =="
$PY "$E/d8_compare.py" --queryset "$W/queryset_60.json" --bin "$STORE" \
  --dir "$W/data" --key-file "$W/data.key" --vectors "$W/qvec_60.json" \
  --out "$R/d8_original60.json" --label "原 60 题" | tee "$R/d8_original60_brief.json"
$PY "$E/d8_compare.py" --queryset "$W/queryset_paraphrase.json" --bin "$STORE" \
  --dir "$W/data" --key-file "$W/data.key" --vectors "$W/qvec_paraphrase.json" \
  --out "$R/d8_paraphrase.json" --label "改写题" | tee "$R/d8_paraphrase_brief.json"

echo "== 7b. 向量距离阈值扫描（vectorMaxDistance 该取多少）=="
$PY "$E/d8_threshold_sweep.py" --bin "$STORE" --dir "$W/data" --key-file "$W/data.key" \
  --queryset-60 "$W/queryset_60.json" --vectors-60 "$W/qvec_60.json" \
  --queryset-paraphrase "$W/queryset_paraphrase.json" --vectors-paraphrase "$W/qvec_paraphrase.json" \
  --out "$R/d8_threshold_sweep.json" | tee "$R/d8_threshold_sweep_brief.txt"

echo "== 8. 汇总 =="
$PY - "$R" <<'PYEOF'
import json, os, sys
R = sys.argv[1]
def load(name):
    with open(os.path.join(R, name), encoding="utf-8") as fh:
        return json.load(fh)
orig, para = load("d8_original60.json"), load("d8_paraphrase.json")
status = load("vec_status.json")
# SKIP_CORPUS=1 时这一步没跑过，允许缺
embed = load("embed_full.json") if os.path.exists(os.path.join(R, "embed_full.json")) else {}
summary = {
    "corpus": {k: load("stats_after_vectors.json").get(k)
               for k in ("observations", "live_observations", "text_versions",
                         "text_payload_bytes", "db_file_bytes")},
    "index": {k: status.get(k) for k in ("chunks", "embeddedChunks", "vectorRows",
                                         "dimension", "elementType", "model")},
    "embedding_run": {k: embed.get(k) for k in ("chunksEmbedded", "providerSeconds",
                                                "elapsedMS", "texts_per_second",
                                                "tokens_per_second", "peak_footprint_mib",
                                                "thermal_at_start", "thermal_at_end",
                                                "cache_limit_mib", "stopReason")},
    "original60": {"fts_recall": orig["fts_only"]["recall_at_10"],
                   "hybrid_recall": orig["hybrid"]["recall_at_10"],
                   "delta_points": orig["delta"]["recall_at_10_points"],
                   "fts_mrr": orig["fts_only"]["mrr_at_10"],
                   "hybrid_mrr": orig["hybrid"]["mrr_at_10"],
                   "false_positives": [orig["fts_only"]["false_positives"],
                                       orig["hybrid"]["false_positives"]],
                   "regressed": len(orig["regressed_queries"])},
    "paraphrase": {"fts_recall": para["fts_only"]["recall_at_10"],
                   "hybrid_recall": para["hybrid"]["recall_at_10"],
                   "delta_points": para["delta"]["recall_at_10_points"],
                   "fts_mrr": para["fts_only"]["mrr_at_10"],
                   "hybrid_mrr": para["hybrid"]["mrr_at_10"],
                   "answered_fts": para["fts_only"]["answered_at_all"],
                   "answered_hybrid": para["hybrid"]["answered_at_all"],
                   "by_rewrite_kind": para["hybrid"]["by_rewrite_kind"]},
}
d8 = (para["delta"]["recall_at_10_points"] or 0) >= 5 or (orig["delta"]["recall_at_10_points"] or 0) >= 5
summary["d8_threshold_met"] = d8
summary["d8_note"] = ("门槛：Recall@10 提升 ≥ 5 个百分点，或解决明确的高价值失败。"
                      "改写题就是那个高价值失败类。")
json.dump(summary, open(os.path.join(R, "d8_summary.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=1)
print(json.dumps(summary, ensure_ascii=False, indent=1))
PYEOF

echo
echo "全部产物在 $R"
