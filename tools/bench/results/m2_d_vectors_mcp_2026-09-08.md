# M2 d 批 / T15：向量通道接进 MCP 检索 + 首次建索引一次性动作

日期：2026-09-08 · 机器：M4 Air（Mac16,12）/ 16 GiB / 无风扇 / macOS 26.6 · Swift 6.3.3、语言模式 v6
对应计划：3.4（检索设计与分层目标）、3.6（`search`）、3.11（降级表 / D18 / D27）、
4.3.2 T15；c 批结果文件 `m2_c_vectors_2026-09-08.md` 第 7 节第 1 条与第 9 节第 1 条的遗留。

**一句话**：c 批的向量通道只差"谁来算查询向量"这一步，本轮把它接在
**app 侧的 IPC 服务端**上（可注入、懒加载、空闲 10 分钟卸载），
并用真实模型在 1 个月合成库上证明**经 MCP 的 `search` 与直接调 `Store.search` 逐题相同**
（改写题 47 / 47、原 60 题 60 / 60）；另加一个「整晚建索引」的一次性动作，
只放开空闲那道门，GPU 单独记账。**schema 没动**（分配给本任务的 v7 没用上）。

---

## 1. 做了什么

| # | 东西 | 落在哪 |
|---|---|---|
| 1 | `QueryEmbedder` 协议 + `ProviderQueryEmbedder` + **常驻/空闲卸载状态机（纯函数）** + `QueryEmbedTiming` | `core/Sources/BrosisCore/QueryEmbedder.swift`（新） |
| 2 | `StoreMCPService` 可注入查询嵌入器；`search` 四道门 + `queryEmbed` 计时块 + 审计 note | `core/Sources/BrosisCore/StoreMCPService.swift`（只加 init 参数、两个访问器、一个私有方法与三行调用） |
| 3 | **唯一真的加载权重的地方**：懒加载 + 空闲卸载 + D27 缓冲池策略 | `app/Sources/BrosisModels/MLXQueryEmbedder.swift`（新） |
| 4 | 产品路径接线（解锁注入 / 关库 / 锁屏 / 关开关卸载 + 事件） | `app/Sources/brosis/Models/QueryEmbedderService.swift`（新） |
| 5 | 「现在开始建索引（连续跑到完成或取消）」：门控纯函数 + 进度 + 单独 GPU 账 | `app/Sources/brosis/Models/OvernightIndexJob.swift`（新） |
| 6 | 自检第 10 组（12 项） | `app/Sources/brosis/Models/QueryEmbedderSelfCheck.swift`（新），`SelfCheck.swift` **只加一行** |
| 7 | `MCPIPCService` 三处接线（attach / detach / setPaused）+ 退出时卸载 | `app/Sources/brosis/IPCService.swift` |
| 8 | 面板按钮 + 开关联动 + 状态行 | `app/Sources/brosis/Models/ModelsWindow.swift` |
| 9 | `brosis-embed serve-search`：**注入了嵌入器的真 IPC 服务端**（没有 GUI 也能量产品路径） | `app/Sources/brosis-embed/main.swift` |
| 10 | `brosis-embed selftest` 加 5 条**真实模型**断言（查询向量与索引向量逐元素相同、热延迟、空闲/关库卸载、卸载后零调用） | 同上 |
| 11 | E2 一致性脚本（直接路径 vs 经 `brosis-mcp` 的真实 IPC 路径，逐题对照） | `tools/eval/d8_mcp_compare.py`（新） |
| 12 | 8 个新用例 | `core/Tests/BrosisCoreTests/QueryEmbedderTests.swift`（新） |

**`AppDelegate.swift` 一行没改**（并行约束）。接入方式：**不需要主会话做任何事**——
注入点在 `MCPIPCService.attach/detach/setPaused`，那是 `LockController` 已经在调的路径；
面板按钮在 `ModelsWindow` 里，菜单项还是 c 批那一行 `ModelsMenu.menuItem()`。

**schema**：分配给 T15 的 v7 **没有用**（这一批不需要新表新列），磁盘上仍是 v6 / T16 的 v8。

### 1.1 为什么注入的是协议而不是让 core 直接算

