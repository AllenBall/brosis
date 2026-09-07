#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M0 / E7（T5）：容量与延迟测量。

对应《实施计划》附录 A 的 **E7**、**2.4 验收口径**（存储 / 延迟两行），落实
《调研方案评审》**F8**（容量与性能估算必须有统一口径：按 UTF-8 字节分项，
延迟分层并在 1 / 3 / 12 个月规模上分别测冷热 p50 / p95）。

只用 Python 标准库。数据库一律写到 ~/Library/Caches/brosis-build/proto/。

口径（全部写进报告，不在这里重复解释）：
  * 规模        = 每天 8640 次捕获（24 h / 10 s），30% 新文本，平均 1500 字符中英混排；
                  一个月 = 30 天，三个月 = 90 天，十二个月 = 360 天。
  * 字节        = 全部按 UTF-8 字节；库内分项用 dbstat 逐 b-tree 统计，不用估算系数。
  * FTS 方案    = T3（tools/bench/results/fts_compare_2026-09-06.md §9.2）推荐的 B+E+V：
                  汉字 bigram 预处理 + unicode61 + contentless + 候选 LIKE 复核。
  * 冷          = 新进程 + 新连接（每个查询单独 connect），热 = 同一连接重复执行。

用法见 README.md。
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True      # 项目目录在 iCloud Drive 里，不要生成 __pycache__
sys.path.insert(0, HERE)

import gen_synth  # noqa: E402

DEFAULT_BUILD = os.path.expanduser("~/Library/Caches/brosis-build/proto")
DAYS_PER_MONTH = 30


# --------------------------------------------------------------------------- #
# T3 的查询工具（同一份实现，避免两处漂移）
# --------------------------------------------------------------------------- #
def load_fts_tools():
    import importlib.util

    path = os.path.join(os.path.dirname(HERE), "bench", "fts_compare.py")
    if not os.path.exists(path):
        raise SystemExit("找不到 %s；本脚本复用 T3 的 bigram / 路由实现" % path)
    old = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("brosis_fts_compare", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = old
    return mod


FTS = load_fts_tools()


# --------------------------------------------------------------------------- #
# 采样器：WAL 峰值与临时空间峰值
# --------------------------------------------------------------------------- #
class PeakSampler(threading.Thread):
    """后台采样 -wal / -shm 文件与 SQLITE_TMPDIR 目录的峰值字节。"""

    def __init__(self, db_path, tmpdir, interval=0.05):
        super().__init__(daemon=True)
        self.db_path = db_path
        self.tmpdir = tmpdir
        self.interval = interval
        self.stop_flag = threading.Event()
        self.wal_peak = 0
        self.shm_peak = 0
        self.tmp_peak = 0
        self.fs_drop_peak = 0
        self.samples = 0
        try:
            st = os.statvfs(tmpdir)
            self._free0 = st.f_bavail * st.f_frsize
            self._frsize = st.f_frsize
        except OSError:
            self._free0 = None

    @staticmethod
    def _size(p):
        try:
            return os.path.getsize(p)
        except OSError:
            return 0

    def _dir_size(self, d):
        total = 0
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            return 0
        return total

    def run(self):
        while not self.stop_flag.is_set():
            self.wal_peak = max(self.wal_peak, self._size(self.db_path + "-wal"))
            self.shm_peak = max(self.shm_peak, self._size(self.db_path + "-shm"))
            self.tmp_peak = max(self.tmp_peak, self._dir_size(self.tmpdir))
            if self._free0 is not None:
                try:
                    st = os.statvfs(self.tmpdir)
                    self.fs_drop_peak = max(self.fs_drop_peak,
                                            self._free0 - st.f_bavail * st.f_frsize)
                except OSError:
                    pass
            self.samples += 1
            self.stop_flag.wait(self.interval)

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=2)


# --------------------------------------------------------------------------- #
# 分项字节：dbstat
# --------------------------------------------------------------------------- #
FTS_SHADOW_RE = re.compile(r"^text_fts(_data|_idx|_docsize|_config|_content)?$")

TABLE_GROUPS = [
    ("text_versions", "text_versions（原文）"),
    ("observations", "observations（观察）"),
    ("occurrences", "occurrences（出现记录）"),
    ("sessions", "sessions（会话）"),
    ("ledgers", "ledgers（日台账）"),
    ("apps", "规范化对象（apps/windows/urls/files）"),
    ("windows", "规范化对象（apps/windows/urls/files）"),
    ("urls", "规范化对象（apps/windows/urls/files）"),
    ("files", "规范化对象（apps/windows/urls/files）"),
    ("meta", "策略与运行时（meta/jobs/grants/app_policies/deletions）"),
    ("jobs", "策略与运行时（meta/jobs/grants/app_policies/deletions）"),
    ("grants", "策略与运行时（meta/jobs/grants/app_policies/deletions）"),
    ("app_policies", "策略与运行时（meta/jobs/grants/app_policies/deletions）"),
    ("deletions", "策略与运行时（meta/jobs/grants/app_policies/deletions）"),
]
GROUP_OF = dict(TABLE_GROUPS)


def owner_table(name):
    """把索引 / 影子表归到它所属的主表。"""
    if name.startswith("sqlite_autoindex_"):
        base = name[len("sqlite_autoindex_"):]
        name = base.rsplit("_", 1)[0]
    if name.startswith("text_fts"):
        return "text_fts"
    if name.startswith("idx_"):
        for t in ("observations", "occurrences", "text_versions", "sessions",
                  "ledgers", "windows", "urls", "files", "jobs"):
            short = {"observations": "obs", "occurrences": "occ", "sessions": "sessions",
                     "ledgers": "ledgers", "windows": "windows", "urls": "urls",
                     "files": "files", "jobs": "jobs", "text_versions": "tv"}[t]
            if name.startswith("idx_" + short + "_") or name == "idx_" + short:
                return t
    if name in ("sqlite_stat1", "sqlite_stat4"):
        return "sqlite_stat"
    if name == "sqlite_schema":
        return "sqlite_schema"
    return name


def dbstat_breakdown(conn):
    """返回 {b-tree 名: 字节} 与按主表汇总的 {分组: {'data':.., 'index':..}}。"""
    raw = {}
    for name, nbytes, ncell in conn.execute(
            "SELECT name, SUM(pgsize), SUM(ncell) FROM dbstat GROUP BY name"):
        raw[name] = {"bytes": nbytes or 0, "cells": ncell or 0}
    groups = {}
    for name, v in raw.items():
        owner = owner_table(name)
        is_index = (name.startswith("idx_") or name.startswith("sqlite_autoindex_"))
        if owner == "text_fts":
            key, kind = "text_fts（全文索引）", "index"
        elif owner == "sqlite_stat":
            key, kind = "sqlite_stat1/stat4（ANALYZE 统计）", "data"
        elif owner == "sqlite_schema":
            key, kind = "sqlite_schema（表定义）", "data"
        else:
            key = GROUP_OF.get(owner, owner)
            kind = "index" if is_index else "data"
        g = groups.setdefault(key, {"data": 0, "index": 0})
        g[kind] += v["bytes"]
    return raw, groups


def db_files(db_path):
    out = {}
    for suffix, label in (("", "主库"), ("-wal", "WAL"), ("-shm", "SHM")):
        p = db_path + suffix
        out[label] = os.path.getsize(p) if os.path.exists(p) else 0
    return out


# --------------------------------------------------------------------------- #
# 查询集
# --------------------------------------------------------------------------- #
# FTS 查询串：全部取自 gen_synth 容量语料，保证在库里真实存在。
FTS_QUERIES = [
    ("中文三字以上（常见词）", "采集覆盖率"),
    ("中文两字词（稀有，植入）", "蟠桃"),
    ("中文四字（稀有，植入）", "蟠桃调度器"),
    ("英文单词（常见）", "checkpoint"),
    ("英文单词（稀有，植入）", "zygomorphic"),
    ("代码标识符（稀有，植入）", "frobnicate_widget"),
    ("数字/错误码（常见）", "E1042"),
    ("中英混排短语（常见）", "FTS5 索引"),
    ("URL/域名", "sqlite.org"),
    ("文件路径", "tools/bench/fts_compare.py"),
    ("单个汉字（走扫描回退）", "帧"),
]

# 同样的查询串，但候选阶段改成 rowid 倒序（≈ 时间倒序），验证 §7 的修复建议
FTS_ROWID_VARIANTS = ["采集覆盖率", "checkpoint", "tools/bench/fts_compare.py"]
# 再加一道：rowid 倒序 + rowid 下界（= 只查最近 FTS_WINDOW_DAYS 天）
FTS_WINDOW_VARIANTS = ["采集覆盖率", "tools/bench/fts_compare.py"]
FTS_WINDOW_DAYS = 30

SCAN_WINDOW_DAYS = 7          # 单字查询与 app 扫描的时间窗（T3 §9.3 的口径）
CONTEXT_HOURS = 24            # get_context(hours=24)


def open_conn(db_path, hot_pragmas=True):
    import sqlite3

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA secure_delete = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    if hot_pragmas:
        conn.execute("PRAGMA temp_store = FILE")
    return conn


