# T6 · brosis.app 采集骨架：构建与签名结果

- 日期：2026-09-06
- 对应：`docs/实施计划.md` 4.1 的 **E4「TCC 打包与采集骨架」**、3.1 组件表、3.3 采集策略；`docs/可行性调研报告.md` 3.3 打包要求、3.4 采集策略；评审 **F5**（状态分离、门控不丢证据）
- 代码：`app/`，说明见 `app/README.md`
- 机器：M4 Max / 128 GB，macOS 26.6.2（25G83）；Xcode 26.6（Build 17F113），Swift 6.3.3，macOS SDK 26.5
- 本次**没有运行 GUI app**，因此没有触发任何 TCC 授权弹窗。只跑了构建脚本、无 TCC 的 `--self-check`，
  以及两个不碰 TCC 的独立小程序（AX 超时探针、退出模式复现），见第 9 节。
- **第二轮**（验收 fail 后的修复轮）。第一轮记了 1 个 major（AX 0.5 s 超时覆盖面与文档陈述不符）+ 3 个 minor，
  修复内容与实测证据在第 9 节；本节以下的所有数字与输出都是修复后重跑的。

## 1. 结论

| 项 | 结果 |
|---|---|
| SwiftPM 目标能在 Swift 6 语言模式 + macOS 26.0 平台下编译 | 通过，0 error / 0 warning |
| `build_app.sh` 能组装出 `.app`（MacOS / Info.plist / Resources / Library/LaunchAgents 四件齐） | 通过 |
| Developer ID 签名 + hardened runtime + 非沙盒 entitlements | 通过，`flags=0x10000(runtime)`，`TeamIdentifier=<TEAMID>` |
| `codesign --verify --deep --strict` | 通过（`valid on disk` + `satisfies its Designated Requirement`） |
| Info.plist 六个必备键（含三个中文 usage string） | 齐全 |
| 不出现已废弃的旧版窗口截图 API（`CGWindowList*` 家族） | 0 处。**约束的范围是 `app/` 目录与签名后的二进制**：`grep -rn CGWindowList app/` 0 处，`nm -u` 与 `strings` 在签名后的可执行文件里也各 0 处。本结果文件与验收清单里为了说清楚约束本身，会写出这个符号名，那是**描述**不是引用 |
| 无 GUI 自检 `--self-check` | **13 项**全通过，退出码 0；写独立的 `m0-selfcheck.sqlite`，不碰 GUI 库 |
| AX 消息超时 0.5 s 的作用域 | **进程级**（对 `AXUIElementCreateSystemWide()` 设置一次），覆盖 BFS 里的子元素 |
| 公证 | **未做**（T6 范围外），`spctl` 评估为 `rejected: Unnotarized Developer ID`，符合预期 |

**E4 打包路线判定：可行。** 签名 `.app` + 固定 bundle id + LSUIElement + LaunchAgent plist 这条路在本机跑通了，
D13（打包路线）在「构建与签名」这一半没有阻塞。剩下一半——首次授权流程、系统设置可见性、
**月度再授权到期时流的行为与恢复**——必须真人点弹窗，见第 6 节 blockers。

## 2. 关键数字（含口径）

