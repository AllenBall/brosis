#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M0 / E3：确定性合成观察流生成器。

只用 Python 标准库。相同 --seed / --days / --per-day / --devices 生成完全相同的库内容
（内容摘要用 --digest 校验）。

用法：
    python3 gen_synth.py --days 7 --per-day 120 --seed 20260906 --devices 2 \
        --out ~/Library/Caches/brosis-build/proto/synth.db

生成的内容覆盖 E3 需要的四种情形：
  1. 应用切换：观察流按确定性模式在 8 个应用之间切换；
  2. 文本版本复用：段落取自固定语料池，相同文本按 sha256 复用同一个 text_version；
  3. 正文修改：每天同一份「项目 A 季度规划」文档先后出现 预算 100 万元 / 预算 200 万元 两版；
  4. 两个 device_id：默认 dev-mbp16 与 dev-mba13，主键都带 device_id（D17）。
"""

import argparse
import hashlib
import json
import os
import random
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "schema.sql")

# 时间锚点：固定 UTC，避免本机时区影响确定性。最后一天 = 2026-09-06。
ANCHOR_UTC = datetime(2026, 9, 6, 0, 0, 0, tzinfo=timezone.utc)
DAY_START_S = 9 * 3600          # 每天 09:00 开始
DAY_SPAN_S = 9 * 3600           # 覆盖 9 小时到 18:00

DEVICE_NAMES = ["dev-mbp16", "dev-mba13", "dev-mini", "dev-studio"]

# (bundle_id, 显示名, 载体类型, 采集模式, 主要 capture_method)
APPS = [
    ("com.electron.lark",        "飞书",           "chat",    "events_and_content", "adapter"),
    ("com.tencent.xinWeChat",    "微信",           "chat",    "events_and_content", "ocr"),
    ("com.apple.Safari",         "Safari",         "web",     "events_and_content", "ax"),
    ("com.google.Chrome",        "Google Chrome",  "web",     "events_and_content", "ax"),
    ("com.microsoft.VSCode",     "Visual Studio Code", "file", "events_and_content", "ax"),
    ("com.apple.dt.Xcode",       "Xcode",          "file",    "events_and_content", "mixed"),
    ("com.apple.Terminal",       "Terminal",       "file",    "events_and_content", "ocr"),
    ("md.obsidian",              "Obsidian",       "file",    "events_and_content", "ax"),
]
DENYLIST_APPS = [("com.1password.1password", "1Password"), ("com.apple.keychainaccess", "钥匙串访问")]

WINDOW_TITLES = {
    "com.electron.lark": ["飞书 — 项目 A 群", "飞书 — 文件传输助手", "飞书 — 周会纪要"],
    "com.tencent.xinWeChat": ["微信", "微信 — 文件传输助手"],
    "com.apple.Safari": ["SQLite FTS5 文档", "Screen Capture Kit — Apple Developer", "项目 A 季度规划"],
    "com.google.Chrome": ["brosis 需求看板", "Vision 框架参考", "项目 A 季度规划"],
    "com.microsoft.VSCode": ["schema.sql — brosis", "gen_synth.py — brosis", "README.md — brosis"],
    "com.apple.dt.Xcode": ["brosis.xcodeproj", "Recorder.swift"],
    "com.apple.Terminal": ["zsh — brosis", "sqlite3 — proto"],
    "md.obsidian": ["项目 A 季度规划.md", "每日笔记 2026-09.md"],
}

URLS = [
    ("https://sqlite.org/fts5.html#the_trigram_tokenizer",
     "https://sqlite.org/fts5.html#the_trigram_tokenizer", "sqlite.org", "web"),
    ("https://developer.apple.com/documentation/screencapturekit?language=swift",
     "https://developer.apple.com/documentation/screencapturekit?language=swift",
     "developer.apple.com", "web"),
    ("https://example-corp.feishu.cn/docx/BdX1p2?from=space#heading-budget",
     "https://example-corp.feishu.cn/docx/BdX1p2?from=space#heading-budget",
     "example-corp.feishu.cn", "doc"),
    ("https://kanban.internal.example.com/board/7?filter=mine",
     "https://kanban.internal.example.com/board/7?filter=mine",
     "kanban.internal.example.com", "web"),
    ("file:///Users/demo/Notes/%E9%A1%B9%E7%9B%AE%20A.md",
     "file:///Users/demo/Notes/项目 A.md", None, "file"),
]

FILES = [
    "/Users/demo/dev/brosis/tools/proto/schema.sql",
    "/Users/demo/dev/brosis/tools/proto/gen_synth.py",
    "/Users/demo/Notes/项目 A 季度规划.md",
    "/Users/demo/dev/brosis/Recorder.swift",
    "/Users/demo/Downloads/2026Q3 预算表.numbers",
]

# 固定语料池：中英混排、代码、URL、路径、短词，供文本版本复用
CORPUS = [
    "会议纪要：项目 A 的采集范围先覆盖飞书与微信，其余应用按停留时长排序逐步加入。",
    "Recall@10 在合成证据集上是 0.82，引用有效率 0.91，两项都要在真实题上复跑。",
    "SELECT id, sha256, byte_len FROM text_versions WHERE device_id = ? ORDER BY created_at DESC LIMIT 20;",
    "note: AXManualAccessibility must be set on the Electron app element before reading the AX tree.",
    "错误：the database disk image is malformed —— 说明 WAL 与主库文件被分别同步过。",
    "let stream = try SCStream(filter: filter, configuration: config, delegate: self)",
    "参考 https://sqlite.org/fts5.html#the_trigram_tokenizer 里关于 detail=full 的说明。",
    "路径 /Users/demo/dev/brosis/tools/proto/schema.sql 里 auto_vacuum 必须在建表前设置。",
    "张三：预算表我今天下午改完发你。李四：好，改完在群里同步一下。",
    "TODO(M1)：把 observations 的 completeness 分布写进每日台账，方便判断哪些应用值得留正文。",
    "The trigram tokenizer indexes every three-character sequence, so index size grows fast.",
    "验收：删除后 search / get_evidence / get_context / get_day_ledger 均不返回对应内容。",
    "构建产物统一放 ~/Library/Caches/brosis-build/，项目目录里不放大量小文件。",
    "OCR 只对三类区域触发：AX 不可用、AX 值超阈值未变、覆盖检查失败。",
    "pragma integrity_check;  -- 崩溃重启后第一件事",
    "周会：本周把 E3 跑通，schema 定稿，删除级联的七个场景全部要有数字。",
    "备注",
    "已阅",
    "def canonicalize(raw: str) -> str:  # 不删有业务语义的查询参数和 hash 路由",
    "容量口径按实际 UTF-8 字节推算，不按行数或帧数。",
]

# 唯一片段模板：模拟屏幕上大量只出现一次的正文（占比 ~60%），让配额过期能真正回收版本
UNIQUE_TEMPLATES = [
    "[{day}] {app} 第 {k} 屏：{who} 在 {ch} 里回了「{word}」，需要在 {hh}:{mm} 前确认。",
    "[{day}] commit {sha} — {word}: 修改 {k} 处，涉及 tools/proto/{fname}",
    "[{day}] 日志 {hh}:{mm}:{ss} level=info seq={k} msg=\"{word} pipeline flushed\"",
    "[{day}] 搜索结果第 {k} 条：{word} —— https://example.com/r/{sha}?q={word}",
    "[{day}] {who}：{word}。（{hh}:{mm} 于 {app}，第 {k} 条）",
]
UNIQUE_WORDS = ["预算复核", "采集覆盖率", "trigram 索引", "WAL checkpoint", "AX 通知",
                "OCR 回退", "台账重算", "级联删除", "配额过期", "崩溃恢复",
                "canonical_url", "device_id", "occurrence", "text_version", "session 边界"]
UNIQUE_PEOPLE = ["张三", "李四", "王五", "Allen", "Chris"]
UNIQUE_CHANNELS = ["项目 A 群", "文件传输助手", "brosis 研发", "周会纪要"]

BUDGET_V1 = "项目 A 季度规划\n预算 100 万元\n负责人 张三\n状态 待评审"
BUDGET_V2 = "项目 A 季度规划\n预算 200 万元\n负责人 张三\n状态 已批准"

TRIGGERS = ["app_switch", "window_change", "url_change", "ax_notification", "frame_dirty", "timer"]
COMPLETENESS = (["complete"] * 14) + (["partial"] * 4) + ["unavailable", "excluded"]
SOURCE_STATES = (["ok"] * 17) + ["permission_lost", "timeout", "user_idle"]


# --------------------------------------------------------------------------- #
# 连接与 schema
# --------------------------------------------------------------------------- #
def connect(path):
    """打开已存在的库；每次打开都要重设连接级 PRAGMA。"""
    conn = sqlite3.connect(path, isolation_level=None)   # autocommit，PRAGMA 才生效
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA secure_delete = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.row_factory = sqlite3.Row
    return conn


def create_db(path, page_size=None):
    """删掉旧库（含 -wal / -shm）后按 schema.sql 重建。

    page_size 与 auto_vacuum 一样是**建第一张表之前**才能设的文件级参数，
    所以在这里设，不能等 schema.sql 跑完（T5 的页大小敏感性测量要用）。
    """
    for suffix in ("", "-wal", "-shm"):
        p = path + suffix
        if os.path.exists(p):
            os.remove(p)
    thumbs = thumb_dir(path)
    if os.path.isdir(thumbs):
        for name in os.listdir(thumbs):
            os.remove(os.path.join(thumbs, name))
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, isolation_level=None)
    if page_size:
        conn.execute("PRAGMA page_size = %d" % int(page_size))
    with open(SCHEMA_PATH, "r", encoding="utf-8") as fh:
        conn.executescript(fh.read())
    conn.close()
    return connect(path)


def thumb_dir(db_path):
    return os.path.abspath(db_path) + ".thumbs"


def make_unique_fragment(rng, day0, bundle, k, j):
    """确定性唯一片段：同一 (seed, day, k, j) 永远得到同一串。"""
    tmpl = UNIQUE_TEMPLATES[rng.randrange(len(UNIQUE_TEMPLATES))]
    name = next(a[1] for a in APPS if a[0] == bundle)
    return tmpl.format(
        day=day0.strftime("%Y-%m-%d"), app=name, k=k * 10 + j,
        who=UNIQUE_PEOPLE[rng.randrange(len(UNIQUE_PEOPLE))],
        ch=UNIQUE_CHANNELS[rng.randrange(len(UNIQUE_CHANNELS))],
        word=UNIQUE_WORDS[rng.randrange(len(UNIQUE_WORDS))],
        sha="%08x" % rng.getrandbits(32),
        hh="%02d" % rng.randrange(9, 19), mm="%02d" % rng.randrange(60),
        ss="%02d" % rng.randrange(60),
        fname=["schema.sql", "gen_synth.py", "test_correctness.py"][rng.randrange(3)])


# --------------------------------------------------------------------------- #
# 文本版本：按 sha256 复用
# --------------------------------------------------------------------------- #
def intern_text_version(conn, state, device_id, text, ts):
    """返回 (text_version_id, reused)。相同文本在同一设备内只有一行（schema 里 UNIQUE 保证）。"""
    raw = text.encode("utf-8")
    digest = hashlib.sha256(raw).hexdigest()
    row = conn.execute(
        "SELECT id FROM text_versions WHERE device_id = ? AND sha256 = ?", (device_id, digest)
    ).fetchone()
    if row is not None:
        state["tv_reused"] += 1
        return row["id"], True
    state["tv_seq"][device_id] += 1
    tv_id = state["tv_seq"][device_id]
    conn.execute(
        "INSERT INTO text_versions(device_id, id, sha256, text, byte_len, created_at) "
        "VALUES (?,?,?,?,?,?)",
        (device_id, tv_id, digest, text, len(raw), ts),
    )
    state["tv_new"] += 1
    state["bytes_text"] += len(raw)
    return tv_id, False


# --------------------------------------------------------------------------- #
# 生成
# --------------------------------------------------------------------------- #
def generate(out_path, days, per_day, seed, n_devices, verbose=True):
    rng = random.Random(seed)
    conn = create_db(out_path)
    thumbs = thumb_dir(out_path)
    os.makedirs(thumbs, exist_ok=True)

    devices = [DEVICE_NAMES[i] if i < len(DEVICE_NAMES) else "dev-%02d" % i for i in range(n_devices)]

    conn.execute("BEGIN")
    # --- 规范化对象 ---
    app_id_by_bundle = {}
    for i, (bundle, name, _kind, _mode, _cm) in enumerate(APPS, start=1):
        conn.execute("INSERT INTO apps(id, bundle_id, name) VALUES (?,?,?)", (i, bundle, name))
        app_id_by_bundle[bundle] = i
    win_ids = {}
    wid = 0
    for bundle, titles in WINDOW_TITLES.items():
        for t in titles:
            wid += 1
            conn.execute("INSERT INTO windows(id, app_id, title) VALUES (?,?,?)",
                         (wid, app_id_by_bundle[bundle], t))
            win_ids.setdefault(bundle, []).append(wid)
    for i, (raw, canon, host, kind) in enumerate(URLS, start=1):
        conn.execute("INSERT INTO urls(id, raw_locator, canonical_url, host, kind) VALUES (?,?,?,?,?)",
                     (i, raw, canon, host, kind))
    for i, p in enumerate(FILES, start=1):
        conn.execute("INSERT INTO files(id, path) VALUES (?,?)", (i, p))
    url_ids = list(range(1, len(URLS) + 1))
    file_ids = list(range(1, len(FILES) + 1))

    # --- 策略 ---
    now_ms = int(ANCHOR_UTC.timestamp() * 1000)
    for bundle, _name, _kind, mode, _cm in APPS:
        conn.execute("INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)",
                     (bundle, mode, "default", now_ms))
    for bundle, _name in DENYLIST_APPS:
        conn.execute("INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)",
                     (bundle, "none", "builtin_denylist", now_ms))
    conn.execute("INSERT INTO grants(client_id, mode, apps, time_window, fields, created_at) VALUES (?,?,?,?,?,?)",
                 ("claude-code-local", "strict_local", json.dumps(["*"]), 30, "evidence", now_ms))
    conn.execute("INSERT INTO grants(client_id, mode, apps, time_window, fields, created_at) VALUES (?,?,?,?,?,?)",
                 ("remote-assistant", "remote_allowed",
                  json.dumps(["com.apple.Safari", "com.microsoft.VSCode"]), 7, "summary", now_ms))
    for key, val in (("schema_version", "0.1"),
                     ("devices", json.dumps(devices)),
                     ("quota_bytes_default", str(5 * 1024 ** 3)),
                     ("seed", str(seed))):
        conn.execute("INSERT INTO meta(key, value) VALUES (?,?)", (key, val))

    state = {
        "tv_seq": {d: 0 for d in devices},
        "obs_seq": {d: 0 for d in devices},
        "occ_seq": {d: 0 for d in devices},
        "tv_new": 0, "tv_reused": 0, "bytes_text": 0, "thumbs": 0,
        "app_switches": 0, "budget_obs": [],
    }

    first_day = ANCHOR_UTC - timedelta(days=days - 1)
    step_s = DAY_SPAN_S / max(per_day, 1)
    budget_slots = (3, per_day - 4) if per_day >= 8 else (0, max(per_day - 1, 0))

    for device in devices:
        cur_bundle = APPS[0][0]
        for d in range(days):
            day0 = first_day + timedelta(days=d)
            day_ms0 = int((day0.timestamp() + DAY_START_S) * 1000)
            day_obs = []
            for k in range(per_day):
                ts = day_ms0 + int(k * step_s * 1000) + rng.randrange(0, 900)
                # 应用切换：约 1/4 的观察换应用
                if k == 0 or rng.random() < 0.25:
                    new_bundle = APPS[rng.randrange(len(APPS))][0]
                    if new_bundle != cur_bundle:
                        state["app_switches"] += 1
                    cur_bundle = new_bundle
                    trig = "app_switch"
                else:
                    trig = TRIGGERS[rng.randrange(1, len(TRIGGERS))]
                bundle = cur_bundle
                meta = next(a for a in APPS if a[0] == bundle)
                kind = meta[2]
                app_id = app_id_by_bundle[bundle]
                window_id = win_ids[bundle][rng.randrange(len(win_ids[bundle]))]
                url_id = url_ids[rng.randrange(len(url_ids))] if kind == "web" else None
                file_id = file_ids[rng.randrange(len(file_ids))] if kind == "file" else None
                capture_method = meta[4] if rng.random() < 0.8 else \
                    ["ax", "ocr", "adapter", "mixed"][rng.randrange(4)]
                completeness = COMPLETENESS[rng.randrange(len(COMPLETENESS))]
                source_state = SOURCE_STATES[rng.randrange(len(SOURCE_STATES))]
                if source_state != "ok":
                    completeness = "unavailable" if source_state == "permission_lost" else "partial"
                # 预算文档的两个槽位强制读到完整正文：这两次观察是「正文修改」场景的固定证据
                if k in budget_slots:
                    completeness, source_state = "complete", "ok"
                frame_hash = "%016x" % rng.getrandbits(64)
                thumb_ref = None
                if rng.random() < 0.25:
                    thumb_ref = "thumb_%s_%06d.bin" % (device, state["obs_seq"][device] + 1)
                    with open(os.path.join(thumbs, thumb_ref), "wb") as fh:
                        fh.write(b"THUMB")           # 占位缩略图，验证删除时一并清理
                    state["thumbs"] += 1
                visible_range = json.dumps({"viewport": [0, rng.randrange(600, 1400)],
                                            "scrolled": rng.random() < 0.3})

                state["obs_seq"][device] += 1
                obs_id = state["obs_seq"][device]
                conn.execute(
                    'INSERT INTO observations(device_id, id, ts, display_id, app_id, window_id, '
                    'url_id, file_id, "trigger", capture_method, completeness, visible_range, '
                    'source_state, frame_hash, thumb_ref, deleted_at) '
                    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
                    (device, obs_id, ts, 1 if rng.random() < 0.75 else 2, app_id, window_id,
                     url_id, file_id, trig, capture_method, completeness, visible_range,
                     source_state, frame_hash, thumb_ref))
                day_obs.append(obs_id)

                # --- 片段 / 出现记录 ---
                if completeness in ("unavailable", "excluded"):
                    frags = []                       # 没读到正文，只有事件骨架
                elif k == budget_slots[0]:
                    frags = [BUDGET_V1]
                    state["budget_obs"].append((device, obs_id, "v1", ts))
                elif k == budget_slots[1]:
                    frags = [BUDGET_V2]
                    state["budget_obs"].append((device, obs_id, "v2", ts))
                else:
                    n = [1, 2, 2, 3, 3][rng.randrange(5)]
                    frags = []
                    for j in range(n):
                        if rng.random() < 0.40:
                            frags.append(CORPUS[rng.randrange(len(CORPUS))])   # 共享片段，触发复用
                        else:
                            frags.append(make_unique_fragment(rng, day0, bundle, k, j))
                for ordinal, frag in enumerate(frags):
                    tv_id, _reused = intern_text_version(conn, state, device, frag, ts)
                    state["occ_seq"][device] += 1
                    conn.execute(
                        "INSERT INTO occurrences(device_id, id, observation_id, text_version_id, region, ord) "
                        "VALUES (?,?,?,?,?,?)",
                        (device, state["occ_seq"][device], obs_id, tv_id,
                         json.dumps({"x": 0, "y": 120 + ordinal * 40, "w": 1200, "h": 36}), ordinal))

            # --- 派生：当天台账 ---
            build_day_ledger(conn, device, day0.strftime("%Y-%m-%d"), day_obs, now_ms)

        # --- 派生：会话 ---
        build_sessions(conn, device, now_ms)

    # --- 任务队列样例 ---
    for i, (typ, st) in enumerate([("index_fts", "done"), ("build_session", "done"),
                                   ("build_ledger", "done"), ("incremental_vacuum", "pending")], start=1):
        conn.execute("INSERT INTO jobs(id, type, state, input_ref, output_ref, created_at, updated_at) "
                     "VALUES (?,?,?,?,?,?,?)", (i, typ, st, None, None, now_ms, now_ms))
    conn.execute("COMMIT")
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    stats = summarize(conn, out_path)
    stats.update({"tv_new": state["tv_new"], "tv_reused": state["tv_reused"],
                  "app_switches": state["app_switches"], "thumbs": state["thumbs"],
                  "devices": devices, "days": days, "per_day": per_day, "seed": seed})
    if verbose:
        print_stats(stats)
    return conn, stats


def build_sessions(conn, device, now_ms):
    """确定性会话：同一应用、间隔 <= 300 s 归为一段；三类时间分列（3.7）。"""
    rows = conn.execute(
        'SELECT id, ts, app_id, display_id, source_state FROM observations '
        "WHERE device_id = ? AND deleted_at IS NULL ORDER BY ts", (device,)).fetchall()
    gap_ms = 300 * 1000
    seq = conn.execute("SELECT COALESCE(MAX(id),0) AS m FROM sessions WHERE device_id=?",
                       (device,)).fetchone()["m"]
    cur = None
    batch = []

    def flush(s):
        if s is None:
            return
        dwell = (s["end"] - s["start"]) / 1000.0
        unknown = s["unknown_n"] * 5.0
        active = max(dwell - unknown, 0.0) * 0.6
        batch.append((device, s["id"], s["start"], s["end"], s["display_id"], s["app_id"],
                      round(dwell, 3), round(active, 3), round(unknown, 3), s["interruptions"],
                      json.dumps(s["evidence"]), 0, now_ms))

    for r in rows:
        if cur is not None and r["app_id"] == cur["app_id"] and r["ts"] - cur["end"] <= gap_ms:
            cur["end"] = r["ts"]
            cur["evidence"].append(r["id"])
            if r["source_state"] != "ok":
                cur["unknown_n"] += 1
            continue
        if cur is not None:
            cur["interruptions"] = max(len(cur["evidence"]) // 8, 0)
        flush(cur)
        seq += 1
        cur = {"id": seq, "start": r["ts"], "end": r["ts"], "app_id": r["app_id"],
               "display_id": r["display_id"], "evidence": [r["id"]],
               "unknown_n": 1 if r["source_state"] != "ok" else 0, "interruptions": 0}
    if cur is not None:
        cur["interruptions"] = max(len(cur["evidence"]) // 8, 0)
        flush(cur)
    conn.executemany(
        'INSERT INTO sessions(device_id, id, start, "end", display_id, primary_app_id, dwell_s, '
        "active_s, unknown_s, interruptions, evidence, stale, computed_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)


def build_day_ledger(conn, device, period, obs_ids, now_ms):
    if not obs_ids:
        return
    q = ",".join("?" * len(obs_ids))
    by_app = conn.execute(
        "SELECT a.bundle_id AS b, COUNT(*) AS n FROM observations o JOIN apps a ON a.id = o.app_id "
        "WHERE o.device_id = ? AND o.id IN (%s) AND o.deleted_at IS NULL GROUP BY 1 ORDER BY 2 DESC" % q,
        [device] + obs_ids).fetchall()
    ledger = {"observations": len(obs_ids), "by_app": {r["b"]: r["n"] for r in by_app}}
    seq = conn.execute("SELECT COALESCE(MAX(id),0) AS m FROM ledgers WHERE device_id=?",
                       (device,)).fetchone()["m"] + 1
    conn.execute("INSERT INTO ledgers(device_id, id, level, period, ledger, narrative, model, "
                 "evidence, stale, computed_at) VALUES (?,?,?,?,?,?,?,?,0,?)",
                 (device, seq, "day", period, json.dumps(ledger, ensure_ascii=False),
                  None, None, json.dumps(obs_ids), now_ms))


# --------------------------------------------------------------------------- #
# 统计与摘要
# --------------------------------------------------------------------------- #
def summarize(conn, db_path):
    def one(sql, args=()):
        return conn.execute(sql, args).fetchone()[0]
    db_bytes = os.path.getsize(db_path)
    for suffix in ("-wal", "-shm"):
        if os.path.exists(db_path + suffix):
            db_bytes += os.path.getsize(db_path + suffix)
    return {
        "observations": one("SELECT COUNT(*) FROM observations"),
        "occurrences": one("SELECT COUNT(*) FROM occurrences"),
        "text_versions": one("SELECT COUNT(*) FROM text_versions"),
        "text_bytes": one("SELECT COALESCE(SUM(byte_len),0) FROM text_versions"),
        "fts_rows": one("SELECT COUNT(*) FROM text_fts_docsize"),
        "sessions": one("SELECT COUNT(*) FROM sessions"),
        "ledgers": one("SELECT COUNT(*) FROM ledgers"),
        "db_bytes": db_bytes,
    }


def content_digest(conn):
    """内容摘要：用于验证同 seed 生成结果一致（不含文件大小等易变量）。"""
    h = hashlib.sha256()
    for sql in (
        'SELECT device_id, id, ts, app_id, window_id, url_id, file_id, "trigger", capture_method, '
        "completeness, source_state, frame_hash, thumb_ref FROM observations ORDER BY device_id, id",
        "SELECT device_id, id, sha256, byte_len FROM text_versions ORDER BY device_id, id",
        "SELECT device_id, id, observation_id, text_version_id, ord FROM occurrences ORDER BY device_id, id",
    ):
        for row in conn.execute(sql):
            h.update(repr(tuple(row)).encode("utf-8"))
    return h.hexdigest()


def print_stats(s):
    print("合成库生成完成")
    print("  设备            : %s" % ", ".join(s["devices"]))
    print("  天数 / 每天观察 : %d 天 / %d 条" % (s["days"], s["per_day"]))
    print("  observations    : %d 条（应用切换 %d 次）" % (s["observations"], s["app_switches"]))
    print("  occurrences     : %d 条" % s["occurrences"])
    print("  text_versions   : %d 个（新建 %d，复用命中 %d 次，复用率 %.1f%%）"
          % (s["text_versions"], s["tv_new"], s["tv_reused"],
             100.0 * s["tv_reused"] / max(s["tv_new"] + s["tv_reused"], 1)))
    print("  原文字节        : %d 字节（%.2f KiB）" % (s["text_bytes"], s["text_bytes"] / 1024.0))
    print("  FTS 行          : %d 行" % s["fts_rows"])
    print("  sessions/ledgers: %d / %d" % (s["sessions"], s["ledgers"]))
    print("  缩略图占位文件  : %d 个" % s["thumbs"])
    print("  库文件（含 WAL）: %d 字节（%.2f MiB）" % (s["db_bytes"], s["db_bytes"] / 1024.0 / 1024.0))


# =========================================================================== #
# 容量模式（E7 / T5）：按 2.4「存储」与评审 F8 的口径生成 1 / 3 / 12 个月规模库
#
# 与上面 E3 模式的区别（E3 模式一个字节都没改，摘要可校验）：
#   * 规模按「每天 per_day 次捕获」，默认 8640 次 = 24 h / 10 s；
#   * 每次捕获产出一段完整可见正文（schema 里 text 的口径是「存完整原文，不分块」），
#     平均 avg_chars 字符中英混排，所以 occurrences 与 observations 一比一；
#   * 新文本占 new_ratio（默认 30%），其余按 sha256 复用既有 text_version；
#   * 不写缩略图占位文件（12 个月会是 78 万个小文件），只填 thumb_ref 字段占字节，
#     缩略图文件体积在报告里单列解析式估算；
#   * sessions 边生成边攒，不做 3.1 M 行的回查；
#   * FTS 方案可换：bigram（T3 推荐的 B+E+V）或 trigram（schema.sql 里的占位）。
# =========================================================================== #

# 语料：中英混排，行级拼装。中文行偏多，让字节/字符比落在真实中英混排区间。
CAP_ZH = [
    "会议纪要：项目 A 的采集范围先覆盖飞书与微信，其余应用按停留时长排序逐步加入。",
    "张三说预算复核要在本周五之前完成，李四负责把上季度的实际支出对齐到新的科目表。",
    "结论是先不做语义图谱，等检索侧把跨实体问题的失败原因分清楚再决定要不要建。",
    "采集覆盖率这周从百分之六十一提到百分之七十八，主要是补上了终端与编辑器两类窗口。",
    "这段正文是从飞书文档里读出来的，无障碍树给到的层级不完整，缺失区域走了局部识别。",
    "台账口径要把前台停留、有输入的活跃、未知状态三类时间分开列，不能混成一个总时长。",
    "王五在群里贴了一份排期表，说下周三之前要把存储服务的删除级联跑通并出数字。",
    "注意窗口标题里带了客户名字，脱敏规则要在写库之前生效，不能靠事后清洗。",
    "配额到百分之八十的时候提示用户，满了以后最旧的先删，删之前要能先做加密导出。",
    "跨设备同步用段文件加校验和，缺段就停止导入并提示，不要自动跳过去装作没事。",
    "本次评审提出的第八条意见是容量与性能估算没有统一口径，验收要按字节而不是字符。",
    "屏幕录制权限每个月要重新授权一次，静默停掉是最危险的失败模式，必须有可见状态。",
    "微信这边无障碍基本读不到东西，只能靠识别，发送者按坐标归属，出错就如实标部分完整。",
    "把观察记录和文本版本拆开之后，同一段文字在不同时间出现就各留一条出现记录。",
    "文本版本不可变，改内容只能插新版本，这样才能回答当时屏幕上看到的到底是哪一版。",
    "夜间接电空闲的时候跑增量清理，包括增量整理、检查点截断和索引优化，避免白天卡顿。",
    "检索先按查询形态路由，像网址和路径这种走精确字段列，剩下的才交给全文索引。",
    "单个汉字的查询三种索引都召回不了，必须限定时间或应用范围之后走扫描回退。",
    "评估集的题目要标清楚来源和出题时间，自己出题自己答的偏差要在报告里写明白。",
    "存储服务是唯一持钥的进程，接口层只做授权校验和审计，不碰密钥也不直接写库。",
    "这条日志说数据库磁盘映像损坏，通常是主库文件和预写日志被分别同步造成的。",
    "本周把正确性与删除的七个场景全部跑通，每个场景都要有可复现的数字而不是描述。",
    "会话常量目前是停留上限九十秒、间隔三百秒、打断二十秒，属于待校准参数不是结论。",
    "双屏的时长按焦点窗口归属，另外再算一个区间并集当作总在线，两个数都要报出来。",
    "用户主动删除是合规工具，点了立即执行并级联，观察记录留墓碑供审计和同步重放。",
    "把每日新文本比例和压缩比的口径统一改成字节，压缩本身推迟到容量实测证明必要再做。",
    "识别只对三类区域触发：无障碍读不到、无障碍的值超过阈值没变、覆盖检查没通过。",
    "从这周开始所有构建产物都放到缓存目录下，项目目录里不再产生大量小文件。",
    "如果本地嵌入模型没装，向量检索显示为未启用，精确字段与全文检索不受影响。",
    "远程模式默认关闭，开启之前要展示外发范围，外发前脱敏，并记录条数与字节数。",
    "这次把索引体积和正文体积的比值单独列出来，因为它直接决定同样配额能留多少天。",
    "报告里不要再引用那个百分之九十八点四的数字当作通用记忆质量的证明，口径不一样。",
    "应用采集清单按应用单独勾选三档，分别是完全不采、只记事件、事件加正文。",
    "锁屏之后进入暂停子状态，库保持打开，接电的时候夜间任务照常跑，采集停掉。",
    "把删除后的物理清理拆成三步：安全删除覆写、增量整理回收页、检查点截断日志。",
    "本轮语料是合成的，真实题到位之前所有召回数字都只能当作方法验证不能当结论。",
    "本轮 FTS5 索引体积是正文的零点七九倍，trigram 方案会到一点八八倍，差三倍多。",
    "帧率不是重点，帧哈希只用来决定要不要做内容检查，不用来丢弃任何一条观察。",
]

# 稀有标记：按很低的概率植入，让 T5 的查询集里有真正高选择性的查询串，
# 否则合成语料里任何词都出现在几乎每一篇文档中，延迟数字会被「全库命中」带偏。
CAP_RARE = [
    "备注：蟠桃调度器在本次回归里没有复现那个死锁，先记一笔。",
    "error E1042: capture failed after 3 retries, see ~/Library/Logs/brosis/E1042.log",
    "// TODO: frobnicate_widget(ctx) 只在旧版适配器里出现，新版已经删掉了",
    "参考链接 https://rare.example.org/note/7 —— zygomorphic layout 的那篇笔记。",
]
CAP_RARE_P = 1.0 / 300.0

CAP_EN = [
    "The trigram tokenizer indexes every three-character sequence, so the index grows fast.",
    "note: AXManualAccessibility must be set on the Electron app element before reading the tree.",
    "WAL checkpoint starvation happens when a long-running reader keeps the log from resetting.",
    "Recall@10 measures whether the first ten hits are filled with relevant documents, nothing more.",
    "Contentless FTS5 tables need contentless_delete=1 before a row can be removed by rowid.",
    "Screen capture on macOS requires the ScreenCaptureKit entitlement and a monthly re-approval.",
    "Deterministic ledgers must not depend on model output; narrative text is labelled separately.",
    "The observation is the evidence unit; the text version is the content unit. Keep them apart.",
    "Incremental auto_vacuum has to be set before the first table is created, otherwise VACUUM.",
    "Cold latency here only clears the SQLite page cache, not the operating system file cache.",
    "Each capture stores the full visible text, so byte accounting is exact rather than estimated.",
    "Quota eviction removes the oldest observations first and writes one audit row per operation.",
    "Foreign key RESTRICT on the text version is what actually protects shared content from delete.",
    "Latency is reported per layer: retrieval service, embedding, and end to end, cold and hot.",
]

CAP_CODE = [
    "let stream = try SCStream(filter: filter, configuration: config, delegate: self)",
    "SELECT id, sha256, byte_len FROM text_versions WHERE device_id = ? ORDER BY created_at DESC;",
    "func parseObservation(_ raw: RawFrame) throws -> Observation { /* ... */ }",
    "PRAGMA wal_checkpoint(TRUNCATE);  -- 夜间接电时执行",
    "if err := sqlite3_prepare_v2(db, sql, -1, &stmt, nil); err != SQLITE_OK { return }",
    "error E1042: capture failed, source_state=permission_lost, retry after re-authorization",
    "INSERT INTO text_fts(rowid, body) VALUES (:text_version_id, :bigrammed);",
    "kAXDocumentChangedNotification -> scheduleContentCheck(window: id, delay: .milliseconds(250))",
    "exit code 137 (SIGKILL) — 子进程在未提交事务中间被杀，重启后整批回滚",
    "assert(occurrence.textVersionID != nil, \"occurrence must point at a text version\")",
]

CAP_PATH = [
    "/Users/demo/dev/brosis/tools/proto/schema.sql",
    "~/Library/Caches/brosis-build/proto/capacity_12m.db",
    "/Users/demo/Notes/项目 A 季度规划.md",
    "tools/bench/fts_compare.py",
    "/Users/demo/Library/Application Support/brosis/brosis.sqlite",
    "Sources/BrosisCapture/AXReader.swift",
    "/usr/local/lib/libsqlcipher.dylib",
    "~/Downloads/2026Q3 预算表.numbers",
]

CAP_URL = [
    "https://sqlite.org/fts5.html#the_trigram_tokenizer",
    "https://developer.apple.com/documentation/screencapturekit?language=swift",
    "https://example-corp.feishu.cn/docx/BdX1p2?from=space#heading-budget",
    "https://kanban.internal.example.com/board/7?filter=mine",
    "https://github.com/asg017/sqlite-vec",
    "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B",
]

# 行池与权重：中文行偏多，落在中英混排的真实区间（实际字节/字符比由报告实测给出）
CAP_POOLS = ((CAP_ZH, 62), (CAP_EN, 16), (CAP_CODE, 12), (CAP_PATH, 5), (CAP_URL, 5))
CAP_KINDS = ("chat", "doc", "code", "web", "term")


def _text_capable_rate():
    """读到正文的捕获占比：completeness ∈ {complete, partial} 才有 occurrence。

    评审 F8 的算式 `8640 × 1500 字符 × 30%` 里的 30% 是对**全部捕获**说的，
    而 13.5% 的捕获压根读不到正文（权限丢失 / 排除 / 不可用）。所以「新文本概率」
    要按这个比例放大，才能让每天新文本正好是 per_day × new_ratio 段。
    """
    n_src = len(SOURCE_STATES)
    p_lost = SOURCE_STATES.count("permission_lost") / n_src
    p_ok = SOURCE_STATES.count("ok") / n_src
    n_c = len(COMPLETENESS)
    p_bad = (COMPLETENESS.count("unavailable") + COMPLETENESS.count("excluded")) / n_c
    return 1.0 - (p_lost + p_ok * p_bad)


TEXT_CAPABLE_RATE = _text_capable_rate()        # 本机常数：0.865

FTS_SCHEME_SQL = {
    # T3（tools/bench/results/fts_compare_2026-09-06.md §9.2 / §9.4）推荐的 B+E+V：
    # 汉字 bigram 预处理 + unicode61 + contentless，FTS 行由应用层显式维护。
    "bigram": """
