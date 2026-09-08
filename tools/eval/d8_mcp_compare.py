#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E2 一致性：经 MCP 的 search 与直接调 Store.search 必须逐题相同（计划 3.4 / 3.6 / 4.3.2 T15）。

c 批把向量通道做进了 `Store.search`，但**查询向量要调用方算好塞进来**，
所以经 `brosis-mcp` 过来的查询一律 `no_query_vector`（c 批结果文件第 9 节第 1 条）。
d 批 T15 在 `StoreMCPService` 上挂了一个可注入的查询嵌入器，app 侧的 IPC 服务端注入它。
这个脚本量的就是「接上之后，MCP 这条路与直接调用是不是同一个结果」。

两条路：

| 路 | 谁算查询向量 | 谁查库 |
|---|---|---|
| 直接 | `brosis-embed queries --batch 1`（离线算好一张表） | `brosis-store search-batch --vectors --query-vectors <表>` |
| MCP  | **服务端自己算**（`MLXQueryEmbedder`，批构造同样是 1） | `brosis-mcp` → 本地 IPC → `StoreMCPService.search` → `Store.search` |

MCP 那条走的是**真实链路**：真的 `brosis-mcp` 二进制、真的 unix socket、真的
`MCPGate` + `StoreMCPService` + grant + 审计。唯一的替身是服务端进程：
产品里它在 `brosis.app`（要 GUI 与钥匙串），这里用 `brosis-embed serve-search`
（同一份 `MLXQueryEmbedder` + 同一个 `StoreMCPService` + 同一个 `IPCServer`，
差别只有 FileKeyProvider、写死 unlocked、可跳过对端签名校验；理由见那个子命令的注释）。

**两边必须对齐的四件事**（对不齐就不是在量同一个东西）：
  1. 嵌入的文本：都用 `search.q`（不要 `embed_text`），服务端拿到的就是 `q`；
  2. 批构造：都为 1（E9 已知限制：换批大小向量会差 1e-3 量级）；
  3. 时间窗：grant 的窗口是硬下界，MCP 一定会带一个 `start`，
     所以直接那条也传同一个 `start`，让两边的候选窗口口径一致
     （`RetrievalOptions` 对"带过滤"的查询用更大的候选窗）；
  4. limit：都取题目里的 limit（默认 10）。

    PYTHONDONTWRITEBYTECODE=1 python3 d8_mcp_compare.py \\
        --queryset <qs.json> --dir <库> --key-file <密钥> --models-dir <模型根目录> \\
        --store <brosis-store> --embed <brosis-embed> --mcp <brosis-mcp> \\
        --out <结果.json> --label 改写题
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time

# 硬约束：项目目录里不许出现 __pycache__ / *.pyc。命令行一律加 PYTHONDONTWRITEBYTECODE=1，
# 这里再上一道保险——下面 import 的是同目录的 d8_compare，忘了加环境变量就会写出 .pyc。
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d8_compare import score, K            # noqa: E402  指标口径与 D8 那份完全一致

ENVELOPE = re.compile(r"<brosis:evidence>\n(.*)\n</brosis:evidence>", re.S)
# grant 的时间窗：取得足够大，好让「MCP 一定带 start」这件事不改变结果集。
GRANT_WINDOW_DAYS = 3650


def run(cmd, **kw):
    proc = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if proc.returncode != 0:
        raise SystemExit("命令失败（%d）：%s\n%s\n%s"
                         % (proc.returncode, " ".join(cmd), proc.stdout[-2000:],
                            proc.stderr[-2000:]))
    return proc