core 必须保持零 mlx 依赖（c 批「二选一」那一节的三条理由不变）。
所以 core 只定义 `QueryEmbedder`（`(String) throws -> [Float]?`）与"什么时候加载/卸载"的**纯函数**，
真正持有权重的类在 app 的 `BrosisModels` 里。`nil` 时行为与 c 批**逐位相同**
（`vectorsUnavailable = true`、`vectorUnavailableReason = "no_query_vector"`），
`brosis-store serve` 不注入，因此它的行为一个字节都没变。

### 1.2 四道门（"零模型调用"是结构性保证）

`search` 的结果里多了一个 `queryEmbed`：`{source, elapsedMS, dimension}`。

| `source` | 什么时候 | 调模型吗 |
|---|---|---|
| `disabled` | `retrieval.vectorsEnabled == false`（产品默认关，D8 条件 1） | **不会** |
| `no_embedder` | 没注入（`brosis-store serve`、或 app 选择不注入） | **不会** |
| `field_prefix` | 查询带 `app:` / `host:` / `path:` / `url:` / `title:`，本来就不走向量通道 | **不会** |
| `unavailable` | 注入了但这次返回 nil（模型没装 / 正在卸载） | 问了一句，没加载 |
| `embedder` | 真算了 | 会 |
| `error:<原因>` | 算失败：**不算检索失败**，前三条通道照常返回 | 试过 |

"库锁着"不在这张表里：`MCPGate` 在 `locked` / `paused` 时根本不把调用交给 `StoreMCPService`（3.5），
锁着的时候连 `runSearch` 都进不来。三条零调用的**实测**见第 3.3 节。

### 1.3 生命周期：常驻 + 空闲 10 分钟卸载

判定是 core 的 `QueryEmbedderPolicy`（纯函数，`swift test` 与 `--self-check` 各钉一遍）：

| 事件 | 动作 |
|---|---|
| 第一次 `search` | **加载**（解锁只是"允许"，不加载） |
| 又一次 `search` | 复用 |
| 空闲 ≥ **600 s**（定时器 60 s 一查） | 卸载 + `MLX.Memory.clearCache()` |
| 屏幕锁定 / 用户暂停 | **立刻**卸载 |
| 关库 / 退出 | **立刻**卸载 |
| 用户关掉「在检索里使用向量」 | **立刻**卸载 |

为什么不是"每次查完就卸"：冷加载实测 **0.35–0.37 s**，每条 MCP 查询都付一次，
3.4 的「查询嵌入 ≤ 150 ms」直接不可能达标。
为什么不是"一直常驻"：模型常驻约 **0.73 GiB** footprint，而 MCP 查询是阵发的。

**批构造固定为 1**：E9 的已知限制是"换批大小向量差 1e-3 量级"，
所以查询侧必须自己逐位可复现；评估脚本对照时也用 `brosis-embed queries --batch 1`
（这条口径直接决定第 4 节的"逐题相同"成不成立，见 4.4）。

**不持库锁**：`runSearch` 在 `store.search`（那里面才 `withLock`）**之前**算向量。
`QueryEmbedderTests.testQueryVectorIsComputedWithoutHoldingTheStoreLock` 在嵌入器里
再去另一个线程读一次库来钉这条（持锁就会超时）。

### 1.4 「整晚建索引」与夜间增量的差别

D8 的第三个条件：首次全量建索引在 Air 上要按小时计（c 批实测 1 小时 32 分），
塞不进 10 分钟的日均预算。这个动作与夜间增量共用同一套判定输入，**只有三处不一样**：

| 门 | 夜间增量 | 整晚一次性 | 理由 |
|---|---|---|---|
| 空闲 ≥ 5 分钟 | 要 | **不要** | 用户自己按的按钮，他知道机器要忙一夜；等空闲会让"睡前点一下"变成永远等不到 |
| 日均 GPU 预算 600 s | 要 | **不作为门**，单独一本账（`embedding.overnightGPUSecondsUsed`） | 一夜就是几小时 GPU；单独记账才不会吞掉夜间增量的预算 |
| 「夜间自动建索引」开关 | 要 | 不看 | 这个动作本身就是显式的用户动作 |
| **接电** | 要 | **要**（拔电 → 暂停，插回来继续） | 一夜的 GPU 活拿电池必然跑不完；但拔电通常是临时的，所以是暂停不是终止 |
| 热状态 | `nominal` 才跑 | fair **暂停**、serious / critical **停止** | Air 持续负载 2 分 10 秒就转 fair（D27），要求 nominal 等于永远跑不动 |
| 锁定 / 采集暂停 | 停 | **停**（不放开） | 库关了没得跑；锁屏按停处理，宁可保守 |

