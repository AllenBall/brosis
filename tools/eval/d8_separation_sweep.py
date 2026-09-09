#!/usr/bin/env python3
"""间隔判据扫描（e 批 ⑧a）。

固定绝对阈值，扫 `vectorMinSeparation`：候选距离的**中位数**要比最好的那条大出多少，
向量通道才算数。判据针对的是 `vectorMaxDistance` 的已知毛病——它不随索引规模自适应，
块越多，「库里根本没有的内容」的最近邻越近，迟早挤进任何固定阈值。

看两列就够：
  - 改写题（可回答）：Recall@10 掉了多少 —— 判据太狠会把真答案也挡掉
  - 原 60 题：负例误报少了几条 —— 这才是它要解决的问题

    python3 tools/eval/d8_separation_sweep.py --bin <brosis-store> --dir <库> --key-file <钥> \\
        --queryset-60 <qs60> --vectors-60 <qvec60> \\
        --queryset-paraphrase <qsp> --vectors-paraphrase <qvecp> --out <结果.json>
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEPARATIONS = [0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12]


def run(args, queryset, vectors, separation, tag):
    out = os.path.join(os.path.dirname(os.path.abspath(args.out)), "sep_%s_%s.json" % (tag, separation))
    cmd = [sys.executable, os.path.join(HERE, "d8_compare.py"),
           "--queryset", queryset, "--bin", args.bin, "--dir", args.dir,
           "--key-file", args.key_file, "--vectors", vectors,
           "--out", out, "--label", "sep=%s" % separation,
           "--vector-max-distance", str(args.vector_max_distance),
           "--vector-min-separation", str(separation)]
    subprocess.run(cmd, check=True, capture_output=True)
    with open(out, encoding="utf-8") as handle:
        return json.load(handle)


def main():
    parser = argparse.ArgumentParser()
    for name in ["bin", "dir", "key-file", "queryset-60", "vectors-60",
                 "queryset-paraphrase", "vectors-paraphrase", "out"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--vector-max-distance", default="0.50")
    args = parser.parse_args()

    rows = []
    for separation in SEPARATIONS:
        para = run(args, args.queryset_paraphrase, args.vectors_paraphrase, separation, "para")
        orig = run(args, args.queryset_60, args.vectors_60, separation, "orig")
        row = {
            "vector_min_separation": separation,
            "paraphrase_recall_at_10": para["hybrid"]["recall_at_10"],
            "paraphrase_mrr_at_10": para["hybrid"]["mrr_at_10"],
            "paraphrase_answered": para["hybrid"]["answered_at_all"],
            "original60_recall_at_10": orig["hybrid"]["recall_at_10"],
            "original60_mrr_at_10": orig["hybrid"]["mrr_at_10"],
            "original60_false_positives": orig["hybrid"]["false_positives"],
            "original60_regressed": len(orig["regressed_queries"]),
        }
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False))

    with open(os.path.expanduser(args.out), "w", encoding="utf-8") as handle:
        json.dump({"vector_max_distance": args.vector_max_distance, "rows": rows},
                  handle, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
