# app/ — brosis.app 采集端（M1 / R1 · T4，R2 · T7 + T5 + T8 + T10 + T9）

对应：`docs/实施计划.md` 的 **3.1**（采集端 + 单一存储服务）、**3.3**（采集策略与完整性状态）、
**3.5**（密钥与锁定状态机）、**3.12**（应用采集清单）、**4.2**（规则脱敏、暂停触发器）、
**2.2 硬约束 1–3**；`docs/可行性调研报告.md` 3.3、3.4；评审 **F1**（单一持钥者）、**F5**（状态分离、门控不丢证据）。

**M1 起采集端不再自己开库。** 唯一持钥者是 `../core` 的 `BrosisCore`（SQLCipher 加密库），
`app/` 通过 `Recorder` 这层薄壳写进去。M0 的明文测试库 `~/Library/Application Support/brosis-m0/`
**原样保留、不再读写、不迁移**——它是 E4 的原始观测数据，schema 与 v1 完全不同。

> **不含 3.12 的应用清单窗口**（那一页 GUI 还没做），只有它的数据层、内置默认清单与菜单栏快捷项。
> 适配器与局部 OCR 也还没做。**MCP 已经接上了**（R2 / T5）：本地 IPC 服务端在这个进程里，
> 见 8.9 与第 10 节。

**R1 验收复核后的六处修订**（本文件已同步）：

1. **用户显式策略不再被默认判定覆盖**：`app_policies` 只在"库里确实没有这一行"时插入，
   库没开时的判定是**临时的**（不缓存、不落库、不记事件）——见 8.2；
2. **私密浏览命中时，窗口标题 / URL / 文件路径连同正文一起不存**——见 8.4；
3. **窗口标题与 URL 也过入库前脱敏**（原来只有正文过）——见 8.3；
4. `locking` 期间到达的唤醒 / 解锁触发会在关库落地后**补做**，不再被丢掉——见 8.1；
5. `app_launched` 只在本次进程第一次开库时写，之后每次解锁写 `store_unlocked`；
6. 第 9 节的运行期事件 kind 一览补全到 **54 种**（原来漏了权限引导的 6 种）。

**M1 第二轮（R2 / T7）又改了八处**（本文件已同步；每条都有自检或纯函数断言，
见 `tools/bench/results/m1_r2a_cleanup_2026-09-07.md`）：

1. **被延后的纯定时截图不再被当成事件截图**：`finish()` 重排队时不再追加 `queued`，
   `capture_stats.trigger` 里从此不会出现 `queued`——见 8.6；
2. **`ax_bfs_limit_hit` 的 `hit=depth` 改成"确实有子树没展开"**（原来只要有元素落在最后一层就报）——见 8.5；
3. **兜底间隔改 `UserDefaults` 后要重启 app 才生效**（值在进程启动时解析一次）——见 8.6；
4. **`recorder_dropped` 在解锁当次就落库**，不再晚一个锁定周期——见第 9 节；
5. **非严格模式下的锁屏不再取消"补做的开库"**（它本来就不关库）——见 8.1；
6. **版本号单一来源**：`build_app.sh` 从 `BuildInfo.swift` 读 `version` 写进 `Info.plist`，自检核对——见第 3、4 节；
7. **`setPaused` 只在状态变化时写 `capture_paused` / `capture_resumed`**（原来每次 `syncSubsystems` 都写一条）；
8. **新增菜单项「导出存储统计…」**（加密库的统计在库外读不到）——见 8.8。

**M1 第二轮（R2 / T5）接上了 MCP**（计划 3.1 / 3.6，见
`tools/bench/results/m1_r2a_mcp_2026-09-07.md`）：

1. **本地 IPC 服务端进了这个进程**（`IPCService.swift`，挂在 `LockController` 上）：
   数据目录下的 `ipc.sock`（0600）、对端同 Team ID 校验、按客户端限流——见 8.9；
2. **`brosis-mcp` 一起进了 bundle**（`Contents/MacOS/brosis-mcp`，先单独签再签 bundle）——见第 2、3 节；
3. **3.5 的相位直接决定 MCP 服不服务**：`paused` 与 `locked` 都拒绝，锁定期间的审计解锁后补写；
4. **菜单里多一行 MCP 状态**；自检多 8 项（socket 权限、无 grant 全拒、两档字段级别、审计、
   应用白名单也裁出现上下文、对端校验）；
5. 配置 Claude Code 的步骤见**第 10 节**。

## 1. 边界（先说不做什么）

| 不做 | 原因 |
|---|---|
| 不做 OCR | 归第二轮（E5 定完适配器名单与阈值再上 Vision accurate 视口 OCR） |
| 不保存任何图像 | 帧像素只在内存里算一次 64 bit dHash + 32×32 网格，随即释放；库里只有哈希与面积比 |
| ~~不存 AX 正文~~ **M1 起存**（这是与 M0 最大的差别） | 正文经**入库前脱敏**后写进 `text_versions` / `occurrences`，`region` 记 AX 角色；库是加密的（2.2 硬约束 1） |
| 不做视口裁剪 | 计划 3.3 要求"只入库视口内实际显示的内容"，那要等 E5 的适配规则。本轮先用**单角色 20 000 字符**的粗上限兜住，命中写事件、不静默截断 |
| 不做 3.12 的应用清单窗口 | 第二轮。本轮只做数据层 + 内置默认清单 + 菜单快捷项 |
| 不用已废弃的旧版窗口截图 API | macOS 15 起废弃；截图全部走 ScreenCaptureKit |
| 不申请「输入监控」 | 只用 `CGEventSource` 的计数与空闲秒数，没有键值内容（报告 3.3） |
| 不做公证 | 归分发管线；`spctl` 评估预期为 `rejected: Unnotarized Developer ID` |

## 2. 目录

```
app/
├── Package.swift                     SwiftPM 可执行目标 brosis；依赖 .package(path: "../core")
│                                     与 Sparkle 2（唯一的外部依赖，exact "2.9.6"，见 Package.resolved）
├── build_app.sh                      swift build（app + core 的 brosis-mcp）→ 组装 .app →
│                                     先签内嵌的 brosis-mcp 再签 bundle → 验证
├── Sources/brosis/
│   ├── main.swift                    入口；--version / --self-check / --dump-vectors / --dump-ocr
│   │                                 都不创建 NSApplication
│   ├── BuildInfo.swift               版本、bundle id、ObservationTrigger 及其到 core 枚举的收敛
│   ├── AppDelegate.swift             菜单栏（录制 / 暂停 / 锁定 / 权限缺失）、一键暂停、
│   │                                 「暂停采集当前应用（今天 / 永久）」、锁定 / 解锁、登录项、
│   │                                 「导出存储统计…」、「应用采集清单…」、「检查更新…」、
│   │                                 新应用一次性提示行
│   ├── LockController.swift          3.5 锁定状态机：LockPolicy（纯函数）+ 取钥 / 开库 / 校验 / checkpoint / 关库
│   │                                 并持有下面这个 IPC 服务端（它是本进程唯一拿得到 Store 的地方）
│   ├── IPCService.swift              3.1 / 3.6 的本地 IPC 服务端：<数据目录>/ipc.sock（0600）、
│   │                                 对端同 Team ID 校验（写死，不读环境变量）、按客户端限流
│   ├── Recorder.swift                写入 BrosisCore.Store 的唯一出口 + DataLocation（D16）+ AXTextSummary
│   ├── CapturePolicy.swift           3.12 三档数据层、内置默认不采集清单、全局默认档、
│   │                                 新应用一次性提示、今日临时暂停、私密浏览判定
│   ├── Policies/                     **3.12 应用采集清单界面（M1 R2 / T9）**
│   │   ├── PolicyList.swift          视图模型（纯函数）：三处数据源合并、分组、排序、过滤、
│   │   │                             改档状态机 + 自检用的合成向量
│   │   └── PoliciesWindow.swift      AppKit 窗口：NSTableView（分组行 + 每行一个档位弹出菜单）、
│   │                                 顶部全局默认档与搜索框、降档时的删数据询问
│   ├── Redaction.swift               入库前规则脱敏（gitleaks 子集 + Luhn + 验证码）+ 33 条测试向量
│   ├── Permissions.swift             TCC 探测与请求；SystemState（空闲、安全输入、锁屏）
│   ├── EventSkeleton.swift           NSWorkspace 通知 + AXObserver + 屏保通知 + 显示器归属 + 策略闸门
│   ├── AXSupport.swift               AX 读取（进程级 0.5 s 超时）、Chromium/Electron 两路判定 +
│   │                                 AXManualAccessibility、按 bundle id 的 BFS 限额、正文与统计
│   ├── Adapters/                     **适配规则引擎（3.3，M1 R2 / T8）**
│   │   ├── AXNodeSource.swift        读 AX 的协议 + 真实实现 LiveAXNode + 测试用合成树 SyntheticAXNode
│   │   ├── AdapterRule.swift         规则的纯数据结构：区域定位 / 读取方式 / 视口处理 / 气泡布局
│   │   ├── AdapterRegistry.swift     首批规则：Safari、Claude 桌面版、飞书、微信 + 通用兜底
│   │   ├── AdapterEngine.swift       执行规则：定位 → 读取（含视口裁剪）→ 排 OCR → 判完整性
│   │   ├── BubbleAttribution.swift   气泡归属（单聊左右 / 群聊昵称 / 语音标签）+ 合成布局结构
│   │   └── AdapterVectors.swift      四棵合成 AX 树与全部判定用例（自检与 --dump-vectors 共用）
│   ├── OCR/                          **视口 OCR（3.3 / D24，M1 R2 / T8）**
│   │   ├── OCRTrigger.swift          三类触发条件（纯函数）+ 同一窗口区域的最小间隔限流
│   │   ├── ReadingOrder.swift        按 boundingBox 行聚类重建阅读顺序 + 低置信 token 判定
│   │   ├── ViewportOCR.swift         裁剪（AX 坐标 → 显示器局部 → 像素）+ Vision accurate
│   │   ├── CaptureCoordinator.swift  把 AX 扫描、截图帧、OCR、采样审计接起来的协调者
│   │   ├── OCRSelfTest.swift         自绘图像基准（CER / 标识符召回，口径同 tools/bench/ocr_bench）
│   │   └── OCRDump.swift             --dump-ocr：把样张的真值与识别原文摊开
│   ├── CaptureController.swift       按需截图（SCScreenshotManager）+ 帧门控 + 定时兜底 + 策略排除
│   ├── DHash.swift                   9×8 灰度差分哈希（64 bit）
│   ├── PermissionGuide.swift         权限引导窗口
│   ├── StatsExport.swift             「导出存储统计…」：stats() + statsDetail() → 数据目录的 JSON
│   ├── ExportWindow.swift            **加密导出（3.8 / D7，M2 d / T16）**：ExportController
│   │                                 （后台队列跑导出、配额通知联动）+ ExportWindowController
│   │                                 （目标目录 / 范围 / 口令两次输入 / 进度 / 结果与提示文案）
│   ├── ExportSelfCheck.swift         加密导出的临时库往返冒烟（由 SelfCheck 调一次）
│   ├── Updater.swift                 Sparkle 2 签名更新：Info.plist 的 SU* 配置检查（纯函数）+
│   │                                 「检查更新…」菜单入口（默认不联网、fail-closed）
│   └── SelfCheck.swift               无 GUI / 无 TCC / 不碰钥匙串的自检（90 项）+ --dump-vectors 判定表转储
├── Support/
│   ├── Info.plist                    LSUIElement=1 + 三个 usage string
│   ├── brosis.entitlements           不沙盒 + apple-events
│   └── com.brosis.agent.plist        SMAppService LaunchAgent
└── Resources/exclusions.txt          3.12 内置默认「不采集」清单（与代码内清单取**并集**）
```

**bundle 里还有一个可执行文件**：`Contents/MacOS/brosis-mcp`（core 的产品，计划 3.6 的薄 MCP）。
`build_app.sh` 会一起构建、放进 bundle、**先单独签它再签外层 bundle**——
`codesign` 对 bundle 签名不会替 `Contents/MacOS` 里的第二个 Mach-O 生成签名，
漏了的话 `--verify --deep --strict` 会报 "code object is not signed at all"。
两者用同一个 Developer ID 身份，所以 Team ID 相同，能过 IPC 的对端校验（见第 10 节）。

**已删除**：M0 的 `Store.swift`（明文 SQLite 测试库）。它的四张表按下表搬进了 core：

| M0 明文库 | M1 加密库（core） |
|---|---|
| `observations`（app / title / url / document / trigger / source_state / idle_s） | `observations` + `apps` / `windows` / `urls` / `files` 四张规范化对象表 |
| `ax_texts`（只有角色 / 节点数 / 字符数） | `text_versions` + `occurrences`（**正文本身**，`region` = AX 角色） |
| `frame_stats` | `capture_stats` |
| `runtime_events` | `jobs`（`type = 'runtime_event:<kind>'`，见 core 的 `recordRuntimeEvent`） |

## 3. 构建

```bash
# 项目在同步盘里，构建产物一律落在 ~/Library/Caches/brosis-build/ 下
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH=~/Library/Caches/brosis-build/m1-app \
  "<项目目录>/app/build_app.sh"
```

**前置**：`core` 的 vendor 源码要先就位（一次即可）——`sh core/setup.sh`，它会把 SQLCipher
amalgamation 与 sqlite-vec 放进 `~/Library/Caches/brosis-build/sqlcipher/vendor/` 并在 `core/Vendor/`
下建符号链接（`core/Vendor/{SQLCipher,SqliteVec}` 与 `core/Sources/CSQLCipher/include`）。
没有它 `app` 编不过（依赖链 `brosis → BrosisCore → SQLCipher`）。

**`DEVELOPER_DIR` 是必须的**：本机 `xcode-select` 指向 CommandLineTools，不加前缀拿不到完整工具链。

**版本号只有一个来源**：`Sources/brosis/BuildInfo.swift` 的 `static let version`。
`Support/Info.plist` 里放的是 `__VERSION__` 占位符，`build_app.sh` 组装时把
`CFBundleShortVersionString` 与 `CFBundleVersion` **都**写成这一串（两者同串；本项目不上
App Store，不需要"同一版本多次构建"的递增号，真要区分就在末尾追加 `.N`），
写完立刻读回来核对，自检再从 `Bundle.main` 比一次——手改 plist 没有意义，会被覆盖。

脚本步骤：确认签名身份 → `swift build --scratch-path`（app）→ **`swift build --product brosis-mcp`
（core，另一个 scratch：`${SCRATCH}-core`）** → 组装 bundle（写版本号、拷进 `brosis-mcp`）并
`plutil -lint` + 校验**八个**必备键 → **先签 `Contents/MacOS/brosis-mcp`**（hardened runtime，
identifier `com.brosis.app.mcp`，不带任何权利）→ 签外层 bundle（`--options runtime --timestamp
--entitlements`）→ `codesign --verify --deep --strict`（外层与 `brosis-mcp` 各验一次）→
**核对两者 Team ID 一致**（不一致就 `fail`，否则 IPC 的对端校验一定过不去）→
`codesign -dv --verbose=4` → 打印 entitlements → `spctl` 评估 → 打印
`claude mcp add` 与 `admin grant add` 两条命令。

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CONFIG` | `release` | 传给 `swift build -c` |
| `SCRATCH` | `~/Library/Caches/brosis-build/app` | SwiftPM scratch 与 .app 输出目录 |
| `CORE_SCRATCH` | `${SCRATCH}-core` | core 包的 scratch（编 `brosis-mcp` 用；两个 SwiftPM 包不能共用一个 scratch） |
| `IDENTITY` | 自动探测的 `<Developer ID Application 身份>` | 签名身份 |
| `SKIP_SIGN` | `0` | `1` = 只组装不签名（此时不要用于任何 TCC 测试） |
| `TIMESTAMP` | `yes` | `none` = 离线时跳过 Apple 时间戳服务（这样签的包不能公证） |

只想编译不组装：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "<项目目录>/app" \
  --scratch-path ~/Library/Caches/brosis-build/m1-app -c release
```

### 3.1 应用图标

`Resources/AppIcon.icns` 由 `Support/icon/make_icon.swift` 生成（只用 CoreGraphics / ImageIO），`Info.plist` 里
`CFBundleIconFile` / `CFBundleIconName` = `AppIcon`，`build_app.sh` 随 `Resources/` 一起拷进 bundle。

### 3.2 分发：DMG、公证、Sparkle 签名更新（计划 4.2）

脚本在仓库根的 `dist/`：

```
dist/
├── build_dmg.sh    build_app.sh → 压缩 DMG（含 /Applications 快捷方式）→ 签 DMG →
│                   公证 + staple（可 --skip-notarize）→ spctl 评估 → sha256 与 manifest.json
├── make_appcast.sh Sparkle 的 generate_appcast：给归档目录里的 DMG 生成签名的 appcast.xml
└── RELEASE.md      发布清单（一次性配置、七步流程、两台机器安装验证、TCC 不丢的判据）
```

```bash
# 出一个可分发的 DMG（要先解锁屏幕并配好公证凭据）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/dist-app" \
  <项目目录>/dist/build_dmg.sh

# 屏幕锁定 / 还没配公证凭据时：只出一个自己能装的包
… <项目目录>/dist/build_dmg.sh --skip-notarize
```

产物在 `~/Library/Caches/brosis-build/dist/<版本>/`：`brosis-<版本>.dmg`、
`manifest.json`（版本 / sha256 / Team ID / 公证状态 / Gatekeeper 判定）、`SHA256SUMS.txt`；
DMG 同时硬链一份到 `~/Library/Caches/brosis-build/dist/appcast/`，
那是 `make_appcast.sh` 的输入目录（`generate_appcast` 要在一个目录里看到所有历史版本）。

#### Sparkle 在 bundle 里长什么样

| 位置 | 内容 |
|---|---|
| `Contents/Frameworks/Sparkle.framework` | SwiftPM 的 binaryTarget 解出来的 XCFramework，`build_app.sh` 用 `ditto` 放进去 |
| ↳ `Versions/B/{Sparkle,Autoupdate}` | 主 dylib 与安装器 |
| ↳ `Versions/B/Updater.app` | 更新时替换 app 的那个小程序 |
| ↳ `Versions/B/XPCServices/{Downloader,Installer}.xpc` | **只有沙盒应用才用得到**；brosis 不沙盒，留着是为了将来真沙盒化时不用改脚本 |

**主程序的 rpath**：SwiftPM 链出来只带一条 `@loader_path`（裸二进制跑得通，框架就在它旁边），
装进 bundle 后 `@loader_path` 是 `Contents/MacOS`，找不到框架，所以 `build_app.sh` 用
`install_name_tool -add_rpath @executable_path/../Frameworks` 补一条，并当场
`otool -l` 核对。**没走 `Package.swift` 的 `.unsafeFlags`**：带 `unsafeFlags` 的清单
不能被别的包按版本引用。

