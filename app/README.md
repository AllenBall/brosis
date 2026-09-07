# app/ — brosis.app 采集端（M1 / R1 · T4）

对应：`docs/实施计划.md` 的 **3.1**（采集端 + 单一存储服务）、**3.3**（采集策略与完整性状态）、
**3.5**（密钥与锁定状态机）、**3.12**（应用采集清单）、**4.2**（规则脱敏、暂停触发器）、
**2.2 硬约束 1–3**；`docs/可行性调研报告.md` 3.3、3.4；评审 **F1**（单一持钥者）、**F5**（状态分离、门控不丢证据）。

**M1 起采集端不再自己开库。** 唯一持钥者是 `../core` 的 `BrosisCore`（SQLCipher 加密库），
`app/` 通过 `Recorder` 这层薄壳写进去。M0 的明文测试库 `~/Library/Application Support/brosis-m0/`
**原样保留、不再读写、不迁移**——它是 E4 的原始观测数据，schema 与 v1 完全不同。

> 本轮（R1 / T4）**不含 3.12 的应用清单窗口**（那一页 GUI 在第二轮），只做它的数据层、
> 内置默认清单与菜单栏快捷项。适配器、局部 OCR、MCP 也都不在本轮。

**R1 验收复核后的六处修订**（本文件已同步）：

1. **用户显式策略不再被默认判定覆盖**：`app_policies` 只在"库里确实没有这一行"时插入，
   库没开时的判定是**临时的**（不缓存、不落库、不记事件）——见 8.2；
2. **私密浏览命中时，窗口标题 / URL / 文件路径连同正文一起不存**——见 8.4；
3. **窗口标题与 URL 也过入库前脱敏**（原来只有正文过）——见 8.3；
4. `locking` 期间到达的唤醒 / 解锁触发会在关库落地后**补做**，不再被丢掉——见 8.1；
5. `app_launched` 只在本次进程第一次开库时写，之后每次解锁写 `store_unlocked`；
6. 第 9 节的运行期事件 kind 一览补全到 **54 种**（原来漏了权限引导的 6 种）。

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
├── build_app.sh                      swift build → 组装 .app → Developer ID 签名 → 验证
├── Sources/brosis/
│   ├── main.swift                    入口；--version / --self-check / --dump-vectors 都不创建 NSApplication
│   ├── BuildInfo.swift               版本、bundle id、ObservationTrigger 及其到 core 枚举的收敛
│   ├── AppDelegate.swift             菜单栏（录制 / 暂停 / 锁定 / 权限缺失）、一键暂停、
│   │                                 「暂停采集当前应用（今天 / 永久）」、锁定 / 解锁、登录项
│   ├── LockController.swift          3.5 锁定状态机：LockPolicy（纯函数）+ 取钥 / 开库 / 校验 / checkpoint / 关库
│   ├── Recorder.swift                写入 BrosisCore.Store 的唯一出口 + DataLocation（D16）+ AXTextSummary
│   ├── CapturePolicy.swift           3.12 三档数据层、内置默认不采集清单、私密浏览判定
│   ├── Redaction.swift               入库前规则脱敏（gitleaks 子集 + Luhn + 验证码）+ 33 条测试向量
│   ├── Permissions.swift             TCC 探测与请求；SystemState（空闲、安全输入、锁屏）
│   ├── EventSkeleton.swift           NSWorkspace 通知 + AXObserver + 屏保通知 + 显示器归属 + 策略闸门
│   ├── AXSupport.swift               AX 读取（进程级 0.5 s 超时）、Chromium/Electron 两路判定 +
│   │                                 AXManualAccessibility、按 bundle id 的 BFS 限额、正文与统计
│   ├── CaptureController.swift       按需截图（SCScreenshotManager）+ 帧门控 + 定时兜底 + 策略排除
│   ├── DHash.swift                   9×8 灰度差分哈希（64 bit）
│   ├── PermissionGuide.swift         权限引导窗口
│   └── SelfCheck.swift               无 GUI / 无 TCC / 不碰钥匙串的自检（38 项）+ --dump-vectors 判定表转储
├── Support/
│   ├── Info.plist                    LSUIElement=1 + 三个 usage string
│   ├── brosis.entitlements           不沙盒 + apple-events
│   └── com.brosis.agent.plist        SMAppService LaunchAgent
└── Resources/exclusions.txt          3.12 内置默认「不采集」清单（与代码内清单取**并集**）
```

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
下建两个符号链接。没有它 `app` 编不过（依赖链 `brosis → BrosisCore → SQLCipher`）。

**`DEVELOPER_DIR` 是必须的**：本机 `xcode-select` 指向 CommandLineTools，不加前缀拿不到完整工具链。

脚本七步：确认签名身份 → `swift build --scratch-path` → 组装 bundle 并 `plutil -lint` + 校验六个必备键 →
`codesign --options runtime --timestamp --entitlements` → `codesign --verify --deep --strict` →
`codesign -dv --verbose=4` → 打印 entitlements → `spctl` 评估。

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CONFIG` | `release` | 传给 `swift build -c` |
| `SCRATCH` | `~/Library/Caches/brosis-build/app` | SwiftPM scratch 与 .app 输出目录 |
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

