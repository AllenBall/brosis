#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 1 个月合成流（tools/proto/gen_synth_m1.py 产出的 JSONL）造 60 题合成查询集。

用途：M1 第二轮的两阶段评估需要一套**带标准答案**的题，在真实题（D12，你按
`tools/eval/queryset.schema.md` 手写）到位之前先把脚本与口径跑通。

口径（与 gen_synth_m1.py 一致，见它第 2 节）：
  * 真值 **对 JSONL 全量重算**，不从种植记录推断，也不读 gen_synth 自己算的 truth；
  * 相关 = 正文按 ASCII 大小写不敏感含查询串；host / path / title 三类另加结构字段命中
    （结构 ∪ 正文）；app 类按 bundle_id 等值；再按题目的时间窗 / 应用过滤裁一次；
  * 观察 id = JSONL 行号（1 起），依据是 `import-jsonl` 按行序写入（core/README.md）。

四类配额沿用 docs/查询集草稿.md 的 10 / 10 / 5 / 5，M1 扩到 60 题即 **20 / 20 / 10 / 10**，
其中「无答案或已删除」10 题 = 6 道负例 + 4 道已删除（删除由 `apply-deletions` 子命令
真的对库执行 `brosis-store delete` 造出来）。

确定性：没有任何随机数。同一份 JSONL + 同一个 `--seed` 标签 → 逐字节相同的查询集。

    PYTHONDONTWRITEBYTECODE=1 python3 make_synthetic_queryset.py gen \
        --jsonl  <scratch>/m1/synth_1m.jsonl \
        --corpus <scratch>/m1/queries_1m.json \
        --out    <scratch>/m1/queryset_60.json

    PYTHONDONTWRITEBYTECODE=1 python3 make_synthetic_queryset.py apply-deletions \
        --queryset <scratch>/m1/queryset_60.json \
        --bin <scratch>/release/brosis-store \
        --dir <scratch>/m1/db --key-file <scratch>/m1/db.key \
        --out <scratch>/results/deletions.json
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA = "brosis/queryset@1"
CLASS_LOC = "活动定位"
CLASS_DETAIL = "原文细节"
CLASS_CROSS = "跨来源"
CLASS_NONE = "无答案或已删除"
QUOTA = {CLASS_LOC: 20, CLASS_DETAIL: 20, CLASS_CROSS: 10, CLASS_NONE: 10}

# 合成语料里的应用（与 gen_synth_m1.py 的 APPS 一致）
APP_NAMES = {
    "com.electron.lark": "飞书",
    "com.tencent.xinWeChat": "微信",
    "com.apple.Safari": "Safari",
    "com.microsoft.VSCode": "Code",
    "com.apple.Terminal": "终端",
    "md.obsidian": "Obsidian",
}

AUTHORED = "2026-09-07"


# --------------------------------------------------------------------------- #
# 1. 题面
#
# 每条 spec：(id, class, 自然语言问题, 检索前缀, 检索词, 真值规则, 窗口, expect, 理由)
#   检索前缀 ∈ {None, app, host, path, title}；None 就是裸查询串
#   真值规则 ∈ {text, app, host, path, title}
#   窗口 = None 或 ("day", 起始天, 起始小时, 小时数) 或 ("week", 第几周)
# 检索词全部来自 gen_synth_m1.py 的种植清单（QUERY_SPECS），基础语料里不出现；
# 负例的检索词是本文件自己挑的，生成时会断言「全库 0 命中」。
# --------------------------------------------------------------------------- #

