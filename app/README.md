# app/ — brosis.app 采集骨架（M0 / 计划 E4）

对应：`docs/实施计划.md` 3.1、3.3、4.1 的 E4；`docs/可行性调研报告.md` 3.3、3.4；评审 F5（状态分离、门控不丢证据）。

**这是 M0 探针，不是 v1 采集端。** 它只验证「打包 + TCC + 事件骨架 + 按需截图」这条路走不走得通（2026-09-07 前是单条 SCStream，改动原因见第 8 节），
写的是**明文测试库**，只允许放合成内容或你明确许可的内容。加密库（SQLCipher）是 E6 的事。

## 1. 边界（先说不做什么）

| 不做 | 原因 |
|---|---|
| 不做 OCR | E8 单独测；骨架阶段只看 AX 覆盖与帧统计 |
| 不保存任何图像 | 帧像素只在内存里算一次 64 bit dHash，随即释放；库里只有哈希与面积比 |
| 不存 AX 正文 | 只记「角色 / 节点数 / 字符数 / 是否为空」，避免明文库里出现真实内容 |
| 不用已废弃的旧版窗口截图 API | macOS 15 起废弃；截图全部走 ScreenCaptureKit（`app/` 全目录搜不到那些旧 API 名字，含本文件） |
| 不申请「输入监控」 | 只用 `CGEventSource` 的计数与空闲秒数，没有键值内容（报告 3.3） |
| 不做公证 | T6 范围外；`spctl` 评估预期为 `rejected: Unnotarized Developer ID` |

## 2. 目录

```
app/
├── Package.swift                     SwiftPM 可执行目标 brosis，Swift 6 语言模式，平台 macOS 26.0
├── build_app.sh                      swift build → 组装 .app → Developer ID 签名 → 验证
├── Sources/brosis/
│   ├── main.swift                    入口；--version / --self-check 不创建 NSApplication
│   ├── BuildInfo.swift               版本、bundle id、trigger / source_state / completeness 枚举
│   ├── AppDelegate.swift             菜单栏状态项、暂停/继续、请求权限、登录项、退出
│   ├── Permissions.swift             TCC 探测与请求；SystemState（空闲、安全输入、锁屏）
│   ├── EventSkeleton.swift           NSWorkspace 通知 + AXObserver + 显示器归属
│   ├── AXSupport.swift               AX 读取（进程级 0.5 s 超时）、AXManualAccessibility、文本统计
│   ├── CaptureController.swift       按需截图（SCScreenshotManager）+ 帧门控 + 排除清单
│   ├── DHash.swift                   9×8 灰度差分哈希（64 bit）
│   ├── Store.swift                   SQLite（系统 libsqlite3）明文测试库
│   └── SelfCheck.swift               无 GUI、无 TCC 的自检（写独立的 m0-selfcheck.sqlite）
├── Support/
│   ├── Info.plist                    LSUIElement=1 + 三个 usage string
│   ├── brosis.entitlements           不沙盒 + apple-events
│   └── com.brosis.agent.plist        SMAppService LaunchAgent
└── Resources/exclusions.txt          采集排除清单（bundle id，一行一个）
```

## 3. 构建

```bash
# 项目在 iCloud Drive，构建产物一律落在 ~/Library/Caches/brosis-build/app/
"<项目目录>/app/build_app.sh"
```

