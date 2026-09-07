#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M1 / T3：1 个月规模合成观察流 + 带标准答案的查询集 + 检索评估。

只用 Python 标准库。为什么新写一个而不是扩 `tools/proto/gen_synth.py`：
后者直接往一个**明文** SQLite 库里写（M0 的原型 schema，自己建表、自己维护 FTS 触发器），
M1 的库是 SQLCipher 的、由 `core/` 独占持钥，外部进程不该也不能直接写。
所以这里只产出 `brosis-store import-jsonl` 吃的 JSONL，建库全部走存储服务自己的写入口径。
语料池与「稀有标记」的做法沿用 gen_synth.py 的 `--capacity` 分支，
查询集与真值口径沿用 `tools/bench/fts_compare.py`（种植 + 全量重算真值）。

规模口径与 E7（tools/proto/results/capacity_2026-09-06.md §1）一致：
每天 8640 次捕获（24 h ÷ 10 s）、平均 1500 字符中英混排、30% 是新文本。

用法：
    # 1) 生成 JSONL 与查询集（含标准答案）
    PYTHONDONTWRITEBYTECODE=1 python3 tools/proto/gen_synth_m1.py gen \\
        --out  ~/Library/Caches/brosis-build/m1-retrieval/synth_1m.jsonl \\
        --queries ~/Library/Caches/brosis-build/m1-retrieval/queries_1m.json \\
        --days 30 --per-day 8640 --seed 20260907

    # 2) 建库（走 core 的写入口径）
    brosis-store init        --dir <db> --key-file <key>
    brosis-store import-jsonl --dir <db> --key-file <key> --file <jsonl>

    # 3) 评估 Recall@10 / Precision@10
    PYTHONDONTWRITEBYTECODE=1 python3 tools/proto/gen_synth_m1.py eval \\
        --queries <queries.json> --bin <brosis-store> --dir <db> --key-file <key> \\
        --out <eval.json>

`gen` 是确定性的：同 --seed / --days / --per-day 两次产出逐字节相同（`--digest` 打印 SHA-256）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone

# --------------------------------------------------------------------------- #
# 1. 语料池
#
# 规则：**基础语料里不能出现任何查询词**，否则真值会被基础语料稀释成「几乎全库命中」，
# Recall@10 与延迟都失去意义（gen_synth.py 的 CAP_RARE 注释说的就是这件事）。
# 查询词一律靠 §3 的「种植」放进指定数量的文档里。
# --------------------------------------------------------------------------- #

APPS = [
    # (bundle_id, 名称, 载体类型)
    ("com.electron.lark", "飞书", "chat"),
    ("com.tencent.xinWeChat", "微信", "chat"),
    ("com.apple.Safari", "Safari", "web"),
    ("com.microsoft.VSCode", "Code", "code"),
    ("com.apple.Terminal", "终端", "term"),
    ("md.obsidian", "Obsidian", "doc"),
]
KIND_APPS = {
    "chat": ["com.electron.lark", "com.tencent.xinWeChat"],
    "web": ["com.apple.Safari"],
    "code": ["com.microsoft.VSCode"],
    "term": ["com.apple.Terminal"],
    "doc": ["md.obsidian", "com.electron.lark"],
}
KIND_WEIGHTS = [("chat", 26), ("doc", 24), ("web", 20), ("code", 18), ("term", 12)]

WINDOW_TITLES = {
    "chat": ["群「研发同步」", "群「周会」", "与同事的对话", "文件传输助手"],
    "doc": ["每日笔记", "季度小结", "阅读摘录", "草稿箱"],
    "web": ["文档站点", "代码托管站", "论坛首页", "搜索结果"],
    "code": ["主分支工作区", "测试工作区", "补丁审阅"],
    "term": ["shell 会话", "构建输出"],
}

BASE_HOSTS = ["a1.example.com", "b2.example.net", "c3.example.org",
              "d4.example.io", "e5.example.dev"]
BASE_PATHS = ["/tmp/workspace/alpha.md", "/tmp/workspace/beta.md",
              "/tmp/workspace/gamma.txt", "/tmp/workspace/delta.json",
              "/tmp/workspace/epsilon.log"]

