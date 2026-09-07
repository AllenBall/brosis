#!/usr/bin/env python3
# brosis M0 · E9：把各步骤的中间 JSON 汇总成一份结果文件
#
# 用法：python3 tools/e9/Support/assemble_results.py > tools/bench/results/e9_runtime_2026-09-07.json
#
# 中间产物都在 ~/Library/Caches/brosis-build/e9/results/，不落在 iCloud 项目目录。
import json
import os
import re
import subprocess
import sys

R = os.path.expanduser("~/Library/Caches/brosis-build/e9/results")
APP = os.path.expanduser("~/Library/Caches/brosis-build/e9/brosis-e9.app")
MIB = 1 << 20
GIB = 1 << 30


def load(name):
    p = os.path.join(R, name)
    return json.load(open(p)) if os.path.exists(p) else None


def text(name):
    p = os.path.join(R, name)
    return open(p).read() if os.path.exists(p) else None


def time_l(name):
    """从 /usr/bin/time -l 的 stderr 里抠出内存两项。

    评审 F8：Apple Silicon 统一内存下 Metal 缓冲计入 phys_footprint 而不计入 RSS，
    批量推理时 RSS 会低估约 8 倍，所以两项都要留。
    """
    t = text(name)
    if not t:
        return None
    out = {}
    for key, label in (
        ("peakResidentBytes", "maximum resident set size"),
        ("peakFootprintBytes", "peak memory footprint"),
        ("realSeconds", "real"),
    ):
        if label == "real":
            m = re.search(r"([\d.]+)\s+real", t)
            if m:
                out[key] = float(m.group(1))
            continue
        m = re.search(r"(\d+)\s+" + label, t)
        if m:
            out[key] = int(m.group(1))
    for k in ("peakResidentBytes", "peakFootprintBytes"):
        if k in out:
            out[k.replace("Bytes", "MiB")] = out[k] / MIB
    return out


def embed_runs():
    """5 次热态 embed 的原始记录（结果 JSON + /usr/bin/time -l 输出）。

    上一轮这 5 个数字没有落盘、不可追溯，本轮补上。
    """
    runs = []
    for i in range(1, 6):
        d = load("embed_%d.json" % i)
        if not d:
            continue
        runs.append({
            "run": i,
            "secondsFromProcessStartToFirstVector": d["secondsFromProcessStartToFirstVector"],
            "containerLoadSeconds": d["loadSeconds"],
            "dimension": d["dimension"],
            "first8": d["first8"],
            "gpuMemoryConfig": d.get("gpuMemoryConfig"),
            "memory": d["memory"],
            "timeMinusL": time_l("embed_%d_stderr.txt" % i),
        })
    if not runs:
        return None
    secs = [r["secondsFromProcessStartToFirstVector"] for r in runs]
    ident = all(r["first8"] == runs[0]["first8"] for r in runs)
    return {
        "note": "热态（页缓存已暖）。真冷启动要 sudo purge 或重启后跑，见 blockers。",
        "runs": runs,
        "secondsMin": min(secs),
        "secondsMax": max(secs),
        "secondsMean": sum(secs) / len(secs),
        "first8IdenticalAcrossRuns": ident,
        "peakFootprintMiB": max(r["timeMinusL"]["peakFootprintMiB"] for r in runs),
        "peakResidentMiB": max(r["timeMinusL"]["peakResidentMiB"] for r in runs),
        "gpuPeakMiB": max(r["memory"]["gpuPeakMiB"] for r in runs),
    }


def cache_limit_runs():
    """限制 MLX 缓冲池后的重跑：给 M1 夜间任务『跑完立刻释放』和 Air 16 GiB 可行性做依据。"""
    out = []
    for mib in (None, 1024, 256, 0):
        name = "bench_signed_app" if mib is None else "bench_cachelimit_%d" % mib
        d = load(name + ".json")
        if not d:
            continue
        t = d["throughput"]
        out.append({
            "cacheLimitMiB": "默认（= memoryLimit，实测不限）" if mib is None else mib,
            "peakFootprintBytes": d["peakFootprintBytes"],
            "peakFootprintMiB": d["peakFootprintMiB"],
            "peakFootprintGiB": d["peakFootprintBytes"] / GIB,
            "peakResidentBytes": d["peakResidentBytes"],
            "peakResidentMiB": d["peakResidentMiB"],
            "gpuPeakMiB": d["gpuPeakMiB"],
            "gpuCacheAtEndMiB": d["memoryAtEnd"]["gpuCacheMiB"],
            "textsPerSecond": t["textsPerSecond"],
            "tokensPerSecond": t["tokensPerSecond"],
            "secondsPerBatchMean": t["secondsPerBatch"]["mean"],
            "timeMinusL": time_l(name + "_stderr.txt"),
        })
    return out or None


