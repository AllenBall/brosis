#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M0 · T3 全文检索分词方案对照。

对应《实施计划》3.4 检索设计与实验 E2 的离线部分，落实《调研方案评审》F3 的修正：
  - unicode61 不会逐字切分中文；
  - trigram detail=column 不支持 phrase 查询；
  - 1~2 字查询需要受时间/应用范围限制的扫描兜底；
  - URL / 路径等精确字段独立成列，不经 FTS。

只用标准库 sqlite3。方案 D（jieba）需要额外依赖，运行方式见 README。

用法:
    python3 tools/bench/fts_compare.py                      # 跑 A/B/C/E/扫描，跳过 D
    uv run --no-project --python "$(which python3)" \
        --with jieba python tools/bench/fts_compare.py      # 含方案 D

输出:
    tools/bench/results/fts_compare_<date>.md
    tools/bench/results/fts_compare_<date>.json
中间数据库写到 ~/Library/Caches/brosis-build/t3-fts/（不进项目目录）。
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import re
import sqlite3
import statistics
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent.parent
DEFAULT_BUILD = Path.home() / "Library" / "Caches" / "brosis-build" / "t3-fts"

# ---------------------------------------------------------------- 文本工具

CJK_RANGES = (
    (0x3400, 0x4DBF),   # 扩展 A
    (0x4E00, 0x9FFF),   # 基本区
    (0xF900, 0xFAFF),   # 兼容区
)


def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in CJK_RANGES)


def bigram_join(text: str) -> str:
    """方案 B：把汉字连续段切成重叠 bigram，其余片段原样保留，统一用空格分隔。

    "知识图谱 research" -> "知识 识图 图谱  research"
    长度为 1 的汉字连续段保留该字本身（此时只能靠扫描回退，见 §6）。
    """
    parts: list[str] = []
    run: list[str] = []
    other: list[str] = []

    def flush_run() -> None:
        if not run:
            return
        s = "".join(run)
        if len(s) == 1:
            parts.append(s)
        else:
            parts.extend(s[i:i + 2] for i in range(len(s) - 1))
        run.clear()

    def flush_other() -> None:
        if other:
            parts.append("".join(other))
            other.clear()

    for ch in text:
        if is_cjk(ch):
            flush_other()
            run.append(ch)
        else:
            flush_run()
            other.append(ch)
    flush_run()
    flush_other()
    return " ".join(parts)


_JIEBA = None


def jieba_available() -> bool:
    global _JIEBA
    if _JIEBA is None:
        try:
            import jieba  # type: ignore

            jieba.setLogLevel(60)
            _JIEBA = jieba
        except Exception:
            _JIEBA = False
    return bool(_JIEBA)


def jieba_join(text: str) -> str:
    assert jieba_available()
    return " ".join(t for t in _JIEBA.lcut(text) if t.strip())


def fts_phrase(s: str) -> str:
    """把任意字符串包成 FTS5 phrase 字面量。"""
    return '"' + s.replace('"', '""') + '"'


def like_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# ---------------------------------------------------------------- 查询路由

URL_RE = re.compile(r"^(?:https?://\S+|[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}(?:/\S*)?)$")
ABS_PATH_RE = re.compile(r"^~?(?:/[^/\s][^/]*)+/?$")
REL_PATH_RE = re.compile(r"^[\w.㐀-鿿-]+(?:/[\w.㐀-鿿-]+)+$")


def route_kind(q: str) -> str:
    """精确字段路由：判断查询是不是 URL / 域名 / 路径。"""
    s = q.strip()
    if ABS_PATH_RE.match(s):
        return "path"
    if URL_RE.match(s):
        return "url"
    if REL_PATH_RE.match(s):
        return "path"
    return "text"


def is_short_cjk(q: str) -> bool:
    s = q.strip()
    return 1 <= len(s) <= 2 and all(is_cjk(c) for c in s)


# ---------------------------------------------------------------- 语料生成

APPS_BY_KIND = {
    "zh_doc": ["飞书", "备忘录", "邮件", "VS Code"],
    "mixed": ["飞书", "Chrome", "VS Code", "备忘录"],
    "code": ["Xcode", "VS Code"],
    "url": ["Safari", "Chrome"],
    "path": ["Finder", "VS Code", "Terminal"],
    "chat_feishu": ["飞书"],
    "chat_wechat": ["微信"],
    "terminal": ["Terminal"],
}

KIND_COUNTS = {
    "zh_doc": 520,
    "mixed": 420,
    "code": 420,
    "url": 400,
    "path": 320,
    "chat_feishu": 420,
    "chat_wechat": 340,
    "terminal": 360,
}

ZH_ACTOR = [
    "采集器", "存储服务", "MCP 接口", "夜间任务", "评审意见", "调研报告", "处理任务",
    "模型管理器", "嵌入索引", "台账生成", "会话切分器", "同步通道", "配额守护", "审计模块",
]
ZH_TOPIC = [
    "采集覆盖率", "会话切分", "台账口径", "删除级联", "索引体积", "查询延迟", "权限状态",
    "帧门控", "文本版本", "出现记录", "应用适配规则", "可见范围", "保留期限", "配额策略",
    "同步冲突", "设备标识", "密钥轮换", "锁定状态机", "审计日志", "证据展开", "回退阈值",
    "热状态判定", "输入计数", "窗口标题", "去重口径",
]
ZH_VERB = [
    "需要再确认一遍", "已经按评审改掉了", "下周排期", "还没有实测数据", "风险等级是中",
    "要写进验收清单", "先按草稿执行", "等你确认后再动", "已经落库", "改成可配置参数",
    "暂时挂起", "拆成两个任务", "留到 M2 再做", "本轮不做取舍",
]
ZH_EXTRA = [
    "这条结论只在本机成立，换机器要重测。",
    "验收口径写在附录里，别再口头传。",
    "如果磁盘配额到 80%，先提示再删最旧的一段。",
    "锁屏时库保持打开，接电时夜间任务照跑。",
    "权限丢失、读取超时、用户未活动要分成不同状态，不要混成一个空。",
    "证据必须能完整取回，删除后所有入口都不能再返回。",
    "近似重复只用于归组，不删唯一证据。",
    "这一段是给评审看的，别直接抄进产品文案。",
]

EN_TERMS = [
    "SQLite", "FTS5", "SQLCipher", "unicode61", "trigram", "bigram", "tokenizer",
    "embedding", "throughput", "checkpoint", "accessibility", "Vision", "OCR", "MLX",
    "Metal", "zstd", "WAL", "bm25", "recall", "precision", "latency", "sandbox",
    "entitlement", "TCC", "AXUIElement", "NSWorkspace", "CGWindow", "Swift", "Python",
    "dbstat", "vacuum", "rowid", "snapshot",
]

IDENTS = [
    "parseObservation", "TextVersionStore", "kAXDocument", "wal_checkpoint",
    "bigram_tokenize", "didActivateApplicationNotification", "sqlite3_prepare_v2",
    "OccurrenceWriter", "LedgerBuilder", "FrameGate", "AXReader", "CaptureError",
    "normalizeLocator", "dhashDistance", "rebuildIndex", "ObservationStore",
    "makeThumbnail", "flushPendingOccurrences",
]

ERRCODES = [
    "E1042", "E2201", "E3310", "-25300", "-128", "0x80070005", "SQLITE_BUSY",
    "SQLITE_CORRUPT", "errSecItemNotFound", "OSStatus -60005", "E1188",
]

HOSTS = [
    "sqlite.org", "www.sqlite.org", "developer.apple.com", "github.com",
    "huggingface.co", "news.ycombinator.com", "lark-doc.example.com",
    "docs.python.org", "ml-explore.github.io", "stackoverflow.com",
]

URL_TAILS = [
    "/fts5.html", "/fts5.html#tokenizers", "/documentation/appkit/nsworkspace",
    "/asg017/sqlite-vec", "/ml-explore/mlx-swift", "/wiki/BroSisM0", "/lang_expr.html",
    "/questions/12345678/how-to-tokenize-chinese-in-fts5", "/3/library/sqlite3.html",
    "/mlx-swift/documentation/mlx", "/Qwen/Qwen3-Embedding-0.6B", "/item?id=41234567",
]

PAGE_TITLES = [
    "SQLite FTS5 Extension", "NSWorkspace | Apple Developer Documentation",
    "sqlite-vec: a vector search SQLite extension", "mlx-swift", "brosis M0 计划",
    "How to tokenize Chinese in FTS5", "sqlite3 — DB-API 2.0 interface",
    "MLX Swift Documentation", "Qwen3-Embedding-0.6B", "Hacker News",
]

DIRS = [
    "<项目目录>",
    "~/Library/Caches/brosis-build",
    "~/Developer/brosis-app",
    "/usr/local/lib",
    "~/Downloads",
    "/private/tmp",
]
FILENAMES = [
    "brosis.sqlite", "AXReader.swift", "LedgerBuilder.swift", "fts_review_probe.py",
    "ocr_bench.swift", "可行性调研报告.md", "调研方案评审.md", "launch.json",
    "Info.plist", "capture.log", "index.wal", "thumbs.db",
]

NAMES_FEISHU = ["张伟", "李娜", "王芳", "陈磊", "赵敏", "周杰", "Alex", "Nina"]
NAMES_WECHAT = ["妈妈", "老王", "小林", "陈磊", "房东", "我"]
GROUPS = ["brosis 研发", "M0 实验组", "客户端小组", "周会同步", "工具链"]

CHAT_MSGS_WORK = [
    "这个我先看一下，下午给你结论。",
    "刚跑完一轮，数字待会儿贴到文档里。",
    "麻烦把日志发我一份，我这边复现不了。",
    "评审那几条我都改了，你再扫一眼。",
    "今天先到这，明天继续。",
    "这个口径要写清楚，不然验收会吵。",
    "我这边的机器是 16 GB，跑不动大模型。",
    "先别合，等我测完延迟。",
    "文档我更新到最新版了。",
    "这条我拉了个新分支在弄。",
]
CHAT_MSGS_LIFE = [
    "晚上回来带点水果。",
    "周末有空吗，一起吃个饭。",
    "快递放门口了。",
    "明天降温，多穿点。",
    "收到，谢谢。",
    "我到楼下了。",
]

TERM_CMDS = [
    "sqlite3 brosis.sqlite '.tables'",
    "swiftc -O -parse-as-library fm_check.swift -o fm_check",
    "python3 tools/bench/fts_review_probe.py",
    "codesign --verify --deep --strict Brosis.app",
    "xcrun notarytool submit Brosis.zip --keychain-profile brosis",
    "log show --predicate 'subsystem == \"com.brosis.capture\"' --last 10m",
    "du -sh ~/Library/Caches/brosis-build",
    "git status --short",
    "sqlite3 brosis.sqlite 'PRAGMA wal_checkpoint(TRUNCATE);'",
    "vm_stat | head -5",
]
TERM_OUT = [
    "apps  observations  occurrences  text_versions  sessions  ledgers",
    "warning: 'value(for:)' is deprecated in macOS 26.0",
    "error: The operation couldn't be completed. (OSStatus error -25300.)",
    "Compiling BrosisCapture (12 sources)",
    "Build succeeded in 4.31s",
    "zsh: killed     brosis-index (exit code 137)",
    "0  1  0",
    "Pages free:                              123456.",
    "fatal: not a git repository",
    "page_size = 4096, page_count = 51200, freelist_count = 12",
    "index_bytes=4096 wal_bytes=32768",
    "Submission ID received: 8f1e-4a2b-9c33",
]

CODE_TEMPLATES = [
    (
        "// {path}:{line}\n"
        "func {ident}(_ el: AXUIElement) throws -> Observation {{\n"
        "    guard let raw = try el.value(for: {axconst}) else {{\n"
        "        throw CaptureError.missing(\"{axconst}\")   // {err}\n"
        "    }}\n"
        "    return Observation(text: raw, ts: .now)\n"
        "}}"
    ),
    (
        "# {path}:{line}\n"
        "def {ident}(con, rows):\n"
        "    con.executemany(\"INSERT INTO occurrences VALUES (?,?,?,?)\", rows)\n"
        "    con.execute(\"PRAGMA {pragma}\")   # {err}\n"
        "    return len(rows)"
    ),
    (
        "// {path}:{line}\n"
        "let stmt = try db.prepare(\"SELECT rowid FROM text_fts WHERE text_fts MATCH ?\")\n"
        "if status != SQLITE_OK {{ log.error(\"{err} in {ident}\") }}"
    ),
]
AX_CONSTS = ["kAXDocument", "kAXValueAttribute", "kAXFocusedWindowAttribute", "kAXRoleAttribute"]
PRAGMAS = ["wal_checkpoint(TRUNCATE)", "secure_delete=ON", "incremental_vacuum", "journal_mode=WAL"]

