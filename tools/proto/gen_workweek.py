#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M2 c / T14：带**作息**的合成观察流（给 get_patterns / 周台账用）。

为什么不用 `tools/proto/gen_synth_m1.py`：它按 E7 的容量口径铺流量——每天 8640 次捕获、
24 小时**均匀**分布。那是压容量与检索延迟的最坏情形，但热力图在它上面是一条直线，
"每天什么时候在干什么"这类模式压根没有真值可对。

这里反过来：**先写下作息表，再按表生成观察**，并且把表自己算出来的
「每小时应有多少秒 dwell」「每个应用多少秒」一并写进 `--summary`。
于是 `brosis-store patterns` 的输出可以逐格跟生成器的计划对照——
真值由生成器定义，不由被测代码定义。

只用标准库。确定性：同 `--seed` / `--days` / `--start` 两次产出逐字节相同。

用法：
    PYTHONDONTWRITEBYTECODE=1 python3 tools/proto/gen_workweek.py \\
        --out <目录>/workweek.jsonl --summary <目录>/workweek_plan.json \\
        --days 28 --start 2026-08-10 --seed 20260908

    brosis-store init         --dir <db> --key-file <key>
    brosis-store import-jsonl --dir <db> --key-file <key> --file <目录>/workweek.jsonl
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import time
from datetime import datetime, timedelta, timezone

# --------------------------------------------------------------------------- #
# 1. 作息表（真值就是它）
#
# 时刻一律按 **UTC** 生成，导库时 brosis-store 也用 --tz UTC，这样"当地小时"= UTC 小时，
# 生成器算出来的每小时计划与 get_patterns 的热力图能逐格对上。
# --------------------------------------------------------------------------- #

APPS = [
    ("com.microsoft.VSCode", "Code"),
    ("com.apple.Safari", "Safari"),
    ("com.electron.lark", "飞书"),
    ("com.apple.Terminal", "终端"),
    ("com.tencent.xinWeChat", "微信"),
]

# 每段 = (起点小时, 终点小时, [(bundle, 权重), …])
# 权重决定这一段里各应用被抽到的比例；一段里按 3–30 分钟一小节换应用。
MORNING = [("com.microsoft.VSCode", 5), ("com.apple.Terminal", 2), ("com.electron.lark", 3)]
AFTERNOON = [("com.microsoft.VSCode", 4), ("com.apple.Safari", 4), ("com.electron.lark", 2)]
EVENING = [("com.apple.Safari", 5), ("com.tencent.xinWeChat", 5)]
WEEKEND = [("com.tencent.xinWeChat", 6), ("com.apple.Safari", 4)]

# weekday: 0 = 周一 … 6 = 周日
SCHEDULE = {
    0: [(9.0, 12.5, MORNING), (13.5, 18.0, AFTERNOON)],
    1: [(9.0, 12.5, MORNING), (13.5, 18.0, AFTERNOON), (20.0, 22.0, EVENING)],
    2: [(9.0, 12.5, MORNING), (13.5, 18.0, AFTERNOON)],
    3: [(9.0, 12.5, MORNING), (13.5, 18.0, AFTERNOON), (20.0, 22.0, EVENING)],
    4: [(9.0, 12.5, MORNING), (13.5, 17.0, AFTERNOON)],
    5: [(10.0, 11.5, WEEKEND)],
    6: [],                                   # 周日不开机
}

STEP_MS = 10_000            # 采集节奏：10 s 一条（E7 口径）
CJK = ["会议纪要", "知识图谱", "季度复盘", "设计评审", "接口文档", "全文检索",
       "存储服务", "删除级联", "配额过期", "崩溃恢复", "密钥轮换", "台账口径"]
ASCII_ = ["SQLCipher", "contentless FTS5", "incremental vacuum", "WAL checkpoint",
          "bigram tokenizer", "device_id primary key", "peak footprint", "auto_vacuum"]
HOSTS = ["example.com", "docs.internal", "git.example.org"]


def make_text(rng: random.Random, serial: int, avg_chars: int) -> str:
    target = int(avg_chars * (0.7 + 0.6 * rng.random()))
    parts = ["段落#%d" % serial]
    total = len(parts[0])
    while total < target:
        line = rng.choice(CJK) + "，" + rng.choice(ASCII_)
        parts.append(line)
        total += len(line) + 1
    return "，".join(parts) + "。"


def weighted(rng: random.Random, pairs):
    total = sum(w for _, w in pairs)
    r = rng.randrange(total)
    acc = 0
    for key, w in pairs:
        acc += w
        if r < acc:
            return key
    return pairs[-1][0]


