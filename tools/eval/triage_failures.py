#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「答不出的问题」按 `docs/实施计划.md` 4.4 的**六类**归因，并留出人工标注列。

4.4 原文：「每个答不出的问题先归入六类之一：未采集、已过期、索引漏召回、上下文裁剪、
别名不统一、推理错误。前四类修采集与检索。……只有轻量方案之后留出题上的失败仍然集中在
关系 / 别名 / 时态问题，才对同一批留出题做图谱对照实验」。这个脚本就是那张诊断表的生成器：
**M2b 语义图谱要不要启动，看的是它的输出**。

    PYTHONDONTWRITEBYTECODE=1 python3 triage_failures.py \\
        --queryset  <scratch>/queryset_100.json \\
        --stage1    <scratch>/results/stage1.json \\
        --stage2    <scratch>/results/stage2.json          # 可选，没有就只看第一阶段
        --paraphrase-stage1 <scratch>/results/stage1_para.json  # 可选，别名的第二个证据来源
        --annotations <scratch>/triage_annotations.jsonl   # 可选，人工标注回写在这里
        --out-json <…>/triage.json --out-md <…>/triage.md \\
        --write-annotations <scratch>/triage_annotations.jsonl

---

## 1. 六类怎么判（规则，按优先级从上往下第一个命中的算）

| 类 | 判据（本脚本实际用的） | 数据来源 |
|---|---|---|
| `未采集` | 真值为空、期望证据也一条都没匹配上——答案的那次观察**根本不在库里** | 第一阶段 |
| `已过期或已删除` | 漏掉的证据 id 拿去 `get_evidence` 全部回 `missing`（墓碑或配额过期物理删除） | 第一阶段 |
| `别名不统一` | 证据**还活着**却没召回，**并且**检索串与期望答案没有任何公共字面（中文字符 bigram ∪ ASCII 词元）——换了个说法，字面通道必然打不中；或者原题过了、它的**改写题**挂了 | 第一阶段 + 可选的改写题跑分 |
| `索引漏召回` | 证据还活着、没召回，但检索串与答案**有**公共字面——是索引 / 候选截断 / 排序的问题，不是说法的问题 | 第一阶段 |
| `上下文裁剪` | 证据召回了，但 ≤ 100 token 的摘要与片段里都没有答案子串（要展开 `get_evidence` 才有） | 第一阶段 |
| `推理错误` | **兜底**：证据拿到了、也没被裁，第二阶段仍然答错 | 第二阶段 |

另外单列一个 **`负例误报`**：不可答题却返回了证据。它不在 4.4 的六类里（六类说的是"答不出"），
但查询集草稿规定"编造一次即失败"，所以必须看得见。

`别名不统一` 排在 `索引漏召回` 前面，是因为它更具体：两者都是"活着但没召回"，
区别只在**为什么**没召回。判据写成"没有公共字面"是有依据的——本项目的 FTS 通道是
「bigram phrase 命中 → 在原文上做子串复核」（D22 + 3.4），语义上等于精确子串，
换个说法之后字面通道必然一条都召不回（这也正是 D8 改写题实验的前提，见 README §4）。

## 2. 人工标注

规则只给**候选**归因。`--write-annotations` 会写一份 JSONL（一题一行），
人工把 `manual_bucket` 填上（六类之一或 `负例误报` / `通过`）、`note` 写理由，
下次跑加 `--annotations <同一个文件>` 就会读回来：报告里 `final_bucket` 优先用人工的，
并统计规则与人工**分歧**了几题（`disagreements`）——分歧率就是这套规则的可信度。
已有文件里的 `manual_bucket` / `note` / `annotator` 永远不会被覆盖。
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

SCHEMA = "brosis/queryset@1"

# 引用判据的三档说法，与 `eval_stage2.py` 的 `BASIS_WORD` 逐字一致。
# 这里是抄一份而不是 import：两个脚本各自独立跑，归因不该因为判分脚本的依赖而起不来。
BASIS_WORD = {"relevant_ids": "真值 id", "evidence_match": "满足期望证据的 id",
              "packed_evidence": "喂给它看过的 id"}

# 4.4 的六类 + 一个单列项 + 通过
BUCKET_NOT_CAPTURED = "未采集"
BUCKET_EXPIRED = "已过期或已删除"
BUCKET_INDEX_MISS = "索引漏召回"
BUCKET_TRIMMED = "上下文裁剪"
BUCKET_ALIAS = "别名不统一"
BUCKET_REASONING = "推理错误"
SIX = (BUCKET_NOT_CAPTURED, BUCKET_EXPIRED, BUCKET_INDEX_MISS,
       BUCKET_TRIMMED, BUCKET_ALIAS, BUCKET_REASONING)