FILLER_ZH = [
    "这一段是随手记下来的想法，等确认之后再整理成正式的文字。",
    "刚才那一版的做法留着当对照，别急着删掉，回头还要拿来比。",
    "把口径写清楚，不然到时候两边报的数对不上，又要重新解释一遍。",
    "先按草稿往前推，遇到拿不准的地方停下来问一句再继续。",
    "这条只是提醒自己，不需要别人跟进，也不用排进任何清单。",
    "上午那件事已经处理完了，下午换个方向接着往下做。",
    "这里的判断依据是当时屏幕上看到的东西，不是事后回忆出来的。",
    "两种写法都试过了，差别不大，选看起来更好懂的那个。",
    "把边界情况列出来逐个过一遍，能省掉后面很多来回。",
    "先记一笔，等有空的时候再回来看看还成不成立。",
    "这段话没有特别的含义，只是让整屏内容看起来更像真实的一屏。",
    "从结果看方向是对的，细节还需要再打磨一轮。",
    "同样的东西换个说法再写一遍，读起来会顺一些。",
    "把不确定的部分标出来，别混在已经确认的内容里。",
    "今天先到这里，剩下的明天继续，不用赶。",
    "这份材料给自己看的，不用讲究格式，能读懂就行。",
    "相关的几处都改过了，还剩最后一处等确认。",
    "先留个位置，具体内容等拿到之后再填进去。",
    "看起来没问题，但还是跑一遍确认一下比较放心。",
    "把顺序调整了一下，读下来的逻辑更连贯。",
]
FILLER_EN = [
    "The note above is a placeholder and carries no special meaning.",
    "Keep the previous revision around for comparison before deleting anything.",
    "Write down the assumptions first, otherwise the numbers stop matching later.",
    "Two approaches were tried and the difference turned out to be small.",
    "This paragraph exists only to make the captured screen look realistic.",
    "Leave the uncertain parts marked so they do not blend into confirmed text.",
    "Reordering the sections made the whole thing read more smoothly.",
    "Run it once more to be sure before moving on to the next part.",
]
FILLER_CODE = [
    "let value = try container.decode(String.self, forKey: .value)",
    "for row in rows { total += row.weight * row.factor }",
    "if status != 0 { return .failure(.unexpected(status)) }",
    "SELECT column_a, column_b FROM table_x WHERE column_a > ? ORDER BY column_b;",
    "def helper(items): return [i for i in items if i is not None]",
    "guard let handle = handles[key] else { continue }",
]
FILLER_TERM = [
    "user@host workspace % ls -la",
    "total 48",
    "drwxr-xr-x  6 user  staff   192 Aug 20 10:11 .",
    "user@host workspace % ./run.sh --dry-run",
    "done in 1.42s",
]
POOLS = {
    "chat": (FILLER_ZH, 82, FILLER_EN, 18),
    "doc": (FILLER_ZH, 78, FILLER_EN, 22),
    "web": (FILLER_ZH, 70, FILLER_EN, 30),
    "code": (FILLER_CODE, 65, FILLER_EN, 35),
    "term": (FILLER_TERM, 70, FILLER_EN, 30),
}

# --------------------------------------------------------------------------- #
# 2. 查询集（≥ 40 题，带种植规格与真值规则）
#
# 每题的 rule 决定真值怎么算：
#   text       正文（NFKC 折叠后）含该子串，ASCII 大小写不敏感
#   host       观察的 url.host 等于它或以 ".它" 结尾
#   url        观察的 canonical_url 含该子串
#   path       观察的 file 路径含该子串
#   app        观察的 bundle_id 等于它
#   title      观察的窗口标题含该子串
# 结构化的四条（host / url / path / app）真值取「结构字段命中 ∪ 正文命中」——
# 这是「这条观察和这个对象有关」的诚实定义，两条通道都可以贡献。
# window = 只有落在 [start, end) 内的观察才算相关（同时会作为查询参数传给 search）。
# --------------------------------------------------------------------------- #