def generate(args) -> dict:
    t0 = time.time()
    rng = random.Random(args.seed)
    start_day = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    if start_day.weekday() != 0:
        raise SystemExit("--start 必须是周一（这样 --days 是 7 的倍数时正好是整周）")

    out_path = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    digest = hashlib.sha256()

    # 计划（真值）：按 UTC 小时累计秒数、按应用累计秒数、观察条数、种了多少次打断 / 空白
    plan_hour = [0.0] * 24
    plan_weekday = [0.0] * 7
    plan_app: dict[str, float] = {}
    planned_obs = 0
    away_planted = 0
    interruptions_planted = 0
    idle_planted = 0
    unknown_planted = 0

    lines = 0
    serial = 0
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for d in range(args.days):
            day = start_day + timedelta(days=d)
            for (h0, h1, mix) in SCHEDULE[day.weekday()]:
                block_start = day + timedelta(hours=h0)
                block_end = day + timedelta(hours=h1)
                ts = block_start
                display = 1
                while ts < block_end:
                    # 一小节：3–30 分钟同一个应用
                    bundle = weighted(rng, mix)
                    minutes = rng.randint(3, 30)
                    section_end = min(ts + timedelta(minutes=minutes), block_end)
                    if rng.randrange(100) < 8:
                        display = 2 if display == 1 else 1
                    # 一小节里 35% 的概率插一次「瞄一眼别的应用又回来」：**正好一条观察**
                    # （10 s ≤ 3.7 的打断上限 20 s），按 3.7 的口径应当算一次**打断**而不是切会话。
                    # 不种这种模式的话，台账里的"打断数"恒为 0，打断率那条口径就没被真数据验过。
                    peek_index = -1
                    peek_bundle = None
                    section_len = int((section_end - ts).total_seconds() * 1000 // STEP_MS)
                    if section_len >= 5 and rng.randrange(100) < 35:
                        peek_index = rng.randrange(1, section_len - 1)
                        others = [b for b, _ in mix if b != bundle]
                        if others:
                            peek_bundle = rng.choice(others)
                            interruptions_planted += 1
                    section_step = 0
                    while ts < section_end:
                        ms = int(ts.timestamp() * 1000)
                        # 5% 的观察是 user_idle（看着屏幕不动手），1% 是读取超时 / 权限丢失
                        roll = rng.randrange(100)
                        if roll < 1:
                            state = "timeout" if roll == 0 else "permission_lost"
                            unknown_planted += 1
                        elif roll < 6:
                            state = "user_idle"
                            idle_planted += 1
                        else:
                            state = "ok"
                        this_bundle = (peek_bundle if (peek_bundle and section_step == peek_index)
                                       else bundle)
                        host = rng.choice(HOSTS) if this_bundle == "com.apple.Safari" else None
                        record = {
                            "ts": ms,
                            "display_id": display,
                            "app": {"bundle_id": this_bundle,
                                    "name": dict(APPS)[this_bundle]},
                            "window": "%s — 窗口 %d" % (dict(APPS)[this_bundle], serial % 5),
                            "trigger": "timer",
                            "capture_method": "ax",
                            "completeness": "complete",
                            "source_state": state,
                            "texts": [{"text": make_text(rng, serial, args.avg_chars),
                                       "region": "{\"ord\":0}"}],
                        }
                        if host:
                            url = "https://%s/page/%d" % (host, serial % 200)
                            record["url"] = {"raw": url, "canonical": url,
                                             "host": host, "kind": "web"}
                        serial += 1
                        line = json.dumps(record, ensure_ascii=False, sort_keys=True,
                                          separators=(",", ":")) + "\n"
                        fh.write(line)
                        digest.update(line.encode("utf-8"))
                        lines += 1
                        planned_obs += 1
                        # 计划：这一条代表 10 s（下一条在 10 s 后；一节的最后一条见下）
                        hour = ts.hour
                        plan_hour[hour] += STEP_MS / 1000.0
                        plan_weekday[day.weekday()] += STEP_MS / 1000.0
                        plan_app[this_bundle] = plan_app.get(this_bundle, 0.0) + STEP_MS / 1000.0
                        ts = ts + timedelta(milliseconds=STEP_MS)
                        section_step += 1
                    # 每节之间 1/4 的概率插一次「离开 20–40 s」——它 ≥ 3.7 的打断阈值，
                    # 所以会把连续工作块切断（工作块统计需要真的有断点才有意义）。
                    if rng.randrange(100) < 25 and ts < block_end:
                        away = rng.choice([20, 30, 40])
                        ts = ts + timedelta(seconds=away)
                        away_planted += 1

    plan = {
        "out": out_path,
        "sha256": digest.hexdigest(),
        "lines": lines,
        "days": args.days,
        "start": args.start,
        "start_ms": int(start_day.timestamp() * 1000),
        "end_ms": int((start_day + timedelta(days=args.days)).timestamp() * 1000),
        "seed": args.seed,
        "step_ms": STEP_MS,
        "avg_chars": args.avg_chars,
        "planned_observations": planned_obs,
        "planned_dwell_s_by_hour": plan_hour,
        "planned_dwell_s_by_weekday": plan_weekday,
        "planned_dwell_s_by_app": plan_app,
        "planned_peak_hour": max(range(24), key=lambda h: plan_hour[h]),
        "away_gaps_planted": away_planted,
        "interruptions_planted": interruptions_planted,
        "user_idle_planted": idle_planted,
        "unknown_planted": unknown_planted,
        "bytes": os.path.getsize(out_path),
        "elapsed_s": time.time() - t0,
        "note": "计划里的每小时秒数是「每条观察代表 10 s」的直接累加；"
                "实际台账会因为 3.7 的停留上限（90 s）在每节末尾多算最多 90 s，"
                "所以实测值应当**略大于等于**计划值。",
    }
    if args.summary:
        summary_path = os.path.abspath(os.path.expanduser(args.summary))
        os.makedirs(os.path.dirname(summary_path), exist_ok=True)
        with open(summary_path, "w", encoding="utf-8") as fh:
            json.dump(plan, fh, ensure_ascii=False, indent=2, sort_keys=True)
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description="带作息的合成观察流（brosis M2 c / T14）")
    parser.add_argument("--out", required=True)
    parser.add_argument("--summary")
    parser.add_argument("--days", type=int, default=28)
    parser.add_argument("--start", default="2026-08-10", help="起始日，必须是周一")
    parser.add_argument("--seed", type=int, default=20260908)
    parser.add_argument("--avg-chars", type=int, default=1500)
    args = parser.parse_args()
    plan = generate(args)
    print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