BUCKET_FALSE_POSITIVE = "负例误报"
BUCKET_PASS = "通过"
ALL_BUCKETS = (BUCKET_PASS,) + SIX + (BUCKET_FALSE_POSITIVE,)

# 前四类修采集与检索（4.4 原话），后两类是轻量方案 / 图谱实验的入口
REMEDY = {
    BUCKET_NOT_CAPTURED: "修采集：这条内容当时没被记下来（应用没勾选 / 排除清单 / 权限丢失 / 记录器没开）",
    BUCKET_EXPIRED: "修保留策略：被用户删除或配额过期扫掉了；检查 3.8 的保留期与 D7 配额",
    BUCKET_INDEX_MISS: "修检索：索引、候选上限或排序的问题（先看 fts_candidates_truncated 与通道）",
    BUCKET_TRIMMED: "修上下文：摘要 token 预算或片段选取；Agent 应当展开 get_evidence",
    BUCKET_ALIAS: "先试轻量方案（4.4）：项目标签、对象别名表、字段过滤、多步检索；向量通道也算一种",
    BUCKET_REASONING: "修提示 / 换模型：证据齐了还答错，属于 Agent 侧",
    BUCKET_FALSE_POSITIVE: "修不可答判定：不可答题返回了证据，草稿规定编造一次即失败",
}


def load_json(path):
    return json.load(open(os.path.expanduser(path), encoding="utf-8"))


# --------------------------------------------------------------------------- #
# 1. 字面重合：判「别名不统一」用的那把尺子
# --------------------------------------------------------------------------- #

def is_cjk(ch):
    cp = ord(ch)
    return 0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF


def literals(text):
    """一段文本的字面集合：中文连续段的字符 bigram（单字段落也算一个）∪ ASCII 词元。

    口径与索引侧一致：D22 的中文 FTS 就是按字符 bigram 建的，ASCII 按词切。
    """
    low = (text or "").lower()
    out = set()
    run = []
    token = []
    for ch in low:
        if is_cjk(ch):
            if token:
                out.add("".join(token))
                token = []
            run.append(ch)
            continue
        if run:
            if len(run) == 1:
                out.add(run[0])
            else:
                for i in range(len(run) - 1):
                    out.add(run[i] + run[i + 1])
            run = []
        if ch.isalnum():
            token.append(ch)
        elif token:
            out.add("".join(token))
            token = []
    if run:
        if len(run) == 1:
            out.add(run[0])
        else:
            for i in range(len(run) - 1):
                out.add(run[i] + run[i + 1])
    if token:
        out.add("".join(token))
    return out


def strip_prefix(q):
    for prefix in ("url:", "host:", "path:", "app:", "title:"):
        if q.startswith(prefix):
            return q[len(prefix):]
    return q


def alias_signal(query):
    """检索串与"期望答案的字面"有没有公共字面。没有 = 换了说法。"""
    probe = strip_prefix(query["search"]["q"])
    want = " ".join((query.get("evidence") or {}).get("text_substrings") or [])
    want += " " + " ".join((query.get("answer_check") or {}).get("must_include") or [])
    want += " " + " ".join((query.get("evidence") or {}).get("urls") or [])
    want += " " + " ".join((query.get("evidence") or {}).get("paths") or [])
    a, b = literals(probe), literals(want)
    if not a or not b:
        return False, {"probe_literals": len(a), "answer_literals": len(b),
                       "shared": [], "reason": "一侧没有字面可比，不判别名"}
    shared = sorted(a & b)[:6]
    return (not shared), {"probe_literals": len(a), "answer_literals": len(b),
                          "shared": shared,
                          "reason": ("检索串与期望答案没有公共字面" if not shared
                                     else "有公共字面 %s" % "/".join(shared))}


# --------------------------------------------------------------------------- #
# 2. 归因
# --------------------------------------------------------------------------- #