QUERY_SPECS = [
    # ---- 中文两字词（走 1–2 字扫描通道；只种在最近 7 天，对应 3.4 的 7 天窗口） ----
    ("zh2-01", "中文两字词", "熵值", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "recent_days": 7}),
    ("zh2-02", "中文两字词", "橄榄", "hit", "text", {"count": 12, "kinds": ["chat"], "recent_days": 7}),
    ("zh2-03", "中文两字词", "砚台", "hit", "text", {"count": 11, "kinds": ["doc", "web"], "recent_days": 7}),
    ("zh2-04", "中文两字词", "蟠桃", "hit", "text", {"count": 9, "kinds": ["chat", "doc"], "recent_days": 7}),
    ("zh2-05", "中文两字词", "琥珀", "hit", "text", {"count": 15, "kinds": ["doc", "web", "chat"], "recent_days": 7}),
    ("zh2-06", "中文两字词", "驼峰", "hit", "text", {"count": 6, "kinds": ["code", "doc"], "recent_days": 7}),
    ("zh2-neg", "中文两字词", "麒麟", "none", "text", None),

    # ---- 单个汉字（bigram 索引命中不了，必须靠扫描回退） ----
    ("zh1-01", "单个汉字", "熵", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "recent_days": 7}),
    ("zh1-02", "单个汉字", "砚", "hit", "text", {"count": 11, "kinds": ["doc", "web"], "recent_days": 7}),
    ("zh1-03", "单个汉字", "珀", "hit", "text", {"count": 15, "kinds": ["doc", "web", "chat"], "recent_days": 7}),
    ("zh1-04", "单个汉字", "榄", "hit", "text", {"count": 12, "kinds": ["chat"], "recent_days": 7}),
    ("zh1-neg", "单个汉字", "鳄", "none", "text", None),

    # ---- 中文三字以上（bigram phrase 的主场） ----
    ("zh3-01", "中文三字以上", "知识图谱", "hit", "text", {"count": 22, "kinds": ["doc", "web", "chat"]}),
    ("zh3-02", "中文三字以上", "采集覆盖率", "hit", "text", {"count": 18, "kinds": ["doc", "chat"]}),
    ("zh3-03", "中文三字以上", "数据保留策略", "hit", "text", {"count": 14, "kinds": ["doc", "web"]}),
    ("zh3-04", "中文三字以上", "无障碍权限", "hit", "text", {"count": 16, "kinds": ["doc", "term", "chat"]}),
    ("zh3-05", "中文三字以上", "双击标题栏", "hit", "text", {"count": 9, "kinds": ["chat", "doc"]}),
    ("zh3-06", "中文三字以上", "预算复核", "hit", "text", {"count": 12, "kinds": ["chat", "doc"]}),
    ("zh3-07", "中文三字以上", "季度排期表", "hit", "text", {"count": 7, "kinds": ["chat", "doc"]}),
    ("zh3-neg", "中文三字以上", "星际航行日志", "none", "text", None),

    # ---- 英文单词 / 术语 ----
    ("en-01", "英文单词", "contentless", "hit", "text", {"count": 20, "kinds": ["code", "doc", "web"]}),
    ("en-02", "英文单词", "checkpoint", "hit", "text", {"count": 24, "kinds": ["code", "term", "doc"]}),
    ("en-03", "英文单词", "entitlement", "hit", "text", {"count": 13, "kinds": ["doc", "term"]}),
    ("en-04", "英文单词", "zygomorphic", "hit", "text", {"count": 5, "kinds": ["doc"]}),
    ("en-05", "英文单词", "SQLCipher", "hit", "text", {"count": 17, "kinds": ["code", "doc", "term"]}),
    ("en-neg", "英文单词", "quokkaflux", "none", "text", None),

    # ---- 代码标识符 ----
    ("id-01", "代码标识符", "parseObservation", "hit", "text", {"count": 15, "kinds": ["code"]}),
    ("id-02", "代码标识符", "sqlite3_prepare_v2", "hit", "text", {"count": 12, "kinds": ["code", "term"]}),
    ("id-03", "代码标识符", "kAXDocumentChanged", "hit", "text", {"count": 10, "kinds": ["code", "doc"]}),
    ("id-04", "代码标识符", "flushPendingOccurrences", "hit", "text", {"count": 8, "kinds": ["code"]}),
    ("id-05", "代码标识符", "wal_checkpoint(TRUNCATE)", "hit", "text", {"count": 11, "kinds": ["code", "term"]}),

    # ---- URL / 域名（精确字段通道） ----
    ("url-01", "URL/域名", "docs.internal.example", "hit", "host",
     {"count": 26, "kinds": ["web"], "host": "docs.internal.example"}),
    ("url-02", "URL/域名", "kanban.internal.example", "hit", "host",
     {"count": 18, "kinds": ["web"], "host": "kanban.internal.example"}),
    ("url-03", "URL/域名", "https://docs.internal.example/spec/", "hit", "url",
     {"count": 14, "kinds": ["web"], "host": "docs.internal.example",
      "url_prefix": "https://docs.internal.example/spec/"}),
    ("url-04", "URL/域名", "paper.internal.example", "hit", "host",
     {"count": 9, "kinds": ["web"], "host": "paper.internal.example"}),
    ("url-neg", "URL/域名", "nowhere.invalid.example", "none", "host", None),

    # ---- 文件路径（精确字段通道） ----
    ("path-01", "文件路径", "/tmp/brosis-m1/report-q3.md", "hit", "path",
     {"count": 16, "kinds": ["doc", "code"], "path": "/tmp/brosis-m1/report-q3.md"}),
    ("path-02", "文件路径", "brosis-m1/notes", "hit", "path",
     {"count": 13, "kinds": ["doc"], "path": "/tmp/brosis-m1/notes/2026-week.md"}),
    ("path-03", "文件路径", "AXReader.swift", "hit", "path",
     {"count": 11, "kinds": ["code"], "path": "/tmp/brosis-m1/Sources/AXReader.swift"}),
    ("path-04", "文件路径", "LedgerBuilder.swift", "hit", "path",
     {"count": 8, "kinds": ["code"], "path": "/tmp/brosis-m1/Sources/LedgerBuilder.swift"}),
    ("path-neg", "文件路径", "/tmp/brosis-m1/never-written.bin", "none", "path", None),

    # ---- 数字 / 错误码 ----
    ("num-01", "数字/错误码", "OSStatus -25300", "hit", "text", {"count": 12, "kinds": ["term", "code"]}),
    ("num-02", "数字/错误码", "E1042", "hit", "text", {"count": 9, "kinds": ["term", "code", "doc"]}),
    ("num-03", "数字/错误码", "exit code 137", "hit", "text", {"count": 7, "kinds": ["term"]}),
    ("num-04", "数字/错误码", "0x80070005", "hit", "text", {"count": 6, "kinds": ["term", "code"]}),

    # ---- 中英混排短语 ----
    ("mix-01", "中英混排短语", "FTS5 索引体积", "hit", "text", {"count": 12, "kinds": ["doc", "web"]}),
    ("mix-02", "中英混排短语", "AX 通知去重", "hit", "text", {"count": 10, "kinds": ["doc", "code"]}),
    ("mix-03", "中英混排短语", "WAL 增长曲线", "hit", "text", {"count": 8, "kinds": ["doc", "term"]}),

    # ---- 时间窗过滤（同一个词，分别只种在不同的周） ----
    ("win-01", "时间窗过滤", "周次标记甲", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "week": 0}),
    ("win-02", "时间窗过滤", "周次标记乙", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "week": 1}),
    ("win-03", "时间窗过滤", "周次标记丙", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "week": 2}),
    ("win-04", "时间窗过滤", "周次标记丁", "hit", "text", {"count": 14, "kinds": ["doc", "chat"], "week": 3}),
    # 覆盖「全月都出现的词 + 早期时间窗」这一形态：FTS 候选是按 rowid 倒序取的（≈ 时间倒序），
    # 候选上限之外的老文本版本根本进不了复核，窗口越靠前越吃亏。R1 第二轮验收点名要补的一题。
    ("win-05", "时间窗过滤", "跨周高频标记", "hit", "text",
     {"count": 120, "kinds": ["doc", "chat", "web", "code", "term"], "query_week": 0}),

    # ---- 应用过滤 ----
    ("app-01", "应用过滤", "跨应用同名标记", "hit", "text",
     {"count": 24, "kinds": ["chat", "code", "doc"], "app_filter": "com.microsoft.VSCode"}),
    ("app-02", "应用过滤", "app:com.apple.Terminal", "hit", "app", {"app_equals": "com.apple.Terminal"}),
]