| 指标 | 数值 | 口径 |
|---|---|---|
| Swift 源码 | **1,813 行**（10 个 .swift 文件） | `wc -l app/Sources/brosis/*.swift`；第一轮 1,715 行，本轮修复 +98 行。**2026-09-07 的 T9 minor 清理后为 1,898 行**，见文末修订记录 |
| 全新（清空 scratch）构建 + 签名 + 验证总耗时 | **6.28 s** 墙钟 | `/usr/bin/time -p build_app.sh`；user 5.27 s / sys 0.61 s；其中 `swift build` 4.71 s |
| 增量重建（改 1–2 个文件） | 1.7–1.9 s | `swift build` 自报（改一个文件后重编，三次分别 1.72 / 1.94 / 2.04 s） |
| 可执行文件 | **343,968 字节**（约 336 KiB），arm64 thin，签名后 | 签名前 326,808 字节；签名增加 17,160 字节 |
| `.app` 总占用 | **356 KiB** | `du -sk`（含 `_CodeSignature`、Info.plist、exclusions.txt、LaunchAgent plist） |
| 签名块大小 | 9,111 字节 | `codesign -dv` 的 `Signature size`（每次重签会差个位数字节） |
| Info.plist 条目 | 17 项 | `codesign -dv` 的 `Info.plist entries` |
| 密封资源 | rules 13 / files 2 | `Sealed Resources version=2` |
| 构建目录 | `~/Library/Caches/brosis-build/app/` | `swift build --scratch-path`；**项目目录内 0 个构建产物**（无 `.build` / `.swiftpm` / `Package.resolved` / `*.o`） |
| 自检库（1 条观察 + 2 条 AX 统计 + 3 条帧统计 + 1 条事件，跑几次都一样） | m0-selfcheck.sqlite 49,152 字节 + `-shm` 32,768 字节 + `-wal` 0 字节 | `ls -l ~/Library/Application Support/brosis-m0/`；WAL 模式下 shm 是固定开销，不代表数据量 |
| GUI 测试库 `m0.sqlite` | **本轮不存在**（尚未运行 GUI） | 自检已改成写独立库，不再创建/污染它 |
| `AXFocusedUIElementChanged` 节流窗口 | 2.0 s | `EventSkeleton.elementScanThrottle`；窗口/标题/应用切换不节流 |
| dHash 区分度（自检合成图，浅底深条 vs 深底浅条） | 汉明距离 **44 bit / 64 bit** | 门控阈值是 ≤ 6 bit；同一图像重复计算距离 0 bit |
| 采集排除清单 | 8 个 bundle id | 来源 `Contents/Resources/exclusions.txt`（自检确认走的是 bundle 资源而非代码默认值） |

## 3. 构建输出摘录

```
==> 0. 确认签名身份
  3) B5C720D1F65A4C646D7E2F98A2542090ACAC7676 "Developer ID Application: <Company> (<TEAMID>)"

==> 1. swift build（release，scratch=~/Library/Caches/brosis-build/app）
Building for production...
[0/4] Write sources
[1/4] Write swift-version--58304C5D6DBC2206.txt
[3/5] Compiling brosis AXSupport.swift
[4/5] Linking brosis
Build complete! (4.71s)
二进制：~/Library/Caches/brosis-build/app/arm64-apple-macosx/release/brosis（326808 字节）

==> 2. 组装 ~/Library/Caches/brosis-build/app/brosis.app
Info.plist 六个必备键齐全
  brosis.app/Contents/MacOS/brosis
  brosis.app/Contents/Resources/exclusions.txt
  brosis.app/Contents/Library/LaunchAgents/com.brosis.agent.plist
  brosis.app/Contents/Info.plist
  brosis.app/Contents/PkgInfo
```

`plutil -lint` 对 Info.plist 与 LaunchAgent plist 均无输出（合法）；六个必备键由 `PlistBuddy` 逐个 `Print` 验证：
`CFBundleIdentifier`（`com.brosis.app`）、`CFBundleExecutable`、`LSUIElement`（true）、
`NSScreenCaptureUsageDescription`、`NSAccessibilityUsageDescription`、`NSAppleEventsUsageDescription`（三条均为中文）。

## 4. 签名与验证输出摘录

```
==> 3. Developer ID 签名 + hardened runtime
~/Library/Caches/brosis-build/app/brosis.app: replacing existing signature

==> 4. codesign --verify --deep --strict
~/Library/Caches/brosis-build/app/brosis.app: valid on disk
~/Library/Caches/brosis-build/app/brosis.app: satisfies its Designated Requirement

==> 5. codesign -dv --verbose=4
Executable=…/brosis.app/Contents/MacOS/brosis
Identifier=com.brosis.app
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=986 flags=0x10000(runtime) hashes=20+7 location=embedded
Hash type=sha256 size=32
CDHash=885f0cc58aa3f610737e8b5b934486f75272d5c5
Signature size=9111
Authority=Developer ID Application: <Company> (<TEAMID>)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 6, 2026 at 23:16:39
Info.plist entries=17
TeamIdentifier=<TEAMID>
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=2
Internal requirements count=1 size=176
```

要点：`flags=0x10000(runtime)` = hardened runtime 已开；三级 Authority 链完整到 Apple Root CA；
`Timestamp=` 说明用的是 Apple 安全时间戳（离线时可用 `TIMESTAMP=none` 绕过，但那样签的包不能公证）。
`CDHash` 每次重建都会变，TCC 认的是 bundle id + Designated Requirement（含 Team ID），
所以**重签同一份代码不会作废授权，换团队证书会**（报告 3.3）。