自检里有 **12 条对照用例**逐条断言这张表（三条"故意不一样"、九条"必须一样"）。
进度（已嵌入 / 总块数、块每秒、预计剩余）与停因写进 `jobs` 的运行时事件：
`overnight_index_started` / `_progress` / `_paused` / `_finished` / `_failed`。

---

## 2. 怎么跑

### 2.1 一句话复现（验收者用自己的 scratch）

```sh
DEV=/Applications/Xcode.app/Contents/Developer
S=$HOME/Library/Caches/brosis-build/verify-t15
P=<项目目录>

# 1) core：全绿零 warning
DEVELOPER_DIR=$DEV swift test --package-path "$P/core" --scratch-path "$S-core"

# 2) app：零 warning、自检全过
DEVELOPER_DIR=$DEV SCRATCH="$S-app" bash "$P/app/build_app.sh"
"$S-app/brosis.app/Contents/MacOS/brosis" --self-check

# 3) 真实模型的一致性与延迟（模型没装会 skip 并 exit 0）
APP="$S-app/brosis.app"
"$APP/Contents/MacOS/brosis-embed" models --models-dir "$S/models" \
    --import --id Qwen3-Embedding-0.6B-8bit \
    --from "$HOME/Library/Application Support/brosis-m0/models/Qwen3-Embedding-0.6B-8bit"
"$APP/Contents/MacOS/brosis-embed" selftest --models-dir "$S/models"
```

### 2.2 E2 一致性（要一个建好索引的库）

本轮**复用了 c 批建好的那个 1 个月库**（`m2-vectors/d8s/data`，46,545 块全部嵌完），
拷进自己的 scratch 再跑，**没有重建索引**（重建要 1 小时 32 分，见 c 批第 4.1 节）。

```sh
W=$S/d8s
mkdir -p "$W/results"
cp -R $HOME/Library/Caches/brosis-build/m2-vectors/d8s/data "$W/data"
cp $HOME/Library/Caches/brosis-build/m2-vectors/d8s/data.key "$W/"
cp $HOME/Library/Caches/brosis-build/m2-vectors/d8s/queryset_{60,paraphrase}.json "$W/"
# 没有那个库就从零建：SCRATCH=$S sh "$P/tools/eval/run_d8.sh"（最慢的一步 1 小时 32 分）

STORE=$(DEVELOPER_DIR=$DEV swift build --package-path "$P/core" -c release \
          --scratch-path "$S-core-rel" --show-bin-path)/brosis-store
cd "$P"
PYTHONDONTWRITEBYTECODE=1 python3 tools/eval/d8_mcp_compare.py \
  --queryset "$W/queryset_paraphrase.json" --dir "$W/data" --key-file "$W/data.key" \
  --models-dir "$S/models" --store "$STORE" \
  --embed "$APP/Contents/MacOS/brosis-embed" --mcp "$APP/Contents/MacOS/brosis-mcp" \
  --workdir "$W/mcp" --out "$W/results/e2_mcp_paraphrase.json" --label "改写题 47"
# 退出码 0 = 逐题相同；3 = 有不同（differences 里逐题列出来）
```

脚本做的事：① `brosis-embed queries --batch 1` 算查询向量表；
② 直接路径 `brosis-store search-batch --vectors --query-vectors <表>`；
③ 起 `brosis-embed serve-search`（注入嵌入器的真 IPC 服务端）→ `brosis-mcp admin grant add`
→ 用**真的 `brosis-mcp`** 说 JSON-RPC 逐题 `tools/call search`；
④ 逐题比 evidence id 列表与 `fusion`，再用 `d8_compare.score`（与 D8 同一套口径）算指标。

