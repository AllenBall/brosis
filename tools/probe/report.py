#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/probe/report.py —— 读 appswitch.jsonl，按前台停留时长出 Markdown 报告（只用标准库）。

用法:
    python3 report.py                       # 全部数据，前 20 名
    python3 report.py --days 3 --top 20     # 最近 3 个自然日
    python3 report.py --file ~/x.jsonl > report.md

口径见输出末尾的"统计口径"一节。
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta

DEFAULT_FILE = os.path.expanduser(
    "~/Library/Application Support/brosis-probe/appswitch.jsonl")

# 系统 / 无意义项：默认从排行里移出，但单独列一张表，不静默丢弃
SYSTEM_BUNDLES = {
    "com.apple.loginwindow": "登录窗口",
    "com.apple.WindowServer": "窗口服务",
    "com.apple.screencaptureui": "截屏界面",
    "none": "无前台应用",
    "unknown": "无 bundle id 的进程",
}

# D2 已固定入选、不占候选名额的应用
FIXED_BUNDLES = {
    "com.electron.lark": "飞书",
    "com.larksuite.larksuite": "Lark",
    "com.bytedance.macos.lark": "飞书",
    "com.tencent.xinWeChat": "微信",
}


def parse_ts(s):
    """解析探针写出的 ISO 8601 带时区时间戳。"""
    return datetime.fromisoformat(s)


def load(path):
    rows, bad = [], 0
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
                o["_start"] = parse_ts(o["start"])
                o["_end"] = parse_ts(o["end"])
                o["dwell_s"] = float(o["dwell_s"])
                o["active_s"] = float(o.get("active_s", 0.0))
                rows.append(o)
            except Exception:
                bad += 1
    rows.sort(key=lambda r: r["_start"])
    return rows, bad


def h(seconds):
    return seconds / 3600.0


def fmt_h(seconds):
    return "%.2f" % h(seconds)


def fmt_m(seconds):
    return "%.1f" % (seconds / 60.0)


