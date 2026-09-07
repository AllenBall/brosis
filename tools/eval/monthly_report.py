#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""月报：按字节分项报告存储，并折算成月增长对照 2.4 的目标与上限。

输入是一份 stats JSON，**两种来源都认**：
  1. `brosis-store stats --dir … --key-file … --detail` 的输出（扁平键 + `detail` 数组）；
  2. app 菜单「导出存储统计…」写出的 `stats-<日期>.json`（`app/README.md` 8.8：
     `schema_version` / `generated_by` / `device_id` / `exported_at` / `exported_at_ms` +
     `store` 对象（StoreStats 全字段 snake_case）+ `dbstat` 数组）。
解析是**按别名递归找键**的：认识的字段见 `FIELDS`，找不到就记进 `missing_fields`，
报告里那一行写「未提供」，不会因为少一个字段就崩。

口径（计划 2.4 / D21）：
  * **MiB = 2^20、GiB = 2^30**，报告每处都注明；
  * 分项：原文 / 索引（含全文索引）/ 元数据 / WAL / 临时 / 缩略图 / 模型资产；
  * 永久增长目标 **0.6 GiB/月**，上限 **1 GiB/月**；
  * 临时空间在本项目里恒为 0：D25 把 `SQLITE_TEMP_STORE` 编译成 3（强制内存），
    PRAGMA 改不回文件，所以没有明文溢出文件可量——除非你用 `--temp-dir` 指一个目录。

    PYTHONDONTWRITEBYTECODE=1 python3 monthly_report.py \
        --stats <scratch>/results/stats.json \
        --ledger-days <scratch>/results/ledger_days.json \
        --out-md <scratch>/results/monthly_report.md \
        --out-json <scratch>/results/monthly_report.json
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

MIB = 1 << 20
GIB = 1 << 30
TARGET_GIB_PER_MONTH = 0.6      # D21：E7 实测 0.567 GiB/月，目标定 0.6
LIMIT_GIB_PER_MONTH = 1.0       # 2.4 的上限

# 认识的字段 → 别名（按顺序找，第一个命中的算数）
FIELDS = {
    "db_file_bytes": ["db_file_bytes", "dbFileBytes", "database_bytes", "db_bytes"],
    "content_bytes": ["content_bytes", "contentBytes", "text_bytes"],
    "text_payload_bytes": ["text_payload_bytes", "textPayloadBytes", "payload_bytes"],
    "index_bytes": ["index_bytes", "indexBytes"],
    "fts_bytes": ["fts_bytes", "ftsBytes", "fulltext_bytes"],
    "metadata_bytes": ["metadata_bytes", "metadataBytes"],
    "free_bytes": ["free_bytes", "freeBytes", "freelist_bytes"],
    "wal_bytes": ["wal_bytes", "walBytes"],
    "shm_bytes": ["shm_bytes", "shmBytes"],
    "temp_bytes": ["temp_bytes", "tempBytes", "temp_store_bytes"],
    "thumbs_bytes": ["thumbs_bytes", "thumbsBytes", "thumbnail_bytes", "thumbnailBytes",
                     "thumbnails_bytes", "thumbnailsBytes"],
    "models_bytes": ["models_bytes", "modelsBytes", "model_assets_bytes", "modelAssetsBytes",
                     "model_bytes", "modelBytes"],
    "page_size": ["page_size", "pageSize"],
    "page_count": ["page_count", "pageCount"],
    "freelist_pages": ["freelist_pages", "freelistPages"],
    "observations": ["observations", "observation_count"],
    "live_observations": ["live_observations", "liveObservations"],
    "tombstoned_observations": ["tombstoned_observations", "tombstonedObservations"],
    "text_versions": ["text_versions", "textVersions"],
    "occurrences": ["occurrences", "occurrenceCount"],
    "fts_rows": ["fts_rows", "ftsRows"],
    "apps": ["apps", "app_count"],
    "deletions": ["deletions", "deletion_count"],
    "first_ts": ["first_ts", "firstTS", "start_ms", "startMS"],
    "last_ts": ["last_ts", "lastTS", "end_ms", "endMS"],
    "days": ["observation_days", "span_days", "days"],
}


def find_field(obj, aliases):
    """在任意嵌套的 dict / list 里按别名找第一个数值。`detail` 那种数组不会误伤，
    因为我们只按具名别名找，不找 `bytes` 这种通用名。"""
    stack = [obj]
    while stack:
        cur = stack.pop(0)
        if isinstance(cur, dict):
            for a in aliases:
                if a in cur and isinstance(cur[a], (int, float)):
                    return cur[a]
            for v in cur.values():
                if isinstance(v, (dict, list)):
                    stack.append(v)
        elif isinstance(cur, list):
            for v in cur:
                if isinstance(v, (dict, list)):
                    stack.append(v)
    return None


