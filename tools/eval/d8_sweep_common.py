#!/usr/bin/env python3
"""两个 D8 扫描脚本的公共部分（阈值扫描 / 间隔判据扫描）。

它们只差两件事：扫哪个参数、扫哪些取值。其余——同样 8 个必填参数、同样调
`d8_compare.py`、同样从 `["hybrid"]` 里挑同一组指标、同样的打印与落盘——完全一致。
分成两份抄的代价不是行数，是 `d8_compare.py` 的输出结构从此有两个读者：
改一个键名要同时改两处，而漏改的那一处只会在跑评测时才炸。
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def add_common_args(parser):
    for name in ["bin", "dir", "key-file", "queryset-60", "vectors-60",
                 "queryset-paraphrase", "vectors-paraphrase", "out"]:
        parser.add_argument("--" + name, required=True)


def run_compare(args, queryset, vectors, flag, value, workdir, tag):
    """跑一遍 d8_compare.py，返回它的结果 JSON。

    中间产物写进临时目录（跑完自动删），不再堆在 --out 旁边。
    失败时把 stderr 原样带出来——`capture_output` 吞掉它的话，
    评测挂了只会看到一个 CalledProcessError，看不出为什么。
    """
    out = os.path.join(workdir, "%s_%s.json" % (tag, value))
    cmd = [sys.executable, os.path.join(HERE, "d8_compare.py"),
           "--queryset", queryset, "--bin", args.bin, "--dir", args.dir,
           "--key-file", args.key_file, "--vectors", vectors,
           "--out", out, "--label", "%s=%s" % (flag, value),
           "--" + flag, str(value)]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise SystemExit("d8_compare 失败（%s=%s）：\n%s" % (flag, value, result.stderr.strip()))
    with open(out, encoding="utf-8") as handle:
        return json.load(handle)


def row(value_key, value, para, orig):
    """两套题各挑同一组指标。改这里就等于同时改了两个扫描脚本的输出。"""
    return {
        value_key: value,
        "paraphrase_recall_at_10": para["hybrid"]["recall_at_10"],
        "paraphrase_mrr_at_10": para["hybrid"]["mrr_at_10"],
        "paraphrase_answered": para["hybrid"]["answered_at_all"],
        "original60_recall_at_10": orig["hybrid"]["recall_at_10"],
        "original60_mrr_at_10": orig["hybrid"]["mrr_at_10"],
        "original60_false_positives": orig["hybrid"]["false_positives"],
        "original60_regressed": len(orig["regressed_queries"]),
    }


def sweep(args, flag, value_key, values, extra_out=None):
    """按 `values` 逐个跑，打印每一行并落盘。"""
    rows = []
    with tempfile.TemporaryDirectory(prefix="d8-sweep-") as workdir:
        for value in values:
            para = run_compare(args, args.queryset_paraphrase, args.vectors_paraphrase,
                               flag, value, workdir, "para")
            orig = run_compare(args, args.queryset_60, args.vectors_60,
                               flag, value, workdir, "orig")
            item = row(value_key, value, para, orig)
            rows.append(item)
            print(json.dumps(item, ensure_ascii=False))
    payload = dict(extra_out or {})
    payload["rows"] = rows
    with open(os.path.expanduser(args.out), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
    return rows
