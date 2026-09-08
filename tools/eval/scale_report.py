#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 `scale_test.py` 的 JSON 变成结果文件里那几张表 + 3.4 分层目标的**逐项判定**。

分开成两个脚本的理由：压测要跑几十分钟、机器必须空闲，而"把数字排成表"是纯文本操作，
改表格式不该重跑压测。

    PYTHONDONTWRITEBYTECODE=1 python3 tools/eval/scale_report.py \\
        --scale <results>/scale_all.json --out-md <results>/scale_report.md

## 3.4 的分层目标（含 4.3.1 采纳的补充）落到每一条查询上

| 桶 | 目标 | 哪些查询 |
|---|---|---|
| 精确字段 | 热 p95 **< 10 ms** | `exact_host` / `exact_url_prefix` / `exact_path` / `exact_title` / `exact_path_miss` / `exact_evidence` |
| FTS | 热 p95 **< 10 ms** | `fts_*` |
| 1–2 字扫描（7 天窗口） | **≤ 150 ms** | `scan_*` |
| 1–2 字扫描 + 限应用 | **≤ 60 ms** | `scanapp_*` |
| 报表类 | **≤ 50 ms** | `exact_item_app`（`get_item(app)` 月度聚合）、`timeline_day`（`get_timeline` 7 天折算）、`ctx_24h`、`sessions_range` |
| 台账缓存命中 / `recent_activity` | **≤ 50 ms**（4.3.1 补充） | `ledger_day`、`week_ledger_cached`、`recent_30min` |
| `get_patterns` | **≤ 7 ms/天**（4.3.1 补充） | `patterns_7d`（49 ms）、`patterns_30d`（210 ms） |

