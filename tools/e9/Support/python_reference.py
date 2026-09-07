#!/usr/bin/env python3
# brosis M0 · E9：Python 参考实现，用来和 Swift 侧的向量对照
#
# 目的：证明 mlx-swift-lm 的 MLXEmbedders(Qwen3) 与 MLX Python 走同一份权重得到同样的向量。
# 复现口径必须和 Swift 一致：
#   - 同一个本地模型目录（我们自己下载并校验过的）
#   - transformers AutoTokenizer，add_special_tokens=True
#   - 右侧 padding（pad = <|endoftext|>），mask 按真实长度构造
#   - last-token pooling（取每条的第 len-1 个位置），再 L2 归一化
#   - 不做 layer norm、不截断维度
#
# 用法：
#   <python> tools/e9/Support/python_reference.py \
#       --model-dir <目录> --corpus <corpus.json> --swift <crosscheck_swift.json> --out <结果.json>
#
# 本机跑法（不下载任何东西，直接用 LM Studio 自带的 mlx 0.31.2 环境）：
#   ~/.lmstudio/extensions/backends/vendor/_amphibian/app-mlx-generate-mac14-arm64@29/bin/python3.11 ...
# 没有这个环境时的等价做法：
#   UV_CACHE_DIR=~/Library/Caches/brosis-build/uv-cache \
#   uv run --no-project --with mlx --with mlx-lm --with transformers python tools/e9/Support/python_reference.py ...
import argparse
import json
import math
import time

import mlx.core as mx
from mlx_lm.utils import load as mlx_load
from transformers import AutoTokenizer

PAD_TOKEN = "<|endoftext|>"


def embed(model, tok, texts, pad_id, batch_size=8, max_tokens=1024):
    out = []
    for i in range(0, len(texts), batch_size):
        chunk = texts[i:i + batch_size]
        ids = [tok(t, add_special_tokens=True)["input_ids"][:max_tokens] for t in chunk]
        lens = [len(x) for x in ids]
        L = max(lens)
        padded = [x + [pad_id] * (L - len(x)) for x in ids]
        h = model.model(mx.array(padded))  # [B, L, H]，最后一层 RMSNorm 之后的隐状态
        idx = mx.array([[l - 1] for l in lens])
        pooled = mx.take_along_axis(h, idx[:, :, None], axis=1).squeeze(1)
        pooled = pooled / mx.linalg.norm(pooled, axis=-1, keepdims=True)
        mx.eval(pooled)
        out.extend([[float(v) for v in row] for row in pooled.tolist()])
    return out


def cosine(a, b):
    d = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return d / (na * nb) if na and nb else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--swift", required=True, help="Swift 侧导出的 crosscheck_swift.json")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    swift = json.load(open(args.swift))
    texts = swift["texts"]

    t0 = time.time()
    model, _ = mlx_load(args.model_dir)
    tok = AutoTokenizer.from_pretrained(args.model_dir)
    pad_id = tok.convert_tokens_to_ids(PAD_TOKEN)
    load_s = time.time() - t0

    t1 = time.time()
    vecs = embed(model, tok, texts, pad_id)
    embed_s = time.time() - t1

    cos = [cosine(a, b) for a, b in zip(swift["vectors"], vecs)]
    maxabs = max(
        max(abs(x - y) for x, y in zip(a, b)) for a, b in zip(swift["vectors"], vecs)
    )
    result = {
        "modelDir": args.model_dir,
        "pythonMLXVersion": getattr(mx, "__version__", "?"),
        "padTokenId": pad_id,
        "count": len(texts),
        "dimension": len(vecs[0]),
        "loadSeconds": load_s,
        "embedSeconds": embed_s,
        "cosineMin": min(cos),
        "cosineMean": sum(cos) / len(cos),
        "cosineMax": max(cos),
        "maxAbsElementDiff": maxabs,
        "allAtLeast0_99": all(c >= 0.99 for c in cos),
        "cosines": cos,
    }
    with open(args.out, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in result.items() if k != "cosines"},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