# 种植模板：纯汉字目标词直接嵌进连续中文里（真实中文没有词间空格）；
# 含拉丁字母 / 数字 / 符号的目标词按中文写作习惯用空格隔开。写法沿用 fts_compare.py。
INJECT_CJK = {
    "chat": "\n关于{TERM}的那条，我下午再看一眼。",
    "doc": "\n{TERM}这一段先按现在的写法放着。",
    "web": "\n页面里提到{TERM}的用法。",
    "code": "\n// 复核{TERM}的边界条件后再合并",
    "term": "\n# note: 检查{TERM}之后重跑一遍",
}
INJECT_ASCII = {
    "chat": "\n关于 {TERM} 的那条，我下午再看一眼。",
    "doc": "\n{TERM} 这一段先按现在的写法放着。",
    "web": "\n页面里提到 {TERM}。",
    "code": "\n// TODO: 复核 {TERM} 的边界条件",
    "term": "\n# note: {TERM}",
}

TRIGGERS = ["app_switch", "window_change", "url_change", "ax_notification", "frame_dirty", "timer"]
COMPLETENESS = (["complete"] * 14) + (["partial"] * 4) + ["unavailable", "excluded"]
SOURCE_STATES = (["ok"] * 17) + ["permission_lost", "timeout", "user_idle"]
CAPTURE_METHODS = (["ax"] * 12) + (["ocr"] * 4) + (["adapter"] * 3) + ["mixed"]


def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return 0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF


def nfkc(s: str) -> str:
    return unicodedata.normalize("NFKC", s)


def weighted_kind(rng: random.Random) -> str:
    total = sum(w for _, w in KIND_WEIGHTS)
    r = rng.randrange(total)
    acc = 0
    for kind, w in KIND_WEIGHTS:
        acc += w
        if r < acc:
            return kind
    return KIND_WEIGHTS[-1][0]


