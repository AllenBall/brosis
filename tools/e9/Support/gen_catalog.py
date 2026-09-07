#!/usr/bin/env python3
# brosis M0 · E9：生成模型推荐清单 catalog.json（计划 3.11）
#
# 只用标准库。用 Hugging Face 只读 API 查候选仓库，按 8bit > 4bit > bf16 选一个，
# 固定 revision sha，列出文件清单与每个文件的 sha256：
#   - LFS 文件：API tree 里的 lfs.oid 就是 sha256，不用下载
#   - 非 LFS 小文件：API 只给 git blob 的 sha1，必须下载后自己算 sha256
#
# 用法：
#   python3 tools/e9/Support/gen_catalog.py > tools/e9/Sources/brosis-e9/catalog.json
#
# 环境变量：
#   HF_BASE   默认 https://huggingface.co，可设 https://hf-mirror.com
import datetime
import hashlib
import json
import os
import sys
import urllib.request

HF_BASE = os.environ.get("HF_BASE", "https://huggingface.co").rstrip("/")
UA = {"User-Agent": "brosis-e9-catalog/0.1"}
TIMEOUT = 60


def get(url, binary=False):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read()
    return data if binary else json.loads(data)


def pick_repo():
    """在 mlx-community 下找 Qwen3-Embedding-0.6B，量化优先级 8bit > 4bit > bf16。"""
    models = get(f"{HF_BASE}/api/models?author=mlx-community&search=Qwen3-Embedding-0.6B&limit=100")
    ids = [m["modelId"] for m in models]
    order = [
        ("8bit", lambda i: i.endswith("-8bit")),
        ("mxfp8", lambda i: i.endswith("-mxfp8")),
        ("4bit", lambda i: i.endswith("-4bit") or i.endswith("-4bit-DWQ")),
        ("bf16", lambda i: i.endswith("-bf16")),
    ]
    for label, pred in order:
        hits = [i for i in ids if pred(i) and "VL" not in i]
        if hits:
            return sorted(hits)[0], label, ids
    raise SystemExit(f"没有找到合适的仓库，候选：{ids}")


def build_entry(repo_id, quant, purpose, min_ram_gib, note):
    info = get(f"{HF_BASE}/api/models/{repo_id}")
    revision = info["sha"]
    tree = get(f"{HF_BASE}/api/models/{repo_id}/tree/{revision}?recursive=true")
    files, total = [], 0
    for f in tree:
        if f.get("type") != "file":
            continue
        path, size = f["path"], f["size"]
        lfs = f.get("lfs") or {}
        if lfs.get("oid"):
            sha256 = lfs["oid"]
            how = "lfs-oid"
        else:
            blob = get(f"{HF_BASE}/{repo_id}/resolve/{revision}/{path}", binary=True)
            if len(blob) != size:
                print(f"warn: {path} 大小不符 {len(blob)} != {size}", file=sys.stderr)
            sha256 = hashlib.sha256(blob).hexdigest()
            how = "downloaded"
        files.append({"path": path, "size": size, "sha256": sha256, "sha256Source": how})
        total += size
    files.sort(key=lambda x: x["path"])
    cfg = info.get("config", {}) or {}
    return {
        "id": repo_id.split("/")[-1],
        "purpose": purpose,
        "source": "huggingface",
        "repoId": repo_id,
        "revision": revision,
        "quantization": quant,
        "totalBytes": total,
        "minRAMBytes": min_ram_gib * (1 << 30),
        "files": files,
        "note": note,
        "hfLastModified": info.get("lastModified"),
        "hfPipelineTag": info.get("pipeline_tag"),
        "hfModelType": (cfg.get("architectures") or [None])[0],
    }


def main():
    repo_id, quant, candidates = pick_repo()
    print(f"候选仓库：{candidates}", file=sys.stderr)
    print(f"选中：{repo_id}（{quant}）", file=sys.stderr)
    embed = build_entry(
        repo_id,
        quant,
        "embedding",
        8,
        "向量检索唯一依赖（计划 3.11 / D8）。1024 维，支持 MRL 截断到 512 / 256。",
    )
    # D19 叙述 / 抽取模型（2026-09-07 用户定案）。选 -MLX-4bit 而不是同名的 -4bit：
    # 两个仓库权重完全相同，前者是官方 MLX 转换线，仓库名更明确。最低内存按计划 3.11 表取 16 GiB。
    gen = build_entry(
        "mlx-community/Qwen3.5-4B-MLX-4bit",
        "4bit",
        "generation",
        16,
        "D19 叙述 / 抽取模型（2026-09-07 用户定案）。Apache 2.0。"
        "原生多模态（config model_type=qwen3_5，text_config.model_type=qwen3_5_text），"
        "但 mlx-swift-lm 3.31.4 的 Qwen35Model.sanitize 会跳过 vision_tower / model.visual 权重，"
        "Swift 侧只加载文本塔——视觉权重仍会被下载，只是不进显存。"
        "上下文 262,144 token；非思考模式靠对话模板变量 enable_thinking=false 打开"
        "（generate 子命令的 --no-think）；按计划 3.10 温度 0、失败重试一次。",
    )
    catalog = {
        "schemaVersion": 1,
        "generatedAt": datetime.date.today().isoformat(),
        "generatedBy": "tools/e9/Support/gen_catalog.py",
        "note": "随 app 打包、随 app 更新；运行时不联网拉清单（计划 3.11）。",
        "models": [
            embed,
            gen,
            {
                "id": "gemma-4-26B-A4B-it-QAT-MLX-4bit",
                "purpose": "generation",
                "source": "local-import",
                "repoId": "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                "revision": None,
                "quantization": "4bit",
                "totalBytes": None,
                "minRAMBytes": 64 * (1 << 30),
                "files": [],
                "note": "D19 高档位，仅 64 GB 以上机器显示；M0 只走本地导入，不下载。",
            },
        ],
    }
    json.dump(catalog, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