def triage_one(query, s1, s2, para_failed):
    """返回 (bucket, why, evidence_dict)。规则按上面的优先级从上往下。"""
    why = []
    ev = {}
    stage1_bucket = s1.get("bucket")

    if stage1_bucket == BUCKET_FALSE_POSITIVE:
        return BUCKET_FALSE_POSITIVE, "不可答题返回了 %d 条证据" % (s1.get("false_positives") or 0), ev

    if stage1_bucket == BUCKET_NOT_CAPTURED:
        return BUCKET_NOT_CAPTURED, "真值为空且期望证据一条没匹配上", ev

    if stage1_bucket == BUCKET_EXPIRED:
        probe = s1.get("missed_probe") or {}
        ev["missed_probe"] = {"missing": len(probe.get("missing") or []),
                              "live": len(probe.get("live") or [])}
        return BUCKET_EXPIRED, "漏掉的证据在 get_evidence 里全部 missing", ev

    if stage1_bucket == BUCKET_INDEX_MISS:
        alias, detail = alias_signal(query)
        ev["alias"] = detail
        if alias:
            return BUCKET_ALIAS, "证据还活着却没召回，且%s" % detail["reason"], ev
        if query["id"] in para_failed:
            ev["paraphrase_failed"] = True
            return BUCKET_ALIAS, "原题的改写题在改写题集上也挂了（换说法就召不回）", ev
        return BUCKET_INDEX_MISS, "证据还活着、没召回，但%s" % detail["reason"], ev

    if stage1_bucket == BUCKET_TRIMMED:
        return BUCKET_TRIMMED, "证据召回了，但摘要与片段里没有答案子串", ev

    # 第一阶段过了：只可能是第二阶段的问题
    #
    # 键名以 `eval_stage2.py` 的 `score()` 为准：它把返回的字典整个加了 `score_` 前缀，
    # 所以是 `score_content_ok` / `score_citation_ok`，**不是** `score_content` /
    # `score_citation`（原来写的那两个键永远取不到，这一段的理由行因此一直是空的）。
    # `score_unanswerable` 是"模型自己说答不出"这个**事实**，不是判分项——
    # 它为真才是问题（把可答题判成无证据），为假是正常，所以不能拿它当"某项没过"。
    # 判分理由一律以 stage2 自己写的 `score_reason` 为准（不可答题与"输出不是 JSON"
    # 这两种情况下 stage2 根本不写 *_ok 两个键，只有 score_reason 说得清）。
    if s2 is not None and s2.get("scored") and not s2.get("score_passed"):
        why = []
        if s2.get("score_content_ok") is False:
            why.append("答案内容不含 answer_check.must_include")
        if s2.get("score_citation_ok") is False:
            why.append("引用无效（引用 %s 条，落在「%s」里的 %s 条）"
                       % (s2.get("score_citation_total"),
                          BASIS_WORD.get(s2.get("score_citation_basis"), "有效 id"),
                          s2.get("score_citation_valid")))
        if s2.get("score_unanswerable") is True:
            why.append("把可答题判成了无证据")
        reason = (s2.get("score_reason") or "").strip()
        if reason:
            why.append("stage2 判分理由：" + reason)
        ev["stage2"] = {k: s2.get(k) for k in
                        ("score_passed", "score_parsed", "score_content_ok", "score_citation_ok",
                         "score_unanswerable", "score_citation_basis", "score_citation_basis_size",
                         "score_citation_total", "score_citation_valid", "score_reason")}
        # 别名也可能在第二阶段才暴露：证据齐了但答案里一个公共字面都没有
        alias, detail = alias_signal(query)
        if alias:
            ev["alias"] = detail
            return BUCKET_ALIAS, "证据齐了，但检索串与期望答案没有公共字面", ev
        return BUCKET_REASONING, "证据都拿到了、也没被裁，仍然答错：" + "；".join(why or ["未给出理由"]), ev

    if s2 is not None and s2.get("scored") and s1.get("bucket") == BUCKET_PASS:
        return BUCKET_PASS, "两个阶段都过", ev
    if stage1_bucket == BUCKET_PASS:
        return BUCKET_PASS, "第一阶段通过" + ("" if s2 is None else "，第二阶段未评分"), ev
    return BUCKET_REASONING, "第一阶段归因 %r 不在已知桶里，落到兜底" % stage1_bucket, ev


# --------------------------------------------------------------------------- #
# 3. 人工标注
# --------------------------------------------------------------------------- #

