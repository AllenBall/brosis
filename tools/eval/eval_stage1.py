#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""两阶段评估的**第一阶段**：采集与检索有没有把证据拿到手。

对一个已经建好的库，逐题调 `brosis-store search`（题目带时间窗 / 应用过滤就传对应参数），
按 `docs/实施计划.md` 2.4 的检索口径算 Recall@10 / Precision@10 / MRR@10，按四类分列，
并把每道没过的题归入失败类别（4.4 的前三类 + 上下文裁剪）。

    PYTHONDONTWRITEBYTECODE=1 python3 eval_stage1.py \
        --queryset <scratch>/m1/queryset_60.json \
        --bin <scratch>/release/brosis-store \
        --dir <scratch>/m1/db --key-file <scratch>/m1/db.key \
        --out-json <scratch>/results/stage1.json \
        --out-md   <scratch>/results/stage1.md

跑两遍检索：
  1. `search-batch` 一个进程跑完整套（整套耗时就是这一遍量的）；
  2. 逐题 `search`（要 `snippet` / `summary` 才能判「上下文裁剪」）。
两遍的 evidence_ids 必须逐题相同，不同就在报告里点名（`batch_mismatch`）。

`--check-corpus`（可选）：跑检索之前先用 `brosis-store stats` 的观察行数与查询集 `corpus.observations`
比对，对不上就退出，免得拿错库跑出一份没意义的指标；真实查询集没有 `corpus` 段，自动跳过。

失败归因（计划 4.4 的六类里，第一阶段能判的前三类 + 上下文裁剪）：
  * `未采集`      —— 真值本来就是空的：语料里根本没有这条证据；
  * `已过期或已删除` —— 漏掉的证据 id 在 `get_evidence` 里回的是 `missing`
                     （用户删除墓碑或配额过期物理删除，CLI 目前分不出是哪一种）；
  * `索引漏召回`   —— 漏掉的 id 还活着（`get_evidence` 能取回原文），是检索没召回；
  * `上下文裁剪`   —— 证据召回了，但返回的 ≤ 100 token 摘要里没有答案子串，
                     Agent 只看摘要会答不出（要展开 `get_evidence` 才有）；
  * `负例误报`    —— 不可答题却返回了证据。这一类不在 4.4 的六类里（六类说的是「答不出」），
                     单列，因为草稿规定「编造一次即记失败」。
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

SCHEMA = "brosis/queryset@1"
# 六类（M2 d / T17 把「活动模式」「最近活动」两类加进来，见 tools/eval/README §2.1）
CLASSES = ("活动定位", "原文细节", "跨来源", "无答案或已删除", "活动模式", "最近活动")
DIFFICULTIES = ("易", "中", "难")
BUCKETS = ("通过", "未采集", "已过期或已删除", "索引漏召回", "上下文裁剪", "负例误报")


def load_queryset(path):
    qs = json.load(open(os.path.expanduser(path), encoding="utf-8"))
    if qs.get("schema") != SCHEMA:
        raise SystemExit("不认识的查询集：%r（要 %s）" % (qs.get("schema"), SCHEMA))
    counts = {}
    for q in qs["queries"]:
        if q["class"] not in CLASSES:
            raise SystemExit("题 %s 的类别 %r 不在六类里" % (q["id"], q["class"]))
        counts[q["class"]] = counts.get(q["class"], 0) + 1
    if qs.get("quota") and counts != qs["quota"]:
        raise SystemExit("六类配额不符：实际 %r，声明 %r" % (counts, qs["quota"]))
    return qs


def select_queries(qs, mode):
    """留出题（`holdout: true`）默认**不参与**日常评估。

    计划 4.3 要求「留出 30 题作独立测试」——留出题只在 `monthly_report.py` 的月度回归里跑，
    平时调检索参数看的是另外 70 题，免得把留出题也调进去、失去"独立"的意义。

      * `exclude`（默认）—— 只跑非留出题；
      * `include`（`--include-holdout`）—— 100 题全跑；
      * `only`（`--holdout-only`）—— 只跑 30 道留出题，月报用的就是这一档。
    """
    qs_all = qs["queries"]
    if mode == "include":
        return list(qs_all)
    if mode == "only":
        return [q for q in qs_all if q.get("holdout")]
    return [q for q in qs_all if not q.get("holdout")]


