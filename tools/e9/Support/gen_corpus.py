#!/usr/bin/env python3
# brosis M0 · E9：生成嵌入验证用的测试语料 corpus.json
#
# Swift 侧与 Python 参考侧读同一份 JSON，保证比对的是同样的文本。
# 只用标准库；随机部分固定种子，结果可复现。
#
# 用法：python3 tools/e9/Support/gen_corpus.py > tools/e9/Sources/brosis-e9/corpus.json
import json
import random
import sys

SEED = 20260907

ZH_PAIRS = [
    ("今天下午我在 Xcode 里调试采集模块的崩溃问题。", "下午的时间都花在用 Xcode 排查采集模块崩溃上了。"),
    ("这份可行性报告里写了 OCR 的准确模式耗时。", "可行性报告中记录了 OCR accurate 模式的耗时数据。"),
    ("会议纪要说下周一开始做向量检索的评估。", "纪要里定的是下周一启动向量检索评估工作。"),
    ("屏幕录制权限每个月要重新授权一次。", "系统每月会要求重新授予一次屏幕录制权限。"),
    ("数据库文件不能放在 iCloud Drive 里同步。", "不要把数据库文件放进 iCloud Drive 做同步。"),
    ("嵌入模型只在本机跑，不把正文发到线上。", "嵌入一律本地计算，正文不会外发给线上服务。"),
    ("公司那台是 16 GB 内存的 MacBook Air。", "工作用的机器是内存 16 GB 的 MacBook Air。"),
    ("夜间任务跑完之后要立刻把模型卸载掉。", "模型在夜间任务结束后应当马上释放内存。"),
    ("中文短词在全文检索里容易被漏掉。", "全文索引对中文的一两个字的词经常检索不到。"),
    ("签名用的是 Developer ID 证书并开启强化运行时。", "我们用 Developer ID 签名并启用了 hardened runtime。"),
]

EN_PAIRS = [
    ("The screen recording permission has to be re-approved every month.",
     "macOS asks you to grant screen recording again on a monthly basis."),
    ("Store the SQLite database outside of any file syncing folder.",
     "Keep the SQLite file away from folders that sync across machines."),
    ("Embeddings run locally so no document text leaves the machine.",
     "All embedding happens on device; no body text is sent to a server."),
    ("The build failed because the Metal shader library was missing.",
     "Compilation broke since the metallib for Metal shaders could not be found."),
    ("Unload the language model as soon as the nightly job finishes.",
     "Free the model memory right after the overnight task completes."),
    ("Full text search misses very short Chinese queries.",
     "Queries of one or two Chinese characters are not found by the FTS index."),
    ("The laptop used at work is a MacBook Air with 16 GB of memory.",
     "My office machine is a 16 GB MacBook Air."),
    ("We sign the app with a Developer ID certificate and hardened runtime.",
     "The application is signed using Developer ID plus the hardened runtime option."),
    ("Resume the download from the byte offset already written to disk.",
     "Continue fetching the file starting at the offset that was saved."),
    ("Verify the SHA-256 checksum of every downloaded weight file.",
     "Check each weight file against its SHA-256 digest after downloading."),
]

CROSS_PAIRS = [
    ("屏幕录制权限每个月要重新授权一次。", "The screen recording permission must be re-granted once a month."),
    ("数据库文件不能放在 iCloud Drive 里同步。", "The database file must not be placed inside iCloud Drive for syncing."),
    ("嵌入模型只在本机跑，不把正文发到线上。", "The embedding model runs locally and never sends body text online."),
    ("构建失败是因为找不到 Metal 着色器库。", "The build failed because the Metal shader library could not be located."),
    ("夜间任务跑完之后要立刻把模型卸载掉。", "Unload the model immediately after the nightly job is done."),
    ("中文短词在全文检索里容易被漏掉。", "Short Chinese terms are easily missed by full text search."),
    ("公司那台是 16 GB 内存的 MacBook Air。", "The work machine is a MacBook Air with 16 GB of RAM."),
    ("下载中断后要能从已写入的字节继续。", "After an interrupted download it must resume from the bytes already written."),
    ("每个权重文件都要校验 SHA-256。", "Every weight file has to be verified against its SHA-256 hash."),
    ("推荐清单随 app 打包，运行时不联网拉取。", "The recommendation list ships with the app and is never fetched at runtime."),
]