def read_annotations(path):
    if not path or not os.path.exists(os.path.expanduser(path)):
        return {}
    out = {}
    with open(os.path.expanduser(path), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            row = json.loads(line)
            out[row["id"]] = row
    return out


def write_annotations(path, rows, existing):
    p = os.path.expanduser(path)
    os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# 人工标注：把 manual_bucket 填成六类之一（或 负例误报 / 通过），note 写理由。\n")
        fh.write("# 六类：未采集 / 已过期或已删除 / 索引漏召回 / 上下文裁剪 / 别名不统一 / 推理错误\n")
        fh.write("# 已填的行不会被这个脚本覆盖；下次跑加 --annotations <本文件> 读回来。\n")
        for r in rows:
            old = existing.get(r["id"], {})
            fh.write(json.dumps({
                "id": r["id"],
                "class": r["class"],
                "q": r["q"],
                "auto_bucket": r["auto_bucket"],
                "auto_why": r["auto_why"],
                "manual_bucket": old.get("manual_bucket"),
                "annotator": old.get("annotator", ""),
                "annotated_at": old.get("annotated_at", ""),
                "note": old.get("note", ""),
            }, ensure_ascii=False, sort_keys=True) + "\n")


# --------------------------------------------------------------------------- #
# 4. 主流程
# --------------------------------------------------------------------------- #

def run(args):
    qs = load_json(args.queryset)
    if qs.get("schema") != SCHEMA:
        raise SystemExit("不认识的查询集：%r" % qs.get("schema"))
    by_id = {q["id"]: q for q in qs["queries"]}
    stage1 = load_json(args.stage1)
    s1_rows = {r["id"]: r for r in stage1["per_query"]}
    stage2 = load_json(args.stage2) if args.stage2 else None
    s2_rows = {r["id"]: r for r in stage2["per_query"]} if stage2 else {}

    para_failed = set()
    para_meta = None
    if args.paraphrase_stage1:
        para = load_json(args.paraphrase_stage1)
        para_meta = {"queryset": para.get("queryset"), "queries": para.get("queries")}
        for r in para["per_query"]:
            if r["bucket"] != BUCKET_PASS:
                # 改写题 id 形如 <原题 id>-<后缀>
                para_failed.add(r["id"].rsplit("-", 1)[0])

    existing = read_annotations(args.annotations)
    rows = []
    for qid, s1 in s1_rows.items():
        q = by_id.get(qid)
        if q is None:
            continue
        bucket, why, ev = triage_one(q, s1, s2_rows.get(qid), para_failed)
        manual = (existing.get(qid) or {}).get("manual_bucket")
        rows.append({
            "id": qid,
            "class": q["class"],
            "difficulty": q.get("difficulty"),
            "tool": q.get("tool", "search"),
            "holdout": bool(q.get("holdout")),
            "expect": q["expect"],
            "q": q["q"],
            "search_q": q["search"]["q"],
            "stage1_bucket": s1.get("bucket"),
            "recall@10": s1.get("recall@10"),
            "returned": s1.get("returned"),
            "relevant": s1.get("relevant"),
            "auto_bucket": bucket,
            "auto_why": why,
            "auto_evidence": ev,
            "manual_bucket": manual,
            "final_bucket": manual or bucket,
            "remedy": REMEDY.get(manual or bucket, "—"),
        })
    rows.sort(key=lambda r: (r["final_bucket"] == BUCKET_PASS, r["id"]))

    def counts(key):
        c = {b: 0 for b in ALL_BUCKETS}
        for r in rows:
            c[r[key]] = c.get(r[key], 0) + 1
        return c

    failures = [r for r in rows if r["final_bucket"] != BUCKET_PASS]
    disagreements = [r["id"] for r in rows
                     if r["manual_bucket"] and r["manual_bucket"] != r["auto_bucket"]]
    annotated = [r["id"] for r in rows if r["manual_bucket"]]
    out = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "queryset": os.path.basename(os.path.expanduser(args.queryset)),
        "queryset_source": qs.get("source"),
        "stage1": os.path.basename(os.path.expanduser(args.stage1)),
        "stage1_holdout_mode": stage1.get("holdout_mode"),
        "stage2": os.path.basename(os.path.expanduser(args.stage2)) if args.stage2 else None,
        "stage2_graded": bool(stage2 and stage2.get("graded")),
        "paraphrase_source": para_meta,
        "queries": len(rows),
        "failures": len(failures),
        "auto_counts": counts("auto_bucket"),
        "final_counts": counts("final_bucket"),
        "six_class_counts": {b: counts("final_bucket")[b] for b in SIX},
        "annotated": annotated,
        "disagreements": disagreements,
        "by_class": {c: {b: sum(1 for r in rows if r["class"] == c and r["final_bucket"] == b)
                         for b in ALL_BUCKETS}
                     for c in sorted({r["class"] for r in rows})},
        "holdout_failures": [r["id"] for r in failures if r["holdout"]],
        "rows": rows,
    }
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
            fh.write(markdown(out))
    if args.write_annotations:
        write_annotations(args.write_annotations, rows, existing)
        out["annotations_file"] = os.path.expanduser(args.write_annotations)
    print(json.dumps({k: out[k] for k in
                      ("queries", "failures", "final_counts", "six_class_counts",
                       "annotated", "disagreements", "holdout_failures",
                       "stage1_holdout_mode", "stage2_graded")},
                     ensure_ascii=False, indent=1))
    return out


