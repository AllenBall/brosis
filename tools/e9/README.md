# tools/e9 · 内嵌推理运行时、模型管理器与分发验证

对应 `docs/实施计划.md` 4.1 的 **E9**、3.11 模型管理器、**D18 / D19**、附录 A「E9 内嵌运行时与分发验证」，
以及 `docs/可行性调研报告.md` **11.2 第 7 条**（Qwen3-Embedding-0.6B 在 512 / 256 维截断下的检索保真）。

要回答的问题只有一句：**"运行时随 app 携带、模型由 app 自己下载并校验、Developer ID + hardened runtime 下能跑"这条路成不成立。**

结果与全部数字：`tools/bench/results/e9_runtime_2026-09-07.md`（说明）与 `.json`（原始数据）。
一句话结论：**成立**，但构建机必须装 Metal Toolchain，且 D19 的 Gemma 4 26B-A4B 在 Swift 侧跑不起来。

---

## 目录

```
tools/e9/
  Package.swift                     独立 SwiftPM 包，可执行目标 brosis-e9
  catalog.json                      推荐清单（生成物，与 Sources/ 下那份内容相同）
  build_app.sh                      构建 + 组装 .app + Developer ID 签名 + 验证 + 公证提示
  README.md                         本文件
  Sources/brosis-e9/
    main.swift                      子命令入口
    Catalog.swift                   推荐清单模型（3.11）
    Downloader.swift                URLSession 下载器：Range 续传 / 镜像 / 系统代理 / sha256
    ModelStore.swift                模型目录、installed.json、本地导入、校验、原子提交
    Embed.swift                     TokenizerLoader 适配器 + 嵌入器 + 向量工具
    Bench.swift                     六项验证与基准
    Util.swift                      单位换算、进程启动时刻、内存（footprint + RSS）、sha256、资源查找
    catalog.json / corpus.json      随 app 打包的资源
  Support/
    gen_catalog.py                  用 HF 只读 API 生成推荐清单（含每文件 sha256）
    gen_corpus.py                   生成测试语料（近义句 / 互译句 / 无关句 / 合成文档 / 查询）
    build_metallib.sh               手工编 mlx.metallib（需要 Metal Toolchain）
    python_reference.py             Python 参考实现，与 Swift 向量对照
    assemble_results.py             把各步中间 JSON 汇总成结果文件
    Info.plist                      .app 的 Info.plist
```

**构建产物一律不落在项目目录**（这里是 iCloud Drive）：

```
~/Library/Caches/brosis-build/e9/        SwiftPM scratch、.app、中间结果
~/Library/Application Support/brosis-m0/models/<id>/   模型（可用 BROSIS_E9_MODELS 改）
```

---

## 依赖（2026-09-07 解析到的版本）

