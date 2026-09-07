# brosis

本地 macOS 活动记录器：采集所有应用、窗口与屏幕上看到的文本，整理成确定性台账与规范化对象，加密存入 SQLite，经 MCP 供 Agent 检索。硬约束：存储小、零遥测、app 自包含、默认不外发。

当前阶段：**M0 验证已基本完成，M1 最小闭环记录器尚未开始。**

| 目录 | 内容 |
|---|---|
| `docs/`（不在本仓库） | 实施计划（决策表 D1–D28、架构、里程碑、实验结果）与会话交接文档，只保存在本地 |
| `app/` | brosis.app M0 采集骨架（SwiftPM；事件骨架、AX、按需截图、权限引导） |
| `core/` | 加密存储核心（SwiftPM；SQLCipher、3.2 全部表、写入 / 删除 / 配额 / 维护 / 统计、`brosis-store` CLI） |
| `tools/probe/` | D2 应用切换探针（无权限） |
| `tools/bench/` | OCR 基准、FTS 分词对照、E9 运行时结果 |
| `tools/proto/` | 3.2 schema 原型、合成库、正确性与容量测量、SQLCipher 构建 |
| `tools/e9/` | 内嵌 mlx-swift 运行时、模型管理器、嵌入 / 生成基准 |

约定：`docs/` 与 `tools/probe/results/` 已在 .gitignore 里；构建产物不放项目目录（一律 `~/Library/Caches/brosis-build/<任务>/`）；Python 只用标准库；体积单位 GiB = 2^30。各目录的 README 写了怎么跑。
