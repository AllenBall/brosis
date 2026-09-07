#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brosis M1 / T5：MCP 客户端（stdio 传输），只用 Python 标准库。

它扮演 Claude Code 这一侧：拉起 brosis-mcp，按 MCP 规范的 stdio 传输
（换行分隔的 JSON-RPC 2.0）走 initialize → notifications/initialized →
tools/list → 若干次 tools/call，把每一步的原始请求 / 响应打成一份 JSON 报告。

`core/Tests/BrosisCoreTests/MCPEndToEndTests.swift` 用它跑端到端；
验收者也可以直接手跑，例如：

    BIN=~/Library/Caches/brosis-build/m1-mcp/debug
    python3 core/Tests/mcp_client.py --bin $BIN/brosis-mcp \\
        --env BROSIS_IPC_SOCKET=$WORK/db/ipc.sock \\
        --client-name claude-code \\
        --call search '{"q": "知识图谱", "limit": 3}'

退出码：0 = 全部步骤都拿到了 JSON-RPC 响应（工具本身返回 isError 也算拿到）；
1 = 传输层出了问题（进程挂了、响应不是合法 JSON、超时）。
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time


class MCPStdioClient:
    """一条 stdio 上的 MCP 连接。"""

    def __init__(self, argv, env=None, timeout=20.0, stderr_path=None):
        self.timeout = timeout
        self._next_id = 0
        self.transcript = []           # [{"direction": "->"|"<-", "message": {...}}]
        merged = dict(os.environ)
        merged.update(env or {})
        self._stderr_file = open(stderr_path, "wb") if stderr_path else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_file,
            env=merged,
            bufsize=0,
        )

    # ---------------------------------------------------------------- 底层收发

    def _send(self, message):
        line = json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n"
        self.transcript.append({"direction": "->", "message": message})
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()

    def _read_line(self):
        """带超时地读一行。用后台线程读，主线程等——标准库里没有跨平台的 fd 超时读。"""
        box = {}

        def worker():
            try:
                box["line"] = self.proc.stdout.readline()
            except Exception as exc:            # noqa: BLE001
                box["error"] = repr(exc)

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        thread.join(self.timeout)
        if thread.is_alive():
            raise TimeoutError("等 MCP 响应超过 %.1f s" % self.timeout)
        if "error" in box:
            raise IOError(box["error"])
        line = box.get("line") or b""
        if not line:
            raise IOError("brosis-mcp 关闭了 stdout（退出码 %s）" % self.proc.poll())
        return json.loads(line.decode("utf-8"))

    def request(self, method, params=None):
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)
        while True:
            response = self._read_line()
            self.transcript.append({"direction": "<-", "message": response})
            # 服务端可能夹带通知（本实现不会，但客户端要能忍）
            if "id" not in response or response.get("id") is None:
                continue
            if response["id"] != message["id"]:
                continue
            return response

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    # ---------------------------------------------------------------- MCP 语义

    def initialize(self, client_name, client_version="0.0.1",
                   protocol_version="2025-06-18"):
        response = self.request("initialize", {
            "protocolVersion": protocol_version,
            "capabilities": {},
            "clientInfo": {"name": client_name, "version": client_version},
        })
        self.notify("notifications/initialized")
        return response

    def list_tools(self):
        return self.request("tools/list", {})

    def call_tool(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:                       # noqa: BLE001
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:                       # noqa: BLE001
            self.proc.kill()
        if self._stderr_file not in (None, subprocess.DEVNULL):
            self._stderr_file.close()


# -------------------------------------------------------------------- 结果整理

def tool_result_text(response):
    """把 tools/call 的响应压成一段文本，断言用。"""
    result = response.get("result") or {}
    chunks = []
    for item in result.get("content", []):
        if item.get("type") == "text":
            chunks.append(item.get("text", ""))
    return "\n".join(chunks)


def tool_result_payload(response):
    """从 <brosis:evidence> 分隔符里把 JSON 抠出来。拿不到就返回 None。"""
    text = tool_result_text(response)
    # 用 rfind 找开标记：万一将来提示语里又出现一次字面量，取最里面那一对才是对的。
    start = text.rfind("<brosis:evidence>")
    end = text.rfind("</brosis:evidence>")
    if start < 0 or end < 0:
        return None
    body = text[start + len("<brosis:evidence>"):end].strip()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description="brosis MCP stdio 客户端（只用标准库）")
    parser.add_argument("--bin", required=True, help="brosis-mcp 可执行文件路径")
    parser.add_argument("--env", action="append", default=[], metavar="K=V",
                        help="传给 brosis-mcp 的环境变量，可重复")
    parser.add_argument("--client-name", default="mcp-client-py", help="initialize 里的 clientInfo.name")
    parser.add_argument("--protocol-version", default="2025-06-18")
    parser.add_argument("--call", action="append", nargs=2, default=[],
                        metavar=("TOOL", "JSON"), help="调一次工具，可重复")
    parser.add_argument("--script", help="一个 JSON 文件：[{\"tool\": ..., \"arguments\": {...}}, …]")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--stderr", help="把 brosis-mcp 的 stderr 存到这个文件")
    parser.add_argument("--transcript", help="把全部原始 JSON-RPC 消息写到这个文件")
    parser.add_argument("--out", help="报告写到这个文件（默认打到 stdout）")
    parser.add_argument("--no-init", action="store_true", help="跳过 initialize（测协议错误用）")
    parser.add_argument("--gate", metavar="INDEX,REACHED,GO",
                        help="跑到第 INDEX 次调用之前，先建 REACHED 文件，再等 GO 文件出现。"
                             "调用方用它在两次调用之间做点事（比如把服务端重启一遍）")
    args = parser.parse_args(argv)

    gate_index, gate_reached, gate_go = -1, None, None
    if args.gate:
        index, gate_reached, gate_go = args.gate.split(",", 2)
        gate_index = int(index)

    env = {}
    for pair in args.env:
        key, _, value = pair.partition("=")
        env[key] = value

    steps = []
    for tool, payload in args.call:
        steps.append({"tool": tool, "arguments": json.loads(payload)})
    if args.script:
        with open(args.script, encoding="utf-8") as handle:
            steps.extend(json.load(handle))

    report = {"bin": args.bin, "client_name": args.client_name, "steps": []}
    client = MCPStdioClient([args.bin], env=env, timeout=args.timeout,
                            stderr_path=args.stderr)
    status = 0
    started = time.time()
    try:
        if not args.no_init:
            report["initialize"] = client.initialize(
                args.client_name, protocol_version=args.protocol_version)
        listed = client.list_tools()
        report["tools_list"] = listed
        report["tool_names"] = sorted(
            t["name"] for t in (listed.get("result", {}).get("tools", [])))

        for index, step in enumerate(steps):
            if index == gate_index:
                # 告诉调用方"我停在这里了"，然后等它放行。中间这段时间连接是闲置的，
                # 服务端可以被停掉 / 重启——重连由 brosis-mcp 那一侧负责。
                open(gate_reached, "w").close()
                deadline = time.time() + args.timeout
                while not os.path.exists(gate_go):
                    if time.time() > deadline:
                        raise TimeoutError("等 %s 超过 %.1f s" % (gate_go, args.timeout))
                    time.sleep(0.05)
            if "method" in step:
                response = client.request(step["method"], step.get("params"))
                report["steps"].append({"method": step["method"], "response": response})
                continue
            response = client.call_tool(step["tool"], step.get("arguments", {}))
            result = response.get("result") or {}
            report["steps"].append({
                "tool": step["tool"],
                "arguments": step.get("arguments", {}),
                "is_error": bool(result.get("isError")),
                "text": tool_result_text(response),
                "payload": tool_result_payload(response),
                "response": response,
            })
    except Exception as exc:                    # noqa: BLE001
        report["error"] = "%s: %s" % (type(exc).__name__, exc)
        status = 1
    finally:
        report["elapsed_s"] = round(time.time() - started, 3)
        if args.transcript:
            with open(args.transcript, "w", encoding="utf-8") as handle:
                json.dump(client.transcript, handle, ensure_ascii=False, indent=2)
        client.close()

    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    else:
        sys.stdout.write(text + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