| 包 | 版本 | 用到的产品 |
|---|---|---|
| [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | **3.31.4**（`exact`） | `MLXEmbedders`、`MLXLMCommon`、`MLXLLM` |
| [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.31.6（由上面传递引入） | `MLX`、`Cmlx` |
| [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) | **1.3.4**（`exact`） | `Tokenizers` |

包名说明：2026 年语言模型库已经从 `mlx-swift-examples` **拆到独立仓库 `mlx-swift-lm`**（主版本进到 3.x，
把 tokenizer 与 downloader 解耦了）。`mlx-swift-examples` 还在，但只留示例应用。所以这里用 `mlx-swift-lm`。

`MLXEmbedders` 的类型注册表里有 `"qwen3"`，所以 Qwen3-Embedding 是原生支持的。

**没有**依赖 `MLXHuggingFace` 宏和 `swift-huggingface`：`TokenizerLoader` 适配器手写在 `Embed.swift` 里
（等价于 `#huggingFaceTokenizerLoader()` 的宏展开），这样省掉 swift-syntax 宏插件，权重也全部由我们自己的下载器管。

---

## 用法

```bash
E9=tools/e9
APP=~/Library/Caches/brosis-build/e9/brosis-e9.app/Contents/MacOS/brosis-e9

# 生成清单与语料（联网只读 HF API）
python3 $E9/Support/gen_catalog.py > $E9/Sources/brosis-e9/catalog.json
cp $E9/Sources/brosis-e9/catalog.json $E9/catalog.json
python3 $E9/Support/gen_corpus.py  > $E9/Sources/brosis-e9/corpus.json

# 构建 + 签名（见下面"Metal 着色器库"一节）
MLX_METALLIB=<某个 mlx.metallib> $E9/build_app.sh

# 只想要命令行二进制的话：
swift build --package-path $E9 --scratch-path ~/Library/Caches/brosis-build/e9 -c release
```

子命令：

| 命令 | 作用 |
|---|---|
| `env` | 打印运行时环境、metallib 查找结果，并真跑一次 GPU 运算 |
| `catalog` | 列出推荐清单（含"本机内存够不够"的置灰判断） |
| `download --id <id>` | 按清单下载 + 逐文件 sha256 校验 + 原子入库 |
| `import --id <id> --from <dir>` | 从本地目录复制进来 + 校验 + 入库 |
| `verify --id <id>` | 重新逐文件校验已装的模型 |
| `embed --id <id> [--text ...]` | 跑一条嵌入，打印加载耗时、维度、内存（footprint 与 RSS 都有） |
| `bench --id <id> --out a.json` | 完整的六项验证与基准 |
| `generate --id <id> [选项]` | 跑生成（D19 叙述 / 抽取），带 token 计量、非思考模式、温度 0、重复确定性 |

`embed` / `bench` / `generate` 通用选项：

| 选项 | 说明 |
|---|---|
| `--out <path>` | 结果落盘成 JSON（便于溯源；`embed` 也支持） |
| `--cache-limit-mib <n>` | **在加载模型之前**限制 MLX 的缓冲池，`0` = 关掉。不给就是 MLX 默认（等于 `memoryLimit`，Max 上约 121.6 GiB、Air 上 15.20 GiB，都等于不限） |

`generate` 专有选项（对应计划 3.10「温度 0、关闭思考」的要求）：

| 选项 | 默认 | 说明 |
|---|---|---|
| `--id <清单 id>` | `Qwen3.5-4B-MLX-4bit` | 走 `ModelStore.directory(for:)`；也可以 `--dir <目录>` 直接指目录 |
| `--prompt <文本>` | 一句示例 | 提示词 |
| `--prompt-file <路径>` | — | 从文件读提示词。长台账用这个，别塞进命令行 |
| `--system <文本>` | 无 | 系统指令（`ChatSession` 的 `instructions`） |
| `--no-think` | 关（= 思考模式开） | 关闭思考模式。走 `additionalContext` 传 `enable_thinking=false`，Qwen3.5 的 `chat_template.jinja` 见到它就直接吐 `<think>\n\n</think>\n\n` 前缀 |
| `--temperature <f>` | **0** | |
| `--top-p <f>` | 1 | |
| `--max-tokens <n>` | 512 | 真正的 `GenerateParameters.maxTokens`，不是旧版那个「字符数 > maxTokens×4 就截断」 |
| `--repeat <n>` | 1 | 同一提示连跑 n 次，**每次新建 `ChatSession`**（否则第 2 次会看见第 1 次的输出）；结果里给 `answersIdentical` |

输出 JSON 的关键字段：`promptTokens` / `generationTokens` / `promptTokensPerSecond` /
`tokensPerSecond` / `timeToFirstTokenSeconds` / `generateSeconds` / `loadSeconds` /
`thinkingOn` / 按 `</think>` 切开的 `thinking` 与 `answer`（各带字符数）/ `output` 全文 /
`memoryAfterLoad` / `memoryWithModelLoaded` / `peakFootprintMiB` / `peakResidentMiB` /
`gpuPeakMiB` / `cacheRelease` / `thermalStateAtStart` 与 `thermalStateAtEnd`。

**`--cache-limit-mib` 为什么重要**：MLX 的缓冲池默认不限、且进程结束前不还给系统。
本机实测同一份批量基准，峰值 `phys_footprint`：

| 缓冲池上限 | 峰值 footprint | 吞吐 |
|---|---|---|
| 默认（不限） | 6,355.9 MiB = **6.21 GiB** | 70.2 条/s |
| 1024 MiB | 2,761.9 MiB = 2.70 GiB | 68.5 条/s（−2.4%） |
| **256 MiB** | 1,992.4 MiB = **1.95 GiB** | 68.3 条/s（−2.8%） |
| 0（关掉） | 1,839.0 MiB = 1.80 GiB | 65.7 条/s（−6.4%） |

四档的语义 / MRL / 确定性结果**逐位相同**——限缓存只改内存与速度，不改数值。
`bench` 跑完还会主动 `Memory.clearCache()`，把 footprint 从 6,355.9 MiB 拉回 893.3 MiB，
这是 M1 夜间任务"跑完立刻释放"的依据。

下载相关选项：

| 选项 | 说明 |
|---|---|
| `--primary <url>` | 默认 `https://huggingface.co` |
| `--mirror <url>` | 默认 `https://hf-mirror.com` |
| `--force-base <url>` | 跳过探测，强制用某个源 |
| `--simulate-interrupt <字节数>` | 先只下前 N 字节再走 `Range` 续传，用来实测断点续传 |
| `--out <path>` | 把这一步的结果写成 JSON |

环境变量：

| 变量 | 说明 |
|---|---|
| `BROSIS_E9_MODELS` | 换模型根目录（做往返测试时很有用） |
| `BROSIS_E9_RESOURCES` | 换 `catalog.json` / `corpus.json` 的查找目录 |
| `MLX_METALLIB` | 指定现成的 `mlx.metallib` 给 `build_app.sh` |

---

## Metal 着色器库（必读）

`swift build`（SwiftPM **命令行**）**不编译 `.metal`**，mlx-swift 的 README 自己写了
"SwiftPM (command line) cannot build the Metal shaders"。不处理的话，跑起来就是：

```
MLX error: Failed to load the default metallib. library not found ...
```

两条出路：

1. **装 Metal Toolchain（推荐，正式发版必须）**
   ```
   xcodebuild -downloadComponent MetalToolchain
   ```
   之后 `build_app.sh` 会自动调 `Support/build_metallib.sh`，用 mlx 自己 CMake 里那组 flag
   （`-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions`）
   把 `Source/Cmlx/mlx-generated/metal/` 下的 9 个基础 kernel 编成 `mlx.metallib`。
2. **借一个现成的**（本次用的应急手段）：本机 MLX Python wheel 里就有
   `.../site-packages/mlx/lib/mlx.metallib`。**版本要对得上**（mlx-swift 0.31.6 内含 MLX 0.31.1，
   本次借的是 0.31.2 的），而且 wheel 是非 JIT 构建、metallib 是全量的（119.64 MiB），
   **app 体积会明显偏大**。只适合验证，不适合发版。

**放在 `.app` 里的位置**：必须是

```
Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib
```

不要放 `Contents/MacOS/mlx.metallib`——**`Contents/MacOS/` 下的任何文件都被 codesign 当作嵌套代码**去校验签名，
而 metallib 是 **MTLB 格式**（`file` 报 `MetalLib executable (MacOS)`，魔数 `MTLB`），**不是能单独签名的 Mach-O**，
于是直接报 `code object is not signed at all / In subcomponent: .../Contents/MacOS/mlx.metallib`。
换句话说，拒绝的原因是**位置**，不是格式。mlx 的查找顺序见 `Support/build_metallib.sh` 的注释。

---

## 签名与公证

`build_app.sh` 用固定身份签：

```
Developer ID Application: <Company> (<TEAMID>)
--options runtime --generate-entitlement-der --timestamp
```

**不带任何 entitlement**。实测（见结果文件第 5 节）Metal、运行时 JIT 编译 kernel、safetensors 加载
在裸 hardened runtime 下全都正常，`allow-jit` / `allow-unsigned-executable-memory` /
`disable-library-validation` **都不需要**。要加也可以：`ENTITLEMENTS=<plist> build_app.sh`。

**公证需要你先做一次性配置**（脚本第 9 步会自动检测，没配就打印这几行）：

```bash
# 二选一，Team ID 固定 <TEAMID>
xcrun notarytool store-credentials brosis \
    --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>
# 或用 App Store Connect API key
xcrun notarytool store-credentials brosis \
    --key <AuthKey_XXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
```

配好之后：

```bash
APP=~/Library/Caches/brosis-build/e9/brosis-e9.app
ditto -c -k --keepParent "$APP" /tmp/brosis-e9.zip
xcrun notarytool submit /tmp/brosis-e9.zip --keychain-profile brosis --wait
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"     # 期望 accepted
```

App 专用密码在 appleid.apple.com 生成，需要你自己输入。

---

## Air（M4 / 16 GB，无风扇）复测清单

本机基线是 M4 Max / 128 GiB，下面这几项在 Air 上一定不同，M1 之前必须在公司机上重跑。

> **口径提醒（评审 F8）**：Apple Silicon 统一内存里 **Metal 缓冲计入 `phys_footprint`，不计入 RSS**。
> 批量嵌入时 RSS 会把 6.21 GiB 的工作负载报成 766 MiB，低估约 8 倍。
> **一律看 `/usr/bin/time -l` 的 `peak memory footprint`（结果 JSON 里是 `peakFootprintMiB`），不要用 `maximum resident set size`。**

| # | 项 | 本机基线 | 在 Air 上怎么测 |
|---|---|---|---|
| 1 | **首次加载** | 热 0.391 s（5 次均值 0.387–0.396，进程启动 → 第一条向量）；**冷启动本机也没测**（`sudo purge` 要密码） | `sudo purge` 后或重启后**第一次**跑 `embed --out cold.json`，记 `secondsFromProcessStartToFirstVector`；再连跑 5 次取热态 |
| 2 | **内存峰值（footprint，不是 RSS）** | 单条嵌入 **888 MiB**；批量基准 **6.21 GiB**（不限缓存）/ **2.70 GiB**（限 1024 MiB）/ **1.95 GiB**（限 256 MiB）/ **1.80 GiB**（关缓存）。同一次运行的 RSS 都只有 ~766 MiB | 看 `time -l` 的 **`peak memory footprint`**（或 JSON 的 `peakFootprintMiB`）。**必须至少跑 `--cache-limit-mib 256` 和 `0` 两档**，确认 16 GiB 上不进 swap；同时记 `memory_pressure` 与 `sysctl vm.swapusage`。GPU 峰值随批大小涨，批 16 / 8 / 4 各一次找拐点 |
| 3 | **吞吐** | 70.2 条/s、12,328 token/s（批 16、每条 500 字符，不限缓存）；限 256 MiB 时 68.3 条/s | 同一份 `corpus.json`、同样批 16 跑 `bench`，再补批 8 / 批 4，以及 `--cache-limit-mib 256` |
| 4 | **热状态** | 全程 `nominal`（单次基准只有 3 s，几乎没升温） | 连续跑 10 分钟嵌入，每分钟记一次 `ProcessInfo.thermalState` 与当时吞吐；出现 `fair` / `serious` 记时间点 |
| 5 | 下载器 | 直连 11.33 MiB/s、镜像 11.72 MiB/s（都经本机代理 127.0.0.1:<port>） | 公司网络下直连与镜像各一次，记 `baseUsed` 与探测耗时；带 `--simulate-interrupt` 验证续传 |
| 6 | Gatekeeper / MDM | 未公证 → `spctl rejected` | 公证并 staple 后拷过去，`spctl -a -vv -t exec` 应 `accepted`；确认 MDM 不额外拦 |
| 7 | 磁盘 | app 159.55 MiB + 模型 619.02 MiB（`du` 631.24 MiB） | 与 D7 的 10 GB 原文配额一起算可用空间 |
| 8 | 向量一致性 | 同批构造逐位相同；换批大小差 4.04×10⁻⁴ | 跨机器大概率不逐位相同，确认余弦差异仍在 10⁻⁶ 量级（关系到 D17 能不能跨设备共享向量） |

模型不必重下，从本机拷目录过去用 `import` 即可（会重新校验 sha256）：

```bash
tools/e9/build_app.sh
APP=~/Library/Caches/brosis-build/e9/brosis-e9.app/Contents/MacOS/brosis-e9
"$APP" env
"$APP" import --id Qwen3-Embedding-0.6B-8bit --from <拷过去的目录>

# 1) 冷启动（要管理员密码）
sudo purge && /usr/bin/time -l "$APP" embed --id Qwen3-Embedding-0.6B-8bit --out air_cold.json

# 2) 热态首次加载 × 5
for i in 1 2 3 4 5; do
  /usr/bin/time -l "$APP" embed --id Qwen3-Embedding-0.6B-8bit \
    --out air_embed_$i.json > /dev/null 2> air_embed_$i.err
done

# 3) 内存与吞吐：三档缓冲池上限，每次都抓 peak memory footprint
for L in "" "--cache-limit-mib 256" "--cache-limit-mib 0"; do
  /usr/bin/time -l "$APP" bench --id Qwen3-Embedding-0.6B-8bit $L \
    --out air_bench.json --crosscheck-out air_vec.json 2>&1 \
    | egrep "maximum resident set size|peak memory footprint"
done
memory_pressure | tail -5 ; sysctl vm.swapusage
```

---

## 已知限制

1. **家里机的 metallib 是借来的**（见上），app 159.55 MiB 只是上限。公司机（Xcode 26.6 自带 Metal Toolchain）已实测：`build_app.sh` 现编的 JIT 版 metallib 只有 2.99 MiB，app **43.12 MiB**，见 `tools/bench/results/e9_air_2026-09-07.md`。
2. **Gemma 4 26B-A4B 加载不了**：mlx-swift-lm 3.31.4 的 Gemma4 只实现稠密版，MoE 的 `experts` / `router`
   权重报 `unhandledKeys`。D19 高档位要改选稠密模型（`qwen3_5` / 稠密 `gemma4` 都已在注册表里），
   或等上游支持，或走 D20 的线上通道。
3. **换批大小会改变向量数值**（4.04×10⁻⁴ 量级）。入库时要固定批构造，比较向量时用余弦阈值而不是字节相等。
4. **MLX 缓冲池默认不限**，批量嵌入的 `phys_footprint` 峰值能到模型体积的 10 倍（619 MiB 模型 → 6.21 GiB）。
   M1 的嵌入服务启动时必须设 `Memory.cacheLimit`（本工具的 `--cache-limit-mib`，建议 256 MiB），
   批处理结束调 `Memory.clearCache()`。**只看 RSS 会完全错过这件事**（RSS 全程只有 ~766 MiB）。
5. **`generate` 已经不是最小验证了**（2026-09-07 补强）：温度 0、`--no-think`、真正的 `maxTokens`、
   `--cache-limit-mib`、token 计量与 `--repeat` 确定性都做了，实测见下一节。
   **还没做的是 3.10 的另外两条**：JSON schema 约束（现在只能在提示里要求，靠外部脚本 `json.loads` 校验）
   与失败重试一次。这两条连同提供方抽象一起属于 M2。
6. **清单现在有两项可下载**：`Qwen3-Embedding-0.6B-8bit`（619.02 MiB）与
   `Qwen3.5-4B-MLX-4bit`（2,919.32 MiB = 2.851 GiB）。Gemma 4 26B-A4B 仍是 `local-import` 占位、
   在 16 GiB 机器上置灰。高级入口（手填任意 HF 仓库 id、标记"未验证"）没做，M1 再补。
7. **Qwen3.5-4B 是多模态仓库，Swift 只用得上文本塔**：`model.safetensors` 里 1,221 个张量中有 297 个是
   `vision_tower.*`，占 **636.13 MiB（21.98%）**。`Qwen35Model.sanitize` 会把它们丢掉，
   所以这 636 MiB **下载了、占磁盘、但不进内存**。要省这一份得自己重打包权重，M0 不做。
8. **逐块读文件的循环必须包 `autoreleasepool`（2026-09-07 验收时已修）**。修复前下载 2.85 GiB 模型时进程 footprint 峰值
   5,819.2 MiB、`verify` 同一模型 2,935.8 MiB——不是下载器把响应体攒在内存里（`URLSession.download(for:)` 本来就流式落盘），
   而是 `FileHandle.read(upToCount:)` 返回的 `Data` 是 autorelease 对象，命令行工具主线程没有 RunLoop、池子到循环结束才清空。
   `Util.swift`（`Hashing.sha256`）与 `Downloader.swift`（`append`）的循环体各包一层 `autoreleasepool` 后实测：
   `verify` 2.9 GiB 模型 **2,935.8 → 9.4 MiB**、619 MiB 模型 625.4 → 9.2 MiB，`download` 619 MiB 模型 **1,239.4 → 29.8 MiB**，耗时与 sha256 结果不变。
   M1 的下载器 / 校验器沿用这个写法。

---

## D19 Qwen3.5-4B 在 Air 上的数字

2026-09-07 在同一台 Air（Mac16,12 / 16 GiB / 无风扇）上下载并实测了 D19 定案的
`mlx-community/Qwen3.5-4B-MLX-4bit`。**全部数字与原始 JSON 见
`tools/bench/results/d19_qwen35_4b_air_2026-09-07.md` 与同名 `.json`。**

一句话：**Swift 侧能加载、非思考模式有效、温度 0 逐字确定、JSON 抽取 5/5 有效；
但思考模式在这台机器上不可用（4,000 token 都跑不完思考段），必须一直带 `--no-think`。**

| 项 | 数字 |
|---|---|
| 下载（直连 huggingface.co） | 2,919.32 MiB / 235.65 s = **12.39 MiB/s**，12 个文件 sha256 全对 |
| 热态加载（进程启动 → 模型就绪） | **0.800 s**（3 次 0.771 / 0.846 / 0.783） |
| 叙述（837 token 输入 → 147 token 输出） | 预填 **317.4 tok/s**、TTFT **2.65 s**、生成 **35.4 tok/s**、全程约 6.7 s |
| 长输入预填 | 3,664 tok → **344.2 tok/s**（TTFT 10.68 s）；5,354 tok → **339.6 tok/s**（TTFT 15.80 s） |
| 峰值 footprint（`--cache-limit-mib 256`） | 叙述 **3,500.0 MiB = 3.418 GiB**；长输入 3,594–3,687 MiB |
| 峰值 footprint（不限缓冲池） | **4,137.5 MiB = 4.040 GiB**（+637.5 MiB，吞吐一模一样） |
| 磁盘 | `du -sk` **2,929.62 MiB = 2.861 GiB** |

`bench` 那份「限缓存是免费的」结论在生成上同样成立，而且更干脆：256 MiB 与不限两档的
`tokensPerSecond` 差 0.2%、输出**逐字相同**。