# 种植模板分两套，避免制造"人为的分词提示"：
#   纯汉字目标词直接嵌进连续中文里（真实中文没有词间空格，unicode61 会把整段当一个 token）；
#   含拉丁字母/数字/符号的目标词按中文写作习惯用空格或标点隔开（真实文本就是这么写的）。
INJECT_CJK = {
    "zh_doc": "\n关于{TERM}的部分，评审里提到还需要再确认一次。",
    "mixed": "\n这一版把{TERM}的口径写进了文档，M0 结束前不再改。",
    "code": "\n// 复核{TERM}的边界条件后再合并",
    "chat_feishu": "\n{NAME}  {TIME}\n{TERM}这块我今天下午看一下。",
    "chat_wechat": "\n{NAME}  {TIME}\n关于{TERM}我记一下。",
    "terminal": "\n# note: 检查{TERM}后重跑一遍",
    "url": "\n页面里提到{TERM}的用法。",
    "path": "\n备注：这个文件跟{TERM}有关。",
}
INJECT_ASCII = {
    "zh_doc": "\n关于 {TERM} 的部分，评审里提到还需要再确认一次。",
    "mixed": "\n这一版把 {TERM} 的口径写进了文档，M0 结束前不再改。",
    "code": "\n// TODO: 复核 {TERM} 的边界条件",
    "chat_feishu": "\n{NAME}  {TIME}\n{TERM} 这块我今天下午看一下。",
    "chat_wechat": "\n{NAME}  {TIME}\n{TERM} 我记一下。",
    "terminal": "\n# note: {TERM}",
    "url": "\n页面里提到 {TERM}。",
    "path": "\n备注：{TERM}",
}


def gen_corpus(rng: random.Random, queries: list[dict]) -> list[dict]:
    docs: list[dict] = []
    base = datetime(2026, 8, 8, 9, 0, 0)
    doc_id = 0

    def next_ts() -> int:
        # 30 天，工作时间偏多
        day = rng.randrange(0, 30)
        hour = rng.choice([9, 10, 10, 11, 11, 14, 14, 15, 15, 16, 16, 17, 20, 21, 22])
        ts = base + timedelta(days=day, hours=hour - 9, minutes=rng.randrange(0, 60),
                              seconds=rng.randrange(0, 60))
        return int(ts.timestamp())

    def zh_sentences(n: int) -> str:
        out = []
        for _ in range(n):
            r = rng.random()
            if r < 0.65:
                out.append(f"{rng.choice(ZH_ACTOR)}的{rng.choice(ZH_TOPIC)}{rng.choice(ZH_VERB)}。")
            elif r < 0.85:
                out.append(
                    f"这一轮实测 {rng.randrange(500, 9000)} 条观察，索引体积 "
                    f"{rng.randrange(4, 900)} MB，p95 延迟 {rng.randrange(1, 400)} ms。"
                )
            else:
                out.append(rng.choice(ZH_EXTRA))
        return "".join(out)

    for kind, count in KIND_COUNTS.items():
        for _ in range(count):
            doc_id += 1
            app = rng.choice(APPS_BY_KIND[kind])
            url = host = path = None
            title = None
            if kind == "zh_doc":
                title = f"{rng.choice(ZH_ACTOR)}{rng.choice(['纪要', '说明', '草稿', '评审意见'])}"
                text = f"{title}\n" + zh_sentences(rng.randrange(7, 14))
            elif kind == "mixed":
                title = f"{rng.choice(EN_TERMS)} 与 {rng.choice(ZH_TOPIC)}"
                lines = [title]
                for _ in range(rng.randrange(6, 11)):
                    lines.append(
                        f"{rng.choice(EN_TERMS)} 的 {rng.choice(ZH_TOPIC)}"
                        f"{rng.choice(ZH_VERB)}，对照 {rng.choice(EN_TERMS)} 再看一遍。"
                    )
                lines.append(
                    f"指标：Recall@10 {rng.randrange(40, 99)}%，"
                    f"p50 {rng.randrange(1, 60)} ms，体积 {rng.randrange(10, 800)} MB。"
                )
                text = "\n".join(lines)
            elif kind == "code":
                path = f"Sources/{rng.choice(['BrosisCapture', 'BrosisStore', 'BrosisMCP'])}/" \
                       f"{rng.choice(['AXReader', 'LedgerBuilder', 'TextIndex', 'FrameGate'])}." \
                       f"{rng.choice(['swift', 'py'])}"
                text = "\n\n".join(
                    rng.choice(CODE_TEMPLATES).format(
                        path=path, line=rng.randrange(10, 900), ident=rng.choice(IDENTS),
                        axconst=rng.choice(AX_CONSTS), err=rng.choice(ERRCODES),
                        pragma=rng.choice(PRAGMAS),
                    ) for _ in range(rng.randrange(2, 4))
                )
                title = path.rsplit("/", 1)[-1]
            elif kind == "url":
                host = rng.choice(HOSTS)
                url = f"https://{host}{rng.choice(URL_TAILS)}"
                title = rng.choice(PAGE_TITLES)
                text = f"{title}\n{url}\n" + zh_sentences(rng.randrange(4, 9)) + \
                       f"\n{rng.choice(EN_TERMS)} / {rng.choice(EN_TERMS)}"
            elif kind == "path":
                d = rng.choice(DIRS)
                f = rng.choice(FILENAMES)
                path = f"{d}/{f}"
                title = f
                text = (f"{f}\n{path}\n{rng.randrange(1, 900)} KB，修改于 "
                        f"2026-0{rng.randrange(7, 10)}-{rng.randrange(10, 29)} "
                        f"{rng.randrange(10, 23)}:{rng.randrange(10, 59)}\n"
                        + zh_sentences(rng.randrange(3, 7)))
            elif kind in ("chat_feishu", "chat_wechat"):
                if kind == "chat_feishu":
                    title = f"群「{rng.choice(GROUPS)}」"
                    names = NAMES_FEISHU
                    pool = CHAT_MSGS_WORK
                else:
                    peer = rng.choice(NAMES_WECHAT)
                    title = f"与 {peer} 的聊天"
                    names = [peer, "我"]
                    pool = CHAT_MSGS_WORK + CHAT_MSGS_LIFE
                lines = [f"{'飞书' if kind == 'chat_feishu' else '微信'} · {title}"]
                for _ in range(rng.randrange(6, 13)):
                    lines.append(
                        f"{rng.choice(names)}  {rng.randrange(9, 23):02d}:{rng.randrange(0, 60):02d}"
                    )
                    lines.append(rng.choice(pool))
                text = "\n".join(lines)
            else:  # terminal
                lines = []
                for _ in range(rng.randrange(4, 8)):
                    lines.append(f"alice@Mac brosis % {rng.choice(TERM_CMDS)}")
                    for _ in range(rng.randrange(2, 5)):
                        lines.append(rng.choice(TERM_OUT))
                text = "\n".join(lines)
                title = "Terminal — brosis"
            docs.append({
                "id": doc_id, "ts": next_ts(), "app": app, "kind": kind,
                "text": text, "url": url, "host": host, "path": path, "title": title,
            })

    # ---- 种植查询目标 ----
    by_kind: dict[str, list[int]] = {}
    for idx, d in enumerate(docs):
        by_kind.setdefault(d["kind"], []).append(idx)

    for spec in queries:
        plant = spec.get("plant")
        if not plant or spec["expect"] != "hit":
            continue
        term = spec["q"]
        pool: list[int] = []
        for k in plant["kinds"]:
            pool.extend(by_kind.get(k, []))
        pool.sort()
        chosen = rng.sample(pool, min(plant["count"], len(pool)))
        for idx in chosen:
            d = docs[idx]
            table = INJECT_CJK if all(is_cjk(c) for c in term) else INJECT_ASCII
            tmpl = table[d["kind"]]
            name = rng.choice(NAMES_FEISHU if d["kind"] == "chat_feishu" else NAMES_WECHAT)
            tm = f"{rng.randrange(9, 23):02d}:{rng.randrange(0, 60):02d}"
            d["text"] += tmpl.format(TERM=term, NAME=name, TIME=tm)
            kindr = route_kind(term)
            # 精确字段只在"该观察本身就是这个 URL / 这个文件"时才写；
            # 聊天正文里提到的链接不会进 url 列，这类命中只能靠 FTS 或扫描。
            if kindr == "url" and d["kind"] == "url":
                full = term if term.startswith("http") else "https://" + term
                d["url"] = full
                m = re.match(r"^https?://([^/]+)", full)
                d["host"] = m.group(1) if m else d["host"]
                d["text"] += f"\n{full}"
            elif kindr == "path" and d["kind"] == "path":
                d["path"] = term
                d["text"] += f"\n{term}"
    return docs


def compute_truth(docs: list[dict], queries: list[dict]) -> dict[str, set[int]]:
    low = [(d["id"], d["text"].lower()) for d in docs]
    truth: dict[str, set[int]] = {}
    for spec in queries:
        q = spec["q"].lower()
        truth[spec["id"]] = {i for i, t in low if q in t}
    return truth


# ---------------------------------------------------------------- 建库

# 注意 COLLATE NOCASE 写在**列**上而不是只写在索引上：SQLite 的 `col = ?` 用列的排序规则，
# 只给索引加 NOCASE 时等值查询用不上该索引（实测见 §7）。复合 (col, ts DESC) 让过滤和排序一次搞定。
DOCS_DDL = """
CREATE TABLE docs(
  id     INTEGER PRIMARY KEY,
  ts     INTEGER NOT NULL,
  app    TEXT NOT NULL,
  kind   TEXT NOT NULL,
  text   TEXT NOT NULL,
  url    TEXT COLLATE NOCASE,
  host   TEXT COLLATE NOCASE,
  path   TEXT COLLATE NOCASE,
  title  TEXT COLLATE NOCASE
);
CREATE INDEX idx_docs_ts       ON docs(ts);
CREATE INDEX idx_docs_app_ts   ON docs(app, ts);
CREATE INDEX idx_docs_host_ts  ON docs(host, ts DESC);
CREATE INDEX idx_docs_url_ts   ON docs(url, ts DESC);
CREATE INDEX idx_docs_path_ts  ON docs(path, ts DESC);
CREATE INDEX idx_docs_title    ON docs(title);
"""

FTS_DDL = {
    "A": "CREATE VIRTUAL TABLE text_fts USING fts5(text, tokenize=\"unicode61 remove_diacritics 2\", content='', contentless_delete=1)",
    "B": "CREATE VIRTUAL TABLE text_fts USING fts5(text, tokenize=\"unicode61 remove_diacritics 2\", content='', contentless_delete=1)",
    "C": "CREATE VIRTUAL TABLE text_fts USING fts5(text, tokenize=\"trigram\", detail=full, content='', contentless_delete=1)",
    # 参照档：原可行性报告选的配置，用来复现评审 F3 的 phrase 报错
    "Ccol": "CREATE VIRTUAL TABLE text_fts USING fts5(text, tokenize=\"trigram\", detail=column, content='')",
    "D": "CREATE VIRTUAL TABLE text_fts USING fts5(text, tokenize=\"unicode61 remove_diacritics 2\", content='', contentless_delete=1)",
}

PREPROC = {
    "A": lambda s: s,
    "B": bigram_join,
    "C": lambda s: s,
    "Ccol": lambda s: s,
    "D": jieba_join,
}


def build_docs_db(path: Path, docs: list[dict]) -> float:
    if path.exists():
        path.unlink()
    for suf in ("-wal", "-shm"):
        p = Path(str(path) + suf)
        if p.exists():
            p.unlink()
    con = sqlite3.connect(path)
    con.executescript(DOCS_DDL)
    t0 = time.perf_counter()
    con.executemany(
        "INSERT INTO docs(id,ts,app,kind,text,url,host,path,title) VALUES(?,?,?,?,?,?,?,?,?)",
        [(d["id"], d["ts"], d["app"], d["kind"], d["text"], d["url"], d["host"],
          d["path"], d["title"]) for d in docs],
    )
    con.commit()
    dt = time.perf_counter() - t0
    con.execute("ANALYZE")
    con.execute("VACUUM")
    con.close()
    return dt


def build_fts_db(path: Path, docs: list[dict], engine: str) -> tuple[float, float]:
    """返回 (预处理秒, 建 FTS 索引秒)。"""
    build_docs_db(path, docs)
    con = sqlite3.connect(path)
    pre = PREPROC[engine]
    t0 = time.perf_counter()
    rows = [(d["id"], pre(d["text"])) for d in docs]
    t_pre = time.perf_counter() - t0
    con.execute(FTS_DDL[engine])
    t0 = time.perf_counter()
    con.executemany("INSERT INTO text_fts(rowid, text) VALUES(?,?)", rows)
    con.commit()
    con.execute("INSERT INTO text_fts(text_fts) VALUES('optimize')")
    con.commit()
    t_idx = time.perf_counter() - t0
    con.execute("VACUUM")
    con.close()
    return t_pre, t_idx