**为什么服务端用 `brosis-embed serve-search` 而不是 `brosis.app`**：产品路径上算查询向量的
就是 app 里的 IPC 服务端，但本轮屏幕锁定、不能起 GUI；而 `brosis-store serve` 在 core 里
（零 mlx 依赖）注入不了嵌入器。`serve-search` 用的是**同一份 `MLXQueryEmbedder` +
同一个 `StoreMCPService` + 同一个 `MCPGate` + 同一个 `IPCServer`**，
差别只有三处并且都写在子命令注释里：`FileKeyProvider` 代替钥匙串（不弹授权框）、
锁定相位写死 `unlocked`（没有 GUI 的锁定状态机）、可以 `--skip-codesign` 跳过对端签名校验
（`swift build` 出来的 `brosis-mcp` 没有 Developer ID，同 Team 校验必然过不去）。
**产品路径没有这个开关**：`IPCService.swift` 里 `peerPolicy` 写死 `.requireSameTeam`，不读环境变量。
取舍：换来的是"没有 GUI 也能量到真实 IPC + 真实客户端 + 真实 grant + 真实审计"的数字，
代价是"钥匙串取钥"与"锁定状态机"这两段没被这条实验覆盖（它们在 M1 T5 与自检里另有覆盖）。

---

## 3. 实测数字

### 3.1 查询嵌入（真实模型 Qwen3-Embedding-0.6B-8bit，MRL 512 / int8）

| 项 | 改写题 47 | 原 60 题 | 签名 .app 复跑（改写题） |
|---|---:|---:|---:|
| 首次加载 `embedder_loaded` | **0.366 s** | 0.360 s | 0.363 s |
| 加载后 peak footprint | **732.0 MiB** | 732.0 MiB | 733.1 MiB |
| 查询嵌入**热** p50 | **19.4 ms** | 17.4 ms | 18.9 ms |
| 查询嵌入**热** p95 | **26.1 ms** | 34.5 ms | 26.8 ms |
| 首次查询（含加载） | 403 ms | 395 ms | 399 ms |
| 真的算了几条 | 47 / 47 | **41 / 60**（19 题带字段前缀，零调用） | 47 / 47 |
| 服务端进程 peak footprint | 850.4 MiB | 863.9 MiB | 851.7 MiB |
| 卸载（`embedder_unloaded`，关库触发） | GPU 缓冲 25.9 → **0 MiB**，footprint 850.4 → 824.3 MiB | — | — |
| 热状态 | 全程 nominal | 全程 nominal | 全程 nominal |

**3.4 的分层目标：查询嵌入热延迟 ≤ 150 ms —— 达标（p95 26–35 ms，余量 4–5 倍）。**
首次加载单独记事件，不计进这条目标（403 ms 那一次就是冷加载）。

`brosis-embed selftest`（真实模型，11 条断言全过）里的两条相关数字：
**查询嵌入器与索引侧 provider 的向量 512 维逐元素相同**（同为批构造 1）、
首次（含加载）364 ms / 热 **18.3 ms**。

### 3.2 搜索总延迟，按 3.4 分层报（1 个月库 46,545 块 / 28,588 个文本版本）

| 层 | 目标 | 本轮实测 |
|---|---|---|
| 精确字段 / FTS 通道（热 p95） | < 10 ms（3.4） | 未单独复测（c 批 / T3 已测；本轮所有查询都开着向量） |
| 1–2 字扫描通道 | 7 天窗口 ≤ 150 ms | 未复测（本轮题集里没有 1–2 字题） |
| **向量通道（1 个月库）** | c 批建议 ≤ 100 ms | 直接路径 p50 **22.3 ms** / p95 53.9 ms（不带 `start`，与 c 批的 22.17 / 56.20 对得上） |
| **查询嵌入（本轮新增）** | **≤ 150 ms 热** | p50 **19.4 ms** / p95 **26.1 ms** |
| **经 MCP 的一次 `search`（客户端墙钟，含 JSON-RPC + IPC + 嵌入 + 检索）** | 本轮新报 | p50 **84.3 ms** / p95 92.7 ms（改写题）；p50 79.5 / p95 130.1（60 题） |
| 服务端内 `Store.search` 耗时 | — | MCP 路径 p50 65.2 / p95 68.3 ms；直接路径同口径 p50 67.4 / p95 75.5 ms |