**签名**：`--deep` 不可靠（Apple 自己也不建议），所以逐个签，顺序由内向外——
两个 `.xpc` → `Updater.app` → `Autoupdate` → `Sparkle.framework` → 外层 bundle。
反了的话外层的 `CodeResources` 封印会立刻作废。每一件都带 hardened runtime 与安全时间戳
（公证要求**所有**内嵌代码都带时间戳）。签完 `build_app.sh` 会：

- `codesign --verify --deep --strict` 验封印；
- 逐个 Mach-O 问一次 `TeamIdentifier`，与主程序不一致就 fail（漏签一个，hardened runtime
  的库校验会在加载时拒绝，公证也会退回）；
- 从 bundle 里跑一次 `--version`，证明 dyld 真的按 rpath 找到了框架。

#### 更新的口径：默认不联网、fail-closed

`Info.plist` 里四个键（`build_app.sh` 会核对，改坏了构建就失败）：

| 键 | 值 | 为什么 |
|---|---|---|
| `SUFeedURL` | `https://github.com/AllenBall/brosis/releases/latest/download/appcast.xml` | 必须 https；`latest/download/<资产名>` 指向最新 release 的同名资产，所以**每次**发版都要带上 `appcast.xml` |
| `SUPublicEDKey` | 仓库里是占位符 `__SUPublicEDKey__` | 真公钥由你用 `generate_keys` 生成，放 `~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt`，构建时注入；**私钥只在你的钥匙串里** |
| `SUEnableAutomaticChecks` | `false` | 不自动检查、不弹"要不要自动检查更新"的许可框 |
| `SUAutomaticallyUpdate` | `false` | 就算将来打开自动检查，也不允许后台静默下载 / 安装 |

代码在 `Sources/brosis/Updater.swift`，两块：

- `enum UpdaterConfig`（非隔离的纯函数）：`issues(in:)` 把上面四个键逐条查一遍——
  源是不是 https、公钥是不是占位符、解出来是不是 32 字节、自动检查是不是显式 `false`。
  可以在任何线程调用，也可以直接喂自造的字典做测试。
- `@MainActor final class UpdaterController`：**只有它会创建 Sparkle 的对象**，而且是
  **懒创建**——只有用户点「检查更新…」的那一刻才 `SPUStandardUpdaterController(startingUpdater: false, …)`
  再自己 `try updater.start()`。没被点过就一个字节都不会发出去。
  配置有问题时不联网，直接弹一个说清楚原因的框。

**fail-closed 的含义**：没注公钥的构建里 `SUPublicEDKey` 是占位符（不是合法 base64），
`UpdaterConfig.issues` 当场拦下、Sparkle 的 `start()` 也会失败，
也就是**这份构建装不上任何"更新"**，而不是"没验签就装"。
`dist/make_appcast.sh` 同样会拒绝给这种构建生成 appcast。

#### 菜单项（M1 R2 / T9 已接入）

「检查更新…」在菜单栏里，位置是「导出存储统计…」之后、退出前那条分隔线之前：

```swift
menu.addItem(UpdaterController.shared.makeMenuItem())
```

菜单项自带 target/action 与可用性判定；`UpdaterController.shared` 是 `@MainActor` 单例，
`refreshMenu` 本身就在主线程。**点它之前一个字节都不会出网**（updater 是点下去那一刻才创建的）。
想在菜单上再显示一行只读状态的话，`UpdaterController.shared.statusLine()` 返回
「更新源已配置：…」或「更新未启用：…」，也不联网——当前没有显示这一行。

#### 签名身份跨版本不变（D13）

TCC 授权绑的是 `bundle id + 签名的 Designated Requirement`。换 Team、换 bundle id
都会让用户已经给过的屏幕录制 / 辅助功能授权作废。证书到期换新证书时**必须**还是
同一个 Team 的 Developer ID。升级后怎么验见 `dist/RELEASE.md` 第 7 节。

## 4. 自检（安全，不触发任何授权弹窗、不碰钥匙串）

```bash
~/Library/Caches/brosis-build/m1-app/brosis.app/Contents/MacOS/brosis --self-check
~/Library/Caches/brosis-build/m1-app/brosis.app/Contents/MacOS/brosis --dump-vectors
~/Library/Caches/brosis-build/m1-app/brosis.app/Contents/MacOS/brosis --dump-ocr
```

`SelfCheck.swift` 明确不调用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` /
`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` / `SCShareableContent` / 任何 `AXUIElement*`，
不创建 `NSApplication`，**也不用 `KeychainKeyProvider`**（那会弹钥匙串授权框）。
共 **90 项**（M0 骨架 38 → R2/T7 的 47 → R2/T5 又加了 8 项 MCP → R2/T8 又加了 21 项适配器与视口 OCR
→ R2/T9 又加了 14 项 3.12 应用采集清单）。
MCP 那 8 项是：`ipc.sock` 权限 0600、
没有 grant 全拒、加了 grant 之后 search 命中、`fields = summary` 不回原文、`fields = evidence` 回原文、
`mcp_audit` 记了每次调用且不含查询串、**应用白名单也裁 `get_evidence` 的出现上下文**、
对端同 Team ID 校验），退出码 0 = 全通过。
**对端校验那一项分两支**：本进程有 Team ID（从签名过的 `.app` 里跑）时要求同 Team 的连接**放行**；
没有 Team ID（`swift build` 的裸二进制）时要求**一律拒绝**——两支都是断言，不是"跳过"。
**从裸二进制（`swift build` 的产物）跑是 75 项 PASS + 1 项 SKIP**：版本那一项没有 `Info.plist` 可读，会打印
`[SKIP]` 并说明，不计失败——要验它必须跑 `brosis.app/Contents/MacOS/brosis --self-check`。
**T8 加的 21 项里有 5 项真的跑 Vision**（对本进程自绘的位图，合计 10 次识别），
Vision 是本地推理、不需要任何授权，所以自检仍然不触发弹窗；
代价是自检时间从不到 1 s 涨到约 1.8 s（本机实测 `real 1.83`）。

| 组 | 项数 | 验什么 |
|---|---|---|
| core 往返 | 21 | 用 `InMemoryKeyProvider` 在**临时目录**开一个真加密库：SQLCipher 版本 / `cipher_page_size=16384` / `journal_mode=wal` / `auto_vacuum=2` / `foreign_keys=1` / 编译期 `TEMP_STORE=3`、目录 0700 与两个排除标记、写一条带两个片段的观察、按 ord 读回逐字符比对、库里搜不到脱敏前明文、**库文件字节里搜不到正文明文（带阳性对照）**、运行期事件与遥测各 1 行、`app_policies` 三档往返、**用户策略经「锁定 → 解锁」往返后不变**、**库没开时的判定是临时的（不缓存、不落库）**、**存储统计导出 JSON 往返 + 里面没有路径 / 正文**、13 项悬空引用 + `integrity_check` + FTS、关库后密钥已清零 |
| `recorder_dropped` 时序 | 2 | 另开一个临时加密库走「开库 → 关库 → 三类写入被丢弃 → 再开库」：`jobs` 只在**再开库那一次**多一行；差值计数 = 这一段真丢掉的三类写入 |
| 入库前脱敏 | 2 | 21 条正例（含窗口标题 / URL 三条）+ 12 条反例逐字符比对；Luhn 能区分卡号与订单号 / 时间戳 |
| 3.12 三档 | 8 | 三档的生效方式开关表；解析优先级 5 条；内置清单已加载且覆盖四个类别 |
| 3.5 状态机 | 4 | 21 条转移用例；7 条「`locking` 期间的开库触发要补做」用例；**11 条「锁定类触发取消补做」用例（含非严格模式的锁屏不取消）**；低磁盘阈值 = 2 GiB |
| 私密浏览 | 2 | 浏览器标题含无痕标记时命中；非浏览器不误伤 |
| dHash | 2 | 同图稳定、异图汉明距离 > 6 |
| Electron / CEF | 2 | 伪造 `.app` 正反两例 |
| 截图触发口径 | 2 | 7 条 `isEventTrigger` 用例（`periodic+queued` 不算事件触发）；`setPaused` 只在状态变化时写事件 |
| AX 深度上限 | 1 | 4 条 `depthLimitHit` 用例；已命中后不再多取一次 `kAXChildren` |
| 版本号单一来源 | 1 | `Bundle.main` 的两个版本键 == `BuildInfo.version`（裸二进制跳过） |
| **适配规则（T8）** | 6 | bundle id → 规则的路由（4 条首批 + 兜底，兜底继承按 bundle id 的 BFS 限额）；四个应用各一棵**合成 AX 树**上的完整判定：片段数、完整性、必含串、**视口外与回滚区的内容必须不出现**、该排哪些 OCR 区域 |
| **视口与可见范围（T8）** | 2 | 7 条视口相交用例（完全在内 / 部分相交 / 回滚区 / 视口下方 / 读不到 frame / 没有视口 / 零面积）；5 条 `AXVisibleCharacterRange` 裁剪用例（含越界与长度 0 不崩） |
| **completeness 四态（T8）** | 1 | 三态由适配器在合成树上判出来，`excluded` 由 3.12 档位与私密浏览先行判——四个取值各有出处 |
| **OCR 触发条件（T8）** | 2 | 三类触发条件 + 4 条反例（**AX 值变了就不 OCR**）；同一「bundle id + 区域名」的最小间隔限流（首次放行 / 半个间隔内被限 / 别的区域不受影响 / 超过间隔再放行） |
| **阅读顺序与低置信（T8）** | 2 | 3 条行聚类用例（两栏、行距紧、同行高度不齐）；D24 的低置信 token 正例 4 条 / 反例 5 条 |
| **气泡归属（T8）** | 1 | 2 份**合成布局 JSON**：单聊左 = 对方 / 右 = 自己 + 语音记 `[语音]`；群聊取气泡上方昵称且昵称行不入库成正文 |
| **视口 OCR（T8）** | 3 | 裁剪坐标（AX → 显示器局部 → 像素，含 2x 与"矩形在另一块屏上就不裁"）；**6 组自绘图像的 Vision 基准**（3 样张 × 2x/1x，标识符召回与中文行 CER）；采样审计的覆盖率口径冒烟 |
| **端到端（T8）** | 4 | 走产品路径 `CaptureCoordinator.handleFrame`：AX 全空 → 写一条 `capture_method = ocr` 的观察（region 前缀 `ocr:`、confidence 与 note 都在）；**前台已换应用时整帧不处理**（换一张自绘"屏幕"当另一个应用：跑 0 个区域、一个字都不入库，同一张图换回原应用作阳性对照就会入库）；**同一区域正文逐字节未变时不写第二条观察**；轮到采样审计 → 全窗口 OCR 对照 → `capture_audit` 一行（`method` 照抄被审计那条观察的 `capture_method`） |

**上面这张表只覆盖 M1 的那 90 项**。M2 又加了四组，明细各在自己的 `*SelfCheck.swift` 里
（`SelfCheck.swift` 每组只加一行调用，为的是并行任务不改同一段）：
第 7 组跨设备同步（T13）、第 8 组模型管理器与向量检索（T11）、第 9 组夜间叙述（T12）、
**第 10 组 MCP 检索的查询向量与整晚建索引（T15，12 项）**。
本机在**只含 T15 改动**的树上实测总数 **149 项全过**、退出码 0、
peak footprint **232.9 MiB**（不加载任何模型）；d 批其余任务各自还会再加几项，
所以合并后的总数会更大（合并 T16 之后实测 162 项）。

自检的加密库开在 `$TMPDIR/brosis-selfcheck-<pid>/`，**跑完删除**，
既不碰产品数据目录也不碰 M0 库；跑几次结果都一样。

`--dump-vectors` 把判定表逐条摊开成 Markdown 表格（正例 21 / 反例 12 / 三档开关 / 21 条转移 /
7 条补做用例 / **11 条取消补做用例** / 内置清单分类 / **四条适配规则的完整规则表 / 7 条 OCR 触发条件 /
完整性四态的判定来源 / 6 组自绘样张的 OCR 基准**，共 **11** 节），输出可以直接贴进结果文件核对。

`--dump-ocr` 只做一件事：把自绘样张的真值与 **Vision 识别出来的原文**逐行打印。
存在的理由是"召回没到"这个数字本身没法复核——看了原文才知道是**真认错了**，
还是只是 accurate 模型把 `(` `)` `:` 认成了全角（D24 / E8 早就实测过，本项目的 FTS 与查询串都折叠）。

## 5. 首次运行：**两次 TCC 授权 + 一次钥匙串授权，都必须手动**

> 下面这些步骤 Claude 不能替你做（TCC 与钥匙串弹窗只接受真人点击），需要你自己操作一次。

1. **先移到固定安装路径。** TCC 用 bundle id + 代码签名要求识别客户端，路径变化会让系统设置里出现
   多条同名项、且 LaunchAgent 的 `BundleProgram` 会失效。建议固定到 `/Applications/brosis.app`：

   ```bash
   ditto ~/Library/Caches/brosis-build/m1-app/brosis.app /Applications/brosis.app
   xattr -dr com.apple.quarantine /Applications/brosis.app   # 未公证，需要去隔离属性
   ```

2. **从 Finder 双击启动，不要从终端启动。** 从 Terminal 运行的进程，TCC 把授权记到 Terminal 头上
   （等于给所有脚本放权），brosis 自己反而拿不到（Apple DTS：`Shell scripts and TCC don't mix`）。

3. **启动后会先弹一次钥匙串授权（M1 新增）。** 3.5 的 `unlocking` 第一步是取钥：
   `KeychainKeyProvider` 在 data-protection 钥匙串里找 `com.brosis.store` / `primary-db-key`，
   没有就用 `SecRandomCopyBytes` 生成 32 字节并写入，ACL 绑本应用签名、
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（不进备份、不跨设备）。
   系统会弹一次「brosis 想使用您存储在钥匙串中的机密信息」——**点「始终允许」**。
   之后菜单里「数据库：」那一行会从 `unlocking` 变成 `unlocked`；
   如果一直停在 `locked` 并显示「开库失败：…」，把那一行的文字连同下面这条一起发回来：

   ```bash
   security find-generic-password -s com.brosis.store -a primary-db-key 2>&1 | head -5
   ```

   **换签名身份 / 重装会让 ACL 失配**，表现为取钥失败。这时删掉钥匙串条目会让**旧库再也打不开**，
   所以不要盲删；先确认库里没有你要留的数据。

4. **两项 TCC 权限**：app 一启动发现有缺就会**自动**弹系统授权框（先辅助功能、0.8 s 后屏幕录制），
   并显示「brosis 权限设置」引导窗口：两行实时状态、各自的「打开系统设置…」按钮、
   「重新请求授权」、「退出并重新打开 brosis」、「稍后再说」。窗口每 1.5 s 复查一次。
   实现在 `PermissionGuide.swift`，入口是 `AppDelegate.promptForPermissions(reason:)`。

   **屏幕录制的登记问题（公司机实测）**：macOS 26 的「录屏与系统录音」列表只在 app 真正通过
   ScreenCaptureKit 请求过内容后才出现条目，只调 `CGRequestScreenCaptureAccess()` 既不弹框也不登记。
   所以 `Permissions.requestScreenRecording()` 在未授权时会再异步取一次 `SCShareableContent`。
   若列表里仍没有 brosis，在该页点「+」手动添加 `/Applications/brosis.app` 即可。

   **注意点弹窗那一刻两行状态不会变。** 在系统设置里拨完开关后，**回到菜单栏重新展开一次菜单**：
   每次展开都会重新取权限快照（`NSMenuDelegate.menuWillOpen`）并把采集拉起来。
   **屏幕录制首次授权通常要求退出重开 app**（`kTCCServiceScreenCapture` 一般只对新启动的进程生效）。

5. **数据目录变了**（D16）。默认 `~/Library/Application Support/brosis/`，
   菜单「打开数据目录」直接跳过去。可以用 UserDefaults 换位置：

   ```bash
   defaults write com.brosis.app data.directory -string /Volumes/Work/brosis-data
   ```

   写成 iCloud Drive / Dropbox / 网络卷会**开库失败并在菜单里报错**，不会静默降级——
   拒绝逻辑在 `BrosisCore.DataDirectory.validate`（D16 / 3.9）。
   **M0 的 `~/Library/Application Support/brosis-m0/` 原样留着，本版本不读不写不迁移。**

6. **验证有没有真的在写**：库是 SQLCipher 加密的，`sqlite3` 打不开；`core` 的 `brosis-store` CLI
   只支持 `--key-file` 取钥，而产品库的钥匙在钥匙串里，所以它也读不了产品库。
   看菜单栏那一行实时计数即可：

   ```
   写入：观察 N / 事件 N / 遥测 N，锁定期间丢弃 观察 a / 事件 b / 遥测 c，写入错误 N
   ```

   数字在涨就说明观察、运行期事件、采集遥测三条写入通路都通了。

## 6. 如何验证「屏幕录制月度再授权」行为

macOS 15.0 起屏幕录制授权带有效期，系统会周期性重新提示；报告 3.3 说 26 上仍在。要拿到的
不是「多久提示一次」，而是**提示到期时截图会不会失败、我们能不能自动恢复**。

**主动撤销再恢复（最快）**：系统设置 → 隐私与安全性 → 录屏与系统录音 → 关掉 brosis 的开关。
预期：下一次触发的截图失败，库里出现 `runtime_event:capture_failed`（`permission_lost=true`）、
一行 `capture_stats.status='failed'` 和 `runtime_event:capture_disarmed`；
菜单栏图标变成警告三角、状态显示「权限缺失（屏幕录制）」，并自动弹出权限引导窗口。
再把开关打开（可能要求重开 app），应看到 `capture_armed` 重新写入。

`detail` 里带 `domain/code`，`SCStreamErrorUserDeclined = -3801`。
系统侧的 TCC 记录可以用 `log show --last 2h --predicate 'subsystem == "com.apple.TCC"' --info`
辅助判断（读 `TCC.db` 需要给终端「完全磁盘访问」，本项目不建议为它开 FDA）。

## 7. SMAppService 注册为登录项

代码路径：`AppDelegate.toggleLoginItem()` → `LoginItem` → `SMAppService.agent(plistName: "com.brosis.agent.plist")`。
plist 必须位于 `Contents/Library/LaunchAgents/`（build_app.sh 已经放好），且 app 必须已签名。

菜单栏 → **注册为登录项**；首次注册后状态可能是 `requiresApproval`，菜单会显示
「登录项待批准，打开设置…」，点它跳到系统设置 → 通用 → 登录项与扩展。
验证：`launchctl print gui/$(id -u)/com.brosis.agent | head -20`。

LaunchAgent 关键键（报告 3.3 的结论）：`LimitLoadToSessionType=Aqua`、`ProcessType=Background`、
`LowPriorityBackgroundIO=true`、`RunAtLoad=true`、`AssociatedBundleIdentifiers=[com.brosis.app]`。
`KeepAlive` 用 `{SuccessfulExit: false}` 而不是 `true`——否则从菜单栏点「退出」会被 launchd 立刻拉起来。

## 8. 运行时行为

### 8.1 锁定状态机（3.5）