SPECS = [
    # ---------------- 活动 / 定位 20 题 ----------------
    # 6 题按应用 + 3 小时窗口（草稿第 2 题「昨天下午 2 点到 4 点我主要在哪个应用里」的形状）
    ("loc-01", CLASS_LOC, "第 3 天上午 9 点到 12 点，我在飞书里都停在哪些窗口？",
     "app", "com.electron.lark", "app", ("day", 2, 9, 3), "hit", None),
    ("loc-02", CLASS_LOC, "第 6 天下午 2 点到 5 点，我在微信里看的是哪几个会话？",
     "app", "com.tencent.xinWeChat", "app", ("day", 5, 14, 3), "hit", None),
    ("loc-03", CLASS_LOC, "第 9 天上午 10 点到下午 1 点，我用 Safari 打开过什么页面？",
     "app", "com.apple.Safari", "app", ("day", 8, 10, 3), "hit", None),
    ("loc-04", CLASS_LOC, "第 12 天下午 3 点到 6 点，我在 VS Code 里改的是哪个工作区？",
     "app", "com.microsoft.VSCode", "app", ("day", 11, 15, 3), "hit", None),
    ("loc-05", CLASS_LOC, "第 15 天晚上 8 点到 11 点，我在终端里做了什么？",
     "app", "com.apple.Terminal", "app", ("day", 14, 20, 3), "hit", None),
    ("loc-06", CLASS_LOC, "第 18 天上午 8 点到 11 点，我在 Obsidian 里写的是哪一类笔记？",
     "app", "md.obsidian", "app", ("day", 17, 8, 3), "hit", None),
    # 4 题按站点 + 当天窗口（草稿第 6 题「昨天我在浏览器里打开过哪些页面」的形状）
    ("loc-07", CLASS_LOC, "第 4 天我访问过 a1.example.com 吗？大概什么时候？",
     "host", "a1.example.com", "host", ("day", 3, 0, 24), "hit", None),
    ("loc-08", CLASS_LOC, "第 10 天我在 b2.example.net 上停留过几次？",
     "host", "b2.example.net", "host", ("day", 9, 0, 24), "hit", None),
    ("loc-09", CLASS_LOC, "第 16 天我打开 c3.example.org 是上午还是下午？",
     "host", "c3.example.org", "host", ("day", 15, 0, 24), "hit", None),
    ("loc-10", CLASS_LOC, "第 22 天我看过 d4.example.io 上的哪些页面？",
     "host", "d4.example.io", "host", ("day", 21, 0, 24), "hit", None),
    # 3 题按文件路径 + 6 小时窗口（草稿第 5 题「我上一次打开某文档是什么时候」的形状）
    ("loc-11", CLASS_LOC, "第 7 天上午我在 /tmp/workspace/alpha.md 上工作过吗？",
     "path", "/tmp/workspace/alpha.md", "path", ("day", 6, 6, 6), "hit", None),
    ("loc-12", CLASS_LOC, "第 13 天下午我编辑 /tmp/workspace/beta.md 是几点开始的？",
     "path", "/tmp/workspace/beta.md", "path", ("day", 12, 12, 6), "hit", None),
    ("loc-13", CLASS_LOC, "第 19 天傍晚我打开过 /tmp/workspace/gamma.txt 吗？",
     "path", "/tmp/workspace/gamma.txt", "path", ("day", 18, 18, 6), "hit", None),
    # 4 题按周次标记（同一个词只种在某一周，考时间窗过滤）
    ("loc-14", CLASS_LOC, "第 1 周里我记下「周次标记甲」是在哪几天？",
     None, "周次标记甲", "text", ("week", 0), "hit", None),
    ("loc-15", CLASS_LOC, "第 2 周里带「周次标记乙」的那几屏是什么时候？",
     None, "周次标记乙", "text", ("week", 1), "hit", None),
    ("loc-16", CLASS_LOC, "第 3 周我在哪些应用里写过「周次标记丙」？",
     None, "周次标记丙", "text", ("week", 2), "hit", None),
    ("loc-17", CLASS_LOC, "第 4 周的「周次标记丁」最早出现在哪一天？",
     None, "周次标记丁", "text", ("week", 3), "hit", None),
    # 1 题：全月都出现的词 + 只查第 1 周（FTS 候选按 rowid 倒序取，早期窗口最吃亏）
    ("loc-18", CLASS_LOC, "只看第 1 周，「跨周高频标记」出现在哪些时候？",
     None, "跨周高频标记", "text", ("week", 0), "hit", None),
    # 2 题按窗口标题 + 6 小时窗口（草稿第 9 题「被打断最频繁的时段」的证据形状）
    ("loc-19", CLASS_LOC, "第 24 天下午，「群「研发同步」」这个窗口我开着的时候在看什么？",
     "title", "群「研发同步」", "title", ("day", 23, 12, 6), "hit", None),
    ("loc-20", CLASS_LOC, "第 27 天上午，终端的「构建输出」窗口里滚过什么？",
     "title", "构建输出", "title", ("day", 26, 6, 6), "hit", None),

    # ---------------- 原文细节 20 题 ----------------
    ("det-01", CLASS_DETAIL, "我看到过的关于「知识图谱」的那段原文是怎么写的？",
     None, "知识图谱", "text", None, "hit", None),
    ("det-02", CLASS_DETAIL, "「采集覆盖率」那一条的原文是什么？",
     None, "采集覆盖率", "text", None, "hit", None),
    ("det-03", CLASS_DETAIL, "「数据保留策略」那段里写了什么？",
     None, "数据保留策略", "text", None, "hit", None),
    ("det-04", CLASS_DETAIL, "关于「无障碍权限」我屏幕上出现过的原话是什么？",
     None, "无障碍权限", "text", None, "hit", None),
    ("det-05", CLASS_DETAIL, "提到「双击标题栏」的那条消息原文是什么？",
     None, "双击标题栏", "text", None, "hit", None),
    ("det-06", CLASS_DETAIL, "我在哪里见过 contentless 这个词，上下文是什么？",
     None, "contentless", "text", None, "hit", None),
    ("det-07", CLASS_DETAIL, "关于 checkpoint 的那几屏里写了什么？",
     None, "checkpoint", "text", None, "hit", None),
    ("det-08", CLASS_DETAIL, "entitlement 出现在什么上下文里？",
     None, "entitlement", "text", None, "hit", None),
    ("det-09", CLASS_DETAIL, "关于 SQLCipher 的原文我看到的是哪一句？",
     None, "SQLCipher", "text", None, "hit", None),
    ("det-10", CLASS_DETAIL, "我在代码里看过的 parseObservation 那一行写的是什么？",
     None, "parseObservation", "text", None, "hit", None),
    ("det-11", CLASS_DETAIL, "sqlite3_prepare_v2 出现的那一屏原文是什么？",
     None, "sqlite3_prepare_v2", "text", None, "hit", None),
    ("det-12", CLASS_DETAIL, "kAXDocumentChanged 是在什么上下文里出现的？",
     None, "kAXDocumentChanged", "text", None, "hit", None),
    ("det-13", CLASS_DETAIL, "flushPendingOccurrences 这个函数名我在哪见过，原文怎么说？",
     None, "flushPendingOccurrences", "text", None, "hit", None),
    ("det-14", CLASS_DETAIL, "wal_checkpoint(TRUNCATE) 那条原文是什么？",
     None, "wal_checkpoint(TRUNCATE)", "text", None, "hit", None),
    ("det-15", CLASS_DETAIL, "我看到的那个 OSStatus -25300 报错，完整文本是什么？",
     None, "OSStatus -25300", "text", None, "hit", None),
    ("det-16", CLASS_DETAIL, "错误码 E1042 出现在哪一屏，原文是什么？",
     None, "E1042", "text", None, "hit", None),
    ("det-17", CLASS_DETAIL, "终端里那条 exit code 137 的原文是什么？",
     None, "exit code 137", "text", None, "hit", None),
    ("det-18", CLASS_DETAIL, "0x80070005 这个码出现在什么内容里？",
     None, "0x80070005", "text", None, "hit", None),
    # 两题单字查询：bigram 索引命中不了，必须走 1–2 字扫描通道（默认 7 天窗口，这里显式传）
    ("det-19", CLASS_DETAIL, "最近一周里带「熵」这个字的内容都写了什么？",
     None, "熵", "text", ("last_days", 7), "hit", None),
    ("det-20", CLASS_DETAIL, "最近一周我在哪儿见过「砚」这个字？",
     None, "砚", "text", ("last_days", 7), "hit", None),

    # ---------------- 跨来源 10 题（同一个词跨 ≥ 2 个应用，生成时断言） ----------------
    ("cross-01", CLASS_CROSS, "「跨应用同名标记」我在哪几个应用里都见过？分别是什么时候？",
     None, "跨应用同名标记", "text", None, "hit", None),
    ("cross-02", CLASS_CROSS, "关于「预算复核」，我在聊天和笔记里分别看到过什么？",
     None, "预算复核", "text", None, "hit", None),
    ("cross-03", CLASS_CROSS, "「季度排期表」这件事我在哪些地方跟进过？",
     None, "季度排期表", "text", None, "hit", None),
    ("cross-04", CLASS_CROSS, "关于「FTS5 索引体积」，文档和网页里各写了什么？",
     None, "FTS5 索引体积", "text", None, "hit", None),
    ("cross-05", CLASS_CROSS, "「AX 通知去重」我在笔记和代码里分别是怎么记的？",
     None, "AX 通知去重", "text", None, "hit", None),
    ("cross-06", CLASS_CROSS, "「WAL 增长曲线」在文档和终端里分别出现在什么上下文？",
     None, "WAL 增长曲线", "text", None, "hit", None),
    ("cross-07", CLASS_CROSS, "「熵值」这个词我在哪些应用里见过，按时间排？",
     None, "熵值", "text", None, "hit", None),
    ("cross-08", CLASS_CROSS, "「砚台」出现在哪几类界面里？",
     None, "砚台", "text", None, "hit", None),
    ("cross-09", CLASS_CROSS, "「琥珀」我在聊天、文档、网页里分别看到过什么？",
     None, "琥珀", "text", None, "hit", None),
    ("cross-10", CLASS_CROSS, "「驼峰」这个说法我在代码和笔记里各出现过几次？",
     None, "驼峰", "text", None, "hit", None),

    # ---------------- 无答案或已删除 10 题 ----------------
    # 6 道负例：三条通道各覆盖到（FTS / 扫描 / 精确字段），生成时断言全库 0 命中
    ("none-01", CLASS_NONE, "「犀角」那件事我记在哪儿了？",
     None, "犀角", "text", None, "none", "not_seen"),
    ("none-02", CLASS_NONE, "最近一周我见过带「鸩」字的内容吗？",
     None, "鸩", "text", ("last_days", 7), "none", "not_seen"),
    ("none-03", CLASS_NONE, "记录器启动之前，我读的那本《星象观测手册》里写了什么？",
     None, "星象观测手册", "text", None, "none", "not_captured"),
    ("none-04", CLASS_NONE, "flibbertigibbet 这个词我是在哪篇文章里看到的？",
     None, "flibbertigibbet", "text", None, "none", "not_seen"),
    ("none-05", CLASS_NONE, "我在密码库站点 vault.absent.example 上改过哪个账号？",
     "host", "vault.absent.example", "host", None, "none", "excluded"),
    ("none-06", CLASS_NONE, "我昨天听的那条语音消息（存成 /tmp/workspace/never-written.bin）说了什么？",
     "path", "/tmp/workspace/never-written.bin", "path", None, "none", "not_recorded"),
    # 4 道已删除：语料里本来有，建库后被 brosis-store delete 删掉
    ("del-01", CLASS_NONE, "我删掉了「蟠桃」相关的那几屏，那时候我在做什么？",
     None, "蟠桃", "text", None, "none", "user_deleted"),
    ("del-02", CLASS_NONE, "被我删掉的那条含 zygomorphic 的内容原文是什么？",
     None, "zygomorphic", "text", None, "none", "user_deleted"),
    ("del-03", CLASS_NONE, "第 21 天凌晨 3 点到 4 点那一小时（我删过这段）我在终端里做了什么？",
     "app", "com.apple.Terminal", "app", ("day", 20, 3, 1), "none", "user_deleted"),
    ("del-04", CLASS_NONE, "我把 paper.internal.example 的记录删了之后，那篇论文页写了什么？",
     "host", "paper.internal.example", "host", None, "none", "user_deleted"),
]