Entitlements（`codesign -d --entitlements -`）：

```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
```

不沙盒是硬要求：沙盒应用拿不到辅助功能权限（报告 3.3）。`automation.apple-events` 是 hardened runtime 下
发 Apple 事件的前置条件，与 `NSAppleEventsUsageDescription` 配套；M0 还没真去发事件。

Gatekeeper（预期内的失败）：

```
==> 7. spctl 评估（未公证，预期 rejected）
…/brosis.app: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: <Company> (<TEAMID>)
```

## 5. 无 TCC 自检输出

`SelfCheck.swift` 不调用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` /
`AXIsProcessTrusted(WithOptions)` / `SCShareableContent` / 任何 `AXUIElement*`，也不创建 `NSApplication`，
所以可以在终端里安全执行，不会把 TCC 授权记到终端头上。

```
$ ~/Library/Caches/brosis-build/app/brosis.app/Contents/MacOS/brosis --self-check
brosis 0.1.0 自检（不触发任何 TCC 授权）
[PASS] 自检库路径：~/Library/Application Support/brosis-m0/m0-selfcheck.sqlite
[PASS] 自检库与 GUI 测试库分离：GUI 库 m0.sqlite 未被自检写入
[PASS] SQLite 版本：3.51.0
[PASS] journal_mode = wal：wal
[PASS] foreign_keys = ON：1
[PASS] schema 表数量 = 5：实得 5
[PASS] 写入 observations：rowid=1
[PASS] 写入 ax_texts：实得 2
[PASS] 空 AX 记为 unavailable：实得 1
[PASS] 同一图像 dHash 稳定：aaa9a0b382cf8693
[PASS] 不同图像 dHash 汉明距离 > 6：距离 44 bit（门控阈值 6）
[PASS] 写入 frame_stats：累计 3 行
[PASS] 排除清单已加载：8 个 bundle id，来源=Contents/Resources/exclusions.txt
自检库 observations 由 0 增至 1 行；库文件 4096 字节
GUI 测试库 ~/Library/Application Support/brosis-m0/m0.sqlite：尚未创建
自检通过    （退出码 0）
```

（末行「4096 字节」是 checkpoint 之前的主文件大小；进程退出后落盘为 49,152 字节。）

**可重复性**：连跑三次 `--self-check`，退出码都是 0，自检库始终是
`observations=1 / ax_texts=2 / frame_stats=3 / runtime_events=1`（每次运行前先删旧库重建），
且 `~/Library/Application Support/brosis-m0/m0.sqlite` 三次之后仍然不存在——
自检不再往 GUI 库里掺合成行（第一轮的 minor 之一）。

写入的三张表（`sqlite3` CLI 3.51.0 读回）：

```
observations: id=1 app=com.brosis.selfcheck trigger=self_check source_state=ok display_id=1
ax_texts:     AXTextArea 1234 字符 is_empty=0 completeness=partial
              AXWebArea     0 字符 is_empty=1 completeness=unavailable
frame_stats:  complete 640x400 dhash=aaa9a0b382cf8693 hamming=0  dirty=0 面积比 0.0  gated=1
              complete 640x400 dhash=87969eccbcb2faee hamming=44 dirty=3 面积比 0.31 gated=0
              idle_batch                                          idle_count=60
