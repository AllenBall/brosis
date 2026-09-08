#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""规模压测：1 / 3 / 12 个月合成库，按 `docs/实施计划.md` 2.4 报体积与延迟（M2 d / T17）。

计划 4.3 的最后一条：「规模压测：1 / 3 / 12 个月合成库，按 2.4 报告延迟」。
2.4 的两行口径：

  * **存储** —— 按 UTF-8 字节分别报告：原文、索引、元数据、WAL、临时空间、缩略图、模型资产；
  * **延迟** —— 分别报告检索服务、嵌入、端到端；**冷 / 热；p50 / p95；在 1 / 3 / 12 个月规模上测**。

本脚本只测**检索服务**那一层（`brosis-store`，不加载任何模型，所以没有嵌入与端到端；
嵌入的数在 `tools/bench/results/m2_c_vectors_2026-09-08.md`）。

    PYTHONDONTWRITEBYTECODE=1 python3 tools/eval/scale_test.py \\
        --bin  ~/Library/Caches/brosis-build/m2-eval-scale-core/release/brosis-store \\
        --work ~/Library/Caches/brosis-build/m2-eval-scale/scale \\
        --results ~/Library/Caches/brosis-build/m2-eval-scale/results \\
        --months 1,3,12

---

## 1. 库是怎么造出来的

`tools/proto/gen_synth_m1.py` 的 E7 最坏口径：每天 **8640** 次捕获（24 h ÷ 10 s）、
平均 **1500** 字符中英混排、30% 是新文本。**按月分文件**生成 → 导入 → 立刻删掉 JSONL，
所以磁盘峰值只有「库 + 一个月的 JSONL」。2026-09-08 实测（`m2_d_eval_scale_2026-09-08.md`
§6.3 / §6.9）：1 / 3 / 12 个月档的**目录磁盘峰值 0.61 / 1.61 / 6.11 GiB**，
其中库文件 0.500 / 1.505 / 6.020 GiB。若改成一次性生成 12 个月的 JSONL，
光 JSONL 就要 7.35 GiB，加上库超过 13 GiB。

两件必须这么做的事：

1. **每个月一个 `--anchor`**，否则 12 段落在同一个月上，时间区间全重叠；
2. **每个月一个种子**（`seed + 月序号`）。同种子会产出**逐字节相同的正文**，
   而存储层按内容去重（`text_versions`），12 个月会塌成 1 个月的正文量——
   库体积会小得离谱，测出来的东西就不是 12 个月了。

导入顺序**从最老的月份开始**：`observations.id` 随时间单调，
才符合检索层「FTS 候选按 rowid 倒序 ≈ 时间倒序」的前提（3.4 / D22）。

## 2. 冷 / 热怎么定义（与 `brosis-store bench` 一致）

| | 定义 |
|---|---|
| 冷 | **全新子进程 + 全新连接**，跑一次就退出。清掉的是 SQLite 自己的页缓存，没有清 macOS 文件缓存（要提权），所以冷数字是**下界** |
| 热 | 同一条连接上预热一次之后连测 N 次 |

`bench` 子命令自己 spawn 子进程做冷测；`week-ledger` / `patterns` / `recent` 三条走
`--reps`（同一进程里第一次是冷、其余是热），冷的分布靠**重复启动进程 N 次各取第一次**得到。

## 3. 机器必须空闲

延迟是在一台**无风扇**的 Air 上量的，旁边跑一个 `swift build` 就能把数字翻倍。
每一档在开测之前先等：1 分钟负载 < `--max-load`（默认 4）**且**没有
`swift-build` / `swift-frontend` / `clang` 进程；最多等 `--max-wait-min`（默认 30）分钟，
等了多久写进结果 JSON 的 `idle_gate`。等不到就照测，但 `idle_gate.timed_out = true`
会一路带到报告里——**带这个标记的数字不能拿去对目标**。
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

MIB = 1 << 20
GIB = 1 << 30
DAY = timedelta(days=1)


