#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核对 `brosis-embed env` 的输出（build_app.sh 第 4c 步）。

三条断言，任一不过就让构建失败：
  1. **GPU 冒烟通过**：bundle 里真跑了一次 Metal 运算并算对了 —— 这一条同时证明
     `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib` 在位且版本对得上
     （E9：不处理的话运行时报 "Failed to load the default metallib"）；
  2. **sqlite-vec 已注册**：v4 的 `vec_chunks` 是 vec0 虚拟表，没注册连表都建不出来；
  3. **模型清单读得到且至少两项**：清单随 app 打包、运行时不联网拉（计划 3.11 / D18）。

只用标准库。
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("用法：check_embed_env.py <brosis-embed env 的 JSON>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)

    problems = []
    smoke = data.get("gpu_smoke") or {}
    if not smoke.get("ok"):
        problems.append("GPU 冒烟失败：%r（metallib 没找到或版本对不上）" % (smoke,))
    if not data.get("sqlite_vec_registered"):
        problems.append("sqlite-vec 没注册成功")
    # 2026-09-08（D29）：叙述下架后清单里只剩嵌入模型，判据从"至少 2 项"改成
    # "嵌入模型必须在、生成模型必须不在"——这才是闸门真正要守的东西。
    # D30：嵌入模型改成多尺寸（Qwen3-Embedding 系列）可切换，所以按前缀判，不写死某个 id。
    models = data.get("catalog_models") or []
    if not any(m.startswith("Qwen3-Embedding-") for m in models):
        problems.append("模型清单里没有 Qwen3-Embedding 系列的嵌入模型：%r" % (models,))
    if any("Qwen3.5" in m or "gemma" in m for m in models):
        problems.append("模型清单里还有生成模型（叙述已下架，D29）：%r" % (models,))
    if data.get("vector_dimension") != 1024:
        problems.append("向量维度不是 1024（D30 统一维度）：%r" % data.get("vector_dimension"))

    if problems:
        for line in problems:
            print("FAIL " + line, file=sys.stderr)
        return 1
    print("PASS bundle 内 GPU 冒烟 %s（metallib %s）、sqlite-vec %s、清单 %d 项、向量 %d 维 %s"
          % (smoke.get("value"), smoke.get("metallib"), data.get("sqlite_vec_version"),
             len(models), data.get("vector_dimension"), data.get("vector_element_type")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