四个相位 + 一个 `paused` 子状态，判定逻辑在 `LockPolicy.next(_:on:strictScreenLock:)`，
是**纯函数**，自检用 21 条转移用例 + 7 条补做用例全量跑（`--dump-vectors` 第 4、5 节逐条可看）。

```
locked ──launch / menuUnlock / systemDidWake──▶ unlocking ──取钥+开库+校验成功──▶ unlocked
   ▲                                               │                              │
   └────── lockCompleted ◀── locking ◀─────────────┴──────────────────────────────┘
                              ▲ systemWillSleep / userWillLogout / menuLock / lowDisk / thermalCritical
```

| 触发 | 来源 | 结果 |
|---|---|---|
| 启动 | `AppDelegate.applicationDidFinishLaunching` | `unlocking` |
| 系统睡眠 | `NSWorkspace.willSleepNotification` | `locking` |
| 注销 / 关机 | `NSWorkspace.willPowerOffNotification` | `locking` |
| 菜单「锁定数据库」 | 菜单项（⌘L） | `locking` |
| 磁盘剩余 < **2 GiB** | 60 s 轮询 `volumeAvailableCapacityForImportantUsage` | `locking` |
| 热状态 `critical` | `ProcessInfo.thermalStateDidChangeNotification` | `locking` |
| 屏幕锁定 | `com.apple.screenIsLocked` | **`paused`，库保持打开**；`lock.strict=true` 时改为 `locking` |
| 屏幕解锁 | `com.apple.screenIsUnlocked` | 去掉暂停原因；严格模式下从 `locked` 回 `unlocking` |
| 屏保启动 / 停止 | `com.apple.screensaver.didstart` / `.didstop` | 进 / 出 `paused` |
| 菜单「暂停采集」 | 菜单项（⌘P） | 进 / 出 `paused` |

三条实现口径：

1. **暂停原因是集合不是布尔**（`PauseReason`：`user` / `screenLocked` / `screensaver` / `secureInput`）。
   用户按了暂停、屏幕又锁了，解锁只该去掉 `screenLocked` 那一路，采集仍然停着。
2. **`unlocking` 期间来的锁定触发会生效**（开库中途睡眠是真实场景），开库回调发现相位已经不是
   `unlocking` 就把刚开的库直接 checkpoint + 关掉，不挂上去。`locking` 期间再来锁定触发则是空操作。
3. **`locking` 期间到达的"要开库"触发会补做**（`LockPolicy.deferredUnlock`，7 条纯函数用例）。
   关库是异步的（checkpoint + close 在后台执行器上），如果唤醒赶在 `lockCompleted` 回调之前到，
   `LockPolicy.next` 会把它当空操作丢掉，状态就停在 `locked` 直到用户手动 ⌘L。
   现在这类触发（`systemDidWake` / `menuUnlock` / 严格模式下的 `screenUnlocked`）先记下来，
   关库落地后补做一次，并写一条 `runtime_event:lock_unlock_deferred`。
   反过来，关库过程中再来**锁定类**触发（⌘L / 睡眠 / 注销 / 低磁盘 / 热 critical）会**取消**补做——
   用户刚按了锁定，不该因为半分钟前的一次唤醒又把库开回来。
   **锁屏只在 `lock.strict=true` 时算锁定类触发**（M1 R2 修正）：非严格模式下锁屏只往
   `pauseReasons` 里加一条、库照开着，它不关库，就不该把「睡醒了要开库」这件事吃掉——
   否则"睡眠 → 唤醒 → 屏幕还锁着"这条最常见的路径会停在 `locked`，正是补做要解决的那个问题。
   判定是纯函数 `LockPolicy.cancelsDeferredUnlock(_:strictScreenLock:)`，自检 11 条用例
   （`--dump-vectors` 第 6 节逐条可看）。

**开库（unlocking）三步**：`KeychainKeyProvider` 取钥 → `Store.open`（连接序言由 core 负责，
顺序 key → cipher_page_size → auto_vacuum → WAL → …）→ 校验（`buildInfo()` + 真读一次 `observations`）。
**关库（locking）三步**：`wal_checkpoint(TRUNCATE)` → `close()`（core 内部清零密钥）→ 清缓存。
关库那一刻库已经不在，`key_zeroized=…` 写不进事件表，所以攒到**下一次** `store_opened` 的
`prev_close=[…]` 字段里，不让它凭空消失。

**菜单栏可见状态**（2.2 硬约束 2）：**录制 / 暂停（原因）/ 锁定（解锁中 / 锁定中）/ 权限缺失**。

### 8.2 3.12 三档采集策略（数据层）

权威存储是库里的 `app_policies`（本机配置，不随 iCloud 同步）。解析优先级：

**今日临时暂停 > 库里已有的策略 > 内置默认不采集清单 > 全局默认（事件 + 内容）**

生效方式在**采集时**，不是入库后过滤：

| 模式 | 记事件 | 读正文 | 进 `SCContentFilter` 排除 | 采集端具体做什么 |
|---|---|---|---|---|
| `none` 不采集 | ✘ | ✘ | ✔ | 不附着 AXObserver、不写观察、进排除列表 |
| `events_only` 只记事件 | ✔ | ✘ | ✘ | 写观察但 `completeness = excluded`、不做截图内容检查 |
| `events_and_content` 事件 + 内容 | ✔ | ✔ | ✘ | 全开 |

- **内置默认不采集清单**：`Resources/exclusions.txt` **∪** `CapturePolicy.swift` 的
  `BuiltinDenylist.categories`（25 个 bundle id，五类：密码管理器 11 / 钥匙串访问 1 / 验证器 5 /
  银行券商 6 / 远程屏幕 2）。**与 M0 的差别**：M0 是"文件存在就整个覆盖代码默认集合"，
  M1 改成并集——覆盖语义在这里是错的，用户往文件里加一个应用不该把密码管理器整类默默放开。
  要放开某一项就在应用清单里改档，用户显式设置的优先级本来就高于内置清单。
  银行 / 券商类的 bundle id **没有在本机逐一核对**（本机没装），它们是"给个起点"。
- **新应用首次出现**：按全局默认 `events_and_content` 处理，写进 `app_policies`
  （`source = default`）并记一条 `runtime_event:app_policy_new_app`。
  **落库是"只插不改"**：先读一次 `app_policies`，确实没有这一行才插入，绝不 UPDATE 已有行；
  唯一会覆盖已有行的路径是用户显式改档（`setMode`）。
- **库没开（`locked` / `locking` / `unlocking`）时的判定是临时的**：`Resolution.provisional = true`，
  **不缓存、不落库、不记事件**，菜单里那一行也会标注"（库未打开，临时判定）"。
  这条是硬的——库关着读不到 `app_policies`，把"读不到"当成"没有"补写回去，
  就会把用户设的「不采集」在一次锁定 / 解锁之后改回「事件 + 内容」（R1 复核抓到的问题）。
  读库失败同样只给临时判定。反过来，**用户在锁定期间点的「永久（不采集）」不会丢**：
  它进 `pendingUserChoices`，下一次开库补写。
- **菜单快捷项**「暂停采集当前应用」两档：
  - **今天**：临时切到不采集，到本地时间当日 24:00 自动失效。存在 UserDefaults 的
    `policy.pausedToday`（`[bundle id: 到期 Unix 秒]`）而不是库里——它不是"策略"而是"临时开关"，
    而且必须在库还没开（`locked`）时也能读到。
  - **永久**：真正改档到 `none` 并写库（`source = user`）。
  - 另有「恢复采集」改回 `events_and_content`。
- **全局默认档可改**（M1 R2 / T9）：应用清单窗口顶部那一格，存 UserDefaults 的
  `policy.globalDefault`（出厂值 `events_and_content`）。**改它不动任何已有的
  `app_policies` 行**——那些行是"已经定过的应用"，其中还包括用户显式设过的档；
  全局默认只对"以后才第一次出现的应用"生效。和 `policy.pausedToday` 一样放 UserDefaults
  而不是库里，因为库没开（`locked`）的时候冒出来的新应用也要按它做临时判定。

#### 应用采集清单窗口（3.12 的界面，M1 R2 / T9）

菜单栏 →「应用采集清单…」。判定逻辑全在 `Policies/PolicyList.swift`（纯函数，自检整段跑），
`Policies/PoliciesWindow.swift` 只负责把行画出来、把点击转成一次调用。

**数据源是三处的并集**（3.12：「来源是 NSWorkspace 的运行记录和本系统自己的观察记录」）：

| 来源 | core 里的查询 | 给出什么 | 为什么少不了 |
|---|---|---|---|
| `app_policies` 全表 | `Store.appPolicies()` | 已经定过档的应用 | 「不采集」的应用永远没有观察，只能从这里看到 |
| 最近 7 天的观察聚合 | `Store.appObservationStats(since:)` | 观察数、完整性四态分布、最近出现 | 3.12 要求每行显示这些 |
| 当前运行的 GUI 应用 | `NSWorkspace.runningApplications` | 刚装上、采集端还没碰到的应用 | 用户想"先设好再用"时得能找到它 |

统计口径三条，写死在 core 里（`Store+AppInventory.swift`）：**只算未删除的观察**
（`deleted_at IS NULL`）、**只算本机**（`device_id`，D17 同步下来的另一台机器不参与本机策略判断）、
**窗口下界由调用方给**（7 天这个数字在 app 侧的 `PolicyList.statsWindowDays`）。
这条聚合走 `idx_obs_live(device_id, ts) WHERE deleted_at IS NULL` 部分索引，
不是全表扫——`--self-check` 里有一项直接把 `EXPLAIN QUERY PLAN` 打出来。

**窗口里的列**：

| 列 | 内容 |
|---|---|
| 应用 | 显示名。优先级：`apps.name`（库里记过的）> `NSWorkspace` 的 localizedName > bundle id |
| bundle id | 等宽字体，就是 `app_policies.bundle_id` |
| 分组 | 有适配器（带规则 id，如 `safari` / `wechat`）/ 通用采集 / 默认不采集 |
| 采集模式 | 三档弹出菜单。显示的是**存下来**的那一档；库锁着时整列是灰的 |
| 最近 7 天观察 | 未删除的本机观察条数 |
| 完整性分布 | `完整 n · 部分 n · 不可用 n · 排除 n`，四项之和 == 观察数；0 条时显示 `—` |
| 最近出现 | 相对时间（`3 小时前`）；窗口内没有观察时显示 `—` 或 `运行中，无观察` |
| 状态 | `运行中` / `今日暂停至 HH:mm` / `你设的` / `内置清单` |

**分组顺序是「内置清单 > 有适配器 > 通用」**，并且分的是**出厂分类**不是当前档位：
用户把某个密码管理器显式改成「事件 + 内容」之后，它仍然留在「默认不采集」组里，
只是状态列标「你设的」。这样"这台机器上哪些应用是默认被挡掉的"始终一眼看得全。
一个应用既在内置清单里、又碰巧有适配规则时按内置清单归组——用户最需要看到的是
"它默认不被采集"，而不是"它有适配器"。

**排序**：先分组，组内按最近 7 天观察数倒序 → 最近出现倒序 → bundle id（保证全序，
同名同数的两行不会随机换位置）。**搜索框**按应用名或 bundle id 做不区分大小写子串匹配。

**改档流程是一个状态机**（`PolicyModeChange.plan`，8 条用例在 `--dump-vectors` 第 13 节）：

| 情况 | 结果 |
|---|---|
| 库没开（`locked` / `locking` / `unlocking`） | **挡下**，弹框说明原因并提示「今日暂停」不需要开库 |
| 档位没变 | 什么都不做 |
| 升档或平级 | 直接写库（`setMode`，`source = user`），不问删数据 |
| **降档**且这个应用全库还有未删除的观察 | 先写档，再问「是否删除该应用已有数据」 |
| 降档但这个应用一条数据都没有 | 直接写档，**不弹框**（问"是否删除 0 条"是纯噪音） |

档位高低：不采集 0 < 只记事件 1 < 事件 + 内容 2。
"要不要弹框"看的是**全库**计数 `Store.appObservationCount(bundleID:)`（走 `idx_obs_app_ts`），
不是列表里那个 7 天数字——7 天没动过不等于库里没有这个应用的东西。

**删除询问的默认是"不删"**：默认按钮（回车）是「保留数据」，第二个按钮才是
「删除这 N 条」。选删走 `Store.deleteByApp(bundleID:reason: .policy)`，也就是 3.8 的
按应用删除并级联（观察打墓碑 → occurrences → 无引用的 text_version → FTS 行 →
会话与日台账标 stale → 缩略图 → `deletions` 审计行），删完把
「观察 / 文本版本 / 索引行 / 释放字节 / 待重建的会话与台账」摊在窗口底部那一行。
两个分支都写运行期事件：`app_policy_downgrade_kept_data` / `app_policy_downgrade_deleted`。

**改完档立刻生效**：窗口回调把新档位推给 `CaptureController.setFrontmostApp`
（当它就是当前前台应用时），不等下一次前台切换——3.12 的「生效方式在采集时」。

**新应用一次性提示**（3.12：「首次出现时按全局默认处理，菜单栏提示一次，可一键改档」）：
`CapturePolicyStore.resolve` 真的往 `app_policies` 插了一行时，除了原有的
`runtime_event:app_policy_new_app`，还把这个 bundle id 放进提示队列。菜单栏最多挂**一行**
「新应用 X 已按默认档「…」记录（点此改档）」，点它就划掉提示并打开清单窗口、
**定位并选中那一行**。提示过的 bundle id 记在 UserDefaults 的 `policy.newAppNoticed`
里，重启 app 也不会再提示同一个。

**窗口自己不开库**：所有读写都经 `Recorder.withStore`，与采集端同一个 `Store` 实例。
库锁着时窗口照样能开，只是横幅说明"读不到 `app_policies`，下面只有当前运行的应用，
并且不能改档"。

### 8.3 入库前规则脱敏（2.2 硬约束 2 / 4.2）

`Redactor.redact(_:)` 是纯函数，`EventSkeleton` 在构造 `ObservationInput` **之前**调用它，
所以库里从一开始就没有这些明文。**过脱敏的不只是正文**：AX 正文片段、**窗口标题**、
**URL**、`kAXDocument` 的文件路径四样都过（邮件与浏览器标签的标题里常见
「Your verification code is 482913」，URL 查询串里常见 `?access_token=…`，
它们对「只记事件」档的应用同样会入库）。URL 的 `kind` 与 `host` 仍用**原始**串判定
（占位符里的 `[` `]` 会让 URL 解析失败），真正写进 `urls` 的定位串是脱敏后的。
**8 条规则**，按优先级：

| # | 类型 | 命中什么 |
|---|---|---|
| 1 | `private_key` | `-----BEGIN … PRIVATE KEY-----` 整块（优先级最高，块内部还会命中别的规则） |
| 2 | `aws_access_key` | `AKIA` / `ASIA` / `AROA` 等八种前缀 + 16 位大写字母数字 |
| 3 | `github_token` | `ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` + ≥36 位 |
| 4 | `slack_token` | `xoxb` / `xoxa` / `xoxp` / `xoxr` / `xoxs` |
| 5 | `generic_secret` | `api_key` / `secret` / `token` / `password` 等 **+ 显式 `=` 或 `:` +** ≥8 位 URL-safe 值 |
| 6 | `card_number` | 13–19 位、允许单个空格或短横分隔，**必须过 Luhn** |
| 7–8 | `verification_code` | 「验证码 / 校验码 / 动态密码 / verification code / OTP …」前后 4–8 位数字（两个方向各一条） |

命中替换成 `[REDACTED:<类型>]`（固定长度占位符，**不保留前后几位**——保留几位就等于泄漏几位），
重叠时靠前的规则赢，替换从后往前做。命中数按类型累计，每 20 条写一条
`runtime_event:redaction`（detail 只有类型与条数，**没有被删掉的内容**）。

**Luhn 是关键**：不过 Luhn 就不替换，否则 13 位毫秒时间戳、16 位订单号会被大面积误伤——
反例向量里专门放了这三种（时间戳 / 订单号 / 手机号）。

测试向量在 `RedactionVectors`：**正例 21 条（最后三条是窗口标题 / URL）、反例 12 条**，自检逐字符比对，
`--dump-vectors` 可以逐条看输入 → 输出。**查询时那一道**（计划 4.2 说"入库前一道、查询时一道"）
属于 T3 的检索层，本轮不做；`Redactor` 是纯函数，直接复用即可。

### 8.4 暂停触发器

| 触发器 | 状态 | 做法 |
|---|---|---|
| 安全输入 | M0 就有 | `IsSecureEventInputEnabled()`，截图与正文一律跳过 |
| 锁屏 | M0 就有 | 两路信号（前台应用 = `loginwindow` + 分布式通知），去重后进 `paused` |
| **屏保** | **M1 新增** | `com.apple.screensaver.didstart` / `.didstop` 分布式通知 → 进 / 出 `paused` |
| **私密浏览** | **M1 新增（尽力）** | 见下 |
| **全局热键** | **M2 d 新增** | `RegisterEventHotKey`：⌃⌥⌘P 暂停 / 继续、⌃⌥⌘L 锁定。详见第 17 节 |
| 视频会议前台 | 不做 | 计划 4.2 已定：改为可选开关，默认关闭 |

**私密浏览是"尽力"，不是保证。** 做法：浏览器窗口标题里出现无痕标记
（`无痕浏览` / `私密浏览` / `隐私浏览` / `Private Browsing` / `InPrivate` / `Incognito`）时，
这次观察的 `completeness` 记 `excluded`，**正文、窗口标题、URL、文件路径一个都不存**——
页面标题与地址正是私密浏览要保护的东西，只留 `app + ts + completeness=excluded`；
事件照记（不然台账凭空少一段时间），但看不出"在看什么"。
三条局限**如实写在代码注释与这里**：

1. **靠标题就一定漏**：Safari 的无痕标记是**系统语言相关**的，本表只列了中英两种；
2. **网页可以改写标题**：`document.title` 由页面控制，标题栏显示页面标题时 `AXTitle` 里可能根本没有标记；
3. **Chromium 系基本无效**：Chrome 无痕窗口的标题就是页面标题，"（无痕模式）"只在窗口边角的徽章上，
   AX 读不到。真要挡住只能靠 3.12 把整个浏览器改档，或者等 M3 的域名清单。

判定只对浏览器 bundle id 生效——别的应用标题里出现"私密浏览"四个字大概率是在讨论它。

### 8.5 事件骨架与 AX（沿用 M0，只改写入口径）

`NSWorkspace` 的 `didActivateApplication` / `didDeactivateApplication` / `willSleep` / `didWake` /
`sessionDidResignActive` / `sessionDidBecomeActive`；每次前台应用切换重建一个 `AXObserver`，订阅
`AXFocusedWindowChanged`、`AXFocusedUIElementChanged`、`AXTitleChanged`、`AXMainWindowChanged`。

