#!/usr/bin/env python3
# brosis：生成 app 随包的模型推荐清单 catalog.json（计划 3.11 / D18 / D30）
#
# 只用标准库。用 Hugging Face 只读 API 固定 revision sha，列出文件清单与每个文件的 sha256：
#   - LFS 文件：API tree 里的 lfs.oid 就是 sha256，不用下载
#   - 非 LFS 小文件：API 只给 git blob 的 sha1，必须下载后自己算 sha256
#
# 用法：
#   python3 app/Support/gen_catalog.py > app/Sources/BrosisModels/catalog.json
#
# 环境变量：
#   HF_BASE   默认 https://huggingface.co，可设 https://hf-mirror.com
#
# 与 tools/e9/Support/gen_catalog.py 的差别：那份是 M0 的（选一个 0.6B 嵌入 + 一个生成模型）；
# 这份按 D30 只出**嵌入模型**，而且是写死的多尺寸清单（4B / 8B），因为要让用户在面板里切换。
import datetime
import hashlib
import json
import os
import sys
import urllib.request

HF_BASE = os.environ.get("HF_BASE", "https://huggingface.co").rstrip("/")
UA = {"User-Agent": "brosis-catalog/0.2"}
TIMEOUT = 120

# D30（2026-09-08 用户决定）：向量检索支持 Qwen3-Embedding 的多个尺寸，可在面板里切换；
# 去掉 0.6B（用户认为太小）。统一向量维度 1024（两者原生 2560 / 4096，MRL 截断）。
REPOS = [
    # 0.6B 一度按 D30 去掉（用户嫌小），2026-09-08 又加回来：4B 在 M4 Air 上实测只有
    # 1.20 块/s（0.6B 是 16.3），日预算 600 s 只够约 720 块/天，所以留一个"快档"很有必要。
    # 统一维度 1024 正好是 0.6B 的原生维度——它反而是唯一不需要 MRL 截断的那个。
    ("mlx-community/Qwen3-Embedding-0.6B-8bit", "8bit", 8,
     "Qwen3-Embedding 0.6B（原生 1024 维＝本项目统一维度，不截断）。最快的一档："
     "Air 实测 16.3 块/s，是 4B 的 13.6 倍；代价是检索质量最低（C-MTEB 检索 71.03，"
     "4B 是 77.03）。想快就用它，想准用 4B / 8B。"),
    ("mlx-community/Qwen3-Embedding-4B-4bit-DWQ", "4bit-DWQ", 8,
     "Qwen3-Embedding 4B（原生 2560 维，MRL 截到本项目统一的 1024 维）。质量与速度的平衡档："
     "C-MTEB 检索 77.03（0.6B 是 71.03）；Air 实测 1.20 块/s，比 0.6B 慢 13.6 倍。"),
    ("mlx-community/Qwen3-Embedding-8B-4bit-DWQ", "4bit-DWQ", 16,
     "Qwen3-Embedding 8B（原生 4096 维，MRL 截到 1024 维）。质量最好、最慢："
     "C-MTEB 检索 78.21，只比 4B 高 1.2 分而慢一倍，建议只在大内存机器上当索引模型。"
     "换模型会让已建的向量索引作废，需要重建。"),
]


def get(url, binary=False):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read()
    return data if binary else json.loads(data)


def build_entry(repo_id, quant, min_ram_gib, note):
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
            sha256, how = lfs["oid"], "lfs-oid"
        else:
            blob = get(f"{HF_BASE}/{repo_id}/resolve/{revision}/{path}", binary=True)
            if len(blob) != size:
                print(f"warn: {path} 大小不符 {len(blob)} != {size}", file=sys.stderr)
            sha256, how = hashlib.sha256(blob).hexdigest(), "downloaded"
        files.append({"path": path, "size": size, "sha256": sha256, "sha256Source": how})
        total += size
    files.sort(key=lambda x: x["path"])
    cfg = info.get("config", {}) or {}
    print(f"  {repo_id}: {len(files)} 个文件、{total / (1 << 30):.2f} GiB、rev {revision[:12]}",
          file=sys.stderr)
    return {
        "id": repo_id.split("/")[-1],
        "purpose": "embedding",
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
    models = [build_entry(*r) for r in REPOS]
    catalog = {
        "schemaVersion": 2,
        "generatedAt": datetime.date.today().isoformat(),
        "generatedBy": "app/Support/gen_catalog.py",
        "note": "随 app 打包、随 app 更新；运行时不联网拉清单（计划 3.11）。"
                "D29：叙述下架，清单里没有生成模型。"
                "D30：嵌入模型支持多尺寸并可在面板里切换，统一向量维度 1024。",
        "models": models,
    }
    json.dump(catalog, sys.stdout, ensure_ascii=False, indent=2)
    print()


main()