def sh(cmd, **kw):
    proc = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if proc.returncode != 0:
        raise SystemExit("命令失败：%s\n%s" % (" ".join(str(c) for c in cmd[:4]),
                                          proc.stderr[-4000:]))
    return proc


def sh_json(cmd, **kw):
    return json.loads(sh(cmd, **kw).stdout)


def timed(cmd):
    """/usr/bin/time -l 包一层，返回 (stdout 的 JSON, real 秒, peak footprint 字节)。"""
    proc = subprocess.run(["/usr/bin/time", "-l"] + [str(c) for c in cmd],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("命令失败：%s\n%s" % (" ".join(str(c) for c in cmd[:4]),
                                          proc.stderr[-4000:]))
    real = peak = None
    for line in proc.stderr.splitlines():
        m = re.match(r"\s*([\d.]+)\s+real", line)
        if m:
            real = float(m.group(1))
        m = re.search(r"(\d+)\s+peak memory footprint", line)
        if m:
            peak = int(m.group(1))
    out = json.loads(proc.stdout) if proc.stdout.strip() else {}
    return out, real, peak


def dir_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def busy_processes():
    proc = subprocess.run(["/bin/ps", "-Ao", "comm"], capture_output=True, text=True)
    names = ("swift-build", "swift-frontend", "clang", "swift-driver", "ld-prime")
    return sorted({n for line in proc.stdout.splitlines()
                   for n in names if os.path.basename(line.strip()) == n
                   or line.strip().endswith("/" + n)})


def wait_idle(max_load, max_wait_min, poll_s=30):
    """开测之前等机器空闲；返回等了多久与最后一次观测。"""
    t0 = time.time()
    deadline = t0 + max_wait_min * 60
    while True:
        load1 = os.getloadavg()[0]
        busy = busy_processes()
        ok = load1 < max_load and not busy
        waited = time.time() - t0
        if ok or time.time() >= deadline:
            return {"waited_s": round(waited, 1), "load1": round(load1, 2),
                    "busy_processes": busy, "max_load": max_load,
                    "max_wait_min": max_wait_min, "idle": ok, "timed_out": (not ok)}
        print("    [等空闲] 负载 %.2f，忙进程 %s，已等 %.0f s"
              % (load1, ",".join(busy) or "无", waited), flush=True)
        time.sleep(poll_s)


# --------------------------------------------------------------------------- #
# 1. 建库
# --------------------------------------------------------------------------- #

def build_tier(args, months, tier_dir):
    """按月生成 → 导入 → 删 JSONL。返回建库过程的全部数字。"""
    os.makedirs(tier_dir, exist_ok=True)
    db = os.path.join(tier_dir, "db")
    key = os.path.join(tier_dir, "db.key")
    base_anchor = datetime(2026, 9, 7, tzinfo=timezone.utc)
    common = ["--dir", db, "--key-file", key]
    if args.quota_bytes:
        common += ["--quota-bytes", str(args.quota_bytes)]
    init = sh_json([args.bin, "init"] + common)

    rows = []
    disk_peak = 0
    for m in range(months):
        anchor = (base_anchor - (months - 1 - m) * args.days * DAY).strftime("%Y-%m-%d")
        seed = args.seed + m
        jsonl = os.path.join(tier_dir, "month_%02d.jsonl" % m)
        meta = os.path.join(tier_dir, "month_%02d.meta.json" % m)
        t0 = time.time()
        gen = sh_json([sys.executable, args.gen, "gen", "--out", jsonl, "--queries", meta,
                       "--days", str(args.days), "--per-day", str(args.per_day),
                       "--avg-chars", str(args.avg_chars), "--seed", str(seed),
                       "--anchor", anchor],
                      env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        gen_s = time.time() - t0
        disk_peak = max(disk_peak, dir_bytes(tier_dir))
        imp, imp_real, imp_peak = timed([args.bin, "import-jsonl"] + common + ["--file", jsonl])
        os.remove(jsonl)
        os.remove(meta)
        rows.append({
            "month": m, "anchor": anchor, "seed": seed,
            "observations": gen["observations"], "jsonl_bytes": gen["jsonl_bytes"],
            "gen_s": round(gen_s, 2),
            "import_s": round(imp["elapsed_s"], 2), "import_real_s": imp_real,
            "import_peak_footprint_bytes": imp_peak,
            "imported": imp["imported"],
            "new_text_versions": imp["new_text_versions"],
            "reused_text_versions": imp["reused_text_versions"],
        })
        print("    [%2d/%2d] %s 导入 %d 条 %.1f s 峰值 %.0f MiB"
              % (m + 1, months, anchor, imp["imported"], imp["elapsed_s"],
                 (imp_peak or 0) / MIB), flush=True)

    maint, maint_real, maint_peak = timed([args.bin, "maintenance"] + common)
    sess, sess_real, sess_peak = timed([args.bin, "sessions"] + common + ["--build", "--tz", args.tz])
    disk_peak = max(disk_peak, dir_bytes(tier_dir))
    return {
        "tier_dir": tier_dir, "db": db, "key": key, "months": months,
        "init": {k: init.get(k) for k in ("page_size", "quota_bytes", "schema_version")},
        "per_month": rows,
        "observations_total": sum(r["imported"] for r in rows),
        "jsonl_bytes_total": sum(r["jsonl_bytes"] for r in rows),
        "gen_s_total": round(sum(r["gen_s"] for r in rows), 1),
        "import_s_total": round(sum(r["import_s"] for r in rows), 1),
        "import_peak_footprint_bytes_max": max(r["import_peak_footprint_bytes"] or 0
                                               for r in rows),
        "maintenance_s": maint_real, "maintenance": maint,
        "sessions_build_s": sess_real, "sessions_build_peak_bytes": sess_peak,
        # `sessions --build` 的输出：total（库里的会话总数）+ build（这一次增量做了什么）
        "sessions": {"total": sess.get("total"), "stale": sess.get("stale"),
                     "build": sess.get("build"), "config": sess.get("config")},
        "dir_bytes_peak": disk_peak,
        "disk_free_after_bytes": free_bytes(tier_dir),
    }


# --------------------------------------------------------------------------- #
# 2. 体积
# --------------------------------------------------------------------------- #

def measure_size(args, tier):
    common = ["--dir", tier["db"], "--key-file", tier["key"]]
    stats = sh_json([args.bin, "stats"] + common + ["--detail"])
    db_file = stats.get("db_file_bytes") or 0
    payload = stats.get("text_payload_bytes") or 0
    out = {"stats": {k: v for k, v in stats.items() if not isinstance(v, list)},
           "dir_bytes": dir_bytes(tier["tier_dir"])}
    for name, key in (("原文（净载荷）", "text_payload_bytes"),
                      ("原文（含 b-tree 开销）", "content_bytes"),
                      ("索引（全部，含 FTS）", "index_bytes"),
                      ("其中全文索引", "fts_bytes"),
                      ("元数据", "metadata_bytes"),
                      ("空闲页", "free_bytes"),
                      ("库文件", "db_file_bytes"),
                      ("WAL", "wal_bytes"),
                      ("SHM", "shm_bytes")):
        n = stats.get(key) or 0
        out.setdefault("breakdown", []).append({
            "项": name, "bytes": n, "MiB": round(n / MIB, 2), "GiB": round(n / GIB, 4),
            "占库文件": round(n / db_file, 4) if db_file else None,
            "对原文净载荷的倍数": round(n / payload, 4) if payload else None,
        })
    out["vector_index_bytes"] = stats.get("vec_bytes")
    out["note_vectors"] = ("本轮没有建向量索引（要加载 mlx 模型，见 T11 的结论：1 个月库 46,545 块"
                           "要 1 小时 32 分），所以「向量」一项是 0 / 未测；"
                           "向量索引的体积口径见 tools/bench/results/m2_c_vectors_2026-09-08.md")
    out["note_thumbs_models"] = "缩略图（D10 默认关）与模型资产不在库里，本轮都是 0"
    return out


# --------------------------------------------------------------------------- #
# 3. 延迟
# --------------------------------------------------------------------------- #

def percentile(xs, p):
    if not xs:
        return None
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(ys) - 1)
    return ys[lo] + (ys[hi] - ys[lo]) * (k - lo)


def reps_tool(args, tier, label, cli, cold_rounds, hot_reps):
    """带 `--reps` 的三条工具：冷 = 重启进程 N 次各取第一次；热 = 一次进程里连测 N 次。"""
    common = ["--dir", tier["db"], "--key-file", tier["key"]]
    cold = []
    for _ in range(cold_rounds):
        out = sh_json([args.bin] + cli[:1] + common + cli[1:] + ["--reps", "1"])
        cold.append(out["cold_ms"])
    hot = sh_json([args.bin] + cli[:1] + common + cli[1:] + ["--reps", str(hot_reps)])
    return {"id": label, "cli": " ".join(str(c) for c in cli),
            "cold_n": len(cold), "cold_p50": percentile(cold, 0.50),
            "cold_p95": percentile(cold, 0.95),
            "hot_n": hot["reps"], "hot_p50": hot["hot_p50_ms"], "hot_p95": hot["hot_p95_ms"],
            "rows": hot.get("rows")}


def measure_latency(args, tier):
    common = ["--dir", tier["db"], "--key-file", tier["key"]]
    gate = wait_idle(args.max_load, args.max_wait_min)
    print("    [空闲] 等了 %.0f s，负载 %.2f%s"
          % (gate["waited_s"], gate["load1"], "（超时，数字带保留）" if gate["timed_out"] else ""),
          flush=True)
    load_before = os.getloadavg()
    bench_out = os.path.join(tier["tier_dir"], "bench.json")
    t0 = time.time()
    bench = sh_json([args.bin, "bench"] + common + ["--tz", args.tz,
                                                    "--cold-rounds", str(args.cold_rounds),
                                                    "--hot-reps", str(args.hot_reps),
                                                    "--out", bench_out])
    bench_s = time.time() - t0

    # M2 c 批那三个工具（周台账 / 活动模式 / 最近活动）：bench 里没有，单独量
    max_ts = int(bench["parameters"]["max_ts"])
    min_ts = int(bench["parameters"]["min_ts"])
    day = 86_400_000
    week_start = max_ts - 7 * day
    tools = [
        reps_tool(args, tier, "week_ledger_cached",
                  ["week-ledger", "--week", bench["parameters"]["ledger_day"], "--tz", args.tz],
                  args.cold_rounds, args.hot_reps),
        reps_tool(args, tier, "patterns_7d",
                  ["patterns", "--start", str(week_start), "--end", str(max_ts + 1),
                   "--tz", args.tz], args.cold_rounds, args.hot_reps),
        reps_tool(args, tier, "patterns_30d",
                  ["patterns", "--start", str(max(min_ts, max_ts - 30 * day)),
                   "--end", str(max_ts + 1), "--tz", args.tz], args.cold_rounds, args.hot_reps),
        reps_tool(args, tier, "recent_30min",
                  ["recent", "--minutes", "30", "--max-items", "20", "--at", str(max_ts),
                   "--tz", args.tz], args.cold_rounds, args.hot_reps),
    ]
    # 测完再看一次：外面有没有别的活儿插进来（本进程自己也会把负载顶上去，
    # 所以这里同时记"忙进程"——那才是外部干扰的证据）。
    after = {"load": [round(x, 2) for x in os.getloadavg()],
             "busy_processes": busy_processes()}
    return {"idle_gate": gate, "bench_elapsed_s": round(bench_s, 1),
            "load_before": [round(x, 2) for x in load_before], "after_measure": after,
            "contended": bool(after["busy_processes"]),
            "bench": bench, "tools": tools}


# --------------------------------------------------------------------------- #
# 4. 主流程
# --------------------------------------------------------------------------- #

def run(args):
    os.makedirs(args.results, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    tiers = [int(x) for x in args.months.split(",")]
    all_out = {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "bin": args.bin, "days_per_month": args.days, "per_day": args.per_day,
               "avg_chars": args.avg_chars, "seed_base": args.seed, "tz": args.tz,
               "cold_rounds": args.cold_rounds, "hot_reps": args.hot_reps,
               "quota_bytes": args.quota_bytes, "tiers": []}
    for months in tiers:
        name = "m%02d" % months
        tier_dir = os.path.join(args.work, name)
        prev_path = os.path.join(args.results, "scale_%s.json" % name)
        if args.reuse and os.path.exists(os.path.join(tier_dir, "db")) and os.path.exists(prev_path):
            # 机器被别的活儿干扰过要**重测**时用：库留着，只把延迟再量一遍。
            print("== %d 个月：复用已有的库，只重测 ==" % months, flush=True)
            tier = json.load(open(prev_path, encoding="utf-8"))["build"]
        else:
            if os.path.exists(tier_dir):
                shutil.rmtree(tier_dir)
            print("== %d 个月：建库 ==" % months, flush=True)
            tier = build_tier(args, months, tier_dir)
        print("== %d 个月：体积 ==" % months, flush=True)
        size = measure_size(args, tier)
        print("== %d 个月：延迟 ==" % months, flush=True)
        lat = measure_latency(args, tier)
        row = {"months": months, "build": tier, "size": size, "latency": lat}
        path = os.path.join(args.results, "scale_%s.json" % name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(row, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
        row["out"] = path
        all_out["tiers"].append(row)
        print("   库文件 %.2f GiB，热 p95 最大 %.2f ms，写到 %s"
              % (size["stats"]["db_file_bytes"] / GIB,
                 lat["bench"]["hot_p95_max_ms"], path), flush=True)
        if not args.keep_db:
            shutil.rmtree(tier_dir)
            print("   已删库释放磁盘（--keep-db 可保留）", flush=True)
    path = os.path.join(args.results, "scale_all.json")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(all_out, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")
    print(json.dumps({"out": path,
                      "tiers": [{"months": t["months"],
                                 "observations": t["build"]["observations_total"],
                                 "db_file_GiB": round(t["size"]["stats"]["db_file_bytes"] / GIB, 4),
                                 "hot_p95_max_ms": t["latency"]["bench"]["hot_p95_max_ms"],
                                 "idle_gate_timed_out": t["latency"]["idle_gate"]["timed_out"]}
                                for t in all_out["tiers"]]}, ensure_ascii=False, indent=1))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    p.add_argument("--bin", required=True)
    p.add_argument("--work", required=True, help="建库用的临时目录（每档跑完就删）")
    p.add_argument("--results", required=True)
    p.add_argument("--gen", default=os.path.join(os.path.dirname(here), "proto", "gen_synth_m1.py"))
    p.add_argument("--months", default="1,3,12")
    p.add_argument("--days", type=int, default=30, help="一个月按几天生成")
    p.add_argument("--per-day", type=int, default=8640)
    p.add_argument("--avg-chars", type=int, default=1500)
    p.add_argument("--seed", type=int, default=20260908, help="第 m 个月用 seed + m")
    p.add_argument("--tz", default="UTC")
    p.add_argument("--cold-rounds", type=int, default=20)
    p.add_argument("--hot-reps", type=int, default=20)
    p.add_argument("--quota-bytes", type=int, default=None,
                   help="不给就是 D7 的默认 10 GiB；12 个月库实测 6.02 GiB（目录峰值 6.11 GiB），"
                        "不会触发 expire")
    p.add_argument("--max-load", type=float, default=4.0)
    p.add_argument("--max-wait-min", type=float, default=30.0)
    p.add_argument("--keep-db", action="store_true",
                   help="每档测完不删库（要重测延迟就得留着，配 --reuse）")
    p.add_argument("--reuse", action="store_true",
                   help="--work 下已经有这一档的库、--results 下有上一次的 JSON 时，跳过建库只重测")
    args = p.parse_args(argv)
    for k in ("bin", "work", "results", "gen"):
        setattr(args, k, os.path.expanduser(getattr(args, k)))
    run(args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
