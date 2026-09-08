#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 60 题合成查询集派生一套**改写题**，用来裁决 D8（计划 D8 / 3.4 / 4.3）。

D8 的门槛原文：「Recall@10 提升 ≥ 5 个百分点**或解决明确的高价值失败**才纳入」。
这套题就是那个「明确的高价值失败」：**同一个问题换一种说法**。

为什么它能把 FTS 与向量分开：本项目的 FTS 通道是「bigram phrase 命中 → 在**原文**上做
子串复核」（D22 + 3.4），语义上等于**精确子串**。换一种说法之后原文里没有那个子串，
FTS 通道必然一条都召不回；能不能召回全看向量通道。所以这套题量的正是
「向量到底解决了什么 FTS 解决不了的问题」。

三类改写（计划里写的「同义改写、中英互译、术语换说法」各占一部分）：

| kind | 意思 | 例子（原题词 -> 改写） |
|---|---|---|
| `synonym` | 同义改写，中文换近义说法 | 采集覆盖率 -> 抓取完整度 |
| `translation` | 中英互译 | contentless -> 无内容模式的全文索引 |
| `terminology` | 术语换说法 | wal_checkpoint(TRUNCATE) -> 把预写日志截断的检查点命令 |

硬规则（生成时逐条断言，不满足直接退出）：
  1. **标准答案与原题相同**：`relevant` 原样抄过来（原题的真值已经扣掉删除）；
  2. **改写串里不能含原词**（大小写不敏感），否则 FTS 会照样命中，这套题就白出了；
  3. 只从**真值是正文**的题派生（`rule == "text"`）——`app:` / `host:` / `path:` 那几类
     的真值是"这个应用/站点的全部观察"，换个说法属于 Agent 该不该把「Lark」映射成
     bundle id 的问题，不是检索层的问题，混进来只会两边一起掉分；
  4. 真值非空。

确定性：改写表是手写常量，脚本里没有随机数。同一份输入两次产出逐字节相同。

    PYTHONDONTWRITEBYTECODE=1 python3 make_paraphrase_queryset.py gen \\
        --queryset <scratch>/queryset_60.json --out <scratch>/queryset_paraphrase.json