def make_text(rng: random.Random, kind: str, serial: int, avg_chars: int) -> str:
    pool_a, weight_a, pool_b, _ = POOLS[kind]
    target = int(avg_chars * (0.7 + 0.6 * rng.random()))
    lines = ["[%s #%d]" % (kind, serial)]
    total = len(lines[0])
    while total < target:
        pool = pool_a if rng.randrange(100) < weight_a else pool_b
        line = pool[rng.randrange(len(pool))]
        if rng.random() < 0.25:
            line = "%s（%d）" % (line, rng.randrange(1000))
        lines.append(line)
        total += len(line) + 1
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# 3. 生成
# --------------------------------------------------------------------------- #

def generate(args) -> dict:
    t0 = time.time()
    n = args.days * args.per_day
    seed = args.seed
    day_s = 86400
    step_ms = int(day_s * 1000 / args.per_day)
    # 最后一天的 24:00 = anchor；第 0 条落在 anchor - days 天。
    anchor = datetime(2026, 9, 7, 0, 0, 0, tzinfo=timezone.utc)
    start_ms = int((anchor - timedelta(days=args.days)).timestamp() * 1000)
    end_ms = int(anchor.timestamp() * 1000)

    # --- 3.1 先定每条观察的 kind / 应用 / 屏幕，种植要按 kind 选目标 ---
    #
    # 按「连续停留段」铺，不是每条观察独立掷骰子：真实使用里人会在一个应用里待一阵子
    # （本合成流一段是 6–60 条 = 1–10 分钟），而不是每 10 s 换一个应用。
    # 这件事直接决定会话数——独立掷骰子时 3.7 的「打断 20 s」几乎永远不成立，
    # 25.9 万条观察会切出 21.3 万个会话（实测），完全不像真实台账。
    krng = random.Random(seed ^ 0xA5A5)
    kinds: list[str] = [""] * n
    bundles: list[str] = [""] * n
    displays: list[int] = [1] * n
    i = 0
    display = 1
    runs = 0
    interruptions_planted = 0
    while i < n:
        kind = weighted_kind(krng)
        bundle = KIND_APPS[kind][krng.randrange(len(KIND_APPS[kind]))]
        if krng.randrange(100) < 8:                 # 偶尔把焦点挪到第二块屏
            display = 2 if display == 1 else 1
        run = krng.randint(6, 60)
        runs += 1
        start_i = i
        for _ in range(min(run, n - i)):
            kinds[i] = kind
            bundles[i] = bundle
            displays[i] = display
            i += 1
        # 四分之一的停留段里插一次「瞄一眼别的应用又回来」：段中间挖 1 条换成别的应用。
        # 一条 = 10 s < 3.7 的打断上限 20 s，所以它应当被算成**打断**而不是切会话——
        # 不造这种模式的话，1 个月台账里的「打断数」永远是 0，这条口径就没被真数据验过。
        length = i - start_i
        if length >= 5 and krng.randrange(100) < 25:
            pos = start_i + 1 + krng.randrange(length - 2)
            other = weighted_kind(krng)
            other_bundle = KIND_APPS[other][krng.randrange(len(KIND_APPS[other]))]
            if other_bundle != bundle:
                kinds[pos] = other
                bundles[pos] = other_bundle
                interruptions_planted += 1
    by_kind: dict[str, list[int]] = {}
    for idx, k in enumerate(kinds):
        by_kind.setdefault(k, []).append(idx)

    # --- 3.2 种植 ---
    prng = random.Random(seed ^ 0x5A5A)
    plants: dict[int, list[dict]] = {}
    week_ms = 7 * day_s * 1000
    specs = []
    for qid, cls, q, expect, rule, plant in QUERY_SPECS:
        spec = {"id": qid, "class": cls, "q": q, "expect": expect, "rule": rule}
        if plant:
            pool: list[int] = []
            for k in plant.get("kinds", list(by_kind)):
                pool.extend(by_kind.get(k, []))
            pool.sort()
            # 时间限制：recent_days 只种在最后 N 天，week 只种在第 N 周
            if "recent_days" in plant:
                lo = n - plant["recent_days"] * args.per_day
                pool = [i for i in pool if i >= lo]
                spec["window"] = {"days": plant["recent_days"]}
            if "week" in plant:
                lo = plant["week"] * 7 * args.per_day
                hi = min(n, lo + 7 * args.per_day)
                pool = [i for i in pool if lo <= i < hi]
                spec["search"] = {"start": start_ms + lo * step_ms,
                                  "end": start_ms + hi * step_ms}
            # query_week：种在**全月**，只把查询窗口限到第 N 周（候选截断的形态）。
            if "query_week" in plant:
                lo = plant["query_week"] * 7 * args.per_day
                hi = min(n, lo + 7 * args.per_day)
                spec["search"] = {"start": start_ms + lo * step_ms,
                                  "end": start_ms + hi * step_ms}
            if "app_filter" in plant:
                spec["search"] = dict(spec.get("search", {}), app=plant["app_filter"])
            count = plant.get("count")
            if count:
                chosen = prng.sample(pool, min(count, len(pool)))
                for idx in sorted(chosen):
                    plants.setdefault(idx, []).append({
                        "id": qid, "term": q, "host": plant.get("host"),
                        "url_prefix": plant.get("url_prefix"), "path": plant.get("path"),
                    })
            if "app_equals" in plant:
                spec["rule"] = "app"
                spec["app_equals"] = plant["app_equals"]
        specs.append(spec)

    # --- 3.3 逐条生成、边写边算真值 ---
    truth: dict[str, list[int]] = {s["id"]: [] for s in specs}
    reuse_ring: list[str] = []
    ring_size = 64
    stats = {"chars": 0, "bytes": 0, "cjk": 0, "with_text": 0, "new_text": 0, "reused_text": 0}
    counts_by_app: dict[str, int] = {}

    out_path = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    digest = hashlib.sha256()
    written = 0

    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for i in range(n):
            rng = random.Random((seed * 1_000_003 + i) & 0xFFFF_FFFF_FFFF_FFFF)
            kind = kinds[i]
            bundle = bundles[i]                      # 同一段停留里应用不变（见 §3.1）
            app_name = next(nm for b, nm, _ in APPS if b == bundle)
            title = "%s — %s" % (app_name,
                                 WINDOW_TITLES[kind][rng.randrange(len(WINDOW_TITLES[kind]))])
            ts = start_ms + i * step_ms
            display = displays[i]
            completeness = COMPLETENESS[rng.randrange(len(COMPLETENESS))]
            source_state = SOURCE_STATES[rng.randrange(len(SOURCE_STATES))]
            trigger = TRIGGERS[rng.randrange(len(TRIGGERS))]
            method = CAPTURE_METHODS[rng.randrange(len(CAPTURE_METHODS))]

            host = None
            url = None
            path = None
            if kind == "web":
                host = BASE_HOSTS[rng.randrange(len(BASE_HOSTS))]
                url = "https://%s/page/%d" % (host, rng.randrange(400))
            elif kind in ("doc", "code"):
                path = BASE_PATHS[rng.randrange(len(BASE_PATHS))]

            mine = plants.get(i, [])
            # 种植的观察一定产出新正文，绝不复用，免得目标词随复用扩散到没种过的观察上。
            planted = bool(mine)
            has_text = source_state != "permission_lost" and completeness not in ("unavailable", "excluded")
            text = None
            if has_text or planted:
                has_text = True
                if not planted and reuse_ring and rng.random() < 0.62:
                    text = reuse_ring[rng.randrange(len(reuse_ring))]
                    stats["reused_text"] += 1
                else:
                    body = make_text(rng, kind, i, args.avg_chars)
                    # 窗口标题就在屏幕上，作为正文第一行——这样「标题命中」天然是「正文命中」的子集。
                    text = title + "\n" + body
                    for p in mine:
                        table = INJECT_CJK if all(is_cjk(c) for c in p["term"]) else INJECT_ASCII
                        text += table[kind].format(TERM=p["term"])
                        if p.get("host"):
                            host = p["host"]
                            url = p.get("url_prefix")
                            if url:
                                url = url + "%d" % rng.randrange(400)
                            else:
                                url = "https://%s/page/%d" % (host, rng.randrange(400))
                            text += "\n" + url
                        if p.get("path"):
                            path = p["path"]
                            text += "\n" + path
                    text = nfkc(text)
                    if not planted:
                        reuse_ring.append(text)
                        if len(reuse_ring) > ring_size:
                            reuse_ring.pop(0)
                    stats["new_text"] += 1

            record: dict = {
                "ts": ts,
                "display_id": display,
                "app": {"bundle_id": bundle, "name": app_name},
                "window": title,
                "trigger": trigger,
                "capture_method": method,
                "completeness": completeness,
                "source_state": source_state,
            }
            if url:
                record["url"] = {"raw": url, "canonical": url, "host": host, "kind": "web"}
            if path:
                record["file"] = path
            record["texts"] = [{"text": text, "region": '{"ord":0}'}] if text else []

            line = json.dumps(record, ensure_ascii=False, sort_keys=True,
                              separators=(",", ":")) + "\n"
            fh.write(line)
            digest.update(line.encode("utf-8"))
            written += 1
            counts_by_app[bundle] = counts_by_app.get(bundle, 0) + 1

            if text:
                stats["with_text"] += 1
                stats["chars"] += len(text)
                stats["bytes"] += len(text.encode("utf-8"))
                stats["cjk"] += sum(1 for c in text if is_cjk(c))

            # ---- 真值：全量重算，不靠种植记录推断（口径同 fts_compare.py） ----
            low = text.lower() if text else ""
            oid = i + 1                        # import-jsonl 按行序写入，observation.id 从 1 开始
            for s in specs:
                rule = s["rule"]
                hit = False
                if rule == "text":
                    hit = bool(low) and s["q"].lower() in low
                elif rule == "host":
                    q = s["q"].lower()
                    hit = bool(host) and (host.lower() == q or host.lower().endswith("." + q))
                    hit = hit or (bool(low) and q in low)
                elif rule == "url":
                    q = s["q"].lower()
                    hit = bool(url) and q in url.lower()
                    hit = hit or (bool(low) and q in low)
                elif rule == "path":
                    q = s["q"].lower()
                    hit = bool(path) and q in path.lower()
                    hit = hit or (bool(low) and q in low)
                elif rule == "app":
                    hit = bundle == s.get("app_equals")
                if not hit:
                    continue
                win = s.get("search")
                if win:
                    if "start" in win and ts < win["start"]:
                        continue
                    if "end" in win and ts >= win["end"]:
                        continue
                    if "app" in win and bundle != win["app"]:
                        continue
                if "window" in s:                       # 1–2 字查询的 7 天默认窗口
                    if ts < end_ms - s["window"]["days"] * day_s * 1000:
                        continue
                truth[s["id"]].append(oid)

    for s in specs:
        s["relevant"] = truth[s["id"]]

    payload = {
        "version": "m1-r1",
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seed": seed,
        "days": args.days,
        "per_day": args.per_day,
        "avg_chars": args.avg_chars,
        "observations": n,
        "dwell_runs": runs,
        "interruptions_planted": interruptions_planted,
        "start_ms": start_ms,
        "end_ms": end_ms,
        "step_ms": step_ms,
        "jsonl": os.path.basename(out_path),
        "jsonl_sha256": digest.hexdigest(),
        "jsonl_bytes": os.path.getsize(out_path),
        "truth_rule": ("相关 = 该观察的正文（NFKC 折叠后）按 ASCII 大小写不敏感的方式含查询串；"
                       "host / url / path 三类另加结构字段命中（结构 ∪ 正文）；app 类按 bundle_id 等值。"
                       "真值在生成时对每条观察全量重算，不靠种植记录推断。"),
        "id_rule": "import-jsonl 按行序写入，第 k 行（1 起）对应 observations.id = k",
        "corpus_stats": {
            "with_text": stats["with_text"],
            "new_text": stats["new_text"],
            "reused_text": stats["reused_text"],
            "chars": stats["chars"],
            "bytes": stats["bytes"],
            "avg_chars_per_text": stats["chars"] / max(1, stats["with_text"]),
            "bytes_per_char": stats["bytes"] / max(1, stats["chars"]),
            "cjk_ratio": stats["cjk"] / max(1, stats["chars"]),
            "by_app": counts_by_app,
        },
        "queries": specs,
        "elapsed_s": time.time() - t0,
    }
    qpath = os.path.abspath(os.path.expanduser(args.queries))
    os.makedirs(os.path.dirname(qpath), exist_ok=True)
    with open(qpath, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)

    summary = {k: payload[k] for k in
               ("observations", "jsonl_bytes", "jsonl_sha256", "start_ms", "end_ms", "elapsed_s")}
    summary["queries"] = len(specs)
    summary["hit_queries"] = sum(1 for s in specs if s["expect"] == "hit")
    summary["none_queries"] = sum(1 for s in specs if s["expect"] == "none")
    summary["empty_truth"] = [s["id"] for s in specs
                              if s["expect"] == "hit" and not s["relevant"]]
    summary["corpus_stats"] = payload["corpus_stats"]
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return payload