def bundle_sizes(app):
    out = {}
    total = 0
    for root, _, files in os.walk(app):
        for f in files:
            fp = os.path.join(root, f)
            if os.path.islink(fp):
                continue
            s = os.path.getsize(fp)
            out[os.path.relpath(fp, app)] = s
            total += s
    return total, out


def main():
    total, files = bundle_sizes(APP)
    dl = load("download.json")
    mirror = load("download_mirror.json")
    bench_app = load("bench_signed_app.json")
    bench_cli = load("bench_cli.json")
    py = load("crosscheck_python.json")
    imp = load("import.json")
    gen = load("generate_gemma4.json")

    exe = files.get("Contents/MacOS/brosis-e9", 0)
    metallib = files.get("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib", 0)

    result = {
        "experiment": "E9 内嵌推理运行时、模型管理器与分发验证",
        "date": "2026-09-07",
        "plan": ["4.1 E9", "3.11", "D18", "D19", "附录 A E9", "报告 11.2 第 7 条"],
        "unitsNote": "MiB = 2^20 字节，GiB = 2^30 字节；HF 页面上的 GB 是 10^9，两者不要混。",
        "machine": bench_app["environment"] if bench_app else None,
        "toolchain": {
            "xcode": "26.6 (17F113)",
            "swift": "6.3.3",
            "mlx-swift-lm": "3.31.4",
            "mlx-swift": "0.31.6（内含 MLX_VERSION 0.31.1）",
            "swift-transformers": "1.3.4",
            "swiftPMProducts": ["MLXEmbedders", "MLXLMCommon", "MLXLLM", "Tokenizers"],
            "pythonReference": "LM Studio 自带 venv：Python 3.11.9 / mlx 0.31.2 / mlx-lm 0.31.3 / transformers 5.8.1（本机已有，未下载）",
        },
        "sizes": {
            "appTotalBytes": total,
            "appTotalMiB": total / MIB,
            "executableBytes": exe,
            "executableMiB": exe / MIB,
            "metallibBytes": metallib,
            "metallibMiB": metallib / MIB,
            "runtimeBytes": exe + metallib,
            "runtimeMiB": (exe + metallib) / MIB,
            "modelBytes": dl["totalBytes"] if dl else None,
            "modelMiB": dl["totalMiB"] if dl else None,
            "modelGiB": (dl["totalBytes"] / GIB) if dl else None,
            "files": files,
            "note": "metallib 是从本机 MLX 0.31.2 Python wheel 借来的全量（非 JIT）版本，是上限；"
                    "mlx-swift 自己是 JIT 构建，只预编 9 个基础 kernel，装了 Metal Toolchain 后应显著更小。",
        },
        "download": dl,
        "downloadMirror": mirror,
        "localImport": imp,
        "memoryFootprint": {
            "note": "评审 F8 口径修正。Apple Silicon 统一内存里 Metal 缓冲（含 MLX 缓冲池）计入进程的 "
                    "phys_footprint 而不计入 resident set size，批量嵌入时两者差约 8 倍。"
                    "『内存峰值』一律以 peak memory footprint 为准，RSS 只作参考。",
            "singleEmbed": embed_runs(),
            "byCacheLimit": cache_limit_runs(),
            "cacheReleaseAtEnd": bench_app.get("cacheRelease") if bench_app else None,
            "memorySnapshotsDefaultRun": {
                k: bench_app[k] for k in (
                    "memoryBeforeLoad", "memoryAfterLoad", "memoryAfterFirstVector",
                    "memoryAtEnd", "memoryAfterCacheRelease")
                if bench_app and k in bench_app
            } if bench_app else None,
        },
        "benchFromSignedApp": bench_app,
        "benchFromSignedAppTimeMinusL": time_l("bench_signed_app_stderr.txt"),
        "benchFromCLIBinary": bench_cli,
        "benchFromCLIBinaryTimeMinusL": time_l("bench_cli_stderr.txt"),
        "envSignedApp": load("env_signed_app.json"),
        "verify": load("verify.json"),
        "pythonCrossCheck": py,
        "generation": gen,
        "codesign": {
            "identity": os.environ.get("IDENTITY", "Developer ID Application: <Company> (<TEAMID>)"),
            "options": "runtime（hardened runtime）+ --timestamp + --generate-entitlement-der",
            "entitlements": "无（空）",
            "dv": text("codesign_dv.txt"),
            "verifyDeepStrict": text("codesign_verify.txt"),
            "spctl": text("spctl.txt"),
        },
        "notarization": {
            "keychainProfile": "brosis",
            "available": False,
            "error": (text("notarytool.txt") or "").strip(),
        },
        "systemProxy": text("proxy.txt"),
    }
    json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