UNRELATED_PAIRS = [
    ("今天下午我在 Xcode 里调试采集模块的崩溃问题。", "楼下那家川菜馆的水煮鱼分量很足。"),
    ("The build failed because the Metal shader library was missing.", "She planted three rows of tulips along the south fence."),
    ("数据库文件不能放在 iCloud Drive 里同步。", "The ferry to the island leaves at a quarter past six."),
    ("嵌入模型只在本机跑，不把正文发到线上。", "上周末去爬了香山，红叶还没全红。"),
    ("Verify the SHA-256 checksum of every downloaded weight file.", "他小时候学过四年小提琴，后来就放下了。"),
    ("夜间任务跑完之后要立刻把模型卸载掉。", "The bakery on the corner sells sourdough only on Fridays."),
    ("中文短词在全文检索里容易被漏掉。", "台风过境之后，海边的栈道被冲坏了一段。"),
    ("We sign the app with a Developer ID certificate and hardened runtime.", "冰箱里还剩两个鸡蛋和半盒牛奶。"),
    ("公司那台是 16 GB 内存的 MacBook Air。", "The referee showed a yellow card in the eighty-second minute."),
    ("推荐清单随 app 打包，运行时不联网拉取。", "他养的那只橘猫最近胖了不少。"),
]

APPS = ["Xcode", "Safari", "Chrome", "飞书", "微信", "VS Code", "Obsidian", "Terminal",
        "Preview", "Notes", "Slack", "钉钉", "Numbers", "预览", "系统设置"]
FILES = ["Downloader.swift", "Embedder.swift", "schema.sql", "实施计划.md", "ocr_bench.py",
         "Package.swift", "build_app.sh", "catalog.json", "fts_compare.py", "main.swift",
         "调研方案评审.md", "AppDelegate.swift", "Storage.swift", "index.html", "notes.txt"]
TOPICS_ZH = ["向量检索评估", "OCR 基准", "全文检索方案", "模型下载器", "公证流程", "屏幕采集权限",
             "会话切分", "台账口径", "iCloud 同步", "内存峰值", "热降频", "断点续传",
             "哈希校验", "排除清单", "菜单栏状态"]
TOPICS_EN = ["vector search evaluation", "OCR benchmark", "full text search", "model downloader",
             "notarization", "screen capture permission", "session segmentation", "ledger",
             "iCloud sync", "peak memory", "thermal throttling", "range resume",
             "checksum verification", "exclusion list", "menu bar status"]
PEOPLE = ["张伟", "李娜", "王磊", "陈静", "Alex", "Maria", "刘洋", "赵敏"]
ACTIONS_ZH = ["编译通过", "跑了一遍基准", "改了参数", "定稿", "回滚了一次", "补了单元测试",
              "记录了耗时", "对齐了口径", "重新授权", "导出了结果"]