```

`gated=1` 表示「不触发内容检查」，那一帧的统计**仍然入库**——这是评审 F5 的要求：
门控只用于决定要不要去读正文，不用于丢弃证据。

## 6. 尚未验证 / 需要你操作（blockers）

| # | 事项 | 为什么 Claude 做不了 | 你要做什么 |
|---|---|---|---|
| B1 | 首次两次授权（辅助功能 + 屏幕录制） | TCC 弹窗只接受真人点击 | 把 `.app` ditto 到 `/Applications`，去 quarantine，Finder 双击启动，菜单栏 →「请求权限…」，两次都在系统设置里打开 |
| B2 | 必须从 Finder 启动，不能从终端 | 终端启动会把授权记到 Terminal（Apple DTS：shell 脚本与 TCC 不兼容） | 同上 |
| B3 | 未公证，Gatekeeper 拦截 | 公证是 E9 的范围，且需要 App Store Connect 凭据 | `xattr -dr com.apple.quarantine /Applications/brosis.app`，或右键「打开」 |
| B4 | 屏幕录制**月度再授权**行为 | 需要挂 3–5 周等真实提示 | 先做「主动撤销 → 观察 `capture_did_stop_with_error` → 重新打开 → 观察 `capture_started`」的快速验证；再记录基线时间等真实提示。步骤见 `app/README.md` 第 6 节 |
| B5 | SMAppService 登录项批准 | `requiresApproval` 需要在系统设置里手动打开 | 菜单栏 →「注册为登录项」→ 系统设置 → 通用 → 登录项与扩展；验证命令见 `app/README.md` 第 7 节 |
| B6 | 系统设置里的可见性 / 路径型 TCC（报告 §11.2 第 9 条） | 需要看 GUI | 授权后确认「隐私与安全性」两个面板里各只有一条 brosis，且移动 app 后不会分裂成多条 |
| B7 | AX 覆盖率、OCR 回退比例、飞书/微信适配 | 属于 E5，不在 T6 | 按计划 4.1 的 E5 单独跑 |
| B8 | 剪贴板 `accessBehavior` 是否弹窗（报告 §11.2 第 2 条） | 需要运行并观察 | v1 不依赖剪贴板，可延后 |
| B9 | AX 0.5 s 超时的**端到端计时**（挂死的目标应用是否真的 0.5 s 返回） | 需要一个能人为卡住的目标应用 + 授权后运行 | 归 E5：拿断点挂起的测试 app 量 `AXUIElementCopyAttributeValue` 返回耗时。本轮只验到 SDK 文档 + 调用返回 success，见第 9.1 节 |

## 7. 复现命令

```bash
APP="<项目目录>/app"
rm -rf ~/Library/Caches/brosis-build/app        # 全新构建
/usr/bin/time -p "$APP/build_app.sh"            # 构建 + 签名 + 验证（约 6.3 s）
~/Library/Caches/brosis-build/app/brosis.app/Contents/MacOS/brosis --self-check   # 无 TCC 自检，期望退出码 0
grep -rn "CGWindowList" "$APP" | wc -l          # 期望 0
ls -la ~/Library/Application\ Support/brosis-m0/                                  # 期望只有 m0-selfcheck.sqlite*
```

## 8. 与 E3 原型 schema 的差异（M1 必须收敛）

`tools/proto/schema.sql`（E3 按计划 3.2 建的 v1 schema）和本骨架的 `Store.swift` 是两套表，
故意不一样：E3 验证的是**正确性与删除级联**，T6 验证的是**打包与采集通道**，M0 阶段各跑各的。
但 M1 只能有一套，下面是需要收敛的九点：

| 维度 | T6 骨架（`Store.swift`） | E3 原型（`tools/proto/schema.sql`） | M1 取向 |
|---|---|---|---|
| 时间戳 | `ts REAL` Unix 秒 | `ts INTEGER` Unix 毫秒 | 取毫秒整数 |
| 主键 | `id INTEGER PRIMARY KEY` | `(device_id, id)` 复合主键（D17） | 取复合主键 |
| 应用 / 窗口 / URL / 文件 | 直接存文本列 `app` / `title` / `url` / `document` | 规范化到 `apps` / `windows` / `urls` / `files` 四张表 | 取规范化 |
| `capture_method` | 无（M0 只有 AX，没有 OCR） | `ax / ocr / adapter / mixed` | 补上 |
| `completeness` | 占位：非空=partial、空=unavailable | 同枚举，但由适配规则判定 | 取 E5 的判定规则 |
| `visible_range` | 无 | JSON，记视口内实际显示范围（F5） | 补上 |
| `frame_hash` | 在独立的 `frame_stats.dhash` | 在 `observations.frame_hash` | 观察记录带一份，帧统计表保留明细 |
| `deleted_at` / 删除级联 | 无（M0 不删） | 有，且有 `deletions` 审计表 | 取 E3 |
| `trigger` 取值 | `app_activated` / `focused_window_changed` / `title_changed` / … | `app_switch` / `window_change` / `url_change` / `ax_notification` / `frame_dirty` / `timer` / `manual` | 取 E3 的取值集合，把骨架的细分映射进去 |

骨架里 `frame_stats`（dHash、汉明距离、dirtyRects 面积比、`gated`、`idle_count`）在 E3 schema 里没有对应表。
它是 M0 用来校准门控阈值的观测数据，M1 可以降频保留，也可以合并进采样审计表。


## 9. 第一轮验收问题与本轮修复（含实测证据）

第一轮验收 **fail**：1 个 major + 3 个 minor。四条全部改完并重跑验证，代码净增 **98 行（1,715 → 1,813）**，与第 2 节的行数表一致。

| # | 级别 | 问题 | 改法 | 证据 |
|---|---|---|---|---|
| 1 | **major** | AX 0.5 s 超时只设在应用元素和焦点窗口上，BFS 里 `kAXChildren` 拿到的子元素仍用系统默认（约 6 s）；README / 上一轮报告却写「所有元素都设了 0.5 s」——既没落实规格意图，陈述也不属实 | `AppDelegate.applicationDidFinishLaunching` 在任何 AX 读取之前调用一次 `AX.installGlobalMessagingTimeout()`，即对 `AXUIElementCreateSystemWide()` 设 0.5 s（**进程级**）；应用元素/窗口上的两次保留为冗余防守。README 第 8 节与本文改成实际行为的表述 | 见下面 9.1 |
| 2 | minor | `applicationWillTerminate` 用 `Task { }`（继承 MainActor）+ 主线程 `semaphore.wait`，任务永远起不来，白等 2 s 且 `stop()` 没执行 | 换成 `Task.detached`（`CaptureController.stop` 是 nonisolated async） | 见下面 9.2 |
| 3 | minor | `--self-check` 把合成行写进 GUI 用的 `m0.sqlite`，每跑一次就给 E4 的真实数据掺一批 | 自检改写独立库 `m0-selfcheck.sqlite`，每次运行前删旧库重建；新增第 13 项检查「自检库与 GUI 测试库分离」 | 见第 5 节的可重复性段落 |
| 4 | minor | `AXFocusedUIElementChanged` 每次触发都做 ≤1500 节点的正文 BFS + ≤400 节点的 URL 搜索，编辑器/浏览器里会刷屏并占满主线程 | 只对这一个通知做 2 s 节流（`EventSkeleton.elementScanThrottle`），丢弃数累计写 `runtime_events.ax_element_notifications_throttled`；窗口/标题/应用切换不节流 | 代码见 `EventSkeleton.handleAXNotification`；节流不影响「换窗口/换标题/换应用」的即时记录 |

被污染的旧 `m0.sqlite`（里面只有两轮自检的合成行，`app=com.brosis.selfcheck`）已移出
`~/Library/Application Support/brosis-m0/`，E4 首次真实运行时会从零重建。

### 9.1 AX 超时作用域：SDK 依据 + API 实测

SDK 头文件 `$(xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks/ApplicationServices.framework/
Frameworks/HIServices.framework/Headers/AXUIElement.h` 第 387–393 行对 `AXUIElementSetMessagingTimeout` 写的是：
把 system-wide 对象传进去才是「globally for this process」，传别的对象「only for that object」。
所以只对应用元素和焦点窗口设置，覆盖不到遍历中新拿到的子元素。

用一个**不碰任何 TCC 的**独立小程序（`swiftc` 直接编译，只调 `AXUIElementCreateSystemWide` /
`AXUIElementCreateApplication` / `AXUIElementSetMessagingTimeout`，绝不调
`AXIsProcessTrusted(WithOptions)` 或任何屏幕录制 API）实测：

```
system-wide 设 0.5 s  -> AXError=0 (success)
system-wide 设 -1 s   -> AXError=-25201 (期望 -25201 kAXErrorIllegalArgument)
单个应用元素设 0.5 s -> AXError=0（按 SDK 头文件：只对该元素生效，不是全局）
system-wide 设 0 s    -> AXError=0（按头文件：恢复系统默认全局超时）
```

第二行说明这个调用确实在起作用（会校验参数），不是空转；在**没有辅助功能授权**的当前状态下
也返回 `success`，说明它不依赖 TCC、也不会弹窗，放在启动路径上是安全的。
app 里这次调用的 `AXError` 会写进 `runtime_events.kind='ax_global_timeout_installed'`，
授权后第一次运行就能核对：

```bash
sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
  "SELECT datetime(ts,'unixepoch','localtime'), kind, detail FROM runtime_events
   WHERE kind IN ('ax_global_timeout_installed','event_skeleton_started');"
```

**没有做的验证**：AX 没有「读回当前超时」的 API，也没有现成的挂死应用，所以「0.5 s 到点就返回」
这件事本轮只能靠 SDK 文档 + 调用成功来支撑，没有端到端计时证据。真正的验证要等 E5：
拿一个能人为卡住的目标应用（例如断点挂起的测试 app），量 `AXUIElementCopyAttributeValue` 的返回耗时。

### 9.2 退出路径：两种写法的实测对比

同样用独立小程序复现（顶层代码在 Swift 6 下是 `@MainActor`，与 `AppDelegate` 的 `@MainActor`
方法同构；`Worker.stop` 是 nonisolated async，与 `CaptureController.stop` 同构），
超时都设 2 s，`stop()` 内部 sleep 50 ms：

```
旧写法 Task{}        : wait=timedOut 耗时=2.002 s stop 是否执行=否
新写法 Task.detached : wait=signaled 耗时=0.051 s stop 是否执行=是
```

结论与验收官的判断一致：旧写法每次退出白等 2 秒且清理根本没跑（流靠进程退出被系统回收）；
换成 `Task.detached` 后 51 ms 返回，`stop()` 真的执行了。

### 9.3 本轮重跑的验证清单

| 步骤 | 结果 |
|---|---|
| `swift build -c release`（清空 scratch） | Build complete! (4.71s)，**0 error / 0 warning** |
| `build_app.sh` 七步 | 全过，退出码 0，`real 6.28 s` |
| `codesign --verify --deep --strict` | `valid on disk` + `satisfies its Designated Requirement` |
| `codesign -dv --verbose=4` | `flags=0x10000(runtime)`、`Identifier=com.brosis.app`、`TeamIdentifier=<TEAMID>`、`Runtime Version=26.5.0`、Apple 时间戳 |
| Info.plist 六个必备键 | 齐全（`PlistBuddy` 逐个 `Print`） |
| `--version` / `--self-check` | 版本正常；13 项全过，退出码 0；连跑三次结果一致 |
| `grep -rn CGWindowList app/` | 0 处；签名后二进制 `nm -u` / `strings` 各 0 处（约束范围 = `app/` 目录 + 二进制，本文的措辞说明见第 1 节同名行） |
| 项目目录内构建产物 | 0 个（`.build` / `.swiftpm` / `Package.resolved` / `*.o` / `*.app` 均无） |
| 是否运行过 GUI app | **没有**，因此本轮同样零 TCC 弹窗 |

## 12. 修订记录

| 日期 | 改动 | 重跑的验证 |
|---|---|---|
| 2026-09-06 | 首版（第二轮，四条第一轮问题已修） | 见上文各节 |
| 2026-09-07（T9 minor 清理） | ① **锁屏判定改对**：`sessionDidResignActive` / `DidBecomeActive` 不是锁屏通知（只在快速用户切换时触发），改记 `user_switched_away` / `_back`；锁屏改用「前台应用 = `com.apple.loginwindow`」直判 + 分布式通知 `com.apple.screenIsLocked` / `Unlocked` 补充，两路信号用一个标志位去重，启动时用 `CGSessionCopyCurrentDictionary` 现查初始化。② **菜单加 `NSMenuDelegate.menuWillOpen`**：每次展开重新取权限快照，权限补齐且采集流未运行时自动拉起。③ README 第 5 节改成「拨完开关后重新展开一次菜单」，并写明屏幕录制首次授权通常要退出重开 app。④ 本文第 1 / 11 节的 `CGWindowList` 措辞改为写明约束范围。⑤ 第 9 节「净增 95 行」改为 98 行，与第 2 节对齐 | `swift build`（0.86 s，无警告）、`./build_app.sh` 七步全过、`codesign --verify --deep --strict` 通过、`--self-check` 13 项全过退出码 0。**没有运行 GUI**，零 TCC 弹窗 |

T9 之后的实测值：Swift 源码 **1,898 行**（10 个文件）、签名后可执行文件 **362,048 字节（约 353.6 KiB）**、
`.app` 总占用 **376 KiB**（`du -sk`）。`grep -rn CGWindowList app/`、二进制 `nm -u` / `strings` 仍各 0 处。