def fmt_hm(seconds):
    total_m = int(round(seconds / 60.0))
    return "%d 时 %02d 分" % (total_m // 60, total_m % 60)


def main():
    ap = argparse.ArgumentParser(
        description="brosis D2 应用切换探针报告", add_help=True)
    ap.add_argument("--file", default=DEFAULT_FILE, help="JSONL 数据文件路径")
    ap.add_argument("--days", type=int, default=0,
                    help="只统计最近 N 个自然日（含今天，本地时区）；0 表示全部")
    ap.add_argument("--top", type=int, default=20, help="排行榜条数，默认 20")
    ap.add_argument("--no-exclude", action="store_true",
                    help="不把系统项从主排行里移出")
    args = ap.parse_args()

    path = os.path.expanduser(args.file)
    if not os.path.exists(path):
        print("找不到数据文件: %s" % path, file=sys.stderr)
        return 1

    rows, bad = load(path)
    if not rows:
        print("# brosis D2 应用切换探针报告\n\n数据文件 `%s` 里没有可解析的区间记录。" % path)
        return 0

    window_note = "全部数据"
    if args.days and args.days > 0:
        tz = rows[-1]["_start"].tzinfo
        today = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
        cutoff = today - timedelta(days=args.days - 1)
        rows = [r for r in rows if r["_start"] >= cutoff]
        window_note = "最近 %d 个自然日（%s 起）" % (
            args.days, cutoff.strftime("%Y-%m-%d"))
        if not rows:
            print("# brosis D2 应用切换探针报告\n\n%s 内没有记录。" % window_note)
            return 0

    dwell = defaultdict(float)
    active = defaultdict(float)
    switches = defaultdict(int)
    days_seen = defaultdict(set)
    names = defaultdict(lambda: defaultdict(float))
    per_day_dwell = defaultdict(float)
    per_day_rows = defaultdict(int)

    prev_bundle = None
    for r in rows:
        b = r["bundle_id"]
        dwell[b] += r["dwell_s"]
        active[b] += r["active_s"]
        names[b][r.get("name") or b] += r["dwell_s"]
        d = r["_start"].strftime("%Y-%m-%d")
        days_seen[b].add(d)
        per_day_dwell[d] += r["dwell_s"]
        per_day_rows[d] += 1
        if b != prev_bundle:
            switches[b] += 1
            prev_bundle = b

    def disp_name(b):
        return max(names[b].items(), key=lambda kv: kv[1])[0]

    excluded = [] if args.no_exclude else [b for b in dwell if b in SYSTEM_BUNDLES]
    ranked = sorted(
        [b for b in dwell if b not in excluded], key=lambda b: -dwell[b])

    total_dwell = sum(dwell.values())
    total_active = sum(active.values())
    n_days = len(per_day_dwell)
    first, last = rows[0]["_start"], rows[-1]["_end"]

    out = []
    A = out.append
    A("# brosis D2 应用切换探针报告")
    A("")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 生成时间 | %s |" % datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"))
    A("| 数据文件 | `%s` |" % path)
    A("| 统计窗口 | %s |" % window_note)
    A("| 记录区间 | %s ～ %s |" % (first.strftime("%Y-%m-%d %H:%M"),
                                last.strftime("%Y-%m-%d %H:%M")))
    A("| 区间条数 | %d 条 |" % len(rows))
    A("| 解析失败行 | %d 行 |" % bad)
    A("| 覆盖自然日 | %d 天 |" % n_days)
    A("| 前台停留合计 | %s 小时 = %s 分钟（%s） |" % (fmt_h(total_dwell), fmt_m(total_dwell), fmt_hm(total_dwell)))
    A("| 有输入活跃合计 | %s 小时 = %s 分钟（%s） |" % (fmt_h(total_active), fmt_m(total_active), fmt_hm(total_active)))
    A("| 活跃占比 | %.1f %% |" % (100.0 * total_active / total_dwell if total_dwell else 0.0))
    A("")

    A("## 每日覆盖")
    A("")
    A("| 日期 | 区间条数（条） | 前台停留（小时） | 前台停留（分钟） |")
    A("|---|---:|---:|---:|")
    for d in sorted(per_day_dwell):
        A("| %s | %d | %s | %s |" % (d, per_day_rows[d], fmt_h(per_day_dwell[d]), fmt_m(per_day_dwell[d])))
    A("")

    A("## 应用排行（按前台停留时长）")
    A("")
    A("| # | bundle_id | 应用名 | 前台停留（小时） | 前台停留（分钟） | 有输入活跃（小时） | 活跃占比 | 切到前台（次） | 覆盖天数（天） | 日均停留（小时/天） |")
    A("|---:|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for i, b in enumerate(ranked[:args.top], 1):
        ratio = 100.0 * active[b] / dwell[b] if dwell[b] else 0.0
        nd = len(days_seen[b])
        A("| %d | `%s` | %s | %s | %s | %s | %.1f %% | %d | %d | %s |" % (
            i, b, disp_name(b), fmt_h(dwell[b]), fmt_m(dwell[b]), fmt_h(active[b]),
            ratio, switches[b], nd, "%.2f" % (h(dwell[b]) / nd if nd else 0.0)))
    A("")
    if len(ranked) > args.top:
        rest = sum(dwell[b] for b in ranked[args.top:])
        A("其余 %d 个应用合计前台停留 %s 小时。" % (len(ranked) - args.top, fmt_h(rest)))
        A("")

    if excluded:
        A("### 已从排行移出的系统项")
        A("")
        A("| bundle_id | 说明 | 前台停留（小时） | 前台停留（分钟） |")
        A("|---|---|---:|---:|")
        for b in sorted(excluded, key=lambda x: -dwell[x]):
            A("| `%s` | %s | %s | %s |" % (b, SYSTEM_BUNDLES.get(b, ""), fmt_h(dwell[b]), fmt_m(dwell[b])))
        A("")

    A("## D2 候选清单")
    A("")
    A("飞书、微信按 D2 已固定入选，不占候选名额；下表是其余应用按前台停留时长的前 6 名。")
    A("")
    fixed_hit = [b for b in ranked if b in FIXED_BUNDLES]
    cands = [b for b in ranked if b not in FIXED_BUNDLES][:6]
    A("| 位次 | bundle_id | 应用名 | 前台停留（小时） | 有输入活跃（小时） | 切到前台（次） |")
    A("|---:|---|---|---:|---:|---:|")
    for i, b in enumerate(cands, 1):
        A("| %d | `%s` | %s | %s | %s | %d |" % (i, b, disp_name(b), fmt_h(dwell[b]), fmt_h(active[b]), switches[b]))
    A("")
    if fixed_hit:
        A("固定入选项在本窗口内的实测停留：" + "、".join(
            "%s %s 小时" % (FIXED_BUNDLES[b], fmt_h(dwell[b])) for b in fixed_hit) + "。")
    else:
        A("固定入选项（飞书 / 微信）在本窗口内没有记录。")
    A("")

    A("## 统计口径")
    A("")
    A("- **前台停留（dwell_s）**：`NSWorkspace.frontmostApplication` 每 2 秒采样一次，把相邻两次采样之间的秒数记给上一次采样看到的应用。切换点最多滞后 1 个轮询间隔（2 秒）。单位：秒（原始 JSONL）/ 小时（本表）。")
    A("- **有输入活跃（active_s）**：同一段秒数，只有在采样时刻「距上次键鼠事件 < 60 秒」时才计入。它是注意力的保守下界，不等于停留。")
    A("- **未计入的时间**：锁屏（前台变成 `com.apple.loginwindow` 时直接判定）、系统睡眠、显示器睡眠、快速用户切换期间不记；两条兜底：采样空档 > 10 秒按上次心跳收口，键鼠空闲 >= 15 分钟按离开处理并把区间结束时刻回拨到最后一次输入。因此「前台停留合计」小于开机时长是正常的，两者之差即未知状态。")
    A("- **切到前台（次）**：按 start 排序后，`bundle_id` 与上一条不同即计 1 次；单个区间超过 30 分钟会切段落盘，切段不计入切换次数。")
    A("- **覆盖天数**：该应用出现过区间的本地自然日天数。")
    A("- **双屏**：探针只有一个前台应用概念，副屏上同时可见的窗口不单独计时，不存在重复计时。")
    A("")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