def dir_bytes(path):
    """目录实占字节（按文件逻辑大小累加；符号链接不跟随）。"""
    if not path:
        return None
    p = os.path.expanduser(path)
    if not os.path.isdir(p):
        return None
    total = 0
    for root, _dirs, files in os.walk(p):
        for f in files:
            fp = os.path.join(root, f)
            try:
                total += os.lstat(fp).st_size
            except OSError:
                pass
    return total


def mib(n):
    return None if n is None else n / MIB


def gib(n):
    return None if n is None else n / GIB


def ibytes(n):
    return "未提供" if n is None else "{:,}".format(int(n))


def stats_source(raw):
    if raw.get("command") == "stats":
        return "brosis-store stats"
    if raw.get("schema_version") is not None and "store" in raw:
        return ("app 导出「导出存储统计…」（schema_version=%s，generated_by=%s）"
                % (raw.get("schema_version"), raw.get("generated_by")))
    return "未知来源（按别名解析）"


def detail_rows(raw):
    """逐 b-tree 明细：CLI 叫 `detail`，app 导出叫 `dbstat`，两个名字都认。"""
    for key in ("detail", "dbstat"):
        rows = raw.get(key)
        if isinstance(rows, list) and rows:
            return sorted(rows, key=lambda r: -(r.get("bytes") or 0))
    return []


def collect(args):
    raw = json.load(open(os.path.expanduser(args.stats), encoding="utf-8"))
    vals, missing = {}, []
    for key, aliases in FIELDS.items():
        v = find_field(raw, aliases)
        if v is None:
            missing.append(key)
        vals[key] = v

    # 命令行给的目录 / 显式字节覆盖 stats 里的（app 导出还没有这几项时用）
    overrides = {}
    for key, dirarg, byarg in (("thumbs_bytes", args.thumbs_dir, args.thumbs_bytes),
                               ("models_bytes", args.models_dir, args.models_bytes),
                               ("temp_bytes", args.temp_dir, args.temp_bytes)):
        if byarg is not None:
            vals[key] = byarg
            overrides[key] = "命令行显式给定 %s 字节" % "{:,}".format(byarg)
        elif dirarg:
            v = dir_bytes(dirarg)
            vals[key] = 0 if v is None else v
            overrides[key] = dirarg + ("（目录不存在，记 0）" if v is None else "")
        if vals.get(key) is not None and key in missing:
            missing.remove(key)
    if vals.get("temp_bytes") is None:
        # D25：SQLITE_TEMP_STORE=3 是编译期强制内存，没有临时文件可量
        vals["temp_bytes"] = 0
        overrides["temp_bytes"] = "SQLITE_TEMP_STORE=3（编译期强制内存），恒为 0"
        if "temp_bytes" in missing:
            missing.remove("temp_bytes")
    return raw, vals, missing, overrides


def span(args, vals):
    """库里的时间跨度：优先 --span-days，其次 ledger --days 的行数，最后 first/last ts。"""
    if args.span_days:
        return float(args.span_days), "--span-days"
    if args.ledger_days:
        d = json.load(open(os.path.expanduser(args.ledger_days), encoding="utf-8"))
        days = d.get("days") if isinstance(d, dict) else d
        if isinstance(days, list) and days:
            return float(len(days)), "`ledger --days`：%s … %s，共 %d 个有观察的自然日" % (
                days[0], days[-1], len(days))
    a, b = vals.get("first_ts"), vals.get("last_ts")
    if a and b and b > a:
        return (b - a) / 86_400_000.0, "stats 里的 first_ts / last_ts"
    return None, "未知"