def load_params(db_path):
    """从库里取真实存在的查询参数（host / path / app / 时间窗）。"""
    conn = open_conn(db_path)
    max_ts = conn.execute("SELECT MAX(ts) FROM observations").fetchone()[0]
    min_ts = conn.execute("SELECT MIN(ts) FROM observations").fetchone()[0]
    device = conn.execute("SELECT device_id FROM observations LIMIT 1").fetchone()[0]
    host = conn.execute("SELECT host FROM urls WHERE host IS NOT NULL LIMIT 1").fetchone()[0]
    canon = conn.execute("SELECT canonical_url FROM urls LIMIT 1").fetchone()[0]
    path = conn.execute("SELECT path FROM files LIMIT 1").fetchone()[0]
    app_id, bundle = conn.execute(
        "SELECT a.id, a.bundle_id FROM apps a JOIN observations o ON o.app_id = a.id "
        "GROUP BY a.id ORDER BY COUNT(*) DESC LIMIT 1").fetchone()
    title = conn.execute("SELECT title FROM windows LIMIT 1").fetchone()[0]
    ids = [r[0] for r in conn.execute(
        "SELECT id FROM observations ORDER BY ts DESC LIMIT 20")]
    day_ms = 86400 * 1000
    vrow_lo = conn.execute(
        "SELECT COALESCE(MIN(vrow), 0) FROM text_versions WHERE created_at >= ?",
        (max_ts - FTS_WINDOW_DAYS * day_ms,)).fetchone()[0]
    conn.close()
    return {
        "device": device, "min_ts": min_ts, "max_ts": max_ts,
        "host": host, "canon_prefix": canon[:40], "path_frag": os.path.basename(path)[:12],
        "app_id": app_id, "bundle": bundle, "title_prefix": title[:6],
        "ctx_from": max_ts - CONTEXT_HOURS * 3600 * 1000, "ctx_to": max_ts,
        "scan_from": max_ts - SCAN_WINDOW_DAYS * day_ms, "scan_to": max_ts,
        "evidence_ids": ids,
        "vrow_%dd" % FTS_WINDOW_DAYS: vrow_lo,
    }


# ---- 四类查询的实现。每个函数返回 (命中行数)。 ---------------------------- #

def q_exact_host(conn, p):
    rows = conn.execute(
        "SELECT o.id, o.ts FROM observations o JOIN urls u ON u.id = o.url_id "
        "WHERE u.host = ? AND o.deleted_at IS NULL ORDER BY o.ts DESC LIMIT 20",
        (p["host"],)).fetchall()
    return len(rows)


def q_exact_url_prefix(conn, p):
    like = FTS.like_escape(p["canon_prefix"]) + "%"
    rows = conn.execute(
        "SELECT o.id FROM urls u JOIN observations o ON o.url_id = u.id "
        "WHERE u.canonical_url LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT 20", (like,)).fetchall()
    return len(rows)


def q_exact_path(conn, p):
    like = "%" + FTS.like_escape(p["path_frag"]) + "%"
    rows = conn.execute(
        "SELECT o.id FROM files f JOIN observations o ON o.file_id = f.id "
        "WHERE f.path LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT 20", (like,)).fetchall()
    return len(rows)


MISS_PATH = "tools/bench/fts_compare.py"      # files 表里没有这条路径，谓词命中 0 行


def q_exact_path_miss_join(conn, p):
    """命中 0 行 + 单条 JOIN + ORDER BY ts DESC LIMIT：退化成 observations 全表倒序扫描。"""
    like = "%" + FTS.like_escape(MISS_PATH) + "%"
    rows = conn.execute(
        "SELECT o.id, o.ts FROM files f JOIN observations o ON o.file_id = f.id "
        "WHERE f.path LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT 20", (like,)).fetchall()
    return len(rows)


def q_exact_path_miss_2step(conn, p):
    """同样命中 0 行，但先查 files 拿 id，空集直接返回。"""
    return len(_exact_channel(conn, MISS_PATH, "path"))


def q_exact_title(conn, p):
    like = FTS.like_escape(p["title_prefix"]) + "%"
    rows = conn.execute(
        "SELECT o.id FROM windows w JOIN observations o ON o.window_id = w.id "
        "WHERE w.title LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT 20", (like,)).fetchall()
    return len(rows)


def q_exact_evidence(conn, p):
    """get_evidence(ids)：按主键点查 20 条观察并展开正文。"""
    ph = ",".join("?" * len(p["evidence_ids"]))
    rows = conn.execute(
        "SELECT o.id, o.ts, tv.text FROM observations o "
        "LEFT JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id "
        "LEFT JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id "
        "WHERE o.device_id = ? AND o.id IN (%s)" % ph,
        [p["device"]] + p["evidence_ids"]).fetchall()
    return len(rows)


def _fts_channel(conn, q, device, limit=20, cand=200, order="bm25", rowid_lo=None):
    """T3 §9.4 的查询规划：bigram phrase 取候选 → LIKE 复核 → 展开到观察。

    order='bm25'  ：按 T3 §9.4 原样，`ORDER BY bm25(text_fts)`。
    order='rowid' ：改成 `ORDER BY rowid DESC`。text_versions.vrow 是单调递增的，
                    所以 rowid 倒序 ≈ 时间倒序；FTS5 可以直接从倒排表尾部拿前 N 条，
                    不必把整条 posting list 读完再排序。用来验证 §7 里那条修复建议。
    """
    pq = FTS.fts_phrase(FTS.bigram_join(q))
    ob = "ORDER BY bm25(text_fts)" if order == "bm25" else "ORDER BY rowid DESC"
    if rowid_lo is None:
        cands = [r[0] for r in conn.execute(
            "SELECT rowid FROM text_fts WHERE text_fts MATCH ? %s LIMIT ?" % ob, (pq, cand))]
    else:
        # vrow 单调递增，所以 rowid 下界 = 时间下界。FTS5 能把 rowid 约束推进倒排表，
        # 不用把整条 posting list 读完。
        cands = [r[0] for r in conn.execute(
            "SELECT rowid FROM text_fts WHERE text_fts MATCH ? AND rowid >= ? %s LIMIT ?" % ob,
            (pq, rowid_lo, cand))]
    if not cands:
        return []
    ph = ",".join("?" * len(cands))
    like = "%" + FTS.like_escape(q) + "%"
    verified = [r[0] for r in conn.execute(
        "SELECT id FROM text_versions WHERE vrow IN (%s) AND text LIKE ? ESCAPE '\\'" % ph,
        cands + [like])]
    if not verified:
        return []
    ph2 = ",".join("?" * len(verified))
    return conn.execute(
        "SELECT o.id, o.ts FROM occurrences oc "
        "JOIN observations o ON o.device_id = oc.device_id AND o.id = oc.observation_id "
        "WHERE oc.device_id = ? AND oc.text_version_id IN (%s) AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT ?" % ph2,
        [device] + verified + [limit]).fetchall()


def _exact_channel(conn, q, kind, limit=20):
    """精确字段通道。**先在小表上求出 id 集合，空集直接返回**。

    直接写成 `JOIN ... ORDER BY o.ts DESC LIMIT 20` 时，规划器为了满足 ORDER BY
    会选 `SCAN observations USING INDEX idx_obs_ts`（倒序）再回表查 files/urls；
    谓词一条都不命中时它就得把整张 observations 扫完 —— 12 个月规模上实测 533 ms。
    这个失败模式单独作为两条查询留在查询集里（见 §5 的「命中 0 行」两行）。
    """
    like = "%" + FTS.like_escape(q) + "%"
    if kind == "url":
        ids = [r[0] for r in conn.execute(
            "SELECT id FROM urls WHERE host = ? OR canonical_url LIKE ? ESCAPE '\\'",
            (q, like))]
        col = "url_id"
    else:
        ids = [r[0] for r in conn.execute(
            "SELECT id FROM files WHERE path LIKE ? ESCAPE '\\'", (like,))]
        col = "file_id"
    if not ids:
        return []
    ph = ",".join("?" * len(ids))
    return conn.execute(
        "SELECT id, ts FROM observations WHERE %s IN (%s) AND deleted_at IS NULL "
        "ORDER BY ts DESC LIMIT ?" % (col, ph), ids + [limit]).fetchall()


def _scan_channel(conn, q, p, limit=20):
    """单字查询：限定最近 SCAN_WINDOW_DAYS 天再扫正文（T3 §9.3）。"""
    like = "%" + FTS.like_escape(q) + "%"
    return conn.execute(
        "SELECT o.id, o.ts FROM observations o "
        "JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id "
        "JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id "
        "WHERE o.ts >= ? AND o.ts <= ? AND o.deleted_at IS NULL "
        "AND tv.text LIKE ? ESCAPE '\\' ORDER BY o.ts DESC LIMIT ?",
        (p["scan_from"], p["scan_to"], like, limit)).fetchall()


def make_fts_query(q, order="bm25", window_days=None):
    def run(conn, p):
        lo = p["vrow_%dd" % window_days] if window_days else None
        kind = FTS.route_kind(q)
        hits = {}
        if kind in ("url", "path"):
            for oid, ts in _exact_channel(conn, q, kind):
                hits[oid] = ts
        if len(q.strip()) == 1 and FTS.is_cjk(q.strip()):
            for oid, ts in _scan_channel(conn, q, p):
                hits[oid] = ts
        else:
            for oid, ts in _fts_channel(conn, q, p["device"], order=order, rowid_lo=lo):
                hits[oid] = ts
        return len(hits)
    return run


def q_ctx_by_app(conn, p):
    rows = conn.execute(
        "SELECT a.bundle_id, COUNT(*) n, MIN(o.ts), MAX(o.ts), "
        "SUM(o.completeness = 'complete'), SUM(o.completeness = 'partial'), "
        "SUM(o.source_state <> 'ok') "
        "FROM observations o JOIN apps a ON a.id = o.app_id "
        "WHERE o.device_id = ? AND o.deleted_at IS NULL AND o.ts >= ? AND o.ts <= ? "
        "GROUP BY 1 ORDER BY n DESC", (p["device"], p["ctx_from"], p["ctx_to"])).fetchall()
    return len(rows)


