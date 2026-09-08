#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向量距离阈值扫描：`vectorMaxDistance` 该取多少（M2 c / T11，D8 裁决的配套数据）。

背景：向量通道是相似度语义，**它对"库里根本没有这个内容"的查询也会给出最近邻**。
原 60 题里有 10 道不可答题（6 道负例 + 4 道已删除），`docs/查询集草稿.md` 规定
「编造一次即失败」，所以必须有一个距离闸把这类命中挡掉。
但闸门收紧会同时挡掉改写题的真命中——这两条曲线的取舍就是这个脚本要量的东西。

对每个阈值跑两套题，各报一个数：
  * 改写题（47 道全部可答）：**Recall@10 / MRR@10**，越高越好；
  * 原 60 题：**负例误报数**（10 道不可答题里返回了证据的），越低越好；顺带核对可答题不退化。

    PYTHONDONTWRITEBYTECODE=1 python3 d8_threshold_sweep.py \\
        --bin <brosis-store> --dir <库> --key-file <密钥> \\
        --queryset-60 <qs60.json> --vectors-60 <qvec60.json> \\
        --queryset-paraphrase <qsp.json> --vectors-paraphrase <qvecp.json> \\
        --out <sweep.json> [--thresholds 0.30,0.35,0.40,0.45,0.50,0.55,0.60,2.0]
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def run_compare(args, queryset, vectors, out, label, threshold):
    cmd = [sys.executable, os.path.join(HERE, "d8_compare.py"),
           "--queryset", queryset, "--bin", args.bin, "--dir", args.dir,
           "--key-file", args.key_file, "--vectors", vectors,
           "--out", out, "--label", label,
           "--vector-max-distance", str(threshold)]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise SystemExit("d8_compare 失败（阈值 %s）：%s" % (threshold, proc.stderr.strip()))
    with open(out, encoding="utf-8") as fh:
        return json.load(fh)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bin", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--queryset-60", required=True)
    parser.add_argument("--vectors-60", required=True)
    parser.add_argument("--queryset-paraphrase", required=True)
    parser.add_argument("--vectors-paraphrase", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--thresholds", default="0.30,0.35,0.40,0.45,0.50,0.55,0.60,2.00")
    args = parser.parse_args()

    thresholds = [float(x) for x in args.thresholds.split(",")]
    rows = []
    with tempfile.TemporaryDirectory(prefix="brosis-d8-sweep-") as tmp:
        for threshold in thresholds:
            tag = ("%.2f" % threshold).replace(".", "p")
            para = run_compare(args, os.path.expanduser(args.queryset_paraphrase),
                               os.path.expanduser(args.vectors_paraphrase),
                               os.path.join(tmp, "para_%s.json" % tag),
                               "改写题 @%.2f" % threshold, threshold)
            orig = run_compare(args, os.path.expanduser(args.queryset_60),
                               os.path.expanduser(args.vectors_60),
                               os.path.join(tmp, "orig_%s.json" % tag),
                               "原 60 题 @%.2f" % threshold, threshold)
            rows.append({
                "vector_max_distance": threshold,
                "paraphrase_recall_at_10": para["hybrid"]["recall_at_10"],
                "paraphrase_mrr_at_10": para["hybrid"]["mrr_at_10"],
                "paraphrase_answered": para["hybrid"]["answered_at_all"],
                "paraphrase_total": para["hybrid"]["answerable"],
                "original60_recall_at_10": orig["hybrid"]["recall_at_10"],
                "original60_mrr_at_10": orig["hybrid"]["mrr_at_10"],
                "original60_false_positives": orig["hybrid"]["false_positives"],
                "original60_regressed": len(orig["regressed_queries"]),
            })
            print(json.dumps(rows[-1], ensure_ascii=False))

    baseline_para = run_compare(args, os.path.expanduser(args.queryset_paraphrase),
                                os.path.expanduser(args.vectors_paraphrase),
                                os.path.join(os.path.dirname(os.path.expanduser(args.out)),
                                             "sweep_baseline_paraphrase.json"),
                                "改写题（FTS-only 基线）", 0)
    out = {
        "note": ("阈值是 vec0 的余弦距离上界（0 = 完全一致、1 = 正交）。"
                 "2.00 = 不设闸。改写题 47 道全部可答；原 60 题里 10 道不可答，"
                 "「负例误报」= 这 10 道里返回了证据的题数（草稿规定编造一次即失败）。"),
        "fts_only_baseline": {
            "paraphrase_recall_at_10": baseline_para["fts_only"]["recall_at_10"],
            "paraphrase_mrr_at_10": baseline_para["fts_only"]["mrr_at_10"],
            "paraphrase_answered": baseline_para["fts_only"]["answered_at_all"],
            "original60_false_positives": 0,
        },
        "rows": rows,
    }
    path = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(json.dumps(out["fts_only_baseline"], ensure_ascii=False))


if __name__ == "__main__":
    sys.exit(main())