脚本七步：确认签名身份 → `swift build --scratch-path` → 组装 bundle 并 `plutil -lint` + 校验六个必备键 →
`codesign --options runtime --timestamp --entitlements` → `codesign --verify --deep --strict` →
`codesign -dv --verbose=4` → 打印 entitlements → `spctl` 评估。

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CONFIG` | `release` | 传给 `swift build -c` |
| `SCRATCH` | `~/Library/Caches/brosis-build/app` | SwiftPM scratch 与 .app 输出目录 |
| `IDENTITY` | `Developer ID Application: <Company> (<TEAMID>)` | 签名身份 |
| `SKIP_SIGN` | `0` | `1` = 只组装不签名（此时不要用于任何 TCC 测试） |
| `TIMESTAMP` | `yes` | `none` = 离线时跳过 Apple 时间戳服务（这样签的包不能公证） |

只想编译不组装：

```bash
swift build --package-path "…/brosis/app" --scratch-path ~/Library/Caches/brosis-build/app -c release
```

### 3.1 应用图标

`Resources/AppIcon.icns` 由 `Support/icon/make_icon.swift` 生成（只用 CoreGraphics / ImageIO），`Info.plist` 里
`CFBundleIconFile` / `CFBundleIconName` = `AppIcon`，`build_app.sh` 随 `Resources/` 一起拷进 bundle。改了设计要重新生成：

```bash
B=~/Library/Caches/brosis-build/app/icon && mkdir -p "$B"
swiftc -O Support/icon/make_icon.swift -o "$B/make_icon" && "$B/make_icon" "$B"
iconutil -c icns "$B/AppIcon.iconset" -o Resources/AppIcon.icns
```

设计：靛蓝 → 青绿的纵向渐变圆角底；白色时间线横穿，线上两个事件点；中央白色观察环，环心一颗琥珀色记录点。

## 4. 自检（安全，不触发任何授权弹窗）

```bash
~/Library/Caches/brosis-build/app/brosis.app/Contents/MacOS/brosis --self-check
```

`SelfCheck.swift` 明确不调用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` /
`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` / `SCShareableContent` / 任何 `AXUIElement*`，
也不创建 `NSApplication`，所以在 CI 或终端里跑都不会弹窗。它验证 13 项：自检库路径、
**自检库与 GUI 测试库分离**、SQLite 版本、`journal_mode=wal`、`foreign_keys=ON`、五张表、
observations / ax_texts / frame_stats 写入、空 AX 记为 `unavailable`、dHash 稳定性与区分度、
排除清单来源。退出码 0 = 全通过。

自检写的是**独立的库** `~/Library/Application Support/brosis-m0/m0-selfcheck.sqlite`，
不碰 GUI 用的 `m0.sqlite`——自检行全是合成数据（`app=com.brosis.selfcheck`），
混进真实观测库会污染 E4 的行数与统计口径。每次运行前会先删掉上一轮的自检库，
所以跑几次结果都一样（observations 1 行 / ax_texts 2 行 / frame_stats 3 行）。

## 5. 首次运行：**两次授权，必须手动**

> 下面这些步骤 Claude 不能替你做（TCC 弹窗只接受真人点击），需要你自己操作一次。

1. **先移到固定安装路径。** TCC 用 bundle id + 代码签名要求识别客户端，但路径变化会让系统设置里出现
   多条同名项、且 LaunchAgent 的 `BundleProgram` 会失效。建议固定到 `/Applications/brosis.app`：

   ```bash
   ditto "$HOME/Library/Caches/brosis-build/app/brosis.app" "/Applications/brosis.app"
   xattr -dr com.apple.quarantine "/Applications/brosis.app"   # 未公证，需要去隔离属性
   ```

2. **从 Finder 双击启动，不要从终端启动。** 从 Terminal 运行的进程，TCC 把授权记到 Terminal 头上
   （等于给所有脚本放权），brosis 自己反而拿不到（Apple DTS：`Shell scripts and TCC don't mix`）。