def q_ctx_sessions(conn, p):
    rows = conn.execute(
        'SELECT primary_app_id, COUNT(*), SUM(dwell_s), SUM(active_s), SUM(unknown_s) '
        'FROM sessions WHERE device_id = ? AND "end" >= ? AND start <= ? '
        'GROUP BY 1 ORDER BY 3 DESC', (p["device"], p["ctx_from"], p["ctx_to"])).fetchall()
    return len(rows)


def q_ctx_sessions_bounded(conn, p):
    """同上，但给 start 补一个下界，让 idx_sessions_range 能真正切范围。

    原查询 `"end" >= ? AND start <= ?` 在索引 (device_id, start, "end") 上只能用
    `start <= ctx_to`，等于扫掉库里几乎所有会话。补上 `start >= ctx_from - 最长会话`
    之后才是一个真正的区间。这里用 24 h 当会话长度上界。
    """
    lo = p["ctx_from"] - 24 * 3600 * 1000
    rows = conn.execute(
        'SELECT primary_app_id, COUNT(*), SUM(dwell_s), SUM(active_s), SUM(unknown_s) '
        'FROM sessions WHERE device_id = ? AND start >= ? AND start <= ? AND "end" >= ? '
        'GROUP BY 1 ORDER BY 3 DESC',
        (p["device"], lo, p["ctx_to"], p["ctx_from"])).fetchall()
    return len(rows)


def q_ctx_snippets(conn, p):
    rows = conn.execute(
        "SELECT o.id, o.ts, substr(tv.text, 1, 200) FROM observations o "
        "JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id "
        "JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id "
        "WHERE o.device_id = ? AND o.deleted_at IS NULL AND o.ts >= ? AND o.ts <= ? "
        "ORDER BY o.ts DESC LIMIT 30", (p["device"], p["ctx_from"], p["ctx_to"])).fetchall()
    return len(rows)


def q_ctx_full(conn, p):
    return q_ctx_by_app(conn, p) + q_ctx_sessions(conn, p) + q_ctx_snippets(conn, p)


def q_app_range_count(conn, p):
    row = conn.execute(
        "SELECT COUNT(*), MIN(ts), MAX(ts) FROM observations "
        "WHERE app_id = ? AND ts >= ? AND ts <= ? AND deleted_at IS NULL",
        (p["app_id"], p["scan_from"], p["scan_to"])).fetchone()
    return 1 if row else 0


def q_app_range_text(conn, p):
    rows = conn.execute(
        "SELECT o.id, o.ts, tv.byte_len FROM observations o "
        "JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id "
        "JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id "
        "WHERE o.app_id = ? AND o.ts >= ? AND o.ts <= ? AND o.deleted_at IS NULL "
        "ORDER BY o.ts DESC LIMIT 200", (p["app_id"], p["scan_from"], p["scan_to"])).fetchall()
    return len(rows)


def q_app_range_scan(conn, p):
    like = "%" + FTS.like_escape("采集覆盖率") + "%"
    rows = conn.execute(
        "SELECT o.id, o.ts FROM observations o "
        "JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id "
        "JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id "
        "WHERE o.app_id = ? AND o.ts >= ? AND o.ts <= ? AND o.deleted_at IS NULL "
        "AND tv.text LIKE ? ESCAPE '\\' ORDER BY o.ts DESC LIMIT 20",
        (p["app_id"], p["scan_from"], p["scan_to"], like)).fetchall()
    return len(rows)


def build_query_set():
    qs = [
        ("精确字段", "host 等值 → 观察", "exact_host", q_exact_host),
        ("精确字段", "canonical_url 前缀 → 观察", "exact_url_prefix", q_exact_url_prefix),
        ("精确字段", "files.path 子串 → 观察", "exact_path", q_exact_path),
        ("精确字段", "窗口标题前缀 → 观察", "exact_title", q_exact_title),
        ("精确字段", "get_evidence 主键点查 20 条", "exact_evidence", q_exact_evidence),
        ("精确字段", "路径命中 0 行：单条 JOIN + ORDER BY ts LIMIT",
         "exact_path_miss_join", q_exact_path_miss_join),
        ("精确字段", "路径命中 0 行：两步式（先查 files，空集早返回）",
         "exact_path_miss_2step", q_exact_path_miss_2step),
    ]
    for cat, q in FTS_QUERIES:
        qs.append(("FTS 检索", "%s：`%s`" % (cat, q), "fts_" + re.sub(r"\W+", "_", q),
                   make_fts_query(q)))
    for q in FTS_ROWID_VARIANTS:
        qs.append(("FTS 检索（rowid 倒序取候选）", "同上但按 rowid 倒序：`%s`" % q,
                   "ftsrid_" + re.sub(r"\W+", "_", q), make_fts_query(q, order="rowid")))
    for q in FTS_WINDOW_VARIANTS:
        qs.append(("FTS 检索（rowid 倒序 + 限最近 %d 天）" % FTS_WINDOW_DAYS,
                   "再加 rowid 下界：`%s`" % q,
                   "ftswin_" + re.sub(r"\W+", "_", q),
                   make_fts_query(q, order="rowid", window_days=FTS_WINDOW_DAYS)))
    qs += [
        ("get_context 聚合", "按应用聚合最近 %d h" % CONTEXT_HOURS, "ctx_by_app", q_ctx_by_app),
        ("get_context 聚合", "会话时长汇总最近 %d h" % CONTEXT_HOURS, "ctx_sessions", q_ctx_sessions),
        ("get_context 聚合", "会话时长汇总最近 %d h（start 补下界）" % CONTEXT_HOURS,
         "ctx_sessions_bounded", q_ctx_sessions_bounded),
        ("get_context 聚合", "取窗口内最近 30 段正文", "ctx_snippets", q_ctx_snippets),
        ("get_context 聚合", "get_context(hours=%d) 三段合计" % CONTEXT_HOURS, "ctx_full", q_ctx_full),
        ("app + 时间范围扫描", "计数（最近 %d 天）" % SCAN_WINDOW_DAYS, "app_count", q_app_range_count),
        ("app + 时间范围扫描", "取 200 条并连正文", "app_text", q_app_range_text),
        ("app + 时间范围扫描", "范围内 LIKE 扫描正文", "app_scan", q_app_range_scan),
    ]
    return qs


QUERY_SET = build_query_set()
QUERY_BY_ID = {q[2]: q for q in QUERY_SET}


# --------------------------------------------------------------------------- #
# 冷 / 热延迟
# --------------------------------------------------------------------------- #
def run_cold_round(db_path):
    """在**本进程内**跑一轮冷测：每个查询各开一条新连接，跑一次就关。

    由 --cold-worker 在一个全新的子进程里调用，所以是「新进程 + 新连接」。
    """
    p = load_params(db_path)
    out = {}
    for _cat, _label, qid, fn in QUERY_SET:
        conn = open_conn(db_path)
        t0 = time.perf_counter()
        try:
            n = fn(conn, p)
        except Exception as exc:                       # noqa: BLE001
            conn.close()
            out[qid] = {"ms": None, "rows": None, "error": "%s: %s" % (type(exc).__name__, exc)}
            continue
        dt = (time.perf_counter() - t0) * 1000.0
        conn.close()
        out[qid] = {"ms": dt, "rows": n, "error": None}
    return out


def measure_cold(db_path, rounds):
    """spawn `rounds` 个全新子进程，每个进程把整套查询各冷跑一次。"""
    per_q = {q[2]: [] for q in QUERY_SET}
    rows = {}
    errors = {}
    for _i in range(rounds):
        proc = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--cold-worker", db_path],
            capture_output=True, text=True)
        if proc.returncode != 0:
            raise SystemExit("冷测子进程失败：\n%s" % proc.stderr[-2000:])
        data = json.loads(proc.stdout)
        for qid, v in data.items():
            if v["error"]:
                errors[qid] = v["error"]
                continue
            per_q[qid].append(v["ms"])
            rows[qid] = v["rows"]
    return per_q, rows, errors


def measure_hot(db_path, reps):
    p = load_params(db_path)
    conn = open_conn(db_path)
    per_q = {}
    rows = {}
    errors = {}
    for _cat, _label, qid, fn in QUERY_SET:
        try:
            fn(conn, p)                                # 预热一次，不计入
        except Exception as exc:                       # noqa: BLE001
            errors[qid] = "%s: %s" % (type(exc).__name__, exc)
            per_q[qid] = []
            continue
        t0 = time.perf_counter()
        n = fn(conn, p)
        warm_ms = (time.perf_counter() - t0) * 1000.0
        r_eff = reps if warm_ms < 200 else max(3, int(reps * 200.0 / warm_ms))
        samples = []
        for _r in range(r_eff):
            t0 = time.perf_counter()
            n = fn(conn, p)
            samples.append((time.perf_counter() - t0) * 1000.0)
        per_q[qid] = samples
        rows[qid] = n
    conn.close()
    return per_q, rows, errors