def db_bytes(path: Path) -> int:
    total = path.stat().st_size
    for suf in ("-wal", "-shm"):
        p = Path(str(path) + suf)
        if p.exists():
            total += p.stat().st_size
    return total


def dbstat_breakdown(path: Path) -> dict[str, int]:
    try:
        con = sqlite3.connect(path)
        rows = con.execute("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name").fetchall()
        con.close()
        return {n: int(s or 0) for n, s in rows}
    except sqlite3.Error:
        return {}


# ---------------------------------------------------------------- 检索

SCAN_WINDOW_DAYS = 7


class Searcher:
    """一个方案 = FTS 引擎（可选）+ 精确字段路由（可选）+ 短查询扫描补充。

    `max_cjk_scan` / `min_len_any` 决定什么样的查询要额外跑一次限定范围扫描：
    纯汉字且长度 <= max_cjk_scan，或总长度 < min_len_any。扫描结果与 FTS 结果**并集**，
    不是替代——扫描给的是精确子串命中，排在前面。
    """

    def __init__(self, name: str, engine: str | None, exact: bool, scan: str | None,
                 scan_cutoff: int, max_cjk_scan: int = 0, min_len_any: int = 0,
                 rule: str = "—", verify: bool = False):
        self.name = name
        self.engine = engine          # A/B/C/Ccol/D 或 None
        self.exact = exact            # 是否启用精确字段列
        self.scan = scan              # None / "all" / "range"
        self.scan_cutoff = scan_cutoff
        self.max_cjk_scan = max_cjk_scan
        self.min_len_any = min_len_any
        self.rule = rule
        self.verify = verify      # 只对 FTS 候选再用 LIKE 复核精确子串（精确字段与扫描通道不复核）

    def needs_scan(self, q: str) -> bool:
        if self.scan is None or self.engine is None:
            return False
        t = q.strip()
        if len(t) < self.min_len_any:
            return True
        return bool(t) and all(is_cjk(c) for c in t) and len(t) <= self.max_cjk_scan

    def plan(self, q: str) -> list[str]:
        ch: list[str] = []
        if self.exact and route_kind(q) in ("url", "path"):
            ch.append("exact:" + route_kind(q))
        if self.engine is None:
            if self.scan is not None:
                ch.append("scan:" + self.scan)
        else:
            if self.needs_scan(q):
                ch.append("scan:" + self.scan)
            ch.append("fts:" + self.engine)
        return ch

    # --- 单个检索通道 ---
    def _fts(self, con: sqlite3.Connection, q: str, limit: int) -> list[int]:
        pq = fts_phrase(PREPROC[self.engine](q))
        cur = con.execute(
            "SELECT rowid FROM text_fts WHERE text_fts MATCH ? ORDER BY bm25(text_fts) LIMIT ?",
            (pq, limit),
        )
        return [r[0] for r in cur]

    def _exact(self, con: sqlite3.Connection, q: str, kind: str, limit: int) -> list[int]:
        pat = "%" + like_escape(q) + "%"
        if kind == "url":
            body = q.split("://", 1)[1] if "://" in q else q
            if "/" in body:
                # 带路径的 URL：只能按 url 列子串匹配，按 host 匹配会把同域名其他页面全带进来
                sql = "SELECT id FROM docs WHERE url LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?"
                args = (pat, limit)
            else:
                # 裸域名：host 列等值 + 子域后缀，走 NOCASE 索引
                bare = like_escape(body)
                sql = ("SELECT id FROM docs WHERE host = ? OR host LIKE ? ESCAPE '\\' "
                       "OR url LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?")
                args = (body, "%." + bare, pat, limit)
        else:
            sql = "SELECT id FROM docs WHERE path LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?"
            args = (pat, limit)
        return [r[0] for r in con.execute(sql, args)]

    def _verify(self, con: sqlite3.Connection, q: str, ids: list[int]) -> list[int]:
        """FTS 候选复核：只保留正文里真的含该子串的行，保持原有排序。

        **只用于 FTS 通道。** 假阳性的来源是 unicode61 丢标点 / bigram 跨边界，这只发生在
        FTS 候选里；精确字段（url/host/path）与限定范围扫描本身就是精确匹配，正文里不含
        该串是正常的（例如 urls 表命中而正文没抄这条 URL），对它们复核等于用正文过滤掉
        本来正确的结构化命中。
        """
        if not ids:
            return ids
        pat = "%" + like_escape(q) + "%"
        keep: set[int] = set()
        for i in range(0, len(ids), 500):
            chunk = ids[i:i + 500]
            ph = ",".join("?" * len(chunk))
            keep.update(r[0] for r in con.execute(
                f"SELECT id FROM docs WHERE id IN ({ph}) AND text LIKE ? ESCAPE '\\'",
                (*chunk, pat)))
        return [i for i in ids if i in keep]

    def _scan(self, con: sqlite3.Connection, q: str, limit: int, ranged: bool) -> list[int]:
        pat = "%" + like_escape(q) + "%"
        if ranged:
            sql = ("SELECT id FROM docs WHERE ts >= ? AND text LIKE ? ESCAPE '\\' "
                   "ORDER BY ts DESC LIMIT ?")
            args = (self.scan_cutoff, pat, limit)
        else:
            sql = "SELECT id FROM docs WHERE text LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?"
            args = (pat, limit)
        return [r[0] for r in con.execute(sql, args)]

    # --- 规划 + 执行 ---
    def search(self, con: sqlite3.Connection, q: str, limit: int) -> tuple[list[int], str | None]:
        out: list[int] = []
        seen: set[int] = set()
        err: str | None = None

        def add(ids: list[int]) -> None:
            for i in ids:
                if i not in seen:
                    seen.add(i)
                    out.append(i)

        kind = route_kind(q) if self.exact else "text"
        if kind in ("url", "path"):
            add(self._exact(con, q, kind, limit))

        if self.engine is None:
            if self.scan is not None:      # 纯扫描方案
                add(self._scan(con, q, limit, ranged=(self.scan == "range")))
            # scan is None 时是"只有精确字段"的方案 E，正文查询没有任何通道
            return out[:limit], err

        # FTS 方案：索引处理不了的短查询，额外并上一次限定范围扫描（并集，不是替代）
        if self.needs_scan(q):
            add(self._scan(con, q, limit, ranged=(self.scan == "range")))
        try:
            fts_ids = self._fts(con, q, limit)
            if self.verify:                      # 复核只作用于 FTS 候选
                fts_ids = self._verify(con, q, fts_ids)
            add(fts_ids)
        except sqlite3.OperationalError as e:
            err = str(e)
        return out[:limit], err


# ---------------------------------------------------------------- 评测

def collate_experiment(rows: int = 20000, reps: int = 200) -> dict:
    """独立对照：COLLATE NOCASE 写在列上 vs 只写在索引上，对 `col = ?` 能不能走索引的影响。

    这是 §7 的一个独立结论，与主语料无关，所以单独建一个内存库跑。
    """
    data = [(i, i, f"h{i % 50}.example.com", f"https://h{i % 50}.example.com/p/{i}",
             f"~/Developer/brosis/Sources/File{i}.swift") for i in range(rows)]
    out: dict = {"rows": rows, "reps": reps, "shapes": {}}

    def plan_of(con, sql, args):
        return " / ".join(" ".join(str(x) for x in r[3:])
                          for r in con.execute("EXPLAIN QUERY PLAN " + sql, args))

    def timed(con, sql, args):
        t0 = time.perf_counter()
        for _ in range(reps):
            con.execute(sql, args).fetchall()
        return (time.perf_counter() - t0) / reps * 1000

    eq_sql = "SELECT id FROM d WHERE host = ? ORDER BY ts DESC LIMIT 10"
    eq_arg = ("h7.example.com",)

    # 变体一：列是默认 BINARY，只有索引带 NOCASE
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE d(id INTEGER PRIMARY KEY, ts INT, host TEXT, url TEXT, path TEXT)")
    con.executemany("INSERT INTO d VALUES(?,?,?,?,?)", data)
    con.execute("CREATE INDEX i_host ON d(host COLLATE NOCASE, ts DESC)")
    con.execute("ANALYZE")
    out["索引 NOCASE、列 BINARY"] = {"plan": plan_of(con, eq_sql, eq_arg),
                                 "hot_ms": timed(con, eq_sql, eq_arg)}
    con.close()

    # 变体二：列和索引都是 NOCASE（推荐）
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE d(id INTEGER PRIMARY KEY, ts INT, host TEXT COLLATE NOCASE,"
                " url TEXT COLLATE NOCASE, path TEXT COLLATE NOCASE)")
    con.executemany("INSERT INTO d VALUES(?,?,?,?,?)", data)
    con.execute("CREATE INDEX i_host_ts ON d(host, ts DESC)")
    con.execute("CREATE INDEX i_url_ts ON d(url, ts DESC)")
    con.execute("CREATE INDEX i_path_ts ON d(path, ts DESC)")
    con.execute("ANALYZE")
    out["列与索引都 NOCASE"] = {"plan": plan_of(con, eq_sql, eq_arg),
                           "hot_ms": timed(con, eq_sql, eq_arg)}
    shapes = {
        "`host = ?`（裸域名）": (eq_sql, eq_arg),
        "`host LIKE '%.x'`（子域后缀）": (
            "SELECT id FROM d WHERE host LIKE ? ORDER BY ts DESC LIMIT 10", ("%.example.com",)),
        "`url LIKE 'https://x/%'`（URL 前缀）": (
            "SELECT id FROM d WHERE url LIKE ? ORDER BY ts DESC LIMIT 10",
            ("https://h7.example.com/%",)),
        "`url LIKE '%x%'`（URL 子串）": (
            "SELECT id FROM d WHERE url LIKE ? ORDER BY ts DESC LIMIT 10",
            ("%h7.example.com/p/1%",)),
        "`path LIKE '%x%'`（路径子串）": (
            "SELECT id FROM d WHERE path LIKE ? ORDER BY ts DESC LIMIT 10", ("%File199.swift%",)),
    }
    for name, (sql, args) in shapes.items():
        out["shapes"][name] = {"plan": plan_of(con, sql, args), "hot_ms": timed(con, sql, args)}
    con.close()
    return out


def app_scope_probe(db_path: Path, docs: list[dict], queries: list[dict],
                    truth: dict[str, set[int]], scan_cutoff: int,
                    limit: int = 5000, reps: int = 50) -> dict:
    """限定「时间窗口 + 应用」的补扫描实测（计划 3.4：一两字查询回退为限定范围扫描）。

    口径：假定用户提问时已经把范围说清楚了（「上周在飞书里说的预算」），
    所以对每条 1~2 字的正例查询，取「7 天窗口内相关文档最多的那个应用」当作用户指定的应用，
    真值 = 窗口内 ∩ 该应用 的相关文档集合。这一档只回答两个问题：
    在用户给定的范围里扫描能不能全召回、要多久；它不与 FTS 各档比排名。
    """
    by_id = {d["id"]: d for d in docs}
    in_range = {d["id"] for d in docs if d["ts"] >= scan_cutoff}
    con = sqlite3.connect(db_path)
    sql_app = ("SELECT id FROM docs WHERE ts >= ? AND app = ? AND text LIKE ? ESCAPE '\\' "
               "ORDER BY ts DESC LIMIT ?")
    sql_ts = ("SELECT id FROM docs WHERE ts >= ? AND text LIKE ? ESCAPE '\\' "
              "ORDER BY ts DESC LIMIT ?")
    rows = []
    for spec in queries:
        q = spec["q"]
        if spec["expect"] != "hit" or not is_short_cjk(q):
            continue
        rel_win = truth[spec["id"]] & in_range
        if not rel_win:
            continue
        cnt: dict[str, int] = {}
        for i in rel_win:
            cnt[by_id[i]["app"]] = cnt.get(by_id[i]["app"], 0) + 1
        app = max(sorted(cnt), key=lambda k: cnt[k])
        rel_scope = {i for i in rel_win if by_id[i]["app"] == app}
        scope_docs = sum(1 for d in docs if d["ts"] >= scan_cutoff and d["app"] == app)
        pat = "%" + like_escape(q) + "%"
        got = {r[0] for r in con.execute(sql_app, (scan_cutoff, app, pat, limit))}
        plan = " / ".join(" ".join(str(x) for x in r[3:]) for r in con.execute(
            "EXPLAIN QUERY PLAN " + sql_app, (scan_cutoff, app, pat, 10)))

        def hot(sql, args):
            con.execute(sql, args).fetchall()          # 预热
            vals = []
            for _ in range(reps):
                t0 = time.perf_counter()
                con.execute(sql, args).fetchall()
                vals.append((time.perf_counter() - t0) * 1000.0)
            return percentile(vals, 0.50), percentile(vals, 0.95)

        p50_app, p95_app = hot(sql_app, (scan_cutoff, app, pat, 10))
        p50_ts, p95_ts = hot(sql_ts, (scan_cutoff, pat, 10))
        rows.append({
            "q": q, "app": app, "apps_in_window": cnt,
            "scope_docs": scope_docs, "relevant_in_window": len(rel_win),
            "relevant_in_scope": len(rel_scope),
            "hits_in_scope": len(got & rel_scope),
            "recall_in_scope": (len(got & rel_scope) / len(rel_scope)) if rel_scope else None,
            "returned": len(got), "plan": plan,
            "hot_p50_ms": p50_app, "hot_p95_ms": p95_app,
            "range_only_p50_ms": p50_ts, "range_only_p95_ms": p95_ts,
        })
    con.close()
    return {"window_days": SCAN_WINDOW_DAYS, "docs_in_window": len(in_range),
            "limit": limit, "reps": reps, "rows": rows}


