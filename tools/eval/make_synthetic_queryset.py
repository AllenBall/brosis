#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 1 个月合成流（tools/proto/gen_synth_m1.py 产出的 JSONL）造 100 题合成查询集。

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

**M2 d / T17 扩到 100 题**（计划 4.3「查询集扩到 100 题，留出 30 题作独立测试」）：
原 60 题的 `id` / `q` / `search` / `relevant` / `answer` **一个字都没改**，只是每道题多了
`difficulty` / `tool` / `truth_mode` 三个字段；新增 40 题分两拨——

  * **18 题走检索**（`loc-21…25` / `det-21…26` / `cross-11…13` / `none-07…10`），
    真值口径与原 60 题完全一样（对 JSONL 全量重算）；
  * **22 题走 M2 c 批的新工具**（`pat-01…14` 用 `get_day_ledger` / 周台账 / `get_patterns` /
    `get_timeline` / `get_item`，`rec-01…08` 用 `recent_activity` / `get_context`）。
    这类题问的是**聚合量**不是"某几条观察"，给它编一份全量 `relevant` 既臃肿（一周窗口
    动辄一万多条）又没意义（前 10 条里随便哪 10 条都"相关"）。所以它们 `relevant` 留空、
    `truth_mode = "evidence_match"`：第一阶段判"返回的证据满不满足期望证据"、Recall 记 null
    （与真实题同一条口径，见 queryset.schema.md §7），真正的判据是 `tool_check` ——
    一组能从 JSONL **精确算出来**的断言，由 `verify-tools` 子命令真的调 `brosis-store`
    跑一遍逐条核对。断言只用**条数**这类严格可算的量，不用 dwell 秒数
    （`source_state` 里有 10% 的 permission_lost / timeout 不计入 dwell，条数才是确定的）。

六类配额：活动定位 25 / 原文细节 26 / 跨来源 13 / 无答案或已删除 14 / 活动模式 14 / 最近活动 8。
难度 `difficulty` 由规则算出来（见 `difficulty_of`），不是手工标的。
留出题 30 道 = 原 60 题的 18 道（每类第 3、6、9… 题，**与 M1 完全一致，一道都没换**）
+ 新 40 题按 id 排序后每 10 题取第 3 / 6 / 9 道（12 道）。

确定性：没有任何随机数。同一份 JSONL + 同一个 `--seed` 标签 → 逐字节相同的查询集。

    PYTHONDONTWRITEBYTECODE=1 python3 make_synthetic_queryset.py gen \
        --jsonl  <scratch>/m1/synth_1m.jsonl \
        --corpus <scratch>/m1/queries_1m.json \
        --out    <scratch>/m1/queryset_100.json

    PYTHONDONTWRITEBYTECODE=1 python3 make_synthetic_queryset.py apply-deletions \
        --queryset <scratch>/m1/queryset_100.json \
        --bin <scratch>/release/brosis-store \
        --dir <scratch>/m1/db --key-file <scratch>/m1/db.key \
        --out <scratch>/results/deletions.json
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

SCHEMA = "brosis/queryset@1"
CLASS_LOC = "活动定位"
CLASS_DETAIL = "原文细节"
CLASS_CROSS = "跨来源"
CLASS_NONE = "无答案或已删除"
CLASS_PATTERN = "活动模式"      # M2 d / T17 新增：答案是台账 / 模式类聚合量
CLASS_RECENT = "最近活动"        # M2 d / T17 新增：答案是 recent_activity / get_context
CLASSES = (CLASS_LOC, CLASS_DETAIL, CLASS_CROSS, CLASS_NONE, CLASS_PATTERN, CLASS_RECENT)
QUOTA = {CLASS_LOC: 25, CLASS_DETAIL: 26, CLASS_CROSS: 13, CLASS_NONE: 14,
         CLASS_PATTERN: 14, CLASS_RECENT: 8}

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
AUTHORED_M2 = "2026-09-08"     # M2 d / T17 新增的 40 题


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

# --------------------------------------------------------------------------- #
# 1b. M2 d / T17 新增的 18 道检索题（口径与上面的 60 题完全一样，只是题多了）
#
# 检索词全部取自 gen_synth_m1.py 的种植清单里**原 60 题没用到的那些**，
# 外加两个不靠种植也确定存在的形态：
#   * `复核` —— 只出现在 INJECT_CJK["code"] / INJECT_ASCII["code"] 两条注入模板里，
#     所以它是"高频但仍然有界"的词，专门用来压 FTS 候选上限；
#   * `SQLCIPHER` —— 全大写查同一个词，考的是 ASCII 大小写不敏感（真值与 det-09 相同）。
# --------------------------------------------------------------------------- #