def wait_for_socket(path, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(path)
                s.close()
                return True
            except OSError:
                pass
            finally:
                s.close()
        time.sleep(0.2)
    return False


class MCPClient:
    """真的把 brosis-mcp 当 MCP 服务端用：JSON-RPC 2.0，换行分隔，走 stdio。"""

    def __init__(self, binary, socket_path, client_id):
        env = dict(os.environ)
        env["BROSIS_CLIENT_ID"] = client_id
        self.proc = subprocess.Popen(
            [binary, "--socket", socket_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env, bufsize=1)
        self.next_id = 0
        self.initialize(client_id)

    def call(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method,
                   "params": params or {}}
        self.proc.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise SystemExit("brosis-mcp 没有回应（stderr）：" + self.proc.stderr.read()[-2000:])
        return json.loads(line)

    def initialize(self, client_id):
        self.call("initialize", {"protocolVersion": "2025-06-18",
                                 "clientInfo": {"name": client_id, "version": "0"},
                                 "capabilities": {}})
        self.next_id += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0",
                                          "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()

    def search(self, args):
        t0 = time.time()
        response = self.call("tools/call", {"name": "search", "arguments": args})
        wall = (time.time() - t0) * 1000
        result = response.get("result") or {}
        text = (result.get("content") or [{}])[0].get("text", "")
        if result.get("isError"):
            raise SystemExit("MCP search 失败：" + text)
        match = ENVELOPE.search(text)
        if not match:
            raise SystemExit("MCP 返回里找不到证据分隔符：" + text[:500])
        payload = json.loads(match.group(1))
        payload["_client_wall_ms"] = wall
        return payload

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:                                    # noqa: BLE001
            self.proc.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--queryset", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--models-dir", required=True)
    parser.add_argument("--store", required=True, help="brosis-store 可执行文件")
    parser.add_argument("--embed", required=True, help="brosis-embed 可执行文件")
    parser.add_argument("--mcp", required=True, help="brosis-mcp 可执行文件")
    parser.add_argument("--socket", default=None, help="默认 <workdir>/mcp.sock")
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", default="")
    parser.add_argument("--client", default="d8-mcp-compare")
    parser.add_argument("--skip-vectors", action="store_true",
                        help="只对照 FTS-only（不给向量），用来证明没有向量时两边也一致")
    args = parser.parse_args()

    queryset = json.load(open(os.path.expanduser(args.queryset), encoding="utf-8"))
    queries = queryset["queries"]
    out_path = os.path.expanduser(args.out)
    workdir = os.path.expanduser(args.workdir or os.path.dirname(out_path))
    os.makedirs(workdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(out_path))[0]
    directory = os.path.expanduser(args.dir)
    key_file = os.path.expanduser(args.key_file)
    models_dir = os.path.expanduser(args.models_dir)
    socket_path = os.path.expanduser(args.socket or os.path.join(workdir, "mcp.sock"))

    # MCP 一定会给一个 start（grant 的时间窗是硬下界），所以直接那条也传同一个，
    # 两边的候选窗口口径才一致。取"现在往回 GRANT_WINDOW_DAYS 天"，覆盖整个语料。
    window_start = int(time.time() * 1000) - GRANT_WINDOW_DAYS * 86_400_000

    # ---- 1. 查询向量（批构造 1，用 search.q 而不是 embed_text）----
    qbatch = os.path.join(workdir, stem + "_qbatch.json")
    qvec = os.path.join(workdir, stem + "_qvec.json")
    json.dump([{"id": q["id"], "q": q["search"]["q"]} for q in queries],
              open(qbatch, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    queries_report = {}
    if not args.skip_vectors:
        proc = run([os.path.expanduser(args.embed), "queries", "--file", qbatch,
                    "--out", qvec, "--models-dir", models_dir, "--dir", directory,
                    "--batch", "1"])
        queries_report = json.loads(proc.stdout)

    # ---- 2. 直接路径：brosis-store search-batch ----
    batch = os.path.join(workdir, stem + "_batch.json")
    json.dump([{"id": q["id"], "q": q["search"]["q"],
                "start": q["search"]["start"] or window_start,
                "end": q["search"]["end"], "app": q["search"]["app"],
                "limit": max(K, q["search"].get("limit") or K)} for q in queries],
              open(batch, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    direct_out = os.path.join(workdir, stem + "_direct.json")
    cmd = [os.path.expanduser(args.store), "search-batch", "--dir", directory,
           "--key-file", key_file, "--file", batch, "--out", direct_out, "--tz", "UTC"]
    if not args.skip_vectors:
        cmd += ["--vectors", "--query-vectors", qvec]
    t0 = time.time()
    run(cmd)
    direct_wall = time.time() - t0
    direct_rows = {row["id"]: row
                   for row in json.load(open(direct_out, encoding="utf-8"))["results"]}

    # ---- 3. MCP 路径：serve-search（注入嵌入器）+ 真的 brosis-mcp ----
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    serve_out = os.path.join(workdir, stem + "_serve.json")
    serve_log = open(os.path.join(workdir, stem + "_serve.log"), "w", encoding="utf-8")
    serve_cmd = [os.path.expanduser(args.embed), "serve-search", "--dir", directory,
                 "--key-file", key_file, "--models-dir", models_dir,
                 "--socket", socket_path, "--tz", "UTC", "--rate", "100000",
                 "--skip-codesign", "--out", serve_out]
    if args.skip_vectors:
        serve_cmd.append("--no-vectors")
    server = subprocess.Popen(serve_cmd, stdout=serve_log, stderr=serve_log, text=True)
    mcp_rows, embed_ms, client_ms = {}, [], []
    try:
        if not wait_for_socket(socket_path):
            raise SystemExit("serve-search 的 socket 没起来，见 " + serve_log.name)
        run([os.path.expanduser(args.mcp), "admin", "grant", "add",
             "--client", args.client, "--socket", socket_path,
             "--apps", "*", "--time-window", str(GRANT_WINDOW_DAYS), "--fields", "summary"])
        client = MCPClient(os.path.expanduser(args.mcp), socket_path, args.client)
        t0 = time.time()
        for q in queries:
            call_args = {"q": q["search"]["q"],
                         "limit": max(K, q["search"].get("limit") or K)}
            if q["search"]["start"] is not None:
                call_args["start"] = q["search"]["start"]
            if q["search"]["end"] is not None:
                call_args["end"] = q["search"]["end"]
            if q["search"]["app"]:
                call_args["app"] = q["search"]["app"]
            payload = client.search(call_args)
            mcp_rows[q["id"]] = {
                "id": q["id"],
                "evidence_ids": [h["evidenceID"] for h in payload.get("hits", [])],
                "channels": payload.get("channels"),
                "fusion": payload.get("fusion"),
                "vectors_unavailable": payload.get("vectorsUnavailable"),
                "vector_unavailable_reason": payload.get("vectorUnavailableReason", ""),
                "vector_candidates": payload.get("vectorCandidates"),
                "vector_best_distance": payload.get("vectorBestDistance", -1),
                "elapsed_ms": payload.get("elapsedMS"),
                "query_embed": payload.get("queryEmbed"),
                "applied_start": payload.get("appliedStart"),
                "client_wall_ms": payload["_client_wall_ms"],
            }
            timing = payload.get("queryEmbed") or {}
            if timing.get("elapsedMS") is not None:
                embed_ms.append(timing["elapsedMS"])
            client_ms.append(payload["_client_wall_ms"])
        mcp_wall = time.time() - t0
        client.close()
    finally:
        server.terminate()
        try:
            server.wait(timeout=30)
        except subprocess.TimeoutExpired:
            server.kill()
        serve_log.close()
    serve_stats = json.load(open(serve_out, encoding="utf-8")) if os.path.exists(serve_out) else {}

    # ---- 4. 逐题对照 ----
    differences = []
    for q in queries:
        a = direct_rows.get(q["id"], {})
        b = mcp_rows.get(q["id"], {})
        ids_a = list(a.get("evidence_ids") or [])[:K]
        ids_b = list(b.get("evidence_ids") or [])[:K]
        if ids_a != ids_b or a.get("fusion") != b.get("fusion"):
            differences.append({
                "id": q["id"],
                "direct_ids": ids_a, "mcp_ids": ids_b,
                "direct_fusion": a.get("fusion"), "mcp_fusion": b.get("fusion"),
                "direct_reason": a.get("vector_unavailable_reason"),
                "mcp_reason": b.get("vector_unavailable_reason"),
            })

    direct_summary, direct_per = score(queries, direct_rows)
    mcp_summary, mcp_per = score(queries, mcp_rows)
    metric_keys = ("recall_at_10", "precision_at_10", "mrr_at_10", "answered_at_all",
                   "false_positives")
    metrics_equal = all(direct_summary[k] == mcp_summary[k] for k in metric_keys)
    per_query_equal = all(
        (a["recall_at_k"] == b["recall_at_k"] and a["mrr_at_k"] == b["mrr_at_k"])
        for a, b in zip(sorted(direct_per, key=lambda r: r["id"]),
                        sorted(mcp_per, key=lambda r: r["id"])))

    def pct(values, p):
        if not values:
            return None
        s = sorted(values)
        return round(s[min(len(s) - 1, int(len(s) * p))], 3)

    out = {
        "label": args.label or os.path.basename(os.path.expanduser(args.queryset)),
        "queryset": os.path.basename(os.path.expanduser(args.queryset)),
        "queryset_count": len(queries),
        "k": K,
        "vectors": not args.skip_vectors,
        "grant_window_days": GRANT_WINDOW_DAYS,
        "window_start_ms": window_start,
        "identical": len(differences) == 0 and metrics_equal and per_query_equal,
        "identical_queries": len(queries) - len(differences),
        "differences": differences,
        "metrics_equal": metrics_equal,
        "per_query_equal": per_query_equal,
        "direct": direct_summary,
        "mcp": mcp_summary,
        "query_embed_ms": {
            "n": len(embed_ms),
            "p50": pct(embed_ms, 0.50), "p95": pct(embed_ms, 0.95),
            "max": round(max(embed_ms), 3) if embed_ms else None,
            "budget": 150,
            "within_budget": (pct(embed_ms, 0.95) or 0) <= 150,
        },
        "mcp_client_wall_ms": {"p50": pct(client_ms, 0.50), "p95": pct(client_ms, 0.95)},
        "wall_seconds": {"direct": round(direct_wall, 3), "mcp": round(mcp_wall, 3)},
        "serve_search": serve_stats,
        "queries_command": queries_report,
        "per_query": {"direct": direct_per, "mcp": mcp_per, "mcp_raw": mcp_rows},
    }
    json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    brief = {k: out[k] for k in ("label", "queryset_count", "vectors", "identical",
                                 "identical_queries", "metrics_equal", "per_query_equal",
                                 "query_embed_ms", "mcp_client_wall_ms", "wall_seconds")}
    brief["direct"] = {k: v for k, v in direct_summary.items() if not isinstance(v, dict)}
    brief["mcp"] = {k: v for k, v in mcp_summary.items() if not isinstance(v, dict)}
    brief["differences"] = len(differences)
    print(json.dumps(brief, ensure_ascii=False, indent=1))
    return 0 if out["identical"] else 3


if __name__ == "__main__":
    sys.exit(main())