3. **启动即自动引导（2026-09-07 起）**：app 一启动发现两项权限有缺，就会**自动**弹出系统授权框
   （先辅助功能、0.8 s 后屏幕录制），并显示「brosis 权限设置」引导窗口：两行实时状态、
   各自的「打开系统设置…」按钮、「重新请求授权」、「退出并重新打开 brosis」、「稍后再说」。
   窗口每 1.5 s 复查一次，两项都打开后自动收起并开始采集，不需要再回菜单栏。
   实现在 `PermissionGuide.swift`，入口是 `AppDelegate.promptForPermissions(reason:)`，
   权限在运行中丢失（月度再授权到期 / 用户撤销）时走同一套。菜单里的「请求权限…」仍在，效果相同。
   **屏幕录制的登记问题（2026-09-07 公司机实测）**：macOS 26 的「录屏与系统录音」列表只在 app 真正通过
   ScreenCaptureKit 请求过内容后才出现条目，只调 `CGRequestScreenCaptureAccess()` 既不弹框也不登记。
   所以 `Permissions.requestScreenRecording()` 在未授权时会再异步取一次 `SCShareableContent` 来触发
   系统对话框与登记。若列表里仍没有 brosis，在该页点「+」手动添加 `/Applications/brosis.app` 即可。
   下面第 3 步的老流程仍然成立，只是不再需要手动点：

   **菜单栏图标 → 请求权限…**（现在会自动发生），会连着来两次系统弹窗：
   - **辅助功能**：点「打开系统设置」，在「隐私与安全性 → 辅助功能」里把 brosis 打开；
   - **屏幕录制**：macOS 26 面板名为「屏幕与系统音频录制」，同样手动打开。

   **注意点弹窗那一刻两行状态不会变。** 弹窗只是把系统设置打开，app 在弹窗返回时取到的快照
   仍然是「未授权」，所以菜单里还会显示「权限缺失」——这是正常的，不是没生效。
   **在系统设置里拨完开关后，回到菜单栏重新展开一次菜单即可**：菜单每次展开都会重新取一次
   权限快照（`NSMenuDelegate.menuWillOpen`），两行状态会变成「已授权」，
   并且如果采集流还没起来会自动拉起，状态变成「运行中」。不需要再点一次「请求权限…」。

   **屏幕录制首次授权通常要求退出重开 app**：macOS 对 `kTCCServiceScreenCapture` 的授权
   一般只对**新启动的进程**生效，系统自己也会弹一个「退出并重新打开」的提示。
   如果拨完开关、重新展开菜单后屏幕录制那一行仍是「未授权」，就从菜单「退出」再启动一次。
   两项都授权后 app 才会武装按需截图；只有辅助功能时，事件骨架照常工作，不截图。

4. 验证有没有真的在写：菜单「打开测试库目录」→ `~/Library/Application Support/brosis-m0/m0.sqlite`。

```bash
sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
  "SELECT ts, app, title, trigger, source_state FROM observations ORDER BY id DESC LIMIT 10;"
sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
  "SELECT status, COUNT(*), ROUND(AVG(dirty_area_ratio),4) FROM frame_stats GROUP BY status;"
```

## 6. 如何验证「屏幕录制月度再授权」行为（E4 的决策出口之一）

macOS 15.0 起屏幕录制授权带有效期，系统会周期性重新提示；报告 3.3 说 26 上仍在。M0 要拿到的
不是「多久提示一次」，而是**提示到期时截图会不会失败、我们能不能自动恢复**。三条可复现的验证路径：

1. **主动撤销再恢复（最快，建议先做这条）**
   系统设置 → 隐私与安全性 → 录屏与系统录音 → 关掉 brosis 的开关。
   预期（按需截图，2026-09-07 起）：下一次触发的截图失败，库里出现
   `runtime_events.kind = 'capture_failed'`（`permission_lost=true`）、一行 `frame_stats.status='failed'`
   和 `capture_disarmed`；菜单栏图标变成警告三角、状态显示「权限缺失（屏幕录制）」，并自动弹出权限引导窗口。
   再把开关打开（可能要求重开 app），应看到 `capture_armed` 重新写入。

   ```bash
   sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
     "SELECT datetime(ts,'unixepoch','localtime'), kind, detail FROM runtime_events
      WHERE kind LIKE 'capture%' OR kind LIKE 'permission%' ORDER BY id;"
   ```