# 建库后要执行的删除。probe 决定删哪些观察（生成时按 JSONL 全量算），
# 它与上面 del-0N 题的真值是两回事：probe 是「删什么」，真值是「本来相关的是哪些」。
DELETION_PLAN = [
    ("del-01", "observations", ("text", "蟠桃", None), "把「蟠桃」出现过的那几屏按用户删除处理"),
    ("del-02", "observations", ("text", "zygomorphic", None), "删掉含 zygomorphic 的那几屏"),
    ("del-03", "range", ("window", None, ("day", 20, 3, 1)), "删掉第 21 天 03:00–04:00 这一小时"),
    ("del-04", "object", ("host", "paper.internal.example", None), "按对象删掉 paper.internal.example 的全部记录"),
]


# --------------------------------------------------------------------------- #
# 2. 窗口换算
# --------------------------------------------------------------------------- #

def window_ms(kind, corpus):
    """把 ("day", d, h, n) / ("week", w) / ("last_days", n) 换成 [start_ms, end_ms)。"""
    if kind is None:
        return None, None
    start_ms = corpus["start_ms"]
    end_ms = corpus["end_ms"]
    per_day = corpus["per_day"]
    step = corpus["step_ms"]
    per_hour = per_day // 24
    days_total = max(1, corpus["days"])
    weeks_total = max(1, (days_total + 6) // 7)
    if kind[0] == "day":
        # 题目里写死的第 N 天在比 30 天短的语料上要绕回来（直接拿 `gen` 子命令跑一份
        # 短 JSONL 时的防线；`run_all.sh` 不支持调小 DAYS，见它的头注）。
        # DAYS=30 时 day % 30 == day，30 天的正式跑一点没变。
        _, day, hour, hours = kind
        day %= days_total
        lo = day * per_day + hour * per_hour
        hi = min(corpus["observations"], lo + hours * per_hour)
    elif kind[0] == "week":
        _, week = kind
        week %= weeks_total
        lo = week * 7 * per_day
        hi = min(corpus["observations"], lo + 7 * per_day)
    elif kind[0] == "last_days":
        _, days = kind
        return end_ms - days * 86_400_000, end_ms
    else:
        raise SystemExit("未知窗口类型：%r" % (kind,))
    return start_ms + lo * step, start_ms + hi * step


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------- #
# 3. 扫一遍 JSONL，算真值
# --------------------------------------------------------------------------- #

def scan(jsonl_path, specs, probes, corpus):
    """一次遍历同时算：每题的真值、每题的语料事实、每个删除 probe 的观察 id。"""
    truth = {s["id"]: [] for s in specs}
    facts = {s["id"]: {"apps": {}, "first_ts": None, "last_ts": None, "sample": None,
                       "sample_id": None, "titles": {}} for s in specs}
    probe_ids = {p["id"]: [] for p in probes}

    text_specs = [s for s in specs if s["rule"] == "text"]
    other_specs = [s for s in specs if s["rule"] != "text"]
    text_probes = [p for p in probes if p["kind"] == "text"]
    host_probes = [p for p in probes if p["kind"] == "host"]
    win_probes = [p for p in probes if p["kind"] == "window"]

    lines = 0
    with open(jsonl_path, encoding="utf-8") as fh:
        for line in fh:
            lines += 1
            oid = lines                      # import-jsonl 按行序写入
            rec = json.loads(line)
            ts = rec["ts"]
            bundle = (rec.get("app") or {}).get("bundle_id")
            title = rec.get("window") or ""
            u = rec.get("url") or {}
            host = (u.get("host") or "").lower()
            url = (u.get("canonical") or u.get("raw") or "").lower()
            path = (rec.get("file") or "").lower()
            texts = rec.get("texts") or []
            text = texts[0]["text"] if texts else ""
            low = text.lower()

            for p in win_probes:
                if p["start"] <= ts < p["end"]:
                    probe_ids[p["id"]].append(oid)
            for p in text_probes:
                if p["term_low"] in low:
                    probe_ids[p["id"]].append(oid)
            for p in host_probes:
                if host == p["term_low"]:
                    probe_ids[p["id"]].append(oid)

            for s in text_specs:
                if s["term_low"] not in low:
                    continue
                _accept(s, truth, facts, oid, ts, bundle, title, text)
            for s in other_specs:
                rule = s["rule"]
                t = s["term_low"]
                if rule == "app":
                    hit = bundle == s["term"]
                elif rule == "host":
                    hit = (host == t or host.endswith("." + t) or (url and t in url)
                           or t in low)
                elif rule == "path":
                    hit = (path and t in path) or (t in low)
                elif rule == "title":
                    hit = (t in title.lower()) or (t in low)
                else:
                    raise SystemExit("未知真值规则：%s" % rule)
                if hit:
                    _accept(s, truth, facts, oid, ts, bundle, title, text)

    if lines != corpus["observations"]:
        raise SystemExit("JSONL 行数 %d 与 corpus.observations %d 不符" % (lines, corpus["observations"]))
    return truth, facts, probe_ids


def _accept(spec, truth, facts, oid, ts, bundle, title, text):
    """一条观察对某题命中：先按题目的时间窗裁一次，再记真值与语料事实。"""
    if spec["start"] is not None and ts < spec["start"]:
        return
    if spec["end"] is not None and ts >= spec["end"]:
        return
    truth[spec["id"]].append(oid)
    f = facts[spec["id"]]
    if bundle:
        f["apps"][bundle] = f["apps"].get(bundle, 0) + 1
    if title:
        f["titles"][title] = f["titles"].get(title, 0) + 1
    f["first_ts"] = ts if f["first_ts"] is None else min(f["first_ts"], ts)
    f["last_ts"] = ts if f["last_ts"] is None else max(f["last_ts"], ts)
    if f["sample"] is None and spec["rule"] == "text":
        for ln in text.split("\n"):
            if spec["term_low"] in ln.lower():
                f["sample"] = ln.strip()
                f["sample_id"] = oid
                break


# --------------------------------------------------------------------------- #
# 4. 组装查询集
# --------------------------------------------------------------------------- #

def build_answer(spec, fact, relevant, corpus):
    n = len(relevant)
    apps = sorted(fact["apps"], key=lambda b: (-fact["apps"][b], b))
    app_text = "、".join("%s（%s）" % (APP_NAMES.get(b, b), b) for b in apps[:4])
    if spec["expect"] == "none":
        reason_text = {
            "excluded": "该站点在排除清单里，从来没有采集过。",
            "not_captured": "那段时间记录器还没启动，没有任何记录。",
            "user_deleted": "这段记录已被我主动删除，库里只剩删除审计，不留内容。",
            "not_seen": "库里没有出现过这个内容。",
            "not_recorded": "这类内容（音频 / 未落盘的文件）不在采集范围内。",
        }[spec["reason"]]
        return "无证据。" + reason_text, {"must_include": [], "must_not_include": []}

    span = "%s 到 %s" % (iso(fact["first_ts"]), iso(fact["last_ts"]))
    if spec["rule"] == "app":
        bundle = spec["term"]
        top_titles = sorted(fact["titles"], key=lambda t: (-fact["titles"][t], t))[:3]
        ans = ("这段时间前台是 %s（%s），共 %d 条观察，%s；出现最多的窗口是 %s。"
               % (APP_NAMES.get(bundle, bundle), bundle, n, span, "、".join(top_titles)))
        return ans, {"must_include": [APP_NAMES.get(bundle, bundle)], "must_not_include": []}
    if spec["rule"] == "host":
        ans = "有，共 %d 条观察落在 %s 上，%s；前台应用是 %s。" % (n, spec["term"], span, app_text)
        return ans, {"must_include": [spec["term"]], "must_not_include": []}
    if spec["rule"] == "path":
        ans = "有，共 %d 条观察涉及 %s，%s；前台应用是 %s。" % (n, spec["term"], span, app_text)
        return ans, {"must_include": [spec["term"]], "must_not_include": []}
    if spec["rule"] == "title":
        ans = "共 %d 条观察的窗口标题含「%s」，%s；前台应用是 %s。" % (n, spec["term"], span, app_text)
        return ans, {"must_include": [spec["term"]], "must_not_include": []}
    sample = fact["sample"] or ""
    ans = ("共 %d 条证据含「%s」，%s；涉及应用 %s。原文里的那一句是：「%s」"
           % (n, spec["term"], span, app_text, sample))
    return ans, {"must_include": [spec["term"]], "must_not_include": []}


def gen(args):
    corpus_meta = json.load(open(os.path.expanduser(args.corpus), encoding="utf-8"))
    corpus = {
        "jsonl": os.path.basename(os.path.expanduser(args.jsonl)),
        "jsonl_sha256": corpus_meta.get("jsonl_sha256"),
        "jsonl_bytes": corpus_meta.get("jsonl_bytes"),
        "observations": corpus_meta["observations"],
        "start_ms": corpus_meta["start_ms"],
        "end_ms": corpus_meta["end_ms"],
        "step_ms": corpus_meta["step_ms"],
        "per_day": corpus_meta["per_day"],
        "days": corpus_meta["days"],
        "generator": "tools/proto/gen_synth_m1.py gen --seed %s" % corpus_meta.get("seed"),
        "id_rule": "import-jsonl 按行序写入，第 k 行（1 起）对应 observations.id = k",
    }

    specs = []
    for qid, cls, q, prefix, term, rule, win, expect, reason in SPECS:
        start, end = window_ms(win, corpus)
        specs.append({
            "id": qid, "class": cls, "q": q, "prefix": prefix, "term": term,
            "term_low": term.lower(), "rule": rule, "window": win,
            "start": start, "end": end, "expect": expect, "reason": reason,
        })

    probes = []
    for pid, kind, (ptype, pterm, pwin), note in DELETION_PLAN:
        p = {"id": pid, "cli_kind": kind, "kind": ptype, "note": note,
             "term": pterm, "term_low": (pterm or "").lower(), "start": None, "end": None}
        if ptype == "window":
            p["start"], p["end"] = window_ms(pwin, corpus)
        probes.append(p)

    truth, facts, probe_ids = scan(os.path.expanduser(args.jsonl), specs, probes, corpus)

    deleted = set()
    for p in probes:
        deleted.update(probe_ids[p["id"]])

    # --- 断言：题目设计的前提必须在这份语料上真的成立 ---
    problems = []
    for s in specs:
        raw = truth[s["id"]]
        rel = [i for i in raw if i not in deleted]
        s["raw_count"] = len(raw)
        s["relevant"] = rel
        if s["expect"] == "hit" and not rel:
            problems.append("%s 期望可答但真值为空" % s["id"])
        if s["expect"] == "none" and rel:
            problems.append("%s 期望不可答但真值有 %d 条" % (s["id"], len(rel)))
        if s["expect"] == "none" and s["reason"] == "user_deleted" and not raw:
            problems.append("%s 是已删除题，删除前的真值不能为空" % s["id"])
        if s["expect"] == "none" and s["reason"] != "user_deleted" and raw:
            problems.append("%s 是负例，全库应当 0 命中，实际 %d" % (s["id"], len(raw)))
        if s["class"] == CLASS_CROSS and len(facts[s["id"]]["apps"]) < 2:
            problems.append("%s 是跨来源题，证据只覆盖 %d 个应用"
                            % (s["id"], len(facts[s["id"]]["apps"])))
    counts = {}
    for s in specs:
        counts[s["class"]] = counts.get(s["class"], 0) + 1
    if counts != QUOTA:
        problems.append("四类配额不符：实际 %r，期望 %r" % (counts, QUOTA))
    n_none = sum(1 for s in specs if s["expect"] == "none")
    if n_none < 8:
        problems.append("负例 / 已删除题只有 %d 道，少于 8 道" % n_none)
    for p in probes:
        if not probe_ids[p["id"]]:
            problems.append("删除项 %s 一条都没匹配到" % p["id"])
    if problems:
        raise SystemExit("查询集自检失败：\n  - " + "\n  - ".join(problems))

    # --- 留出题：每类按 id 排序后第 3、6、9… 题（确定性，30%） ---
    by_class = {}
    for s in specs:
        by_class.setdefault(s["class"], []).append(s["id"])
    holdout = set()
    for cls, ids in by_class.items():
        for k, qid in enumerate(sorted(ids)):
            if k % 3 == 2:
                holdout.add(qid)

    queries = []
    for s in specs:
        fact = facts[s["id"]]
        answer, check = build_answer(s, fact, s["relevant"], corpus)
        search_q = ("%s:%s" % (s["prefix"], s["term"])) if s["prefix"] else s["term"]
        evidence = {"text_substrings": [], "apps": [], "time_window": None,
                    "urls": [], "paths": []}
        if s["rule"] in ("text", "title"):
            evidence["text_substrings"] = [s["term"]]
        if s["rule"] == "host":
            evidence["urls"] = [s["term"]]
        if s["rule"] == "path":
            evidence["paths"] = [s["term"]]
        if s["rule"] == "app":
            evidence["apps"] = [s["term"]]
        elif s["expect"] == "hit":
            evidence["apps"] = sorted(fact["apps"])
        if s["start"] is not None or s["end"] is not None:
            evidence["time_window"] = {"start_ms": s["start"], "end_ms": s["end"]}
        queries.append({
            "id": s["id"],
            "class": s["class"],
            "holdout": s["id"] in holdout,
            "q": s["q"],
            "search": {"q": search_q, "start": s["start"], "end": s["end"],
                       "app": None, "limit": args.limit},
            "expect": s["expect"],
            "unanswerable_reason": s["reason"],
            "evidence": evidence,
            "relevant": s["relevant"],
            "relevant_count": len(s["relevant"]),
            "relevant_before_deletions": s["raw_count"],
            "answer": answer,
            "answer_check": check,
            "answer_source": "合成语料全量重算",
            "authored": AUTHORED,
            "notes": "",
        })
    queries.sort(key=lambda r: r["id"])

    deletions = []
    for p in probes:
        ids = probe_ids[p["id"]]
        if p["cli_kind"] == "observations":
            cli = ["--observations", ",".join(str(i) for i in ids)]
        elif p["cli_kind"] == "range":
            cli = ["--range", "%d,%d" % (p["start"], p["end"])]
        elif p["cli_kind"] == "object":
            cli = ["--object", "host=%s" % p["term"]]
        else:
            raise SystemExit("未知删除类型 %s" % p["cli_kind"])
        deletions.append({"id": p["id"], "kind": p["cli_kind"], "cli": cli,
                          "expect_observations_affected": len(ids), "note": p["note"]})

    payload = {
        "schema": SCHEMA,
        "source": "synthetic",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seed": args.seed,
        "quota": QUOTA,
        "corpus": corpus,
        "deletions": deletions,
        "truth_rule": ("相关 = 该观察的正文按 ASCII 大小写不敏感含检索串；host / path / title "
                       "三类另加结构字段命中（结构 ∪ 正文）；app 类按 bundle_id 等值。"
                       "真值对 JSONL 全量重算，再按题目的时间窗裁剪，最后扣掉 deletions 删掉的观察。"),
        "scoring": {
            "stage1": {
                "metric": ["recall@10", "precision@10", "mrr@10"],
                "hit_pass": "recall@10 == 1.0",
                "none_pass": "返回 0 条",
                "target": "可答题 Recall@10 ≥ 0.90（计划 2.4）",
            },
            "stage2": {
                "hit_pass": ("答案含 answer_check.must_include 的全部子串，"
                             "且 cited_evidence_ids 至少一条落在 relevant 里"),
                "none_pass": "unanswerable = true 且不给出任何具体事实、不引用任何证据",
                "target": "有效证据引用 ≥ 0.95（计划 2.4）；编造一次即记失败（查询集草稿）",
            },
        },
        "queries": queries,
    }
    out = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")

    summary = {
        "out": out,
        "queries": len(queries),
        "by_class": counts,
        "holdout": sorted(holdout),
        "hit_queries": sum(1 for q in queries if q["expect"] == "hit"),
        "none_queries": n_none,
        "deleted_observations": len(deleted),
        "relevant_total": sum(q["relevant_count"] for q in queries),
        "relevant_max": max(q["relevant_count"] for q in queries),
        "deletions": [{"id": d["id"], "kind": d["kind"],
                       "observations": d["expect_observations_affected"]} for d in deletions],
    }
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return payload


# --------------------------------------------------------------------------- #
# 5. 执行删除（并与生成侧模拟出来的条数对账）
# --------------------------------------------------------------------------- #

def apply_deletions(args):
    qs = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    if qs.get("schema") != SCHEMA:
        raise SystemExit("不认识的查询集：%r" % qs.get("schema"))
    results = []
    mismatch = []
    for d in qs.get("deletions", []):
        cmd = [os.path.expanduser(args.bin), "delete",
               "--dir", os.path.expanduser(args.dir),
               "--key-file", os.path.expanduser(args.key_file)] + d["cli"]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise SystemExit("delete 失败（%s）：\n%s" % (d["id"], proc.stderr[-4000:]))
        out = json.loads(proc.stdout)
        got = out.get("observations_affected")
        row = {"id": d["id"], "kind": d["kind"], "note": d["note"],
               "expect_observations_affected": d["expect_observations_affected"],
               "observations_affected": got,
               "match": got == d["expect_observations_affected"],
               "store": {k: out.get(k) for k in
                         ("deletion_id", "kind", "reason", "occurrences_deleted",
                          "text_versions_deleted", "fts_rows_deleted", "sessions_stale",
                          "ledgers_stale", "bytes_freed", "fts_rows_after")}}
        results.append(row)
        if not row["match"]:
            mismatch.append(d["id"])
    payload = {"deletions": results, "mismatch": mismatch,
               "all_match": not mismatch,
               "observations_deleted_total": sum(r["observations_affected"] or 0 for r in results)}
    if args.out:
        out = os.path.expanduser(args.out)
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    if mismatch:
        raise SystemExit("删除条数与生成侧模拟不符：%s" % ",".join(mismatch))
    return payload


# --------------------------------------------------------------------------- #
# 6. 变异检验：故意造四道注定失败的题，看 eval_stage1.py 的归因分类对不对
#
# 全 1.000 的评估报告里，「失败归因」那张表是空的——空表证明不了分类器是对的。
# 这四道题分别踩中四个桶，跑完 `verify-mutations` 逐题对答案。
# --------------------------------------------------------------------------- #

def mutate(args):
    qs = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    st = json.load(open(os.path.expanduser(args.stage1), encoding="utf-8"))
    dels = json.load(open(os.path.expanduser(args.deletions), encoding="utf-8"))
    by_id = {q["id"]: q for q in qs["queries"]}
    st_by_id = {r["id"]: r for r in st["per_query"]}

    deleted = set()
    for d in qs["deletions"]:
        if d["kind"] == "observations":
            deleted.update(int(x) for x in d["cli"][1].split(","))
    # 确认这份 deletions.json 确实是这套查询集那一次删除的产物
    plan = {d["id"]: d["expect_observations_affected"] for d in qs["deletions"]}
    done = {r["id"]: r["observations_affected"] for r in dels["deletions"]}
    if plan != done:
        raise SystemExit("deletions.json 与查询集的删除计划不符：%r vs %r" % (done, plan))
    del_01 = next(d for d in qs["deletions"] if d["id"] == "del-01")
    del_01_ids = sorted(int(x) for x in del_01["cli"][1].split(","))

    det = by_id["det-01"]
    det_top = st_by_id["det-01"]["evidence_ids"][0]
    # 一个「活着但绝不会被这条查询召回」的 id：从 1 起找第一个没被删、也不在返回里的
    live_id = next(i for i in range(1, 1000)
                   if i not in deleted and i not in st_by_id["det-01"]["evidence_ids"])
    loc = by_id["loc-01"]

    def q(qid, cls, question, search, expect_bucket, relevant, subs, note):
        return {
            "id": qid, "class": cls, "holdout": False, "q": question, "search": search,
            "expect": "hit", "unanswerable_reason": None,
            "evidence": {"text_substrings": subs, "apps": [], "time_window": None,
                         "urls": [], "paths": []},
            "relevant": relevant, "relevant_count": len(relevant),
            "answer": "（变异检验用，不判内容）",
            "answer_check": {"must_include": [], "must_not_include": []},
            "answer_source": "变异检验", "authored": AUTHORED,
            "notes": "expect_bucket=%s；%s" % (expect_bucket, note),
        }

    queries = [
        q("mut-01-not-captured", CLASS_DETAIL, "《星象观测手册》里写了什么？",
          {"q": "星象观测手册", "start": None, "end": None, "app": None, "limit": 10},
          "未采集", [], ["星象观测手册"], "语料里根本没有这条证据，真值为空"),
        q("mut-02-expired", CLASS_DETAIL, "「蟠桃」那几屏原文是什么？",
          {"q": "蟠桃", "start": None, "end": None, "app": None, "limit": 10},
          "已过期或已删除", del_01_ids, ["蟠桃"],
          "证据本来在，被 del-01 删了；漏掉的 id 在 get_evidence 里应当全进 missing"),
        q("mut-03-index-miss", CLASS_DETAIL, "关于「知识图谱」的原文是什么？",
          dict(det["search"]), "索引漏召回", sorted([det_top, live_id]), ["知识图谱"],
          "真值里掺了一个活着但这条查询召不回的 id（%d），Recall 应当掉到 0.5" % live_id),
        q("mut-04-context-trim", CLASS_LOC, loc["q"],
          dict(loc["search"]), "上下文裁剪", list(loc["relevant"]), ["跨周高频标记"],
          "证据全召回了，但期望子串不在任何一条 ≤ 100 token 摘要里"),
    ]
    payload = {
        "schema": SCHEMA, "source": "synthetic",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seed": qs.get("seed"),
        "corpus": qs["corpus"], "deletions": [], "scoring": qs["scoring"],
        "truth_rule": "变异检验：真值是手工构造的，用来触发四个失败归因桶各一次。",
        "queries": queries,
    }
    out = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")
    print(json.dumps({"out": out, "queries": len(queries), "live_id_used": live_id,
                      "det_top_id": det_top, "deleted_ids_used": del_01_ids},
                     ensure_ascii=False, indent=1))


def verify_mutations(args):
    qs = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    st = json.load(open(os.path.expanduser(args.stage1), encoding="utf-8"))
    got = {r["id"]: r["bucket"] for r in st["per_query"]}
    rows = []
    for q in qs["queries"]:
        want = q["notes"].split("expect_bucket=")[1].split("；")[0]
        rows.append({"id": q["id"], "expect_bucket": want, "bucket": got.get(q["id"]),
                     "match": got.get(q["id"]) == want})
    payload = {"rows": rows, "all_match": all(r["match"] for r in rows)}
    if args.out:
        out = os.path.expanduser(args.out)
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    if not payload["all_match"]:
        raise SystemExit("变异检验没对上：归因分类有问题")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen", help="造 60 题合成查询集")
    g.add_argument("--jsonl", required=True, help="gen_synth_m1.py 产出的 JSONL")
    g.add_argument("--corpus", required=True, help="gen_synth_m1.py 产出的 queries json（只读元数据）")
    g.add_argument("--out", required=True)
    g.add_argument("--limit", type=int, default=10)
    g.add_argument("--seed", type=int, default=20260907, help="只作标签：本脚本没有随机数")

    a = sub.add_parser("apply-deletions", help="按查询集里的 deletions 对库执行删除并对账")
    a.add_argument("--queryset", required=True)
    a.add_argument("--bin", required=True)
    a.add_argument("--dir", required=True)
    a.add_argument("--key-file", required=True)
    a.add_argument("--out", default=None)

    m = sub.add_parser("mutate", help="造 4 道注定失败的题，检验失败归因分类")
    m.add_argument("--queryset", required=True, help="60 题的查询集")
    m.add_argument("--stage1", required=True, help="60 题跑出来的 stage1.json")
    m.add_argument("--deletions", required=True)
    m.add_argument("--out", required=True)

    v = sub.add_parser("verify-mutations", help="核对变异检验的归因是不是四个桶各一")
    v.add_argument("--queryset", required=True, help="mutate 产出的查询集")
    v.add_argument("--stage1", required=True, help="它跑出来的 stage1.json")
    v.add_argument("--out", default=None)

    args = p.parse_args(argv)
    if args.cmd == "gen":
        gen(args)
    elif args.cmd == "apply-deletions":
        apply_deletions(args)
    elif args.cmd == "mutate":
        mutate(args)
    else:
        verify_mutations(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