**一条必须写清楚的口径差异**：grant 的时间窗是硬下界，所以**经 MCP 的 `search` 一定带 `start`**，
于是 `RetrievalOptions` 走"带过滤"的候选窗（`filteredFTSCandidateLimit` 2000、`filteredVectorK` 1000），
而不带 `start` 直接调 `Store.search` 走的是 200 / 200。同一套改写题上实测：

| 口径 | 单题 p50 / p95 | Recall@10 | MRR@10 | 答出 |
|---|---:|---:|---:|---:|
| 不带 `start`（c 批口径） | **22.3 / 53.9 ms** | 0.2540 | 0.6167 | 32 / 47 |
| 带 `start`（MCP 口径） | **67.4 / 75.5 ms** | **0.2774** | 0.6619 | 32 / 47 |

即：**经 MCP 慢约 3 倍，但召回略好**（候选窗更大）。这不是 bug，是候选窗口口径不同；
第 4 节的"逐题相同"因此是在**两边都带同一个 `start`** 的前提下量的。

### 3.3 「零模型调用」的三条，进程级实测

| 情况 | 服务端 `loads` | 服务端进程 peak footprint | `search` 还工作吗 |
|---|---:|---:|---|
| `retrieval.vectorsEnabled` 关（`--no-vectors`） | **0** | **11.08 MiB** | 工作：FTS-only，与直接路径逐题相同 |
| 模型没装（`--models-dir` 指向空目录） | **0** | **17.00 MiB** | 工作：返回 5 条命中，`queryEmbed.source = unavailable`（0.023 ms）、`vectorUnavailableReason = no_query_vector` |
| 库锁着 / 采集暂停 | — | — | MCP 直接拒（`locked` / `paused`），嵌入器调用次数不变（自检那一条） |
| 查询带字段前缀 | 不加载 | — | 60 题里 19 题走这条，`source = field_prefix` |

**11.08 MiB 那一行是最有说服力的**：整个服务端进程从头到尾没碰过模型。

### 3.4 空闲卸载（真实模型，把门槛调成 3 秒来量）

`brosis-embed serve-search --idle-unload-seconds 3 --idle-tick-seconds 1` 的事件流：

```
embedder_loaded    load_seconds 0.362  peak_footprint 732.0 MiB  cache_limit 256 MiB
embedder_unloaded  reason idle_3s      gpu_cache 7.2 → 0.0 MiB   footprint 781.4 → 774.0 MiB
embedder_loaded    load_seconds 0.343  （空闲卸载之后再查一次，重新加载）
embedder_unloaded  reason store_closed gpu_cache 13.1 → 0.0 MiB  footprint 819.9 → 806.7 MiB
```

`loads = 2`、`unloads = 2`、`failures = 0`。产品默认门槛是 **600 s**。

### 3.5 构建与自检

| 项 | 数 |
|---|---|
| `swift test --package-path core` | **229 个用例 0 失败**（209 → +8 本任务 → +12 并行的 T16），零 warning |
| 只含 T15 改动的树上 | 217 个用例 0 失败 |
| `build_app.sh` | 零 warning、`codesign --verify --deep --strict` 通过、`spctl` 未公证按预期 rejected |
| `--self-check`（只含 T15 改动的树） | **149 项全过**（137 → +12），退出码 0，peak footprint **232.9 MiB**（不加载任何模型） |
| `--self-check`（并进 T16 之后） | 162 项全过，peak footprint 229.5 MiB |
| app bundle | **99.90 MiB**（c 批 99.79 MiB，**+0.11 MiB**）；主程序 47.11 MiB、`brosis-embed` 45.40 MiB、`brosis-mcp` 0.45 MiB、metallib 2.99 MiB |
| 模型导入（重新校验 sha256） | 15 个文件、619.02 MiB、0.25 s、peak footprint **9.64 MiB**（3.11 的 `autoreleasepool` 那条修复仍然有效） |

本任务新增的 12 项自检（第 10 组）：MCP 无嵌入器时降级、注入后走 RRF、耗时随结果返回、
开关关零调用、字段前缀零调用、锁定 / 暂停零调用、空闲卸载状态机 10 条、
整晚门控 12 条对照、进度速率、进度不瞎报、整晚 GPU 单独记账、跨日归零。