**系统级事件只写运行期事件，不写 `observations`**（M1 改动）：schema 的 `trigger` 枚举里没有
"睡眠 / 锁屏"这类取值（`app_switch` / `window_change` / `url_change` / `ax_notification` /
`frame_dirty` / `timer` / `manual`），硬塞成 `manual` 会让台账把它们当成一次用户主动记录。
采集端细分的 `ObservationTrigger` 通过 `coreTrigger` 收敛：应用激活 / 失活 → `app_switch`，
焦点窗口 / 标题变化 → `window_change`，焦点元素变化 → `ax_notification`。
细分值本身保留在 `capture_stats."trigger"` 与运行期事件里，不丢信息。

**锁屏怎么判**：`sessionDidResignActive` / `sessionDidBecomeActive` **不是锁屏通知**——它们只在
**快速用户切换**时触发，所以记的是 `user_switched_away` / `user_switched_back`。锁屏用两路信号：

| 优先级 | 信号 | 说明 |
|---|---|---|
| 1 | **前台应用 = `com.apple.loginwindow`** | 直接观测，不依赖通知投递；进程在锁屏之后才启动也成立。登录窗口不做 AX 附着 |
| 2 | 分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | 私有通知、不保证投递，只作补充 |

**Chromium / Electron 系判定：两路。** 命中任意一路就在读树前设 `AXManualAccessibility`
（公开属性，不用私有的 `AXEnhancedUserInterface`）：显式清单 `chromiumFamilyBundleIDs`（`detection=list`）、
`Contents/Frameworks/` 下有 `Electron Framework.framework` 或 `Chromium Embedded Framework.framework`
（`detection=framework`）。判定结果按 bundle id 缓存，每个 bundle id **第一次**判定时写一条
`runtime_event:ax_manual_accessibility`。第二路不是万能的：改过框架名的应用匹配不到
（飞书把它重命名成 `Lark Framework.framework`），只能靠第一路的清单兜底。

**AX 超时 0.5 s 是进程级的。** `AXUIElementSetMessagingTimeout` 只对传进去的那个元素生效，
只有传 `AXUIElementCreateSystemWide()` 才是本进程全局。所以
`AppDelegate.applicationDidFinishLaunching` 里在任何 AX 读取之前调用一次
`AX.installGlobalMessagingTimeout()`，返回的 `AXError` 记进 `runtime_event:ax_global_timeout_installed`。

**高频通知节流**：只对 `AXFocusedUIElementChanged` 做 **2 秒节流**，累计丢弃数每 100 次和 `stop()` 时
写一条 `runtime_event:ax_element_notifications_throttled`。应用切换、焦点窗口变化、标题变化不受影响。

**AX 正文（M1 起入库）**：焦点窗口下 BFS（默认 1500 节点 / 12 层，`com.apple.finder` 收到 400 / 6），
统计并**收集** `AXTextArea` / `AXTextField` / `AXStaticText` / `AXWebArea` 四个角色的正文；
遇到 `AXSecureTextField` 直接剪枝。同一角色的多个节点按遍历顺序用换行拼成**一个片段**——
AX 树里一段正文常被拆成几十个 `AXStaticText`，逐节点入库会把 `text_versions` 打成碎片、
也让 bigram 检索失去上下文。每个角色最多留 **20 000 字符**，命中上限记 `hit=chars`。

**`runtime_event:ax_bfs_limit_hit` 的三个 `hit` 各是什么意思**（`detail` 形如
`limits=nodes=1500 depth=12 visited=1500 chars=8123 hit=node`）：

| `hit` | 含义 | 判定 |
|---|---|---|
| `node` | 节点数吃满 `maxNodes`，队列里还有没走的元素 | `visited >= maxNodes && !queue.isEmpty` |
| `depth` | **确实有子树因为深度上限没被展开** | 至少一个 `depth == maxDepth` 的元素**还有子节点**（`AX.depthLimitHit`） |
| `chars` | 至少一个角色的正文吃满 20 000 字符 | 累计字符数越过上限 |

`depth` 这条是 **M1 R2 修正**的：原来只要取出一个 `depth == maxDepth` 的元素就置位，
而最后一层通常全是叶子（`AXStaticText` 之类），于是限深的应用（访达 6 层）几乎每次遍历都报
`hit=depth`，这个字段等于没有信息。现在要真的还有子节点才算，代价是**一次遍历最多多发一轮
`kAXChildren`**（已经命中过就不再判定，`hasChildren` 是 `@autoclosure`）。
口径改了之后 `hit=depth` 才是"该收紧限额了"的信号。
**M1 R2 / T8 起这段话只描述兜底规则**：正文读取的入口换成了适配规则引擎
（`AdapterEngine.scan`，见 8.6），没有专门规则的应用走的就是上面这套四角色 BFS，
唯一的差别是加了视口裁剪。`occurrences.region` 也从裸角色名换成带来源前缀的区域名
（`adapter:generic.window` / `ocr:wechat.chat_panel`）。
`completeness` **不再是占位值**：四个取值的判定见 8.6 的表。

**source_state 分离**（评审 F5，判定顺序）：`locked` > `permission_lost` > `secure_input` >
`user_idle`（≥30 s）> `ok`；AX 读不到焦点窗口时单独记 `timeout`。绝不混成一个「空」。

### 8.6 适配器与视口 OCR（3.3 / D24，M1 R2 / T8）

M0 的真实数据（`tools/bench/results/m0_closeout_2026-09-07.md` §2.2）决定了这一节存在的理由：

| 应用 | AX 正文 | 结论 |
|---|---:|---|
| Safari | 81.9% 的观察有正文、109,035 字符 | AX 够用，规则只负责收窄区域 + 裁视口 |
| Claude 桌面版（Electron，探针里停留第一） | **0 字符 / 74 条观察** | 先设 `AXManualAccessibility`，读不到就视口 OCR |
| 访达 | 80.0%，但 22% 的观察 0.5 s 超时 | 兜底规则 + 收紧限额（400 节点 / 6 层） |
| 飞书（Electron） | 12/17 条"有正文"，合计 **156 字符** | 消息列表按行读，读不到就对消息面板 OCR |
| 微信 | 0 字符、6 条里 2 条超时 | AX 一路都不走，聊天面板与会话名都视口 OCR |

#### 规则怎么写

一条规则 = `AdapterRule`（`Adapters/AdapterRule.swift`），全是**纯数据**，所以能单元测试：

| 字段 | 作用 |
|---|---|
| `bundleIDs` | 命中哪些应用；空数组 = 兜底规则 |
| `electron` | 读树前要不要设 `AXManualAccessibility`（沿用 `AXSupport` 的两路判定） |
| `regions` | 一到多个正文区域，每个区域声明**定位**、**读取方式**、**视口处理**、**字符上限** |
| `chatLayout` | 有值就对 OCR 结果做气泡归属 |
| `limits` / `maxFrameProbes` | BFS 节点 / 深度上限；以及**一次扫描最多问多少次元素坐标** |
| `notes` | 已知局限，`--dump-vectors` 第 8 节原样打出来 |

**定位**（`ElementLocator`）：`role` / `roleAndSubrole` / `identifier` / `rolePath`（从窗口逐层下钻）/
`relativeRect`（窗口内的 0–1 相对矩形，给 AX 读不到、只能按坐标 OCR 的应用）/ `wholeWindow`。

**读取方式**（`ReadMethod`）：

| 值 | 做什么 |
|---|---|
| `ax_value` | 直接读节点的 `AXValue` / `AXDescription`，配合 `AXVisibleCharacterRange` 裁视口 |
| `ax_subtree` | 子树限额 BFS，收集四个文本角色，按 frame 相交裁视口 |
| `ax_rows` | 消息列表：`AXList` 的每个 `AXRow` 拼成「发送者 时间 文本」，只取视口内已渲染的行 |
| `ocr` | 不读 AX，这块区域直接走视口 OCR（**规则声明 AX 不可用**） |

**可见范围处理**（计划 3.3「只入库视口内实际显示的内容；回滚区与视口外的 AX 节点不入库，
完整性字段标记为 partial」）分三层，按精度从高到低：

1. `AXVisibleCharacterRange` 可用时**优先用它**——它是文本控件自己报的"现在显示的是哪一段"，
   比按坐标猜准得多；真的裁掉了东西就置 `clippedByCharRange`。
2. 否则用**元素 frame 与窗口可见区域相交**判定。容器整块在视口外时**整棵子树一次剪掉**
   （聊天窗口的回滚区最大的一块开销就是这么省掉的）；`frame.maxY <= viewport.minY` 的另记为"回滚区"。
3. **读不到 frame 一律按可见处理**。宁可多存一点，也绝不因为读不到坐标就丢证据。

`maxFrameProbes`（默认 **300**）是主线程预算的闸：每问一次坐标要发两条 AX 消息
（position + size）。配合"只问带正文的节点与滚动 / 列表类容器"（`AdapterEngine.shouldProbeFrame`），
真实窗口远到不了这个数；真到了就**不再裁视口**并把完整性降成 `partial`，而不是让菜单栏 app 卡住。

**新鲜度判定**（两侧都有，R2 复核时补齐了 OCR 侧）：
- **AX 侧**：每次扫描把「区域名 → 文本」存进 `CaptureCoordinator`，下一次同一个应用同一个区域拿来比对。
  它决定第二类 OCR 触发条件里的"AX 值有没有变"。
- **OCR 侧**：认出来的正文与这个窗口区域上一次逐字节相同就**不写第二条观察**（计数进
  `ocrUnchanged`）。没有这一层的话，微信这类全 OCR 的规则在屏幕静止时每 12 s 就会写一条
  一模一样的 `ocr` 观察（约 300 条/小时）；AX 侧的观察照写，所以时间线不缺段。
  OCR 拦不到"认之前"——得认了才知道变没变，所以省下的是入库，不是识别。

**入库形状**：适配器读到的片段 `region` 写 `adapter:<规则 id>.<区域名>`，
OCR 读到的写 `ocr:<规则 id>.<区域名>`；`observations.capture_method` 相应记
`ax`（兜底规则）/ `adapter` / `ocr` / `mixed`（AX 与 OCR 都有）。
`observations.visible_range` 存一段 JSON——**只有形状没有正文**：窗口矩形、每个区域的
字符数 / 视口内节点数 / 视口外节点数 / 回滚区节点数 / 是否被字符范围裁过 / 区域矩形。

#### 四个应用的规则与局限

| 规则 | 区域 | 读取 | 已知局限 |
|---|---|---|---|
| `safari` | `web_area`（AXWebArea 子树） | AX | AXWebArea 找不到时（PDF 预览、部分扩展页）退回整窗口 BFS；跨 iframe 的顺序按 AX 树顺序，不是视觉顺序 |
| `claude_desktop` | `conversation`（AXWebArea 子树，**允许回退 OCR**） | AX → OCR | 必须先设 `AXManualAccessibility`（M0 没设时正文为 0）；代码块是等宽小字，OCR 回退时按 D24 不降采样；折叠起来的长回复只记展开的部分 |
| `feishu` | `message_list`（AXList/AXRow，**允许回退 OCR**）、`conversation_title`（顶部 8% 相对矩形，OCR，非必需） | AX 行 → OCR | 只记视口内已渲染的消息，**不追溯未打开的会话与未滚动到的历史**；图片 / 文件 / 语音 / 通话只有屏幕上显示的文字才可能被 OCR；发送者与时间取自行内子元素，行结构变了就退化成整行文本 |
| `wechat` | `chat_panel`（左 22% 之后、上 8%–78% 的相对矩形，OCR）、`conversation_title`（顶部 8%，OCR，非必需） | 全 OCR | 相对矩形是按三栏布局估的，**用户改了窗口比例或开了浮层会偏**；主窗口标题恒为「微信」，会话名只能从顶部区域 OCR；语音只记 `[语音]`；支付 / 转账 / 红包与聊天一起记录，不特殊处理（D14 已定） |
| `generic` | `window`（整窗口子树） | AX | 就是 M0 那套四角色 BFS，唯一差别是加了视口裁剪；不触发 OCR |

**气泡归属**（`BubbleAttribution`）：单聊按气泡中心的 x 分左右（阈值 0.55，右 = 自己）；
群聊时"够短 + 紧贴下一行 + 与下一行同侧"的那一行判为**昵称**，本身不入库成正文，
而是当作后面那条气泡的发送者；形如 `3"` / `12''` / `5 秒` 的气泡记 `[语音]`。
判定的输入是 OCR 的行与归一化矩形，所以可以直接对**合成布局 JSON** 跑（自检里就是这么验的）。

#### OCR 触发条件：只有三类

计划 3.3 写死了，`OCRTriggerGate.reason(...)` 是它的纯函数版本：

| # | 条件 | 触发原因 |
|---|---|---|
| ① | 规则声明 AX 不可用的区域（`read = ocr`），或规则允许回退且 AX 读到空 | `rule_declared` |
| ② | 帧变化超阈值（帧门控判为**没被门控**）**但该区域的 AX 值没变** | `frame_changed_ax_stable` |
| ③ | 覆盖检查失败的区域（上一次采样审计的覆盖率低于阈值） | `coverage_failed` |

**反例同样重要**：AX 值变了就**不 OCR**——AX 通道还在工作，再认一遍是白花钱
（3.3「文本是否变化以 AX 通知与值比较为准」）。帧没变也不 OCR。

**第二类的已知局限（M1 记录在案，等真机数据再改）**：请求是在"变化帧之后"的那次 AX 扫描里排出来的，
所以它只有在**再下一帧也没被门控**时才会真的跑。「屏幕变了一次然后静止」（新消息到达）这种最典型的
场景里，静止帧显示的恰恰就是变化后的内容，却会被跳过，而上下文被下一次扫描替换后请求就丢了。
产品路径上第二类因此几乎不执行；要量化影响得有真机数据（第 11 节的清单里）。

**频率限制**：同一「bundle id + 区域名」两次 OCR 最少间隔 **5 s**
（`capture.ocrMinInterval`，下限 1 s），被限的次数计进统计，不推进时钟。

**分辨率按 D24**：正文类区域允许 1x（只有当图像超过区域点宽 2 倍时才降到 1x——D24 实测降采样不省时间，
所以默认不主动降）；`kind = code` 的区域**不降采样**。语言 `zh-Hans` + `en-US`，
`usesLanguageCorrection = false`，级别 `accurate`。**采集端不做 NFKC 折叠**（折叠只在索引侧）。

**低置信标记（D24）**：短哈希、十六进制串、内存地址（`0x…`）在识别文本里被数出来，
条数写进 `occurrences.note`（形如 `lowconf=2 conf=0.84 px=864x560 rect=…`），
片段的 `confidence` 写 Vision 按字符数加权的平均置信度。文本照样入库（它确实在屏幕上），
但检索与叙述侧不该把这类串当成可引用的证据。

#### 挂在哪儿：`CaptureCoordinator`

AX 在主线程读、图像在 utility 队列才有，两边时机对不上，所以中间有个协调者
（`OCR/CaptureCoordinator.swift`），一把 `NSLock` 串行：

```
EventSkeleton（主线程）                     CaptureController（utility 队列）
  AX.focusedWindowInfo 一次拿窗口元素+定位          SCScreenshotManager 截一张图
  AdapterEngine.scan(rule:window:…)               analyze() 算 dHash + 32×32 网格差
  → 片段 / 完整性 / visible_range / 待办 OCR        → noteFrameGate(gated:)
  → noteScan(Context)  ──────────────────────────→ handleFrame(image:…)
                                                     ├ 跑待办 OCR → 写一条 ocr / mixed 观察
                                                     └ 轮到审计 → 全窗口 OCR → capture_audit
```

绝大多数帧 `handleFrame` 直接返回 0：没有待办请求、也没轮到审计时它什么都不做。
实际跑了几个区域会写进 `capture_stats.ocr_regions`。

**上下文必须与当前前台应用对得上**（R2 复核发现的缺陷，两道防线）：上下文只在 AX 扫描时更新，
而**私密浏览 / AX 超时或读不到焦点窗口 / 「只记事件」档这三支根本不扫描**，
截图那条通路并不知道，照样会出图并调 `handleFrame`。所以：

1. `EventSkeleton` 在这三支里调 `coordinator.clearContext()`——事前不留；
2. `handleFrame` 还要把 `CaptureController` 自己记的 `frontmostBundleID` 与上下文里的
   bundle id 核一次，对不上就整帧不处理并把这份上下文丢掉（计数进 `ocrStaleContext`）。

不这么做的后果是实打实的：微信（或飞书、AX 为空的 Claude）之后切到 Safari 无痕窗口，
下一帧就会把无痕页面上落在微信 `chat_panel` 矩形里的正文**以微信的身份、
`capture_method = ocr` 入库**——既破了"私密浏览正文一个都不存"，也归错了应用。
自检里有这条的复现与阳性对照（第 4 节「端到端」那一组）。

#### 完整性四态（3.2 的 `completeness`，M1 R2 起是真判定）

M0 时期只有 `partial` / `unavailable` 两个占位值，**一条 `complete` 都没有**。现在：

| 状态 | 谁判的 | 条件 |
|---|---|---|
| `complete` | `AdapterEngine` | 规则声明的**必需**区域全部读到，且没有视口外内容、没命中任何限额、没被字符范围裁过、没有待办 OCR |
| `partial` | `AdapterEngine` | 读到了一些，但上面任意一条成立 |
| `unavailable` | `AdapterEngine` | 一个字都没读到（含读不到焦点窗口） |
| `excluded` | `EventSkeleton` | 3.12 的「不采集」/「只记事件」档，或私密浏览命中——**读都不读**，所以轮不到适配器判 |

OCR 那条观察单独判：所有请求的区域都认出东西、且平均置信度 ≥ 0.5 才算 `complete`，否则 `partial`。

#### 采样审计（3.3，M1 低频版）

AX 非空的观察每 **50** 次（`capture.auditEvery`，0 = 关）取一次全窗口 OCR 对照，
覆盖率写进 core 的 `capture_audit` 表（schema v3）与一条 `runtime_event:capture_audit`。
覆盖率口径是「**AX 文本的 token 有多少比例能在 OCR 文本里找到**」——去空白与标点、NFKC 折叠、
汉字按 bigram 切、AX 侧 token 去重、判定用子串（详见 `core/README.md` 的「采样审计」一节）。
低于阈值 **0.6**（`capture.coverageThreshold`）就把该应用标成"覆盖检查失败"，
下一轮触发第三类 OCR。审计行**不存正文**，也不是证据：不参与同步、不进删除级联。

#### 可调参数一览

| UserDefaults 键 | 默认 | 作用 |
|---|---|---|
| `capture.ocrMinInterval` | 5 s（下限 1 s） | 同一窗口区域两次 OCR 的最小间隔 |
| `capture.auditEvery` | 50 | 每多少条 AX 非空观察做一次采样审计；0 = 关 |
| `capture.coverageThreshold` | 0.6 | 覆盖率低于它就标"覆盖检查失败" |

#### 还没接上的两处（交给主会话）

1. **菜单入口**：本轮按并行约束**没有改 `AppDelegate.swift`**。`CaptureCoordinator.shared.currentStats`
   已经能给出「OCR 次数 / 限流次数 / 平均耗时 / 采样审计次数与平均覆盖率」，
   要放进菜单栏或状态面板只需在 `AppDelegate` 里读它；`CaptureController` 的
   `capture_disarmed` 事件里已经带上了这段统计。