def run_json(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("命令失败：%s\n%s" % (" ".join(cmd[:3]), proc.stderr[-4000:]))
    return json.loads(proc.stdout)


def search_batch(args, queries, batch_path):
    items = []
    for q in queries:
        s = q["search"]
        item = {"id": q["id"], "q": s["q"], "limit": s.get("limit") or 10}
        for k in ("start", "end", "app"):
            if s.get(k) is not None:
                item[k] = s[k]
        items.append(item)
    os.makedirs(os.path.dirname(os.path.abspath(batch_path)), exist_ok=True)
    with open(batch_path, "w", encoding="utf-8") as fh:
        json.dump(items, fh, ensure_ascii=False)
    cmd = [args.bin, "search-batch", "--dir", args.dir, "--key-file", args.key_file,
           "--file", batch_path, "--tz", args.tz]
    t0 = time.time()
    out = run_json(cmd)
    return {r["id"]: r for r in out["results"]}, time.time() - t0


def search_one(args, q):
    s = q["search"]
    cmd = [args.bin, "search", "--dir", args.dir, "--key-file", args.key_file,
           "--q", s["q"], "--limit", str(s.get("limit") or 10), "--tz", args.tz]
    for flag, key in (("--start", "start"), ("--end", "end"), ("--app", "app")):
        if s.get(key) is not None:
            cmd += [flag, str(s[key])]
    return run_json(cmd)


def probe_missing(args, ids):
    """漏掉的证据 id 还活着吗？活着 = 索引漏召回；missing = 已删除或已过期。"""
    if not ids:
        return {"checked": [], "live": [], "missing": []}
    cmd = [args.bin, "evidence", "--dir", args.dir, "--key-file", args.key_file,
           "--ids", ",".join(str(i) for i in ids), "--neighbors", "0"]
    out = run_json(cmd)
    live = [it["evidenceID"] for it in out.get("items", [])]
    return {"checked": list(ids), "live": live, "missing": out.get("missing", [])}


def probe_full_text(args, ids, subs):
    """把返回的证据展开成原文，看答案子串在不在原文里（在 = 被摘要裁掉了）。"""
    if not ids:
        return {"checked": [], "carrying": [], "missing": []}
    cmd = [args.bin, "evidence", "--dir", args.dir, "--key-file", args.key_file,
           "--ids", ",".join(str(i) for i in ids), "--neighbors", "0"]
    out = run_json(cmd)
    carrying = [it["evidenceID"] for it in out.get("items", [])
                if carries(it.get("text"), subs)]
    return {"checked": list(ids), "carrying": carrying, "missing": out.get("missing", [])}


def carries(text, subs):
    low = (text or "").lower()
    return all(s.lower() in low for s in subs)


def evidence_match(hit, ev):
    """真实查询集没有全量真值（`relevant` 为空）时的兜底判定：
    返回的这条证据满不满足题目写的期望证据（子串 / 应用 / 时间窗 / url / path）。"""
    subs = ev.get("text_substrings") or []
    if subs and not (carries(hit.get("snippet"), subs) or carries(hit.get("summary"), subs)):
        return False
    apps = ev.get("apps") or []
    if apps and hit.get("appBundleID") not in apps:
        return False
    urls = ev.get("urls") or []
    if urls:
        blob = ((hit.get("url") or "") + " " + (hit.get("host") or "")).lower()
        if not any(u.lower() in blob for u in urls):
            return False
    paths = ev.get("paths") or []
    if paths:
        blob = (hit.get("filePath") or "").lower()
        if not any(p.lower() in blob for p in paths):
            return False
    tw = ev.get("time_window") or {}
    lo, hi = tw.get("start_ms"), tw.get("end_ms")      # 半开区间 [lo, hi)，null 端 = 无界
    if lo is not None and hit["ts"] < lo:
        return False
    if hi is not None and hit["ts"] >= hi:
        return False
    return True


def check_corpus(args, qs):
    """`--check-corpus`：核对「现在这个库」就是查询集 `corpus` 段说的那份语料建出来的。

    判据是 `brosis-store stats` 的 `observations`（观察行数**含墓碑**，所以删除执行前后
    都应当等于 `corpus.observations`）；对不上直接退出，免得拿错库跑出一份没意义的指标。
    墓碑数与 `deletions` 计划的预期条数只并排列出**不作判据**——删除是在建库之后、
    评估之前执行的，未执行时墓碑本来就是 0。真实查询集没有 `corpus` 段，跳过。
    """
    corpus = qs.get("corpus") or {}
    if corpus.get("observations") is None:
        return {"checked": False,
                "reason": "查询集没有 corpus.observations（真实题就是这样），跳过"}
    stats = run_json([args.bin, "stats", "--dir", args.dir, "--key-file", args.key_file])
    expect_deleted = sum(int(d.get("expect_observations_affected") or 0)
                         for d in (qs.get("deletions") or []))
    res = {
        "checked": True,
        "corpus_observations": int(corpus["observations"]),
        "stats_observations": stats.get("observations"),
        "live_observations": stats.get("live_observations"),
        "tombstoned_observations": stats.get("tombstoned_observations"),
        "deletions_expected_total": expect_deleted,
        "corpus_jsonl_sha256": corpus.get("jsonl_sha256"),
        "note": "观察行数含墓碑，删除前后都应当等于 corpus.observations；"
                "墓碑数只作参考（删除未执行时为 0），不作判据",
    }
    res["observations_match"] = res["stats_observations"] == res["corpus_observations"]
    res["tombstones_match"] = res["tombstoned_observations"] == expect_deleted
    if not res["observations_match"]:
        raise SystemExit("--check-corpus 不符：库里 %s 条观察，查询集的 corpus 说 %s 条"
                         "——这个库不是这份语料建出来的"
                         % (res["stats_observations"], res["corpus_observations"]))
    return res


def evaluate(args):
    qs = load_queryset(args.queryset)
    corpus_check = (check_corpus(args, qs) if args.check_corpus
                    else {"checked": False, "reason": "没加 --check-corpus"})
    queries = select_queries(qs, args.holdout_mode)
    if not queries:
        raise SystemExit("按 --holdout 口径 %r 选出来 0 道题" % args.holdout_mode)
    batch, batch_elapsed = search_batch(args, queries, args.batch_file or (args.out_json + ".batch.json"))

    rows = []
    mismatched = []
    for q in queries:
        qid = q["id"]
        b = batch.get(qid, {})
        limit = q["search"].get("limit") or 10
        got = list(b.get("evidence_ids", []))[:limit]
        rel = set(q.get("relevant") or [])
        subs = (q.get("evidence") or {}).get("text_substrings") or []

        detail = search_one(args, q)
        detail_ids = [h["evidenceID"] for h in detail.get("hits", [])][:limit]
        if detail_ids != got:
            mismatched.append(qid)

        hits10 = [i for i in got if i in rel]
        row = {
            "id": qid, "class": q["class"], "holdout": bool(q.get("holdout")),
            "difficulty": q.get("difficulty"), "tool": q.get("tool", "search"),
            "truth_mode": q.get("truth_mode", "relevant_ids"),
            "expect": q["expect"], "q": q["q"], "search_q": q["search"]["q"],
            "relevant": len(rel), "returned": len(got),
            "route": b.get("route"), "channels": b.get("channels", []),
            "fts_candidates": b.get("fts_candidates"),
            "fts_candidates_truncated": b.get("fts_candidates_truncated"),
            "max_summary_tokens": b.get("max_summary_tokens"),
            "elapsed_ms": b.get("elapsed_ms"),
            "evidence_ids": got,
        }

        if q["expect"] == "none":
            row["false_positives"] = len(got)
            row["bucket"] = "负例误报" if got else "通过"
            row["unanswerable_reason"] = q.get("unanswerable_reason")
            rows.append(row)
            continue

        ev = q.get("evidence") or {}
        matched = [h["evidenceID"] for h in detail.get("hits", [])[:limit]
                   if evidence_match(h, ev)]
        row["evidence_matched"] = len(matched)
        row["evidence_matched_ids"] = matched
        row["judged_by"] = "relevant_ids" if rel else "evidence_match"
        if rel:
            denom = min(limit, len(rel))
            row["hits@10"] = len(hits10)
            row["recall@10"] = len(hits10) / denom
            row["precision@10"] = (len(hits10) / len(got)) if got else None
            rank = next((k + 1 for k, i in enumerate(got) if i in rel), None)
        else:
            # 真实查询集：没有全量真值，改判「返回的证据里有没有满足期望证据的那条」。
            # Recall 无从算起，留 null 并在报告里单列（口径见 queryset.schema.md §7）。
            row["hits@10"] = len(matched)
            row["recall@10"] = None
            row["precision@10"] = (len(matched) / len(got)) if got else None
            rank = next((k + 1 for k, h in enumerate(detail.get("hits", [])[:limit])
                         if evidence_match(h, ev)), None)
        row["first_relevant_rank"] = rank
        row["mrr@10"] = (1.0 / rank) if rank else 0.0

        # 上下文裁剪：证据召回了，但摘要 / 片段里没有答案子串
        if subs:
            keep = rel if rel else set(matched)
            hit_objs = [h for h in detail.get("hits", []) if h["evidenceID"] in keep]
            row["summary_carries_answer"] = any(carries(h.get("summary"), subs) for h in hit_objs)
            row["snippet_carries_answer"] = any(carries(h.get("snippet"), subs) for h in hit_objs)
        else:
            row["summary_carries_answer"] = None
            row["snippet_carries_answer"] = None

        if not rel and not matched:
            # 没有全量真值时，「摘要里没有」分不清是没召回还是被裁剪：
            # 把返回的证据展开成原文再看一次，原文里有 = 上下文裁剪，原文里也没有 = 未采集。
            probe = probe_full_text(args, got, subs) if (subs and got) else None
            row["fulltext_probe"] = probe
            row["bucket"] = "上下文裁剪" if (probe and probe["carrying"]) else "未采集"
        elif not rel:
            row["bucket"] = "通过"
        elif (row["recall@10"] or 0) < 1.0:
            missed = [i for i in sorted(rel) if i not in got][:args.missed_probe]
            probe = probe_missing(args, missed)
            row["missed_probe"] = probe
            row["bucket"] = "已过期或已删除" if (probe["missing"] and not probe["live"]) \
                else "索引漏召回"
        elif subs and not row["summary_carries_answer"] and not row["snippet_carries_answer"]:
            row["bucket"] = "上下文裁剪"
        else:
            row["bucket"] = "通过"
        rows.append(row)

    out = summarize(qs, rows, batch_elapsed, mismatched, args)
    out["corpus_check"] = corpus_check
    write_outputs(qs, rows, out, args)
    return out


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def group(rows, pred):
    hit = [r for r in rows if r["expect"] == "hit" and pred(r)]
    none = [r for r in rows if r["expect"] == "none" and pred(r)]
    return {
        "hit_queries": len(hit),
        # Recall 只对"有全量真值"的题算得出来：工具题与真实题的 relevant 是空的，
        # 它们按 evidence_match 判、recall 记 null，所以均值的分母是这个数不是 hit_queries。
        "recall_scored_queries": sum(1 for r in hit if r.get("recall@10") is not None),
        "none_queries": len(none),
        "recall@10": mean([r.get("recall@10") for r in hit]),
        "precision@10": mean([r.get("precision@10") for r in hit]),
        "mrr@10": mean([r.get("mrr@10") for r in hit]),
        "none_with_false_positives": sum(1 for r in none if r.get("false_positives")),
        "passed": sum(1 for r in hit + none if r["bucket"] == "通过"),
    }


def summarize(qs, rows, batch_elapsed, mismatched, args):
    """注意：`corpus_check` 由 evaluate() 在这之后塞进来（它要跑 CLI，放在检索之前做）。"""
    buckets = {b: [r["id"] for r in rows if r["bucket"] == b] for b in BUCKETS}
    by_class = {c: group(rows, lambda r, c=c: r["class"] == c) for c in CLASSES
                if any(r["class"] == c for r in rows)}
    by_difficulty = {d: group(rows, lambda r, d=d: r.get("difficulty") == d)
                     for d in DIFFICULTIES if any(r.get("difficulty") == d for r in rows)}
    tools = sorted({r.get("tool", "search") for r in rows})
    by_tool = {t: group(rows, lambda r, t=t: r.get("tool", "search") == t) for t in tools}
    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "queryset": os.path.basename(os.path.expanduser(args.queryset)),
        "queryset_source": qs.get("source"),
        "db": args.dir,
        "queries": len(rows),
        "overall": group(rows, lambda r: True),
        "by_class": by_class,
        "by_difficulty": by_difficulty,
        "by_tool": by_tool,
        "holdout_mode": args.holdout_mode,
        "queryset_total_queries": len(qs["queries"]),
        "holdout": group(rows, lambda r: r["holdout"]),
        "non_holdout": group(rows, lambda r: not r["holdout"]),
        "buckets": {b: len(v) for b, v in buckets.items()},
        "bucket_ids": buckets,
        "batch_elapsed_s": batch_elapsed,
        "batch_vs_single_mismatch": mismatched,
        "max_fts_candidates": max([r.get("fts_candidates") or 0 for r in rows]),
        "fts_candidates_truncated_queries": [r["id"] for r in rows
                                             if r.get("fts_candidates_truncated")],
        "max_summary_tokens": max([r.get("max_summary_tokens") or 0 for r in rows]),
        "target_2_4": {"recall@10": 0.90,
                       "met": (group(rows, lambda r: True)["recall@10"] or 0) >= 0.90},
        "per_query": rows,
    }