def percentile(vals: list[float], p: float) -> float:
    if not vals:
        return float("nan")
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def evaluate(db_path: Path, searcher: Searcher, queries: list[dict],
             truth: dict[str, set[int]], truth_range: dict[str, set[int]],
             deep_limit: int, cold_reps: int, hot_reps: int) -> dict:
    per_query = []
    con = sqlite3.connect(db_path)
    for spec in queries:
        qid, q = spec["id"], spec["q"]
        rel = truth[qid]
        deep, err = searcher.search(con, q, deep_limit)
        channels = searcher.plan(q)
        top10 = deep[:10]
        hits10 = len([i for i in top10 if i in rel])
        hits_all = len([i for i in deep if i in rel])
        rel_range = truth_range[qid]
        denom10 = min(10, len(rel)) or 0
        rec10 = (hits10 / denom10) if denom10 else None
        # 返回 0 条时 precision 无定义：漏检由 Recall 体现，另用"空结果正例数"单列
        prec10 = (hits10 / len(top10)) if top10 else None
        rec_all = (hits_all / len(rel)) if rel else None
        rec_range = (len([i for i in deep if i in rel_range]) / len(rel_range)) if rel_range else None
        per_query.append({
            "id": qid, "class": spec["class"], "q": q, "expect": spec["expect"],
            "relevant": len(rel), "relevant_in_range": len(rel_range),
            "returned": len(deep), "returned_top10": len(top10),
            "hits_top10": hits10, "hits_all": hits_all,
            "recall@10": rec10, "precision@10": prec10,
            "recall_all": rec_all, "recall_all_in_range": rec_range,
            "error": err, "channels": channels,
            "false_positives_top10": (len(top10) if not rel else None),
        })
    con.close()

    # 延迟（LIMIT 10）
    lat_cold: dict[str, list[float]] = {}
    lat_hot: dict[str, list[float]] = {}
    for spec in queries:
        qid, q = spec["id"], spec["q"]
        cold, hot = [], []
        for _ in range(cold_reps):
            c = sqlite3.connect(db_path)
            t0 = time.perf_counter()
            try:
                searcher.search(c, q, 10)
            except sqlite3.OperationalError:
                pass
            cold.append((time.perf_counter() - t0) * 1000.0)
            c.close()
        c = sqlite3.connect(db_path)
        try:
            searcher.search(c, q, 10)  # 预热
        except sqlite3.OperationalError:
            pass
        for _ in range(hot_reps):
            t0 = time.perf_counter()
            try:
                searcher.search(c, q, 10)
            except sqlite3.OperationalError:
                pass
            hot.append((time.perf_counter() - t0) * 1000.0)
        c.close()
        lat_cold[qid] = cold
        lat_hot[qid] = hot

    for row in per_query:
        row["lat_cold_p50_ms"] = percentile(lat_cold[row["id"]], 0.50)
        row["lat_hot_p50_ms"] = percentile(lat_hot[row["id"]], 0.50)
    return {
        "per_query": per_query,
        "lat_cold_all": [v for vs in lat_cold.values() for v in vs],
        "lat_hot_all": [v for vs in lat_hot.values() for v in vs],
        "lat_cold_by_q": lat_cold,
        "lat_hot_by_q": lat_hot,
    }


def aggregate(rows: list[dict], key: str | None = None) -> dict:
    def m(vals):
        vals = [v for v in vals if v is not None]
        return (sum(vals) / len(vals)) if vals else None

    pos = [r for r in rows if r["expect"] == "hit"]
    neg = [r for r in rows if r["expect"] == "none"]
    return {
        "n_queries": len(rows),
        "n_positive": len(pos),
        "n_negative": len(neg),
        "recall@10": m(r["recall@10"] for r in pos),
        "precision@10": m(r["precision@10"] for r in pos),
        "recall_all": m(r["recall_all"] for r in pos),
        "empty_positives": sum(1 for r in pos if r["returned_top10"] == 0),
        "errors": sum(1 for r in rows if r["error"]),
        "error_rate": (sum(1 for r in rows if r["error"]) / len(rows)) if rows else 0.0,
        "neg_with_fp": sum(1 for r in neg if r["returned_top10"] > 0),
        "neg_fp_rows": sum(r["returned_top10"] for r in neg),
    }


# ---------------------------------------------------------------- 报告

def fmt_pct(v) -> str:
    return "—" if v is None else f"{v * 100:.1f}%"


def fmt_ms(v) -> str:
    return "—" if v is None or v != v else f"{v:.2f}"


