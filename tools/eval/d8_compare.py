#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""D8 裁决：同一套题上比「FTS-only」与「混合检索」的 Recall@10 / MRR@10（计划 D8 / 3.4 / 4.3）。

两个跑法用的是**同一条产品检索路径**（`brosis-store search-batch`），差别只有一个开关：

| 跑法 | 命令 | 走哪几条通道 |
|---|---|---|
| `fts` | `search-batch --file q.json` | 精确字段 + 1–2 字扫描 + FTS（`RetrievalOptions.vectorsEnabled` 默认 false） |
| `hybrid` | `search-batch --file q.json --vectors --query-vectors v.json` | 上面三条 + 向量，按加权 RRF 合并 |

查询向量由 `brosis-embed queries` 事先算好（core 不加载模型），所以这里不需要 mlx。

指标口径与 `eval_stage1.py` 一致：
  * `Recall@10 = |前 10 条 ∩ 真值| / min(10, |真值|)`
  * `Precision@10 = |前 10 条 ∩ 真值| / min(10, 返回条数)`
  * `MRR@10 = 1 / 第一条命中的名次`（前 10 条里没有命中就是 0）
  * 不可答题（`expect == "none"`）只看有没有返回，返回了就算**负例误报**

    PYTHONDONTWRITEBYTECODE=1 python3 d8_compare.py \\
        --queryset <qs.json> --bin <brosis-store> --dir <库> --key-file <密钥> \\
        --vectors <查询向量表.json> --out <结果.json> --label 改写题