def build(args):
    raw, vals, missing, overrides = collect(args)
    span_days, span_note = span(args, vals)

    permanent = 0
    for k in ("db_file_bytes", "thumbs_bytes"):
        if vals.get(k):
            permanent += vals[k]
    per_month = (permanent / span_days * args.month_days) if span_days else None
    db_only_per_month = ((vals["db_file_bytes"] / span_days * args.month_days)
                         if (span_days and vals.get("db_file_bytes")) else None)

    occ, tv = vals.get("occurrences"), vals.get("text_versions")
    dedup = (1 - tv / occ) if (occ and tv) else None
    index_ratio = ((vals["fts_bytes"] / vals["text_payload_bytes"])
                   if (vals.get("fts_bytes") and vals.get("text_payload_bytes")) else None)
    amplification = ((vals["content_bytes"] / vals["text_payload_bytes"])
                     if (vals.get("content_bytes") and vals.get("text_payload_bytes")) else None)

    out = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stats_file": os.path.expanduser(args.stats),
        "stats_source": stats_source(raw),
        "units": {"MiB": MIB, "GiB": GIB,
                  "note": "本报告所有 MiB = 2^20 字节、GiB = 2^30 字节（计划 2.4）"},
        "bytes": {k: vals.get(k) for k in FIELDS if k.endswith("_bytes")},
        "rows": {k: vals.get(k) for k in
                 ("observations", "live_observations", "tombstoned_observations",
                  "text_versions", "occurrences", "fts_rows", "apps", "deletions")},
        "span_days": span_days,
        "span_note": span_note,
        "month_days": args.month_days,
        "growth": {
            "permanent_bytes": permanent,
            "permanent_per_month_bytes": per_month,
            "permanent_per_month_gib": gib(per_month),
            "db_only_per_month_gib": gib(db_only_per_month),
            "target_gib": TARGET_GIB_PER_MONTH,
            "limit_gib": LIMIT_GIB_PER_MONTH,
            "meets_target": (gib(per_month) <= TARGET_GIB_PER_MONTH) if per_month else None,
            "under_limit": (gib(per_month) <= LIMIT_GIB_PER_MONTH) if per_month else None,
        },
        "ratios": {"dedup_rate": dedup, "fts_over_payload": index_ratio,
                   "content_over_payload": amplification},
        "missing_fields": sorted(missing),
        "overrides": overrides,
        "detail_top": detail_rows(raw)[:12],
    }
    return out


def row(label, n, note):
    if n is None:
        return "| %s | 未提供 | — | — | %s |" % (label, note)
    return "| %s | %s | %.2f | %.4f | %s |" % (label, "{:,}".format(int(n)), n / MIB, n / GIB, note)


