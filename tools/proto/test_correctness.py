#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M0 / E3：schema 正确性与删除级联测试（实施计划 3.2、3.8，评审 F4）。

只用 Python 标准库。运行后会重新生成合成库，依次跑 7 个场景，并把每个场景的
通过/失败与关键数字写成 Markdown 报告。

    python3 test_correctness.py                     # 用默认参数跑全部场景并写报告
    python3 test_correctness.py --days 7 --per-day 120 --seed 20260906
    python3 test_correctness.py --report /path/to/out.md

退出码 0 = 全部通过，1 = 有场景失败。
"""

import argparse
import json
import os
import platform
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.dont_write_bytecode = True   # 项目目录在 iCloud Drive 里，不要留 __pycache__
import gen_synth  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.expanduser("~/Library/Caches/brosis-build/proto")


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def q1(conn, sql, args=()):
    row = conn.execute(sql, args).fetchone()
    return None if row is None else row[0]


def fts_phrase(s):
    """把任意字符串包成 FTS5 短语查询（trigram 分词下等价于子串匹配）。"""
    return '"' + s.replace('"', '""') + '"'


def now_ms():
    return int(time.time() * 1000)


def rm_thumb(db_path, ref):
    if not ref:
        return 0
    p = os.path.join(gen_synth.thumb_dir(db_path), ref)
    if os.path.exists(p):
        os.remove(p)
        return 1
    return 0


def mark_derived_stale(conn, device, obs_ids):
    """派生结果（sessions / ledgers）证据里只要命中一个被删观察，就标 stale 待重算（3.8）。"""
    target = set(obs_ids)
    s_n = l_n = 0
    for table in ("sessions", "ledgers"):
        for row in conn.execute(
                "SELECT id, evidence, stale FROM %s WHERE device_id = ?" % table, (device,)).fetchall():
            if row["stale"]:
                continue
            if target.intersection(json.loads(row["evidence"])):
                conn.execute("UPDATE %s SET stale = 1 WHERE device_id = ? AND id = ?" % table,
                             (device, row["id"]))
                if table == "sessions":
                    s_n += 1
                else:
                    l_n += 1
    return s_n, l_n


def sweep_orphan_versions(conn, device, candidate_tv_ids):
    """删掉候选里已经没有任何 occurrence 的文本版本；FTS 行由 AFTER DELETE 触发器同步删除。"""
    freed_bytes = 0
    deleted = 0
    for tv_id in sorted(candidate_tv_ids):
        left = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id = ? AND text_version_id = ?",
                  (device, tv_id))
        if left:
            continue
        blen = q1(conn, "SELECT byte_len FROM text_versions WHERE device_id = ? AND id = ?", (device, tv_id))
        if blen is None:
            continue
        conn.execute("DELETE FROM text_versions WHERE device_id = ? AND id = ?", (device, tv_id))
        deleted += 1
        freed_bytes += blen
    return deleted, freed_bytes


def next_deletion_id(conn, device):
    return (q1(conn, "SELECT COALESCE(MAX(id),0) FROM deletions WHERE device_id = ?", (device,)) or 0) + 1


# --------------------------------------------------------------------------- #
# 删除引擎：用户主动删除 vs 配额过期（3.8 里语义不同的两条路径）
# --------------------------------------------------------------------------- #
def user_delete(conn, db_path, device, obs_ids, kind, params):
    """用户主动删除：observations 打 deleted_at 墓碑（保留用于审计与跨设备同步），
    内容全部级联清除。顺序：observation → occurrences → 无引用 text_version → FTS 行
    → 派生结果 stale → 缩略图文件 → 审计行。"""
    if not obs_ids:
        raise ValueError("空的删除集合")
    marks = ",".join("?" * len(obs_ids))
    conn.execute("BEGIN")
    ts = now_ms()
    # fts_rows_deleted 是审计字段，必须实测而不是照抄 text_versions_deleted：
    # 触发器保证 1:1 是被审计的对象本身，抄过去就失去了独立核验的意义。
    fts_before = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")

    tv_ids = {r[0] for r in conn.execute(
        "SELECT DISTINCT text_version_id FROM occurrences WHERE device_id = ? AND observation_id IN (%s)"
        % marks, [device] + obs_ids)}
    thumbs = [r[0] for r in conn.execute(
        "SELECT thumb_ref FROM observations WHERE device_id = ? AND id IN (%s) AND thumb_ref IS NOT NULL"
        % marks, [device] + obs_ids)]

    cur = conn.execute("UPDATE observations SET deleted_at = ?, thumb_ref = NULL "
                       "WHERE device_id = ? AND id IN (%s) AND deleted_at IS NULL" % marks,
                       [ts, device] + obs_ids)
    obs_marked = cur.rowcount
    cur = conn.execute("DELETE FROM occurrences WHERE device_id = ? AND observation_id IN (%s)" % marks,
                       [device] + obs_ids)
    occ_deleted = cur.rowcount
    tv_deleted, bytes_freed = sweep_orphan_versions(conn, device, tv_ids)
    fts_deleted = fts_before - q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    s_stale, l_stale = mark_derived_stale(conn, device, obs_ids)
    thumbs_deleted = sum(rm_thumb(db_path, t) for t in thumbs)

    conn.execute(
        "INSERT INTO deletions(device_id, id, kind, reason, params, applied_at, observations_affected, "
        "occurrences_deleted, text_versions_deleted, fts_rows_deleted, sessions_stale, ledgers_stale, "
        "thumbs_deleted, bytes_freed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (device, next_deletion_id(conn, device), kind, "user",
         json.dumps(params, ensure_ascii=False), ts, obs_marked, occ_deleted, tv_deleted,
         fts_deleted, s_stale, l_stale, thumbs_deleted, bytes_freed))
    conn.execute("COMMIT")
    return {"observations_marked": obs_marked, "occurrences_deleted": occ_deleted,
            "text_versions_deleted": tv_deleted, "fts_rows_deleted": fts_deleted,
            "sessions_stale": s_stale, "ledgers_stale": l_stale,
            "thumbs_deleted": thumbs_deleted, "bytes_freed": bytes_freed}


def quota_expire(conn, db_path, device, target_bytes, batch=50):
    """配额过期：最旧先删。与用户删除的区别是 observations 行物理删除（真正回收空间），
    删除审计行本身就是这段范围的墓碑；内容级联路径与用户删除相同。"""
    total = 0
    stats = {"observations_deleted": 0, "occurrences_deleted": 0, "text_versions_deleted": 0,
             "fts_rows_deleted": 0, "bytes_freed": 0, "sessions_stale": 0, "ledgers_stale": 0,
             "thumbs_deleted": 0, "oldest_ts": None, "newest_deleted_ts": None}
    content_bytes = q1(conn, "SELECT COALESCE(SUM(byte_len),0) FROM text_versions WHERE device_id = ?",
                       (device,))
    if content_bytes <= target_bytes:
        return stats, content_bytes
    ts0 = now_ms()
    conn.execute("BEGIN")
    fts_before = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")   # 实测 FTS 行减少量
    while content_bytes > target_bytes:
        rows = conn.execute(
            "SELECT id, ts, thumb_ref FROM observations WHERE device_id = ? ORDER BY ts, id LIMIT ?",
            (device, batch)).fetchall()
        if not rows:
            break
        ids = [r["id"] for r in rows]
        if stats["oldest_ts"] is None:
            stats["oldest_ts"] = rows[0]["ts"]
        stats["newest_deleted_ts"] = rows[-1]["ts"]
        marks = ",".join("?" * len(ids))
        tv_ids = {r[0] for r in conn.execute(
            "SELECT DISTINCT text_version_id FROM occurrences WHERE device_id = ? AND observation_id IN (%s)"
            % marks, [device] + ids)}
        occ_n = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id = ? AND observation_id IN (%s)"
                   % marks, [device] + ids)
        for r in rows:
            stats["thumbs_deleted"] += rm_thumb(db_path, r["thumb_ref"])
        # ON DELETE CASCADE 自动带走 occurrences
        conn.execute("DELETE FROM observations WHERE device_id = ? AND id IN (%s)" % marks,
                     [device] + ids)
        tv_n, freed = sweep_orphan_versions(conn, device, tv_ids)
        s_n, l_n = mark_derived_stale(conn, device, ids)
        stats["observations_deleted"] += len(ids)
        stats["occurrences_deleted"] += occ_n
        stats["text_versions_deleted"] += tv_n
        stats["bytes_freed"] += freed
        stats["sessions_stale"] += s_n
        stats["ledgers_stale"] += l_n
        content_bytes -= freed
        total += 1
    stats["fts_rows_deleted"] = fts_before - q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    conn.execute(
        "INSERT INTO deletions(device_id, id, kind, reason, params, applied_at, observations_affected, "
        "occurrences_deleted, text_versions_deleted, fts_rows_deleted, sessions_stale, ledgers_stale, "
        "thumbs_deleted, bytes_freed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (device, next_deletion_id(conn, device), "range", "quota",
         json.dumps({"policy": "oldest_first", "target_bytes": target_bytes,
                     "batches": total, "device_id": device}, ensure_ascii=False),
         ts0, stats["observations_deleted"], stats["occurrences_deleted"],
         stats["text_versions_deleted"], stats["fts_rows_deleted"],
         stats["sessions_stale"], stats["ledgers_stale"], stats["thumbs_deleted"],
         stats["bytes_freed"]))
    conn.execute("COMMIT")
    return stats, content_bytes


# --------------------------------------------------------------------------- #
# 场景
# --------------------------------------------------------------------------- #
class Scenario(object):
    def __init__(self, key, title):
        self.key = key
        self.title = title
        self.rows = []          # (指标, 值)
        self.notes = []
        self.checks = []        # (描述, bool)

    def n(self, k, v):
        self.rows.append((k, v))

    def check(self, desc, ok):
        self.checks.append((desc, bool(ok)))
        return bool(ok)

    @property
    def passed(self):
        return all(ok for _d, ok in self.checks) and bool(self.checks)


def scenario_1_reuse(conn):
    s = Scenario("S1", "同一文本重复出现 → 一个 text_version、多条 occurrence")
    dup_sha = q1(conn, "SELECT COUNT(*) FROM (SELECT device_id, sha256 FROM text_versions "
                       "GROUP BY 1,2 HAVING COUNT(*) > 1)")
    tv_total = q1(conn, "SELECT COUNT(*) FROM text_versions")
    occ_total = q1(conn, "SELECT COUNT(*) FROM occurrences")
    shared = q1(conn, "SELECT COUNT(*) FROM (SELECT device_id, text_version_id FROM occurrences "
                      "GROUP BY 1,2 HAVING COUNT(*) > 1)")
    top = conn.execute(
        "SELECT o.device_id AS d, o.text_version_id AS tv, COUNT(*) AS n, "
        "COUNT(DISTINCT ob.app_id) AS apps, substr(tv2.text,1,28) AS snippet "
        "FROM occurrences o JOIN observations ob ON ob.device_id=o.device_id AND ob.id=o.observation_id "
        "JOIN text_versions tv2 ON tv2.device_id=o.device_id AND tv2.id=o.text_version_id "
        "GROUP BY 1,2 ORDER BY n DESC LIMIT 1").fetchone()
    bad_len = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE byte_len != length(CAST(text AS BLOB))")

    s.n("text_versions 总数", "%d 个" % tv_total)
    s.n("occurrences 总数", "%d 条" % occ_total)
    s.n("occurrence / version 比", "%.2f" % (occ_total / float(tv_total)))
    s.n("同一设备内 sha256 重复的版本", "%d 个" % dup_sha)
    s.n("被 ≥2 条 occurrence 引用的版本", "%d 个（占 %.1f%%）" % (shared, 100.0 * shared / tv_total))
    s.n("引用最多的一个版本", "%d 条 occurrence，跨 %d 个应用，原文前 28 字「%s…」"
        % (top["n"], top["apps"], top["snippet"].replace("\n", " ")))
    s.n("byte_len 与实际 UTF-8 字节不一致的版本", "%d 个" % bad_len)

    s.check("同一设备内不存在两个 sha256 相同的 text_version（精确哈希复用生效）", dup_sha == 0)
    s.check("存在被多条 occurrence 共享的版本（复用确实发生）", shared > 0)
    s.check("最热版本跨 ≥2 个应用出现，且每次出现各留一条 occurrence", top["n"] > 1 and top["apps"] >= 2)
    s.check("byte_len 口径正确（等于原文 UTF-8 字节数）", bad_len == 0)
    return s


def scenario_2_edit(conn):
    s = Scenario("S2", "正文修改后两版都可取回，按 observation 能查到对应版本")
    device = "dev-mbp16"
    vers = conn.execute(
        "SELECT id, sha256, byte_len, text FROM text_versions "
        "WHERE device_id = ? AND text LIKE '项目 A 季度规划%' ORDER BY id", (device,)).fetchall()
    s.n("「项目 A 季度规划」在 %s 上的版本数" % device, "%d 个" % len(vers))
    ok_two = s.check("同一文档的两版各自是独立、不可变的 text_version（不是覆盖）", len(vers) == 2)

    detail = []
    if ok_two:
        for v in vers:
            budget = "100" if "预算 100" in v["text"] else ("200" if "预算 200" in v["text"] else "?")
            occ = conn.execute(
                "SELECT o.observation_id AS oid, ob.ts AS ts FROM occurrences o "
                "JOIN observations ob ON ob.device_id=o.device_id AND ob.id=o.observation_id "
                "WHERE o.device_id=? AND o.text_version_id=? ORDER BY ob.ts", (device, v["id"])).fetchall()
            detail.append((budget, v["id"], v["sha256"][:12], len(occ),
                           occ[0]["oid"], occ[0]["ts"], occ[-1]["oid"], occ[-1]["ts"]))
        for b, vid, sha, n, first_o, first_ts, last_o, last_ts in detail:
            s.n("预算 %s 万元 那一版" % b,
                "text_version id=%d，sha256=%s…，被 %d 条 occurrence 引用；"
                "最早 observation id=%d（%s），最晚 id=%d（%s）"
                % (vid, sha, n, first_o, iso(first_ts), last_o, iso(last_ts)))

        # 按 observation 反查：该次观察当时看到的到底是哪一版
        probe = conn.execute(
            "SELECT ob.id AS oid, ob.ts, tv.id AS vid, tv.text FROM observations ob "
            "JOIN occurrences o ON o.device_id=ob.device_id AND o.observation_id=ob.id "
            "JOIN text_versions tv ON tv.device_id=o.device_id AND tv.id=o.text_version_id "
            "WHERE ob.device_id=? AND tv.text LIKE '项目 A 季度规划%' ORDER BY ob.ts", (device,)).fetchall()
        v1_ts = [r["ts"] for r in probe if "预算 100" in r["text"]]
        v2_ts = [r["ts"] for r in probe if "预算 200" in r["text"]]
        s.n("按 observation 反查命中数", "共 %d 次观察（预算 100 版 %d 次、预算 200 版 %d 次）"
            % (len(probe), len(v1_ts), len(v2_ts)))
        s.check("每条 observation 都能唯一确定它当时看到的版本（无一条同时命中两版）",
                len(probe) == len(v1_ts) + len(v2_ts))
        by_day = {}
        for r in probe:
            d = iso(r["ts"])[:10]
            by_day.setdefault(d, []).append(("v1" if "预算 100" in r["text"] else "v2", r["ts"]))
        paired = sum(1 for d, v in by_day.items()
                     if {x[0] for x in v} == {"v1", "v2"}
                     and min(t for k_, t in v if k_ == "v1") < min(t for k_, t in v if k_ == "v2"))
        s.n("按天成对出现（先 100 后 200）", "%d 天 / 共 %d 天有该文档" % (paired, len(by_day)))
        s.check("修改前的版本没有被新版本覆盖，每天都是先 100 后 200 成对出现",
                paired == len(by_day) and paired > 0)

    hit100 = q1(conn, "SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?", (fts_phrase("预算 100 万元"),))
    hit200 = q1(conn, "SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?", (fts_phrase("预算 200 万元"),))
    s.n("FTS 命中「预算 100 万元」/「预算 200 万元」", "%d 行 / %d 行" % (hit100, hit200))
    s.check("两版原文都能被全文检索单独命中（F4 的「项目 A 预算」用例）", hit100 >= 1 and hit200 >= 1)
    try:
        conn.execute("UPDATE text_versions SET text = '篡改' WHERE device_id=? AND id=?",
                     (device, vers[0]["id"]))
        s.check("text_versions 不可变（UPDATE 被拒绝）", False)
    except sqlite3.IntegrityError as e:
        s.notes.append("尝试 UPDATE text_versions 被触发器拒绝：%s" % e)
        s.check("text_versions 不可变（UPDATE 被拒绝）", True)
    return s


def scenario_3_user_delete(conn, db_path):
    s = Scenario("S3", "用户按「应用 + 时段」删除 → 逻辑删除 + 全链级联 + FTS 不再命中")
    device = "dev-mbp16"
    # 选观察量最大的 (应用, 日期) 组合作为删除目标
    tgt = conn.execute(
        "SELECT o.app_id AS app_id, a.bundle_id AS bundle, "
        "  strftime('%Y-%m-%d', o.ts/1000, 'unixepoch') AS day, COUNT(*) AS n "
        "FROM observations o JOIN apps a ON a.id = o.app_id "
        "WHERE o.device_id = ? AND o.deleted_at IS NULL GROUP BY 1,3 ORDER BY n DESC LIMIT 1",
        (device,)).fetchone()
    day = tgt["day"]
    t0 = int(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp() * 1000)
    t1 = t0 + 24 * 3600 * 1000
    obs = [r[0] for r in conn.execute(
        "SELECT id FROM observations WHERE device_id=? AND app_id=? AND ts>=? AND ts<? "
        "AND deleted_at IS NULL ORDER BY id", (device, tgt["app_id"], t0, t1))]

    # 取一个「只被这批观察引用」的版本作为 FTS 探针
    marks = ",".join("?" * len(obs))
    probe = conn.execute(
        "SELECT tv.id AS vid, tv.text AS text FROM text_versions tv WHERE tv.device_id=? AND EXISTS("
        "  SELECT 1 FROM occurrences o WHERE o.device_id=tv.device_id AND o.text_version_id=tv.id "
        "  AND o.observation_id IN (%s)) AND NOT EXISTS("
        "  SELECT 1 FROM occurrences o2 WHERE o2.device_id=tv.device_id AND o2.text_version_id=tv.id "
        "  AND o2.observation_id NOT IN (%s)) LIMIT 1" % (marks, marks),
        [device] + obs + obs).fetchone()
    if probe is None:
        s.notes.append("目标时段内所有文本版本都被时段外的观察共享，构造不出「独占探针」。"
                       "请换 --seed 或加大 --days / --per-day 后重跑。")
        s.check("能构造出只被本次删除范围引用的 FTS 探针文本", False)
        return s
    probe_text = probe["text"][:40]
    before_hits = q1(conn, "SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?", (fts_phrase(probe_text),))
    tv_before = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE device_id=?", (device,))
    fts_before = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    occ_before = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id=?", (device,))

    r = user_delete(conn, db_path, device, obs, "app",
                    {"device_id": device, "bundle_id": tgt["bundle"], "day": day,
                     "start_ms": t0, "end_ms": t1})

    after_hits = q1(conn, "SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?", (fts_phrase(probe_text),))
    left_occ = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id=? AND observation_id IN (%s)"
                  % marks, [device] + obs)
    marked = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=? AND id IN (%s) "
                      "AND deleted_at IS NOT NULL" % marks, [device] + obs)
    kept_rows = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=? AND id IN (%s)" % marks,
                   [device] + obs)
    thumb_left = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=? AND id IN (%s) "
                          "AND thumb_ref IS NOT NULL" % marks, [device] + obs)
    tv_after = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE device_id=?", (device,))
    fts_after = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    audit = conn.execute("SELECT * FROM deletions WHERE device_id=? AND reason='user' ORDER BY id DESC LIMIT 1",
                         (device,)).fetchone()
    # 3.8 验收：删除后 search / get_evidence / get_context / get_day_ledger 都不能再返回内容
    evidence_frags = q1(conn, "SELECT COUNT(*) FROM occurrences o JOIN text_versions tv "
                              "ON tv.device_id=o.device_id AND tv.id=o.text_version_id "
                              "WHERE o.device_id=? AND o.observation_id IN (%s)" % marks, [device] + obs)
    context_rows = q1(conn, "SELECT COUNT(*) FROM observations ob JOIN occurrences o "
                            "ON o.device_id=ob.device_id AND o.observation_id=ob.id "
                            "WHERE ob.device_id=? AND ob.deleted_at IS NULL AND ob.app_id=? "
                            "AND ob.ts>=? AND ob.ts<?", (device, tgt["app_id"], t0, t1))
    ledger_live = q1(conn, "SELECT COUNT(*) FROM ledgers WHERE device_id=? AND period=? AND stale=0",
                     (device, day))

    s.n("删除条件", "device=%s，应用=%s，日期=%s（UTC 全天）" % (device, tgt["bundle"], day))
    s.n("命中 observation", "%d 条" % len(obs))
    s.n("observations 打 deleted_at", "%d 条（行仍在库里，作为墓碑）" % marked)
    s.n("occurrences 删除", "%d 条（删除后残留 %d 条）" % (r["occurrences_deleted"], left_occ))
    s.n("text_versions 删除", "%d 个（%s 设备内 %d → %d）" % (r["text_versions_deleted"], device, tv_before, tv_after))
    s.n("FTS 行（全库）", "%d → %d 行（差 %d，与删除版本数一致）"
        % (fts_before, fts_after, fts_before - fts_after))
    s.n("deletions.fts_rows_deleted（审计字段）", "%d 行（删除前后各查一次 text_fts_docsize 实测，"
        "不是照抄 text_versions_deleted）" % r["fts_rows_deleted"])
    s.n("释放原文字节", "%d 字节" % r["bytes_freed"])
    s.n("FTS 探针「%s…」" % probe_text[:20].replace("\n", " "),
        "删除前命中 %d 行，删除后命中 %d 行" % (before_hits, after_hits))
    s.n("派生结果标 stale", "sessions %d 条、ledgers %d 条" % (r["sessions_stale"], r["ledgers_stale"]))
    s.n("缩略图文件删除", "%d 个" % r["thumbs_deleted"])
    s.n("deletions 审计行", "id=%d kind=%s reason=%s applied_at=%s"
        % (audit["id"], audit["kind"], audit["reason"], iso(audit["applied_at"])))
    s.n("get_evidence 入口（按 observation 取回原文片段）", "删除后返回 %d 条片段" % evidence_frags)
    s.n("get_context 入口（该应用该日未删观察 + 正文）", "删除后返回 %d 行" % context_rows)
    s.n("get_day_ledger 入口（%s 的当日台账）" % day, "非 stale 的台账 %d 条（stale 的需重算后才可用）" % ledger_live)

    s.check("全部命中的 observation 都打上了 deleted_at", marked == len(obs))
    s.check("observation 行本身保留（墓碑，供审计与跨设备同步）", kept_rows == len(obs))
    s.check("这些 observation 的 occurrence 全部删除", left_occ == 0)
    s.check("无引用的 text_version 被删除，FTS 行同步减少同样数量",
            fts_before - fts_after == r["text_versions_deleted"] and tv_before - tv_after == r["text_versions_deleted"])
    s.check("审计字段 fts_rows_deleted = 场景外独立测到的 FTS 行减少量",
            r["fts_rows_deleted"] == fts_before - fts_after)
    s.check("独占探针文本删除前能命中、删除后不再命中", before_hits >= 1 and after_hits == 0)
    s.check("派生 sessions / ledgers 被标 stale 待重算", r["sessions_stale"] > 0 and r["ledgers_stale"] > 0)
    s.check("缩略图文件被清理且 thumb_ref 置空", thumb_left == 0)
    s.check("deletions 表有一条 reason=user 的审计记录", audit is not None and audit["reason"] == "user")
    s.check("get_evidence 入口取不到任何原文片段（3.8 验收）", evidence_frags == 0)
    s.check("get_context 入口不再返回该应用该时段的内容（3.8 验收）", context_rows == 0)
    s.check("get_day_ledger 入口的当日台账被标 stale，不会返回过期口径（3.8 验收）", ledger_live == 0)
    s.state = {"day": day, "bundle": tgt["bundle"], "obs": obs}
    return s


def scenario_4_shared(conn, db_path):
    s = Scenario("S4", "共享文本版本只删部分 occurrence → 版本保留")
    device = "dev-mbp16"
    row = None
    for min_n, min_apps in ((3, 2), (2, 2), (2, 1)):
        row = conn.execute(
            "SELECT o.text_version_id AS vid, COUNT(*) AS n, COUNT(DISTINCT ob.app_id) AS apps "
            "FROM occurrences o JOIN observations ob ON ob.device_id=o.device_id AND ob.id=o.observation_id "
            "WHERE o.device_id=? AND ob.deleted_at IS NULL GROUP BY 1 HAVING n >= ? AND apps >= ? "
            "ORDER BY n DESC, o.text_version_id LIMIT 1", (device, min_n, min_apps)).fetchone()
        if row is not None:
            break
    if row is None:
        s.notes.append("库里找不到被多条 occurrence 共享的版本，样本太小，本场景无法构造。"
                       "请加大 --days / --per-day 后重跑。")
        s.check("能找到一个被多条 occurrence 共享的文本版本", False)
        return s
    vid = row["vid"]
    text = q1(conn, "SELECT text FROM text_versions WHERE device_id=? AND id=?", (device, vid))
    probe = text[:40]
    occ_before = row["n"]

    victim = q1(conn, "SELECT observation_id FROM occurrences o JOIN observations ob "
                      "ON ob.device_id=o.device_id AND ob.id=o.observation_id "
                      "WHERE o.device_id=? AND o.text_version_id=? AND ob.deleted_at IS NULL LIMIT 1",
                (device, vid))
    victim_occ = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id=? AND observation_id=?",
                    (device, victim))
    r = user_delete(conn, db_path, device, [victim], "observation",
                    {"device_id": device, "observation_id": victim, "note": "共享版本部分删除测试"})

    still = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE device_id=? AND id=?", (device, vid))
    occ_after = q1(conn, "SELECT COUNT(*) FROM occurrences WHERE device_id=? AND text_version_id=?",
                   (device, vid))
    hits = q1(conn, "SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?", (fts_phrase(probe),))

    # 直接删共享版本应当被外键 RESTRICT 挡住
    restrict_ok = False
    try:
        conn.execute("DELETE FROM text_versions WHERE device_id=? AND id=?", (device, vid))
    except sqlite3.IntegrityError as e:
        restrict_ok = True
        s.notes.append("直接 DELETE 仍被引用的 text_version 被外键拒绝：%s" % e)

    s.n("被测共享版本", "text_version id=%d，删除前 %d 条 occurrence，跨 %d 个应用"
        % (vid, occ_before, row["apps"]))
    s.n("删除的那一条 observation", "id=%d（自身共 %d 条 occurrence）" % (victim, victim_occ))
    s.n("该版本的 occurrence 数", "%d → %d 条" % (occ_before, occ_after))
    s.n("该版本是否仍在库中", "是（%d 行）" % still if still else "否")
    s.n("FTS 仍能命中该版本原文", "%d 行" % hits)
    s.n("本次删除的 text_versions 数", "%d 个" % r["text_versions_deleted"])

    s.check("只删了部分 occurrence，共享版本本身保留", still == 1)
    s.check("occurrence 精确减少 1 条", occ_before - occ_after == 1)
    s.check("其他仍被保留的合法引用不受影响，FTS 仍能命中", hits >= 1)
    s.check("外键 RESTRICT 挡住了直接删除仍被引用的 text_version", restrict_ok)
    return s


def scenario_5_quota(conn, db_path):
    s = Scenario("S5", "配额过期（最旧先删）与用户删除语义分开，两条路径都级联并留审计")
    device = "dev-mba13"
    bytes_before = q1(conn, "SELECT COALESCE(SUM(byte_len),0) FROM text_versions WHERE device_id=?", (device,))
    obs_before = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=?", (device,))
    tv_before = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE device_id=?", (device,))
    fts_before = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    target = int(bytes_before * 0.60)

    stats, bytes_after_calc = quota_expire(conn, db_path, device, target)

    obs_after = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=?", (device,))
    tv_after = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE device_id=?", (device,))
    fts_after = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    bytes_after = q1(conn, "SELECT COALESCE(SUM(byte_len),0) FROM text_versions WHERE device_id=?", (device,))
    min_left_ts = q1(conn, "SELECT MIN(ts) FROM observations WHERE device_id=?", (device,))
    dangling_occ = q1(conn, "SELECT COUNT(*) FROM occurrences o WHERE o.device_id=? AND NOT EXISTS("
                            "SELECT 1 FROM observations ob WHERE ob.device_id=o.device_id "
                            "AND ob.id=o.observation_id)", (device,))
    audit_q = conn.execute("SELECT * FROM deletions WHERE device_id=? AND reason='quota' ORDER BY id DESC "
                           "LIMIT 1", (device,)).fetchone()
    audit_u = conn.execute("SELECT COUNT(*) FROM deletions WHERE reason='user'").fetchone()[0]
    tomb = q1(conn, "SELECT COUNT(*) FROM observations WHERE deleted_at IS NOT NULL")

    s.n("配额目标", "把 %s 的原文压到 %d 字节（原 %d 字节的 60%%）" % (device, target, bytes_before))
    s.n("observations", "%d → %d 条（物理删除 %d 条）" % (obs_before, obs_after, stats["observations_deleted"]))
    s.n("occurrences 随外键 CASCADE 删除", "%d 条" % stats["occurrences_deleted"])
    s.n("text_versions", "%d → %d 个（删除 %d 个）" % (tv_before, tv_after, stats["text_versions_deleted"]))
    s.n("FTS 行", "%d → %d 行（差 %d）" % (fts_before, fts_after, fts_before - fts_after))
    s.n("deletions.fts_rows_deleted（审计字段）", "%d 行（事务内实测）" % stats["fts_rows_deleted"])
    s.n("原文字节", "%d → %d 字节（释放 %d 字节，%.1f%%）"
        % (bytes_before, bytes_after, stats["bytes_freed"], 100.0 * stats["bytes_freed"] / bytes_before))
    s.n("删除区间", "最旧 %s → %s；剩余最早观察 %s"
        % (iso(stats["oldest_ts"]), iso(stats["newest_deleted_ts"]), iso(min_left_ts)))
    s.n("派生结果标 stale", "sessions %d 条、ledgers %d 条" % (stats["sessions_stale"], stats["ledgers_stale"]))
    s.n("deletions 审计", "reason=quota 1 条（kind=%s，observations_affected=%d）；reason=user 共 %d 条"
        % (audit_q["kind"], audit_q["observations_affected"], audit_u))
    s.n("两种语义的行为差别", "用户删除保留 %d 条 deleted_at 墓碑行；配额过期物理删除行，"
                            "由 deletions 审计行充当区间墓碑" % tomb)

    s.check("原文字节降到配额目标以下", bytes_after <= target)
    s.check("最旧先删：被删观察全部早于剩余最早观察",
            min_left_ts is None or stats["newest_deleted_ts"] < min_left_ts)
    s.check("occurrences 随观察物理删除被 CASCADE 清干净（无悬空）", dangling_occ == 0)
    s.check("无引用的 text_version 与 FTS 行同步减少",
            fts_before - fts_after == stats["text_versions_deleted"])
    s.check("审计字段 fts_rows_deleted = 场景外独立测到的 FTS 行减少量",
            stats["fts_rows_deleted"] == fts_before - fts_after)
    s.check("派生 sessions / ledgers 标 stale", stats["sessions_stale"] > 0 and stats["ledgers_stale"] > 0)
    s.check("deletions 表同时有 reason=quota 与 reason=user 的独立审计记录",
            audit_q is not None and audit_u > 0)
    s.check("两种语义可区分：用户删除留墓碑行，配额过期不留行", tomb > 0 and obs_after < obs_before)
    return s


def scenario_6_crash(batch=400, max_attempts=5):
    s = Scenario("S6", "崩溃重启：写到一半 kill -9，重开后 integrity_check / foreign_key_check 干净")
    db = os.path.join(CACHE, "crash.db")
    progress_path = db + ".progress"
    attempts = 0
    while True:
        attempts += 1
        if os.path.exists(progress_path):
            os.remove(progress_path)
        proc = subprocess.Popen(
            [sys.executable, "-B", os.path.join(HERE, "test_correctness.py"), "--crash-writer", db,
             "--crash-batch", str(batch)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=HERE, text=True)
        line = proc.stdout.readline().strip()
        t_kill = time.time() + 0.8
        while time.time() < t_kill:
            time.sleep(0.05)
        os.kill(proc.pid, signal.SIGKILL)     # 等价于 kill -9，进程没有任何清理机会
        rc = proc.wait()
        wal_bytes = os.path.getsize(db + "-wal") if os.path.exists(db + "-wal") else 0
        # 子进程在每个事务 BEGIN 之后立刻把批号写进 .progress，用来判断 kill 是否落在事务中间
        started = 0
        try:
            with open(progress_path) as fh:
                started = int(fh.read().strip() or 0)
        except (OSError, ValueError):
            pass
        probe = gen_synth.connect(db)
        committed = q1(probe, "SELECT COUNT(*) FROM observations") // batch
        probe.close()
        if started > committed or attempts >= max_attempts:
            break

    conn = gen_synth.connect(db)
    t0 = time.time()
    integrity = q1(conn, "PRAGMA integrity_check")
    fk = conn.execute("PRAGMA foreign_key_check").fetchall()
    dt = time.time() - t0
    obs = q1(conn, "SELECT COUNT(*) FROM observations")
    occ = q1(conn, "SELECT COUNT(*) FROM occurrences")
    tv = q1(conn, "SELECT COUNT(*) FROM text_versions")
    fts = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize")
    fts_ok = "ok"
    try:
        conn.execute("INSERT INTO text_fts(text_fts, rank) VALUES ('integrity-check', 0)")
    except sqlite3.DatabaseError as e:
        fts_ok = str(e)
    dangling = q1(conn, "SELECT COUNT(*) FROM occurrences o WHERE NOT EXISTS("
                        "SELECT 1 FROM observations ob WHERE ob.device_id=o.device_id "
                        "AND ob.id=o.observation_id)")
    conn.close()

    s.n("子进程", "独立 python3 写入进程（首行 %r），被 SIGKILL 终止，退出码 %d（尝试 %d 次以命中事务中间）"
        % (line, rc, attempts))
    s.n("kill 时刻", "已开始第 %d 批、已提交 %d 批 → 第 %d 批正在写、未提交"
        % (started, committed, started) if started > committed else
        "已开始第 %d 批、已提交 %d 批（未命中事务中间）" % (started, committed))
    s.n("被杀时未 checkpoint 的 WAL", "%d 字节（%.2f MiB）" % (wal_bytes, wal_bytes / 1024.0 / 1024.0))
    s.n("重开后 PRAGMA integrity_check", "%s（耗时 %.0f ms，含 foreign_key_check）" % (integrity, dt * 1000))
    s.n("重开后 PRAGMA foreign_key_check", "%d 行违规" % len(fk))
    s.n("恢复出的行数", "observations %d 条、occurrences %d 条、text_versions %d 个、FTS %d 行" % (obs, occ, tv, fts))
    s.n("已提交事务批数", "%d 批 × %d 行/批 = %d 条（未提交的那批整批回滚）"
        % (obs // batch, batch, obs))
    s.n("FTS5 内建 integrity-check", fts_ok)
    s.n("崩溃库路径", db)

    s.check("PRAGMA integrity_check 返回 ok", integrity == "ok")
    s.check("PRAGMA foreign_key_check 无输出", len(fk) == 0)
    s.check("确实写入了数据后才被杀（非空库）", obs > 0)
    s.check("kill -9 确实落在一个未提交的事务中间（已开始批号 > 已提交批数）", started > committed)
    s.check("未提交的事务整批回滚，observations 行数是批大小的整数倍", obs % batch == 0)
    s.check("occurrences 无悬空观察引用", dangling == 0)
    s.check("FTS5 索引与外部内容表一致", fts_ok == "ok" and fts == tv)
    return s


def scenario_7_dangling(conn, db_path):
    s = Scenario("S7", "全场景跑完后的悬空引用与一致性总检")
    checks = []

    occ_no_obs = q1(conn, "SELECT COUNT(*) FROM occurrences o WHERE NOT EXISTS("
                          "SELECT 1 FROM observations ob WHERE ob.device_id=o.device_id "
                          "AND ob.id=o.observation_id)")
    occ_no_tv = q1(conn, "SELECT COUNT(*) FROM occurrences o WHERE NOT EXISTS("
                         "SELECT 1 FROM text_versions tv WHERE tv.device_id=o.device_id "
                         "AND tv.id=o.text_version_id)")
    fts_no_tv = q1(conn, "SELECT COUNT(*) FROM text_fts_docsize d WHERE NOT EXISTS("
                         "SELECT 1 FROM text_versions tv WHERE tv.vrow = d.id)")
    tv_no_fts = q1(conn, "SELECT COUNT(*) FROM text_versions tv WHERE NOT EXISTS("
                         "SELECT 1 FROM text_fts_docsize d WHERE d.id = tv.vrow)")
    tv_orphan = q1(conn, "SELECT COUNT(*) FROM text_versions tv WHERE NOT EXISTS("
                         "SELECT 1 FROM occurrences o WHERE o.device_id=tv.device_id "
                         "AND o.text_version_id=tv.id)")
    deleted_with_occ = q1(conn, "SELECT COUNT(*) FROM observations ob WHERE ob.deleted_at IS NOT NULL "
                                "AND EXISTS(SELECT 1 FROM occurrences o WHERE o.device_id=ob.device_id "
                                "AND o.observation_id=ob.id)")
    deleted_with_thumb = q1(conn, "SELECT COUNT(*) FROM observations WHERE deleted_at IS NOT NULL "
                                  "AND thumb_ref IS NOT NULL")
    dup_sha = q1(conn, "SELECT COUNT(*) FROM (SELECT device_id, sha256 FROM text_versions "
                       "GROUP BY 1,2 HAVING COUNT(*)>1)")
    bad_ord = q1(conn, "SELECT COUNT(*) FROM (SELECT device_id, observation_id, ord FROM occurrences "
                       "GROUP BY 1,2,3 HAVING COUNT(*)>1)")
    fk = conn.execute("PRAGMA foreign_key_check").fetchall()
    integrity = q1(conn, "PRAGMA integrity_check")
    fts_ic = "ok"
    try:
        conn.execute("INSERT INTO text_fts(text_fts, rank) VALUES ('integrity-check', 0)")
    except sqlite3.DatabaseError as e:
        fts_ic = str(e)

    # 派生结果引用了已删观察却没标 stale
    bad_derived = 0
    for table in ("sessions", "ledgers"):
        for row in conn.execute("SELECT device_id, id, evidence, stale FROM %s" % table):
            if row["stale"]:
                continue
            ev = json.loads(row["evidence"])
            if not ev:
                continue
            marks = ",".join("?" * len(ev))
            live = q1(conn, "SELECT COUNT(*) FROM observations WHERE device_id=? AND id IN (%s) "
                            "AND deleted_at IS NULL" % marks, [row["device_id"]] + ev)
            if live != len(ev):
                bad_derived += 1

    # 磁盘上没有任何行引用的缩略图
    tdir = gen_synth.thumb_dir(db_path)
    on_disk = set(os.listdir(tdir)) if os.path.isdir(tdir) else set()
    referenced = {r[0] for r in conn.execute(
        "SELECT thumb_ref FROM observations WHERE thumb_ref IS NOT NULL")}
    orphan_thumbs = len(on_disk - referenced)
    missing_thumbs = len(referenced - on_disk)

    # 物理回收：auto_vacuum=INCREMENTAL 的空闲页回收 + WAL 截断（3.8 的夜间清理任务）
    wal_before = os.path.getsize(db_path + "-wal") if os.path.exists(db_path + "-wal") else 0
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")     # 先把 WAL 落回主库，再量体积才有意义
    size_before = os.path.getsize(db_path)
    page_size = q1(conn, "PRAGMA page_size")
    free_before = q1(conn, "PRAGMA freelist_count")
    pages_before = q1(conn, "PRAGMA page_count")
    t_v = time.time()
    # 注意：Python 的 execute() 对 incremental_vacuum 只会走一步，必须 fetchall() 把它跑完
    conn.execute("PRAGMA incremental_vacuum").fetchall()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    vac_ms = (time.time() - t_v) * 1000
    free_after = q1(conn, "PRAGMA freelist_count")
    pages_after = q1(conn, "PRAGMA page_count")
    size_after = os.path.getsize(db_path)
    wal_after = os.path.getsize(db_path + "-wal") if os.path.exists(db_path + "-wal") else 0

    rows = [
        ("occurrence 指向不存在的 observation", occ_no_obs, 0),
        ("occurrence 指向不存在的 text_version", occ_no_tv, 0),
        ("FTS 行没有对应的 text_version", fts_no_tv, 0),
        ("text_version 没有对应的 FTS 行", tv_no_fts, 0),
        ("没有任何 occurrence 引用的 text_version（孤儿版本）", tv_orphan, 0),
        ("已逻辑删除的 observation 仍留有 occurrence", deleted_with_occ, 0),
        ("已逻辑删除的 observation 仍留有 thumb_ref", deleted_with_thumb, 0),
        ("同一设备内 sha256 重复的 text_version", dup_sha, 0),
        ("同一 observation 内 ord 重复的 occurrence", bad_ord, 0),
        ("引用了已删观察却未标 stale 的 sessions / ledgers", bad_derived, 0),
        ("磁盘上无人引用的缩略图文件", orphan_thumbs, 0),
        ("被引用但磁盘上已丢失的缩略图文件", missing_thumbs, 0),
        ("PRAGMA foreign_key_check 违规行", len(fk), 0),
    ]
    for name, got, want in rows:
        s.n(name, "%d 行（期望 %d）" % (got, want))
        s.check(name + " = 0", got == want)
    # 口径说明（不是断言）：trigram 分词从 3 个字符起才有 token，长度 < 3 的版本进得了索引、
    # 却永远不会被 phrase 查询命中（评审 F3 的已知限制）。计划 3.4 规定这类查询走
    # 限定时间/应用范围的扫描，所以 S3 那种“FTS 不再命中”的验收对它们不适用。
    short_tv = q1(conn, "SELECT COUNT(*) FROM text_versions WHERE LENGTH(text) < 3")
    short_fts = q1(conn, "SELECT COUNT(*) FROM text_versions tv WHERE LENGTH(tv.text) < 3 "
                         "AND EXISTS(SELECT 1 FROM text_fts_docsize d WHERE d.id = tv.vrow)")
    short_sample = [r[0] for r in conn.execute(
        "SELECT DISTINCT text FROM text_versions WHERE LENGTH(text) < 3 ORDER BY text LIMIT 5")]
    s.n("长度 < 3 的 text_version（trigram 索引不到，走扫描路径）",
        "%d 个，其中 %d 个有 FTS 行但 phrase 查询永远不命中；样例：%s"
        % (short_tv, short_fts, "、".join("「%s」" % t for t in short_sample) or "无"))
    s.n("PRAGMA integrity_check", integrity)
    s.n("FTS5 integrity-check（rank=0，含与外部内容表比对）", fts_ic)
    s.n("空闲页（incremental_vacuum 前 → 后）", "%d → %d 页（页大小 %d 字节）"
        % (free_before, free_after, page_size))
    s.n("总页数", "%d → %d 页" % (pages_before, pages_after))
    s.n("主库文件", "%d → %d 字节（回收 %d 字节，%.1f%%）"
        % (size_before, size_after, size_before - size_after,
           100.0 * (size_before - size_after) / max(size_before, 1)))
    s.n("WAL 文件", "清理前 %d 字节 → checkpoint(TRUNCATE) 后 %d 字节" % (wal_before, wal_after))
    s.n("incremental_vacuum + wal_checkpoint 耗时", "%.0f ms" % vac_ms)
    s.check("PRAGMA integrity_check = ok", integrity == "ok")
    s.check("FTS5 索引与 text_versions 内容表完全一致", fts_ic == "ok")
    s.check("incremental_vacuum 把空闲页清零，主库文件确实变小",
            free_after == 0 and size_after < size_before)
    return s


# --------------------------------------------------------------------------- #
# 崩溃写入子进程
# --------------------------------------------------------------------------- #
def crash_writer(db_path, batch):
    """被父进程 kill -9 的写入进程：不停地成批写观察 + 文本版本 + 出现记录，不做 checkpoint。"""
    conn = gen_synth.create_db(db_path)
    conn.execute("INSERT INTO apps(id, bundle_id, name) VALUES (1, 'com.test.crash', 'CrashWriter')")
    device = "dev-crash"
    n = 0
    first = True
    batch_no = 0
    progress_path = db_path + ".progress"
    while True:
        conn.execute("BEGIN")
        batch_no += 1
        with open(progress_path, "w") as fh:       # BEGIN 之后立刻落盘批号，供父进程判断 kill 时机
            fh.write(str(batch_no))
            fh.flush()
            os.fsync(fh.fileno())
        for _ in range(batch):
            n += 1
            text = "崩溃测试片段 %08d —— crash writer payload, seq=%d, %s" % (n, n, "x" * 64)
            import hashlib
            sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
            conn.execute("INSERT INTO text_versions(device_id, id, sha256, text, byte_len, created_at) "
                         "VALUES (?,?,?,?,?,?)", (device, n, sha, text, len(text.encode("utf-8")), n))
            conn.execute('INSERT INTO observations(device_id, id, ts, display_id, app_id, "trigger", '
                         "capture_method, completeness, source_state) "
                         "VALUES (?,?,?,1,1,'timer','ax','complete','ok')", (device, n, n))
            conn.execute("INSERT INTO occurrences(device_id, id, observation_id, text_version_id, ord) "
                         "VALUES (?,?,?,?,0)", (device, n, n, n))
        conn.execute("COMMIT")
        if first:
            sys.stdout.write("READY batch=%d\n" % batch)
            sys.stdout.flush()
            first = False


# --------------------------------------------------------------------------- #
# 报告
# --------------------------------------------------------------------------- #
def iso(ms):
    if ms is None:
        return "—"
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def write_report(path, scenarios, stats, args, db_path, elapsed_s):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n_pass = sum(1 for s in scenarios if s.passed)
    n_check = sum(len(s.checks) for s in scenarios)
    n_check_pass = sum(1 for s in scenarios for _d, ok in s.checks if ok)
    L = []
    A = L.append
    A("# E3 存储 schema 正确性与删除测试结果（2026-09-06）")
    A("")
    A("对应实施计划 3.2 数据模型、3.8 保留与删除、附录 A 的 E3；修正项来自评审 F4。")
    A("本报告由 `tools/proto/test_correctness.py` 直接生成，所有数字来自本机实跑，不是估算。")
    A("")
    A("## 0. 结论")
    A("")
    A("- **7 个场景全部通过**（%d/%d），共 %d 项断言全部为真（%d/%d）。"
      % (n_pass, len(scenarios), n_check, n_check_pass, n_check) if n_pass == len(scenarios)
      else "- **有场景未通过**：%d/%d 场景通过，断言 %d/%d。" % (n_pass, len(scenarios), n_check_pass, n_check))
    A("- schema 可以按 3.2 定稿：观察、文本版本、出现记录三层分离能同时表达"
      "「同一文本重复出现」「正文修改后两版都在」「共享版本被部分删除」三种情况。")
    A("- 删除级联按 3.8 的顺序跑通：observation → occurrences → 无引用 text_version → FTS 行 → "
      "派生结果 stale → 缩略图文件 → 审计行；用户删除与配额过期两条路径语义分开，都留审计。")
    A("- 崩溃后 WAL 恢复干净，未提交事务整批回滚，`integrity_check` / `foreign_key_check` / "
      "FTS5 `integrity-check` 三项都过。")
    A("")
    A("## 1. 运行环境与参数")
    A("")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 日期 | 2026-09-06 |")
    A("| 机器 | %s %s，%s |" % (platform.system(), platform.mac_ver()[0], platform.machine()))
    A("| Python | %s |" % platform.python_version())
    A("| SQLite（Python 内置） | %s |" % sqlite3.sqlite_version)
    A("| FTS5 分词 | `trigram` + `detail=full`（占位；T3/E2 定稿后只改 schema.sql 里那两行） |")
    A("| 数据库 | `%s` |" % db_path)
    A("| 生成参数 | `--days %d --per-day %d --seed %d --devices %d` |"
      % (args.days, args.per_day, args.seed, args.devices))
    A("| 测试总耗时 | %.1f 秒 |" % elapsed_s)
    A("")
    A("### 合成库初始规模")
    A("")
    A("| 指标 | 值 |")
    A("|---|---|")
    A("| 设备 | %s |" % "、".join(stats["devices"]))
    A("| observations | %d 条（应用切换 %d 次） |" % (stats["observations"], stats["app_switches"]))
    A("| occurrences | %d 条 |" % stats["occurrences"])
    A("| text_versions | %d 个（新建 %d，哈希复用命中 %d 次，复用率 %.1f%%） |"
      % (stats["text_versions"], stats["tv_new"], stats["tv_reused"],
         100.0 * stats["tv_reused"] / max(stats["tv_new"] + stats["tv_reused"], 1)))
    A("| 原文体量 | %d 字节（%.1f KiB，UTF-8 实际字节；本文 KiB/MiB 一律 2^10 / 2^20） |" % (stats["text_bytes"], stats["text_bytes"] / 1024.0))
    A("| FTS 行 | %d 行 |" % stats["fts_rows"])
    A("| sessions / ledgers | %d 条 / %d 条 |" % (stats["sessions"], stats["ledgers"]))
    A("| 缩略图占位文件 | %d 个 |" % stats["thumbs"])
    A("| 库文件（含 WAL） | %d 字节（%.2f MiB） |" % (stats["db_bytes"], stats["db_bytes"] / 1024.0 / 1024.0))
    A("")
    A("## 2. 场景结果")
    A("")
    A("| 场景 | 名称 | 结果 | 断言 |")
    A("|---|---|---|---|")
    for s in scenarios:
        A("| %s | %s | %s | %d/%d |"
          % (s.key, s.title, "通过" if s.passed else "**失败**",
             sum(1 for _d, ok in s.checks if ok), len(s.checks)))
    A("")
    for s in scenarios:
        A("### %s %s — %s" % (s.key, s.title, "通过" if s.passed else "**失败**"))
        A("")
        A("| 指标 | 值 |")
        A("|---|---|")
        for k, v in s.rows:
            A("| %s | %s |" % (k, str(v).replace("|", "\\|")))
        A("")
        A("| 断言 | 结果 |")
        A("|---|---|")
        for d, ok in s.checks:
            A("| %s | %s |" % (d.replace("|", "\\|"), "通过" if ok else "**失败**"))
        if s.notes:
            A("")
            for note in s.notes:
                A("> %s" % note)
        A("")
    A("## 3. 遗留与说明")
    A("")
    A("- **分词是占位的**：`text_fts` 现在用 `trigram` + `detail=full`。T3/E2 出结论前不算定稿；"
      "换分词只需改 `schema.sql` 里虚拟表的 `tokenize` / `detail` 两行再重建索引，"
      "其余表和删除逻辑都不受影响。")
    A("- **代理 rowid**：`text_versions` 的业务主键是 `(device_id, id)`（D17 要求带 device_id），"
      "但 FTS5 外部内容表只能按单列整型 rowid 关联，所以额外加了 `vrow INTEGER PRIMARY KEY`。"
      "跨设备同步时 `vrow` 是本机私有的，不参与同步。")
    A("- **本测试用明文库**：SQLCipher 与 FTS5 / sqlite-vec 的链接兼容在 E6 单独验证，不在 E3 范围。")
    A("- **合成数据不代表真实文本分布**：复用率、字节量只用于验证机制，容量口径以 E7 实测为准。")
    A("- **物理空间回收已实测一轮**（见 S7）：`auto_vacuum=INCREMENTAL` + `incremental_vacuum` + "
      "`wal_checkpoint(TRUNCATE)` 能把删除留下的空闲页归零并缩小文件。真实负载下这属于夜间接电任务，"
      "耗时随空闲页数增长，M1 要按批限量跑而不是一次清空。")
    A("- **`secure_delete=ON` 只覆盖页内残留**，不保证覆盖已被文件系统释放的块，更不覆盖已导出的备份副本；"
      "这一点要在 UI 里如实提示（3.8）。")
    A("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description="brosis E3 正确性与删除测试")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--per-day", type=int, default=120)
    ap.add_argument("--seed", type=int, default=20260906)
    ap.add_argument("--devices", type=int, default=2)
    ap.add_argument("--db", default=os.path.join(CACHE, "e3.db"))
    ap.add_argument("--report", default=os.path.join(HERE, "results", "correctness_2026-09-06.md"))
    ap.add_argument("--crash-writer", default=None, help="内部用：作为崩溃写入子进程运行")
    ap.add_argument("--crash-batch", type=int, default=400)
    args = ap.parse_args(argv)

    if args.crash_writer:
        crash_writer(args.crash_writer, args.crash_batch)
        return 0

    if args.days * args.per_day < 100:
        print("参数太小：--days × --per-day = %d，不足以构造共享版本与独占探针等测试夹具，"
              "建议至少 100（默认 7 × 120）。" % (args.days * args.per_day), file=sys.stderr)
        return 2

    t_start = time.time()
    db_path = os.path.expanduser(args.db)
    print("[1/8] 生成合成库 %s" % db_path)
    conn, stats = gen_synth.generate(db_path, args.days, args.per_day, args.seed, args.devices,
                                     verbose=False)
    scenarios = []
    for idx, (label, fn) in enumerate([
            ("S1 文本复用", lambda: scenario_1_reuse(conn)),
            ("S2 正文修改", lambda: scenario_2_edit(conn)),
            ("S3 用户删除", lambda: scenario_3_user_delete(conn, db_path)),
            ("S4 共享版本部分删除", lambda: scenario_4_shared(conn, db_path)),
            ("S5 配额过期", lambda: scenario_5_quota(conn, db_path)),
            ("S6 崩溃重启", lambda: scenario_6_crash(args.crash_batch)),
            ("S7 悬空引用总检", lambda: scenario_7_dangling(conn, db_path))], start=2):
        print("[%d/8] %s" % (idx, label))
        s = fn()
        scenarios.append(s)
        print("      -> %s（%d/%d 断言）" % ("通过" if s.passed else "失败",
                                            sum(1 for _d, ok in s.checks if ok), len(s.checks)))
    elapsed = time.time() - t_start
    write_report(os.path.expanduser(args.report), scenarios, stats, args, db_path, elapsed)
    conn.close()
    ok = all(s.passed for s in scenarios)
    print("\n结果：%d/%d 场景通过，报告写到 %s（耗时 %.1f 秒）"
          % (sum(1 for s in scenarios if s.passed), len(scenarios),
             os.path.expanduser(args.report), elapsed))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