def markdown(out):
    L = []
    L.append("# 失败归因（计划 4.4 的六类）\n")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append("| 查询集 | `%s`（source = %s） |" % (out["queryset"], out["queryset_source"]))
    L.append("| 第一阶段 | `%s`（留出题口径 `%s`） |" % (out["stage1"], out["stage1_holdout_mode"]))
    L.append("| 第二阶段 | %s |"
             % ("`%s`%s" % (out["stage2"], "（已评分）" if out["stage2_graded"] else "（未评分：`推理错误`这一类判不出来）")
                if out["stage2"] else "未提供——**`推理错误` 这一类判不出来**"))
    L.append("| 改写题跑分 | %s |"
             % ("`%s`（%s 题）" % (out["paraphrase_source"]["queryset"],
                                 out["paraphrase_source"]["queries"])
                if out["paraphrase_source"] else "未提供（别名只靠字面重合判）"))
    L.append("| 题数 / 没过的 | %d / **%d** |" % (out["queries"], out["failures"]))
    L.append("| 人工标注 / 与规则分歧 | %d / %d |" % (len(out["annotated"]), len(out["disagreements"])))
    L.append("| 留出题里没过的 | %s |" % (", ".join(out["holdout_failures"]) or "无"))

    L.append("\n## 按类计数\n")
    L.append("| 类 | 题数 | 该修什么 |")
    L.append("|---|---:|---|")
    for b in ALL_BUCKETS:
        L.append("| %s%s | %d | %s |"
                 % (b, "" if b in (BUCKET_PASS, BUCKET_FALSE_POSITIVE) else "（4.4 六类）",
                    out["final_counts"].get(b, 0), REMEDY.get(b, "—")))

    L.append("\n## 逐题（只列没过的；全过时这张表是空的）\n")
    L.append("| id | 类 | 难度 | 留出 | 第一阶段归因 | 六类归因 | 人工 | 依据 |")
    L.append("|---|---|---|---|---|---|---|---|")
    any_fail = False
    for r in out["rows"]:
        if r["final_bucket"] == BUCKET_PASS:
            continue
        any_fail = True
        L.append("| `%s` | %s | %s | %s | %s | **%s** | %s | %s |"
                 % (r["id"], r["class"], r["difficulty"] or "—", "是" if r["holdout"] else "否",
                    r["stage1_bucket"], r["auto_bucket"], r["manual_bucket"] or "—", r["auto_why"]))
    if not any_fail:
        L.append("| — | — | — | — | — | — | — | 一道都没挂 |")

    L.append("\n## 全部题目的归因（含通过）\n")
    L.append("| id | 类 | 工具 | 六类归因 | 依据 |")
    L.append("|---|---|---|---|---|")
    for r in out["rows"]:
        L.append("| `%s` | %s | `%s` | %s | %s |"
                 % (r["id"], r["class"], r["tool"], r["final_bucket"], r["auto_why"]))
    L.append("")
    L.append("> 4.4 的启动条件：只有**留出题**上的失败仍然集中在关系 / 别名 / 时态问题，"
             "才对同一批留出题做图谱对照实验。所以看的是上面「留出题里没过的」那一行 + "
             "`别名不统一` 的计数，不是总体通过率。\n")
    return "\n".join(L)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--queryset", required=True)
    p.add_argument("--stage1", required=True)
    p.add_argument("--stage2", default=None)
    p.add_argument("--paraphrase-stage1", default=None,
                   help="改写题集跑出来的 stage1.json：原题过了、改写题挂了 = 别名不统一的第二个证据")
    p.add_argument("--annotations", default=None, help="读回已有的人工标注 JSONL")
    p.add_argument("--write-annotations", default=None, help="写一份人工标注 JSONL（已填的不覆盖）")
    p.add_argument("--out-json", default=None)
    p.add_argument("--out-md", default=None)
    args = p.parse_args(argv)
    run(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