def markdown(out):
    b = out["bytes"]
    L = ["# brosis 存储月报\n"]
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append("| 生成时间 | %s |" % out["generated_at"])
    L.append("| stats 来源 | %s（`%s`） |"
             % (out["stats_source"], os.path.basename(out["stats_file"])))
    L.append("| 单位口径 | **MiB = 2^20 字节、GiB = 2^30 字节**（计划 2.4） |")
    L.append("| 库内时间跨度 | %s 天（%s） |"
             % ("未知" if out["span_days"] is None else ("%.2f" % out["span_days"]),
                out["span_note"]))
    L.append("| 折算月长度 | %d 天 |" % out["month_days"])

    L.append("\n## 1. 存储分项（2.4 的七项）\n")
    L.append("| 分项 | 字节 | MiB (2^20) | GiB (2^30) | 口径 |")
    L.append("|---|---:|---:|---:|---|")
    L.append(row("原文（`text_versions` b-tree）", b.get("content_bytes"),
                 "dbstat 实占页字节，不是估算"))
    L.append(row("— 其中原文净载荷", b.get("text_payload_bytes"),
                 "`SUM(text_versions.byte_len)`，配额按它算"))
    L.append(row("索引合计（含全文索引）", b.get("index_bytes"), "全部索引 b-tree + FTS5 影子表"))
    L.append(row("— 其中全文索引 `text_fts`", b.get("fts_bytes"), "与上一行是包含关系"))
    L.append(row("元数据", b.get("metadata_bytes"), "观察 / 出现 / 规范化对象 / 审计 / 策略 / 遥测"))
    L.append(row("空闲页", b.get("free_bytes"), "freelist，库文件里已分配但没用的部分"))
    L.append(row("**库文件合计**", b.get("db_file_bytes"), "主库文件实际大小"))
    L.append(row("WAL", b.get("wal_bytes"), "临时，checkpoint 后回落"))
    L.append(row("SHM", b.get("shm_bytes"), "临时，共享内存索引"))
    L.append(row("临时空间", b.get("temp_bytes"),
                 out["overrides"].get("temp_bytes", "见 D25")))
    L.append(row("缩略图", b.get("thumbs_bytes"),
                 out["overrides"].get("thumbs_bytes",
                                      "来自 stats 本身；也可以用 --thumbs-dir 量 `<库>.thumbs/` 目录")))
    L.append(row("模型资产", b.get("models_bytes"),
                 out["overrides"].get("models_bytes",
                                      "嵌入 / 叙述模型权重；一次性资产，不计月增长")))
    if out["missing_fields"]:
        L.append("\n> stats 里没有这些字段，已按「未提供」处理：`%s`。"
                 % "`、`".join(out["missing_fields"]))

    if out["detail_top"]:
        L.append("\n### 1b. 占用最大的 b-tree（`--detail`）\n")
        L.append("| b-tree | 桶 | 字节 | MiB |")
        L.append("|---|---|---:|---:|")
        for r in out["detail_top"]:
            L.append("| `%s` | %s | %s | %.2f |"
                     % (r.get("name"), r.get("bucket"), "{:,}".format(int(r.get("bytes", 0))),
                        r.get("bytes", 0) / MIB))

    g = out["growth"]
    L.append("\n## 2. 月增长对照 2.4 / D21\n")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append("| 永久增长口径 | 库文件 + 缩略图（WAL / SHM / 临时是瞬时的，模型资产是一次性的，都不计） |")
    L.append("| 永久占用 | %s 字节 = %s MiB = %s GiB |"
             % (ibytes(g["permanent_bytes"]), "%.2f" % mib(g["permanent_bytes"]),
                "%.4f" % gib(g["permanent_bytes"])))
    if g["permanent_per_month_bytes"] is None:
        L.append("| 折算月增长 | 无法折算：时间跨度未知 |")
    else:
        L.append("| 折算月增长 | **%.4f GiB/月**（%.2f MiB/月） |"
                 % (g["permanent_per_month_gib"], mib(g["permanent_per_month_bytes"])))
        L.append("| — 只算库文件 | %.4f GiB/月 |" % g["db_only_per_month_gib"])
        L.append("| 对照目标 0.6 GiB/月（D21） | %s |"
                 % ("达标" if g["meets_target"] else "**超目标**"))
        L.append("| 对照上限 1 GiB/月（2.4） | %s |"
                 % ("在上限内" if g["under_limit"] else "**超上限**"))

    r = out["rows"]
    ra = out["ratios"]
    L.append("\n## 3. 行数与去重\n")
    L.append("| 项 | 值 |")
    L.append("|---|---:|")
    for label, key in (("观察总数（含墓碑）", "observations"), ("其中未删除", "live_observations"),
                       ("其中删除墓碑", "tombstoned_observations"), ("文本版本", "text_versions"),
                       ("出现记录", "occurrences"), ("全文索引行", "fts_rows"),
                       ("应用", "apps"), ("删除审计", "deletions")):
        L.append("| %s | %s |" % (label, ibytes(r.get(key))))
    L.append("| **去重率** = 1 − 文本版本 / 出现记录 | %s |"
             % ("未提供" if ra["dedup_rate"] is None else "%.4f" % ra["dedup_rate"]))
    L.append("| 全文索引 / 原文净载荷 | %s |"
             % ("未提供" if ra["fts_over_payload"] is None else "%.4f×" % ra["fts_over_payload"]))
    L.append("| 原文 b-tree / 原文净载荷（页开销） | %s |"
             % ("未提供" if ra["content_over_payload"] is None
                else "%.4f×" % ra["content_over_payload"]))
    L.append("")
    return "\n".join(L)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--stats", required=True, help="brosis-store stats 的输出或 app 导出的 stats-<日期>.json")
    p.add_argument("--ledger-days", default=None, help="`ledger --days` 的输出，用来定时间跨度")
    p.add_argument("--span-days", type=float, default=None, help="直接给天数，优先级最高")
    p.add_argument("--month-days", type=float, default=30.0, help="一个月按几天折算（默认 30，E7 / D21 口径）")
    p.add_argument("--thumbs-dir", default=None, help="缩略图目录（一般是 <库路径>.thumbs）")
    p.add_argument("--models-dir", default=None, help="模型资产目录")
    p.add_argument("--temp-dir", default=None, help="临时文件目录（默认按 D25 记 0）")
    p.add_argument("--thumbs-bytes", type=int, default=None)
    p.add_argument("--models-bytes", type=int, default=None)
    p.add_argument("--temp-bytes", type=int, default=None)
    p.add_argument("--out-md", default=None)
    p.add_argument("--out-json", default=None)
    args = p.parse_args(argv)

    out = build(args)
    md = markdown(out)
    if args.out_json:
        pth = os.path.expanduser(args.out_json)
        os.makedirs(os.path.dirname(os.path.abspath(pth)), exist_ok=True)
        with open(pth, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    if args.out_md:
        pth = os.path.expanduser(args.out_md)
        os.makedirs(os.path.dirname(os.path.abspath(pth)), exist_ok=True)
        with open(pth, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(md)
    else:
        print(md)
    if args.out_md or args.out_json:
        print(json.dumps({k: out[k] for k in
                          ("span_days", "span_note", "growth", "ratios", "missing_fields")},
                         ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