def pct(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    idx = min(int(round((len(s) - 1) * q)), len(s) - 1)
    return s[idx]


# --------------------------------------------------------------------------- #
# 临时空间
# --------------------------------------------------------------------------- #
TEMP_OPS = [
    ("ANALYZE 重算统计", "ANALYZE"),
    ("全表排序 text_versions.sha256（外部归并）",
     "SELECT sha256 FROM text_versions ORDER BY sha256"),
    ("全表排序 text_versions.text（最坏情况：排序键带正文）",
     "SELECT vrow FROM text_versions ORDER BY text"),
    ("按应用 + 时间分组聚合（GROUP BY 溢出）",
     "SELECT app_id, date(ts/1000,'unixepoch'), COUNT(*) FROM observations "
     "GROUP BY 1, 2 ORDER BY 3 DESC"),
    ("incremental_vacuum 回收", "PRAGMA incremental_vacuum"),
    ("wal_checkpoint(TRUNCATE)", "PRAGMA wal_checkpoint(TRUNCATE)"),
]


def measure_temp_space(db_path, tmpdir):
    """把 SQLITE_TMPDIR 指到一个空目录，逐个跑重活并采样目录峰值。"""
    os.makedirs(tmpdir, exist_ok=True)
    for name in os.listdir(tmpdir):
        try:
            os.remove(os.path.join(tmpdir, name))
        except OSError:
            pass
    script = os.path.abspath(__file__)
    results = []
    for label, sql in TEMP_OPS:
        env = dict(os.environ, SQLITE_TMPDIR=tmpdir)
        db_before = sum(db_files(db_path).values())
        sampler = PeakSampler(db_path, tmpdir, interval=0.01)
        sampler.start()
        t0 = time.perf_counter()
        proc = subprocess.run([sys.executable, script, "--temp-worker", db_path, sql],
                              capture_output=True, text=True, env=env)
        dt = (time.perf_counter() - t0) * 1000.0
        sampler.stop()
        db_after = sum(db_files(db_path).values())
        db_delta = max(db_after - db_before, 0)
        results.append({"op": label, "sql": sql, "ms": dt,
                        "dir_peak_bytes": sampler.tmp_peak,
                        "fs_drop_peak_bytes": sampler.fs_drop_peak,
                        "db_delta_bytes": db_after - db_before,
                        "peak_bytes": max(sampler.fs_drop_peak - db_delta, 0),
                        "ok": proc.returncode == 0,
                        "err": proc.stderr[-300:] if proc.returncode else ""})
    return results


# --------------------------------------------------------------------------- #
# 一个规模的完整测量
# --------------------------------------------------------------------------- #
def measure_scale(months, days, build_dir, seed, fts_scheme, page_size,
                  cold_rounds, hot_reps, tag=None, do_latency=True, do_temp=True):
    tag = tag or ("%dm" % months)
    db_path = os.path.join(build_dir, "capacity_%s.db" % tag)
    tmpdir = os.path.join(build_dir, "tmp_%s" % tag)
    os.makedirs(tmpdir, exist_ok=True)
    os.environ["SQLITE_TMPDIR"] = tmpdir

    print("\n=== 规模 %s：%d 天 × 8640 次/天（fts=%s, page_size=%s）==="
          % (tag, days, fts_scheme, page_size or "默认 4096"), flush=True)
    sampler = PeakSampler(db_path, tmpdir, interval=0.05)
    sampler.start()
    last = [time.monotonic()]

    def progress(d, total, day_s, elapsed):
        if d % 15 == 0 or d == total:
            print("    第 %3d/%d 天  本天 %.2f s  累计 %.1f s  WAL 峰值 %.1f MiB"
                  % (d, total, day_s, elapsed, sampler.wal_peak / 1024.0 ** 2), flush=True)
            last[0] = time.monotonic()

    conn, gstats = gen_synth.generate_capacity(
        db_path, days, seed=seed, per_day=8640, avg_chars=1500, new_ratio=0.30,
        fts_scheme=fts_scheme, page_size=page_size, progress=progress, verbose=False)
    sampler.stop()

    raw, groups = dbstat_breakdown(conn)
    payload_bytes = conn.execute("SELECT COALESCE(SUM(byte_len),0) FROM text_versions").fetchone()[0]
    fts_rows = conn.execute("SELECT COUNT(*) FROM text_fts_docsize").fetchone()[0] \
        if "text_fts_docsize" in raw else None
    freelist = conn.execute("PRAGMA freelist_count").fetchone()[0]
    page_sz = conn.execute("PRAGMA page_size").fetchone()[0]
    integrity = conn.execute("PRAGMA quick_check").fetchone()[0]
    conn.close()

    files = db_files(db_path)
    total_file = sum(files.values())

    res = {
        "tag": tag, "months": months, "days": days, "fts_scheme": fts_scheme,
        "page_size": page_sz, "db_path": db_path,
        "gen": gstats,
        "dbstat_raw": raw, "dbstat_groups": groups,
        "payload_bytes": payload_bytes, "fts_rows": fts_rows,
        "freelist_pages": freelist, "freelist_bytes": freelist * page_sz,
        "integrity": integrity,
        "files": files, "total_file_bytes": total_file,
        "wal_peak_bytes": sampler.wal_peak, "shm_peak_bytes": sampler.shm_peak,
        "tmp_peak_build_bytes": sampler.tmp_peak,
        "build_s": gstats["build_s"], "finalize_s": gstats["finalize_s"],
    }
    print("    建库 %.1f s（+收尾 %.1f s）；主库 %.2f GiB；WAL 峰值 %.1f MiB"
          % (gstats["build_s"], gstats["finalize_s"], files["主库"] / 1024.0 ** 3,
             sampler.wal_peak / 1024.0 ** 2), flush=True)

    if do_temp:
        res["temp_ops"] = measure_temp_space(db_path, tmpdir)
        res["tmp_peak_ops_bytes"] = max([t["peak_bytes"] for t in res["temp_ops"]] or [0])
        print("    临时空间峰值（重活）：%.1f MiB"
              % (res["tmp_peak_ops_bytes"] / 1024.0 ** 2), flush=True)

    if do_latency:
        t0 = time.monotonic()
        cold, cold_rows, cold_err = measure_cold(db_path, cold_rounds)
        hot, hot_rows, hot_err = measure_hot(db_path, hot_reps)
        res["latency"] = {}
        for cat, label, qid, _fn in QUERY_SET:
            res["latency"][qid] = {
                "cat": cat, "label": label,
                "cold_p50": pct(cold.get(qid), 0.50), "cold_p95": pct(cold.get(qid), 0.95),
                "hot_p50": pct(hot.get(qid), 0.50), "hot_p95": pct(hot.get(qid), 0.95),
                "rows": hot_rows.get(qid, cold_rows.get(qid)),
                "cold_n": len(cold.get(qid, [])), "hot_n": len(hot.get(qid, [])),
                "error": cold_err.get(qid) or hot_err.get(qid),
            }
        print("    延迟测量 %.1f s（冷 %d 轮 / 热 %d 次）"
              % (time.monotonic() - t0, cold_rounds, hot_reps), flush=True)
    return res


# --------------------------------------------------------------------------- #
# 报告
# --------------------------------------------------------------------------- #
def mb(n):
    return "%.2f MiB" % (n / 1024.0 ** 2)


def gb(n):
    return "%.3f GiB" % (n / 1024.0 ** 3)


def human(n):
    """体积一律 2^10 进制，并且标 KiB/MiB/GiB（评审 F8：口径统一且把进制写在单位里）。

    §7 起的结论段落用的也是这套单位；与《实施计划》2.4 的十进制 GB 对账时，
    结论 §7 那张表同时给了两种进制的倍数。
    """
    if n >= 1024 ** 3:
        return "%.2f GiB" % (n / 1024.0 ** 3)
    if n >= 1024 ** 2:
        return "%.1f MiB" % (n / 1024.0 ** 2)
    if n >= 1024:
        return "%.1f KiB" % (n / 1024.0)
    return "%d B" % n


def ms(v):
    return "—" if v is None else ("%.2f" % v)


def write_report(path, results, sens, env, args, probe=None, cprobe=None):
    a = []
    w = a.append
    date = args.date
    base = {r["tag"]: r for r in results}
    # 外推条目（--max-build-min 触发）只进 §2 的行数/字节表，不进 dbstat / WAL / 延迟各表
    extras = [r for r in results if r.get("extrapolated")]
    extras.sort(key=lambda r: r["months"])
    main = [r for r in results if r["tag"] in ("1m", "3m", "12m") and not r.get("extrapolated")]
    main.sort(key=lambda r: r["months"])

    w("# brosis M0 · T5 容量与延迟实测（%s）" % date)
    w("")
    w("对应《实施计划》附录 A 的 **E7**、**2.4 验收口径**的「存储」与「延迟」两行，"
      "落实《调研方案评审》**F8**（统一按 UTF-8 字节分项，延迟分冷热 p50/p95，"
      "并在 1 / 3 / 12 个月三个规模上分别测）。全部数据本机实跑，"
      "脚本 `tools/proto/measure.py`，建库用 `tools/proto/gen_synth.py --capacity`。")
    w("")
    w("## 1. 环境与口径")
    w("")
    w("| 项 | 值 |")
    w("|---|---|")
    for k, v in env.items():
        w("| %s | %s |" % (k, v))
    w("")
    w("口径说明（先说清楚，后面所有数字都按这个）：")
    w("")
    w("- **规模**：每天 **8640 次捕获**（24 h ÷ 10 s），**30% 是新文本**，"
      "每次捕获的可见正文**平均 1500 字符**中英混排。1 个月 = 30 天，"
      "3 个月 = 90 天，12 个月 = 360 天，单设备单库。")
    w("- **8640 次/天怎么铺开**：可行性调研报告 §6.2 的同一个 8640 是按「12 h 活跃 ÷ 5 s」算的，"
      "本脚本把同样 8640 次**均匀铺满 24 h（每 10 s 一次）**。"
      "捕获次数与字节数完全一致，所以**容量结论不受影响**；受影响的只有按时间窗口取行的查询——"
      "`get_context(hours=24)` 这类查询在本报告里窗口内有 8640 条观察，"
      "而 12 h 活跃场景下同样的 24 h 窗口也是 8640 条但集中在半天，"
      "会话切分与「最近 N 小时」的行数分布因此不同，本报告的这几个延迟数字偏保守。")
    w("- **30%% 的分母是全部捕获**（评审 F8 的算式 `8640 × 1500 字符 × 30%%`）。"
      "实际上 %.1f%% 的捕获 `completeness ∈ {unavailable, excluded}`，根本没有正文，"
      "所以在「读到正文的捕获」里新文本概率被放大到 %.1f%%，"
      "使每天新 `text_version` 正好落在 8640 × 30%% = 2592 段附近。"
      % (100.0 * (1 - gen_synth.TEXT_CAPABLE_RATE),
         100.0 * 0.30 / gen_synth.TEXT_CAPABLE_RATE))
    w("- **一次捕获 = 一段完整可见正文**（schema 里 `text_versions.text` 的口径是"
      "「v1 存完整原文，不分块」），所以 `occurrences` 与有正文的 `observations` 一比一。")
    w("- **字节**：全部是 UTF-8 字节。库内分项用 `dbstat` 逐 b-tree 统计**实占页字节**，"
      "不是估算系数；「原文净载荷」是 `SUM(text_versions.byte_len)`，即正文本身的 UTF-8 字节。")
    w("- **FTS 方案**：T3 推荐的 **B+E+V**（`tools/bench/results/fts_compare_2026-09-06.md` §9.2）"
      "——汉字 bigram 预处理 + `unicode61 remove_diacritics 2` + `content=''` + "
      "`contentless_delete=1`，查询时 bigram 化包成 phrase，候选再用 `LIKE` 复核。")
    w("- **冷**：全新子进程 + 全新连接，每个查询单开一条连接跑一次就关；"
      "**只清掉了 SQLite 自己的页缓存，没有清 macOS 文件缓存**（清缓存要提权），"
      "所以冷数字是下界。还有第二个成因：冷测子进程在计时之前会先跑一次 `load_params()`"
      "（内含 `ORDER BY ts DESC LIMIT 20`、`MIN(vrow) WHERE created_at >= ?` 等），"
      "这会把一部分索引页与 `observations` 尾部的数据页读进 OS 文件缓存，"
      "**等于给后面的冷查询做了部分预热**。两个成因方向一致：真实冷启动只会更慢。"
      "**热**：同一连接，先预热 1 次再连测 %d 次。" % args.hot_reps)
    hotn = [d["hot_n"] for r in main if "latency" in r for d in r["latency"].values()
            if d.get("hot_n")]
    coldn = [d["cold_n"] for r in main if "latency" in r for d in r["latency"].values()
             if d.get("cold_n")]
    w("- **p50 / p95**：冷 %d 个样本；热的目标是 %d 个样本，但 `measure_hot` 有时间预算——"
      "**单次热执行 ≥ 200 ms 的查询按 `max(3, reps × 200 / 单次毫秒)` 缩减样本数，最少 3 个**。"
      "本轮实际热样本 %d–%d 个、冷样本 %d–%d 个，逐查询的 `hot_n` / `cold_n` 都在 JSON 里；"
      "被缩减的几条在 §5 表下面单独列出。样本数少的时候 p95 实际上就是最大值，"
      "这一点在读数字时要记住。"
      % (args.cold_rounds, args.hot_reps,
         min(hotn) if hotn else 0, max(hotn) if hotn else 0,
         min(coldn) if coldn else 0, max(coldn) if coldn else 0))
    w("- **单位**：本报告 §1–§6 的体积一律写作 **KiB / MiB / GiB = 2^10 / 2^20 / 2^30 字节**，"
      "字节原值在 JSON 里。**《实施计划》2.4 的「0.3 GB/月、1 GB/月、5 GB 配额」没有注明进制**，"
      "两种解释差 7%，所以 §7 的对比表同时给出 GiB 与十进制 GB 两套倍数与配额月数——"
      "建议在 2.4 里把进制定死（推荐十进制 GB，与 Finder、磁盘厂商一致）。")
    w("- **WAL 峰值**：建库全程后台每 50 ms 采样 `-wal` 文件字节取最大值。"
      "**临时空间**另有一套测法与坑，见 §4。")
    w("")

    # ---- 2. 规模与建库 ----
    w("## 2. 三个规模的行数与建库耗时")
    w("")
    w("| 规模 | 天数 | observations | occurrences | text_versions | sessions | "
      "正文净载荷 | 建库耗时 | 收尾（ANALYZE + checkpoint） | 吞吐 |")
    w("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in sorted(main + extras, key=lambda x: x["months"]):
        g = r["gen"]
        if r.get("extrapolated"):
            w("| %d 个月（**线性外推**，未实建） | %d | %s | %s | %s | %s | %s | — | — | — |"
              % (r["months"], r["days"], f"{g['observations']:,}", f"{g['occurrences']:,}",
                 f"{g['text_versions']:,}", f"{g['sessions']:,}", human(r["payload_bytes"])))
            continue
        thr = g["observations"] / max(g["build_s"], 1e-9)
        w("| %d 个月 | %d | %s | %s | %s | %s | %s | %s | %.1f s | %.0f 条观察/s |"
          % (r["months"], r["days"], f"{g['observations']:,}", f"{g['occurrences']:,}",
             f"{g['text_versions']:,}", f"{g['sessions']:,}", human(r["payload_bytes"]),
             fmt_dur(g["build_s"]), g["finalize_s"], thr))
    w("")
    if extras:
        w("> 标「线性外推」的行**没有真建库**：建库耗时按上一档实测外推超过 `--max-build-min` "
          "的上限就跳过实建，行数与字节按天数从 %d 个月那一档线性放大（`× 天数比`），"
          "延迟、WAL 峰值、`dbstat` 分项一律留空，后面 §3–§5 各表都不含这些规模。"
          "**这类行只能用来估量级，不能当实测数引用。**"
          % (extras[0].get("extrapolated_from_months", 0)))
        w("")
    ref = main[0]["gen"]
    w("正文语料实测：平均 **%.0f 字符/段**（目标 1500），**%.2f 字节/字符**，"
      "汉字占字符数的 **%.1f%%**。评审 F8 里「1–3 字节/字符」的区间在这份中英混排语料上"
      "落到 %.2f，`8640 × 1500 × 30%%` = 每天 388.8 万字符折合 **%s 新增正文/天**。"
      % (ref["text_chars"] / max(ref["text_versions"], 1),
         ref["text_bytes"] / max(ref["text_chars"], 1),
         100.0 * ref["cjk_chars"] / max(ref["text_chars"], 1),
         ref["text_bytes"] / max(ref["text_chars"], 1),
         human(main[0]["payload_bytes"] / main[0]["days"])))
    w("")

    # ---- 3. 分项字节 ----
    w("## 3. 分项字节（dbstat 逐 b-tree 实测）")
    w("")
    keys = []
    for r in main:
        for k in r["dbstat_groups"]:
            if k not in keys:
                keys.append(k)
    order = ["text_versions（原文）", "text_fts（全文索引）", "observations（观察）",
             "occurrences（出现记录）", "sessions（会话）", "ledgers（日台账）",
             "规范化对象（apps/windows/urls/files）",
             "策略与运行时（meta/jobs/grants/app_policies/deletions）",
             "sqlite_stat1/stat4（ANALYZE 统计）", "sqlite_schema（表定义）"]
    keys = [k for k in order if k in keys] + [k for k in keys if k not in order]

    for r in main:
        w("### 3.%d %d 个月（%s）" % (main.index(r) + 1, r["months"], r["db_path"]))
        w("")
        tot = r["total_file_bytes"]
        w("| 分项 | 表数据 | 索引 | 合计 | 占总文件 | 折合每月 |")
        w("|---|---:|---:|---:|---:|---:|")
        s_data = s_idx = 0
        for k in keys:
            g = r["dbstat_groups"].get(k)
            if not g:
                continue
            tt = g["data"] + g["index"]
            s_data += g["data"]
            s_idx += g["index"]
            w("| %s | %s | %s | %s | %.1f%% | %s |"
              % (k, human(g["data"]), human(g["index"]) if g["index"] else "—",
                 human(tt), 100.0 * tt / tot, human(tt / r["months"])))
        w("| **b-tree 合计** | **%s** | **%s** | **%s** | %.1f%% | %s |"
          % (human(s_data), human(s_idx), human(s_data + s_idx),
             100.0 * (s_data + s_idx) / tot, human((s_data + s_idx) / r["months"])))
        w("| 空闲页（freelist，%d 页） | — | — | %s | %.1f%% | — |"
          % (r["freelist_pages"], human(r["freelist_bytes"]),
             100.0 * r["freelist_bytes"] / tot))
        w("| WAL 文件（收尾 TRUNCATE 后） | — | — | %s | %.1f%% | — |"
          % (human(r["files"]["WAL"]), 100.0 * r["files"]["WAL"] / tot))
        w("| SHM 文件 | — | — | %s | %.1f%% | — |"
          % (human(r["files"]["SHM"]), 100.0 * r["files"]["SHM"] / tot))
        w("| **磁盘总占用（主库 + WAL + SHM）** | | | **%s** | 100%% | **%s** |"
          % (human(tot), human(tot / r["months"])))
        w("")
        w("- 正文净载荷 `SUM(byte_len)` = **%s**；`text_versions` 表实占 **%s**，"
          "**存储放大 %.2f×**（成因见 §7.2）。"
          % (human(r["payload_bytes"]),
             human(r["dbstat_groups"]["text_versions（原文）"]["data"]),
             r["dbstat_groups"]["text_versions（原文）"]["data"] / max(r["payload_bytes"], 1)))
        w("- 全文索引 **%s** = 正文净载荷的 **%.2f×**（T3 在 1.82 MiB 语料上是 0.55×）。"
          % (human(r["dbstat_groups"]["text_fts（全文索引）"]["index"]),
             r["dbstat_groups"]["text_fts（全文索引）"]["index"] / max(r["payload_bytes"], 1)))
        w("- **WAL 建库峰值 %s**、SHM 峰值 %s（每天一个事务，日终 COMMIT，"
          "`wal_autocheckpoint` 保持默认 1000 页）。" % (human(r["wal_peak_bytes"]),
                                                        human(r["shm_peak_bytes"])))
        w("- `PRAGMA quick_check` = `%s`。" % r["integrity"])
        w("")

    # ---- 4. 临时空间 ----
    w("## 4. 临时空间（SQLITE_TMPDIR 峰值）")
    w("")
    w("**测法与它的坑**：SQLite 在 unix 上建完临时文件立刻 `unlink`，"
      "所以扫 `SQLITE_TMPDIR` 目录**永远是 0 字节**（本轮实测三个规模全部 0，"
      "不是没占空间，是看不见）。这里改用「文件系统可用空间下降峰值 − 同期库文件增长」"
      "来估：把 `SQLITE_TMPDIR` 指到专用目录、`temp_store = FILE`、`cache_size` 保持默认 "
      "2 MiB，在**独立子进程**里逐个跑重活，后台每 10 ms 采一次 `statvfs`。"
      "这个数含其他进程的磁盘噪声，是**上界**不是精确值。")
    w("")
    w("| 操作 | " + " | ".join("%d 个月：临时空间 / 库增长 / 耗时" % r["months"] for r in main) + " |")
    w("|---|" + "---:|" * len(main))
    ops = [t["op"] for t in main[0].get("temp_ops", [])]
    for i, op in enumerate(ops):
        cells = []
        for r in main:
            t = r.get("temp_ops", [])
            if i < len(t):
                cells.append("%s / %s / %.0f ms"
                             % (human(t[i]["peak_bytes"]),
                                ("+" if t[i]["db_delta_bytes"] >= 0 else "−")
                                + human(abs(t[i]["db_delta_bytes"])), t[i]["ms"]))
            else:
                cells.append("—")
        w("| %s | %s |" % (op, " | ".join(cells)))
    w("")
    w("**`VACUUM` 不在上表里**：整库 `VACUUM` 需要约等于库本身大小的临时空间"
      "（12 个月规模就是 %s 量级），这正是 schema.sql 第一行把 `auto_vacuum` 设成 "
      "`INCREMENTAL` 的理由——日常只跑 `incremental_vacuum`，不跑整库 `VACUUM`。"
      % human(main[-1]["total_file_bytes"]))
    w("")

    # ---- 5. 延迟 ----
    w("## 5. 查询延迟（冷 / 热，p50 / p95，单位 ms）")
    w("")
    w("| 类别 | 查询 | 命中行 | " +
      " | ".join("%dm 冷 p50/p95 | %dm 热 p50/p95" % (r["months"], r["months"])
                 for r in main if "latency" in r) + " |")
    w("|---|---|---:|" + "---:|" * (2 * len([r for r in main if "latency" in r])))
    lat_scales = [r for r in main if "latency" in r]
    for cat, label, qid, _fn in QUERY_SET:
        cells = []
        rows_hit = None
        for r in lat_scales:
            d = r["latency"][qid]
            rows_hit = d["rows"] if rows_hit is None else rows_hit
            if d["error"]:
                cells += ["报错", "报错"]
            else:
                cells += ["%s/%s" % (ms(d["cold_p50"]), ms(d["cold_p95"])),
                          "%s/%s" % (ms(d["hot_p50"]), ms(d["hot_p95"]))]
        w("| %s | %s | %s | %s |" % (cat, label,
                                     "—" if rows_hit is None else rows_hit, " | ".join(cells)))
    w("")
    short = []
    for cat, label, qid, _fn in QUERY_SET:
        got = [(r["months"], r["latency"][qid]["hot_n"]) for r in lat_scales
               if r["latency"][qid].get("hot_n") and r["latency"][qid]["hot_n"] < args.hot_reps]
        if got:
            short.append("`%s`（%s）" % (label, "、".join("%dm: n=%d" % g for g in got)))
    if short:
        w("> **热样本被缩减的查询**（单次 ≥ 200 ms，按时间预算降到 "
          "`max(3, %d × 200 / 单次毫秒)`）：%s。其余查询都是满 %d 个热样本。"
          "这些行的 p95 由更少的样本得出，波动更大。" % (args.hot_reps, "；".join(short), args.hot_reps))
        w("")
    if extras:
        w("> %s 个月是线性外推的规模，没有真建库，所以不在这张表里——外推只放大行数与字节，不外推延迟。"
          % "、".join(str(r["months"]) for r in extras))
        w("")
    w("按类别汇总（同类查询的全部样本混在一起算分位）：")
    w("")
    w("| 类别 | " + " | ".join("%dm 冷 p50/p95 | %dm 热 p50/p95" % (r["months"], r["months"])
                               for r in lat_scales) + " |")
    w("|---|" + "---:|" * (2 * len(lat_scales)))
    cats = []
    for cat, _l, _q, _f in QUERY_SET:
        if cat not in cats:
            cats.append(cat)
    for cat in cats:
        cells = []
        for r in lat_scales:
            cold = [r["latency"][q[2]]["cold_p50"] for q in QUERY_SET
                    if q[0] == cat and r["latency"][q[2]]["cold_p50"] is not None]
            cold95 = [r["latency"][q[2]]["cold_p95"] for q in QUERY_SET
                      if q[0] == cat and r["latency"][q[2]]["cold_p95"] is not None]
            hot = [r["latency"][q[2]]["hot_p50"] for q in QUERY_SET
                   if q[0] == cat and r["latency"][q[2]]["hot_p50"] is not None]
            hot95 = [r["latency"][q[2]]["hot_p95"] for q in QUERY_SET
                     if q[0] == cat and r["latency"][q[2]]["hot_p95"] is not None]
            cells += ["%s/%s" % (ms(statistics.median(cold) if cold else None),
                                 ms(max(cold95) if cold95 else None)),
                      "%s/%s" % (ms(statistics.median(hot) if hot else None),
                                 ms(max(hot95) if hot95 else None))]
        w("| %s | %s |" % (cat, " | ".join(cells)))
    w("")

    # ---- 6. 敏感性 ----
    if sens:
        w("## 6. 敏感性：页大小与 FTS 方案（都在 1 个月规模上测）")
        w("")
        w("| 变体 | 主库 | text_versions 表 | 全文索引 | 磁盘总占用 | 折合每月 | 建库 |")
        w("|---|---:|---:|---:|---:|---:|---:|")
        for r in [base["1m"]] + sens:
            g = r["dbstat_groups"]
            w("| %s | %s | %s | %s | %s | %s | %s |"
              % (r.get("variant_label", "基准：page_size=%d，fts=%s"
                       % (r["page_size"], r["fts_scheme"])),
                 human(r["files"]["主库"]), human(g["text_versions（原文）"]["data"]),
                 human(g["text_fts（全文索引）"]["index"]), human(r["total_file_bytes"]),
                 human(r["total_file_bytes"] / r["months"]), fmt_dur(r["gen"]["build_s"])))
        w("")

    if probe:
        w("### 6.x 补一个 `observations(file_id, ts)` 索引值多少（%d 个月规模）"
          % probe.get("months", 12))
        w("")
        w("`schema.sql` 只给 `observations` 建了 `(app_id, ts)`，`file_id` / `url_id` / "
          "`window_id` 都没有配套的复合索引。补上之后：")
        w("")
        w("| 场景 | 建索引前 p50/p95 | 建索引后 p50/p95 | 建索引后的查询计划 |")
        w("|---|---:|---:|---|")
        for c in probe["cases"]:
            w("| %s | %s/%s | %s/%s | `%s` |"
              % (c["case"], ms(c["before_p50"]), ms(c["before_p95"]),
                 ms(c["after_p50"]), ms(c["after_p95"]), c["plan_after"]))
        w("")
        w("索引本身 **%s**（= 库的 %.2f%%），建索引耗时 **%s**；跑完已 `DROP INDEX` + "
          "`incremental_vacuum`，库回到 %s，所以 §3 的分项字节不受影响。"
          % (human(probe["index_bytes"]),
             100.0 * probe["index_bytes"] / max(probe["db_bytes_before"], 1),
             fmt_dur(probe["build_ms"] / 1000.0), human(probe["db_bytes_after"])))
        w("")

    if cprobe:
        w("### 6.y 正文字节按应用怎么分布，压不压得动（%d 个月规模）" % cprobe["months"])
        w("")
        w("字节按「这段正文第一次出现在哪个应用」记一次，复用不重复计数。"
          "这张表用来算「缩覆盖」这档降级能省多少。")
        w("")
        w("> **这张表几乎是平的，因为合成器是等概率在 8 个应用之间切换的**，"
          "不是因为真实使用就这么均匀。所以它现在只支持一句话：**关掉 1/8 的应用省 1/8 的正文字节**。"
          "真实的应用分布必须等 M1 试用实测，那时这张表才有选谁的价值。")
        w("")
        w("| 应用 | text_version 数 | 正文字节 | 占比 | 关掉它每月省 |")
        w("|---|---:|---:|---:|---:|")
        for r in cprobe["per_app"]:
            w("| %s（`%s`） | %s | %s | %.1f%% | %s |"
              % (r["name"], r["bundle"], f"{r['versions']:,}", human(r["bytes"]),
                 r["share"], human(r["bytes"] / cprobe["months"])))
        w("| **合计** | | **%s** | 100%% | **%s** |"
          % (human(cprobe["total_text_bytes"]),
             human(cprobe["total_text_bytes"] / cprobe["months"])))
        w("")
        w("压缩（只用标准库，`zlib` ≈ 通用 deflate，`lzma` ≈ zstd 高压缩档的量级；"
          "**逐段独立压缩**，因为要能单独取回一段原文）。样本 = 最近 %s 段正文、%s。"
          % (f"{cprobe['sample']:,}", human(cprobe["sample_bytes"])))
        w("")
        w("| 编码 | 压缩后 | 压缩比 | 压缩吞吐 | 解压吞吐 | 每段压缩 | 每段解压 |")
        w("|---|---:|---:|---:|---:|---:|---:|")
        for c in cprobe["codecs"]:
            w("| %s | %s | %.3f | %.0f MiB/s | %.0f MiB/s | %.0f µs | %.0f µs |"
              % (c["codec"], human(c["bytes"]), c["ratio"], c["compress_mb_s"],
                 c["decompress_mb_s"], c["us_per_doc_compress"], c["us_per_doc_decompress"]))
        w("")
    return a


def fmt_dur(s):
    if s < 90:
        return "%.1f s" % s
    return "%d 分 %02d 秒" % (int(s // 60), int(s % 60))


# --------------------------------------------------------------------------- #
INDEX_PROBE_SQL = (
    "SELECT o.id, o.ts FROM files f JOIN observations o ON o.file_id = f.id "
    "WHERE f.path LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL ORDER BY o.ts DESC LIMIT 20")


def index_probe(db_path, reps=8):
    """量一下 observations 缺 (file_id, ts) 复合索引的代价：建索引前 / 后 / 建索引成本。

    跑完会把索引 DROP 掉并 incremental_vacuum，库回到原样（§3 的分项字节是在这之前测的，
    不受影响）。
    """
    def timeit(conn, sql, args):
        conn.execute(sql, args).fetchall()                      # 预热
        xs = []
        for _ in range(reps):
            t0 = time.perf_counter()
            conn.execute(sql, args).fetchall()
            xs.append((time.perf_counter() - t0) * 1000.0)
        return pct(xs, 0.50), pct(xs, 0.95)

    conn = open_conn(db_path)
    hit = conn.execute("SELECT path FROM files LIMIT 1").fetchone()[0]
    cases = [("谓词命中 0 行", "%" + FTS.like_escape(MISS_PATH) + "%"),
             ("谓词命中 1 行（库里真有这个 file）", "%" + FTS.like_escape(os.path.basename(hit)) + "%")]
    out = {"db": db_path, "cases": []}
    before = {}
    for label, like in cases:
        before[label] = timeit(conn, INDEX_PROBE_SQL, (like,))

    size0 = os.path.getsize(db_path)
    t0 = time.perf_counter()
    conn.execute("CREATE INDEX idx_obs_file_ts ON observations(file_id, ts)")
    build_ms = (time.perf_counter() - t0) * 1000.0
    idx_bytes = conn.execute(
        "SELECT COALESCE(SUM(pgsize),0) FROM dbstat WHERE name='idx_obs_file_ts'").fetchone()[0]
    conn.execute("ANALYZE")
    for label, like in cases:
        p50, p95 = timeit(conn, INDEX_PROBE_SQL, (like,))
        b50, b95 = before[label]
        plan = " / ".join(r[3] for r in conn.execute("EXPLAIN QUERY PLAN " + INDEX_PROBE_SQL, (like,)))
        out["cases"].append({"case": label, "before_p50": b50, "before_p95": b95,
                             "after_p50": p50, "after_p95": p95, "plan_after": plan})
    conn.execute("DROP INDEX idx_obs_file_ts")
    conn.execute("ANALYZE")
    # 注意：PRAGMA incremental_vacuum 是逐页 step 的，只 execute 不取完结果等于没跑
    cur = conn.execute("PRAGMA incremental_vacuum")
    while cur.fetchmany(5000):
        pass
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    out.update({"index_bytes": idx_bytes, "build_ms": build_ms,
                "db_bytes_before": size0, "db_bytes_after": os.path.getsize(db_path)})
    return out


def content_probe(db_path, sample=4000, months=1):
    """两件事：正文字节按应用怎么分布（决定「缩覆盖」能省多少），以及正文压不压得动。

    压缩只用标准库：zlib（≈ 通用 deflate）与 lzma（≈ zstd 高压缩档的量级）。
    计划 3.4 说「压缩只有当 M0 容量实测证明必要时再引入」，这里给出那个「必要与否」的数。
    """
    import lzma
    import zlib

    conn = open_conn(db_path)
    # 一段正文可能被多条观察复用，字节按「第一次出现的应用」记一次，避免重复计数
    rows = conn.execute("""
        SELECT a.bundle_id, a.name, COUNT(*) AS n, SUM(t.byte_len) AS b
        FROM (
          SELECT tv.vrow AS vrow, tv.byte_len AS byte_len, MIN(o.id) AS first_obs
          FROM text_versions tv
          JOIN occurrences oc ON oc.device_id = tv.device_id AND oc.text_version_id = tv.id
          JOIN observations o ON o.device_id = oc.device_id AND o.id = oc.observation_id
          GROUP BY tv.vrow
        ) t
        JOIN observations o2 ON o2.id = t.first_obs
        JOIN apps a ON a.id = o2.app_id
        GROUP BY 1, 2 ORDER BY b DESC""").fetchall()
    total_b = sum(r[3] for r in rows) or 1
    per_app = [{"bundle": r[0], "name": r[1], "versions": r[2], "bytes": r[3],
                "share": 100.0 * r[3] / total_b} for r in rows]

    texts = [r[0] for r in conn.execute(
        "SELECT text FROM text_versions ORDER BY vrow DESC LIMIT ?", (sample,))]
    conn.close()
    raws = [t.encode("utf-8") for t in texts]
    raw_total = sum(len(x) for x in raws)

    out = {"db": db_path, "months": months, "per_app": per_app,
           "total_text_bytes": total_b, "sample": len(raws), "sample_bytes": raw_total,
           "codecs": []}
    for label, comp, dec in (
            ("zlib level 6（逐段独立压缩）",
             lambda b: zlib.compress(b, 6), lambda b: zlib.decompress(b)),
            ("zlib level 9（逐段独立压缩）",
             lambda b: zlib.compress(b, 9), lambda b: zlib.decompress(b)),
            ("lzma preset 3（逐段独立压缩）",
             lambda b: lzma.compress(b, preset=3), lambda b: lzma.decompress(b))):
        t0 = time.perf_counter()
        blobs = [comp(x) for x in raws]
        ct = time.perf_counter() - t0
        t0 = time.perf_counter()
        for x in blobs:
            dec(x)
        dt = time.perf_counter() - t0
        comp_total = sum(len(x) for x in blobs)
        out["codecs"].append({
            "codec": label, "bytes": comp_total, "ratio": comp_total / raw_total,
            "compress_mb_s": raw_total / 1024.0 ** 2 / max(ct, 1e-9),
            "decompress_mb_s": raw_total / 1024.0 ** 2 / max(dt, 1e-9),
            "us_per_doc_compress": ct / len(raws) * 1e6,
            "us_per_doc_decompress": dt / len(raws) * 1e6})
    return out


def env_info():
    import platform
    import sqlite3

    return {
        "日期": time.strftime("%Y-%m-%d %H:%M %Z"),
        "Python": platform.python_version(),
        "SQLite 库版本（Python 链接）": sqlite3.sqlite_version,
        "平台": "%s / %s" % (platform.platform(), platform.machine()),
        "sqlite3 CLI": (subprocess.run(["sqlite3", "--version"], capture_output=True,
                                       text=True).stdout.split()[0]
                        if shutil.which("sqlite3") else "未安装"),
        "构建目录": DEFAULT_BUILD,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="brosis E7 / T5 容量与延迟测量")
    ap.add_argument("--cold-worker", metavar="DB", help="内部用：在新进程里跑一轮冷测")
    ap.add_argument("--temp-worker", nargs=2, metavar=("DB", "SQL"), help="内部用：跑一条重活")
    ap.add_argument("--scales", default="1,3,12", help="要测的规模（月），逗号分隔")
    ap.add_argument("--days-per-month", type=int, default=DAYS_PER_MONTH)
    ap.add_argument("--seed", type=int, default=20260906)
    ap.add_argument("--build-dir", default=DEFAULT_BUILD)
    ap.add_argument("--fts", default="bigram", choices=["bigram", "trigram"])
    ap.add_argument("--cold-rounds", type=int, default=10, help="冷测轮数（每轮一个新进程）")
    ap.add_argument("--hot-reps", type=int, default=20, help="热测重复次数")
    ap.add_argument("--sensitivity", action="store_true",
                    help="额外在 1 个月规模上跑页大小与 trigram 变体")
    ap.add_argument("--max-build-min", type=float, default=20.0,
                    help="单个规模的建库时间上限（分钟）；超过则不实建，按天数线性外推行数与字节"
                         "（延迟、WAL、dbstat 分项不外推，报告里标「线性外推」）")
    ap.add_argument("--date", default=time.strftime("%Y-%m-%d"))
    ap.add_argument("--report", default=None, help="报告输出路径（默认 results/capacity_<日期>.md）")
    ap.add_argument("--results-dir", default=None,
                    help="JSON 与报告的输出目录（默认 tools/proto/results；试跑时指到缓存目录，"
                         "别覆盖 results/ 里的存档）")
    ap.add_argument("--content-probe", action="store_true",
                    help="按应用统计正文字节分布，并测正文的压缩比与压缩/解压吞吐")
    ap.add_argument("--index-probe", action="store_true",
                    help="在 JSON 里最大的那个库上测 observations 缺 (file_id, ts) 索引的代价")
    ap.add_argument("--latency-only", action="store_true",
                    help="不重建库，在 JSON 里已有的库上重跑延迟，合并后重出报告")
    ap.add_argument("--report-only", action="store_true",
                    help="不重跑测量，直接从 results/capacity_<日期>.json 重新生成报告")
    args = ap.parse_args(argv)

    if args.cold_worker:
        json.dump(run_cold_round(args.cold_worker), sys.stdout)
        return 0
    if args.temp_worker:
        db, sql = args.temp_worker
        conn = open_conn(db)
        conn.execute("PRAGMA temp_store = FILE")
        cur = conn.execute(sql)
        while cur.fetchmany(5000):
            pass
        conn.close()
        return 0

    results_dir = args.results_dir or os.path.join(HERE, "results")
    os.makedirs(results_dir, exist_ok=True)
    json_path = os.path.join(results_dir, "capacity_%s.json" % args.date)

    if args.content_probe:
        with open(json_path, encoding="utf-8") as fh:
            blob = json.load(fh)
        target = min((r for r in blob["results"] if os.path.exists(r["db_path"])),
                     key=lambda r: r["months"])
        print("内容对照：%s" % target["db_path"], flush=True)
        blob["content_probe"] = content_probe(target["db_path"], months=target["months"])
        with open(json_path, "w", encoding="utf-8") as fh:
            json.dump(blob, fh, ensure_ascii=False, indent=1, default=str)
        emit_report(args, blob["results"], blob["sensitivity"], blob["env"], results_dir,
                    blob.get("index_probe"), blob.get("content_probe"))
        return 0

    if args.index_probe:
        with open(json_path, encoding="utf-8") as fh:
            blob = json.load(fh)
        target = max((r for r in blob["results"] if os.path.exists(r["db_path"])),
                     key=lambda r: r["months"])
        print("索引对照：%s" % target["db_path"], flush=True)
        blob["index_probe"] = index_probe(target["db_path"])
        blob["index_probe"]["months"] = target["months"]
        with open(json_path, "w", encoding="utf-8") as fh:
            json.dump(blob, fh, ensure_ascii=False, indent=1, default=str)
        emit_report(args, blob["results"], blob["sensitivity"], blob["env"], results_dir,
                    blob.get("index_probe"), blob.get("content_probe"))
        return 0

    if args.latency_only:
        with open(json_path, encoding="utf-8") as fh:
            blob = json.load(fh)
        for r in blob["results"]:
            if not os.path.exists(r["db_path"]):
                print("跳过 %s：库不在了（%s）" % (r["tag"], r["db_path"]))
                continue
            print("重测延迟：%s" % r["tag"], flush=True)
            os.environ["SQLITE_TMPDIR"] = os.path.join(args.build_dir, "tmp_%s" % r["tag"])
            os.makedirs(os.environ["SQLITE_TMPDIR"], exist_ok=True)
            cold, cold_rows, cold_err = measure_cold(r["db_path"], args.cold_rounds)
            hot, hot_rows, hot_err = measure_hot(r["db_path"], args.hot_reps)
            lat = r.get("latency", {})
            for cat, label, qid, _fn in QUERY_SET:
                lat[qid] = {
                    "cat": cat, "label": label,
                    "cold_p50": pct(cold.get(qid), 0.50), "cold_p95": pct(cold.get(qid), 0.95),
                    "hot_p50": pct(hot.get(qid), 0.50), "hot_p95": pct(hot.get(qid), 0.95),
                    "rows": hot_rows.get(qid, cold_rows.get(qid)),
                    "cold_n": len(cold.get(qid, [])), "hot_n": len(hot.get(qid, [])),
                    "error": cold_err.get(qid) or hot_err.get(qid)}
            r["latency"] = lat
        with open(json_path, "w", encoding="utf-8") as fh:
            json.dump(blob, fh, ensure_ascii=False, indent=1, default=str)
        emit_report(args, blob["results"], blob["sensitivity"], blob["env"], results_dir,
                    blob.get("index_probe"), blob.get("content_probe"))
        return 0

    if args.report_only:
        with open(json_path, encoding="utf-8") as fh:
            blob = json.load(fh)
        emit_report(args, blob["results"], blob["sensitivity"], blob["env"], results_dir,
                    blob.get("index_probe"), blob.get("content_probe"))
        return 0

    os.makedirs(args.build_dir, exist_ok=True)
    scales = [int(x) for x in args.scales.split(",") if x.strip()]
    results = []
    prev = None
    for m in scales:
        days = m * args.days_per_month
        if prev is not None:
            per_day = prev["gen"]["build_s"] / prev["days"]
            est_min = per_day * days * 1.3 / 60.0        # 1.3 = 规模增大后的写放大余量
            if est_min > args.max_build_min:
                print("跳过实建 %d 个月：按 %d 个月实测外推需要约 %.1f 分钟 > 上限 %.1f 分钟；"
                      "改为按天数线性外推行数与字节（延迟不外推）"
                      % (m, prev["months"], est_min, args.max_build_min), flush=True)
                results.append(extrapolate_scale(prev, m, days))
                continue
        r = measure_scale(m, days, args.build_dir, args.seed, args.fts, None,
                          args.cold_rounds, args.hot_reps)
        results.append(r)
        prev = r

    sens = []
    if args.sensitivity:
        for ps in (8192, 16384):
            r = measure_scale(1, args.days_per_month, args.build_dir, args.seed, args.fts, ps,
                              args.cold_rounds, args.hot_reps,
                              tag="1m_ps%d" % ps, do_latency=False, do_temp=False)
            r["variant_label"] = "page_size=%d，fts=%s" % (ps, args.fts)
            sens.append(r)
        r = measure_scale(1, args.days_per_month, args.build_dir, args.seed, "trigram", None,
                          args.cold_rounds, args.hot_reps,
                          tag="1m_trigram", do_latency=False, do_temp=False)
        r["variant_label"] = "page_size=4096，fts=trigram detail=full（schema.sql 占位）"
        sens.append(r)

    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump({"env": env_info(), "args": vars(args),
                   "results": results, "sensitivity": sens}, fh,
                  ensure_ascii=False, indent=1, default=str)
    print("\n原始数据：%s" % json_path)
    emit_report(args, results, sens, env_info(), results_dir)
    return 0


def extrapolate_scale(prev, months, days):
    """--max-build-min 触发时：不实建库，按天数线性放大行数与字节。

    只放大「随时间线性增长」的量（行数、正文字节、库文件字节）；
    延迟、WAL 峰值、临时空间、dbstat 分项都不外推——它们不是线性的，
    猜一个数比留空更糟。report 里这类条目会显式标「线性外推」。
    """
    k = days / float(prev["days"])
    g = prev["gen"]
    gen = {key: (int(round(g[key] * k)) if isinstance(g.get(key), int) else None)
           for key in ("observations", "occurrences", "text_versions", "sessions")}
    gen["build_s"] = None
    gen["finalize_s"] = None
    return {
        "tag": "%dm" % months, "months": months, "days": days,
        "extrapolated": True, "extrapolated_from_months": prev["months"],
        "extrapolated_factor": k,
        "gen": gen,
        "payload_bytes": int(round(prev["payload_bytes"] * k)),
        "total_file_bytes": int(round(prev["total_file_bytes"] * k)),
        "page_size": prev.get("page_size"), "fts_scheme": prev.get("fts_scheme"),
    }


def emit_report(args, results, sens, env, results_dir, probe=None, cprobe=None):
    """§1–§6 由脚本按实测数生成；§7 起的结论段落取自 capacity_conclusions.md。"""
    report_path = args.report or os.path.join(results_dir, "capacity_%s.md" % args.date)
    lines = write_report(report_path, results, sens, env, args, probe, cprobe)
    concl = os.path.join(HERE, "capacity_conclusions.md")
    if os.path.exists(concl):
        with open(concl, encoding="utf-8") as fh:
            lines.append(fh.read().rstrip("\n"))
    else:
        lines.append("> 结论段落缺失：把 §7 起的内容写进 `tools/proto/capacity_conclusions.md`，"
                     "再跑 `measure.py --report-only` 重新拼接。")
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("报告：%s" % report_path)


if __name__ == "__main__":
    sys.exit(main())