---

## 4. E2 一致性：经 MCP 与直接调用逐题相同

### 4.1 改写题 47 道

| 指标 | 直接（`brosis-store search-batch`） | 经 MCP（`brosis-mcp` → IPC → `StoreMCPService`） |
|---|---:|---:|
| Recall@10 | 0.2774 | **0.2774** |
| Precision@10 | 0.4515 | **0.4515** |
| MRR@10 | 0.6619 | **0.6619** |
| 至少答出一条真证据 | 32 / 47 | **32 / 47** |
| 负例误报 | 0 | 0 |
| **逐题前 10 条完全相同** | — | **47 / 47** |

### 4.2 原 60 题（50 可答 + 10 不可答）

| 指标 | 直接 | 经 MCP |
|---|---:|---:|
| Recall@10（可答题） | 1.0000 | **1.0000** |
| Precision@10 | 0.9780 | **0.9780** |
| MRR@10 | 1.0000 | **1.0000** |
| 负例误报 | 2 | 2 |
| **逐题前 10 条完全相同** | — | **60 / 60** |

### 4.3 对照组：开关关着时也一致

`--skip-vectors`（两边都不给向量）：改写题 47 / 47 逐题相同，两边 Recall@10 都是 **0.0000**
——这正是 c 批 D8 那张表的 FTS-only 基线，说明这条对照跑的确实是同一套题、同一个库。

### 4.4 与 c 批数字的关系（**别当成同一个数**）

拿本轮 MCP 路径的逐题结果与 c 批自己那次混合检索比：**45 / 47 题前 10 条完全相同**，
2 题不同（`det-02-b`、`loc-17-a`），聚合指标恰好落在同一组值上（0.2774 / 0.6619 / 32）。
两个差异来源都不是本任务的改动：

1. **查询向量的批构造**：c 批用 `brosis-embed queries` 的默认批 16，而 MCP 路径按定义
   只能一次算一条（批 1）。E9 已知限制：换批大小向量差 1e-3 量级。
   同样是批 1、同样不带 `start` 时，Recall@10 是 **0.2540**（比 c 批的 0.2774 低）。
2. **`start` 下界**：见 3.2。

所以本轮的"逐题相同"是**内部一致性**（同一批向量、同一个 `start`，两条路必须给出同一个答案），
不是"复现了 c 批的绝对数值"。绝对数值受批构造与候选窗口影响，这两条都记在这里。

---

## 5. 未做与原因

1. **「整晚建索引」的循环体没有真机跑过一整轮**。原因两条：
   ① 手上的 1 个月库 46,545 块**已经全部嵌完**（`pendingChunks = 0`，门控当场返回 `complete`）；
   ② 真跑一轮要 1 小时 32 分（c 批实测）且要 GUI 里点按钮，本轮屏幕锁着。
   已覆盖的是：门控（12 条对照用例）、进度算式（2 条）、GPU 单独记账（2 条）都是纯函数并在自检里跑；
   循环体调用的 `store.runEmbeddingJob` 是 c 批已经实测过"可停止 / 幂等"的那一个。
   **建议主会话在真机上点一次**（接电、任意时刻），看 `overnight_index_progress` 事件的速率与 ETA。
2. **「模型」面板没有真机点过**（同 c 批：屏幕锁着不起 GUI）。按钮只做两件事：
   `OvernightIndexJob.shared.start/cancel` 与 `QueryEmbedderService.setVectorsEnabled`，
   两者的逻辑都在自检里；画界面那部分只保证编译与签名后能加载。
3. **产品路径（`brosis.app` 的 IPC 服务端 + 钥匙串取钥 + 锁定状态机）没有端到端跑过**。
   本轮用 `brosis-embed serve-search` 顶替服务端进程，代码路径同款，差三处（2.2 节写明）。
   要在真机上验：解锁 app → 「模型」面板打开向量开关 → `brosis-mcp admin grant add`
   → `claude mcp` 里问一句 → 看 `jobs` 里有没有 `embedder_loaded`、`search` 结果里的 `queryEmbed.source`。