## 4. 自检（安全，不触发任何授权弹窗、不碰钥匙串）

```bash
~/Library/Caches/brosis-build/m1-app/brosis.app/Contents/MacOS/brosis --self-check
~/Library/Caches/brosis-build/m1-app/brosis.app/Contents/MacOS/brosis --dump-vectors
```

`SelfCheck.swift` 明确不调用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` /
`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` / `SCShareableContent` / 任何 `AXUIElement*`，
不创建 `NSApplication`，**也不用 `KeychainKeyProvider`**（那会弹钥匙串授权框）。
共 **38 项**，退出码 0 = 全通过：

| 组 | 项数 | 验什么 |
|---|---|---|
| core 往返 | 19 | 用 `InMemoryKeyProvider` 在**临时目录**开一个真加密库：SQLCipher 版本 / `cipher_page_size=16384` / `journal_mode=wal` / `auto_vacuum=2` / `foreign_keys=1` / 编译期 `TEMP_STORE=3`、目录 0700 与两个排除标记、写一条带两个片段的观察、按 ord 读回逐字符比对、库里搜不到脱敏前明文、**库文件字节里搜不到正文明文（带阳性对照）**、运行期事件与遥测各 1 行、`app_policies` 三档往返、**用户策略经「锁定 → 解锁」往返后不变**、**库没开时的判定是临时的（不缓存、不落库）**、13 项悬空引用 + `integrity_check` + FTS、关库后密钥已清零 |
| 入库前脱敏 | 2 | 21 条正例（含窗口标题 / URL 三条）+ 12 条反例逐字符比对；Luhn 能区分卡号与订单号 / 时间戳 |
| 3.12 三档 | 8 | 三档的生效方式开关表；解析优先级 5 条；内置清单已加载且覆盖四个类别 |
| 3.5 状态机 | 3 | 21 条转移用例；7 条「`locking` 期间的开库触发要补做」用例；低磁盘阈值 = 2 GiB |
| 私密浏览 | 2 | 浏览器标题含无痕标记时命中；非浏览器不误伤 |
| dHash | 2 | 同图稳定、异图汉明距离 > 6 |
| Electron / CEF | 2 | 伪造 `.app` 正反两例 |

自检的加密库开在 `$TMPDIR/brosis-selfcheck-<pid>/`，**跑完删除**，
既不碰产品数据目录也不碰 M0 库；跑几次结果都一样。

`--dump-vectors` 把判定表逐条摊开成 Markdown 表格（正例 21 / 反例 12 / 三档开关 / 21 条转移 /
7 条补做用例 / 内置清单分类，共 6 节），输出可以直接贴进结果文件核对。

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
   反过来，关库过程中再来锁定类触发（⌘L / 锁屏 / 睡眠 / 低磁盘 / 热 critical）会**取消**补做——
   用户刚按了锁定，不该因为半分钟前的一次唤醒又把库开回来。

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
- **改为更低档时询问是否删除已有数据**（3.12 最后一条）属于应用清单窗口，**第二轮做**。

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
`occurrences.region` 存 AX 角色（3.2 允许 region 是"AX 路径"，角色是它最粗的一档）。
`completeness` 仍是**占位**：读到正文 = `partial`，读不到 = `unavailable`，
被策略排除 / 私密浏览 = `excluded`。真正的 `complete` 判定要等第二轮的适配规则 + OCR 对照。

**source_state 分离**（评审 F5，判定顺序）：`locked` > `permission_lost` > `secure_input` >
`user_idle`（≥30 s）> `ok`；AX 读不到焦点窗口时单独记 `timeout`。绝不混成一个「空」。

### 8.6 按需截图

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

### 8.7 退出

`applicationWillTerminate`：停事件骨架 → 停截图（`Task.detached` + 信号量，**不能用 `Task { }`**：
在 `@MainActor` 上下文里创建的 Task 继承 MainActor 隔离，而主线程正被 `DispatchSemaphore.wait`
挡着，任务根本没机会开始）→ `LockController.shutdown()` 同步做 checkpoint + 关库 + 清零密钥。

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

**运行期事件 kind 一览**（`jobs.type = 'runtime_event:<kind>'`，**54 种**）：

- 生命周期（4）：`app_launched`（本次进程只写一次）、`store_unlocked`（之后每次解锁）、
  `app_terminating`、`self_check`
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
（观察 / 事件 / 遥测），下一次开库写一条 `runtime_event:recorder_dropped`——
"锁定期间丢了多少"是可核对的，不是悄悄消失。菜单栏「写入：」那一行实时显示同一组计数。

**M0 的明文库**：`~/Library/Application Support/brosis-m0/`（`m0.sqlite` + `m0-selfcheck.sqlite`）
**原样保留、本版本不读不写不迁移**。它的 schema 与 v1 差得太远，迁移的收益抵不上污染 v1 库的风险；
要看 E4 的老数据直接用 `sqlite3` 打开那两个文件即可。

## 10. 还没做 / 需要你操作的

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
9. **私密浏览**：Safari 开无痕窗口，看该窗口的观察 `completeness = excluded`，
   且**没有正文、没有窗口标题、没有 URL**（`windows` / `urls` 里不该出现那个无痕窗口）。
10. **屏幕录制月度再授权**（第 6 节）与 **SMAppService 登录项批准**（第 7 节）。

**本轮明确没做的**：

- **3.12 的应用清单窗口**（分组、7 天统计、改档时询问是否删数据）→ 第二轮。
- **查询时那一道脱敏**（计划 4.2 说入库前一道、查询时一道）→ 属于 T3 的检索层。
- **视口裁剪**：计划 3.3 要求只入库视口内实际显示的内容，本轮只有 20 000 字符的粗上限；
  真正的视口判定要等 E5 的适配规则。
- **适配器、局部 OCR、`completeness = complete` 的判定、采样审计** → 第二轮。
- **未公证**；`spctl` 预期 `rejected: Unnotarized Developer ID`。
- `NSAppleEventsUsageDescription` 与 `com.apple.security.automation.apple-events` 已就位，
  但没有真去发 Apple 事件（浏览器 URL 目前只走 AX）。
- **AX 0.5 s 超时**仍只验到「SDK 文档 + 对 system-wide 元素返回 `.success`」，没有端到端计时证据。
- 路径型 TCC 可见性、剪贴板 `accessBehavior` 都没碰。