判定一律用**热 p95**（3.4 的目标就是按热 p95 定的；冷是下界，且受 macOS 文件缓存影响，
本轮没有清系统缓存的权限）。`contended = true` 的档只报数字、**不判达标**。
"""

import argparse
import json
import os
import sys

MIB = 1 << 20
GIB = 1 << 30

# (桶名, 目标 ms, 是否严格小于, 属于这个桶的查询 id 前缀 / 全名)
TARGETS = [
    ("精确字段（热 p95 < 10 ms）", 10.0, True,
     ["exact_host", "exact_url_prefix", "exact_path", "exact_title",
      "exact_path_miss", "exact_evidence"]),
    ("FTS 通道（热 p95 < 10 ms）", 10.0, True, ["fts_"]),
    ("1–2 字扫描 7 天窗口（≤ 150 ms）", 150.0, False, ["scan_"]),
    ("1–2 字扫描 + 限应用（≤ 60 ms）", 60.0, False, ["scanapp_"]),
    ("报表类（≤ 50 ms）", 50.0, False,
     ["exact_item_app", "timeline_day", "ctx_24h", "sessions_range"]),
    ("台账缓存 / recent（≤ 50 ms，4.3.1 补充）", 50.0, False,
     ["ledger_day", "week_ledger_cached", "recent_30min"]),
    ("get_patterns 7 天（≤ 7 ms/天 = 49 ms）", 49.0, False, ["patterns_7d"]),
    ("get_patterns 30 天（≤ 7 ms/天 = 210 ms）", 210.0, False, ["patterns_30d"]),
]


def bucket_of(qid):
    # scanapp_ 要排在 scan_ 前面判：scanapp_ 也以 scan 开头
    for name, limit, strict, keys in TARGETS:
        for k in keys:
            if qid == k or (k.endswith("_") and qid.startswith(k) and
                            not (k == "scan_" and qid.startswith("scanapp_"))):
                return name, limit, strict
    return None, None, None


def rows_of(tier):
    """把 bench 的 per_query 与三条工具的结果拼成同一种形状。"""
    out = []
    for q in tier["latency"]["bench"]["per_query"]:
        out.append({"id": q["id"], "label": q.get("label", ""), "category": q["category"],
                    "rows": q.get("rows"), "cold_p50": q.get("cold_p50"),
                    "cold_p95": q.get("cold_p95"), "hot_p50": q.get("hot_p50"),
                    "hot_p95": q.get("hot_p95")})
    for t in tier["latency"]["tools"]:
        out.append({"id": t["id"], "label": t["cli"], "category": "M2 c 批的三个工具",
                    "rows": t.get("rows"), "cold_p50": t["cold_p50"], "cold_p95": t["cold_p95"],
                    "hot_p50": t["hot_p50"], "hot_p95": t["hot_p95"]})
    return out


def fmt(x, nd=2):
    return "—" if x is None else ("%.*f" % (nd, x))


def build(scale):
    tiers = scale["tiers"]
    lines = []
    L = lines.append

    L("### 三档一览\n")
    L("| 项 | " + " | ".join("%d 个月" % t["months"] for t in tiers) + " |")
    L("|---|" + "---:|" * len(tiers))

    def row(label, fn):
        L("| %s | %s |" % (label, " | ".join(fn(t) for t in tiers)))

    row("观察数", lambda t: "{:,}".format(t["build"]["observations_total"]))
    row("生成的 JSONL 合计（MiB）",
        lambda t: "%.1f" % (t["build"]["jsonl_bytes_total"] / MIB))
    row("生成耗时（s）", lambda t: "%.1f" % t["build"]["gen_s_total"])
    row("导入耗时合计（s）", lambda t: "%.1f" % t["build"]["import_s_total"])
    row("导入速率（条/s）",
        lambda t: "{:,.0f}".format(t["build"]["observations_total"] / t["build"]["import_s_total"]))
    row("导入峰值 footprint（MiB）",
        lambda t: "%.0f" % (t["build"]["import_peak_footprint_bytes_max"] / MIB))
    row("`maintenance` 耗时（s）", lambda t: "%.1f" % (t["build"]["maintenance_s"] or 0))
    row("`sessions --build` 耗时（s）", lambda t: "%.1f" % (t["build"]["sessions_build_s"] or 0))
    row("会话数", lambda t: ("{:,}".format(t["build"]["sessions"]["total"])
                            if t["build"]["sessions"].get("total") is not None else "未记"))
    row("目录磁盘峰值（GiB）", lambda t: "%.2f" % (t["build"]["dir_bytes_peak"] / GIB))
    row("文本版本 `text_versions`",
        lambda t: "{:,}".format(t["size"]["stats"].get("text_versions") or 0))
    row("出现记录 `occurrences`",
        lambda t: "{:,}".format(t["size"]["stats"].get("occurrences") or 0))
    row("去重率 = 1 − 版本/出现",
        lambda t: "%.4f" % (1 - (t["size"]["stats"].get("text_versions") or 0)
                            / max(1, t["size"]["stats"].get("occurrences") or 1)))
    row("全文索引行 `fts_rows`",
        lambda t: "{:,}".format(t["size"]["stats"].get("fts_rows") or 0))
    row("库文件（GiB）", lambda t: "%.3f" % (t["size"]["stats"]["db_file_bytes"] / GIB))
    row("库文件 / 1 个月档",
        lambda t: "%.2f×" % (t["size"]["stats"]["db_file_bytes"]
                             / tiers[0]["size"]["stats"]["db_file_bytes"]))
    row("每月折算（GiB/月）",
        lambda t: "%.3f" % (t["size"]["stats"]["db_file_bytes"] / GIB / t["months"]))
    L("")

    L("### 体积分项（`brosis-store stats --detail`，MiB = 2²⁰ / GiB = 2³⁰）\n")
    L("| 项 | " + " | ".join("%d 个月 MiB" % t["months"] for t in tiers)
      + " | " + " | ".join("%d 个月 占库" % t["months"] for t in tiers) + " |")
    L("|---|" + "---:|" * (2 * len(tiers)))
    names = [b["项"] for b in tiers[0]["size"]["breakdown"]]
    for name in names:
        vals, shares = [], []
        for t in tiers:
            b = next(x for x in t["size"]["breakdown"] if x["项"] == name)
            vals.append("%.1f" % b["MiB"])
            shares.append("—" if b["占库文件"] is None else "%.1f%%" % (100 * b["占库文件"]))
        L("| %s | %s | %s |" % (name, " | ".join(vals), " | ".join(shares)))
    L("| 向量索引 | " + " | ".join("未建" for _ in tiers) + " | "
      + " | ".join("—" for _ in tiers) + " |")
    L("| 缩略图 / 模型资产 / 临时空间 | " + " | ".join("0" for _ in tiers) + " | "
      + " | ".join("—" for _ in tiers) + " |")
    L("")
    L("> 向量：本轮没建（要加载 mlx 模型，1 个月库就要 1 小时 32 分，见 T11）。"
      "缩略图 D10 默认关；模型资产不在库里；临时空间按 D25 记 0"
      "（`SQLITE_TEMP_STORE=3` 编进去了，PRAGMA 改不回文件）。\n")

    L("### 延迟：逐条查询的冷 / 热 p50 / p95（ms）\n")
    L("| 查询 | 桶 | " + " | ".join("%d 个月 冷 p50/p95" % t["months"] for t in tiers)
      + " | " + " | ".join("%d 个月 热 p50/p95" % t["months"] for t in tiers) + " |")
    L("|---|---|" + "---:|" * (2 * len(tiers)))
    ids = [r["id"] for r in rows_of(tiers[0])]
    per_tier = [{r["id"]: r for r in rows_of(t)} for t in tiers]
    for qid in ids:
        bucket, _limit, _strict = bucket_of(qid)
        cold = " | ".join("%s / %s" % (fmt(pt.get(qid, {}).get("cold_p50")),
                                       fmt(pt.get(qid, {}).get("cold_p95")))
                          for pt in per_tier)
        hot = " | ".join("%s / %s" % (fmt(pt.get(qid, {}).get("hot_p50"), 3),
                                      fmt(pt.get(qid, {}).get("hot_p95"), 3))
                         for pt in per_tier)
        L("| `%s` | %s | %s | %s |" % (qid, (bucket or "—").split("（")[0], cold, hot))
    L("")

    L("### 3.4 分层目标逐项判定（用**热 p95**，取桶内最大的一条）\n")
    L("| 桶（3.4 的目标） | " + " | ".join("%d 个月" % t["months"] for t in tiers)
      + " | 判定 |")
    L("|---|" + "---:|" * len(tiers) + "---|")
    verdicts = []
    for name, limit, strict, _keys in TARGETS:
        cells, ok_all, any_data = [], True, False
        worst = []
        for pt, t in zip(per_tier, tiers):
            vals = [(qid, r["hot_p95"]) for qid, r in pt.items()
                    if bucket_of(qid)[0] == name and r["hot_p95"] is not None]
            if not vals:
                cells.append("—")
                continue
            any_data = True
            qid, v = max(vals, key=lambda kv: kv[1])
            ok = (v < limit) if strict else (v <= limit)
            contended = t["latency"].get("contended")
            ok_all = ok_all and ok
            worst.append((t["months"], qid, v, ok))
            cells.append("%.2f%s%s" % (v, "" if ok else " ✗", "†" if contended else ""))
        verdict = ("—" if not any_data else ("**达标**" if ok_all else "**未达标**"))
        verdicts.append({"bucket": name, "ok": ok_all if any_data else None, "worst": worst})
        L("| %s | %s | %s |" % (name, " | ".join(cells), verdict))
    L("")
    L("> 单元格是该桶里**最慢的一条**的热 p95（ms），`✗` = 超目标，"
      "`†` = 测的时候机器上还有别的编译任务（`contended = true`），这一格不作判据。\n")

    L("### 测量条件\n")
    L("| 档 | 开测前等了多久 | 开测时 1 min 负载 | 忙进程 | 测完的负载 | 有干扰 |")
    L("|---|---:|---:|---|---|---|")
    for t in tiers:
        g = t["latency"]["idle_gate"]
        a = t["latency"].get("after_measure") or {}
        L("| %d 个月 | %.0f s | %.2f | %s | %s | %s |"
          % (t["months"], g["waited_s"], g["load1"],
             ", ".join(g["busy_processes"]) or "无",
             "/".join(str(x) for x in (a.get("load") or [])) or "未记",
             "是（%s）" % ", ".join(a.get("busy_processes") or [])
             if t["latency"].get("contended") else
             ("否" if a else "未记")))
    L("")
    return "\n".join(lines), verdicts


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--scale", default=None, help="scale_test.py 的 scale_all.json")
    p.add_argument("--tier", action="append", default=[],
                   help="单档的 scale_m<NN>.json，可重复。某一档因为机器被占用重测过时用它"
                        "把三档拼起来（按 months 升序排），比手工改 scale_all.json 干净")
    p.add_argument("--out-md", default=None)
    args = p.parse_args(argv)
    if args.tier:
        tiers = [json.load(open(os.path.expanduser(t), encoding="utf-8")) for t in args.tier]
        tiers.sort(key=lambda t: t["months"])
        scale = {"tiers": tiers, "assembled_from": [os.path.basename(os.path.expanduser(t))
                                                    for t in args.tier]}
    elif args.scale:
        scale = json.load(open(os.path.expanduser(args.scale), encoding="utf-8"))
    else:
        raise SystemExit("--scale 与 --tier 至少给一个")
    md, verdicts = build(scale)
    if args.out_md:
        path = os.path.expanduser(args.out_md)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(md)
    print(md)
    print(json.dumps({"verdicts": [{"bucket": v["bucket"], "ok": v["ok"]} for v in verdicts]},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