2. **等真实的月度提示**（需要挂 3–5 周）。开始挂机前记录基线时间：

   ```bash
   date -u +%FT%TZ > ~/Library/Caches/brosis-build/app/tcc_baseline.txt
   sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
     "SELECT MIN(ts) FROM runtime_events WHERE kind='capture_armed';"
   ```
   提示出现当天，把第一条 `permission_lost=true` 的 `capture_failed` 时间戳和基线相减，就是本机实测的再授权周期。
   `detail` 里带 `domain/code`，`SCStreamErrorUserDeclined = -3801`。

3. **看系统侧的 TCC 记录**（辅助判断，不改任何东西）：

   ```bash
   log show --last 2h --predicate 'subsystem == "com.apple.TCC"' --info | grep -i -E "ScreenCapture|com.brosis"
   sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
     "SELECT service, client, auth_value, last_modified FROM access WHERE client LIKE '%brosis%';"
   ```
   第二条需要给终端「完全磁盘访问」，本任务没有做，也不建议为了它开 FDA。

## 7. SMAppService 注册为登录项

代码路径：`AppDelegate.toggleLoginItem()` → `LoginItem` → `SMAppService.agent(plistName: "com.brosis.agent.plist")`。
plist 必须位于 `Contents/Library/LaunchAgents/`（build_app.sh 已经放好），且 app 必须已签名。

手动步骤：

1. 把 app 放到固定路径并启动（见第 5 节）；
2. 菜单栏 → **注册为登录项**；
3. 首次注册后 macOS 通常给一条「brosis 已添加为登录项」的通知，状态可能是
   `requiresApproval`——此时菜单会显示「登录项待批准，打开设置…」，点它跳到
   系统设置 → 通用 → 登录项与扩展，把 brosis 打开；
4. 验证：

   ```bash
   launchctl print gui/$(id -u)/com.brosis.agent | head -20
   # 或
   sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
     "SELECT datetime(ts,'unixepoch','localtime'), kind FROM runtime_events WHERE kind LIKE 'login_item%';"
   ```
5. 取消：菜单栏 → 取消登录项（调 `SMAppService.unregister()`）。

LaunchAgent 关键键（报告 3.3 的结论）：`LimitLoadToSessionType=Aqua`、`ProcessType=Background`、
`LowPriorityBackgroundIO=true`、`RunAtLoad=true`、`AssociatedBundleIdentifiers=[com.brosis.app]`。
`KeepAlive` 用的是 `{SuccessfulExit: false}` 而不是 `true`——否则从菜单栏点「退出」会被 launchd 立刻拉起来，
M0 阶段没法收工；崩溃（非 0 退出）仍然会自动重启。

## 8. 运行时行为（对照计划 3.3）

**事件骨架**：`NSWorkspace` 的 `didActivateApplication` / `didDeactivateApplication` /
`willSleep` / `didWake` / `sessionDidResignActive` / `sessionDidBecomeActive`；
每次前台应用切换重建一个 `AXObserver`，订阅 `AXFocusedWindowChanged`、`AXFocusedUIElementChanged`、
`AXTitleChanged`、`AXMainWindowChanged`。
**锁屏怎么判**（2026-09-07 修正）：`sessionDidResignActive` / `sessionDidBecomeActive`
**不是锁屏通知**——它们只在**快速用户切换**时触发，真锁屏一次都不会来，所以它们现在记的是
`user_switched_away` / `user_switched_back`。锁屏改用两路信号，先到的算数，靠一个标志位去重：

| 优先级 | 信号 | 说明 |
|---|---|---|
| 1 | **前台应用 = `com.apple.loginwindow`** | 直接观测，不依赖通知投递；进程在锁屏之后才启动也成立。登录窗口不做 AX 附着 |
| 2 | 分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | 私有通知、不保证投递，只作补充。本机实测在图形会话里能收到（`tools/probe/results/smoke_2026-09-06.md` 第 4 节有日志） |

进程启动时用 `SystemState.screenLocked()`（`CGSessionCopyCurrentDictionary` 现查）初始化标志位，
不补记事件。`source_state = locked` 一直走的就是这个现查接口，不受上面两路信号影响。
这套判定与 `tools/probe/appswitch.swift` 里已经跑了 3 天的那套是同一套。