2. **真机验证**：相对矩形（微信 / 飞书）与 `AXList` 行结构都是按公开资料与 M0 数据估的，
   必须在真机上按第 11 节的清单核一遍再定稿。

### 8.7 按需截图

`SCScreenshotManager.captureImage` 一次性截图（macOS 14.4 起常驻 SCStream 会让菜单栏常亮紫色
「正在共享」图标）。触发：事件骨架每写一条应用级观察记录、焦点换屏、系统唤醒 / 解锁 / 屏保结束，
以及**默认每 12 s** 的定时兜底（只在 `source_state == ok` 时）；0.35 s 合并、两次截图最少间隔 1 s。

**跳过规则五条**：锁屏、安全输入、用户空闲（只跳兜底）、刚因为事件截过图（`skippedRecent`）、
**前台应用不是「事件 + 内容」档**（`skippedPolicy`，M1 新增，会写一行
`capture_stats.status='skipped'`）。排除列表是**所有解析结果为 `none` 的运行中应用**
（内置清单 + 用户改档 + 今日临时暂停都在 `resolve` 里合过），顺带把没见过的 bundle id
**插入**（不覆盖）`app_policies`——第二轮的应用清单窗口要用它。
副作用要知道：这一步会把大量 helper / 后台进程的 bundle id 也登记进去（`source = default`），
第二轮的清单窗口要按 `NSWorkspace` 的运行记录过滤，别把它们都摆给用户看。

每张图算 dHash + 32×32 网格亮度差后立即丢弃：`capture_stats.dirty_area_ratio` = 亮度差 > 24/255
的格子占比，`dirty_rects` = 变化格子数。门控阈值不变：汉明 ≤ 6 且面积 < 2% → `gated=1`，
只表示「不触发内容检查」，不是丢证据（评审 F5）。

定时兜底间隔可用 UserDefaults 覆盖：`defaults write com.brosis.app capture.periodicInterval -float 5`，
下限 3 s，非法值回落 12 s，来源标记（`default` / `defaults` / `defaults_clamped` / `defaults_invalid`）
写在 `capture_armed` 的 detail 里。
**改完要退出 brosis 再打开才生效**：这个值在进程里只解析一次（`CaptureController` 的
静态 `periodicIntervalResolution`，为的是让每条 `capture_stats` 的口径在一次运行里恒定），
`defaults write` 之后不重启 app 的话，菜单里看到的、事件里记的都还是旧值。
`--self-check` 的最后几行会打印当前解析结果与来源，可以用它确认改动生效了。

**"刚截过图就跳过这次兜底"用的是哪一次截图**（M1 R2 修正）：只算**事件触发**的那次。
合并后的触发串去掉 `periodic` 与 `queued` 之后还剩东西才算事件
（`CaptureController.isEventTrigger`，纯函数，自检 7 条用例）。
原来 `finish()` 重排队时会追加 `queued`，被延后的**纯定时**截图于是变成 `"periodic+queued"`
并被当成事件截图记进 `lastEventCaptureAt`，把紧接着的下一次兜底压掉——纯定时截图反而抑制了
纯定时截图。现在重排队不再追加原因，**`capture_stats.trigger` 里不会再出现 `queued`**
（老库里的历史值仍按非事件处理）。

### 8.8 退出

`applicationWillTerminate`：停事件骨架 → 停截图（`Task.detached` + 信号量，**不能用 `Task { }`**：
在 `@MainActor` 上下文里创建的 Task 继承 MainActor 隔离，而主线程正被 `DispatchSemaphore.wait`
挡着，任务根本没机会开始）→ `LockController.shutdown()` 同步做 checkpoint + 关库 + 清零密钥。

### 8.9 导出存储统计（菜单项「导出存储统计…」）

产品库是 SQLCipher 加密的、钥匙在钥匙串里：`sqlite3` 打不开，`core` 的 `brosis-store` 也只支持
`--key-file`（第 5 节第 6 条）。所以"这个库现在有多大、正文 / 索引 / 元数据各占多少、多少行"
在库外**没有任何出口**。菜单项「导出存储统计…」（`StatsExport.swift`）补上这个出口，
也是 M1 R2 月报脚本（T6）的输入。

- **什么时候可点**：只有 `unlocked` 时可用，否则是灰的。
- **做什么**：先 `checkpoint()`（`dbstat` 只看已经落进主库文件的页），再调 core 的
  `stats()` + `statsDetail()`，把结果写成数据目录下的 **`stats-<yyyy-MM-dd>.json`**
  （本地日期；同一天再导出会覆盖当天那份），文件权限 0600，随后写一条
  `runtime_event:stats_exported` 并在 Finder 里选中它。
- **格式**（`schema_version = 1`，字段表见 `core/README.md` 已知限制第 9 条）：

  | 顶层键 | 类型 | 说明 |
  |---|---|---|
  | `schema_version` | int | 格式版本，字段有增删就 +1 |
  | `generated_by` | string | 采集端版本（= `BuildInfo.version`） |
  | `device_id` | string | D17 的 `device_id` |
  | `exported_at` | string | ISO 8601（UTC，`…Z`） |
  | `exported_at_ms` | int | 同一时刻的 Unix **毫秒**，与 `observations.ts` 同口径 |
  | `store` | object | `StoreStats` 全字段（snake_case）：`page_size` `page_count` `freelist_pages` `db_file_bytes` **`wal_bytes`** `shm_bytes` `content_bytes` `index_bytes` `fts_bytes` `metadata_bytes` `free_bytes` `text_payload_bytes` `observations` `live_observations` `tombstoned_observations` **`text_versions`** `occurrences` `fts_rows` `apps` `deletions` |
  | `dbstat` | array | 逐 b-tree 明细，按字节倒序，每项 `{name, bucket, bytes, pages}`；`bucket ∈ content / index / fts / metadata` |

- **文件里没有正文、没有窗口标题、没有 URL、也没有任何路径**——自检有一条断言直接扫全文
  （连 `/` 都不该出现；`dbstat` 的 `name` 只是表名与索引名）。这份文件是拿来给人拷走看的，
  不能因为"只是统计"就把路径与用户名带出去。
- **自检怎么验**：`--self-check` 用 `InMemoryKeyProvider` 的临时库调**同一个** `StatsExport.export`，
  把 JSON 解析回来逐字段核对（`schema_version` / `device_id` / `generated_by` /
  `exported_at_ms` / `observations` / `text_versions` / `occurrences` / `dbstat` 非空且四个键齐全 /
  文件名），并打印实际字段清单，跑完删除。

### 8.10 本地 IPC 服务端（3.1 / 3.6）

`IPCService.swift` 里的 `MCPIPCService` 挂在 `LockController` 上——那是本进程里唯一持有 `Store`
的地方。协议、socket、grant 判定、裁剪与审计都在 core（`BrosisIPC` + `StoreMCPService` + `MCPGate`），
这里只负责**接生命周期**：

| 时机 | 做什么 |
|---|---|
| 第一次开库成功（`finishUnlock`） | `attach(store:)` + `startIfNeeded(directory:)`：在 `<数据目录>/ipc.sock`（0600）上开始监听 |
| 暂停原因变化（`apply`） | `setPaused(...)`：3.5 的 `paused` 子状态下库开着，但 **MCP 拒绝** |
| 开始关库（`beginLock`）| `detach()`——**在 `store.close()` 之前**，之后所有调用回 `locked`。只把 `service` 置 `nil`，**socket 与既有连接都留着**（不断连接） |
| 退出（`shutdown()` → `stop()`） | 停监听、对每条**存活连接** `shutdown(SHUT_RDWR)`、删掉 socket 文件。这是唯一会断连接的时机 |

**socket 一旦起来就不再关**（除非退出）：锁定时客户端拿到的是一句"brosis 锁着"，
而不是 `connect: No such file or directory`——后者分不清"没装"和"锁着"。
锁定期间被拒的调用写不进 `mcp_audit`（库关着），先攒在内存里（上限 200 条），解锁后补写，
与 8.6 的 `recorder_dropped` 是同一个套路。

**对端校验策略在这里是写死的常量** `.requireSameTeam`：要求对端签名有效且 Team ID 与本进程相同。
本进程自己没有 Team ID（`swift build` 的裸二进制、`SKIP_SIGN=1` 的 bundle）时**一律拒绝**。
core 的 `brosis-store serve` 有个 `BROSIS_IPC_SKIP_CODESIGN=1` 的测试开关，
**产品路径不读任何环境变量**，没有这个口子。

限流默认 60 次 / 分钟 / 客户端，可用
`defaults write com.brosis.app mcp.requestsPerMinute -int 120` 改（`MCPIPCService.rateLimitKey`）。
限流窗口用**单调时钟**，系统时钟被回拨不会放大配额。

菜单里多了一行 `MCP：socket 已就绪 · unlocked`（或 `locked` / `paused` / `socket 未启动`），
用来一眼确认服务端起没起。

## 9. 数据库

目录默认 `~/Library/Application Support/brosis/`（0700、`.metadata_never_index`、排除 Time Machine，
由 `BrosisCore.DataDirectory` 负责），库文件 `brosis.db`，**SQLCipher 全库加密**，
密钥 256 位、存 data-protection 钥匙串。schema 是 core 的 v1（计划 3.2 全部表），
`core/README.md` 有完整对照。采集端只写下面这几张：

| 表 | 采集端往里写什么 |
|---|---|
| `apps` / `windows` / `urls` / `files` | 规范化对象。`urls.kind` 由 `EventSkeleton.urlRef` 推断（`http(s)` → `web`，`file://` 或绝对路径 → `file`，其他 `scheme://` → `deeplink`，否则 `other`）；`kAXDocument` 的 `file://` 转成文件系统路径进 `files.path` |
| `observations` | ts（Unix **毫秒**）/ display_id / 四个对象外键 / trigger / capture_method=`ax` / completeness / source_state |
| `text_versions` + `occurrences` | **脱敏后的 AX 正文**，`region` = AX 角色，`ord` = 角色在 `AX.textRoles` 里的顺序。core 侧做 NFKC 折叠 → sha256 去重 → bigram 写 FTS |
| `capture_stats` | 承接 M0 的 `frame_stats`：dHash / 汉明距离 / 变化格子数与面积比 / gated / trigger / ax_chars；`status ∈ {complete, failed, skipped, ax, private_browsing}` |
| `jobs` | 运行期事件，`type = 'runtime_event:<kind>'`。kind 见下 |
| `app_policies` | 3.12 三档（`bundle_id, mode, source, updated_at`） |

**运行期事件 kind 一览**（`jobs.type = 'runtime_event:<kind>'`，**55 种**）：

- 生命周期（5）：`app_launched`（本次进程只写一次）、`store_unlocked`（之后每次解锁）、
  `app_terminating`、`self_check`、`stats_exported`（M1 R2 新增，见 8.8）
- 事件骨架与 AX（7）：`event_skeleton_started`、`ax_global_timeout_installed`、
  `ax_manual_accessibility`、`ax_observer_skipped`、`ax_observer_create_failed`、
  `ax_element_notifications_throttled`、`ax_bfs_limit_hit`
- 截图（7）：`capture_armed`、`capture_disarmed`、`capture_progress`、`capture_failed`、
  `capture_paused`、`capture_resumed`、`capture_display_changed`
- 策略与脱敏（5）：`capture_policy_frontmost`、`app_policy_new_app`、`app_policy_changed`、
  `app_policy_paused_today`、`redaction`
- 库与锁定（7）：`store_opened`、`store_closing`、`lock_transition`、`lock_unlock_deferred`、
  `low_disk`、`thermal_state`、`recorder_dropped`
- 系统级事件（10，**只写这里、不写 `observations`**）：`screen_locked_detected`、
  `screen_unlocked_detected`、`screen_locked`、`screen_unlocked`、`system_will_sleep`、
  `system_did_wake`、`screensaver_started`、`screensaver_stopped`、
  `user_switched_away`、`user_switched_back`
- 权限（11）：`permission_missing`、`permission_request_started`、`permission_request_finished`、
  `permission_request_pending`、`permission_regained`、`permission_guide_shown`、
  `permission_guide_completed`、`permission_guide_open_settings`、`permission_guide_rerequest`、
  `permission_guide_dismissed`、`app_relaunch_requested`
- 登录项（3）：`login_item_registered`、`login_item_unregistered`、`login_item_error`

**锁定期间的写入会被丢弃并计数。** 采集端的事件源（AXObserver 回调、`DispatchSourceTimer`）是异步的，
不可能保证它们在关库那一刻全部静默。`Recorder` 在库不存在时把写入按类型计数
（观察 / 事件 / 遥测），**下一次开库当场**写一条 `runtime_event:recorder_dropped`——
"锁定期间丢了多少"是可核对的，不是悄悄消失。菜单栏「写入：」那一行实时显示同一组计数。

**M1 R2 修正了它的时机**：原来是 `detach()`（关库那一刻）把**当时的累计计数**攒起来、
等下一次 `attach()` 回放，可锁定期间的丢弃**发生在 `detach()` 之后**，
于是每条事件都晚一个锁定周期——锁一次解一次，库里什么都没有；要锁第二次解第二次
才看到第一次的数字（第一轮"需要用户在 GUI 里验证"的第 11 条因此永远对不上）。
现在改成在 `attach()` 里算差值（`当前累计 − 上一次 attach 时的累计`），
**锁一次解一次就能看到一条**，detail 形如
`dropped_observations=3 dropped_events=12 dropped_capture_stats=1 errors=0；累计 观察 …`。
没丢过就不写。自检用一个独立的临时加密库把整条路径走了一遍（第 4 节的「`recorder_dropped` 时序」两项）。

**M0 的明文库**：`~/Library/Application Support/brosis-m0/`（`m0.sqlite` + `m0-selfcheck.sqlite`）
**原样保留、本版本不读不写不迁移**。它的 schema 与 v1 差得太远，迁移的收益抵不上污染 v1 库的风险；
要看 E4 的老数据直接用 `sqlite3` 打开那两个文件即可。

## 10. 给 Claude Code 配置 brosis-mcp（3.6）

前提：`brosis.app` 已经在跑、处于 `unlocked`（菜单里那行 `MCP：socket 已就绪 · unlocked`）。
`brosis-mcp` 在 bundle 里：`/Applications/brosis.app/Contents/MacOS/brosis-mcp`
（本轮还没装到 `/Applications`，路径按你实际放的位置写）。

**第一步：建第一份 grant。** 没有 grant 的客户端**九个工具全拒**，这是 3.6 的口径，
不是"先能用再收紧"。

```sh
MCP=/Applications/brosis.app/Contents/MacOS/brosis-mcp

# 看看现在有哪些客户端被授权了（第一次是空的）
$MCP admin grant list

# 给 Claude Code 一份：全部应用、30 天窗口、可以展开原文
$MCP admin grant add --client claude-code --fields evidence --apps '*' --time-window 30

# 更保守的一份：只给两个应用、7 天、只给摘要（默认就是 summary）
$MCP admin grant add --client claude-code --fields summary \
     --apps com.electron.lark,com.tencent.xinWeChat --time-window 7

$MCP admin status                 # 相位、schema 版本、grant 数、审计行数
$MCP admin audit --limit 20       # 最近的调用审计（不含正文，也不含查询串本身）
$MCP admin grant remove --client claude-code
```

`admin` 走的是同一条本地 socket，服务端只接受**同 uid 且通过代码签名校验**的对端；
`brosis.app` 没跑或锁着的时候它会明确告诉你连不上 / 锁着。

`--apps` 给了具体清单（不是 `'*'`）时，白名单外的东西**一点都不给**：不只是结果行，
`get_evidence` 每条证据附带的"出现上下文"（前后相邻的观察，带 bundle id 与窗口标题）
也会逐条滤掉，被滤掉几条在返回值的 `grant.droppedByGrant` 里报出来。
另外两条口径值得知道：`get_day_ledger` 按自然日预聚合，**时间窗起点落在某天中间时那天仍是整天口径**
（返回值里 `coversBeforeWindowStart = true`）；白名单生效时台账 / 时间线 / `get_item(url|path)`
会丢掉几个回不到"哪个应用"的字段，丢了什么在 `droppedFields` 里列着。

**第二步：把它加进 Claude Code。**

```sh
claude mcp add brosis /Applications/brosis.app/Contents/MacOS/brosis-mcp
```

Claude Code 会用 stdio 拉起这个进程，`initialize` 里的 `clientInfo.name` 就是 `client_id`
（Claude Code 报的是 `claude-code`）。要给同一个客户端开两份不同范围的 grant，
用环境变量区分：

```sh
claude mcp add brosis-lark --env BROSIS_CLIENT_ID=claude-code-lark \
       -- /Applications/brosis.app/Contents/MacOS/brosis-mcp
```

**九个工具**，全部 `readOnlyHint = true`（3.6：这只是给客户端看的提示，不是隔离；
真正的只读保证在服务端——`StoreMCPService` 只调 `Store` 的查询方法，没有任何写入入口）。
参数与返回见 `core/README.md` 的「本地 IPC 与 `brosis-mcp`」一章。

| 工具 | 干什么 | 典型用法 |
|---|---|---|
| `search(q, start, end, app, limit)` | 三通道检索，每条 ≤ 100 token 摘要 + `evidenceID` | 找东西的入口 |
| `get_evidence(ids)` | 按 `evidenceID` 展开原文与出现上下文 | 接在 `search` 后面；**受 grant 的 `fields` 限制** |
| `get_context(hours, max_tokens)` | 最近 N 小时的活动摘要 + 正文片段，按 token 预算截断 | "我刚才在干什么" |
| `get_timeline(start, end, granularity)` | hour / day / week 分桶的活动时间线 | 画趋势 |
| `get_day_ledger(date)` | 某一自然日的确定性台账 | "上周三我一天怎么过的" |
| `get_item(url \| path \| app)` | 某个 URL / 文件 / 应用的汇总 | "这个文档我看过几次" |
| **`get_week_ledger(week)`**（M2） | 某一 ISO 周的台账（7 个日台账聚合），含 7 行按天分布 | "上周整体怎么样" |
| **`get_patterns(start, end)`**（M2） | 星期 × 小时热力、每应用常用时段、会话长度与打断率、最常切换对、连续工作块 | "我一般几点效率最高" |
| **`recent_activity(minutes, max_items)`**（M2） | 最近 N 分钟的应用聚合 + 会话 + ≤ 100 token 的观察摘要 | 最轻的一条"现在在干什么" |

典型用法是 `search` 拿 `evidenceID`，再 `get_evidence` 展开原文。
后三个是 M2 c 批 / T14 补的（3.6 里写明"放 M2"的那三样），**全部确定性、不经过任何模型**；
台账上的 `narrative` 字段是另一条可选的夜间叙述任务贴的标注，与台账分开标注（3.7），
没跑过就是 `null`。**应用白名单生效时 `get_patterns` 是换输入重算**（热力图 / 切换对 / 工作块
都只用白名单内应用的观察），返回值里的 `appFilter` 与 `scopeNote` 会说明这一点。