DROP TRIGGER trg_text_fts_ai;
DROP TRIGGER trg_text_fts_ad;
DROP TABLE text_fts;
CREATE VIRTUAL TABLE text_fts USING fts5(
  body,
  tokenize           = 'unicode61 remove_diacritics 2',
  content            = '',
  contentless_delete = 1
);
""",
    # schema.sql 里的占位方案：trigram + detail=full + 外部内容表，FTS 行由触发器维护。
    "trigram": "",
}


def load_bigram_join():
    """从 tools/bench/fts_compare.py 取 T3 实测用的同一份 bigram 实现，避免两处实现漂移。"""
    import importlib.util

    path = os.path.join(os.path.dirname(HERE), "bench", "fts_compare.py")
    if not os.path.exists(path):
        raise SystemExit("找不到 %s；bigram 方案需要 T3 的实现" % path)
    old = sys.dont_write_bytecode
    sys.dont_write_bytecode = True          # 不在项目目录里生成 __pycache__
    try:
        spec = importlib.util.spec_from_file_location("brosis_fts_compare", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = old
    return mod.bigram_join


def apply_fts_scheme(conn, scheme):
    sql = FTS_SCHEME_SQL.get(scheme)
    if sql is None:
        raise SystemExit("未知 FTS 方案：%s（可选 %s）" % (scheme, "/".join(FTS_SCHEME_SQL)))
    if sql.strip():
        conn.executescript(sql)


def make_capacity_doc(rng, serial, avg_chars):
    """拼一段约 avg_chars 字符的中英混排「一屏正文」。serial 保证全库唯一。"""
    kind = CAP_KINDS[rng.randrange(len(CAP_KINDS))]
    target = int(avg_chars * (0.7 + 0.6 * rng.random()))     # ±30% 抖动，均值 ≈ avg_chars
    head = "[%s #%d %02d:%02d] %s" % (kind, serial, rng.randrange(24), rng.randrange(60),
                                      CAP_ZH[rng.randrange(len(CAP_ZH))][:18])
    lines = [head]
    total = len(head)
    while total < target:
        r = rng.randrange(100)
        acc = 0
        pool = CAP_ZH
        for p, w in CAP_POOLS:
            acc += w
            if r < acc:
                pool = p
                break
        line = pool[rng.randrange(len(pool))]
        if rng.random() < 0.25:                              # 加一点行内变化，避免整行完全同构
            line = "%s（%d）" % (line, rng.randrange(1000))
        lines.append(line)
        total += len(line) + 1
    if rng.random() < CAP_RARE_P:
        lines.append(CAP_RARE[rng.randrange(len(CAP_RARE))])
    return "\n".join(lines)


def generate_capacity(out_path, days, seed=20260906, per_day=8640, avg_chars=1500,
                      new_ratio=0.30, fts_scheme="bigram", device="dev-mbp16",
                      thumb_ratio=0.25, switch_p=0.03, pool_size=6000,
                      page_size=None, progress=None, verbose=True):
    """按容量口径生成一个规模库。返回 (conn, stats)。"""
    t_start = time.monotonic()
    rng = random.Random(seed)
    conn = create_db(out_path, page_size=page_size)
    conn.execute("PRAGMA synchronous = NORMAL")      # WAL 下的产品常用档，报告里注明
    apply_fts_scheme(conn, fts_scheme)
    bigram = load_bigram_join() if fts_scheme == "bigram" else None

    # --- 规范化对象与策略（与 E3 模式同一份，量很小） ---
    conn.execute("BEGIN")
    app_id_by_bundle = {}
    for i, (bundle, name, _kind, _mode, _cm) in enumerate(APPS, start=1):
        conn.execute("INSERT INTO apps(id, bundle_id, name) VALUES (?,?,?)", (i, bundle, name))
        app_id_by_bundle[bundle] = i
    win_ids, wid = {}, 0
    for bundle, titles in WINDOW_TITLES.items():
        for t in titles:
            wid += 1
            conn.execute("INSERT INTO windows(id, app_id, title) VALUES (?,?,?)",
                         (wid, app_id_by_bundle[bundle], t))
            win_ids.setdefault(bundle, []).append(wid)
    for i, (raw, canon, host, kind) in enumerate(URLS, start=1):
        conn.execute("INSERT INTO urls(id, raw_locator, canonical_url, host, kind) VALUES (?,?,?,?,?)",
                     (i, raw, canon, host, kind))
    for i, p in enumerate(FILES, start=1):
        conn.execute("INSERT INTO files(id, path) VALUES (?,?)", (i, p))
    now_ms = int(ANCHOR_UTC.timestamp() * 1000)
    for bundle, _n, _k, mode, _cm in APPS:
        conn.execute("INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)",
                     (bundle, mode, "default", now_ms))
    for key, val in (("schema_version", "0.1"), ("devices", json.dumps([device])),
                     ("quota_bytes_default", str(5 * 1024 ** 3)), ("seed", str(seed)),
                     ("capacity_mode", json.dumps({"per_day": per_day, "avg_chars": avg_chars,
                                                   "new_ratio": new_ratio, "days": days,
                                                   "fts_scheme": fts_scheme}))):
        conn.execute("INSERT INTO meta(key, value) VALUES (?,?)", (key, val))
    conn.execute("COMMIT")
    url_ids = list(range(1, len(URLS) + 1))
    file_ids = list(range(1, len(FILES) + 1))

    ins_obs = ('INSERT INTO observations(device_id, id, ts, display_id, app_id, window_id, url_id, '
               'file_id, "trigger", capture_method, completeness, visible_range, source_state, '
               'frame_hash, thumb_ref, deleted_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)')
    ins_tv = ("INSERT INTO text_versions(vrow, device_id, id, sha256, text, byte_len, created_at) "
              "VALUES (?,?,?,?,?,?,?)")
    ins_occ = ("INSERT INTO occurrences(device_id, id, observation_id, text_version_id, region, ord) "
               "VALUES (?,?,?,?,?,?)")
    ins_fts = "INSERT INTO text_fts(rowid, body) VALUES (?,?)"
    ins_ses = ('INSERT INTO sessions(device_id, id, start, "end", display_id, primary_app_id, '
               "dwell_s, active_s, unknown_s, interruptions, evidence, stale, computed_at) "
               "VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?)")

    # new_ratio 是「占全部捕获」的口径（评审 F8），换算成「占读到正文的捕获」的概率
    new_p = min(new_ratio / TEXT_CAPABLE_RATE, 1.0)
    step_ms = int(round(86400_000.0 / per_day))      # 8640 次/天 = 每 10 s 一次
    first_day = ANCHOR_UTC - timedelta(days=days - 1)
    st = {"obs": 0, "occ": 0, "tv": 0, "vrow": 0, "ses": 0, "reused": 0,
          "text_chars": 0, "text_bytes": 0, "cjk_chars": 0, "thumbs": 0, "switches": 0,
          "fts_body_bytes": 0}
    pool = []                                        # 最近生成的 text_version id，供复用
    cur_bundle = APPS[0][0]
    sess = None
    t_gen = 0.0

    for d in range(days):
        day0 = first_day + timedelta(days=d)
        day_ms0 = int(day0.timestamp() * 1000)
        obs_rows, tv_rows, occ_rows, fts_rows, ses_rows = [], [], [], [], []
        day_obs = []
        t_day = time.monotonic()
        conn.execute("BEGIN")
        for k in range(per_day):
            ts = day_ms0 + k * step_ms
            if k == 0 or rng.random() < switch_p:
                nb = APPS[rng.randrange(len(APPS))][0]
                if nb != cur_bundle:
                    st["switches"] += 1
                cur_bundle = nb
                trig = "app_switch"
            else:
                trig = TRIGGERS[rng.randrange(1, len(TRIGGERS))]
            meta = next(a for a in APPS if a[0] == cur_bundle)
            app_id = app_id_by_bundle[cur_bundle]
            window_id = win_ids[cur_bundle][rng.randrange(len(win_ids[cur_bundle]))]
            url_id = url_ids[rng.randrange(len(url_ids))] if meta[2] == "web" else None
            file_id = file_ids[rng.randrange(len(file_ids))] if meta[2] == "file" else None
            capture_method = meta[4] if rng.random() < 0.8 else \
                ["ax", "ocr", "adapter", "mixed"][rng.randrange(4)]
            completeness = COMPLETENESS[rng.randrange(len(COMPLETENESS))]
            source_state = SOURCE_STATES[rng.randrange(len(SOURCE_STATES))]
            if source_state != "ok":
                completeness = "unavailable" if source_state == "permission_lost" else "partial"
            thumb_ref = None
            if rng.random() < thumb_ratio:           # 只占字段字节，不落盘文件
                thumb_ref = "thumb_%s_%08d.jpg" % (device, st["obs"] + 1)
                st["thumbs"] += 1
            st["obs"] += 1
            obs_id = st["obs"]
            obs_rows.append((device, obs_id, ts, 1 if rng.random() < 0.75 else 2, app_id,
                             window_id, url_id, file_id, trig, capture_method, completeness,
                             json.dumps({"viewport": [0, rng.randrange(600, 1400)],
                                         "scrolled": rng.random() < 0.3}),
                             source_state, "%016x" % rng.getrandbits(64), thumb_ref))
            day_obs.append(obs_id)

            # --- 会话：同应用连续为一段 ---
            if sess is None or sess["app_id"] != app_id:
                if sess is not None:
                    ses_rows.append(_cap_session_row(device, sess, now_ms))
                st["ses"] += 1
                sess = {"id": st["ses"], "start": ts, "end": ts, "app_id": app_id,
                        "display_id": obs_rows[-1][3], "n": 1, "unknown": 0,
                        "first_obs": obs_id, "evidence": [obs_id]}
            else:
                sess["end"] = ts
                sess["n"] += 1
                if len(sess["evidence"]) < 64:       # 证据数组只留前 64 条，其余靠时间范围回查
                    sess["evidence"].append(obs_id)
            if source_state != "ok":
                sess["unknown"] += 1

            # --- 正文：30% 新文本，其余复用既有版本 ---
            if completeness in ("unavailable", "excluded"):
                continue                              # 没读到正文，只有事件骨架
            if pool and rng.random() >= new_p:
                idx = int(len(pool) * (rng.random() ** 2))     # 偏向最近出现过的内容
                tv_id = pool[len(pool) - 1 - idx]
                st["reused"] += 1
            else:
                t0 = time.monotonic()
                text = make_capacity_doc(rng, st["tv"] + 1, avg_chars)
                raw = text.encode("utf-8")
                st["tv"] += 1
                st["vrow"] += 1
                tv_id, vrow = st["tv"], st["vrow"]
                tv_rows.append((vrow, device, tv_id,
                                hashlib.sha256(raw).hexdigest(), text, len(raw), ts))
                if bigram is not None:
                    body = bigram(text)
                    st["fts_body_bytes"] += len(body.encode("utf-8"))
                    fts_rows.append((vrow, body))
                st["text_chars"] += len(text)
                st["text_bytes"] += len(raw)
                st["cjk_chars"] += sum(1 for c in text if "㐀" <= c <= "鿿")
                pool.append(tv_id)
                if len(pool) > pool_size:
                    del pool[:len(pool) - pool_size]
                t_gen += time.monotonic() - t0
            st["occ"] += 1
            occ_rows.append((device, st["occ"], obs_id, tv_id,
                             json.dumps({"x": 0, "y": 120, "w": 1440, "h": 900}), 0))

        conn.executemany(ins_obs, obs_rows)
        if tv_rows:
            conn.executemany(ins_tv, tv_rows)
        if fts_rows:
            conn.executemany(ins_fts, fts_rows)
        conn.executemany(ins_occ, occ_rows)
        if ses_rows:
            conn.executemany(ins_ses, ses_rows)
        build_day_ledger(conn, device, day0.strftime("%Y-%m-%d"), day_obs, now_ms)
        conn.execute("COMMIT")
        if progress is not None:
            progress(d + 1, days, time.monotonic() - t_day, time.monotonic() - t_start)

    if sess is not None:
        conn.execute("BEGIN")
        conn.execute(ins_ses, _cap_session_row(device, sess, now_ms))
        conn.execute("COMMIT")
    build_s = time.monotonic() - t_start
    t0 = time.monotonic()
    conn.execute("ANALYZE")
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finalize_s = time.monotonic() - t0

    stats = {
        "days": days, "per_day": per_day, "device": device, "seed": seed,
        "avg_chars_target": avg_chars, "new_ratio": new_ratio, "fts_scheme": fts_scheme,
        "observations": st["obs"], "occurrences": st["occ"], "text_versions": st["tv"],
        "sessions": st["ses"], "reused": st["reused"], "thumb_refs": st["thumbs"],
        "app_switches": st["switches"], "text_chars": st["text_chars"],
        "text_bytes": st["text_bytes"], "cjk_chars": st["cjk_chars"],
        "fts_body_bytes": st["fts_body_bytes"],
        "build_s": build_s, "finalize_s": finalize_s, "textgen_s": t_gen,
        "page_size": conn.execute("PRAGMA page_size").fetchone()[0],
        "path": os.path.abspath(out_path),
    }
    if verbose:
        print("容量库生成完成：%s" % out_path)
        print("  规模            : %d 天 × %d 次/天 = %d 条观察" % (days, per_day, st["obs"]))
        print("  text_versions   : %d（新文本占 %.1f%%）"
              % (st["tv"], 100.0 * st["tv"] / max(st["occ"], 1)))
        print("  正文            : %d 字符 / %d 字节（%.2f 字节/字符，汉字占 %.1f%%）"
              % (st["text_chars"], st["text_bytes"],
                 st["text_bytes"] / max(st["text_chars"], 1),
                 100.0 * st["cjk_chars"] / max(st["text_chars"], 1)))
        print("  建库            : %.1f s（收尾 %.1f s）" % (build_s, finalize_s))
    return conn, stats


def _cap_session_row(device, s, now_ms):
    dwell = (s["end"] - s["start"]) / 1000.0
    unknown = s["unknown"] * 10.0
    active = max(dwell - unknown, 0.0) * 0.6
    return (device, s["id"], s["start"], s["end"], s["display_id"], s["app_id"],
            round(dwell, 3), round(active, 3), round(unknown, 3), max(s["n"] // 8, 0),
            json.dumps(s["evidence"]), now_ms)


def main(argv=None):
    ap = argparse.ArgumentParser(description="brosis E3 / E7 合成观察流生成器")
    default_out = os.path.expanduser("~/Library/Caches/brosis-build/proto/synth.db")
    ap.add_argument("--days", type=int, default=7, help="生成多少天（默认 7）")
    ap.add_argument("--per-day", type=int, default=120,
                    help="每台设备每天多少条观察（E3 默认 120；容量模式默认 8640）")
    ap.add_argument("--seed", type=int, default=20260906, help="随机种子（默认 20260906）")
    ap.add_argument("--out", default=default_out, help="输出数据库路径")
    ap.add_argument("--devices", type=int, default=2, help="设备数量（默认 2，容量模式恒为 1）")
    ap.add_argument("--digest", action="store_true", help="额外打印内容摘要（确定性校验）")
    ap.add_argument("--capacity", action="store_true",
                    help="容量模式（E7 / T5）：8640 次/天、30%% 新文本、平均 1500 字符")
    ap.add_argument("--avg-chars", type=int, default=1500, help="容量模式：每次捕获平均字符数")
    ap.add_argument("--new-ratio", type=float, default=0.30, help="容量模式：新文本比例")
    ap.add_argument("--fts", default="bigram", choices=sorted(FTS_SCHEME_SQL),
                    help="容量模式：FTS 方案，bigram = T3 推荐，trigram = schema.sql 占位")
    ap.add_argument("--page-size", type=int, default=None,
                    help="容量模式：库页大小（默认跟 SQLite 默认值 4096）")
    args = ap.parse_args(argv)
    out = os.path.expanduser(args.out)
    if args.capacity:
        per_day = args.per_day if args.per_day != 120 else 8640
        conn, _stats = generate_capacity(out, args.days, seed=args.seed, per_day=per_day,
                                         avg_chars=args.avg_chars, new_ratio=args.new_ratio,
                                         fts_scheme=args.fts, page_size=args.page_size)
    else:
        conn, _stats = generate(out, args.days, args.per_day, args.seed, args.devices)
    if args.digest:
        print("  内容摘要        : %s" % content_digest(conn))
    print("  路径            : %s" % out)
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
