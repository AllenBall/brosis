#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 ocr_bench.swift 产出的 JSON 生成 Markdown 报告（仅标准库）。

用法：
    python3 ocr_report.py results/ocr_bench_2026-09-06.json
输出与输入同名的 .md 文件。
"""
import json
import io
import os
import re
import sys

RES_ORDER = ["3456x2234", "2560x1664", "1728x1117"]
RES_NOTE = {
    "3456x2234": "M4 Max 内置屏原生像素（2x）",
    "2560x1664": "MacBook Air 13\" 原生像素",
    "1728x1117": "3456×2234 的 1x（逻辑点）",
}


def pct(x):
    return "%.2f%%" % (x * 100)


def ms(x):
    return "%.1f" % x


def table(header, rows):
    out = ["| " + " | ".join(header) + " |",
           "|" + "|".join(["---"] * len(header)) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def main(path):
    data = json.load(io.open(path, encoding="utf-8"))
    meta, results = data["meta"], data["results"]
    styles = {s["id"]: s for s in meta["styles"]}
    style_ids = [s["id"] for s in meta["styles"]]
    res_by_label = {r["label"]: r for r in meta["resolutions"]}

    def get(style, res, level, lc):
        for r in results:
            if (r["style"] == style and r["resolution"] == res
                    and r["level"] == level and r["language_correction"] == lc):
                return r
        return None

    def eff_font(sid, res):
        return styles[sid]["font_px"] * res_by_label[res]["scale_y"]

    L = []
    A = L.append

    A("# brosis OCR 基准（同源缩放修正版）· %s" % meta["date"])
    A("")
    A("对应实施计划 E8、调研方案评审 F6。本文件由 `tools/bench/ocr_bench.swift` 实测产出，"
      "原始数据见同目录 `%s`，真值文本见 `%s`。"
      % (os.path.basename(path).replace(".md", ".json"),
         "ocr_bench_%s_truth/" % meta["date"]))
    A("")

    # ---------- 1 口径 ----------
    A("## 1. 口径与方法")
    A("")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 机器 | %s |" % meta["hardware"])
    A("| 系统 | macOS %s |" % meta["os_version"])
    A("| 引擎 | Vision `VNRecognizeTextRequest`，revision %d |" % meta["vision_revision"])
    A("| 识别语言 | %s |" % ", ".join(meta["languages"]))
    A("| 基准位图 | %d × %d 像素，CGContext（DeviceRGB, 8 bit/通道, noneSkipFirst） |"
      % (meta["base_pixels"][0], meta["base_pixels"][1]))
    A("| 每组次数 | %d 次，丢弃前 %d 次预热，计入 %d 次 |"
      % (meta["runs_per_config"], meta["warmup_dropped"], meta["measured_runs"]))
    A("| 分位数 | %s |" % meta["percentile_method"])
    A("| 生成时间 | %s |" % meta["generated_at"])
    A("")
    A("**Vision 语言支持（按识别级别实测，不是文档抄写）**")
    A("")
    A("| 级别 | 支持语言数 | 是否含 zh-Hans | 语言列表 |")
    A("|---|---|---|---|")
    A("| accurate | %d | %s | %s |"
      % (len(meta["vision_supported_languages_accurate"]),
         "是" if "zh-Hans" in meta["vision_supported_languages_accurate"] else "**否**",
         "（30 种，含中日韩俄阿泰越等）"))
    A("| fast | %d | %s | %s |"
      % (len(meta["vision_supported_languages_fast"]),
         "是" if "zh-Hans" in meta["vision_supported_languages_fast"] else "**否**",
         ", ".join(meta["vision_supported_languages_fast"])))
    A("")

    # 1.2 同源缩放
    A("### 1.1 同源缩放核实（F6 的核心修正）")
    A("")
    A("v1 的做法是**每个尺寸重新排版一次**，字号固定 26、行距固定 44，"
      "所以 1728×1117 的图天然只有约一半行数，三张图内容不同，耗时不可比。"
      "v2 只在 3456×2234 的 CGContext 上绘制一次，再用 `CGContext.interpolationQuality = .high` "
      "把同一张 `CGImage` 下采样到另外两个尺寸，并打印 `CGImage.width/height` 核实真实像素。")
    A("")
    rows = []
    for r in meta["resolutions"]:
        rows.append([r["label"], "%d × %d" % (r["requested_w"], r["requested_h"]),
                     "**%d × %d**" % (r["cgimage_w"], r["cgimage_h"]),
                     "%.4f × %.4f" % (r["scale_x"], r["scale_y"]),
                     RES_NOTE.get(r["label"], "")])
    A(table(["分辨率标签", "请求像素", "`CGImage.width` × `.height` 实测", "缩放系数 (x × y)", "说明"], rows))
    A("")
    A("> **口径两点说明。** (1) 2560×1664 是 MacBook Air 13\" 的**原生像素**（其 1x 逻辑分辨率是 "
      "1280×832）；这里选它是因为它代表「另一台机器的实际采集像素数」，相对本机 2x 屏是 0.74× 缩放。"
      "真正意义上的「1x」是 1728×1117。(2) 2560×1664 与 3456×2234 的宽高比分别是 1.5385 和 1.5462，"
      "直接拉伸到目标尺寸带来约 **0.55% 的横向拉伸**（x 缩放 0.7407 对 y 缩放 0.7449）。"
      "这个量级对字形识别没有实际影响，但必须写明：三张图是「同一张位图重采样」，"
      "不是「三台设备各自的原生截屏」。")
    A("")

    # 1.3 样式集
    A("### 1.2 样式集（5 种，文本由脚本生成并存盘为真值）")
    A("")
    rows = []
    for sid in style_ids:
        s = styles[sid]
        rows.append([
            "`%s`" % sid, s["name"], s["font_family"],
            "%d" % s["font_px"], "%d" % s["leading_px"], "%d" % s["line_count"],
            "%d" % s["truth_chars"], "%d" % s["truth_chars_no_ws"], "%d" % s["identifier_count"],
            "深底浅字" if s["bg_rgb"][0] < 0.5 else "白底黑字",
        ])
    A(table(["样式 id", "名称", "字体族", "字号 (px @3456 宽)", "行距 (px)", "行数",
             "真值字符数", "去空白字符数", "标识符 token 数", "配色"], rows))
    A("")
    # 样式名括号里写的是设计目标字符数，真值以实际绘制为准；偏差 > 5% 时明确列出
    dev = []
    for sid in style_ids:
        s = styles[sid]
        m = re.search(r"约\s*([0-9]+)\s*字符", s["name"])
        if not m:
            continue
        want, got = int(m.group(1)), s["truth_chars"]
        if want and abs(got - want) / want > 0.05:
            dev.append("`%s` 名义 %d、实测 **%d**（%+.1f%%）" % (sid, want, got, (got - want) / want * 100))
    A("> **样式名里的字符数是设计目标，实际以「真值字符数」列为准**（真值 = 绘制前裁剪好的字符串，"
      "含换行符）。%s" % ("本轮无偏差超过 5% 的样式。" if not dev
                        else "本轮偏差超过 5% 的样式：" + "；".join(dev) + "。"))
    A("")
    A("换算：3456×2234 是 2x 视网膜像素，所以 px 除以 2 就是逻辑 pt。"
      "`code_small` 的 23 px = **11.5 pt**，落在评审要求的 11–12 pt 区间内。")
    A("")
    A("各样式在三种分辨率下的**等效字号（像素高）**：")
    A("")
    rows = []
    for sid in style_ids:
        rows.append(["`%s`" % sid] + ["%.1f px" % eff_font(sid, r) for r in RES_ORDER])
    A(table(["样式"] + ["%s" % r for r in RES_ORDER], rows))
    A("")
    A("标识符 token 是真值里必须被完整找回的片段，覆盖函数名、URL、绝对路径、错误码、"
      "commit 短哈希、金额、版本号、内存地址等。例如："
      "`captureFrame(_:)`、`https://api.brosis.local/v1/ingest`、`/var/log/brosis/daemon.log`、"
      "`kTCCServiceScreenCapture`、`-25300`、`¥2,480.00`、`$128.40`、`0x0000000104f2a1c0`、`a3f9c1e`。")
    A("")

    # 1.4 指标
    A("### 1.3 指标定义")
    A("")
    A("- **CER（严格）**：%s" % meta["cer_definition"])
    A("- **CER（宽度折叠）**：%s" % meta["cer_relaxed_definition"])
    A("- **标识符召回（严格）**：%s" % meta["recall_definition"])
    A("- **标识符召回（宽度折叠）**：%s" % meta["recall_relaxed_definition"])
    A("- **耗时**：`VNImageRequestHandler.perform([request])` 的单调时钟墙钟时间（毫秒），"
      "**不含**绘图与缩放。每组 %d 次，去掉前 %d 次预热。" % (meta["runs_per_config"], meta["warmup_dropped"]))
    A("- 识别文本的阅读顺序由 `boundingBox` 重建：先按归一化 y 中点降序分带（带宽 = 半个行距），"
      "带内按 x 升序拼接，带间换行。")
    A("")
    A("> 为什么要三档 CER：Vision 的中文模型会把半角标点转成全角"
      "（`captureFrame(_:)` → `captureFrame（_：）`）、并吃掉中英文之间的空格"
      "（`AX 优先` → `AX优先`）。这些是**排版规范化**，不是认错字。"
      "严格 CER 把它们全算错，宽度折叠 CER 只留真正认错的字。"
      "做检索时应按宽度折叠口径判断可用性；做原文展示时应按严格口径判断保真度。")
    A("")

    # ---------- 2 结果 ----------
    A("## 2. 结果")
    A("")
    A("### 2.1 accurate 级别总表")
    A("")
    rows = []
    for sid in style_ids:
        for res in RES_ORDER:
            for lc in (True, False):
                r = get(sid, res, "accurate", lc)
                if not r:
                    continue
                rows.append([
                    "`%s`" % sid, res, "%.1f" % eff_font(sid, res),
                    "开" if lc else "关",
                    pct(r["cer"]), pct(r["cer_no_whitespace"]), "**%s**" % pct(r["cer_relaxed"]),
                    "%d/%d" % (r["identifiers_hit"], r["identifiers_total"]),
                    "**%d/%d**" % (r["identifiers_total"] - len(r["identifiers_missed_relaxed"]),
                                   r["identifiers_total"]),
                    ms(r["p50_ms"]), ms(r["p95_ms"]), r["observation_count"],
                ])
    A(table(["样式", "分辨率", "等效字号 px", "语言纠错", "CER 严格", "CER 去空白", "CER 宽度折叠",
             "标识符召回 严格", "标识符召回 宽度折叠", "p50 (ms)", "p95 (ms)", "识别行数"], rows))
    A("")

    A("### 2.2 fast 级别总表")
    A("")
    rows = []
    for sid in style_ids:
        for res in RES_ORDER:
            for lc in (True, False):
                r = get(sid, res, "fast", lc)
                if not r:
                    continue
                rows.append([
                    "`%s`" % sid, res, "%.1f" % eff_font(sid, res),
                    "开" if lc else "关",
                    pct(r["cer"]), "**%s**" % pct(r["cer_relaxed"]),
                    "%d/%d" % (r["identifiers_hit"], r["identifiers_total"]),
                    "**%d/%d**" % (r["identifiers_total"] - len(r["identifiers_missed_relaxed"]),
                                   r["identifiers_total"]),
                    ms(r["p50_ms"]), ms(r["p95_ms"]), r["observation_count"],
                ])
    A(table(["样式", "分辨率", "等效字号 px", "语言纠错", "CER 严格", "CER 宽度折叠",
             "标识符召回 严格", "标识符召回 宽度折叠", "p50 (ms)", "p95 (ms)", "识别行数"], rows))
    A("")

    # 2.3 分辨率横向对比
    A("### 2.3 分辨率横向对比（accurate，语言纠错开）")
    A("")
    rows = []
    for sid in style_ids:
        row = ["`%s`" % sid]
        for res in RES_ORDER:
            r = get(sid, res, "accurate", True)
            row.append("%s / %d of %d" % (pct(r["cer_relaxed"]), r["identifiers_total"] - len(r["identifiers_missed_relaxed"]), r["identifiers_total"]))
        base = get(sid, "3456x2234", "accurate", True)
        one = get(sid, "1728x1117", "accurate", True)
        row.append("%+.2f pp" % ((one["cer_relaxed"] - base["cer_relaxed"]) * 100))
        row.append("%+d" % ((one["identifiers_total"] - len(one["identifiers_missed_relaxed"]))
                            - (base["identifiers_total"] - len(base["identifiers_missed_relaxed"]))))
        rows.append(row)
    A(table(["样式"] + ["%s：CER 折叠 / 标识符" % r for r in RES_ORDER]
            + ["1x 相对 2x 的 CER 变化", "1x 相对 2x 的标识符变化"], rows))
    A("")

    # 2.4 耗时
    A("### 2.4 耗时 p50 / p95（毫秒）")
    A("")
    rows = []
    for sid in style_ids:
        for res in RES_ORDER:
            cells = ["`%s`" % sid, res]
            for level in ("accurate", "fast"):
                for lc in (True, False):
                    r = get(sid, res, level, lc)
                    cells.append("%s / %s" % (ms(r["p50_ms"]), ms(r["p95_ms"])))
            rows.append(cells)
    A(table(["样式", "分辨率", "accurate 纠错开", "accurate 纠错关", "fast 纠错开", "fast 纠错关"], rows))
    A("")
    A("单元格为 `p50 / p95`。")
    A("")

    return "\n".join(L), data, get, eff_font, styles, style_ids


def compute_facts(data):
    """从原始 JSON 直接算出结论里要用的区间，避免手抄。返回 {占位符: 字符串}。"""
    meta, results = data["meta"], data["results"]
    styles = {s["id"]: s for s in meta["styles"]}
    sids = [s["id"] for s in meta["styles"]]

    def get(style, res, level, lc):
        for r in results:
            if (r["style"] == style and r["resolution"] == res
                    and r["level"] == level and r["language_correction"] == lc):
                return r
        return None

    def pairs(level):
        out = []
        for sid in sids:
            for res in RES_ORDER:
                on, off = get(sid, res, level, True), get(sid, res, level, False)
                if on and off:
                    out.append((sid, res, on, off))
        return out

    f = {}

    # 语言纠错的耗时代价与 CER 变化（开 ÷ 关）
    for level, key in (("fast", "fast"), ("accurate", "acc")):
        ps = pairs(level)
        ratios = [(on["p50_ms"] / off["p50_ms"], sid, res) for sid, res, on, off in ps]
        deltas = [((on["cer"] - off["cer"]) * 100, sid, res) for sid, res, on, off in ps]
        lo, hi = min(ratios), max(ratios)
        dlo, dhi = min(deltas), max(deltas)
        f["%s_lc_ratio" % key] = "%.2f×–%.2f×" % (lo[0], hi[0])
        f["%s_lc_ratio_worst" % key] = "%.2f×，出现在 `%s` @ %s" % (hi[0], hi[1], hi[2])
        f["%s_lc_ratio_pct" % key] = "%+.0f%% ~ %+.0f%%" % ((lo[0] - 1) * 100, (hi[0] - 1) * 100)
        f["%s_lc_cer_range" % key] = "%+.2f pp ~ %+.2f pp" % (dlo[0], dhi[0])
        f["%s_lc_cer_best" % key] = "%.2f pp，出现在 `%s` @ %s" % (-dlo[0], dlo[1], dlo[2])
        f["%s_lc_cer_worst" % key] = "%.2f pp，出现在 `%s` @ %s" % (dhi[0], dhi[1], dhi[2])
        f["%s_lc_groups" % key] = "%d" % len(ps)
        # 「输出是否变化」用 JSON 里所有可比指标判定：编辑距离、归一化字符数、识别块数、
        # 漏掉的标识符清单、首行文本，全部相同才算这一组开/关输出一致。
        same = sum(1 for _, _, on, off in ps
                   if (on["edit_distance"], on["hyp_chars_norm"], on["observation_count"],
                       on["identifiers_missed"], on["hyp_head"])
                   == (off["edit_distance"], off["hyp_chars_norm"], off["observation_count"],
                       off["identifiers_missed"], off["hyp_head"]))
        f["%s_lc_same" % key] = "%d/%d" % (same, len(ps))
        f["%s_lc_diff" % key] = "%d/%d" % (len(ps) - same, len(ps))

    # code_small 严格 CER 的三段拆解（严格 → 去空白 → 宽度折叠）
    r = get("code_small", "3456x2234", "accurate", False)
    f["cs_cer_strict"] = "%.2f%%" % (r["cer"] * 100)
    f["cs_cer_nows"] = "%.2f%%" % (r["cer_no_whitespace"] * 100)
    f["cs_cer_relaxed"] = "%.2f%%" % (r["cer_relaxed"] * 100)
    f["cs_pp_ws"] = "%.2f" % ((r["cer"] - r["cer_no_whitespace"]) * 100)
    f["cs_pp_fullwidth"] = "%.2f" % ((r["cer_no_whitespace"] - r["cer_relaxed"]) * 100)
    f["cs_pp_total"] = "%.2f" % ((r["cer"] - r["cer_relaxed"]) * 100)

    # accurate 的耗时分布与「每字符 / 每识别块」成本
    acc = [r for r in results if r["level"] == "accurate"]
    f["acc_p50_range"] = "%.0f–%.0f ms" % (min(r["p50_ms"] for r in acc), max(r["p50_ms"] for r in acc))
    f["acc_p95_range"] = "%.0f–%.0f ms" % (min(r["p95_ms"] for r in acc), max(r["p95_ms"] for r in acc))
    f["acc_p95_p50_max"] = "%.2f" % max(r["p95_ms"] / r["p50_ms"] for r in acc)
    per_char = [(r["p50_ms"] / styles[r["style"]]["truth_chars"], r["style"]) for r in acc]
    dense = [v for v, sid in per_char if sid != "sparse_page"]
    sparse = [v for v, sid in per_char if sid == "sparse_page"]
    f["acc_ms_per_char"] = "%.2f–%.2f ms" % (min(dense), max(dense))
    f["acc_ms_per_char_sparse"] = "%.2f–%.2f ms" % (min(sparse), max(sparse))
    f["acc_ms_per_obs"] = "%.1f–%.1f ms" % (min(r["p50_ms"] / r["observation_count"] for r in acc),
                                            max(r["p50_ms"] / r["observation_count"] for r in acc))
    fastoff = [r for r in results if r["level"] == "fast" and not r["language_correction"]]
    f["fast_off_p50_range"] = "%.1f–%.1f ms" % (min(r["p50_ms"] for r in fastoff),
                                                max(r["p50_ms"] for r in fastoff))
    accon = [r for r in acc if r["language_correction"]]
    rr = [a["p50_ms"] / b["p50_ms"] for a in accon for b in fastoff
          if a["style"] == b["style"] and a["resolution"] == b["resolution"]]
    f["acc_over_fast"] = "1/%.0f 到 1/%.0f" % (max(rr), min(rr))
    return f


if __name__ == "__main__":
    path = sys.argv[1]
    body = main(path)[0]
    concl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ocr_report_conclusions.md")
    if os.path.exists(concl_path):
        concl = io.open(concl_path, encoding="utf-8").read().rstrip()
        facts = compute_facts(json.load(io.open(path, encoding="utf-8")))
        for k, v in facts.items():
            concl = concl.replace("{{%s}}" % k, v)
        left = re.findall(r"\{\{([a-z0-9_]+)\}\}", concl)
        if left:
            raise SystemExit("结论里有未定义的占位符: %s（可用的见 compute_facts）" % sorted(set(left)))
        body += "\n" + concl + "\n"
    out = path[:-5] + ".md" if path.endswith(".json") else path + ".md"
    io.open(out, "w", encoding="utf-8").write(body + "\n")
    print("已写出", out, "%d 字节" % os.path.getsize(out))