Chromium / Electron 系应用（清单在 `AXSupport.chromiumFamilyBundleIDs`）在读树前先设
`AXManualAccessibility`。窗口读 `AXTitle`、`kAXDocument`、`kAXURL`；`kAXURL` 为空时向下找第一个
`AXWebArea` 的 `AXURL`（Safari / Chromium 的地址挂在那儿，上限 400 节点）。

**AX 超时 0.5 s 是进程级的。** `AXUIElementSetMessagingTimeout` 只对传进去的那个元素生效，
只有传 `AXUIElementCreateSystemWide()` 才是本进程全局——SDK 的 `AXUIElement.h` 写得很明白：
“Pass the system-wide accessibility object … if you want to set the timeout globally for this
process. Setting the timeout on another accessibility object sets it only for that object”。
所以 `AppDelegate.applicationDidFinishLaunching` 里在任何 AX 读取之前调用一次
`AX.installGlobalMessagingTimeout()`（0.5 s，返回的 `AXError` 记进 `runtime_events`
的 `ax_global_timeout_installed`），BFS 里通过 `kAXChildren` 新拿到的每个子元素才会一起是 0.5 s。
应用元素与焦点窗口上另外那两次 `SetMessagingTimeout` 是冗余防守，不是覆盖面的来源。
这一步不发 AX 消息、不需要辅助功能权限、不会弹窗。

**高频通知节流。** `AXFocusedUIElementChanged` 在编辑器 / 浏览器里一秒可能来几十次，
每次都做完整遍历会占满主线程并写出大量重复行，也会污染 E7 的资源占用口径。
只对它做 **2 秒节流**（`EventSkeleton.elementScanThrottle`）：距上次 AX 遍历不足 2 秒的
焦点元素变化直接丢弃，只累计计数，每 100 次和 `stop()` 时写一条
`runtime_events.kind='ax_element_notifications_throttled'`。
应用切换、焦点**窗口**变化、**标题变化**是另外的通知，不受节流影响，
所以「换窗口 / 换标题 / 换应用」这类真正的位置变化仍然即时记录。

**source_state 分离**（评审 F5，判定顺序）：`locked` > `permission_lost` > `secure_input` > `user_idle`（≥30 s）> `ok`；
AX 读不到焦点窗口时单独记 `timeout`。绝不把它们混成一个「空」。

**按需截图（2026-09-07 用户决定，取代常驻 SCStream）**：macOS 14.4 起只要有 SCStream 在跑，
菜单栏就常亮紫色「正在共享」图标，无法隐藏；改为 `SCScreenshotManager.captureImage` 一次性截图后，
图标只在截图瞬间出现。触发：事件骨架每写一条应用级观察记录（切应用 / 切窗口 / 标题变化 / 节流后的焦点元素变化）、
焦点换屏、系统唤醒 / 解锁回来，以及每 5 s 一次的定时兜底（只在 `source_state == ok` 时）；
0.35 s 合并、两次截图最少间隔 1 s；锁屏与安全输入时绝不截，用户空闲时只响应事件不做兜底。
每次截图重新取 `SCShareableContent`（排除清单按当时运行的应用算），`SCContentFilter(display:excludingApplications:)`，
`width/height` = `SCDisplay` 点尺寸（1x）、SDR、无光标。每张图算 dHash + **32×32 网格亮度差**后立即丢弃：
`frame_stats.dirty_area_ratio` = 亮度差 > 24/255 的格子占比（替代流才有的 `dirtyRects`），`dirty_rects` = 变化格子数，
`trigger` = 触发原因（新列，老库自动 `ALTER TABLE` 补上）。门控阈值不变：汉明 ≤ 6 且面积 < 2% → `gated=1`，
只表示「不触发内容检查」，不是丢证据（评审 F5）。失败写 `status='failed'`；权限被收回（preflight 变 false 或
`SCStreamErrorUserDeclined = -3801`）时解除武装并弹权限引导。`runtime_events` 里 `capture_armed` / `capture_disarmed` /
`capture_progress`（每 50 张）/ `capture_failed` 记录统计（张数、门控数、平均耗时、按锁屏 / 安全输入 / 空闲跳过的次数）。
月度再授权提示由系统在下一次截图时给出，行为待 E4 观察。