4. **热状态一直是 `nominal`**：本轮的 GPU 活总共不到 1 分钟（47 + 41 + 47 条查询嵌入），
   够不着 D27 那条"持续负载 2 分 10 秒转 fair"。所以"降频之后查询嵌入要多久"没有数。
5. **12 个月库上的向量通道延迟**没测（c 批已经写明 sqlite-vec 的 kNN 是全量扫描、随块数线性，
   12 个月要按 12 倍折算约 1.8 s）。这条留给 T17 的规模压测。
6. **并发查询没测**：`MLXQueryEmbedder` 用一把锁把加载与嵌入串起来，
   多个 MCP 客户端同时问会排队。单个 Agent 的用法下这不是问题，但没有量过排队延迟。
7. **`vectorMaxDistance` 的自适应阈值**仍然没做（c 批第 9 节第 11 条原样保留）。
   本轮把逐条距离交给调用方这条路没变，MCP 的 `search` 现在真的会带上 `vectorDistance` 了
   （c 批那时因为没有查询向量，这个字段总是 nil）。
8. **`brosis-store serve` 没有注入口**：它在 core 里，注入不了 mlx 实现，行为与 c 批逐位相同
   （`no_query_vector`）。这是有意的——core 的零 mlx 依赖比"命令行也能算向量"更重要。

---

## 6. 验证与变异检验

### 6.1 逐条对照（验收清单）

| 要求 | 证据 |
|---|---|
| 查询嵌入器可注入、nil 时行为不变 | `QueryEmbedderTests.testNilEmbedderKeepsNoQueryVectorBehaviour`；自检第 10 组第 1 条 |
| 注入伪嵌入器后向量通道参与 | `testInjectedEmbedderFeedsTheVectorChannel`；自检第 2 条 |
| MRL 512 与索引一致、与 `brosis-embed` 查询向量逐元素一致 | `brosis-embed selftest` 第 7 条（真实模型，512 维逐元素相同） |
| 查询嵌入 ≤ 150 ms 热 | 3.1 节（p50 19.4 / p95 26.1 ms）；`selftest` 第 8 条 |
| 首次加载单独记事件（耗时、峰值） | 3.4 节的事件流：`embedder_loaded load_seconds 0.362 peak_footprint 732.0 MiB` |
| 查询向量计算不持库锁 | `testQueryVectorIsComputedWithoutHoldingTheStoreLock` |
| 模型未装 / 开关关 / 锁定时零模型调用 | 3.3 节（进程 peak 11.08 / 17.00 MiB、`loads = 0`）+ 自检第 4/5/6 条 |
| 空闲卸载状态机（5 种事件） | `testIdleUnloadStateMachine`（10 条）+ 自检 10 条 + 3.4 节真实模型事件流 |
| 整晚动作的门控与 `EmbeddingGatePolicy` 的差异逐条 | 自检「12 条对照用例」（3 条差异 + 9 条一致） |
| 整晚 GPU 单独记账 | 自检「整晚 5400 s / 夜间 120 s，夜间还剩 480 s」+ 跨日归零 |
| E2 一致性 | 第 4 节：47 / 47、60 / 60，`d8_mcp_compare.py` 退出码 0 |

### 6.2 变异检验（**复制到 scratch 再改，不要动项目目录**）

```sh
MUT=$HOME/Library/Caches/brosis-build/verify-t15-mutate
rm -rf "$MUT" && mkdir -p "$MUT" && cp -R core "$MUT/core" && cp -R app "$MUT/app"
ln -sfn $HOME/Library/Caches/brosis-build/sqlcipher/vendor/route-b "$MUT/core/Vendor/SQLCipher"
ln -sfn $HOME/Library/Caches/brosis-build/sqlcipher/vendor/sqlite-vec-target "$MUT/core/Vendor/SqliteVec"
```