SPECS_M2_SEARCH = [
    # ---------------- 活动定位 +5 ----------------
    ("loc-21", CLASS_LOC, "第 3 周里我在 docs.internal.example 上看过哪些页面？",
     "host", "docs.internal.example", "host", ("week", 2), "hit", None),
    ("loc-22", CLASS_LOC, "我打开过 docs.internal.example 的 /spec/ 目录下的哪些页面？",
     "url", "https://docs.internal.example/spec/", "url", None, "hit", None),
    ("loc-23", CLASS_LOC, "第 26 天上午 9 点到 12 点，我在 e5.example.dev 上停留过吗？",
     "host", "e5.example.dev", "host", ("day", 25, 9, 3), "hit", None),
    ("loc-24", CLASS_LOC, "我在 /tmp/brosis-m1/report-q3.md 上工作过哪些时候？",
     "path", "/tmp/brosis-m1/report-q3.md", "path", None, "hit", None),
    ("loc-25", CLASS_LOC, "第 5 天我在「每日笔记」这个窗口里待过吗？都在什么时候？",
     "title", "每日笔记", "title", ("day", 4, 0, 24), "hit", None),

    # ---------------- 原文细节 +6 ----------------
    ("det-21", CLASS_DETAIL, "最近一周里带「榄」这个字的内容都写了什么？",
     None, "榄", "text", ("last_days", 7), "hit", None),
    ("det-22", CLASS_DETAIL, "我在代码注释里写「复核」的那些地方，原文都是怎么写的？",
     None, "复核", "text", None, "hit", None),
    ("det-23", CLASS_DETAIL, "AXReader.swift 出现在哪几屏里，上下文是什么？",
     None, "AXReader.swift", "text", None, "hit", None),
    ("det-24", CLASS_DETAIL, "LedgerBuilder.swift 那几屏的原文是什么？",
     None, "LedgerBuilder.swift", "text", None, "hit", None),
    ("det-25", CLASS_DETAIL, "kanban.internal.example 这个地址出现在什么内容里？",
     None, "kanban.internal.example", "text", None, "hit", None),
    ("det-26", CLASS_DETAIL, "SQLCIPHER（我记得是全大写）那条原文是什么？",
     None, "SQLCIPHER", "text", None, "hit", None),

    # ---------------- 跨来源 +3（生成时断言证据跨 ≥ 2 个 bundle_id） ----------------
    ("cross-11", CLASS_CROSS, "「橄榄」这个词我在哪几个聊天软件里见过？",
     None, "橄榄", "text", None, "hit", None),
    ("cross-12", CLASS_CROSS, "brosis-m1/notes 底下的东西我在哪些应用里打开过？",
     None, "brosis-m1/notes", "text", None, "hit", None),
    ("cross-13", CLASS_CROSS, "带「珀」字的内容分别出现在哪些界面里？",
     None, "珀", "text", ("last_days", 7), "hit", None),

    # ---------------- 无答案或已删除 +4（全是负例，生成时断言全库 0 命中） ----------------
    ("none-07", CLASS_NONE, "「麒麟」那件事我记在哪儿了？",
     None, "麒麟", "text", None, "none", "not_seen"),
    ("none-08", CLASS_NONE, "最近一周我见过带「鳄」字的内容吗？",
     None, "鳄", "text", ("last_days", 7), "none", "not_seen"),
    ("none-09", CLASS_NONE, "记录器装上之前我读的《星际航行日志》里写了什么？",
     None, "星际航行日志", "text", None, "none", "not_captured"),
    ("none-10", CLASS_NONE, "我在 nowhere.invalid.example 上填过哪个表单？",
     "host", "nowhere.invalid.example", "host", None, "none", "excluded"),
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
# 2b. M2 d / T17：工具题要用的窗口、ISO 周与难度规则
# --------------------------------------------------------------------------- #

DAY_MS = 86_400_000


def full_iso_weeks(corpus):
    """完整落在语料区间里的 ISO 周（周一 00:00 UTC 起算），返回 [(YYYY-Www, start_ms, end_ms)]。

    只取**整周**：整周的观察数恰好是 7 × per_day，工具题的断言才能写成等号。
    """
    start = datetime.fromtimestamp(corpus["start_ms"] / 1000, tz=timezone.utc)
    end_ms = corpus["end_ms"]
    d = start.date()
    d = d + timedelta(days=(7 - d.weekday()) % 7)          # 第一个 >= start 的周一
    weeks = []
    while True:
        w0 = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
        lo = int(w0.timestamp() * 1000)
        hi = lo + 7 * DAY_MS
        if hi > end_ms or lo < corpus["start_ms"]:
            break
        iso = d.isocalendar()
        weeks.append(("%04d-W%02d" % (iso[0], iso[1]), lo, hi))
        d = d + timedelta(days=7)
    if len(weeks) < 2:
        raise SystemExit("语料里凑不出两个完整 ISO 周（%d 个），工具题没法出" % len(weeks))
    return weeks


def day_string(corpus, day_index):
    day_index %= max(1, corpus["days"])
    dt = datetime.fromtimestamp((corpus["start_ms"] + day_index * DAY_MS) / 1000, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d")


def tool_windows(corpus):
    """工具题要精确计数的那几个窗口（半开区间 [lo, hi)）。"""
    start, end = corpus["start_ms"], corpus["end_ms"]
    weeks = full_iso_weeks(corpus)
    out = {
        "full": (start, end),
        "day11": window_ms(("day", 11, 0, 24), corpus),
        "day19": window_ms(("day", 19, 0, 24), corpus),
        "day04": window_ms(("day", 4, 0, 24), corpus),
        "last7d": (end - 7 * DAY_MS, end),
        "last24h": (end - DAY_MS, end),
        "last5m": (end - 5 * 60_000, end),
        "last30m": (end - 30 * 60_000, end),
        "last60m": (end - 60 * 60_000, end),
        "last120m": (end - 120 * 60_000, end),
        "mid30m": (start + 15 * DAY_MS - 30 * 60_000, start + 15 * DAY_MS),
    }
    out["week1"] = (weeks[1][1], weeks[1][2])
    out["weekLast"] = (weeks[-1][1], weeks[-1][2])
    return out


def difficulty_of(q):
    """难度是**算出来的**，不是手工标的。三档，规则写在这里，README 里照抄。

      难 —— 工具题（要先调台账 / 模式 / 最近活动才有答案）、
            不可答题与已删除题（草稿规定"编造一次即失败"）、
            单个汉字（bigram 索引命中不了，只能走扫描回退）、
            全大写变形（考 ASCII 大小写折叠）；
      中 —— 带时间窗或应用过滤、窗口标题类、跨来源类（要 ≥ 2 个应用的证据）；
      易 —— 其余：不带窗口的精确字段前缀 / 三字以上词 / 英文词 / 代码标识符。
    """
    if q.get("tool", "search") != "search":
        return "难"
    if q["expect"] == "none":
        return "难"
    term = q["search"]["q"]
    for prefix in ("url:", "host:", "path:", "app:", "title:"):
        if term.startswith(prefix):
            term = term[len(prefix):]
            break
    if len(term) == 1:
        return "难"
    if term.isascii() and term.isupper() and term.isalpha():
        return "难"
    if q["class"] == CLASS_CROSS:
        return "中"
    if q["search"].get("start") is not None or q["search"].get("end") is not None:
        return "中"
    if q["search"].get("app"):
        return "中"
    if q["class"] == CLASS_LOC and q["search"]["q"].startswith("title:"):
        return "中"
    return "易"


# --------------------------------------------------------------------------- #
# 2c. M2 d / T17：22 道工具题
#
# `tool_check` 是一组能从 JSONL 精确算出来的断言，`verify-tools` 子命令真的调
# `brosis-store` 跑一遍逐条核对。`path` 用点号分段，数字段是数组下标，`*` 表示
# "数组的每一个元素"。op ∈ eq / all_eq / sum_eq / all_le / len / le / ge。
# --------------------------------------------------------------------------- #

TOOL_ANSWER_SOURCE = "合成语料全量重算（工具题的断言由 verify-tools 真的调 brosis-store 核对）"


def _tool_q(qid, cls, q, tool, cli, window, checks, corpus, tool_facts,
            answer, must_include, notes):
    lo, hi = window
    top = next(iter(tool_facts["window_by_app"][notes["window_name"]]), None)
    bundle = notes.get("evidence_app") or top
    return {
        "id": qid,
        "class": cls,
        "q": q,
        "tool": tool,
        "tool_call": {"mcp_tool": notes["mcp_tool"], "cli": cli},
        "tool_check": checks,
        "search": {"q": "app:" + bundle, "start": lo, "end": hi, "app": None,
                   "limit": corpus.get("limit", 10)},
        "expect": "hit",
        "unanswerable_reason": None,
        "evidence": {"text_substrings": [], "apps": [bundle],
                     "time_window": {"start_ms": lo, "end_ms": hi}, "urls": [], "paths": []},
        "relevant": [],
        "relevant_count": None,
        "relevant_before_deletions": None,
        "truth_mode": "evidence_match",
        "answer": answer,
        "answer_check": {"must_include": must_include, "must_not_include": []},
        "answer_source": TOOL_ANSWER_SOURCE,
        "authored": AUTHORED_M2,
        "notes": notes.get("note", ""),
    }


def build_tool_questions(corpus, tool_facts, limit):
    """22 道工具题：14 道活动模式 + 8 道最近活动。全部确定性，参数从语料元数据算出来。"""
    W = tool_windows(corpus)
    weeks = full_iso_weeks(corpus)
    per_day = corpus["per_day"]
    step = corpus["step_ms"]
    tz = ["--tz", "UTC"]
    obs = tool_facts["window_observations"]
    by_app = tool_facts["window_by_app"]
    corpus = dict(corpus, limit=limit)

    def name(b):
        return APP_NAMES.get(b, b)

    def top_app(win):
        return next(iter(by_app[win]))

    def chk(path, op, value, note):
        return {"path": path, "op": op, "value": value, "note": note}

    out = []
    d11, d19, d04 = day_string(corpus, 11), day_string(corpus, 19), day_string(corpus, 4)
    w1_name, w1_lo, w1_hi = weeks[1]
    wl_name, wl_lo, wl_hi = weeks[-1]
    week_obs = 7 * per_day
    tr = tool_facts["top_transition"]

    # ---------------- 活动模式 14 题 ----------------
    out.append(_tool_q(
        "pat-01", CLASS_PATTERN, "%s 那天我用得最多的应用是哪一个？" % d11,
        "get_day_ledger", ["ledger", "--date", d11] + tz, W["day11"],
        [chk("observations", "eq", obs["day11"], "当天存活观察数（每天 %d 条，减去查询集删掉的）" % per_day),
         chk("apps.0.key", "eq", top_app("day11"), "台账里排第一的应用")],
        corpus, tool_facts,
        "%s 当天共 %d 条观察，用得最多的是 %s（%s，%d 条）。"
        % (d11, obs["day11"], name(top_app("day11")), top_app("day11"), by_app["day11"][top_app("day11")]),
        [name(top_app("day11"))],
        {"window_name": "day11", "mcp_tool": "get_day_ledger",
         "note": "日台账按应用排序的第一名；条数是严格可算的（10 s 一格的均匀网格）"}))

    out.append(_tool_q(
        "pat-02", CLASS_PATTERN, "%s 那天我一共记录了多少条观察？用的是哪套会话常量？" % d19,
        "get_day_ledger", ["ledger", "--date", d19] + tz, W["day19"],
        [chk("observations", "eq", obs["day19"], "当天存活观察数"),
         chk("sessionConfig.maxDwellSeconds", "eq", 90, "3.7 的停留上限默认 90 s"),
         chk("sessionConfig.gapSeconds", "eq", 300, "会话间隔默认 300 s"),
         chk("sessionConfig.interruptionSeconds", "eq", 20, "打断阈值默认 20 s")],
        corpus, tool_facts,
        "%s 共 %d 条观察；这份台账用的是 maxDwell 90 s / gap 300 s / interruption 20 s。" % (d19, obs["day19"]),
        [str(obs["day19"])],
        {"window_name": "day19", "mcp_tool": "get_day_ledger",
         "note": "台账要把算它用的三个常量一起交回来（3.7）"}))

    out.append(_tool_q(
        "pat-03", CLASS_PATTERN, "%s 这一周我一共记录了多少条观察？" % w1_name,
        "get_week_ledger", ["week-ledger", "--week", w1_name] + tz, W["week1"],
        [chk("observations", "eq", obs["week1"], "整周存活观察数（7 × %d 减去删掉的）" % per_day),
         chk("days", "len", 7, "周台账覆盖 7 天")],
        corpus, tool_facts,
        "%s 共 %d 条观察（满格是 7 × %d = %d，差的那几条是查询集执行的删除）。"
        % (w1_name, obs["week1"], per_day, week_obs),
        [str(obs["week1"])],
        {"window_name": "week1", "mcp_tool": "get_week_ledger", "note": ""}))

    out.append(_tool_q(
        "pat-04", CLASS_PATTERN, "%s 这一周里哪一天我记录得最多？" % w1_name,
        "get_week_ledger", ["week-ledger", "--week", w1_name] + tz, W["week1"],
        [chk("dayTotals", "len", 7, "7 个日总计"),
         chk("dayTotals.*.observations", "sum_eq", obs["week1"], "7 天之和 = 周总数"),
         chk("dayTotals.*.observations", "all_le", per_day, "没有哪天超过满格 %d 条" % per_day)],
        corpus, tool_facts,
        "没有哪一天特别多：合成语料是 %d s 一格的均匀网格，7 天各 %d 条上下"
        "（个别天少几条是查询集执行的删除），合计 %d 条。" % (step // 1000, per_day, obs["week1"]),
        ["没有"],
        {"window_name": "week1", "mcp_tool": "get_week_ledger",
         "note": "答案是「都一样」——合成语料按定义没有作息，这一条是故意留的诚实答案"}))

    out.append(_tool_q(
        "pat-05", CLASS_PATTERN, "%s 的周台账和那 7 天的日台账加起来对得上吗？" % wl_name,
        "get_week_ledger", ["week-ledger", "--week", wl_name, "--check"] + tz, W["weekLast"],
        [chk("check.week_observations", "eq", obs["weekLast"], "周台账的观察数"),
         chk("check.sum_observations", "eq", obs["weekLast"], "7 个日台账之和"),
         chk("check.week_online_union_s", "eq", "@check.sum_online_union_s",
             "并集时长：天与天不重叠，周 = 7 天之和，这一项没有定义差异")],
        corpus, tool_facts,
        "对得上：周台账 %d 条观察 = 7 个日台账之和；onlineUnionS 也逐字段相等。" % obs["weekLast"],
        ["对得上"],
        {"window_name": "weekLast", "mcp_tool": "get_week_ledger",
         "note": "「周 = 7 天之和」是可断言的不变量（core/README 周台账一节）"}))

    out.append(_tool_q(
        "pat-06", CLASS_PATTERN, "%s 那一周我每天的活动分布是怎样的？" % w1_name,
        "get_patterns", ["patterns", "--start", str(w1_lo), "--end", str(w1_hi)] + tz, W["week1"],
        [chk("observations", "eq", obs["week1"], "区间存活观察数"),
         chk("byWeekday", "len", 7, "星期边际表定长 7 行"),
         chk("byWeekday.*.observations", "sum_eq", obs["week1"], "七行之和 = 区间总数"),
         chk("spanDays", "eq", 7, "跨 7 天")],
        corpus, tool_facts,
        "七天几乎完全平均，每天 %d 条上下，合计 %d 条；byWeekday 七行之和等于区间总数。"
        % (per_day, obs["week1"]),
        [str(obs["week1"])],
        {"window_name": "week1", "mcp_tool": "get_patterns", "note": ""}))

    out.append(_tool_q(
        "pat-07", CLASS_PATTERN, "我一天里哪个小时最活跃？",
        "get_patterns", ["patterns", "--start", str(w1_lo), "--end", str(w1_hi)] + tz, W["week1"],
        [chk("byHour", "len", 24, "小时边际表定长 24 行"),
         chk("byHour.*.observations", "sum_eq", obs["week1"], "24 行之和 = 区间总数"),
         chk("byHour.*.observations", "all_le", 7 * per_day // 24,
             "没有哪个小时超过满格 %d 条" % (7 * per_day // 24)),
         chk("heatmap", "len", 168, "星期 × 小时热力 7 × 24 格")],
        corpus, tool_facts,
        "没有高峰：24 个小时各 %d 条观察上下（满格 %d），热力表 168 格。"
        % (7 * per_day // 24, 7 * per_day // 24),
        ["没有"],
        {"window_name": "week1", "mcp_tool": "get_patterns",
         "note": "合成语料是 24 h 均匀网格，作息类模式题要用 tools/proto/gen_workweek.py 的库"}))

    out.append(_tool_q(
        "pat-08", CLASS_PATTERN, "整整一个月里我在哪个应用上出现得最多？占多大比例？",
        "get_patterns", ["patterns", "--start", str(W["full"][0]), "--end", str(W["full"][1])] + tz,
        W["full"],
        [chk("observations", "eq", obs["full"], "全月观察数"),
         chk("apps.0.key", "eq", top_app("full"), "占比第一的应用"),
         chk("apps.0.observations", "eq", by_app["full"][top_app("full")], "它的观察数")],
        corpus, tool_facts,
        "是 %s（%s），%d / %d 条观察，约 %.1f%%。"
        % (name(top_app("full")), top_app("full"), by_app["full"][top_app("full")],
           obs["full"], 100.0 * by_app["full"][top_app("full")] / obs["full"]),
        [name(top_app("full"))],
        {"window_name": "full", "mcp_tool": "get_patterns", "note": ""}))

    out.append(_tool_q(
        "pat-09", CLASS_PATTERN, "我最常在哪两个应用之间来回切换？",
        "get_patterns", ["patterns", "--start", str(W["full"][0]), "--end", str(W["full"][1])] + tz,
        W["full"],
        [chk("transitions.0.from", "eq", tr["from"], "最常切换对的起点"),
         chk("transitions.0.to", "eq", tr["to"], "最常切换对的终点"),
         chk("transitions.0.count", "eq", tr["count"], "次数（同屏相邻、间隔 <= 90 s）"),
         chk("transitionPairs", "eq", tool_facts["transition_pairs"], "不同的切换对个数")],
        corpus, tool_facts,
        "最常见的是 %s → %s，共 %d 次（同一块屏上相邻两条观察换了应用且间隔不超过 90 s）。"
        % (name(tr["from"]), name(tr["to"]), tr["count"]),
        [name(tr["from"]), name(tr["to"])],
        {"window_name": "full", "mcp_tool": "get_patterns", "evidence_app": tr["from"],
         "note": "第二名 %d 次，与第一名差 %d 次，排序不会因为并列翻转"
                 % (tr["runner_up"], tr["count"] - tr["runner_up"])}))

    out.append(_tool_q(
        "pat-10", CLASS_PATTERN, "%s 那一周我有过连续 25 分钟以上没被打断的工作块吗？" % w1_name,
        "get_patterns", ["patterns", "--start", str(w1_lo), "--end", str(w1_hi)] + tz, W["week1"],
        [chk("focus.count", "eq", 0, "连续工作块个数"),
         chk("focus.minMinutes", "eq", 25, "4.3 的 25 分钟门槛")],
        corpus, tool_facts,
        "没有：一个都没有。连续工作块要求序列里不能出现 unknown 观察（权限丢失 / 超时 / 锁定），"
        "而合成流里每 10 条就有约 1 条 unknown，凑不出 25 分钟。",
        ["没有"],
        {"window_name": "week1", "mcp_tool": "get_patterns",
         "note": "这道题的正确答案是 0，用来验证工具不会为了给答案而编一个块出来"}))

    vscode = "com.microsoft.VSCode"
    out.append(_tool_q(
        "pat-11", CLASS_PATTERN, "%s 那一周我在 VS Code 上出现了多少条记录？" % w1_name,
        "get_item", ["item", "--app", vscode, "--start", str(w1_lo), "--end", str(w1_hi)] + tz,
        W["week1"],
        [chk("observations", "eq", by_app["week1"].get(vscode, 0), "区间内该应用的观察数"),
         chk("key", "eq", vscode, "查的就是这个 bundle_id")],
        corpus, tool_facts,
        "%d 条。" % by_app["week1"].get(vscode, 0),
        [str(by_app["week1"].get(vscode, 0))],
        {"window_name": "week1", "mcp_tool": "get_item", "evidence_app": vscode, "note": ""}))

    out.append(_tool_q(
        "pat-12", CLASS_PATTERN, "最近 7 天每天各有多少条记录？",
        "get_timeline", ["timeline", "--start", str(W["last7d"][0]), "--end", str(W["last7d"][1]),
                         "--granularity", "day"] + tz, W["last7d"],
        [chk("buckets", "len", 7, "7 个日桶"),
         chk("buckets.*.observations", "sum_eq", obs["last7d"], "7 个桶之和 = 区间总数"),
         chk("buckets.*.observations", "all_le", per_day, "没有哪天超过满格 %d 条" % per_day)],
        corpus, tool_facts,
        "7 天合计 %d 条，每天 %d 条上下。" % (obs["last7d"], per_day), [str(obs["last7d"])],
        {"window_name": "last7d", "mcp_tool": "get_timeline", "note": ""}))

    out.append(_tool_q(
        "pat-13", CLASS_PATTERN, "%s 那天按小时看，我的记录是怎么分布的？" % d04,
        "get_timeline", ["timeline", "--start", str(W["day04"][0]), "--end", str(W["day04"][1]),
                         "--granularity", "hour"] + tz, W["day04"],
        [chk("buckets", "len", 24, "24 个小时桶"),
         chk("buckets.*.observations", "sum_eq", obs["day04"], "24 个桶之和 = 当天总数"),
         chk("buckets.*.observations", "all_le", per_day // 24,
             "没有哪个小时超过满格 %d 条" % (per_day // 24))],
        corpus, tool_facts,
        "24 个小时各 %d 条上下，当天合计 %d 条。" % (per_day // 24, obs["day04"]),
        [str(obs["day04"])],
        {"window_name": "day04", "mcp_tool": "get_timeline", "note": ""}))

    term_app = "com.apple.Terminal"
    out.append(_tool_q(
        "pat-14", CLASS_PATTERN, "整个月我在终端里出现过多少次？",
        "get_item", ["item", "--app", term_app] + tz, W["full"],
        [chk("observations", "eq", by_app["full"].get(term_app, 0), "全月该应用的观察数"),
         chk("key", "eq", term_app, "查的就是这个 bundle_id"),
         chk("kind", "eq", "app", "get_item 的对象类型")],
        corpus, tool_facts,
        "共 %d 条。" % by_app["full"].get(term_app, 0),
        [str(by_app["full"].get(term_app, 0))],
        {"window_name": "full", "mcp_tool": "get_item", "evidence_app": term_app, "note": ""}))

    # ---------------- 最近活动 8 题 ----------------
    at_end = corpus["end_ms"] - 1
    at_mid = corpus["start_ms"] + 15 * DAY_MS - 1

    def rec_cli(minutes, max_items=None, at=None):
        cli = ["recent", "--minutes", str(minutes)]
        if max_items is not None:
            cli += ["--max-items", str(max_items)]
        cli += ["--at", str(at if at is not None else at_end)] + tz
        return cli

    out.append(_tool_q(
        "rec-01", CLASS_RECENT, "库里最后这半小时我在做什么？",
        "recent_activity", rec_cli(30), W["last30m"],
        [chk("observations", "eq", obs["last30m"], "30 分钟窗口里的存活观察数"),
         chk("minutes", "eq", 30, "问的就是 30 分钟")],
        corpus, tool_facts,
        "最后半小时共 %d 条观察，占得最多的是 %s。"
        % (obs["last30m"], name(top_app("last30m"))),
        [name(top_app("last30m"))],
        {"window_name": "last30m", "mcp_tool": "recent_activity", "note": ""}))

    out.append(_tool_q(
        "rec-02", CLASS_RECENT, "最后半小时里哪个应用占得最多？",
        "recent_activity", rec_cli(30), W["last30m"],
        [chk("apps.0.key", "eq", top_app("last30m"), "聚合里排第一的应用"),
         chk("apps.0.observations", "eq", by_app["last30m"][top_app("last30m")], "它的条数")],
        corpus, tool_facts,
        "%s（%s），%d 条。" % (name(top_app("last30m")), top_app("last30m"),
                            by_app["last30m"][top_app("last30m")]),
        [name(top_app("last30m"))],
        {"window_name": "last30m", "mcp_tool": "recent_activity", "note": ""}))

    out.append(_tool_q(
        "rec-03", CLASS_RECENT, "最后一小时我一共有多少条记录？",
        "recent_activity", rec_cli(60), W["last60m"],
        [chk("observations", "eq", obs["last60m"], "60 分钟窗口里的存活观察数")],
        corpus, tool_facts,
        "%d 条。" % obs["last60m"], [str(obs["last60m"])],
        {"window_name": "last60m", "mcp_tool": "recent_activity", "note": ""}))

    out.append(_tool_q(
        "rec-04", CLASS_RECENT, "最后 5 分钟我在哪个应用里？",
        "recent_activity", rec_cli(5), W["last5m"],
        [chk("observations", "eq", obs["last5m"], "5 分钟窗口里的存活观察数"),
         chk("apps.0.key", "eq", top_app("last5m"), "排第一的应用")],
        corpus, tool_facts,
        "共 %d 条观察，主要在 %s。" % (obs["last5m"], name(top_app("last5m"))),
        [name(top_app("last5m"))],
        {"window_name": "last5m", "mcp_tool": "recent_activity", "note": ""}))

    out.append(_tool_q(
        "rec-05", CLASS_RECENT, "给我最后半小时的 5 条摘要。",
        "recent_activity", rec_cli(30, max_items=5), W["last30m"],
        [chk("items", "len", 5, "只要 5 条"),
         chk("truncated", "eq", True, "半小时有 %d 条，5 条一定是截断的" % obs["last30m"]),
         chk("items.*.summaryTokens", "all_le", 100, "每条摘要 <= 100 token")],
        corpus, tool_facts,
        "最后半小时共 %d 条观察，这里给最新的 5 条摘要（每条不超过 100 token）。" % obs["last30m"],
        ["5"],
        {"window_name": "last30m", "mcp_tool": "recent_activity",
         "note": "recent_activity 每条 <= 100 token 是 4.3 / T14 的口径"}))

    out.append(_tool_q(
        "rec-06", CLASS_RECENT, "把最后 24 小时的上下文给我一份 2000 token 以内的摘要。",
        "get_context", ["context", "--hours", "24", "--max-tokens", "2000",
                        "--at", str(at_end)] + tz, W["last24h"],
        [chk("maxTokens", "eq", 2000, "预算 2000 token"),
         chk("usedTokens", "le", 2000, "用掉的不超过预算"),
         chk("hours", "eq", 24, "问的是 24 小时"),
         chk("snippets", "ge", 1, "至少给出一条片段")],
        corpus, tool_facts,
        "最后 24 小时的上下文摘要在 2000 token 预算内给出（超出部分标 truncated）。",
        ["24"],
        {"window_name": "last24h", "mcp_tool": "get_context", "note": ""}))

    out.append(_tool_q(
        "rec-07", CLASS_RECENT, "最后两小时我一共记录了多少条？",
        "recent_activity", rec_cli(120), W["last120m"],
        [chk("observations", "eq", obs["last120m"], "120 分钟窗口里的存活观察数")],
        corpus, tool_facts,
        "%d 条。" % obs["last120m"], [str(obs["last120m"])],
        {"window_name": "last120m", "mcp_tool": "recent_activity", "note": ""}))

    out.append(_tool_q(
        "rec-08", CLASS_RECENT, "第 15 天结束前的那半小时我在做什么？",
        "recent_activity", rec_cli(30, at=at_mid), W["mid30m"],
        # 期望值必须取 mid30m：题面、answer、窗口、`--at` 都是「第 15 天结束前的那半小时」。
        # （原来写的是 obs["last30m"]，在均匀网格语料上两个 30 分钟窗口条数碰巧相等，
        #   断言才一直是绿的——语料一变就成了假绿。M2 d 收尾修复。）
        [chk("observations", "eq", obs["mid30m"], "30 分钟窗口里的存活观察数"),
         chk("apps.0.key", "eq", top_app("mid30m"), "排第一的应用")],
        corpus, tool_facts,
        "共 %d 条观察，主要在 %s。" % (obs["mid30m"], name(top_app("mid30m"))),
        [name(top_app("mid30m"))],
        {"window_name": "mid30m", "mcp_tool": "recent_activity",
         "note": "--at 落在语料中间，验证 recent_activity 不只对「现在」成立"}))

    return out


# --------------------------------------------------------------------------- #
# 3. 扫一遍 JSONL，算真值
# --------------------------------------------------------------------------- #

def scan(jsonl_path, specs, probes, corpus, windows=None):
    """一次遍历同时算：每题的真值、每题的语料事实、每个删除 probe 的观察 id，
    以及 M2 d / T17 工具题要用的**精确计数**（`windows` 是 name -> (start_ms, end_ms)）。

    工具题的断言只用条数：观察是 10 s 一格的均匀网格，条数是严格可算的；
    dwell 秒数受 `source_state`（10% 的 permission_lost / timeout 不计 dwell）影响，不拿来断言。
    """
    windows = windows or {}
    win_total = {name: 0 for name in windows}
    win_by_app = {name: {} for name in windows}
    transitions = {}                       # (from, to) -> 次数，同屏相邻且间隔 <= 90 s
    last_by_display = {}                   # display_id -> (ts, bundle)
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

            will_delete = False
            for p in win_probes:
                if p["start"] <= ts < p["end"]:
                    probe_ids[p["id"]].append(oid)
                    will_delete = True
            for p in text_probes:
                if p["term_low"] in low:
                    probe_ids[p["id"]].append(oid)
                    will_delete = True
            for p in host_probes:
                if host == p["term_low"]:
                    probe_ids[p["id"]].append(oid)
                    will_delete = True

            # 工具题的计数**按删除之后的库算**：`deletions` 是查询集的一部分，
            # 建库之后、评估之前就执行了，所以台账 / 模式 / 最近活动看到的是删完的样子
            # （和每道题的 `relevant` 已经扣掉被删观察是同一条口径）。
            # 切换对也一样：被删的观察不参与"相邻"，删掉一整段之后前后两条的间隔
            # 会超过 90 s 的停留上限，那就不算一次切换——与 get_patterns 的定义一致。
            if not will_delete:
                for name, (lo, hi) in windows.items():
                    if lo <= ts < hi:
                        win_total[name] += 1
                        if bundle:
                            win_by_app[name][bundle] = win_by_app[name].get(bundle, 0) + 1
                display = rec.get("display_id")
                prev = last_by_display.get(display)
                if prev is not None and bundle and prev[1] != bundle and ts - prev[0] <= 90_000:
                    transitions[(prev[1], bundle)] = transitions.get((prev[1], bundle), 0) + 1
                if bundle:
                    last_by_display[display] = (ts, bundle)

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
                elif rule == "url":
                    hit = (url and t in url) or (t in low)
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
    top_pairs = sorted(transitions.items(), key=lambda kv: (-kv[1], kv[0]))
    tool_facts = {
        "window_observations": win_total,
        "window_by_app": {n: dict(sorted(v.items(), key=lambda kv: (-kv[1], kv[0])))
                          for n, v in win_by_app.items()},
        "top_transition": ({"from": top_pairs[0][0][0], "to": top_pairs[0][0][1],
                            "count": top_pairs[0][1],
                            "runner_up": top_pairs[1][1] if len(top_pairs) > 1 else 0}
                           if top_pairs else None),
        "transition_pairs": len(transitions),
    }
    return truth, facts, probe_ids, tool_facts


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
    if spec["rule"] == "url":
        ans = "有，共 %d 条观察的地址落在 %s 下，%s；前台应用是 %s。" % (n, spec["term"], span, app_text)
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
    for qid, cls, q, prefix, term, rule, win, expect, reason in SPECS + SPECS_M2_SEARCH:
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

    windows = tool_windows(corpus)
    truth, facts, probe_ids, tool_facts = scan(os.path.expanduser(args.jsonl), specs, probes,
                                               corpus, windows)

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
    n_none = sum(1 for s in specs if s["expect"] == "none")
    if n_none < 8:
        problems.append("负例 / 已删除题只有 %d 道，少于 8 道" % n_none)
    for p in probes:
        if not probe_ids[p["id"]]:
            problems.append("删除项 %s 一条都没匹配到" % p["id"])
    # --- 工具题（22 道）：真值是聚合量，不进上面的真值扫描 ---
    tool_questions = build_tool_questions(corpus, tool_facts, args.limit)

    counts = {}
    for s in specs:
        counts[s["class"]] = counts.get(s["class"], 0) + 1
    for t in tool_questions:
        counts[t["class"]] = counts.get(t["class"], 0) + 1
    if counts != QUOTA:
        problems.append("六类配额不符：实际 %r，期望 %r" % (counts, QUOTA))
    if problems:
        raise SystemExit("查询集自检失败：\n  - " + "\n  - ".join(problems))

    # --- 留出题 30 道（计划 4.3「留出 30 题作独立测试」）---
    #
    # 分两段，为的是**原 60 题的留出标记一道都不换**（M1 那 18 道原样留着）：
    #   1. M1 的 60 题：每类按 id 排序后第 3、6、9… 题（k % 3 == 2）→ 18 道；
    #   2. M2 新增的 40 题：按 id 排序后每 10 题取第 3 / 6 / 9 道（k % 10 ∈ {2,5,8}）→ 12 道。
    # 两段都没有随机数。
    m1_ids = {t[0] for t in SPECS}
    by_class = {}
    for s in specs:
        if s["id"] in m1_ids:
            by_class.setdefault(s["class"], []).append(s["id"])
    holdout = set()
    for cls, ids in by_class.items():
        for k, qid in enumerate(sorted(ids)):
            if k % 3 == 2:
                holdout.add(qid)
    new_ids = sorted([s["id"] for s in specs if s["id"] not in m1_ids]
                     + [t["id"] for t in tool_questions])
    for k, qid in enumerate(new_ids):
        if k % 10 in (2, 5, 8):
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
        if s["rule"] in ("host", "url"):
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
            "truth_mode": "relevant_ids",
            "tool": "search",
            "answer": answer,
            "answer_check": check,
            "answer_source": "合成语料全量重算",
            "authored": AUTHORED if s["id"] in m1_ids else AUTHORED_M2,
            "notes": "",
        })
    queries.extend(tool_questions)
    for q in queries:
        q["holdout"] = q["id"] in holdout
        q["difficulty"] = difficulty_of(q)
    queries.sort(key=lambda r: (list(CLASSES).index(r["class"]), r["id"]))

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
                       "真值对 JSONL 全量重算，再按题目的时间窗裁剪，最后扣掉 deletions 删掉的观察。"
                       "工具题（tool != search）问的是聚合量，relevant 留空、truth_mode = evidence_match，"
                       "判据是 tool_check（由 verify-tools 真的调 brosis-store 核对）。"),
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

    diff_counts = {}
    for q in queries:
        diff_counts[q["difficulty"]] = diff_counts.get(q["difficulty"], 0) + 1
    tool_counts = {}
    for q in queries:
        tool_counts[q["tool"]] = tool_counts.get(q["tool"], 0) + 1
    rels = [q["relevant_count"] for q in queries if q["relevant_count"] is not None]
    summary = {
        "out": out,
        "queries": len(queries),
        "by_class": counts,
        "by_difficulty": diff_counts,
        "by_tool": tool_counts,
        "holdout": sorted(holdout),
        "holdout_count": len(holdout),
        "holdout_by_class": {c: sum(1 for q in queries
                                    if q["class"] == c and q["holdout"]) for c in CLASSES},
        "hit_queries": sum(1 for q in queries if q["expect"] == "hit"),
        "none_queries": n_none,
        "tool_queries": len(tool_questions),
        "deleted_observations": len(deleted),
        "relevant_total": sum(rels),
        "relevant_max": max(rels),
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

    def q(qid, cls, question, search, expect_bucket, relevant, subs, note, expect_triage=None):
        return {
            "id": qid, "class": cls, "holdout": False, "q": question, "search": search,
            "expect": "hit", "unanswerable_reason": None,
            "evidence": {"text_substrings": subs, "apps": [], "time_window": None,
                         "urls": [], "paths": []},
            "relevant": relevant, "relevant_count": len(relevant),
            "answer": "（变异检验用，不判内容）",
            "answer_check": {"must_include": [], "must_not_include": []},
            "answer_source": "变异检验", "authored": AUTHORED,
            "difficulty": "难", "tool": "search", "truth_mode": "relevant_ids",
            "notes": "expect_bucket=%s；expect_triage=%s；%s"
                     % (expect_bucket, expect_triage or expect_bucket, note),
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
        # M2 d / T17：第五个桶「别名不统一」。同一道题换个说法去检索——字面通道
        # （bigram phrase + 子串复核，D22 / 3.4）必然一条都召不回，而证据全都活着。
        # 第一阶段只能判到「索引漏召回」；`triage_failures.py` 靠"检索串与期望答案
        # 没有公共字面"把它再分出来。这是 4.4 里「别名不统一」与「索引漏召回」的分界。
        q("mut-05-alias", CLASS_DETAIL, "我记的那套「概念关系网络」是怎么写的？",
          {"q": "概念关系网络", "start": None, "end": None, "app": None, "limit": 10},
          "索引漏召回", list(det["relevant"]), ["知识图谱"],
          "换了说法的同一道题（原题 det-01「知识图谱」）：真值全活着，字面通道召不回",
          expect_triage="别名不统一"),
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
    triage = {}
    if args.triage:
        tr = json.load(open(os.path.expanduser(args.triage), encoding="utf-8"))
        triage = {r["id"]: r["final_bucket"] for r in tr["rows"]}
    rows = []
    for q in qs["queries"]:
        want = q["notes"].split("expect_bucket=")[1].split("；")[0]
        want_triage = q["notes"].split("expect_triage=")[1].split("；")[0]
        row = {"id": q["id"], "expect_bucket": want, "bucket": got.get(q["id"]),
               "match": got.get(q["id"]) == want}
        if triage:
            row["expect_triage"] = want_triage
            row["triage_bucket"] = triage.get(q["id"])
            row["triage_match"] = triage.get(q["id"]) == want_triage
            row["match"] = row["match"] and row["triage_match"]
        rows.append(row)
    payload = {"rows": rows, "all_match": all(r["match"] for r in rows),
               "checked_triage": bool(triage)}
    if args.out:
        out = os.path.expanduser(args.out)
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    if not payload["all_match"]:
        raise SystemExit("变异检验没对上：归因分类有问题")


# --------------------------------------------------------------------------- #
# 7. verify-tools：真的调 brosis-store 跑一遍 22 道工具题，逐条核对 tool_check
#
# 工具题的"标准答案"是从 JSONL 算出来的聚合量。不真跑一遍的话，这些数只是我这边的
# 一厢情愿；跑一遍才知道存储层的口径与生成侧的模拟是不是同一个（和 apply-deletions
# 的对账是同一个思路）。
# --------------------------------------------------------------------------- #

def resolve_path(obj, path):
    """点号路径。数字段 = 数组下标；`*` = 数组的每个元素（返回列表）。找不到抛 KeyError。"""
    cur = obj
    for k, seg in enumerate(path.split(".")):
        if seg == "*":
            if not isinstance(cur, list):
                raise KeyError("%s：`*` 之前不是数组" % path)
            rest = ".".join(path.split(".")[k + 1:])
            return [resolve_path(x, rest) if rest else x for x in cur]
        if isinstance(cur, list):
            cur = cur[int(seg)]
        elif isinstance(cur, dict):
            if seg not in cur:
                raise KeyError("%s：没有键 %s" % (path, seg))
            cur = cur[seg]
        else:
            raise KeyError("%s：在 %s 处走不下去" % (path, seg))
    return cur


def check_one(out, chk):
    path, op, want = chk["path"], chk["op"], chk["value"]
    if isinstance(want, str) and want.startswith("@"):     # 与另一条路径比
        want = resolve_path(out, want[1:])
    got = resolve_path(out, path)
    if op == "eq":
        ok, shown = got == want, got
    elif op == "len":
        ok, shown = len(got) == want, len(got)
    elif op == "all_eq":
        ok, shown = all(x == want for x in got), sorted(set(got))[:5]
    elif op == "sum_eq":
        ok, shown = sum(got) == want, sum(got)
    elif op == "all_le":
        ok, shown = all(x <= want for x in got), max(got) if got else None
    elif op == "le":
        ok, shown = got <= want, got
    elif op == "ge":
        ok, shown = (len(got) if isinstance(got, list) else got) >= want, \
                    (len(got) if isinstance(got, list) else got)
    else:
        raise SystemExit("未知断言 op：%s" % op)
    return {"path": path, "op": op, "expect": want, "got": shown, "ok": bool(ok),
            "note": chk.get("note", "")}


def verify_tools(args):
    qs = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    if qs.get("schema") != SCHEMA:
        raise SystemExit("不认识的查询集：%r" % qs.get("schema"))
    rows = []
    for q in qs["queries"]:
        if q.get("tool", "search") == "search":
            continue
        cli = q["tool_call"]["cli"]
        cmd = [os.path.expanduser(args.bin), cli[0],
               "--dir", os.path.expanduser(args.dir),
               "--key-file", os.path.expanduser(args.key_file)] + cli[1:]
        t0 = time.time()
        proc = subprocess.run(cmd, capture_output=True, text=True)
        elapsed = (time.time() - t0) * 1000
        if proc.returncode != 0:
            rows.append({"id": q["id"], "tool": q["tool"], "ok": False,
                         "error": proc.stderr[-2000:], "checks": []})
            continue
        out = json.loads(proc.stdout)
        checks = []
        for chk in q.get("tool_check", []):
            try:
                checks.append(check_one(out, chk))
            except (KeyError, IndexError, ValueError) as e:
                checks.append({"path": chk["path"], "op": chk["op"], "expect": chk["value"],
                               "got": None, "ok": False, "note": "取值失败：%s" % e})
        rows.append({"id": q["id"], "tool": q["tool"],
                     "mcp_tool": q["tool_call"]["mcp_tool"],
                     "cli": " ".join(cli), "elapsed_ms": elapsed,
                     "checks": checks, "ok": all(c["ok"] for c in checks)})
    failed = [r["id"] for r in rows if not r["ok"]]
    payload = {"queries": len(rows), "checks": sum(len(r["checks"]) for r in rows),
               "failed": failed, "all_ok": not failed, "rows": rows}
    if args.out:
        out_p = os.path.expanduser(args.out)
        os.makedirs(os.path.dirname(os.path.abspath(out_p)), exist_ok=True)
        with open(out_p, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    print(json.dumps({k: payload[k] for k in ("queries", "checks", "failed", "all_ok")},
                     ensure_ascii=False, indent=1))
    if failed:
        raise SystemExit("工具题断言没过：%s" % ",".join(failed))
    return payload


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
    v.add_argument("--triage", default=None,
                   help="triage_failures.py 的 JSON：一并核对六类归因（expect_triage）")
    v.add_argument("--out", default=None)

    t = sub.add_parser("verify-tools", help="真的调 brosis-store 跑一遍工具题，逐条核对 tool_check")
    t.add_argument("--queryset", required=True)
    t.add_argument("--bin", required=True)
    t.add_argument("--dir", required=True)
    t.add_argument("--key-file", required=True)
    t.add_argument("--out", default=None)

    args = p.parse_args(argv)
    if args.cmd == "gen":
        gen(args)
    elif args.cmd == "apply-deletions":
        apply_deletions(args)
    elif args.cmd == "mutate":
        mutate(args)
    elif args.cmd == "verify-tools":
        verify_tools(args)
    else:
        verify_mutations(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
