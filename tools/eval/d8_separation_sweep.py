#!/usr/bin/env python3
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
"""间隔判据扫描（e 批 ⑧a）。

固定绝对阈值，扫 `vectorMinSeparation`：候选距离的中位数要比最好的那条大出多少，
向量通道才算数。判据针对的是 `vectorMaxDistance` 不随索引规模自适应——块越多，
「库里根本没有的内容」的最近邻越近，迟早挤进任何固定阈值。

看两列就够：改写题（可回答）的 Recall@10 掉多少，原 60 题的负例误报少几条。

**2026-09-09 实测结论：这个判据不成立**（误报卡在 2，直到召回腰斩才掉到 1），
所以 `vectorMinSeparation` 默认 0。这个脚本留作量具：换语料（真实查询题 D12）
或换模型（4B / 8B）时可以再量一次。

    python3 tools/eval/d8_separation_sweep.py --bin <brosis-store> --dir <库> --key-file <钥> \\
        --queryset-60 <qs60> --vectors-60 <qvec60> \\
        --queryset-paraphrase <qsp> --vectors-paraphrase <qvecp> --out <结果.json>
"""
import argparse
import sys

from d8_sweep_common import add_common_args, sweep

SEPARATIONS = [0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12]


def main():
    parser = argparse.ArgumentParser()
    add_common_args(parser)
    parser.add_argument("--vector-max-distance", default="0.50")
    args = parser.parse_args()
    sweep(args, "vector-min-separation", "vector_min_separation", SEPARATIONS,
          extra_out={"vector_max_distance": args.vector_max_distance})
    return 0


if __name__ == "__main__":
    sys.exit(main())