| # | 改什么 | 应当失败的用例 | 本轮实测 |
|---|---|---|---|
| 1 | `StoreMCPService.queryEmbedding` 里删掉 `guard store.retrieval.vectorsEnabled` 那一行 | `QueryEmbedderTests.testSwitchOffMeansZeroModelCalls` | **实测失败**：`("3") is not equal to ("0") - 开关关着时一次模型调用都不许发` |
| 2 | 同一处删掉 `guard QueryRouter.parseField(q).field == nil` 那三行 | `testFieldPrefixQueriesNeverTouchTheModel` | **实测失败**：`("Optional("embedder")") is not equal to ("Optional("field_prefix")")`，随后 `("3") is not equal to ("0")` |
| 3 | `QueryEmbedderPolicy.next` 的 `.tick` 分支把 `>=` 改成 `>` | `testIdleUnloadStateMachine` | **实测失败**：`("none") is not equal to ("unload("idle_600s")")`（600 s 边界翻掉） |
| 4 | `OvernightIndexPolicy.decide` 里把「空闲 ≥ 5 分钟」这道门加回来 | app `--self-check` 的「整晚建索引门控 12 条对照用例」 | **实测失败**：`差异①：机器在用 ⇒ 夜间不跑，整晚照跑 期望 夜间 skip("not_idle") / 整晚 run，实得 … 整晚 pause("not_idle")`，该项 `[FAIL] … 失败 1 条` |
| 5 | `MLXQueryEmbedder.queryVector` 改成一次算两条（`embed([trimmed, trimmed])` 取第一条） | `brosis-embed selftest` 第 7 条 | 未跑（要重编 app + mlx 且要装模型）；E9 已经量过"换批大小差 4e-4 量级"，该条断言比的是逐元素相等，必然翻 |

---

## 7. 对计划的影响（一句话）

**4.3.2 T15 的两件事都落地了：MCP 的 `search` 现在会自己算查询向量（默认关、模型装了才可开、
锁定 / 关库立刻卸载、热延迟 p95 26 ms 远低于 150 ms 的分层目标），并且在 1 个月合成库上
逐题证明了「经 MCP」与「直接调用」给出同一个答案（47 / 47、60 / 60）；
「首次全量建索引」按 D8 条件 3 做成了用户显式确认的一次性动作、GPU 单独记账，
剩下的只有"在真机上点一次"这一步。**

---

## 附录：数字的出处

原始产物在 `~/Library/Caches/brosis-build/m2-vectors-mcp/d8s/results/`（任务结束时
SwiftPM 的编译目录已删，`results/`、库文件与签名后的 `brosis.app` 保留）：

| 文件 | 里面是什么 |
|---|---|
| `e2_mcp_paraphrase.json` | 改写题 47 的逐题对照（直接 vs MCP）、查询嵌入耗时、每题的 `queryEmbed` |
| `e2_mcp_original60.json` | 原 60 题的同一套（含 19 题 `field_prefix` 的分布） |
| `e2_mcp_paraphrase_bundle.json` | 用**签名后的 `.app` 里的二进制**复跑一遍改写题 |
| `e2_mcp_paraphrase_novec.json` / `_novec_bundle.json` | 对照组：开关关着（`--no-vectors`） |
| `direct_nostart.json` | 不带 `start` 的直接路径（量 3.2 节那条口径差异） |
| `serve_no_model.json` + `no_model_search.txt` | 模型没装那一组：`loads = 0`、peak 17.00 MiB、`source = unavailable` |
| `serve_idle_unload.json` + `../mcp/idle_events.jsonl` | 空闲卸载的真实事件流（3.4 节那四行） |
| `embed_selftest.json` / `.time` | `brosis-embed selftest` 11 条断言与耗时 |
| `model_import.json` / `.time` | 模型本地导入 + sha256 重新校验 |
| `self_check.txt` / `.time` | 只含 T15 改动的树上的 149 项自检 |
| `self_check_merged.txt` / `.time` | 并进 T16 之后的 162 项自检 |
| `embed_env.json` | `brosis-embed env`（metallib、sqlite-vec、清单、维度）与打包自检脚本的输出 |
| `../mcp*/…_serve.json` | 每次 `serve-search` 退出时的统计（加载耗时、热 p50/p95、峰值、卸载原因） |

被复用的 1 个月合成库在 `~/Library/Caches/brosis-build/m2-vectors-mcp/d8s/data/`
（从 c 批的 `m2-vectors/d8s/data` 拷来，46,545 块全部嵌完，没有重建）。