"""

import argparse
import json
import os
import subprocess
import sys
import time

K = 10


def run_batch(binary, directory, key_file, batch_file, out_file, vectors=None, extra=None):
    """跑一次 search-batch，返回 {题 id: 结果行}。"""
    cmd = [binary, "search-batch", "--dir", directory, "--key-file", key_file,
           "--file", batch_file, "--out", out_file, "--tz", "UTC"]
    if vectors:
        cmd += ["--vectors", "--query-vectors", vectors]
    if extra:
        cmd += extra
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("search-batch 失败：%s\n%s" % (" ".join(cmd[:2]), proc.stderr.strip()))
    wall = time.time() - t0
    data = json.load(open(out_file, encoding="utf-8"))
    return {row["id"]: row for row in data["results"]}, wall


def score(queries, results):
    """按题算指标，并按类 / 按改写类别分组汇总。"""
    per_query = []
    for q in queries:
        row = results.get(q["id"], {})
        got = list(row.get("evidence_ids") or [])[:K]
        relevant = set(q.get("relevant") or [])
        answerable = q["expect"] == "hit"
        hit = [i for i in got if i in relevant]
        denominator = min(K, len(relevant)) if relevant else 0
        recall = (len(hit) / denominator) if denominator else None
        precision = (len(hit) / min(K, len(got))) if got else (1.0 if not answerable else 0.0)
        rr = 0.0
        for rank, i in enumerate(got, start=1):
            if i in relevant:
                rr = 1.0 / rank
                break
        per_query.append({
            "id": q["id"],
            "class": q.get("class"),
            "rewrite_kind": q.get("rewrite_kind"),
            "source_id": q.get("source_id"),
            "expect": q["expect"],
            "relevant_count": len(relevant),
            "returned": len(got),
            "hits_in_top_k": len(hit),
            "recall_at_k": recall,
            "precision_at_k": precision,
            "mrr_at_k": rr,
            "channels": row.get("channels"),
            "fusion": row.get("fusion"),
            "vectors_unavailable": row.get("vectors_unavailable"),
            "vector_unavailable_reason": row.get("vector_unavailable_reason"),
            "vector_candidates": row.get("vector_candidates"),
            "vector_best_distance": row.get("vector_best_distance"),
            "elapsed_ms": row.get("elapsed_ms"),
            "false_positive": (not answerable) and len(got) > 0,
        })

    def mean(values):
        values = [v for v in values if v is not None]
        return round(sum(values) / len(values), 4) if values else None

    answerable = [r for r in per_query if r["expect"] == "hit"]
    summary = {
        "queries": len(per_query),
        "answerable": len(answerable),
        "recall_at_10": mean([r["recall_at_k"] for r in answerable]),
        "precision_at_10": mean([r["precision_at_k"] for r in answerable]),
        "mrr_at_10": mean([r["mrr_at_k"] for r in answerable]),
        "answered_at_all": sum(1 for r in answerable if r["hits_in_top_k"] > 0),
        "false_positives": sum(1 for r in per_query if r["false_positive"]),
        "p50_elapsed_ms": None,
        "p95_elapsed_ms": None,
    }
    times = sorted(r["elapsed_ms"] for r in per_query if r["elapsed_ms"] is not None)
    if times:
        summary["p50_elapsed_ms"] = round(times[len(times) // 2], 3)
        summary["p95_elapsed_ms"] = round(times[min(len(times) - 1, int(len(times) * 0.95))], 3)

    by_class, by_kind = {}, {}
    for bucket, key in ((by_class, "class"), (by_kind, "rewrite_kind")):
        for r in answerable:
            name = r.get(key)
            if name is None:
                continue
            bucket.setdefault(name, []).append(r)
    summary["by_class"] = {
        name: {"n": len(rows), "recall_at_10": mean([r["recall_at_k"] for r in rows]),
               "mrr_at_10": mean([r["mrr_at_k"] for r in rows])}
        for name, rows in sorted(by_class.items())
    }
    summary["by_rewrite_kind"] = {
        name: {"n": len(rows), "recall_at_10": mean([r["recall_at_k"] for r in rows]),
               "mrr_at_10": mean([r["mrr_at_k"] for r in rows])}
        for name, rows in sorted(by_kind.items())
    }
    return summary, per_query


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--queryset", required=True)
    parser.add_argument("--bin", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--vectors", required=True, help="brosis-embed queries 出的查询向量表")
    parser.add_argument("--out", required=True)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--label", default="")
    parser.add_argument("--vector-max-distance", default=None,
                        help="覆盖 RetrievalOptions.vectorMaxDistance（阈值扫描用）")
    parser.add_argument("--vector-weight", default=None,
                        help="覆盖 RetrievalOptions.vectorWeight")
    args = parser.parse_args()
    extra = []
    if args.vector_max_distance is not None:
        extra += ["--vector-max-distance", str(args.vector_max_distance)]
    if args.vector_weight is not None:
        extra += ["--vector-weight", str(args.vector_weight)]

    queryset = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    queries = queryset["queries"]
    workdir = os.path.expanduser(args.workdir or os.path.dirname(os.path.expanduser(args.out)))
    os.makedirs(workdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(os.path.expanduser(args.out)))[0]

    batch_file = os.path.join(workdir, stem + "_batch.json")
    json.dump([{"id": q["id"], "q": q["search"]["q"], "start": q["search"]["start"],
                "end": q["search"]["end"], "app": q["search"]["app"],
                "limit": max(K, q["search"].get("limit") or K)}
               for q in queries],
              open(batch_file, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    fts_raw, fts_wall = run_batch(args.bin, args.dir, args.key_file, batch_file,
                                  os.path.join(workdir, stem + "_fts.json"))
    hybrid_raw, hybrid_wall = run_batch(args.bin, args.dir, args.key_file, batch_file,
                                        os.path.join(workdir, stem + "_hybrid.json"),
                                        vectors=os.path.expanduser(args.vectors),
                                        extra=extra or None)

    fts_summary, fts_rows = score(queries, fts_raw)
    hybrid_summary, hybrid_rows = score(queries, hybrid_raw)

    def delta(key):
        a, b = fts_summary.get(key), hybrid_summary.get(key)
        if a is None or b is None:
            return None
        return round(b - a, 4)

    # 逐题差异：谁被向量救回来了、谁被挤下去了
    fts_by_id = {r["id"]: r for r in fts_rows}
    improved, regressed = [], []
    for row in hybrid_rows:
        base = fts_by_id.get(row["id"])
        if base is None or row["recall_at_k"] is None or base["recall_at_k"] is None:
            continue
        if row["recall_at_k"] > base["recall_at_k"] + 1e-9:
            improved.append({"id": row["id"], "from": base["recall_at_k"],
                             "to": row["recall_at_k"],
                             "rewrite_kind": row.get("rewrite_kind"),
                             "vector_best_distance": row.get("vector_best_distance")})
        elif row["recall_at_k"] < base["recall_at_k"] - 1e-9:
            regressed.append({"id": row["id"], "from": base["recall_at_k"],
                              "to": row["recall_at_k"],
                              "rewrite_kind": row.get("rewrite_kind")})

    out = {
        "label": args.label or os.path.basename(os.path.expanduser(args.queryset)),
        "queryset": os.path.basename(os.path.expanduser(args.queryset)),
        "queryset_count": len(queries),
        "k": K,
        "hybrid_store_args": extra,
        "metric_note": ("Recall@10 = |前 10 ∩ 真值| / min(10, |真值|)；"
                        "MRR@10 = 1/第一条命中的名次；口径与 eval_stage1.py 一致"),
        "fts_only": fts_summary,
        "hybrid": hybrid_summary,
        "delta": {
            "recall_at_10": delta("recall_at_10"),
            "recall_at_10_points": (None if delta("recall_at_10") is None
                                    else round(delta("recall_at_10") * 100, 2)),
            "mrr_at_10": delta("mrr_at_10"),
            "precision_at_10": delta("precision_at_10"),
            "answered_at_all": (hybrid_summary["answered_at_all"]
                                - fts_summary["answered_at_all"]),
            "false_positives": (hybrid_summary["false_positives"]
                                - fts_summary["false_positives"]),
        },
        "improved_queries": sorted(improved, key=lambda r: r["id"]),
        "regressed_queries": sorted(regressed, key=lambda r: r["id"]),
        "wall_seconds": {"fts_only": round(fts_wall, 3), "hybrid": round(hybrid_wall, 3)},
        "per_query": {"fts_only": fts_rows, "hybrid": hybrid_rows},
    }
    path = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    json.dump(out, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    brief = {k: out[k] for k in ("label", "queryset_count", "fts_only", "hybrid", "delta")}
    brief["fts_only"] = {k: v for k, v in brief["fts_only"].items() if not isinstance(v, dict)}
    brief["hybrid"] = {k: v for k, v in brief["hybrid"].items() if not isinstance(v, dict)}
    brief["improved"] = len(improved)
    brief["regressed"] = len(regressed)
    print(json.dumps(brief, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main())