"""

import argparse
import json
import os
import sys

SCHEMA = "brosis/queryset@1"
AUTHORED = "2026-09-08"

# --------------------------------------------------------------------------- #
# 改写表：原题 id -> [(后缀, 改写类别, 检索串 / 自然语言问题)]
#
# 「检索串」既是 `search.q`（喂给 brosis-store 的那一串），也是 `embed_text`
# （喂给 brosis-embed queries 的那一串）——两边必须**完全一样**，
# 否则量到的就不是同一个查询了。
# --------------------------------------------------------------------------- #

REWRITES = {
    # ---- 原文细节 20 题 ----
    "det-01": [("a", "synonym", "实体关系网络的那段内容"),
               ("b", "terminology", "把概念连成一张网的那种数据结构")],
    "det-02": [("a", "synonym", "抓取完整度是多少"),
               ("b", "terminology", "屏幕内容被记下来的比例")],
    "det-03": [("a", "synonym", "记录留存多久的规则"),
               ("b", "terminology", "旧数据什么时候被清掉")],
    "det-04": [("a", "synonym", "辅助功能的授权"),
               ("b", "terminology", "读取别的应用界面要开的那个系统开关")],
    "det-05": [("a", "synonym", "在窗口顶栏连点两下"),
               ("b", "terminology", "敲两下窗口最上面那一条会怎样")],
    "det-06": [("a", "translation", "无内容模式的全文索引"),
               ("b", "terminology", "只存倒排表不存正文的索引写法")],
    "det-07": [("a", "translation", "检查点，把日志刷回主库")],
    "det-08": [("a", "translation", "签名里的权利声明")],
    "det-09": [("a", "translation", "加密版的 SQLite 数据库")],
    "det-10": [("a", "translation", "解析观察记录的那个函数")],
    "det-11": [("a", "translation", "SQLite 预编译语句的那个接口")],
    "det-12": [("a", "translation", "辅助功能里文档发生变化的通知常量")],
    "det-13": [("a", "translation", "把待写的出现记录刷盘的那个函数")],
    "det-14": [("a", "terminology", "把预写日志截断的检查点命令")],
    "det-15": [("a", "translation", "钥匙串里找不到条目的系统错误码")],
    "det-16": [("a", "terminology", "编号 1042 的那个业务错误")],
    "det-17": [("a", "translation", "进程被强制杀掉时的退出码")],
    "det-18": [("a", "translation", "拒绝访问的那个十六进制错误码")],
    "det-19": [("a", "synonym", "衡量混乱程度的那个字")],
    "det-20": [("a", "synonym", "磨墨用的那个字")],

    # ---- 跨来源 10 题 ----
    "cross-01": [("a", "synonym", "在好几个软件里都出现的同一个记号"),
                 ("b", "terminology", "同一个标签在不同应用之间反复出现")],
    "cross-02": [("a", "synonym", "费用的二次审核"),
                 ("b", "terminology", "花钱计划的重新核对")],
    "cross-03": [("a", "synonym", "三个月的日程计划表"),
                 ("b", "terminology", "一个季度的排班安排")],
    "cross-04": [("a", "terminology", "全文检索的索引占多大空间"),
                 ("b", "translation", "倒排索引相对正文的膨胀倍数")],
    "cross-05": [("a", "translation", "辅助功能事件的重复过滤"),
                 ("b", "terminology", "同一条界面通知来两次要不要丢掉")],
    "cross-06": [("a", "translation", "预写日志文件变大的走势"),
                 ("b", "terminology", "写前日志越来越大的那条曲线")],
    "cross-07": [("a", "synonym", "信息不确定度的数值")],
    "cross-08": [("a", "synonym", "研墨用的石头文具")],
    "cross-09": [("a", "synonym", "松脂化石做成的宝石")],
    "cross-10": [("a", "terminology", "首字母大写连写的命名写法")],

    # ---- 活动定位里真值是正文的那 5 题 ----
    "loc-14": [("a", "synonym", "第一周留下的那个记号")],
    "loc-15": [("a", "synonym", "第二周留下的那个记号")],
    "loc-16": [("a", "synonym", "第三周留下的那个记号")],
    "loc-17": [("a", "synonym", "第四周留下的那个记号")],
    "loc-18": [("a", "synonym", "好几周里反复出现的那个记号")],
}

KIND_LABEL = {
    "synonym": "同义改写",
    "translation": "中英互译",
    "terminology": "术语换说法",
}


def gen(args):
    source = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    by_id = {q["id"]: q for q in source["queries"]}

    problems = []
    queries = []
    for base_id in sorted(REWRITES):
        base = by_id.get(base_id)
        if base is None:
            problems.append("原题 %s 不在查询集里" % base_id)
            continue
        if base["expect"] != "hit":
            problems.append("%s 不是可答题，不该派生改写题" % base_id)
            continue
        relevant = base.get("relevant") or []
        if not relevant:
            problems.append("%s 的真值为空" % base_id)
            continue
        # 原题的检索词：去掉字段前缀之后就是它
        raw = base["search"]["q"]
        for prefix in ("url:", "host:", "path:", "app:", "title:"):
            if raw.startswith(prefix):
                problems.append("%s 是字段前缀题，不该派生改写题" % base_id)
                raw = raw[len(prefix):]
        term = raw

        for suffix, kind, rewritten in REWRITES[base_id]:
            # 规则 2：改写串里不能含原词，否则 FTS 会照样命中
            if term.lower() in rewritten.lower():
                problems.append("%s-%s 的改写串里含原词「%s」" % (base_id, suffix, term))
            queries.append({
                "id": "%s-%s" % (base_id, suffix),
                "class": base["class"],
                "holdout": base.get("holdout", False),
                "source_id": base_id,
                "rewrite_kind": kind,
                "rewrite_kind_label": KIND_LABEL[kind],
                "original_term": term,
                "q": "%s（%s：原题 %s）" % (rewritten, KIND_LABEL[kind], base_id),
                # 检索串与嵌入串**完全一样**，两条通道量的是同一个查询
                "search": {"q": rewritten, "start": base["search"]["start"],
                           "end": base["search"]["end"], "app": None,
                           "limit": base["search"].get("limit", 10)},
                "embed_text": rewritten,
                "expect": "hit",
                "unanswerable_reason": None,
                # 规则 1：标准答案与原题相同
                "relevant": relevant,
                "relevant_count": len(relevant),
                "answer": base["answer"],
                "answer_check": base["answer_check"],
                "answer_source": "改写题：题面换说法，标准答案抄自原题 %s" % base_id,
                "authored": AUTHORED,
                "notes": "",
            })

    if len(queries) < 40:
        problems.append("改写题只有 %d 道，少于 40 道" % len(queries))
    if problems:
        raise SystemExit("改写题自检失败：\n  - " + "\n  - ".join(problems))

    counts = {}
    for q in queries:
        counts[q["rewrite_kind"]] = counts.get(q["rewrite_kind"], 0) + 1

    out = {
        "schema": SCHEMA,
        "name": "brosis 合成改写题（D8 裁决用）",
        "derived_from": os.path.basename(os.path.expanduser(args.queryset)),
        "corpus": source.get("corpus"),
        "note": ("同一个问题换一种说法，标准答案与原题相同。"
                 "FTS 通道是精确子串语义，换说法之后必然召不回；"
                 "能不能召回全看向量通道，所以这套题就是 D8 说的「明确的高价值失败」。"),
        "rewrite_kind_counts": counts,
        "count": len(queries),
        "authored": AUTHORED,
        "queries": queries,
    }
    path = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    json.dump(out, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps({"out": os.path.basename(path), "count": len(queries),
                      "kinds": counts,
                      "sources": len(set(q["source_id"] for q in queries))},
                     ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen", help="从 60 题查询集派生改写题")
    g.add_argument("--queryset", required=True)
    g.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.cmd == "gen":
        gen(args)


if __name__ == "__main__":
    sys.exit(main())