**排查**：

| 现象 | 原因 |
|---|---|
| `连不上 brosis 存储服务` | app 没跑，或还没第一次解锁过（socket 要开库成功后才建） |
| `[locked]` / `[paused]` | 3.5：库关着 / 采集暂停（用户暂停、锁屏、屏保）。解锁或恢复采集 |
| `[no_grant]` | 这个 `client_id` 没有 grant，按上面第一步建一份 |
| `[denied_by_grant]` | 应用白名单 / 时间窗 / 字段级别挡下了；`admin grant list` 看范围 |
| `[rate_limited]` | 每客户端 60 次 / 分钟，等一会儿或改 `mcp.requestsPerMinute` |
| `[unauthorized_peer]` | 这个 `brosis-mcp` 与 `brosis.app` 的签名 Team ID 不一致（例如你手工编了一份没签名的）。用 bundle 里那一份 |
| 退出 brosis.app 再启动之后，第一次调用慢了一下 | 正常：app 退出时 `IPCServer.stop()` 会把存活连接断掉，`brosis-mcp` 下一次调用自己重连（重试前等 150 ms，避开服务端起 socket 时 `bind` 与 `listen` 之间的窗口）。**不用重启 Claude Code**。锁定 / 解锁**不会**断连接，只会让调用返回 `[locked]` |
| 想知道它连的是哪个 socket | `$MCP --print-socket` |

**如实说明**（3.6 原话）：`mode = strict_local` 只是 grants 表里的一个标记加审计，
**系统无法在技术上验证客户端是否把内容外发**；工具返回的正文用
`<brosis:evidence>` 分隔符包起来并标了 `readOnlyHint`，那也只是**提示不是隔离**。
真正硬的是服务端那几条：只读、按 grant 裁剪、限流、每次调用都进 `mcp_audit`。

## 11. 还没做 / 需要你操作的

**需要真人在 GUI 里验证的（本轮全部没跑）**：

1. **钥匙串授权与取钥**：首次运行弹一次授权框，点「始终允许」后菜单里「数据库：」应变成 `unlocked`。
   `KeychainKeyProvider` 从 T2 交付起就没有实跑过（会弹框），本轮同样没跑。
2. **ACL 是否真的限住了本应用**：换个进程（例如 `security find-generic-password`）去读同一条目
   应该被拒或要求单独授权。
3. **锁定状态机的真实触发**：合盖睡眠 → 醒来、注销、菜单「锁定 / 解锁」、屏保启停、锁屏与
   `lock.strict=true` 下的锁屏。转移逻辑本身有 21 条转移 + 7 条补做用例（纯函数），
   但"通知真的会来"只能在 GUI 里看。**特别值得看一次**：睡眠后很快唤醒（关库还没落地就醒），
   预期库里出现 `lock_unlock_deferred` 且状态最终回到 `unlocked`，而不是停在 `locked`。
4. **低磁盘 < 2 GiB**：需要把卷填到 2 GiB 以下，本轮没做（也不建议为它填盘）。
5. **热状态 critical**：无风扇 Air 上 E9 实测持续负载只到 `fair`，`critical` 没复现过。
6. **AX 正文真的入库**：授权后跑一会儿，看菜单「写入：」的观察数在涨，且 `text_versions` 有行。
7. **3.12 三档的实际效果**：把某个应用改成「不采集」后，它不该再产生观察；
   「只记事件」的应用应该有观察但 `completeness = excluded`。
8. **菜单快捷项**「暂停采集当前应用（今天 / 永久）」与「恢复采集」。
8b. **应用采集清单窗口（T9，本轮新加，全部需要真人看）**：
   - 菜单栏 →「应用采集清单…」应打开窗口，三组（有适配器 / 通用采集 / 默认不采集）都在，
     组标题行显示每组条数；跑过一阵之后「最近 7 天观察」与「完整性分布」应该有数字。
   - **搜索框**输入中文应用名与 bundle id 片段（大小写混着打）都能过滤。
   - **顶部「新应用的全局默认档」**改成「只记事件」，再打开一个从没用过的应用，
     库里那条 `app_policy_new_app` 的 `mode` 应是 `events_only`；已经在清单里的应用不受影响。
   - **升档不问删数据**：把某个应用从「只记事件」改成「事件 + 内容」，不该弹框。
   - **降档问删数据**：把一个有数据的应用从「事件 + 内容」改成「不采集」，应弹框，
     **默认按钮是「保留数据」**；选「保留」→ 库里多一条 `app_policy_downgrade_kept_data`；
     再降一次并选「删除这 N 条」→ 窗口底部显示删了多少、释放多少字节，
     库里多一条 `app_policy_downgrade_deleted`，该应用的观察数归零、策略行还在。
   - **锁定时改不了档**：⌘L 锁库后打开窗口，横幅应出现、整列弹出菜单是灰的；
     这时菜单栏的「暂停采集当前应用 → 今天」应该照常能用。
   - **新应用提示**：第一次遇到某个应用时菜单栏应出现一行
     「新应用 … 已按默认档「…」记录（点此改档）」，点它打开窗口并**选中那一行**；
     点过之后这一行不再出现（重启 app 也不再出现）。
8c. **「检查更新…」菜单项（T10 的入口，本轮接进菜单）**：点一次应弹
   「更新功能未启用：SUPublicEDKey 还是占位符…」——除非已经按 `dist/RELEASE.md`
   配好了真公钥再构建。点它之前不应有任何出网。
9. **私密浏览**：Safari 开无痕窗口，看该窗口的观察 `completeness = excluded`，
   且**没有正文、没有窗口标题、没有 URL**（`windows` / `urls` 里不该出现那个无痕窗口）。
10. **屏幕录制月度再授权**（第 6 节）与 **SMAppService 登录项批准**（第 7 节）。
11. **锁定期间的丢弃计数**：⌘L 锁一次、再解锁一次，库里就该有**一条**
    `runtime_event:recorder_dropped`（M1 R2 之前要锁两次才看得到，见第 9 节）。
12. **「导出存储统计…」**：解锁状态下点一次，数据目录里应出现 `stats-<日期>.json`，
    Finder 会选中它；库里同时多一条 `runtime_event:stats_exported`。
    锁定状态下这个菜单项是灰的。JSON 的字段见 8.8。
13. **MCP 的 socket 真的起来了**：app 解锁后菜单里应显示 `MCP：socket 已就绪 · unlocked`，
    数据目录里应出现 `ipc.sock`（`ls -l` 看到 `srw-------`）；
    `/Applications/brosis.app/Contents/MacOS/brosis-mcp admin status` 应打出 JSON。
    ⌘L 锁一次再看，`admin status` 应报 `[locked]`；解锁后 `admin audit` 里能看到那条 `locked` 记录
    （它是解锁后补写的）。
14. **Claude Code 真的连上**：`claude mcp add brosis …` 之后在 Claude Code 里 `/mcp` 应能看到
    6 个工具；第一次调用应因为没有 grant 被拒，`admin grant add` 之后再调应该有结果。
    这一步只有真人在 GUI / 终端里做得了（第 10 节）。
15. **对端签名校验的负面用例**：拿 `swift build` 出来的那个**未签名**的 `brosis-mcp`
    去连正在跑的 app，应当被拒并在 `admin audit` / 库里留下 `unauthorized_peer`。
16. **app 重启之后 `brosis-mcp` 自己重连**（M1 R2 第三轮修的就是这条）：
    解锁 → 在 Claude Code 里调一次 brosis 工具 → **退出 brosis.app** → 重新启动并解锁 →
    再调一次。修之前这一步会让 `brosis-mcp` 被 SIGPIPE 打死（要重启 Claude Code），
    现在应该只是慢一下（重连的 150 ms）就自己接上。
    注意**锁定不算**这条路径：锁定不断连接，只让调用返回 `[locked]`（那是第 13 条）。
17. **适配规则在真窗口上的表现（T8，最需要真人看的一批）**：
    - **Safari**：打开一篇长文，滚到中间。库里那条观察的 `capture_method` 应是 `adapter`，
      `visible_range` 里 `offscreen` / `scrollback` 应大于 0，正文里**不该有**屏幕外那几屏的内容。
    - **Claude 桌面版**：现在它已经在 `chromiumFamilyBundleIDs` 里，应该能读到 AXWebArea。
      读到了 → `capture_method = adapter`；仍然读不到 → 应看到 `runtime_event:ocr_regions_captured`
      且观察是 `capture_method = ocr`。**两种结果都要记下来**，它决定这条规则最终长什么样。
    - **飞书**：打开一个会话滚几屏。先看 `AXList` 那条路走不走得通（`adapter` 且正文里有消息），
      走不通就该看到 `ocr:feishu.message_list` 的片段。顺带确认顶部会话名 OCR 出来的对不对。
    - **微信**：单聊与群聊各看一次。重点核**相对矩形对不对**（`chat_panel` 是左 22% 之后、
      上 8%–78%）——窗口比例不同会偏；以及气泡归属对不对（左 = 对方、右 = 自己、群聊昵称）、
      语音是不是记成 `[语音]`、会话名 OCR 出来对不对。
    - **OCR 频率**：连续操作 1 分钟，`capture_stats` 里 `ocr_regions` 非空的行不该超过
      `60 / 5 = 12` 条每区域；`ocr_failed` 应为 0。
    - **采样审计**：跑够 50 条 AX 非空的观察后，库里 `capture_audit` 应出现一行，
      `runtime_event:capture_audit` 里能看到覆盖率。**这个数字是 2.4「常用应用 complete + partial ≥ 90%」
      的校准依据**，请按应用记下来。
    - **主线程有没有变卡**：适配规则比 M0 多问了元素坐标。切应用 / 滚动时菜单栏应该照常跟手；
      如果卡，看 `runtime_event:adapter_limit_hit` 里有没有 `hit=frame_probe`，
      有就把 `maxFrameProbes` 调小。
    - **切走之后不许串台（R2 复核补的那条，真机务必看一次）**：微信 / 飞书停在前台几秒，
      再切到 **Safari 无痕窗口**，停十几秒。库里不该出现任何 `region` 以 `ocr:wechat.` /
      `ocr:feishu.` 开头、而内容是无痕页面的观察；无痕那段时间的观察应当是
      `completeness = excluded` 且没有正文 / 标题 / URL。换成"AX 会超时的访达"再试一遍
      （M0 实测 22% 超时），同样不该出现归属错误的 `ocr:` 观察。
    - **OCR 新鲜度**：微信停在前台不动几分钟。`ocr:wechat.chat_panel` 的观察应该只有**一条**
      （屏幕没变就不写第二条）；发一条新消息之后应该立刻多出一条。

**本轮明确没做的**：

- **3.12 的应用清单窗口**（分组、7 天统计、改档时询问是否删数据）→ 第二轮。
- **查询时那一道脱敏**（计划 4.2 说入库前一道、查询时一道）→ 属于 T3 的检索层。
- ~~**视口裁剪**~~、~~**适配器、局部 OCR、`completeness = complete` 的判定、采样审计**~~
  → **M1 R2 / T8 已做**，见 8.6；但四条规则的区域参数都还没在真机上核过（第 11 节第 17 条）。
- **适配器的菜单入口**：本轮按并行约束没改 `AppDelegate.swift`，
  `CaptureCoordinator.shared.currentStats` 已经就绪，接进菜单由主会话做。
- **OCR 结果没有二次校验**：同一区域两次识别不一致时不做投票，取最后一次。
- **未公证**；`spctl` 预期 `rejected: Unnotarized Developer ID`。
- `NSAppleEventsUsageDescription` 与 `com.apple.security.automation.apple-events` 已就位，
  但没有真去发 Apple 事件（浏览器 URL 目前只走 AX）。
- **AX 0.5 s 超时**仍只验到「SDK 文档 + 对 system-wide 元素返回 `.success`」，没有端到端计时证据。
- 路径型 TCC 可见性、剪贴板 `accessBehavior` 都没碰。

## 12. 跨设备同步（3.9 / D17，M2 c 批 / T13）

### 12.1 三个新文件，`AppDelegate.swift` 一行没改

| 文件 | 干什么 |
|---|---|
| `SyncController.swift` | 开关、定时循环、状态数据、事件记录；`install(lock:recorder:)` 挂到锁定状态机上 |
| `SyncWindow.swift` | 设置窗口：开关、目录、配对口令、状态显示、「立即同步」 |
| `SyncSelfCheck.swift` | 自检里的两库往返冒烟（无 GUI、无 TCC、不碰钥匙串） |

**接入方式（由主会话加，两行 + 一个菜单项）**：

```swift
// AppDelegate.applicationDidFinishLaunching(_:)，lock 建好之后：
sync = SyncController()
sync.install(lock: lock, recorder: recorder)

// 菜单里加一项（可选；窗口也能从 sync.presentWindow() 打开）：
menu.addItem(NSMenuItem(title: "跨设备同步…", action: #selector(openSync), keyEquivalent: ""))
@objc private func openSync() { sync?.presentWindow() }
```

`install` 会**链式保留** `LockController` 原有的 `onUnlocked` / `onLocking` 回调，不覆盖，
所以加这两行不改变现有行为。自检那边也只加了一行 `failures += SyncSelfCheck.run()`。

### 12.2 循环什么时候跑

- 只在 `phase == .unlocked` 跑——库开着才有得读写；`locked` / `locking` / `unlocking` 全停。
- **`paused` 不停同步**：暂停的是"采集新内容"，同步只是把已经采集到的东西搬进搬出，
  不产生新观察、不看屏幕。这是一条判断，不是疏忽。
- 默认 5 分钟一轮（3.9「定期（如每 5 分钟或每 N 条）」），一轮 = 入站 → 出站 → 清理。
- 文件 I/O 与加密全在一条 utility 串行队列上，不占主线程；一轮没跑完不会再起一轮。

### 12.3 UserDefaults 键

| 键 | 默认 | 说明 |
|---|---|---|
| `sync.enabled` | `false` | 开关，3.9「默认关」 |
| `sync.directory` | `~/Library/Mobile Documents/com~apple~CloudDocs/brosis-sync` | 高级选项可改成任意同步盘 / NAS |
| `sync.intervalSeconds` | `300` | 下限 30 s |
| `sync.deviceName` | 电脑名 | 只写进同步目录的 `devices/<id>.json`，**不入库** |

### 12.4 打开开关时会发生什么（3.9「打开时的流程」）

1. 目录路径含 `com~apple~CloudDocs` 但 iCloud Drive 目录不存在 → 报"iCloud 没登录 / 没启用"，开关保持关。
2. 目录里没有 `manifest.json` → 建目录、生成同步密钥、写 manifest 与 `keyring/<本机>.wrapped`，
   弹一次「配对口令（只显示这一次）」的对话框，可拷贝。**口令不存任何地方**，忘了只能重新配对。
3. 目录里已有 `manifest.json` → 要求输入配对口令解开同步密钥；口令错就不加入（开关弹回关）。
   加入成功后把同步密钥留在**本机加密库**里，以后重开 app 不再问口令。
4. 写 `devices/<本机>.json`（设备名、加入时间、最后出站 seq），起循环。

关掉开关：停两个循环，**本机已合并的数据保留**。"退出并删除本机段文件"是另一个独立操作，本轮没做。

### 12.5 状态显示（3.9）

窗口里有：上次同步时间、待导出条数（观察 / 删除）、待导入段数、本机段文件个数与目录字节、
每台其他设备的「已导入到第几段 / 待导入几段 / 最后出现时间 / 错误」。
错误分得细，能看出是**缺段**、**校验失败**（文件坏了）、**解密失败**（密钥不对）还是 **iCloud 还没下载**。

### 12.6 事件

同步的每一步都写 `jobs` 表的 `runtime_event:*`（与其他运行期事件一个口径）：
`sync_folder_created` / `sync_joined` / `sync_enabled` / `sync_disabled` / `sync_round` /
`sync_export` / `sync_import` / `sync_missing_segment` / `sync_import_failed` /
`sync_manifest_conflict` / `sync_cleanup` / `sync_open_failed`。
`sync_enabled` 只记目录**种类**（`icloud_drive` / `icloud_container` / `custom`），不记路径——
路径里可能有用户名。

### 12.7 需要你在两台真机上验证的

见第 11 节新增的几条：真机同步延迟、iCloud 占位符驱逐后的下载等待、配对口令的一次性显示、
两台机器同时首次打开时的 manifest 冲突提示。


---

## 13. 模型管理器与向量检索（3.4 / 3.11 / D18 / D27，M2 c 批 / T11）

### 13.1 三个新文件 + 一个新目标，`AppDelegate.swift` 一行没改

| 位置 | 是什么 |
|---|---|
| `Sources/BrosisModels/`（**新的库目标**） | 模型清单 `Catalog`、下载器 `HFDownloader`、模型目录 `ModelStore`、本地嵌入运行时 `MLXEmbeddingProvider`、D27 内存策略 `MLXMemoryPolicy`、GPU 冒烟 `MLXSmoke`。依赖 mlx-swift-lm **3.31.4** 与 swift-transformers **1.3.4**（版本固定，与 E9 实测过的那两个相同） |
| `Sources/brosis/Models/ModelsWindow.swift` | 「模型与向量检索」面板 + 菜单接入点 `ModelsMenu` |
| `Sources/brosis/Models/EmbeddingScheduler.swift` | 夜间嵌入任务的门控与调度 |
| `Sources/brosis/Models/ModelsSelfCheck.swift` | 第 4 节自检的第 8 组（`SelfCheck.swift` 只加了一行） |
| `Sources/brosis-embed/`（**新的可执行目标**） | 嵌入任务与查询向量的命令行入口，供 `tools/eval` 的 D8 实验与验收使用 |

**为什么 mlx 放在 app 包而不是 core 包**：core 要保持零 mlx 依赖，
`swift test --package-path core` 才不必解析、编译 mlx-swift（几分钟 + 数 GiB），
`brosis-mcp` 也不会因此从 1 MiB 变成 40 MiB。core 只定义 `EmbeddingProvider` 协议
（计划 3.10 的提供方抽象），这里给它一个本地实现。

**接入方式（留给主会话，两行）**：

```swift
// AppDelegate.applicationDidFinishLaunching 里，recorder 与 lock 都就绪之后：
ModelsWindowController.shared.configure(
    recorder: recorder,
    lockSnapshot: { [weak self] in self?.lock.snapshot ?? LockSnapshot() })
// AppDelegate.refreshMenu() 里，「应用采集清单…」那一项后面：
menu.addItem(ModelsMenu.menuItem())
```

菜单项标题自带状态后缀，不打开面板也能一眼看出向量检索开没开：
`未启用：未安装嵌入模型` / `已装模型，尚未建索引` / `已建索引 N 块，检索开关关着` /
`向量检索已开（N 块）`。

### 13.2 默认零模型，未安装时功能显示为「未启用」（3.11）

app **不内置、不自动下载**任何模型。清单 `catalog.json` 随包，**运行时不联网拉清单**。
D29 叙述下架后清单里没有生成模型；**D30（2026-09-08）起嵌入模型是多尺寸、可切换**：