def make_docs(rng, n):
    docs = []
    kinds = ["code", "chat", "web", "doc", "term", "meeting"]
    for i in range(n):
        k = kinds[i % len(kinds)]
        app = rng.choice(APPS)
        if k == "code":
            docs.append(f"{app} — brosis/tools/{rng.choice(['e9','bench','proto','probe'])}/"
                        f"{rng.choice(FILES)}:{rng.randint(10, 900)}  "
                        f"{rng.choice(ACTIONS_ZH)}，{rng.choice(TOPICS_ZH)}相关")
        elif k == "chat":
            docs.append(f"{app} · 群聊「brosis 研发」 {rng.choice(PEOPLE)}："
                        f"{rng.choice(TOPICS_ZH)}那块{rng.choice(ACTIONS_ZH)}了，"
                        f"{rng.randint(1,28)} 号之前给结论")
        elif k == "web":
            docs.append(f"{app} — {rng.choice(TOPICS_EN)} · "
                        f"{rng.choice(['Hugging Face','GitHub','Apple Developer','Stack Overflow','arXiv'])}"
                        f" — {rng.choice(TOPICS_ZH)}")
        elif k == "doc":
            docs.append(f"{app} — {rng.choice(['docs/实施计划.md','docs/可行性调研报告.md','docs/调研方案评审.md'])}"
                        f" 第 {rng.randint(1,12)}.{rng.randint(1,9)} 节 {rng.choice(TOPICS_ZH)}"
                        f"（{rng.choice(TOPICS_EN)}）")
        elif k == "term":
            docs.append(f"Terminal — $ swift build -c release  "
                        f"{rng.choice(['Build complete','error: cannot find','warning: deprecated'])}"
                        f" ({rng.randint(1,300)}.{rng.randint(10,99)}s)  {rng.choice(TOPICS_EN)}")
        else:
            docs.append(f"{app} — {rng.randint(9,18)}:{rng.choice(['00','15','30','45'])} "
                        f"{rng.choice(PEOPLE)} 主持的{rng.choice(TOPICS_ZH)}评审，"
                        f"结论：{rng.choice(ACTIONS_ZH)}；下一步 {rng.choice(TOPICS_EN)}")
    return docs


def make_queries(rng, docs, n):
    templates_zh = [
        "我上次在哪里看到关于{t}的内容？",
        "{t}那件事最后是什么结论？",
        "谁在讨论{t}？",
        "关于{t}我记了什么？",
    ]
    templates_en = [
        "where did I read about {t}?",
        "what was the conclusion on {t}?",
        "notes about {t}",
        "{t} status",
    ]
    qs = []
    for i in range(n):
        if i % 2 == 0:
            qs.append(rng.choice(templates_zh).format(t=rng.choice(TOPICS_ZH)))
        else:
            qs.append(rng.choice(templates_en).format(t=rng.choice(TOPICS_EN)))
    return qs


ZH_FILLER = ("采集端把当前窗口的标题、路径和可见正文写进本地数据库，不保存画面本身；"
             "夜间任务在接电且空闲时才启动，跑完立刻释放模型占用的内存。")
EN_FILLER = ("The collector writes window titles, paths and visible text into a local database "
             "and never keeps pixels; the nightly job only runs on AC power while idle. ")


def make_throughput(rng, n, target_chars=500):
    out = []
    for i in range(n):
        s = ""
        j = 0
        while len(s) < target_chars:
            s += ZH_FILLER if (i + j) % 2 == 0 else EN_FILLER
            s += f" #{i}-{j} {rng.choice(TOPICS_EN)} / {rng.choice(TOPICS_ZH)}。"
            j += 1
        out.append(s[:target_chars])
    return out


def main():
    rng = random.Random(SEED)
    docs = make_docs(rng, 200)
    queries = make_queries(rng, docs, 40)
    corpus = {
        "seed": SEED,
        "queryInstruction": "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:",
        "pairs": {
            "zh_synonym": ZH_PAIRS,
            "en_synonym": EN_PAIRS,
            "cross_lingual": CROSS_PAIRS,
            "unrelated": UNRELATED_PAIRS,
        },
        "mrl": {"docs": docs, "queries": queries},
        "throughput": make_throughput(rng, 16),
        "crosscheck": (
            [p[0] for p in ZH_PAIRS[:5]]
            + [p[0] for p in EN_PAIRS[:5]]
            + docs[:5]
            + queries[:5]
        ),
    }
    json.dump(corpus, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