**AX 文本**：焦点窗口下 BFS（上限 1500 节点 / 12 层），统计 `AXTextArea` / `AXTextField` /
`AXStaticText` / `AXWebArea` 四个角色的节点数与字符数；遇到 `AXSecureTextField` 直接剪枝。
`completeness` 是**占位**：字符数 > 0 记 `partial`，= 0 记 `unavailable`。
真正的 `complete` 判定要等 E5 的应用适配规则 + OCR 对照采样，M0 不给。

**退出**：`applicationWillTerminate` 里停流用的是 `Task.detached`，不是 `Task { }`。
在 `@MainActor` 上下文里创建的 `Task` 会继承 MainActor 隔离，而主线程正被
`DispatchSemaphore.wait` 挡着，任务根本没机会开始——实测白等 2.002 s 且 `stop()` 没执行；
换成 `Task.detached`（`CaptureController.stop` 是 nonisolated async）实测 0.051 s 返回且真的停了流。

## 9. 测试库

目录 `~/Library/Application Support/brosis-m0/`（都是 WAL、`foreign_keys=ON`），两个文件互不干扰：

| 文件 | 谁写 | 内容 |
|---|---|---|
| `m0.sqlite` | GUI 运行 | E4 的真实观测数据 |
| `m0-selfcheck.sqlite` | `--self-check` | 合成自检数据，每次运行前重建 |

| 表 | 内容 |
|---|---|
| `observations` | ts / app / app_name / pid / title / url / document / trigger / source_state / idle_s / display_id |
| `ax_texts` | observation_id / role / node_count / char_count / is_empty / completeness |
| `frame_stats` | ts / display_id / status / width / height / content_scale / dhash / hamming / dirty_rects / dirty_area_ratio / gated / idle_count / trigger |
| `runtime_events` | 权限变化、流启停、暂停/继续、登录项注册 |
| `meta` | schema_version = 1 |

清库重来：`rm -f ~/Library/Application\ Support/brosis-m0/m0.sqlite*`（只清 GUI 库；自检库自己会重建）。

**这套表不是 v1 schema。** v1 的规范化 schema 在 `tools/proto/schema.sql`（E3），两者的差异与 M1 收敛方向列在 `tools/bench/results/app_skeleton_2026-09-06.md` 第 8 节。

## 10. 还没做 / 需要你操作的

- 授权、月度再授权观察、SMAppService 批准都要真人点击，见第 5–7 节。
- 未公证；`spctl` 预期 `rejected`。公证是 E9 的事。
- `NSAppleEventsUsageDescription` 与 `com.apple.security.automation.apple-events` 已就位，但 M0 没有
  真去发 Apple 事件（浏览器 URL 目前只走 AX）。
- 路径型 TCC 可见性（报告 §11.2 第 9 条）没验证：本骨架只做 bundle 形态。
- 剪贴板 `accessBehavior`（报告 §11.2 第 2 条）没碰，v1 不依赖剪贴板。
- AX 0.5 s 超时只验到「SDK 文档 + `AXUIElementSetMessagingTimeout` 对 system-wide 元素返回 `.success`」，
  没有端到端计时证据（AX 没有读回超时的 API，也没有现成的挂死应用）。真正的验证归 E5：
  拿一个能人为卡住的目标应用，量 `AXUIElementCopyAttributeValue` 的返回耗时是否 ≈0.5 s。
  授权后第一次运行可以先核对这一行：

  ```bash
  sqlite3 ~/Library/Application\ Support/brosis-m0/m0.sqlite \
    "SELECT kind, detail FROM runtime_events WHERE kind='ax_global_timeout_installed';"
  # 期望 detail 里是 AXError=0(success)
  ```