| 清单项 | 体积 | 原生维度 | 最低内存 | Air 实测吞吐 | C-MTEB 检索 | 说明 |
|---|---|---|---|---|---|---|
| `Qwen3-Embedding-0.6B-8bit` | 0.60 GiB | 1024 | 8 GiB | 16.3 块/s | 71.03 | 快档，唯一不需要截断的 |
| `Qwen3-Embedding-4B-4bit-DWQ` | 2.12 GiB | 2560 | 8 GiB | 1.20 块/s | 77.03 | 平衡档 |
| `Qwen3-Embedding-8B-4bit-DWQ` | 3.98 GiB | 4096 | 16 GiB | 未测 | 78.21 | 质量最好、最慢，建议大内存机器 |

都落到统一的 **1024 维**（`SchemaV4.dimension`，schema v9 从 512 改上来）——所有尺寸同一维度，
换模型只要重建向量、不用改表；0.6B 的原生维度正好是 1024，所以它是唯一不经 MRL 截断的一档。
（0.6B 曾按 D30 去掉，实测 4B 在 Air 上慢 13.6 倍后又加回来当快档。）

**模型从哪来（三条路）**：
1. **下载**：面板里的「下载」按钮，或 `brosis-embed models --download --id <清单 id>`。
   走 `HFDownloader`：探测直连与 hf-mirror 选快的、HTTP Range 断点续传、逐文件 sha256、
   全部通过后整目录原子提交。只放行已批准家族 `Qwen3-Embedding-*` 的清单项（`Catalog.isApprovedID`）。
2. **从本地目录导入**：复制进模型目录，逐文件 sha256（老路，没变）。
3. **关联外部目录（D30 新增）**：`ModelStore.linkExternal`，**一个字节都不复制**，
   模型根目录下只放一个含 `installed.json` 的标记目录，`linkedPath` 指向真实位置
   （例如 LM Studio 的 `~/.lmstudio/models/mlx-community/…`）。外部目录的量化版本和文件集
   跟清单不一样，所以校验不是 sha256 而是**结构校验**：`config.json` 的 `model_type`、
   `hidden_size ≥ 1024`、有 `.safetensors`、有分词器；**GGUF 会明确报错**（mlx 只吃 safetensors）。
   每次列清单都复查一遍，外部目录被删 / 体积变了就显示「关联失效」，向量检索按 3.11 降级；
   「移除」只删标记目录，**绝不动外部目录**。

**切换模型**：面板里选中一行点「设为当前模型」（`models.embedding.current`）。
向量不能跨模型比较，所以库里已经有别的模型建的向量时会先问一句，确认后清空索引重建。
加载路径一律走 `ModelStore.weightsDirectory(root:id:)`（关联的模型指向外部目录）。

面板里能做四件事：**从本地目录导入**（复制进来 + 逐文件校验 sha256，只复制不引用）、
**重新校验**、**移除**、**现在跑一次嵌入任务**。
本轮**没有跑过任何下载**：模型是你此前已批准并下载好的，走的是本地导入。
下载器代码在 `BrosisModels/Downloader.swift`（E9 实测过：直连 12.3 MiB/s、镜像续传 HTTP 206），
面板上的下载入口要显式打开 `models.allowDownload` 才出现。

**存放位置（D18）**：默认 `<数据目录>/models/<模型 id>/`，也就是数据目录**里面**，
不在库里、**不加密、不进 iCloud 同步**（权重是公开的）。
可用 `BROSIS_MODELS_DIR` 或 `defaults write com.brosis.app models.directory -string <路径>` 换。
2026-09-08 之前默认在数据目录**旁边**（`<数据目录>/../models`，落到默认数据目录上就是
`~/Library/Application Support/models`）；app 解锁时会把旧目录里带 `installed.json` 的模型
搬进新目录一次（`ModelStore.migrateLegacyDefaultRoot`，事件 `models_dir_migrated`），
旧目录里别的东西不碰。

### 13.3 夜间嵌入任务的门控（3.1 / D27 / 4.3）

九条判定全在 `EmbeddingGatePolicy.decide`（**纯函数**，自检整段跑 14 条用例），
顺序有意义——先报你自己能改的那一条：

| 顺序 | 不跑的原因 | 判据 |
|---|---|---|
| 1 | `disabled_by_user` | 面板里的「夜间自动建索引」没打开（**默认关**） |
| 2 | `model_not_installed` | 嵌入模型没装 |
| 3 | `nothing_pending` | 没有待办的块 |
| 4 | `locked_*` | 锁定状态机不是 `unlocked` |
| 5 | `paused` | 采集暂停（锁屏 / 用户暂停）——**锁定态不跑** |
| 6 | `on_battery` | 没接电（`IOPSCopyPowerSourcesInfo`，不需要任何权限） |
| 7 | `not_idle` | 空闲不足 **5 分钟**（`CGEventSource.secondsSinceLastEventType`，只问"多久没动"，不读事件内容） |
| 8 | `thermal_*` | `ProcessInfo.thermalState != .nominal` —— **fair 就暂停**（D27：无风扇 Air 持续负载 2 分 10 秒转 fair，吞吐掉 33.6%） |
| 9 | `gpu_budget_exhausted` | 今天的 GPU 预算用完（默认 **600 s = 10 分钟**，对应 4.3 验收「日均 GPU < 10 分钟」） |

跑起来之后**每批再问一次**同样的条件，所以转 fair、拔电、你回来动鼠标都会当场干净停下，
已经写进去的块保留（任务是幂等的，下次接着捡）。

**内存（D27）**：加载模型**之前**设 `MLX.Memory.cacheLimit = 256 MiB`，任务结束
`MLX.Memory.clearCache()`。批 16。本轮实测见结果文件。

**事件**：每次运行往 `jobs` 写一行 `runtime_event:embedding_run`，
`input_ref` 里有块数、剩余、GPU 秒数、**今日累计 GPU 秒数**、预算、停止原因、峰值 footprint、热状态。

### 13.4 UserDefaults 键

| 键 | 默认 | 说明 |
|---|---|---|
| `embedding.enabled` | false | 夜间自动建索引 |
| `embedding.dailyGPUSeconds` | 600 | 日均 GPU 预算（秒） |
| `embedding.batchSize` | 16 | 每批块数（D27 实测过的档） |
| `embedding.gpuSecondsUsed` / `embedding.gpuSecondsDay` | — | 今日 GPU 台账（本机策略，不进库、不同步） |
| `embedding.overnightGPUSecondsUsed` / `embedding.overnightGPUSecondsDay` | — | **整晚建索引单独的一本账**（M2 d / T15，不占上面那 600 s 预算） |
| `retrieval.vectorsEnabled` | false | 检索里用不用向量。**M2 d / T15 起解锁时会从这里恢复到 `store.retrieval`**（模型没装则强制关，3.11） |
| `models.directory` | — | 模型根目录（不设就是数据目录里的 `models/`） |
| `models.embedding.current` | — | 当前生效的嵌入模型 id（D30；不设就取第一个装着的） |
| `models.allowDownload` | false | 面板里是否显示下载入口 |

### 13.5 打包（`build_app.sh` 新增的三件事）

1. **现编 `mlx.metallib`**（`Support/build_metallib.sh`，要 Metal Toolchain）放进
   `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`。
   位置不能换：`Contents/MacOS/` 下的**任何**文件都被 codesign 当作嵌套代码去校验，
   而 metallib 是 MTLB 格式、不是可签名的 Mach-O，放那儿必然报
   `code object is not signed at all`（E9 实测）。
2. 把 SwiftPM 生成的资源 bundle（`brosis_BrosisModels.bundle` 的清单、
   `swift-transformers_Hub.bundle` 的 tokenizer 配置）拷进 `Contents/Resources`，
   清单再平铺一份。
3. 把 `brosis-embed` 放进 `Contents/MacOS` 并**单独签**（与 `brosis-mcp` 同一处理），
   然后第 4c 步**从 bundle 里真跑一次 `brosis-embed env`**：GPU 冒烟必须算对、
   sqlite-vec 必须已注册、清单里必须有嵌入模型且没有生成模型（D29），否则构建失败。

### 13.6 `brosis-embed` 用法

```sh
APP=~/Library/Caches/brosis-build/<你的 scratch>/brosis.app
"$APP/Contents/MacOS/brosis-embed" env
"$APP/Contents/MacOS/brosis-embed" models --dir <数据目录> --list
"$APP/Contents/MacOS/brosis-embed" models --dir <数据目录> --import \
    --id Qwen3-Embedding-4B-4bit-DWQ --from <已下载好的模型目录>
"$APP/Contents/MacOS/brosis-embed" embed --dir <数据目录> --key-file <密钥> --batch 16
"$APP/Contents/MacOS/brosis-embed" queries --file <[{"id","q"}…]> --out <向量表.json> \
    --models-dir <模型目录>
```

`queries` 出的向量表喂给 `brosis-store search-batch --vectors --query-vectors <向量表>`，
就是 D8 实验的那条路（见 `tools/eval/run_d8.sh`）。

### 13.7 `brosis-embed selftest`：**用真实模型**的那一组断言

core 的 `swift test` 一条都不碰模型（那边用确定性伪嵌入），所以「真实模型到底对不对」
只能在这里验。**模型没装时打印 `skipped` 并以退出码 0 结束**，CI 上没有模型也不会红。

```sh
"$APP/Contents/MacOS/brosis-embed" selftest --models-dir <模型目录>
```

**十一条**断言（前六条 M2 c / T11，后五条 M2 d / T15），本机
（D30 之前是 Qwen3-Embedding-0.6B-8bit）实测全过：

| 断言 | 实测 |
|---|---|
| 维度 = 512（MRL 截断自 1024） | `[512, 512, 512]` |
| 截断后重新 L2 归一化 | `1.000000` × 3 |
| 同一批构造下两次嵌入逐位相同 | 逐位相同 |
| **换批大小只改动 1e-3 量级**（E9 已知限制，不是 bug） | 批 1 vs 批 3 的余弦 **0.999997** |
| 近义句余弦 > 无关句余弦 + 0.2 | **0.8370 vs 0.2920**（E9 在 Max 上是 0.87 / 0.24） |
| int8 量化后余弦误差 < 0.01 且排序不变 | 0.8370→0.8373、0.2920→0.2918 |
| **查询嵌入器与索引侧 provider 的向量逐元素相同**（同为批构造 1） | 512 维逐元素相同 |
| **查询嵌入热延迟 ≤ 150 ms**（3.4 分层目标） | 首次（含加载）**364 ms**、热 **18.3 ms** |
| 空闲到点后卸载并清 GPU 缓冲池（D27） | 卸载原因 `idle_0s`（把门槛调成 0 秒来测） |
| 关库时立刻卸载 | `store_closed` |
| 关库之后不再算查询向量（零模型调用） | 返回 nil，调用方按 `no_query_vector` 降级 |

模型加载 **0.351 s**（M2 c 那次是 0.998 s，同一台机器，差别是页缓存冷热），
整个 selftest 进程 peak footprint **2,186.7 MiB**（它先后加载了四个嵌入器实例，
产品路径只有一个；单个嵌入器加载后的 peak 见 15.4 的 **732.0 MiB**）。

---

## 14. 夜间叙述（4.3 / 3.7 / 3.10 / D19 / D27，M2 c 批 / T12）——**2026-09-08 已下架（D29）**

> **这一节描述的功能现在不可用**：按用户决定去掉了叙述。`catalog.json` 不再列生成模型、
> 菜单没有「夜间叙述」子菜单、`AppDelegate` 不再 `configure` / `start` `NarrativeScheduler`。
> 下面的代码与 schema v6 的 `narrative` / `model` / `narrative_meta` 三列**原样保留但休眠**
> （自检仍跑门控与忠实度的纯逻辑用例）。恢复步骤：装回生成模型 → 把条目加回 `catalog.json`
> 与 `Catalog.approvedIDs` → 恢复 `AppDelegate` 的两行接线和 `narrativeMenuItem()`。

### 14.1 四个新文件，`AppDelegate.swift` 一行没改

| 文件 | 做什么 |
|---|---|
| `Sources/BrosisModels/MLXGenerationProvider.swift` | 本地生成运行时（mlx-swift-lm 的 `LLMModelFactory` + `ChatSession`），实现 core 的 `GenerationProvider` |
| `Sources/brosis/Models/NarrativeScheduler.swift` | 夜间叙述任务的门控与调度（复用 T11 的环境采集与 GPU 预算账） |
| `Sources/brosis/Models/NarrativeSelfCheck.swift` | 自检第 9 组（门控 15 条、提示裁剪、忠实度 6 条、端到端）——`SelfCheck.swift` **只加一行** |
| `Sources/brosis/Models/NarrativeSmoke.swift` | `--narrative-smoke`：用**真实模型**跑一次（`main.swift` 只加三行） |

`Package.swift` 只多一行：`BrosisModels` 加 `MLXLLM` 产品（同一个固定的 mlx-swift-lm 3.31.4）。

**主会话接入**（两行，放在 `AppDelegate` 起 `EmbeddingScheduler` 的地方旁边）：

```swift
NarrativeScheduler.shared.configure(recorder: recorder, lockSnapshot: { lockController.snapshot })
NarrativeScheduler.shared.start()      // 开关关着时 start() 里的定时器不做事
```

界面上要显示状态就调 `NarrativeScheduler.shared.statusLine()`，
它已经把「未启用（没装生成模型 …）」「等待接电」「机器偏热，暂停」这类话翻译好了。

### 14.2 门控：与嵌入任务同一套，同一本 GPU 账

判定顺序与 `EmbeddingGatePolicy.decide` 逐条对齐（用户没开 → 模型没装 → 没有待办 →
库锁着 → 已暂停 → 用电池 → 空闲不足 5 分钟 → 热状态非 nominal → GPU 预算用完）。

**预算共用一本账**：4.3 验收写的是「日均 GPU < 10 分钟（若启用嵌入与叙述）」，
那是两个任务**合起来**的一个预算，所以 `NarrativeScheduler` 直接用 T11 的 `GPUBudgetLedger`
与同一组 UserDefaults 键（`embedding.dailyGPUSeconds` / `embedding.gpuSecondsUsed`）。
叙述任务的定时器比嵌入任务晚 60 s 起跑，免得同一分钟里抢 GPU。

一次 tick 最多写 4 篇，**每篇之前重新过一遍门控**（转 fair、拔电、用户回来动鼠标都当场停）。

### 14.3 UserDefaults 键

| 键 | 默认 | 含义 |
|---|---|---|
| `narrative.enabled` | `false` | 夜间叙述总开关 |
| `narrative.daily` | `true` | 每天一次日叙述 |
| `narrative.weekly` | `true` | 每周一次周叙述 |
| `narrative.maxInputTokens` | 8000 | 输入上限，**只允许往小里调**（8,000 是 D19 实测的 TTFT 上界） |
| `embedding.dailyGPUSeconds` | 600 | 与嵌入任务共用的日均 GPU 预算 |

### 14.4 三条硬约束写死在代码里，不看调用方给什么

1. **`enable_thinking = false`**（D19：思考模式在 Air 上 4,000 token / 124 s 不收敛，一个答案都没有）；
2. **温度 0**（3.10）；
3. 两道保险：墙钟超时（默认 60 s）中止；万一输出里真的出现 `<think>`，
   再过 48 个 token 还没见到 `</think>` 就当场中止（`stopReason = thinking_not_closed`），
   而且核对里 `thinking_detected` 直接判不通过。

D27 照旧：加载前 `Memory.cacheLimit = 256 MiB`，任务结束 `clearCache()`。

### 14.5 `--narrative-smoke`：用真实模型的那一次

`--self-check` 里那一组用脚本化假提供方，几毫秒跑完、不碰 GPU、没装模型也全过。
真实模型要 8–30 s，所以单独一个子命令，**不进默认自检**：

```sh
"$APP/Contents/MacOS/brosis" --narrative-smoke \
    --dir <数据目录> --key-file <密钥文件> --models-dir <模型目录> \
    --date 2026-08-23 --tz UTC --repeat 2 --out result.json
```

默认**不写库**（只生成 + 核对），加 `--commit` 才真的入库。
输出里有 TTFT、tok/s、输入 token（分词器真值与估算器的比值）、峰值 footprint、
热状态、两次生成是否逐字相同、以及忠实度核对的逐条结果。

本机（M4 Air / 16 GiB / 无风扇）在 T3 的 1 个月合成库上实测，数字见
`tools/bench/results/m2_c_narrative_2026-09-08.md`。

### 14.6 体积

加了 `MLXLLM` 之后 app 从 89.14 MiB 涨到 **99.79 MiB**
（主程序 41.80 → 47.14、`brosis-embed` 40.23 → 45.52、metallib 2.99 不变）。
`brosis-embed` 那一份是**可选的**（评估与验收工具，不是产品必需）：
`build_app.sh` 里拷它那一行去掉，app 回到 54.27 MiB。

---

## 15. MCP 检索的查询向量 + 整晚建索引（3.4 / 3.6 / 4.3.2 T15，M2 d 批）

c 批把向量通道做进了 `Store.search`，但**查询向量要调用方算好**，
所以经 `brosis-mcp` 过来的查询一律 `no_query_vector`（c 批结果文件第 9 节第 1 条）。
这一批把那条线接上：**app 侧的 IPC 服务端在收到 `search` 时自己算查询向量**。

### 15.1 四个新文件，`AppDelegate.swift` 一行没改

| 位置 | 是什么 |
|---|---|
| `Sources/BrosisModels/MLXQueryEmbedder.swift` | 唯一真的加载权重的地方：懒加载 + 空闲卸载 + D27 缓冲池策略。放在库目标里是因为 **app 与 `brosis-embed serve-search` 要用同一份实现** |
| `Sources/brosis/Models/QueryEmbedderService.swift` | 产品路径的接线：解锁时注入、关库 / 锁屏 / 关开关时卸载，事件写进 `jobs` |
| `Sources/brosis/Models/OvernightIndexJob.swift` | 「现在开始建索引」一次性动作：门控纯函数 + 进度 + 单独的一本 GPU 账 |
| `Sources/brosis/Models/QueryEmbedderSelfCheck.swift` | 第 4 节自检的第 10 组（`SelfCheck.swift` 又只加了一行） |

改动过的产品文件只有 `IPCService.swift`（三处：`attach` / `detach` / `setPaused`）
与 `ModelsWindow.swift`（一个按钮 + 开关联动）。

**接入方式（留给主会话）**：**不用改任何东西**——注入点在 `MCPIPCService`，
那是 `LockController` 已经在调的路径；面板按钮在 `ModelsWindow` 里，菜单项还是
13.1 的那一行 `ModelsMenu.menuItem()`。

### 15.2 生命周期：常驻 + 空闲 10 分钟卸载

判定是 core 的纯函数 `QueryEmbedderPolicy`（`swift test` 与自检各钉一遍）：