def human_bytes(n: int) -> str:
    """体积一律按 2^20 计并标 MiB（评审 F8：口径要统一且写明进制）。"""
    return f"{n / 1024 / 1024:.2f} MiB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", default=str(DEFAULT_BUILD))
    ap.add_argument("--out-dir", default=str(HERE / "results"))
    ap.add_argument("--date", default="2026-09-06")
    ap.add_argument("--deep-limit", type=int, default=5000)
    ap.add_argument("--cold-reps", type=int, default=5)
    ap.add_argument("--hot-reps", type=int, default=20)
    args = ap.parse_args()

    build_dir = Path(args.build_dir).expanduser()
    build_dir.mkdir(parents=True, exist_ok=True)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"sqlite3 module version : {sqlite3.version if hasattr(sqlite3, 'version') else 'n/a'}")
    print(f"SQLite library version : {sqlite3.sqlite_version}")
    print(f"Python                 : {sys.version.split()[0]}  ({platform.machine()})")

    # trigram 可用性自检
    probe = sqlite3.connect(":memory:")
    trigram_ok, contentless_delete_ok = False, False
    try:
        probe.execute("CREATE VIRTUAL TABLE _p USING fts5(x, tokenize='trigram', detail=full)")
        probe.execute("INSERT INTO _p(x) VALUES('知识图谱 research')")
        r = probe.execute("SELECT rowid FROM _p WHERE _p MATCH ?", ('"知识图谱"',)).fetchall()
        trigram_ok = bool(r)
    except sqlite3.OperationalError as e:
        print("trigram 不可用:", e)
    try:
        probe.execute("CREATE VIRTUAL TABLE _q USING fts5(x, tokenize='trigram', detail=full,"
                      " content='', contentless_delete=1)")
        contentless_delete_ok = True
    except sqlite3.OperationalError as e:
        print("contentless_delete 不可用:", e)
    fts5_opts = [r[0] for r in probe.execute("PRAGMA compile_options").fetchall()
                 if "FTS" in r[0] or "DBSTAT" in r[0]]
    probe.close()
    print(f"trigram detail=full    : {'可用' if trigram_ok else '不可用'}")
    print(f"contentless_delete=1   : {'可用' if contentless_delete_ok else '不可用'}")
    print(f"相关编译选项           : {fts5_opts}")
    print(f"jieba                  : {'可用' if jieba_available() else '不可用（方案 D 跳过）'}")
    print()

    qs = json.loads((HERE / "fts_queries.json").read_text(encoding="utf-8"))
    queries = qs["queries"]
    rng = random.Random(qs["seed"])
    docs = gen_corpus(rng, queries)
    total_chars = sum(len(d["text"]) for d in docs)
    total_bytes = sum(len(d["text"].encode("utf-8")) for d in docs)
    print(f"语料: {len(docs)} 条观察，{total_chars} 字符，正文 UTF-8 {total_bytes} 字节 "
          f"({human_bytes(total_bytes)})，平均 {total_chars / len(docs):.0f} 字符/条")

    truth = compute_truth(docs, queries)
    # 负例硬校验
    bad = [s["id"] for s in queries if s["expect"] == "none" and truth[s["id"]]]
    if bad:
        print("负例被污染，语料需要调整:", bad)
        return 2
    empty_pos = [s["id"] for s in queries if s["expect"] == "hit" and not truth[s["id"]]]
    if empty_pos:
        print("正例真值为空，语料需要调整:", empty_pos)
        return 2

    ts_max = max(d["ts"] for d in docs)
    scan_cutoff = ts_max - SCAN_WINDOW_DAYS * 86400
    in_range_ids = {d["id"] for d in docs if d["ts"] >= scan_cutoff}
    truth_range = {k: (v & in_range_ids) for k, v in truth.items()}
    print(f"扫描回退窗口: 最近 {SCAN_WINDOW_DAYS} 天 = {len(in_range_ids)} 条 "
          f"({len(in_range_ids) / len(docs) * 100:.1f}%)")
    print(f"真值: 正例 {sum(1 for s in queries if s['expect'] == 'hit')} 条，"
          f"负例 {sum(1 for s in queries if s['expect'] == 'none')} 条，"
          f"正例平均相关文档 "
          f"{statistics.mean([len(truth[s['id']]) for s in queries if s['expect'] == 'hit']):.1f} 篇")
    print()

    # ---- 建库 ----
    base_path = build_dir / "base.sqlite"
    t_docs = build_docs_db(base_path, docs)
    base_size = db_bytes(base_path)
    print(f"[base] 只有 docs 表 + 精确字段索引: {human_bytes(base_size)}，写入 {t_docs * 1000:.0f} ms")

    engines = ["A", "B", "C"] + (["D"] if jieba_available() else [])
    build_engines = ["A", "B", "C", "Ccol"] + (["D"] if jieba_available() else [])
    build_info: dict[str, dict] = {}
    for eng in build_engines:
        p = build_dir / f"{eng}.sqlite"
        t_pre, t_idx = build_fts_db(p, docs, eng)
        size = db_bytes(p)
        build_info[eng] = {
            "db": str(p), "db_bytes": size, "index_bytes": size - base_size,
            "preprocess_s": t_pre, "index_build_s": t_idx,
            "dbstat": dbstat_breakdown(p),
        }
        print(f"[{eng}] 库 {human_bytes(size)}，索引净增 {human_bytes(size - base_size)}，"
              f"预处理 {t_pre * 1000:.0f} ms，建索引 {t_idx * 1000:.0f} ms")
    print()

    # ---- 方案定义 ----
    schemes: list[tuple[str, str, Searcher]] = []
    labels = {
        "A": "A unicode61 原样",
        "B": "B 字符 bigram + unicode61",
        "C": "C trigram detail=full",
        "Ccol": "C0 trigram detail=column（原报告配置，F3 参照）",
        "D": "D jieba 分词 + unicode61",
    }
    for eng in build_engines:
        schemes.append((eng, labels[eng], Searcher(eng, eng, exact=False, scan=None,
                                                   scan_cutoff=scan_cutoff)))
    schemes.append(("E", "E 仅精确字段（url/host/path）",
                    Searcher("E", None, exact=True, scan=None, scan_cutoff=scan_cutoff,
                             rule="只查 url/host/path 列，正文完全不查")))
    # 注意：E 单独一档时没有 FTS，只能靠精确字段；正文查询无结果。
    schemes.append(("SCAN_ALL", "扫描 全表 LIKE",
                    Searcher("SCAN_ALL", None, exact=False, scan="all",
                             scan_cutoff=scan_cutoff, rule="所有查询全表扫正文")))
    schemes.append(("SCAN_7D", f"扫描 最近 {SCAN_WINDOW_DAYS} 天 LIKE",
                    Searcher("SCAN_7D", None, exact=False, scan="range",
                             scan_cutoff=scan_cutoff,
                             rule=f"所有查询只扫最近 {SCAN_WINDOW_DAYS} 天")))
    # 短查询补扫描的阈值按各方案实测能力单独设定（见 §5 纯 FTS 各档的分类召回）
    fb = {
        "A": dict(max_cjk_scan=99, min_len_any=0,
                  rule="纯汉字查询一律补扫描（A 对中文基本无召回）"),
        "B": dict(max_cjk_scan=1, min_len_any=0,
                  rule="纯汉字且长度 = 1 时补扫描（bigram 从 2 字起可用）"),
        "C": dict(max_cjk_scan=0, min_len_any=3,
                  rule="长度 < 3 时补扫描（trigram 从 3 字符起可用）"),
        "D": dict(max_cjk_scan=1, min_len_any=0,
                  rule="纯汉字且长度 = 1 时补扫描（单字是否成词取决于词典切分）"),
    }
    for eng in engines:
        schemes.append((f"{eng}+E", f"{labels[eng]} + 精确字段 + 短查询补扫描",
                        Searcher(f"{eng}+E", eng, exact=True, scan="range",
                                 scan_cutoff=scan_cutoff, **fb[eng])))
    # 推荐形态：B+E 再加一道"候选用 LIKE 复核精确子串"，用来消掉 unicode61 忽略标点带来的假阳性
    kw = dict(fb["B"])
    kw["rule"] = kw["rule"] + "；候选再用 LIKE 复核精确子串"
    schemes.append(("B+E+V", "B 字符 bigram + 精确字段 + 补扫描 + 子串复核",
                    Searcher("B+E+V", "B", exact=True, scan="range",
                             scan_cutoff=scan_cutoff, verify=True, **kw)))

    # E 单独一档需要一个只有 docs 的库
    db_for = {"E": base_path, "SCAN_ALL": base_path, "SCAN_7D": base_path}
    for eng in build_engines:
        db_for[eng] = build_dir / f"{eng}.sqlite"
    for eng in engines:
        db_for[f"{eng}+E"] = build_dir / f"{eng}.sqlite"
    db_for["B+E+V"] = build_dir / "B.sqlite"

    results: dict[str, dict] = {}
    for key, label, sc in schemes:
        t0 = time.perf_counter()
        res = evaluate(db_for[key], sc, queries, truth, truth_range,
                       args.deep_limit, args.cold_reps, args.hot_reps)
        rows = res["per_query"]
        agg = aggregate(rows)
        agg["lat_cold_p50_ms"] = percentile(res["lat_cold_all"], 0.50)
        agg["lat_cold_p95_ms"] = percentile(res["lat_cold_all"], 0.95)
        agg["lat_hot_p50_ms"] = percentile(res["lat_hot_all"], 0.50)
        agg["lat_hot_p95_ms"] = percentile(res["lat_hot_all"], 0.95)
        by_class = {}
        for cls in qs["classes"]:
            sub = [r for r in rows if r["class"] == cls]
            a = aggregate(sub)
            a["lat_hot_p95_ms"] = percentile(
                [v for r in sub for v in res["lat_hot_by_q"][r["id"]]], 0.95)
            by_class[cls] = a
        results[key] = {"label": label, "rule": sc.rule, "overall": agg,
                        "by_class": by_class, "per_query": rows, "db": str(db_for[key]),
                        "wall_s": time.perf_counter() - t0}
        print(f"{label:52s} R@10 {fmt_pct(agg['recall@10']):>7s}  "
              f"P@10 {fmt_pct(agg['precision@10']):>7s}  "
              f"报错 {agg['errors']:2d}  "
              f"热 p50/p95 {fmt_ms(agg['lat_hot_p50_ms'])}/{fmt_ms(agg['lat_hot_p95_ms'])} ms")

    # 扫描吞吐
    scan_p50 = results["SCAN_ALL"]["overall"]["lat_hot_p50_ms"]
    scan_mib_per_s = (total_bytes / 1024 / 1024) / (scan_p50 / 1000.0) if scan_p50 else None

    # EXPLAIN QUERY PLAN 抽样
    eqp = {}
    con = sqlite3.connect(base_path)
    samples = {
        "host 等值（裸域名查询）": (
            "SELECT id FROM docs WHERE host = ? ORDER BY ts DESC LIMIT 10", ("sqlite.org",)),
        "host 子域后缀": (
            "SELECT id FROM docs WHERE host LIKE ? ORDER BY ts DESC LIMIT 10", ("%.sqlite.org",)),
        "url 前缀（完整 URL 查询）": (
            "SELECT id FROM docs WHERE url LIKE ? ORDER BY ts DESC LIMIT 10",
            ("https://sqlite.org/%",)),
        "url 子串": (
            "SELECT id FROM docs WHERE url LIKE ? ORDER BY ts DESC LIMIT 10",
            ("%sqlite-vec%",)),
        "path 子串": (
            "SELECT id FROM docs WHERE path LIKE ? ORDER BY ts DESC LIMIT 10",
            ("%AXReader.swift%",)),
        "正文全表扫描": (
            "SELECT id FROM docs WHERE text LIKE ? ORDER BY ts DESC LIMIT 10", ("%预算%",)),
        "正文限时扫描": (
            "SELECT id FROM docs WHERE ts >= ? AND text LIKE ? ORDER BY ts DESC LIMIT 10",
            (scan_cutoff, "%预算%")),
        "app 等值 + 时间窗口（走 idx_docs_app_ts）": (
            "SELECT id FROM docs WHERE app = ? AND ts >= ? ORDER BY ts DESC LIMIT 10",
            ("飞书", scan_cutoff)),
        "正文限时 + 限应用扫描": (
            "SELECT id FROM docs WHERE ts >= ? AND app = ? AND text LIKE ? ORDER BY ts DESC LIMIT 10",
            (scan_cutoff, "飞书", "%预算%")),
    }
    for name, (sql, aa) in samples.items():
        plan = [" ".join(str(x) for x in r[3:]) for r in
                con.execute("EXPLAIN QUERY PLAN " + sql, aa).fetchall()]
        t0 = time.perf_counter()
        for _ in range(200):
            con.execute(sql, aa).fetchall()
        eqp[name] = {"plan": plan, "hot_ms": (time.perf_counter() - t0) / 200 * 1000}
    con.close()
    collate_probe = collate_experiment()
    app_scope = app_scope_probe(base_path, docs, queries, truth, scan_cutoff)

    payload = {
        "task": "brosis M0 T3 FTS 分词方案对照",
        "date": args.date,
        "env": {
            "python": sys.version.split()[0],
            "sqlite_library": sqlite3.sqlite_version,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "trigram_full_ok": trigram_ok,
            "contentless_delete_ok": contentless_delete_ok,
            "jieba": jieba_available(),
        },
        "corpus": {
            "docs": len(docs), "chars": total_chars, "text_utf8_bytes": total_bytes,
            "avg_chars": total_chars / len(docs),
            "by_kind": {k: KIND_COUNTS[k] for k in KIND_COUNTS},
            "days": 30, "scan_window_days": SCAN_WINDOW_DAYS,
            "scan_window_docs": len(in_range_ids),
        },
        "queries": {"n": len(queries), "classes": qs["classes"],
                    "truth_rule": qs["truth_rule"]},
        "truth_sizes": {k: len(v) for k, v in truth.items()},
        "build": {"base_db_bytes": base_size, "docs_insert_s": t_docs, "engines": build_info},
        "schemes": {k: {"label": v["label"], "rule": v.get("rule", "—"),
                        "overall": v["overall"],
                        "by_class": v["by_class"], "per_query": v["per_query"]}
                    for k, v in results.items()},
        "nl_probe": {
            "samples": NL_SAMPLES,
            "jieba": ({smp: jieba_join(smp).replace(" ", "/") for smp in NL_SAMPLES}
                      if jieba_available() else {}),
            "swift": NL_OUTPUT,
            "notes": NL_PROBE,
        },
        "scan_throughput_mib_per_s": scan_mib_per_s,
        "explain_query_plan": eqp,
        "collate_probe": collate_probe,
        "app_scope_scan": app_scope,
        "params": {"deep_limit": args.deep_limit, "cold_reps": args.cold_reps,
                   "hot_reps": args.hot_reps},
    }
    json_path = out_dir / f"fts_compare_{args.date}.json"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    md_path = out_dir / f"fts_compare_{args.date}.md"
    md_path.write_text(render_md(payload, qs, results, build_info, build_engines, base_size,
                                 scan_mib_per_s, eqp, truth, queries,
                                 app_scope), encoding="utf-8")
    print()
    print("写出:", json_path)
    print("写出:", md_path)
    return 0