# --------------------------------------------------------------------------- #
# 4. 评估
# --------------------------------------------------------------------------- #

def evaluate(args) -> dict:
    with open(os.path.expanduser(args.queries), encoding="utf-8") as fh:
        payload = json.load(fh)
    specs = payload["queries"]

    batch = []
    for s in specs:
        item = {"id": s["id"], "q": s["q"], "limit": args.limit}
        win = s.get("search") or {}
        for key in ("start", "end", "app"):
            if key in win:
                item[key] = win[key]
        batch.append(item)

    tmp = os.path.expanduser(args.batch_file or (args.out + ".batch.json"))
    os.makedirs(os.path.dirname(os.path.abspath(tmp)), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(batch, fh, ensure_ascii=False)

    cmd = [os.path.expanduser(args.bin), "search-batch",
           "--dir", os.path.expanduser(args.dir),
           "--key-file", os.path.expanduser(args.key_file),
           "--file", tmp]
    if args.tz:
        cmd += ["--tz", args.tz]
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("search-batch 失败：\n%s" % proc.stderr[-4000:])
    results = {r["id"]: r for r in json.loads(proc.stdout)["results"]}
    elapsed = time.time() - t0

    rows = []
    rec_sum = 0.0
    rec_n = 0
    prec_sum = 0.0
    prec_n = 0
    false_positive_queries = 0
    for s in specs:
        r = results.get(s["id"], {})
        got = r.get("evidence_ids", [])[:10]
        rel = set(s["relevant"])
        hits10 = len([i for i in got if i in rel])
        if s["expect"] == "none":
            row = {"id": s["id"], "class": s["class"], "q": s["q"], "expect": "none",
                   "relevant": len(rel), "returned": len(got),
                   "false_positives": len(got),
                   "channels": r.get("channels", [])}
            if got:
                false_positive_queries += 1
            rows.append(row)
            continue
        denom = min(10, len(rel))
        recall = (hits10 / denom) if denom else None
        precision = (hits10 / len(got)) if got else None
        if recall is not None:
            rec_sum += recall
            rec_n += 1
        if precision is not None:
            prec_sum += precision
            prec_n += 1
        rows.append({"id": s["id"], "class": s["class"], "q": s["q"], "expect": "hit",
                     "relevant": len(rel), "returned": len(got), "hits@10": hits10,
                     "recall@10": recall, "precision@10": precision,
                     "channels": r.get("channels", []),
                     "fts_candidates": r.get("fts_candidates"),
                     "fts_candidates_truncated": r.get("fts_candidates_truncated"),
                     "max_summary_tokens": r.get("max_summary_tokens"),
                     "elapsed_ms": r.get("elapsed_ms")})

    by_class: dict[str, dict] = {}
    for row in rows:
        if row["expect"] != "hit":
            continue
        b = by_class.setdefault(row["class"], {"n": 0, "recall": 0.0, "precision": 0.0, "pn": 0})
        b["n"] += 1
        b["recall"] += row["recall@10"] or 0.0
        if row["precision@10"] is not None:
            b["precision"] += row["precision@10"]
            b["pn"] += 1
    for b in by_class.values():
        b["recall@10"] = b["recall"] / b["n"] if b["n"] else None
        b["precision@10"] = b["precision"] / b["pn"] if b["pn"] else None
        del b["recall"], b["precision"], b["pn"]

    out = {
        "queries": len(specs),
        "hit_queries": rec_n,
        "none_queries": sum(1 for s in specs if s["expect"] == "none"),
        "recall@10": rec_sum / rec_n if rec_n else None,
        "precision@10": prec_sum / prec_n if prec_n else None,
        "none_queries_with_false_positives": false_positive_queries,
        "fts_candidates_truncated_queries": [r["id"] for r in rows
                                             if r.get("fts_candidates_truncated")],
        "max_fts_candidates": max((r.get("fts_candidates") or 0) for r in rows),
        "max_summary_tokens": max((r.get("max_summary_tokens") or 0) for r in rows),
        "batch_elapsed_s": elapsed,
        "by_class": by_class,
        "per_query": rows,
        "failures": [r for r in rows
                     if (r["expect"] == "hit" and (r.get("recall@10") or 0) < 1.0)
                     or (r["expect"] == "none" and r.get("false_positives", 0) > 0)],
    }
    if args.out:
        with open(os.path.expanduser(args.out), "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, sort_keys=True)
    printable = {k: out[k] for k in
                 ("queries", "hit_queries", "none_queries", "recall@10", "precision@10",
                  "none_queries_with_false_positives", "fts_candidates_truncated_queries",
                  "max_fts_candidates", "max_summary_tokens", "batch_elapsed_s")}
    printable["by_class"] = by_class
    printable["failures"] = [{k: f[k] for k in ("id", "q", "relevant", "returned")
                              if k in f} for f in out["failures"]]
    print(json.dumps(printable, ensure_ascii=False, indent=1))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen", help="生成 JSONL 与查询集")
    g.add_argument("--out", required=True)
    g.add_argument("--queries", required=True)
    g.add_argument("--days", type=int, default=30)
    g.add_argument("--per-day", type=int, default=8640)
    g.add_argument("--avg-chars", type=int, default=1500)
    g.add_argument("--seed", type=int, default=20260907)

    e = sub.add_parser("eval", help="跑检索评估")
    e.add_argument("--queries", required=True)
    e.add_argument("--bin", required=True)
    e.add_argument("--dir", required=True)
    e.add_argument("--key-file", required=True)
    e.add_argument("--out", default=None)
    e.add_argument("--batch-file", default=None)
    e.add_argument("--limit", type=int, default=10)
    e.add_argument("--tz", default="UTC")

    args = parser.parse_args(argv)
    if args.cmd == "gen":
        generate(args)
    else:
        evaluate(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