def fmt(x, nd=3):
    return "—" if x is None else ("%.*f" % (nd, x))


def write_outputs(qs, rows, out, args):
    if args.out_json:
        p = os.path.expanduser(args.out_json)
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
    if args.out_md:
        p = os.path.expanduser(args.out_md)
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(markdown(qs, rows, out))
    printable = {k: out[k] for k in
                 ("queries", "overall", "by_class", "holdout", "non_holdout", "buckets",
                  "batch_elapsed_s", "batch_vs_single_mismatch", "max_fts_candidates",
                  "fts_candidates_truncated_queries", "max_summary_tokens", "target_2_4",
                  "corpus_check")}
    print(json.dumps(printable, ensure_ascii=False, indent=1))


def markdown(qs, rows, out):
    L = []
    L.append("# 第一阶段：检索能不能拿到证据\n")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append("| 查询集 | `%s`（source = %s，%d 题） |"
             % (out["queryset"], out["queryset_source"], out["queries"]))
    L.append("| 采集时间 | %s |" % out["generated_at"])
    L.append("| 整套 `search-batch` 耗时 | %.3f s |" % out["batch_elapsed_s"])
    L.append("| 逐题 `search` 与 `search-batch` 结果不一致的题 | %s |"
             % (", ".join(out["batch_vs_single_mismatch"]) or "无"))
    L.append("| 最大 FTS 候选 / 是否截断 | %d / %s |"
             % (out["max_fts_candidates"],
                ", ".join(out["fts_candidates_truncated_queries"]) or "无"))
    L.append("| 最大摘要 token | %d |" % out["max_summary_tokens"])
    cc = out.get("corpus_check") or {}
    L.append("| 语料核对（`--check-corpus`） | %s |"
             % ("库里 %s 条观察（含墓碑）== 查询集 corpus 的 %s 条；活 %s / 墓碑 %s（删除计划 %s）"
                % (cc.get("stats_observations"), cc.get("corpus_observations"),
                   cc.get("live_observations"), cc.get("tombstoned_observations"),
                   cc.get("deletions_expected_total"))
                if cc.get("checked") else "未核对（%s）" % cc.get("reason")))
    if out["queryset_source"] == "synthetic":
        L.append("\n> 口径说明：这是**合成语料 + 脚本自己出的题**，只能证明检索方法成立，"
                 "不能当作真实使用的召回率。真实 60 题按 `tools/eval/queryset.schema.md` 出（D12）。\n")

    L.append("\n## 总体与分类\n")
    L.append("| 组 | 可答题 | 其中算得出 Recall 的 | 不可答题 | Recall@10 | Precision@10 | MRR@10 | 负例误报 | 通过 |")
    L.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")

    def line(name, g, total):
        L.append("| %s | %d | %d | %d | %s | %s | %s | %d | %d/%d |"
                 % (name, g["hit_queries"], g["recall_scored_queries"], g["none_queries"],
                    fmt(g["recall@10"]), fmt(g["precision@10"]), fmt(g["mrr@10"]),
                    g["none_with_false_positives"], g["passed"], total))

    for c in CLASSES:
        if c not in out["by_class"]:
            continue
        g = out["by_class"][c]
        line(c, g, g["hit_queries"] + g["none_queries"])
    line("**合计**", out["overall"], out["queries"])
    line("留出题", out["holdout"], out["holdout"]["hit_queries"] + out["holdout"]["none_queries"])
    line("非留出题", out["non_holdout"],
         out["non_holdout"]["hit_queries"] + out["non_holdout"]["none_queries"])
    L.append("\n目标（计划 2.4）：可答题 Recall@10 ≥ 0.90 —— 实测 %s，%s。\n"
             % (fmt(out["overall"]["recall@10"]), "达标" if out["target_2_4"]["met"] else "**未达标**"))
    L.append("\n> 留出题口径：`%s`（本次跑了 %d / %d 题）。默认 `exclude`；月报用 `--holdout-only`。\n"
             % (out["holdout_mode"], out["queries"], out["queryset_total_queries"]))

    L.append("\n## 按难度 / 按工具\n")
    L.append("| 分组 | 可答题 | 其中算得出 Recall 的 | 不可答题 | Recall@10 | Precision@10 | MRR@10 | 负例误报 | 通过 |")
    L.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for d in DIFFICULTIES:
        if d not in out["by_difficulty"]:
            continue
        g = out["by_difficulty"][d]
        line("难度 " + d, g, g["hit_queries"] + g["none_queries"])
    for t, g in sorted(out["by_tool"].items()):
        line("工具 `%s`" % t, g, g["hit_queries"] + g["none_queries"])
    L.append("\n> `tool != search` 的题问的是聚合量，`relevant` 留空、按"
             "「返回的证据满不满足期望证据」判（`judged_by = evidence_match`），Recall 记 null——"
             "它们的真正判据是 `make_synthetic_queryset.py verify-tools`。\n")

    L.append("\n## 失败归因（4.4 前三类 + 上下文裁剪）\n")
    L.append("| 类别 | 题数 | 题号 |")
    L.append("|---|---:|---|")
    for b in BUCKETS:
        ids = out["bucket_ids"][b]
        L.append("| %s | %d | %s |" % (b, len(ids), ", ".join(ids) or "—"))

    L.append("\n## 逐题\n")
    L.append("| id | 类 | 难度 | 工具 | 留出 | 期望 | 真值 | 返回 | R@10 | P@10 | MRR | 首个相关位次 | 通道 | 归因 |")
    L.append("|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|")
    for r in rows:
        L.append("| `%s` | %s | %s | `%s` | %s | %s | %d | %d | %s | %s | %s | %s | %s | %s |"
                 % (r["id"], r["class"], r.get("difficulty") or "—", r.get("tool", "search"),
                    "是" if r["holdout"] else "否", r["expect"],
                    r["relevant"], r["returned"], fmt(r.get("recall@10")),
                    fmt(r.get("precision@10")), fmt(r.get("mrr@10")),
                    r.get("first_relevant_rank") or "—",
                    "+".join(r.get("channels") or []) or "—", r["bucket"]))
    L.append("")
    return "\n".join(L)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--queryset", required=True)
    p.add_argument("--bin", required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--key-file", required=True)
    p.add_argument("--tz", default="UTC")
    p.add_argument("--out-json", default=None)
    p.add_argument("--out-md", default=None)
    p.add_argument("--batch-file", default=None)
    p.add_argument("--missed-probe", type=int, default=10,
                   help="漏召回时最多拿几个漏掉的 id 去 get_evidence 探活")
    p.add_argument("--include-holdout", dest="holdout_mode", action="store_const",
                   const="include", default="exclude",
                   help="连留出题一起跑（默认排除，见 select_queries 的说明）")
    p.add_argument("--holdout-only", dest="holdout_mode", action="store_const", const="only",
                   help="只跑留出题（月报的独立测试口径）")
    p.add_argument("--check-corpus", action="store_true",
                   help="评估前先用 stats 的观察数核对这个库就是查询集 corpus 段那份语料建出来的"
                        "（真实题没有 corpus 段，自动跳过）")
    args = p.parse_args(argv)
    for k in ("bin", "dir", "key_file"):
        setattr(args, k, os.path.expanduser(getattr(args, k)))
    if not args.out_json:
        args.out_json = os.path.join(os.path.dirname(os.path.abspath(args.queryset)),
                                     "stage1.json")
    evaluate(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