def render_md(payload, qs, results, build_info, engines, base_size, scan_mib_per_s, eqp,
              truth, queries, app_scope) -> str:
    L: list[str] = []
    a = L.append
    env = payload["env"]
    corpus = payload["corpus"]
    fts_engines = [e for e in engines if e != "Ccol"]
    order = (engines + ["E", "SCAN_ALL", "SCAN_7D"]
             + [f"{e}+E" for e in fts_engines] + ["B+E+V"])

    a(f"# brosis M0 · T3 全文检索分词方案对照（{payload['date']}）")
    a("")
    a("对应《实施计划》3.4 检索设计、实验 E2 的离线部分，落实《调研方案评审》F3。"
      "全部数据为本机实跑，脚本 `tools/bench/fts_compare.py`，查询集 `tools/bench/fts_queries.json`。")
    a("")
    a("## 1. 环境与口径")
    a("")
    a("| 项 | 值 |")
    a("|---|---|")
    a(f"| Python | {env['python']} |")
    a(f"| SQLite 库版本（Python 链接） | {env['sqlite_library']} |")
    a(f"| 平台 | {env['platform']} / {env['machine']} |")
    a(f"| `trigram` + `detail=full` phrase 查询 | {'可用' if env['trigram_full_ok'] else '不可用'} |")
    a(f"| `content='' , contentless_delete=1` | {'可用' if env['contentless_delete_ok'] else '不可用'} |")
    a(f"| jieba（方案 D） | {'可用' if env['jieba'] else '不可用，方案 D 未跑'} |")
    a("")
    a("口径说明：")
    a("")
    a(f"- **真值**：{qs['truth_rule']}")
    a("- **Recall@10** = 前 10 条命中的相关文档数 ÷ min(10, 相关文档总数)。相关文档超过 10 篇时按 10 封顶，"
      "所以这是「前 10 条能不能装满相关结果」，不是全量召回。")
    a(f"- **Recall_all** = 取前 {payload['params']['deep_limit']} 条时命中的相关文档数 ÷ 相关文档总数，"
      "衡量「索引本身能不能找到」，与排序无关。")
    a("- **Precision@10** = 前 10 条里相关文档占比，只对「应有结果」且**确实返回了结果**的查询统计；"
      "返回 0 条时 precision 无定义，漏检由 Recall@10 与「空结果正例数」两列体现。")
    a("- **空结果正例数** = 本该有结果却一条都没返回的查询数（分母是 58 条正例）。")
    a("- **报错率** = 该方案下抛 `sqlite3.OperationalError` 的查询数 ÷ 查询总数（F3 里的 phrase 错误就在这里体现）。")
    a("- **延迟**：`LIMIT 10` 的端到端 Python 侧墙钟时间，含建 SQL、绑参、取结果。"
      f"冷 = 每次新建 `sqlite3.connect`（{payload['params']['cold_reps']} 次/查询）；"
      f"热 = 同一连接重复执行（{payload['params']['hot_reps']} 次/查询）。"
      "**冷只清掉了 SQLite 自己的页缓存，没有清 macOS 的文件缓存**（清缓存需要提权），所以冷数字是下界。")
    a("- **索引体积** = 该方案的库文件字节数 − 只含 `docs` 表与精确字段索引的基准库字节数，两者都 `VACUUM` 后测量。")
    a("- **体积单位**：本文一律 2^20 进制，`MiB = 1024 KiB = 1,048,576 字节`，`GiB = 1024 MiB`；"
      "字节原值同时给出，换算不用猜。")
    a("- **子串匹配用 `LIKE '%q%' ESCAPE '\\'` 而不是 `instr()`**：两者在本轮口径下等价"
      "（真值也是「正文包含该子串」，`%` `_` `\\` 已转义），但 `LIKE` 在 SQLite 里对 ASCII 大小写不敏感，"
      "与精确字段列的 `COLLATE NOCASE` 口径一致；`instr()` 是大小写敏感的，会让英文查询的召回口径"
      "与 §7 的精确字段那一路对不上。产品实现用哪个都行，但要和真值口径保持同一个。")
    a("")
    a("## 2. 语料与查询集")
    a("")
    a(f"合成语料 **{corpus['docs']} 条观察**，确定性种子 `{qs['seed']}`，时间跨度 {corpus['days']} 天"
      f"（2026-08-08 ~ 2026-09-06），正文合计 {corpus['chars']} 字符 / "
      f"{corpus['text_utf8_bytes']} 字节 UTF-8（{corpus['text_utf8_bytes'] / 1024 / 1024:.2f} MiB），"
      f"平均 {corpus['avg_chars']:.0f} 字符/条。每条带 `app`、`ts`、`kind` 以及 `url`/`host`/`path`/`title` 元数据。")
    a("")
    a("| 文本类型 | 条数 | 应用 |")
    a("|---|---:|---|")
    kind_label = {
        "zh_doc": "中文正文（纪要/说明）", "mixed": "中英混排", "code": "代码片段（函数名、错误码）",
        "url": "浏览器页面（标题 + URL）", "path": "文件路径（Finder/编辑器）",
        "chat_feishu": "飞书聊天（发送者 + 时间 + 消息）", "chat_wechat": "微信聊天（发送者 + 时间 + 消息）",
        "terminal": "终端输出（命令 + 回显）",
    }
    for k, n in corpus["by_kind"].items():
        a(f"| {kind_label[k]} | {n} | {'、'.join(APPS_BY_KIND[k])} |")
    a("")
    pos = [s for s in queries if s["expect"] == "hit"]
    neg = [s for s in queries if s["expect"] == "none"]
    a(f"查询集 **{len(queries)} 条**，9 类，其中「应有结果」{len(pos)} 条、「应无结果」{len(neg)} 条"
      f"（每类至少 1 条负例）。正例平均相关文档 "
      f"{statistics.mean([len(truth[s['id']]) for s in pos]):.1f} 篇，中位 "
      f"{statistics.median([len(truth[s['id']]) for s in pos]):.0f} 篇，"
      f"最多 {max(len(truth[s['id']]) for s in pos)} 篇。")
    a("")
    a("| 类别 | 查询数 | 正例 | 负例 | 例子 |")
    a("|---|---:|---:|---:|---|")
    for cls in qs["classes"]:
        sub = [s for s in queries if s["class"] == cls]
        p = [s for s in sub if s["expect"] == "hit"]
        n = [s for s in sub if s["expect"] == "none"]
        ex = "、".join(f"`{s['q']}`" for s in sub[:2])
        a(f"| {cls} | {len(sub)} | {len(p)} | {len(n)} | {ex} |")
    a("")
    a("## 3. 对照方案")
    a("")
    a("| 代号 | 索引 | 查询改写 | 精确字段 | 短查询补扫描规则 |")
    a("|---|---|---|---|---|")
    a("| A | `fts5(text, tokenize=\"unicode61 remove_diacritics 2\")` | 整串包成 phrase | 无 | 无 |")
    a("| B | 同 A，但写入前把汉字连续段切成重叠 bigram | 查询同样 bigram 化后包 phrase | 无 | 无 |")
    a("| C | `fts5(text, tokenize=\"trigram\", detail=full)` | 整串包成 phrase | 无 | 无 |")
    a("| C0 | `fts5(text, tokenize=\"trigram\", detail=column)` — 原可行性报告选的配置 | 整串包成 phrase | 无 | 无 |")
    a("| D | 同 A，但写入前用 jieba 切词并以空格分隔 | 查询同样 jieba 切词后包 phrase | 无 | 无 |")
    for k in order:
        if k in ("E", "SCAN_ALL", "SCAN_7D") or "+E" in k:
            idx = ("X 的索引" if "+E" in k else "无")
            rew = ("先按查询形态路由到 `url`/`path` 列，再并上 FTS 结果"
                   if "+E" in k else
                   ("`url`/`host` 等值或前缀、`path` 子串" if k == "E"
                    else "`text LIKE '%q%' ESCAPE '\\'`"))
            a(f"| {k} | {idx} | {rew} | {'有' if k == 'E' or '+E' in k else '无'} | "
              f"{results[k].get('rule', '—')} |")
    a("")
    a(f"补扫描窗口「最近 {SCAN_WINDOW_DAYS} 天」覆盖 {corpus['scan_window_docs']} 条 "
      f"（{corpus['scan_window_docs'] / corpus['docs'] * 100:.1f}%）。补扫描是**并集**不是替代："
      "扫描出来的精确子串命中排在前面，FTS 结果接在后面。走了补扫描的查询，其召回天然被窗口截断，"
      "§4/§5 里的 Recall 是对**全局**真值算的，所以这类查询在 X+E 下不会到 100%——这是设计如此，"
      "窗口内召回单列在 §6。各方案的阈值是按 §5 里纯 FTS 档的实测能力定的，不是统一拍的。")
    a("")
    a("## 4. 总表")
    a("")
    a("| 方案 | Recall@10 | Precision@10 | Recall_all | 空结果正例 | 报错 | 负例假阳性 | 库体积 | 索引净增 | 预处理 | 建索引 | 冷 p50/p95 (ms) | 热 p50/p95 (ms) |")
    a("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for k in order:
        r = results[k]
        o = r["overall"]
        bi = build_info.get("B" if k == "B+E+V" else (k[:-2] if k.endswith("+E") else k))
        if bi is None:
            size_s, idx_s, pre_s, bld_s = human_bytes(base_size), "0 MiB（无 FTS）", "—", "—"
        else:
            size_s = human_bytes(bi["db_bytes"])
            idx_s = human_bytes(bi["index_bytes"])
            pre_s = f"{bi['preprocess_s'] * 1000:.0f} ms"
            bld_s = f"{bi['index_build_s'] * 1000:.0f} ms"
        a(f"| {r['label']} | {fmt_pct(o['recall@10'])} | {fmt_pct(o['precision@10'])} | "
          f"{fmt_pct(o['recall_all'])} | {o['empty_positives']}/{o['n_positive']} | "
          f"{o['errors']}/{o['n_queries']} | "
          f"{o['neg_with_fp']}/{o['n_negative']} | {size_s} | {idx_s} | {pre_s} | {bld_s} | "
          f"{fmt_ms(o['lat_cold_p50_ms'])}/{fmt_ms(o['lat_cold_p95_ms'])} | "
          f"{fmt_ms(o['lat_hot_p50_ms'])}/{fmt_ms(o['lat_hot_p95_ms'])} |")
    a("")
    a(f"基准库（只有 `docs` 表 + 6 个索引，正文 TEXT 明文）= **{human_bytes(base_size)}**，"
      f"正文本身 {corpus['text_utf8_bytes'] / 1024 / 1024:.2f} MiB。")
    a("")
    a("`dbstat` 逐表明细（字节，`VACUUM` 后）——只列 FTS 影子表与 `docs` 表：")
    a("")
    fts_tabs = ["text_fts_data", "text_fts_idx", "text_fts_docsize", "text_fts_config"]
    a("| 方案 | docs 表 | " + " | ".join(f"`{t}`" for t in fts_tabs) + " | FTS 小计 |")
    a("|---|---:|" + "---:|" * (len(fts_tabs) + 1))
    for eng in engines:
        ds = build_info[eng]["dbstat"]
        vals = [ds.get(t, 0) for t in fts_tabs]
        a(f"| {eng} | {ds.get('docs', 0):,} | " + " | ".join(f"{v:,}" for v in vals)
          + f" | {sum(vals):,} |")
    a("")
    a("`text_fts_data` 是倒排表本体，其余是配置与文档长度表。`docs` 表在各方案里一样"
      f"（{build_info[engines[0]]['dbstat'].get('docs', 0):,} 字节），"
      "因为原文没有被 FTS 复制一份——这是 `content=''` 的作用。")
    a("")
    if scan_mib_per_s:
        a(f"全表 `LIKE` 扫描吞吐 ≈ **{scan_mib_per_s:.0f} MiB/s 正文**"
          f"（{corpus['docs']} 条 / {corpus['text_utf8_bytes'] / 1024 / 1024:.2f} MiB 正文，热 p50 "
          f"{results['SCAN_ALL']['overall']['lat_hot_p50_ms']:.2f} ms）。")
    a("")
    a("## 5. 分类 Recall@10")
    a("")
    hdr = "| 类别 | " + " | ".join(order) + " |"
    a(hdr)
    a("|---" * (len(order) + 1) + "|")
    for cls in qs["classes"]:
        cells = [fmt_pct(results[k]["by_class"][cls]["recall@10"]) for k in order]
        a(f"| {cls} | " + " | ".join(cells) + " |")
    a("")
    a("代号：" + "；".join(f"`{k}` = {results[k]['label']}" for k in order))
    a("")
    a("### 分类 Precision@10（只统计返回了结果的正例）")
    a("")
    a(hdr)
    a("|---" * (len(order) + 1) + "|")
    for cls in qs["classes"]:
        cells = [fmt_pct(results[k]["by_class"][cls]["precision@10"]) for k in order]
        a(f"| {cls} | " + " | ".join(cells) + " |")
    a("")
    a("### 分类 Recall_all（索引能力，忽略排序）")
    a("")
    a(hdr)
    a("|---" * (len(order) + 1) + "|")
    for cls in qs["classes"]:
        cells = [fmt_pct(results[k]["by_class"][cls]["recall_all"]) for k in order]
        a(f"| {cls} | " + " | ".join(cells) + " |")
    a("")
    a("### 分类热 p95 延迟（ms）")
    a("")
    a(hdr)
    a("|---" * (len(order) + 1) + "|")
    for cls in qs["classes"]:
        cells = [fmt_ms(results[k]["by_class"][cls]["lat_hot_p95_ms"]) for k in order]
        a(f"| {cls} | " + " | ".join(cells) + " |")
    a("")
    a("## 6. 报错与负例")
    a("")
    a("| 方案 | 报错查询数 | 报错率 | 报错样例 |")
    a("|---|---:|---:|---|")
    for k in order:
        rows = results[k]["per_query"]
        errs = [r for r in rows if r["error"]]
        ex = f"`{errs[0]['q']}` → {errs[0]['error']}" if errs else "—"
        a(f"| {results[k]['label']} | {len(errs)} | {len(errs) / len(rows) * 100:.1f}% | {ex} |")
    a("")
    a("负例（应无结果）共 " + str(len([s for s in queries if s['expect'] == 'none'])) + " 条：")
    a("")
    a("| 方案 | 有假阳性的负例数 | 前 10 条里的假阳性总条数 |")
    a("|---|---:|---:|")
    for k in order:
        o = results[k]["overall"]
        a(f"| {results[k]['label']} | {o['neg_with_fp']}/{o['n_negative']} | {o['neg_fp_rows']} |")
    a("")
    a("### 短查询补扫描：走了哪些通道，窗口内召回多少")
    a("")
    a(f"下表列出所有 1~2 个汉字的正例查询。窗口内 Recall_all 的真值只算最近 {SCAN_WINDOW_DAYS} 天的文档；"
      "全局 Recall_all 是对整个 30 天语料算的。")
    a("")
    hdr2 = ("| 查询 | 全局相关 | 窗口内相关 | " +
            " | ".join(f"{k} 通道 / 全局 / 窗口内" for k in [f"{e}+E" for e in fts_engines]) + " |")
    a(hdr2)
    a("|---|---:|---:|" + "---|" * len(fts_engines))
    short_ids = [x["id"] for x in queries if x["expect"] == "hit" and is_short_cjk(x["q"])]
    for i, spec in enumerate(queries):
        if spec["id"] not in short_ids:
            continue
        cells = []
        for e in fts_engines:
            r = results[f"{e}+E"]["per_query"][i]
            ch = "+".join(c.split(":")[0] for c in r["channels"])
            cells.append(f"{ch} / {fmt_pct(r['recall_all'])} / {fmt_pct(r['recall_all_in_range'])}")
        base = results[f"{fts_engines[0]}+E"]["per_query"][i]
        a(f"| `{spec['q']}` | {base['relevant']} | {base['relevant_in_range']} | "
          + " | ".join(cells) + " |")
    a("")
    ap = app_scope or {}
    a("### 限定「时间窗口 + 应用」的扫描（`scan=app`）")
    a("")
    a(f"计划 3.4 对一两字查询的回退是「限定**时间或应用**范围的扫描」。上表只限了时间窗口"
      f"（最近 {ap.get('window_days', SCAN_WINDOW_DAYS)} 天 = {ap.get('docs_in_window', 0)} 条），"
      "这一档再叠加应用限定，直接用 `docs(app, ts)` 复合索引先切范围再扫正文：")
    a("")
    a("```sql")
    a("SELECT id FROM docs WHERE ts >= ? AND app = ? AND text LIKE ? ESCAPE '\\'")
    a("ORDER BY ts DESC LIMIT ?;")
    a("```")
    a("")
    a("**口径**：假定用户提问时已经把应用说清楚了（「上周在**飞书**里说的预算」），"
      "所以每条查询取「窗口内相关文档最多的那个应用」当作用户指定的范围，"
      "真值 = 窗口内 ∩ 该应用 的相关文档。这一档只回答「在用户给定的范围里扫描能不能全召回、要多久」，"
      "不与 FTS 各档比排名。")
    a("")
    if ap.get("rows"):
        a("| 查询 | 指定应用 | 窗口内该应用文档数 | 范围内相关篇数 | 范围内召回 | 热 p50 / p95 (ms) | 只限时间的 p50 / p95 (ms) |")
        a("|---|---|---:|---:|---:|---:|---:|")
        for r in ap["rows"]:
            a(f"| `{r['q']}` | {r['app']} | {r['scope_docs']} | {r['relevant_in_scope']} | "
              f"{fmt_pct(r['recall_in_scope'])} | {r['hot_p50_ms']:.2f} / {r['hot_p95_ms']:.2f} | "
              f"{r['range_only_p50_ms']:.2f} / {r['range_only_p95_ms']:.2f} |")
        a("")
        rec = [r["recall_in_scope"] for r in ap["rows"] if r["recall_in_scope"] is not None]
        gain = [r["range_only_p50_ms"] / r["hot_p50_ms"] for r in ap["rows"] if r["hot_p50_ms"]]
        rec_txt = (f"全部为 {min(rec) * 100:.1f}%" if abs(max(rec) - min(rec)) < 1e-9
                   else f"{min(rec) * 100:.1f}%–{max(rec) * 100:.1f}%")
        a(f"{len(ap['rows'])} 条查询在指定范围内的召回{rec_txt}（扫描是精确子串匹配，范围内不会漏），"
          f"比只限时间窗口再快 {min(gain):.1f}×–{max(gain):.1f}×。查询计划："
          f"`{ap['rows'][0]['plan']}`——`app = ?` 走 `idx_docs_app_ts` 先把范围切出来，"
          "正文 `LIKE` 只在这几百行上跑。")
        a("")
        a("> 注意这不是「应用列查询」的完整评测：`app` 列本轮只用于**限定扫描范围**，"
          "没有出「查某个应用下所有内容」这类题（见 §9.5）。")
    else:
        a("本轮没有可用的短查询样本，这一档未跑。")
    a("")
    a("## 7. 精确字段的查询计划")
    a("")
    a(f"`EXPLAIN QUERY PLAN` 与热执行均值（基准库，{corpus['docs']} 行，200 次取平均，`ANALYZE` 过）：")
    a("")
    a("| 查询形态 | 计划 | 热均值 (ms) |")
    a("|---|---|---:|")
    for name, info in eqp.items():
        a(f"| {name} | `{' / '.join(info['plan'])}` | {info['hot_ms']:.3f} |")
    a("")
    a("等值和前缀能走索引 seek，后缀/子串只能扫——但扫 `host`/`url`/`path` 这些窄列比扫 `text` 便宜得多，"
      "这就是把它们拆成独立列的价值（计划 3.4 第一条）。")
    a("")
    a("**一个必须写进 schema 的细节**：`COLLATE NOCASE` 要写在**列**上，不能只写在索引上。"
      "SQLite 的 `col = ?` 用的是列的排序规则，列是 BINARY 而索引是 NOCASE 时，等值查询用不上那个索引。"
      "下面是 20,000 行的独立对照（内存库，`ANALYZE` 过，200 次热执行均值）：")
    a("")
    cp = payload.get("collate_probe", {})
    a("| schema | `host = ?` 的计划 | 热均值 (ms) |")
    a("|---|---|---:|")
    for tag in ("索引 NOCASE、列 BINARY", "列与索引都 NOCASE"):
        if tag in cp:
            a(f"| {tag} | `{cp[tag]['plan']}` | {cp[tag]['hot_ms']:.3f} |")
    a("")
    if all(t in cp for t in ("索引 NOCASE、列 BINARY", "列与索引都 NOCASE")):
        r1 = cp["索引 NOCASE、列 BINARY"]["hot_ms"]
        r2 = cp["列与索引都 NOCASE"]["hot_ms"]
        a(f"差 **{r1 / r2:.0f} 倍**（{r1:.3f} ms vs {r2:.3f} ms，20,000 行）。"
          "行数越多差得越大，因为前者是全表扫。")
    a("")
    a("同一个 20,000 行库上各类精确字段查询的成本：")
    a("")
    a("| 查询形态 | 计划 | 热均值 (ms) |")
    a("|---|---|---:|")
    for k, v in cp.get("shapes", {}).items():
        a(f"| {k} | `{v['plan']}` | {v['hot_ms']:.3f} |")
    a("")
    a("## 8. 逐查询明细（重点方案）")
    a("")
    detail_keys = [k for k in order if k.endswith("+E")] + ["B+E+V"]
    a("| 查询 | 类别 | 相关篇数 | " + " | ".join(f"{k} R@10" for k in detail_keys) + " |")
    a("|---|---|---:|" + "---:|" * len(detail_keys))
    for i, spec in enumerate(queries):
        rows = [results[k]["per_query"][i] for k in detail_keys]
        base = rows[0]
        cells = [(fmt_pct(r["recall@10"]) if r["expect"] == "hit"
                  else ("0 假阳性" if r["returned_top10"] == 0 else f"{r['returned_top10']} 假阳性"))
                 for r in rows]
        a(f"| `{spec['q']}` | {spec['class']} | {base['relevant']} | " + " | ".join(cells) + " |")
    a("")
    L.extend(render_conclusion(payload, qs, results, build_info, base_size, scan_mib_per_s,
                               corpus, app_scope))
    return "\n".join(L) + "\n"


# 附加实测：Swift 原生中文分词。样例与 tools/bench/nl_tokenize_probe.swift 一致，
# NL/CF 两列是那个脚本 2026-09-06 在本机的实际输出（Xcode 26.6 / Swift 6.3）。
NL_SAMPLES = [
    "知识图谱与实施计划的采集覆盖率",
    "SQLCipher 构建与 FTS5 分词对照",
    "数据保留策略需要再确认一遍",
    "双击标题栏可以最大化窗口",
    "无障碍权限没打开导致采集失败",
    "复核parseObservation的边界条件",
    "预算从 100 改成 200",
]
NL_OUTPUT = {
    "知识图谱与实施计划的采集覆盖率": "知识/图谱/与/实施/计划/的/采集/覆盖率",
    "SQLCipher 构建与 FTS5 分词对照": "SQLCipher/构建/与/FTS/5/分词/对照",
    "数据保留策略需要再确认一遍": "数据/保留/策略/需要/再/确认/一/遍",
    "双击标题栏可以最大化窗口": "双击/标题栏/可以/最大化/窗口",
    "无障碍权限没打开导致采集失败": "无障碍/权限/没/打开/导致/采集/失败",
    "复核parseObservation的边界条件": "复核/parseObservation/的/边界/条件",
    "预算从 100 改成 200": "预算/从/100/改/成/200",
}
NL_PROBE = {
    "throughput": "3200 条 / 379,690 字符 / 192,000 token，125 ms → 3.05 M 字符/秒"
                  "（复用同一个 NLTokenizer 实例）",
    "naive": "每次新建 NLTokenizer 实例只有 0.61 M 字符/秒（400 条 / 47,090 字符 / 77 ms），实例必须复用",
    "note": "CFStringTokenizer(zh_CN) 在这 7 个样例上与 NLTokenizer 输出完全一致",
}


def render_conclusion(payload, qs, results, build_info, base_size, scan_mib_per_s,
                      corpus, app_scope):
    L: list[str] = []
    a = L.append

    def o(k):
        return results[k]["overall"]

    has_d = "D" in build_info and "D+E" in results   # 没装 jieba 时方案 D 整档缺席
    text_mib = corpus["text_utf8_bytes"] / 1024 / 1024
    a("## 9. 结论")
    a("")
    a("### 9.1 F3 的三条结论在 3200 条语料上全部复现")
    a("")
    a(f"- `trigram, detail=column`（原可行性报告选的配置）：68 条查询里 "
      f"**{o('Ccol')['errors']} 条直接抛 `fts5: phrase queries are not supported (detail!=full)`**，"
      f"报错率 {o('Ccol')['errors'] / o('Ccol')['n_queries'] * 100:.0f}%，Recall@10 = 0。这个配置不能用。")
    a(f"- `unicode61` 原样：中文两字词 Recall@10 "
      f"{fmt_pct(results['A']['by_class']['中文两字词']['recall@10'])}、"
      f"中文三字以上 {fmt_pct(results['A']['by_class']['中文三字以上']['recall@10'])}、"
      f"单个汉字 {fmt_pct(results['A']['by_class']['单个汉字']['recall@10'])}。"
      "原因是 unicode61 把连续汉字当成一个 token（连中英之间也不断，`复核parseObservation的边界条件` 是一个 token），"
      "只有当目标词恰好被空格或标点隔成独立段时才命中。英文、标识符、URL、路径、错误码则 100%。")
    a(f"- `trigram, detail=full`：三字以上中文 100%，但**两字及一字查询恒为 0**（trigram 需要至少 3 个字符），"
      "而且不报错、静默返回 0 条——比报错更危险，必须在查询规划层显式拦截。")
    a("")
    a("### 9.2 推荐方案")
    a("")
    a("**推荐：B+E+V —— 汉字 bigram 预处理 + unicode61 + 精确字段列 + 单字补扫描 + 候选子串复核。**")
    a("")
    a("| 指标 | B+E+V | 对比 |")
    a("|---|---|---|")
    a(f"| Recall@10 | {fmt_pct(o('B+E+V')['recall@10'])} | C+E {fmt_pct(o('C+E')['recall@10'])}，"
      f"A+E {fmt_pct(o('A+E')['recall@10'])}"
      + (f"，D+E {fmt_pct(o('D+E')['recall@10'])} |" if has_d else "（方案 D 未跑）|"))
    a(f"| Precision@10 | {fmt_pct(o('B+E+V')['precision@10'])} | 全表扫描 100%（真值定义即全表扫描） |")
    a(f"| 索引净增 | {human_bytes(build_info['B']['index_bytes'])} = 正文的 "
      f"{build_info['B']['index_bytes'] / corpus['text_utf8_bytes']:.2f} 倍 | "
      f"C（trigram）{human_bytes(build_info['C']['index_bytes'])} = "
      f"{build_info['C']['index_bytes'] / corpus['text_utf8_bytes']:.2f} 倍，"
      f"A {human_bytes(build_info['A']['index_bytes'])}"
      + (f"，D {human_bytes(build_info['D']['index_bytes'])} |" if has_d else " |"))
    a(f"| 建索引 | 预处理 {build_info['B']['preprocess_s'] * 1000:.0f} ms + 写索引 "
      f"{build_info['B']['index_build_s'] * 1000:.0f} ms（{corpus['docs']} 条 / {text_mib:.2f} MiB） | "
      f"C {build_info['C']['index_build_s'] * 1000:.0f} ms"
      + (f"，D 预处理 {build_info['D']['preprocess_s'] * 1000:.0f} ms |" if has_d else " |"))
    a(f"| 热查询 p50/p95 | {fmt_ms(o('B+E+V')['lat_hot_p50_ms'])} / "
      f"{fmt_ms(o('B+E+V')['lat_hot_p95_ms'])} ms | 全表扫描 "
      f"{fmt_ms(o('SCAN_ALL')['lat_hot_p50_ms'])} / {fmt_ms(o('SCAN_ALL')['lat_hot_p95_ms'])} ms |")
    a(f"| 冷查询 p50/p95 | {fmt_ms(o('B+E+V')['lat_cold_p50_ms'])} / "
      f"{fmt_ms(o('B+E+V')['lat_cold_p95_ms'])} ms | 冷含新建连接，见 §1 口径 |")
    a("")
    a("理由：")
    a("")
    a(f"1. **中文召回**：bigram 让 2 字及以上的中文查询恢复到 100%（A 只有 "
      f"{fmt_pct(results['A']['by_class']['中文两字词']['recall@10'])} / "
      f"{fmt_pct(results['A']['by_class']['中文三字以上']['recall@10'])}），"
      "而且不依赖词典，不会因为分词边界错位漏检。")
    a(f"2. **体积**：索引只有正文的 {build_info['B']['index_bytes'] / corpus['text_utf8_bytes']:.2f} 倍，"
      f"trigram 是 {build_info['C']['index_bytes'] / corpus['text_utf8_bytes']:.2f} 倍——"
      f"差 {build_info['C']['index_bytes'] / build_info['B']['index_bytes']:.1f} 倍。"
      "在 5 GB 配额（3.8）下这是实打实的保留天数差异。")
    a("3. **不依赖第三方分词库**：bigram 是二十行代码，产品里用 Swift 重写没有风险；"
      "jieba 是 Python 库，不可能进 Swift app（Swift 原生替代见 §10）。")
    # 复核的效果用 path-01 这条查询的实测数据说明，不做无根据的"提升"断言
    def pq(scheme, qid):
        return next(r for r in results[scheme]["per_query"] if r["id"] == qid)
    a1, b1, v1 = pq("A+E", "path-01"), pq("B+E", "path-01"), pq("B+E+V", "path-01")
    a(f"4. **复核是给 unicode61 忽略标点上保险**：`unicode61` 丢掉所有标点，"
      "`~/Library/Caches/brosis-build` 和 `~/Library/Caches/brosis-build` "
      "在索引里是同一串 token。这条查询在 A+E 下前 10 条只有 "
      f"{a1['hits_top10']} 条真的含该子串（Precision@10 {fmt_pct(a1['precision@10'])}），"
      f"B+E 恰好排对了（{fmt_pct(b1['precision@10'])}）——但那是 bm25 文档长度归一化的运气，"
      "不是 bigram 的结构性优势，bigram 完全不改变非汉字部分的索引。"
      f"加上复核后返回条数从 {b1['returned']} 降到 {v1['returned']}（= 相关文档总数 {v1['relevant']}），"
      f"整套查询集的 Precision@10 由 {fmt_pct(o('B+E')['precision@10'])} 变为 "
      f"{fmt_pct(o('B+E+V')['precision@10'])}（本轮两者都已满分，复核买的是「不靠运气」），"
      f"代价是热 p95 从 {fmt_ms(o('B+E')['lat_hot_p95_ms'])} ms 到 "
      f"{fmt_ms(o('B+E+V')['lat_hot_p95_ms'])} ms。默认打开。")
    a("")
    a("**不推荐 trigram detail=full 作为主索引**，但它有一个真实优势：trigram 的 phrase 等价于精确子串，"
      f"Precision 天然 100%，不需要复核。如果将来体积不再是约束，或者出现大量「任意子串」需求，"
      "它是唯一不需要额外复核的选项。现在的取舍是体积。")
    a("")
    a("### 9.3 必须走精确字段或扫描的查询类别")
    a("")
    a("| 查询类别 | 走哪条通道 | 依据 |")
    a("|---|---|---|")
    a(f"| URL、域名 | `urls` 表的 `canonical_url` / `host` 列，等值或前缀，走索引；再并上 FTS | "
      f"仅精确字段档 Recall_all 在 URL 类已有 "
      f"{fmt_pct(results['E']['by_class']['URL/域名']['recall_all'])}，"
      "剩下的是「链接被人贴在聊天正文里」的情况，只能靠 FTS |")
    a(f"| 文件路径 | `files.path` 列 `LIKE`；再并上 FTS | 仅精确字段档在路径类 Recall_all "
      f"{fmt_pct(results['E']['by_class']['文件路径']['recall_all'])}，"
      "大部分路径其实出现在终端回显和代码注释里，必须同时查正文 |")
    a("| 应用名、窗口标题 | `apps` / `windows` 规范化对象，等值 | 本轮未单独出题，但同理：这些是结构字段不是正文 |")
    a("| **单个汉字** | 必须走限定时间/应用范围的 `LIKE` 扫描 | bigram、trigram、unicode61 三种索引在单字类 "
      "Recall@10 都是 0"
      + (f"（jieba 靠词典偶然拿到 {fmt_pct(results['D']['by_class']['单个汉字']['recall@10'])}，"
         "不可依赖）|" if has_d else " |"))
    a(f"| 两字中文（若选 trigram） | 必须走扫描 | C 在两字类 Recall@10 "
      f"{fmt_pct(results['C']['by_class']['中文两字词']['recall@10'])}，且静默返回空 |")
    a("")
    a(f"扫描成本实测：全表 `LIKE` 在 {corpus['docs']} 条 / {text_mib:.2f} MiB 正文上热 p50 "
      f"{fmt_ms(o('SCAN_ALL')['lat_hot_p50_ms'])} ms、p95 {fmt_ms(o('SCAN_ALL')['lat_hot_p95_ms'])} ms，"
      f"吞吐约 **{scan_mib_per_s:.0f} MiB/s 正文**。按这个吞吐外推："
      f"正文 100 MiB 的库全表扫一次约 {100 / scan_mib_per_s * 1000:.0f} ms，"
      f"1 GiB 约 {1024 / scan_mib_per_s:.1f} s。所以单字查询必须限定范围——"
      f"最近 {SCAN_WINDOW_DAYS} 天的窗口在本轮只占 "
      f"{corpus['scan_window_docs'] / corpus['docs'] * 100:.0f}% 的行，实测 p95 "
      f"{fmt_ms(o('SCAN_7D')['lat_hot_p95_ms'])} ms；再叠加应用限定见 §6 的 `scan=app` 一档。"
      f"**这些数字来自 {text_mib:.2f} MiB 语料，"
      "不能直接当作产品规模的结论**，M1 要在真实体量上复测。")
    a("")
    a("### 9.4 给 T4 / T5 的建表语句")
    a("")
    a("```sql")
    a("-- 原文：明文 TEXT，直接放在 SQLCipher 库里（计划 3.4：v1 不做 zstd BLOB 外部内容）")
    a("CREATE TABLE text_versions (")
    a("  id        INTEGER PRIMARY KEY,")
    a("  sha256    BLOB    NOT NULL UNIQUE,")
    a("  text      TEXT    NOT NULL,")
    a("  byte_len  INTEGER NOT NULL,")
    a("  created_at INTEGER NOT NULL")
    a(");")
    a("")
    a("-- 全文索引：contentless（不重复存正文），bigram 预处理后的文本写进来。")
    a("-- contentless_delete=1 让删除可以只按 rowid 执行，配合 3.8 的级联删除。")
    a("-- 需要 SQLite >= 3.43；本机 " + payload["env"]["sqlite_library"] + " 已验证可用。")
    a("CREATE VIRTUAL TABLE text_fts USING fts5(")
    a("  body,")
    a("  tokenize = \"unicode61 remove_diacritics 2\",")
    a("  content = '',")
    a("  contentless_delete = 1")
    a(");")
    a("-- 写入：INSERT INTO text_fts(rowid, body) VALUES (:text_version_id, :bigrammed);")
    a("-- 删除：DELETE FROM text_fts WHERE rowid = :text_version_id;")
    a("")
    a("-- 精确字段：独立列，不经 FTS（计划 3.4 第一条）。")
    a("-- COLLATE NOCASE 必须写在【列】上：`col = ?` 用的是列的排序规则，")
    cp = payload.get("collate_probe", {})
    if all(t in cp for t in ("索引 NOCASE、列 BINARY", "列与索引都 NOCASE")):
        _r = cp["索引 NOCASE、列 BINARY"]["hot_ms"] / cp["列与索引都 NOCASE"]["hot_ms"]
        a(f"-- 只给索引加 NOCASE 时等值查询走不了索引（§7 实测差 {_r:.0f} 倍，两个数量级）。")
    else:
        a("-- 只给索引加 NOCASE 时等值查询走不了索引（量级见 §7）。")
    a("CREATE TABLE urls (")
    a("  id            INTEGER PRIMARY KEY,")
    a("  raw_locator   TEXT NOT NULL,                 -- 原始定位信息，不做规范化")
    a("  canonical_url TEXT NOT NULL COLLATE NOCASE,")
    a("  host          TEXT COLLATE NOCASE,")
    a("  kind          TEXT")
    a(");")
    a("CREATE INDEX idx_urls_host  ON urls(host);           -- 裸域名等值：索引 seek")
    a("CREATE INDEX idx_urls_canon ON urls(canonical_url);  -- 完整 URL：前缀 LIKE 走范围")
    a("")
    a("CREATE TABLE files (")
    a("  id   INTEGER PRIMARY KEY,")
    a("  path TEXT NOT NULL COLLATE NOCASE")
    a(");")
    a("CREATE INDEX idx_files_path ON files(path);  -- 子串 LIKE 仍是扫描，但只扫这一窄列")
    a("")
    a("-- 扫描回退要用的复合索引（按时间/应用先切范围，再扫正文）")
    a("CREATE INDEX idx_obs_ts      ON observations(ts);")
    a("CREATE INDEX idx_obs_app_ts  ON observations(app_id, ts);")
    a("```")
    a("")
    a("查询规划（`search(q, start, end, app, limit)`）按下面的顺序，全部结果取并集后去重：")
    a("")
    a("```")
    a("1. q 形如 URL / 域名        -> urls.host 等值或后缀、urls.canonical_url 前缀/子串")
    a("2. q 形如路径               -> files.path 子串")
    a("3. q 是 1 个汉字            -> 在 [start,end] + app 范围内对 text_versions.text 做 LIKE 扫描")
    a("   （范围为空时拒绝执行，提示用户先缩小时间或应用范围）")
    a("4. 其余                     -> bigram(q) 包成 phrase 查 text_fts，按 bm25 取候选")
    a("5. 【只对第 4 步的 FTS 候选】用 LIKE '%q%' 复核精确子串，滤掉分词带来的假阳性")
    a("6. 1/2/3/5 四路结果取并集去重，按 bm25 / 时间倒序输出")
    a("")
    a("第 5 步**不能**作用在第 1~3 步的结果上：那三路本身就是精确匹配，")
    a("urls/files 命中而正文里没抄这条 URL/路径是正常的，复核会把正确结果误删。")
    a("```")
    a("")
    a("### 9.5 尚未验证、留给后续的点")
    a("")
    a("- 本轮用的是 **Python 链接的 SQLite " + payload["env"]["sqlite_library"] +
      "**，不是产品要用的 SQLCipher 构建。`contentless_delete`、trigram、bm25 都要在 E6 选定的 "
      "SQLCipher 上重新验证一次。")
    a(f"- 语料只有 {corpus['docs']} 条 / {text_mib:.2f} MiB，比真实库小两三个数量级。"
      "体积比例（索引/正文）在更大语料上会变，扫描延迟更会变。")
    a("- 真值口径是「精确子串」，对 OCR 错字、同义词、拼音输入没有任何覆盖。"
      "这些属于向量检索（D8）要解决的问题，不在本轮范围。")
    a("- 排序只用 bm25，没有做时间衰减、应用权重、去重合并。M1 的 `search` 要重新定排序。")
    a("- **`app` 列本轮只测了「限定扫描范围」这一种用法**（§6 的 `scan=app`）："
      "没有出「列出某应用下全部内容」「按应用做 facet 过滤」这类题，也没有把 app 当成查询词"
      "（查「飞书」时命中的是正文里出现的这两个字，不是 `app = '飞书'`）。"
      "这两类查询要等 D12 的真实题到位后补。")
    a("- 子串匹配本轮用 `LIKE ... ESCAPE` 而不是规格里写的 `instr()`，理由见 §1 口径"
      "（语义等价，但 `LIKE` 对 ASCII 大小写不敏感，与精确字段列的 `COLLATE NOCASE` 一致）。"
      "产品换成 `instr()` 时要连真值口径一起换。")
    a("- 查询集是合成的（D12 真实题未提供）。真实题到位后必须复跑一次，别拿这版数字当最终结论。")
    a("")
    if not has_d:
        a("> 本次运行没有 jieba，方案 D 与 §10 的 jieba 对照未执行。"
          "完整结论见 README 里的完整跑法。")
        a("")
        return L
    a("## 10. 附：Swift 原生中文分词的可行性（补充实测）")
    a("")
    a("方案 D 用的 jieba 是 Python 库，产品是 Swift app，不能直接用。为了判断「显式分词」这条路是否被堵死，"
      "另外跑了 `tools/bench/nl_tokenize_probe.swift`（Xcode 26.6 / Swift 6.3，系统框架，无第三方依赖）：")
    a("")
    a("| 样例 | jieba（方案 D，本轮实跑） | Swift `NLTokenizer` / `CFStringTokenizer` |")
    a("|---|---|---|")
    for smp in NL_SAMPLES:
        jb = payload.get("nl_probe", {}).get("jieba", {}).get(smp, "—")
        a(f"| `{smp}` | `{jb}` | `{NL_OUTPUT[smp]}` |")
    a("")
    a("| 项 | 结果 |")
    a("|---|---|")
    a(f"| 吞吐 | {NL_PROBE['throughput']} |")
    a(f"| 陷阱一 | {NL_PROBE['naive']} |")
    a("| 陷阱二 | `SQLCipher 构建与 FTS5 分词对照` → `SQLCipher/构建/与/**FTS/5**/分词/对照`，"
      "**字母数字混排的标识符会被切开**；走词典分词就必须对标识符、错误码、URL 单独保留原样 token |")
    a(f"| 一致性 | {NL_PROBE['note']} |")
    a("")
    jb = payload.get("nl_probe", {}).get("jieba", {})
    same = sum(1 for smp in NL_SAMPLES if jb.get(smp) == NL_OUTPUT[smp])
    a(f"结论：Swift 侧确实有中文分词能力，7 个样例里 **{same} 个与 jieba 完全一致**，"
      f"其余 {len(NL_SAMPLES) - same} 个只是粒度不同（`一遍`/`边界条件`/`改成` 被拆得更碎，"
      "`FTS5` 被切成 `FTS`/`5`）。速度也够用（3.05 M 字符/秒，与 bigram 预处理同一量级）。")
    a("")
    a("**但这不足以改变推荐。** 分词方案的召回取决于词典边界，两边都暴露了同一个问题："
      "jieba 把 `边界条件` 当成一个词，那么查 `边界` 就不会命中——查词典里没有的词"
      "（产品名、内部黑话、错别字、OCR 出来的半截词）同理会漏；bigram 没有这个失败模式。"
      "词典分词留作 M1 之后的可选增强（例如与 bigram 并联提升排序），不作为 v1 主路径。")
    a("")
    return L


if __name__ == "__main__":
    raise SystemExit(main())