| 事件 | 动作 |
|---|---|
| 第一次有人 `search` | **加载**（不是解锁时加载：解锁只是"允许"） |
| 又一次 `search` | 复用 |
| 空闲 ≥ **600 s**（定时器 60 s 检查一次） | 卸载 + `MLX.Memory.clearCache()` |
| 屏幕锁定 / 用户暂停（3.5 的 `paused`） | **立刻**卸载 |
| 关库（`locking` / 退出） | **立刻**卸载 |
| 用户在面板里关掉「在检索里使用向量」 | **立刻**卸载 |

为什么不是"每次查完就卸"：冷加载实测 **0.35 s**，每条 MCP 查询都付一次，
3.4 的「查询嵌入 ≤ 150 ms」直接不可能达标。
为什么不是"一直常驻"：Air 只有 16 GiB，模型常驻约 0.6–0.7 GiB footprint，
而 MCP 查询是阵发的（Agent 问几句就走）。

两个事件（`jobs` 里的运行时事件，`brosis-store events` 能看）：
`embedder_loaded`（加载耗时、峰值 footprint、cacheLimit、热状态）、
`embedder_unloaded`（原因、GPU 缓冲池前后、footprint 前后）。

### 15.3 零模型调用的三种情况

「模型未装 / 开关关 / 锁定时零模型调用」是**结构性**保证，不是靠 if 堆出来的：

| 情况 | 谁挡下的 | 实测证据 |
|---|---|---|
| `retrieval.vectorsEnabled` 关（默认） | core 的四道门第一道，连嵌入器都不问 | 整个服务端进程 peak footprint **11.08 MiB**（模型一次都没加载） |
| 模型没装 | 嵌入器返回 nil（0.023 ms） | 服务端 `loads = 0`、peak **17.00 MiB**，`search` 照常返回 5 条 FTS 命中 |
| 库锁着 / 采集暂停 | `MCPGate` 根本不把调用交给 `StoreMCPService`（3.5） | 自检那一条：`locked=locked paused=paused`，嵌入器调用次数不变 |
| 查询带 `app:` / `host:` 等字段前缀 | core 第三道门（这类查询本来就不走向量通道） | 60 题里 19 题走这条，`queryEmbed.source = field_prefix` |

### 15.4 实测（M4 Air，1 个月合成库 46,545 块）

| 项 | 数 |
|---|---|
| 首次加载（`embedder_loaded`） | **0.366 s**，加载后 peak footprint **732.0 MiB** |
| 查询嵌入**热**延迟 | p50 **19.4 ms** / p95 **26.1 ms**（47 题）、p50 17.4 / p95 34.5（60 题）；目标 ≤ 150 ms |
| 首次查询（含加载） | 403 ms（那一次就是冷加载） |
| 服务端进程 peak footprint | **850.4 MiB**（含 SQLCipher 页缓存） |
| 卸载（`embedder_unloaded`） | GPU 缓冲池 25.9 → **0 MiB**，footprint 850.4 → 824.3 MiB |
| 经 MCP 的一次 `search` 端到端（客户端墙钟） | p50 **84.3 ms** / p95 92.7 ms |

数字出处：`tools/bench/results/m2_d_vectors_mcp_2026-09-08.md`。

### 15.5 「现在开始建索引（连续跑到完成或取消）」

D8 的第三个条件：首次全量建索引在 Air 上要按小时计（c 批实测 1 小时 32 分），
塞不进 10 分钟的日均 GPU 预算。所以面板上多一个一次性动作，
与夜间增量共用同一套判定输入，**只有三处不一样**（自检里 12 条对照用例逐条钉住）：

| 门 | 夜间增量 | 整晚一次性 | 理由 |
|---|---|---|---|
| 空闲 ≥ 5 分钟 | 要 | **不要** | 用户自己按的按钮，他知道机器要忙一夜；等空闲会让"睡前点一下"变成永远等不到 |
| 日均 GPU 预算 600 s | 要 | **不作为门**，单独记一本账 | 一夜就是几小时 GPU；单独记账才不会吞掉夜间增量的预算 |
| 「夜间自动建索引」开关 | 要 | 不看 | 这个动作本身就是显式的用户动作 |
| **接电** | 要 | **要**（拔电 → 暂停，插回来继续） | 一夜的 GPU 活拿电池跑必然跑不完 |
| 热状态 | `nominal` 才跑 | fair **暂停**、serious / critical **停止** | 无风扇 Air 持续负载 2 分 10 秒就转 fair（D27），要求 nominal 等于永远跑不动 |
| 锁定 / 暂停 | 停 | **停**（不放开） | 库关了就没得跑；锁屏按停处理，宁可保守 |

进度（`OvernightProgress`，纯函数）写进事件：`overnight_index_started` /
`_progress`（已嵌入 / 剩余 / 总数、块每秒、预计剩余秒、GPU 秒、热状态）/
`_paused`（原因）/ `_finished`（停因、总量、GPU 秒、今日整晚累计、峰值 footprint）。
每跑 60 s 回来重新问一次门控，段内每批也问一次，所以拔电 / 转烫 / 锁屏最多多跑一批（16 块 ≈ 2 s）。

### 15.6 `brosis-embed serve-search`：没有 GUI 也能量"经 MCP 的数字"

产品路径上算查询向量的是 brosis.app 里的 IPC 服务端，而 `brosis-store serve` 在 core 里
（零 mlx 依赖）注入不了嵌入器。屏幕锁着不能起 GUI 时，用这个子命令：
**同一份 `MLXQueryEmbedder` + 同一个 `StoreMCPService` + 同一个 `MCPGate` + 同一个 `IPCServer`**，
差别只有三处，都写在子命令的注释里：`FileKeyProvider` 代替钥匙串、锁定相位写死 `unlocked`、
可以 `--skip-codesign` 跳过对端签名校验（`swift build` 出来的 `brosis-mcp` 没有 Developer ID）。

```sh
"$APP/Contents/MacOS/brosis-embed" serve-search --dir <数据目录> --key-file <密钥> \
    --models-dir <模型目录> --socket <路径>/mcp.sock --tz UTC --rate 100000 \
    --skip-codesign --seconds 600 --out serve.json
# 另一个终端：真的 brosis-mcp 作客户端
"$APP/Contents/MacOS/brosis-mcp" admin grant add --client x --socket <路径>/mcp.sock
```

**产品路径没有这个开关**：`app/Sources/brosis/IPCService.swift` 里
`peerPolicy` 写死 `.requireSameTeam`，不读任何环境变量。

E2 一致性的完整跑法见 `tools/eval/d8_mcp_compare.py`（结果文件第 4 节）。

---

## 16. 加密导出 / 导入（3.8 / D7，M2 d 批 / T16）

计划 3.8「加密导出另有独立口令；删除不能覆盖已导出的副本，需要在 UI 里如实提示」
与 D7「满后最旧先删且删前通知并可先加密导出」的界面那一半。
格式、加密与落库全在 core（`core/README.md` 的「加密导出与导入」一章），这里只讲接法与界面。

### 16.1 两个新文件 + `AppDelegate.swift` 的三行接线

| 文件 | 干什么 |
|---|---|
| `ExportWindow.swift` | `ExportController`（@MainActor；后台串行队列跑导出、进度回主线程、配额通知联动）+ `ExportWindowController`（AppKit 窗口） |
| `ExportSelfCheck.swift` | 临时库往返冒烟；`SelfCheck.swift` 里只加了一行 `failures += ExportSelfCheck.run()` |

**已经接上的两处**（写这一节时留给主会话，现已在 `AppDelegate.swift` 里）：

```swift
// ① applicationDidFinishLaunching(_:) 里，recorder 建好之后：
let exportController = ExportController()
exportController.install(recorder: recorder)
self.exportController = exportController

// ② 菜单里加一项：
let exportItem = NSMenuItem(title: "加密导出…", action: #selector(openExport), keyEquivalent: "")
@objc private func openExport() { exportController?.presentWindow() }
```

`install` 只存一个 `weak var recorder`，不接管任何现有回调，所以这两处不影响现有行为。

**③ 遗留：app 内还没有配额过期的调度器。** 现在 app 里**一个 `store.expire()` 调用点都没有**——
配额过期只有命令行的 `brosis-store expire` 与 `brosis-store maintenance --expire`。
将来在 app 里接上定时的配额检查时，那一处要调 `exportController?.expireWithNotice()`
而**不是** `try store.expire()`：没确认过通知时它**不删**，而是把窗口弹出来停在
"先加密导出"上（3.8「删前通知」/ D7）。这一轮不自己发明调度器，
所以 `expireWithNotice()` 目前只有自检覆盖（16.4 第 10 项）。

### 16.2 窗口上有什么

顶部一段**如实提示**（3.8 的两条要求都在这里），然后是配额通知区、目标目录、范围、
应用白名单、口令两次输入 + 强度提示、开始按钮、进度、结果。

四句提示是写死的文案，不随构建变：

1. 口令是**独立**的：与登录密码、数据库密钥、跨设备同步的配对口令都无关，也不会存在任何地方——
   **丢了就再也打不开这份归档，没有找回通道**；
2. 归档写一次就不再改动：**以后在 app 里删掉这些记录，不会影响已经导出的副本**；
   要让归档也消失，只能自己去把归档目录删掉；
3. 导出的正文就是库里那一份——入库前已经脱敏，归档不做二次脱敏、也不还原；
4. 不含 MCP 访问审计、采集质量遥测与同步密钥。

配额那一行来自 `QuotaAction.message`（core 算的）：满了那一档必然包含「先做一次加密导出」
与「不会影响已经导出的副本」。旁边的「我已了解，允许按最旧先删」只在 `level == .full`
且还没确认过时出现，点它调 `acknowledgeQuotaAction(archiveID:)`——
如果这一轮已经导出成功，会把归档 id 一起记进去（"用户确认时确实先导出了"）。

**口令的处理**：只在 `startExport` 这一次调用里存在；点了开始就立刻把两个输入框清空，
关窗口时再清一次；不写 `UserDefaults`、不进日志、不进事件、不进任何错误消息。

### 16.3 UserDefaults 键

| 键 | 含义 |
|---|---|
| `export.lastDirectory` | 上次选的**父目录**（不是归档本身），下次打开保存面板时定位到它 |
| `export.lastRangeDays` | 预留（当前界面只有三档预设：全部 / 最近 30 天 / 最近 90 天） |

归档默认名 `brosis-export-<yyyyMMdd-HHmm>.brosisexport`——**不含主机名与用户名**。

### 16.4 自检（`--self-check` 的第 11 组，10 项）

两个临时数据目录 + 两个 `Store`（同一个 device_id，模拟"恢复到一台新机器"），
`InMemoryKeyProvider`，不碰钥匙串、不弹授权：

1. 入库前脱敏生效（库里没有脱敏前的密钥）；
2. 弱口令被拒，**且一个字节都没写出去**；
3. 导出成功（条数 / 块数 / 字节数）；
4. 清单不需要口令就能读，且不含密钥材料；
5. 归档目录里搜不到正文、脱敏前明文与口令（**带阳性对照**：`archive_id` 必须搜得到）；
6. 口令错误 → 明确报口令错，一块都没读；
7. 往返一致：恢复模式、id 原样、正文逐字节相同 + 一致性检查全过；
8. 同一份归档再导一次不翻倍；
9. **源库删掉之后：库里查不到，归档仍然完整**（3.8 的如实提示就是这一条）；
10. 篡改一字节 → 校验失败并拒绝；配额满时通知带「先加密导出」且没确认前不删、确认后才删。

### 16.5 本轮不做，界面上也没有入口

- **从窗口里导入归档**。导入是恢复动作，产品路径要先想清楚"往哪个库恢复、恢复到一半怎么办"；
  数据层已经做好（`Store.importArchive`），命令行入口是 `brosis-store import`。
- **归档的自动轮转 / 清理**。归档在用户自己选的位置，app 不去动它——这正是"删除不影响已导出副本"的另一面。
- **自定义起止时刻**。当前只有三档预设；`ExportRequest` 本身支持任意 `[start, end)`，
  命令行 `--start` / `--end` 已经能用。


---

## 17. 全局热键（3.5 / 4.2 / 4.3.2 T18，M2 d 批）

> **2026-09-08：Focus（专注模式）联动整条删除。** 原来这一节还写着一个只读
> `~/Library/DoNotDisturb/DB/` 两个 JSON 的探针（`FocusProbe.swift`）、一份
> `focus.pauseModes` 暂停名单，以及菜单里那个「打开完全磁盘访问设置」的入口。
> 那两个文件受 TCC 的「完全磁盘访问」保护，本机恒为 `unavailable`，功能从没真跑起来过；
> 用户决定不要，于是**代码、暂停原因、状态机触发、自检三组、菜单入口一起删干净**
> （不是像夜间叙述那样留休眠代码）。删掉的东西：`FocusProbe.swift`、
> `FocusHotKeySelfCheck.swift` 里的前三组、`PauseReason.focus`、
> `LockTrigger.focusPauseStarted / .focusPauseEnded` 与它们的转移用例、
> `AppDelegate` 的 `FocusMonitor` 接线与 `openFullDiskAccessSettings()`、
> 三类 `focus_*` 运行期事件。要恢复只能从 git 历史里捞（`f975ab2` 之前）。

### 17.1 两个新文件 + `AppDelegate.swift` 的接线

| 文件 | 干什么 |
|---|---|
| `Sources/brosis/HotKeys.swift` | `RegisterEventHotKey` 的登记处、键位字符串解析（纯函数 + 向量） |
| `Sources/brosis/HotKeySelfCheck.swift` | 自检第 12 组（4 项） |
| `Sources/brosis/HardConstraintSelfCheck.swift` | 自检第 13 组（3 项，补 2.2 硬约束里能自动化的部分） |

改到的现成文件只有 `SelfCheck.swift`（两行 `failures += …`）。

接线在 `AppDelegate.applicationDidFinishLaunching(_:)` 里、`lock` 建好之后：

```swift
// 全局热键：处理器只发通知，动作走既有的 togglePause / lockNow
_ = HotKeys.shared.install(recorder: recorder,
                           onPause: { [weak lock] in lock?.togglePause() },
                           onLock:  { [weak lock] in lock?.lockNow() })
```

菜单里一行状态显示（`menuWillOpen` 的 `refreshMenu()` 里，权限那两行下面）：

```swift
menu.addItem(disabledItem(HotKeys.shared.menuDescription))
```

`applicationWillTerminate` 里调 `HotKeys.shared.uninstall()`（不调也不会漏到别的进程）。

### 17.2 全局热键

| 动作 | 默认组合 | UserDefaults 键 | 走哪条路 |
|---|---|---|---|
| 暂停 / 继续采集 | `⌃⌥⌘P` | `hotkey.pause` | `LockController.togglePause()`（与菜单同一条） |
| 锁定数据库 | `⌃⌥⌘L` | `hotkey.lock` | `LockController.lockNow()`（与菜单同一条） |

改键：`defaults write com.brosis.app hotkey.lock "ctrl+shift+cmd+L"`。
键位字符串收单词写法（`ctrl+alt+cmd+P`，别名 `command` / `opt` / `option` / `control` / `meta`）
与符号写法（`⌃⌥⌘P`），大小写与空格无所谓；**至少要有一个修饰键**——
不带修饰键的全局热键会把那个键从所有 app 里抢走（实测无修饰键的 `F19` 也能注册成功），
这个陷阱不给用户踩，直接拒绝。

**为什么用 Carbon `RegisterEventHotKey`**：`NSEvent.addGlobalMonitorForEvents` 与 `CGEventTap`
都是"看得见所有按键"的接口，因此要辅助功能权限；一个记录型 app 去申请能读全部击键的通道，
与 2.2 的取向相反。`RegisterEventHotKey` 只登记**一个具体组合**，由 WindowServer 匹配后才回调。

**实测依据**（2026-09-08，屏幕锁定态）：把测试进程用 `responsibility_spawnattrs_setdisclaim`
断开与终端的 TCC 归属，使 `AXIsProcessTrusted() == false`，`RegisterEventHotKey` 仍返回
`noErr` 并拿到 `EventHotKeyRef`。**结论：全局热键不需要辅助功能权限。**

三条如实说明：

1. **注册成功 ≠ 按键一定到得了。** 组合被系统快捷键（如 ⌘Space）或别的进程占用时，
   `RegisterEventHotKey` 照样返回 `noErr`，按键只是永远不来。Carbon 只在**本进程内**
   重复登记同一组合时报 `eventHotKeyExistsErr (-9878)`。所以菜单里写的是
   "注册成功 / 失败 + 组合"，不敢写"热键可用"。
2. **注册失败会记事件并在菜单显示**：`hotkey_registered` / `hotkey_register_failed`
   （带 `action`、`combo`、`OSStatus`、原因），菜单那一行直接把失败原因摊开。
   按下时记 `hotkey_fired`。
3. **键盘布局无关的是键码，不是字符。** Dvorak / 法语布局下 `kVK_ANSI_P` 还是那个物理键位，
   但键帽上的字母会变。

### 17.3 自检（`--self-check` 的第 12 / 13 组，7 项）

第 12 组（`HotKeySelfCheck`，4 项）：

1. **热键注册 · 暂停**、2. **热键注册 · 锁定**——**真的调 `RegisterEventHotKey`**，
   把 `OSStatus`、`registered`、原因、`UnregisterEventHotKey` 的返回值全打出来；
   判定的是**一致性**（`registered == (status == noErr)`）与**注册成功的必须能注销**。
3. **热键注销干净**——**装 → 卸 → 再装 → 再卸，两轮 `OSStatus` 必须相同**。
   只看 `UnregisterEventHotKey` 的返回值是不够的（把它换成常量 `noErr` 也全绿）；
   真漏注销时 Carbon 会在第二轮回 `eventHotKeyExistsErr (-9878)`。
   自检因此不会给正在运行的那个 brosis 留下一个抢着的组合。
4. **键位解析 14 条**（单词 / 符号 / 别名 / 重复修饰键 / 三种拒绝）。

第 13 组（`HardConstraintSelfCheck`，3 项）是做 2.2 对照表时补的：

1. **硬约束 6**：`Info.plist` 不含 `NSMicrophoneUsageDescription` /
   `NSCameraUsageDescription` / `NSSpeechRecognitionUsageDescription`——
   没有这几个键的 app 在 macOS 上**拿不到**麦克风 / 摄像头 TCC，
   这比"代码里没写 AVAudioEngine"更可核对。
2. **硬约束 5 / 8**：读本进程主二进制的 `LC_LOAD_DYLIB` 一族（等价 `otool -L`），
   断言直接链接的库全在 `/System/Library/Frameworks/` `/usr/lib/` `@rpath/` 里，
   没有私有框架、没有 `/opt` 或 `/usr/local`、没有 Python。
3. **硬约束 6**：`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` 都是 `false`、
   `SUFeedURL` 是 https——更新检查也是一次出网，默认必须关。

### 17.4 本轮不做

- **界面**：热键只有 `UserDefaults`，没有设置面板。产品化时进「设置」窗口。
- **按下热键的端到端验证**：不能在无人值守的会话里模拟按键（要么用 `CGEvent` 合成——
  那正是我们不想申请的那类权限；要么真人按）。留给你在 GUI 里试。
