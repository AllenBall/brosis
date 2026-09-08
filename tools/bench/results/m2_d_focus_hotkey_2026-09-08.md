# M2 d 批 / T18：Focus 联动 + 全局热键 + 2.2 硬约束逐条对照表

2026-09-08，M4 Air（16 GiB、无风扇）、macOS 26.6.2 (25G83)、Xcode 26.6、Swift 6.3.3、语言模式 v6。
执行全程**屏幕锁定、用户不在场**：没启动 GUI、没触发任何 TCC / 钥匙串弹窗、没碰
`/Applications/brosis.app` 与它的数据目录。对应计划 4.5 M3「Focus 联动」、3.5 触发表里的
「显式锁定（菜单 / 热键）」、4.2「暂停触发器……热键」未做项、4.1 M0 表「Focus 状态 JSON 是否可用
→ 延到 M3」、2.2、4.3.2 T18。

一句话：**热键做完了并有实测依据；Focus 联动代码做完了但在这台机器上恒为不可用（TCC 拒绝，
如实显示原因）；2.2 八条硬约束的证据盘了一遍，补了三条能自动化的自检，剩下的缺口写明了为什么补不了。**

---

## 1. 做了什么

### 1.1 Focus 探针与联动（新文件 `app/Sources/brosis/FocusProbe.swift`）

- `FocusProbe`：只读 `~/Library/DoNotDisturb/DB/Assertions.json` 与 `ModeConfigurations.json`
  两个文件。**绝不用别的接口**（不碰 EventKit、通知中心、Apple 事件、子进程），
  因此不会弹任何窗。读取用 `open(2)` / `read(2)` 而不是 `Data(contentsOf:)`，
  为的是拿到**真实 errno**——`NSError` 会把 EPERM / ENOENT 都揉成
  `NSFileReadNoPermissionError`，分不出"被 TCC 拦了"还是"文件没了"。
- 三态结果：`unavailable(原因)` / `inactive`（可读、当前没有 Focus） / `active([模式])`。
  **解析失败也算 `unavailable`**：「读不到」与「确定没开」必须分得清，否则会静默地把联动关掉。
- 解析是"在整棵 JSON 树里找几个键"的宽容遍历（深度上限 32），不照某一版结构逐层下钻：
  这两个文件没有公开契约，系统换一层包装不至于直接失效。
  主键 `assertionDetailsModeIdentifier`，退路是"同一字典里有 `modeIdentifier` 且有 `assertion*` 键"；
  名字表认两种形状（`modeIdentifier` + `name`，或"以模式 id 作键、值里有 `name` / `mode.name`"）。
- 暂停名单：`UserDefaults` 键 `focus.pauseModes`（字符串数组），**默认空 = 不联动**：
  `FocusMonitor.start()` **启动时探一次**（`poll(force: true)`，为的是菜单第一次打开就能
  说清"可不可用、为什么"），此后名单为空的每一轮轮询都**零 syscall**。
  名单项三种写法都认：显示名、完整模式 id、id 末段；
  `*` 表示"任何 Focus 生效就暂停"。
- `FocusMonitor`：轮询 → 命中就走**现有那条暂停路径**
  `LockController.apply(.focusPauseStarted)` → `pauseReasons` 加一条 `.focus`
  → `isRecording == false`（采集停、MCP 拒绝、库保持打开）；恢复走 `.focusPauseEnded`，
  **只删 `.focus` 这一条**，屏幕还锁着时 `.screenLocked` 留着（有专门的转移用例）。
  与安全输入 / 锁屏 / 屏保 / 私密浏览是同一个集合、同一条恢复路径。
- 轮询间隔**与 `CaptureController` 的定时兜底同一个值**：`CaptureController.periodicInterval`，
  默认 **12 s**，键 `capture.periodicInterval`，下限 3 s。不另设一个键。
- 事件：`focus_probe`（可用性变化，含首次探测）、`focus_pause`、`focus_resume`。
- 不可用时菜单显示 `Focus 联动不可用（<原因>）`（`FocusMonitor.menuDescription`）。

### 1.2 全局热键（新文件 `app/Sources/brosis/HotKeys.swift`）

- Carbon `RegisterEventHotKey`。默认 **⌃⌥⌘P** 暂停 / 继续采集、**⌃⌥⌘L** 锁定数据库；
  可用 `UserDefaults` 的 `hotkey.pause` / `hotkey.lock` 改键。
- **处理器只发通知**：`@convention(c)` 回调里只取一个 `EventHotKeyID` 并
  `NotificationCenter.post`，动作走既有的 `LockController.togglePause()` / `lockNow()`，
  与点菜单是同一条路径。
- 键位解析 `HotKeyParser.parse` 是纯函数，收单词写法（`ctrl+alt+cmd+P`，别名
  `command` / `opt` / `option` / `control` / `meta`）与符号写法（`⌃⌥⌘P`），
  大小写与空格无所谓；**至少一个修饰键**，否则拒绝（无修饰键的全局热键会把那个键从
  所有 app 里抢走，实测 `F19` 无修饰键也能注册成功——不给用户踩这个坑）。
- 注册失败**记事件**（`hotkey_register_failed`，带 action / combo / OSStatus / 原因）
  并在菜单显示（`HotKeys.menuDescription` 把失败原因摊开）；成功记 `hotkey_registered`，
  按下记 `hotkey_fired`。
- **`uninstall()` 把两个热键与事件处理器全撤掉**，自检跑完立刻调，不给正在运行的
  `/Applications/brosis.app` 留下抢着的组合；自检用"装 → 卸 → **再装** → 再卸、
  两轮结果必须相同"来证明组合真的还给了系统（见 §2.1 变异 ③）。

### 1.3 接到锁定状态机上（改 `app/Sources/brosis/LockController.swift`，纯追加）

`PauseReason` 加 `.focus`；`LockTrigger` 加 `.focusPauseStarted` / `.focusPauseEnded`；
`next()` 里两条 case；`transitionCases` 21 → 24 条、`deferredUnlockCases` 7 → 8 条、
`cancelDeferredCases` 11 → 12 条（Focus 暂停不关库，不取消"关库后补做开库"）。

### 1.4 自检（两个新文件 + `SelfCheck.swift` 加两行）

`FocusHotKeySelfCheck`（第 12 组，7 项）与 `HardConstraintSelfCheck`（第 13 组，3 项）。
`SelfCheck.swift` 只加了两行 `failures += …` 与两行参数快照，没动别的任务的块。

---

## 2. 怎么跑（可复制粘贴）

```bash
P="<项目目录>"          # 这个仓库的根（本文件里一律写成 $P，不写本机绝对路径）
cd "$P"

# 构建 + 组装 + 签名 + 验证（产物一律在 ~/Library/Caches 下，不进项目目录）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/m2-focus-app" ./app/build_app.sh

# 自检（172 项；必须从 bundle 里跑——裸二进制没有 mlx.metallib）
"$HOME/Library/Caches/brosis-build/m2-focus-app/brosis.app/Contents/MacOS/brosis" --self-check

# 只看 T18 这两组
"$HOME/Library/Caches/brosis-build/m2-focus-app/brosis.app/Contents/MacOS/brosis" --self-check \
  | grep -E "Focus|热键|键位|硬约束"

# 峰值内存
/usr/bin/time -l "$HOME/Library/Caches/brosis-build/m2-focus-app/brosis.app/Contents/MacOS/brosis" \
  --self-check > /dev/null
```

热键与 Focus 的**底层依据**由三个独立小程序量出来，源码与原始输出都在
`~/Library/Caches/brosis-build/m2-focus/results/`（`eperm.c` / `eopen.c` / `hk.swift` /
`hk2.swift` / `disclaim.c` / `hotkey_probe.txt`）：

```bash
R="$HOME/Library/Caches/brosis-build/m2-focus/results"
cd "$R"
clang -o eperm eperm.c && clang -o eopen eopen.c && clang -o disclaim disclaim.c
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -o hk  hk.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -o hk2 hk2.swift
./eperm "$HOME/Library/DoNotDisturb/DB/Assertions.json"     # stat(2)：TCC 不拦
./eopen "$HOME/Library/DoNotDisturb/DB/Assertions.json"     # open(2)：EPERM
./hk                                                        # 继承终端 TCC 归属
./disclaim "$R/hk"                                          # 断开归属 → AX 未授权
./hk2                                                       # 冲突语义
```

本任务**没有碰 `core/`**，所以没跑 `swift test`；`build_app.sh` 的 1b 步照常构建了
core 包的 `brosis-mcp`，零 warning。

### 2.1 变异检验（**复制到 scratch 再改**，别在项目目录里改）

四处变异各打红一处，已实跑验证（结果见下）。`sed` 用 `|` 作分隔符、模式里不含
`\(`（BRE 里那是分组），照抄即可：

```bash
SRC="<项目目录>"                                # 这个仓库的根
MUT="$HOME/Library/Caches/brosis-build/m2-focus-mutate"
rm -rf "$MUT" && mkdir -p "$MUT" && cp -R "$SRC/app" "$SRC/core" "$MUT/"

# ① EPERM 的原因里不再提 TCC → 「Focus 解析向量 7 条」变红
sed -i '' 's|TCC 拒绝（errno|拒绝（errno|' "$MUT/app/Sources/brosis/FocusProbe.swift"

# ② 去掉「至少一个修饰键」那道闸 → 「键位解析 14 条」变红
sed -i '' 's|guard modifiers != 0 else { return nil }|// mutated|' \
  "$MUT/app/Sources/brosis/HotKeys.swift"

# ③ uninstall() 里不真的注销 → 「热键注销干净」/ 两条注册项变红
sed -i '' 's|UnregisterEventHotKey(ref)|OSStatus(0); _ = ref|' \
  "$MUT/app/Sources/brosis/HotKeys.swift"

# ④ 链接白名单里去掉 /usr/lib/ → 「硬约束 5 / 8」变红
sed -i '' 's|"/System/Library/Frameworks/", "/usr/lib/",|"/System/Library/Frameworks/",|' \
  "$MUT/app/Sources/brosis/HardConstraintSelfCheck.swift"

# 四处都要看到 diff（0 就是模式没匹配上，那说明变异根本没生效）
diff -rq "$SRC/app/Sources/brosis" "$MUT/app/Sources/brosis"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/m2-focus-mutate-app" "$MUT/app/build_app.sh"
"$HOME/Library/Caches/brosis-build/m2-focus-mutate-app/brosis.app/Contents/MacOS/brosis" \
  --self-check | grep -E '^\[FAIL\]'
```

跑完 `rm -rf "$MUT" "$HOME/Library/Caches/brosis-build/m2-focus-mutate-app"*`。

**实跑结果**（`~/Library/Caches/brosis-build/m2-focus/results/mutation_self_check.txt`）：
四处变异共打红 **6 项**，未变异的 166 项全绿。

| 变异 | 变红的自检项 |
|---|---|
| ① | `Focus 解析向量 7 条`（"EPERM 应当是 unavailable 且原因提到 TCC"） |
| ② | `键位解析 14 条`（"没有修饰键 → 拒绝「P」：期望 (拒绝)，实得 P"） |
| ③ | `热键注册 · 暂停`、`热键注册 · 锁定`（第二轮 `OSStatus=-9878`）、`热键注销干净`（第一轮 `pause=0 lock=0`，第二轮 `pause=-9878 lock=-9878`） |
| ④ | `硬约束 5 / 8`（"越界：/usr/lib/libSystem.B.dylib …"） |

**变异 ③ 是这次变异检验真正的收获**：第一版自检只看 `UnregisterEventHotKey` 的返回值，
把它换成常量 `noErr` 照样全绿——"注销干净"根本没被验证。改成
**装 → 卸 → 再装 → 再卸、两轮结果必须相同**之后才抓得住：真漏注销时 Carbon 在第二轮回
`eventHotKeyExistsErr (-9878)`。

---

## 3. 实测数字

### 3.1 Focus 状态文件的可读性（本机）

| 操作 | 路径（相对主目录） | 结果 | 耗时 |
|---|---|---|---|
| `stat(2)` | `Library/DoNotDisturb` | rc=0 | 0.018 ms |
| `stat(2)` | `Library/DoNotDisturb/DB` | rc=0 | 0.005 ms |
| `stat(2)` | `…/DB/Assertions.json` | rc=0 | 0.253 ms |
| `stat(2)` | `…/DB/ModeConfigurations.json` | rc=0 | 0.256 ms |
| `open(2)` | `…/DB/Assertions.json` | **fd=-1, errno=1 EPERM** | 0.057 / 0.011 ms（两次） |
| `open(2)` | `…/DB/ModeConfigurations.json` | **fd=-1, errno=1 EPERM** | 0.026 / 0.011 ms（两次） |

结论三条：

1. **本机 Focus 联动恒为不可用**——终端与 app 都没有「完全磁盘访问」。
   自检如实打印：`focus=unavailable reason=Assertions.json TCC 拒绝（errno 1 …）`。
2. **不弹窗、不阻塞**：`open` 在 0.06 ms 内返回失败。这一类 TCC 服务（完全磁盘访问）
   没有用户提示，系统直接拒；不像文稿 / 桌面那几类会弹框。
3. **`stat` 成功 ≠ 读得到**：TCC 拦的是 `open`。所以探针一定要真开一次文件，
   不能拿"文件存在"当可用性判据——这是实现里踩到的第一个坑。

### 3.2 `RegisterEventHotKey` 不需要辅助功能权限（实测）

| 场景 | `AXIsProcessTrusted()` | `RegisterEventHotKey(⌃⌥⌘P)` | `Unregister` |
|---|---|---|---|
| 从终端跑（继承终端的 TCC 归属） | `true` | `OSStatus=0`，拿到 ref，19.3 ms（首次含 HIToolbox 初始化） | 0 |
| `responsibility_spawnattrs_setdisclaim` 断开归属 | **`false`** | **`OSStatus=0`**，拿到 ref，3.4 ms | 0 |
| 第二个组合 ⌃⌥⌘L（同进程） | — | `OSStatus=0`，0.018–0.020 ms | 0 |

**第二行是关键证据**：进程明确**没有**辅助功能权限（也没有 bundle id、没有
`NSApplication`、屏幕还锁着），热键照样注册成功。

冲突语义（`hk2`）：

| 用例 | 返回 |
|---|---|
| 同 signature 同 id 同组合，第二次 | `-9878 eventHotKeyExistsErr` |
| **同组合、不同 id** | `-9878` |
| **同组合、不同 signature** | `-9878` |
| `⌘Space`（系统 Spotlight 占着） | **`0`（成功）** ← 注册成功不代表按键到得了 |
| `F19` 无修饰键 | `0`（成功）← 所以解析器强制要修饰键 |

即：**Carbon 只在本进程内检测组合冲突；跨进程 / 系统快捷键冲突不报错，按键只是不来。**
菜单因此写"注册成功 / 失败 + 组合"，不写"热键可用"。

### 3.3 构建与自检

| 项 | 数字 |
|---|---|
| `swift build`（app 包，release，增量） | 11.6 / 34.3 s（两次），**零 warning** |
| `build_app.sh` 全流程 | rc=0，**零 warning**；`codesign --verify --deep --strict` 通过；Sparkle 各 Mach-O 的 Team ID 核对通过 |
| `brosis.app` 体积 | 102 MiB（`du -sm`） |
| `--self-check` | **172 项全过、0 失败**（本任务新增 10 项：7 + 3） |
| 自检耗时 / 峰值 | 2.85 s real；**peak memory footprint 240,812,944 B = 229.7 MiB**（不加载模型） |
| 主二进制直接链接的库 | 51 个，全在 `/System/Library/Frameworks/` `/usr/lib/` `@rpath/`；自带的只有 `@rpath/Sparkle.framework/Versions/B/Sparkle` |

本任务新增的 10 项（原文见 `~/Library/Caches/brosis-build/m2-focus/results/self_check_t18_items.txt`）：

```
[PASS] Focus 探针（本机实测，如实报可用性）：focus=unavailable reason=Assertions.json TCC 拒绝（errno 1 …）；轮询间隔 12 s
[PASS] Focus 解析向量 7 条（开 / 关 / 多个 / 无名字表 / 兜底形状 / 坏 JSON / EPERM）
[PASS] Focus 暂停名单匹配 10 条
[PASS] 热键注册 · 暂停 / 继续采集（ctrl+alt+cmd+P）：combo=⌃⌥⌘P OSStatus=0 registered=true unregister=0 第二轮 OSStatus=0
[PASS] 热键注册 · 锁定数据库（ctrl+alt+cmd+L）：combo=⌃⌥⌘L OSStatus=0 registered=true unregister=0 第二轮 OSStatus=0
[PASS] 热键注销干净：组合真的还给了系统（装 → 卸 → 再装，两轮结果必须相同）：第一轮 pause=0 lock=0；第二轮 pause=0 lock=0
[PASS] 键位解析 14 条（单词 / 符号 / 别名 / 三种拒绝）
[PASS] 硬约束 6：Info.plist 不含麦克风 / 摄像头 / 语音识别用途说明
[PASS] 硬约束 5 / 8：主二进制直接链接的 51 个库全是公开框架或自带的
[PASS] 硬约束 6：更新检查默认关、更新源是 https
```

顺带把 3.5 状态机的用例表撑到 **24 条转移 + 8 条补做 + 12 条取消补做**（原 21 / 7 / 11）。

---

## 4. 2.2 硬约束逐条对照表

「证据」列里 `core:` 是 `core/Tests/BrosisCoreTests/` 的测试名，`app:` 是 `--self-check` 的项名
（原样可 `grep`），`build:` 是 `app/build_app.sh` 的步骤。
状态：**有测试** = core 单元测试；**有自检** = app `--self-check` 断言；
**只有代码审查** = 没有自动化断言；**缺** = 连代码都还没有。

### 硬约束 1：静态加密，不产生明文临时文件

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 数据库加密 | `core/Sources/BrosisCore/Store.swift`（`key` → `cipher_page_size` → `auto_vacuum` → WAL 的连接顺序） | core:`testWrongKeyFailsAndRightKeySucceeds`、`testNoPlaintextLeak`；app:`SQLCipher 已链接`、`cipher_page_size = 16384`、`journal_mode = wal` | 有测试 + 有自检 |
| 索引加密 | 同上（FTS / vec_chunks 都在同一个加密库里） | app:`库文件里搜不到正文与脱敏前明文（含阳性对照）`；core:`testNoPlaintextLeak` | 有测试 + 有自检 |
| 不产生明文临时文件 | `SQLITE_TEMP_STORE=3` 编译期写死（`core/Sources/CBrosisSQLite`） | app:`TEMP_STORE 编译期 = 3（D25）`；core:`CryptoAndBuildTests` | 有自检 |
| 密钥用后清零 | `Store.close()` | core:`testKeyIsZeroizedOnClose`、`testSecureKeyZeroize`；app:`关库后密钥已清零（3.5 locking）` | 有测试 + 有自检 |
| 缩略图加密 | — | D10 已定**默认不做**；`thumb_ref` 只是一列路径，`Store+Integrity` 有悬空检查 | 不适用（未实现） |

### 硬约束 2：采集时排除

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 按应用三档模式（3.12） | `app/Sources/brosis/CapturePolicy.swift`、`Policies/PolicyList.swift` | app:`三档的生效方式`、`策略解析：…`、`改档状态机 … 条`、`降档删数据端到端`；core:`AppInventoryTests` | 有测试 + 有自检 |
| `SCContentFilter` 排除「不采集」应用 | `CaptureController.swift`（`excludingApplications:`） | 只有代码审查——要真截图 + 真窗口，屏幕锁定下做不了 | **只有代码审查** |
| 暂停触发器 · 安全输入 | `Permissions.swift` `SystemState.secureInputEnabled()`、`CaptureController` 的 `skippedSecureInput` | 只有代码审查（`IsSecureEventInputEnabled()` 无法在无人值守下造真值） | **只有代码审查** |
| 暂停触发器 · 锁屏 / 屏保 | `LockController.swift` | app:`锁定状态机 24 条转移` | 有自检 |
| 暂停触发器 · 私密浏览 | `CapturePolicy.swift` 的 `PrivateBrowsing` | app:`私密浏览（Safari 标题含无痕标记）`、`私密浏览不误伤非浏览器` | 有自检 |
| 暂停触发器 · **Focus**（本任务） | `FocusProbe.swift` | app:`Focus 解析向量 7 条`、`Focus 暂停名单匹配 10 条`、`Focus 探针（本机实测）` | 有自检 |
| 暂停触发器 · **热键**（本任务） | `HotKeys.swift` | app:`热键注册 · 暂停`、`热键注册 · 锁定`、`键位解析 14 条`、`热键注销干净` | 有自检 |
| 菜单栏可见状态 | `AppDelegate.swift` 的 `statusTitle` / `statusSymbol` | 只有 GUI 验证（README 8.1 / 11 的清单） | **只有代码审查** |
| 不可共享窗口标记默认尊重 | 由系统保证：`sharingType = .none` 的窗口不进 ScreenCaptureKit 的帧 | 只有代码审查（我们没有反向覆盖它的代码，所以"默认尊重"成立） | **只有代码审查** |
| 「已明确纳入的应用可覆盖」 | — | 没有实现 | **缺（功能未做）** |

### 硬约束 3：一键暂停；按应用 / 时间段 / 对象删除，级联

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 一键暂停 | `LockController.togglePause()`（菜单 + 本任务的热键） | app:`锁定状态机 24 条转移`（含 `menuPause` / `menuResume` 与 Focus 三条）、`setPaused 只在状态变化时写 capture_paused / capture_resumed` | 有自检 |
| 按应用删除 | `Store.deleteByApp` | core:`testDeleteByAppClearsStatsButKeepsPolicy`；app:`降档删数据端到端` | 有测试 |
| 按时间段删除 | `Store.deleteByTimeRange` | core:`testDeleteByTimeRangeIsHalfOpen` | 有测试 |
| 按对象删除 | `Store.deleteByObject` | core:`testDeleteByObjectVariants` | 有测试 |
| 级联（派生关系） | `Store+Delete` / `Store+Integrity` | core:`testS3_UserDeleteCascade`、`testDeletedObservationDisappearsFromEveryEntry`、`testDeletedObservationsVanishFromEveryTool`、`testDeleteMarksSessionsStaleAndRebuildRecomputes`、`testDeleteMarksWeekLedgerStaleAndRecomputeDropsIt`、`testKNNRoundTripAndDeleteCascade`、`testCaptureAuditSurvivesObservationDeletion` | 有测试 |
| 删除审计 | 同上 | core:`testEmptyDeleteStillWritesAudit` | 有测试 |

### 硬约束 4：MCP 只读、限流、审计、按客户端范围限制

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 只读（9 个工具全是读） | `core/Sources/BrosisCore/StoreMCPService.swift`、`core/Sources/brosis-mcp` | core:`testInitializeListsEveryToolAndDeniesEverythingWithoutGrant`；app 参数快照打印 9 个工具名 | 有测试 |
| 限流 | `StoreMCPService` 滑动窗口 | core:`testRateLimitThroughMCP`、`testRateLimiterSlidingWindow`、`testRateLimiterEvictsStaleClients`、`testServerEnforcesRateLimitAndExemptsPing` | 有测试 |
| 审计 | `mcp_audit` 表 | core:`testAuditRecordsShapeNotContent`、`testTransportRefusalsAreAudited`、`testAuditPrunedByMaintenance`；app:`mcp_audit 记了每次调用且不含查询串本身（3.6）` | 有测试 + 有自检 |
| 按客户端范围（grants） | `grants` 表 | core:`testNoGrantDeniesEveryTool`、`testGrantLimitsFieldsAppsAndWindow`、`testGrantFieldsControlRawText`、`testSummaryGrantDoesNotLeakRawTextThroughMCP`、`testDroppedNeighborsDoNotConsumeTheNeighborQuota`；app:`没有 grant 的客户端被拒`、`fields = summary 不回原文`、`应用白名单也裁 get_evidence 的出现上下文` | 有测试 + 有自检 |
| 锁定 / 暂停时拒绝 | `MCPIPCService.setPaused` | core:`testLockedAndPausedRejectAndAuditIsFlushed`；app:`锁定 / 暂停时 MCP 拒绝且零模型调用（3.5）` | 有测试 + 有自检 |
| IPC 对端校验 | `IPCService.swift` `PeerVerifier` | app:`对端签名校验：同 Team ID 放行`、`对端签名校验：本进程没有 Team ID 时一律拒绝`、`ipc.sock 权限 0600` | 有自检 |

### 硬约束 5：稳定签名的 `.app` + SMAppService；只依赖公开 API

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| Developer ID 签名 + hardened runtime | `app/build_app.sh` 第 3 / 3a 步 | build:`codesign --verify --deep --strict` 通过、`4a 核对 Sparkle 每个 Mach-O 的 Team ID` | 构建期验证 |
| 签名身份跨版本不变（D13） | `dist/RELEASE.md` | 只有文档 + 发布清单 | **只有代码审查** |
| SMAppService 登录项 | `AppDelegate.swift` 的 `enum LoginItem`（`SMAppService.agent`） | 只有 GUI 验证（README 第 7 节） | **只有代码审查** |
| **只依赖公开 API** | 全仓库 | **本任务新增** app:`硬约束 5 / 8：主二进制直接链接的 51 个库全是公开框架或自带的（无私有框架 / 无 Homebrew / 无 Python）` | **本任务补了自检** |

### 硬约束 6：不录音频、不存视频；默认不上传，例外各有开关与审计

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| **不录音频** | `app/Support/Info.plist`（没有麦克风用途说明 ⇒ 系统层面拿不到麦克风 TCC） | **本任务新增** app:`硬约束 6：Info.plist 不含麦克风 / 摄像头 / 语音识别用途说明（拿不到音频 TCC）` | **本任务补了自检** |
| 不存视频 | `CaptureController` 按需截图：一张图只算 dHash + 32×32 网格亮度差随即丢弃；schema 里没有图像列（只有 `sha256` 一个 BLOB） | 只有代码审查 + schema 审查 | **只有代码审查** |
| **默认不上传 · 更新检查** | `Updater.swift` + `Info.plist` | **本任务新增** app:`硬约束 6：更新检查默认关、更新源是 https` | **本任务补了自检** |
| 默认不上传 · 同步 | `SyncController.Key.enabled`（默认关） | app 参数快照打印 `开关 sync.enabled`；README 12.3 | **只有代码审查** |
| 例外 ① 线上模型（D20） | — | 用户指示**暂不接**，代码里没有线上提供方 | 不适用（未实现） |
| 例外 ② iCloud 加密同步段（D17） | `core/Sources/BrosisSync`、`app/Sources/brosis/SyncController.swift` | core:`SyncTests` 全组；app:`段文件里没有明文（AES-256-GCM）`、`口令错误不加入`、`篡改一字节：校验失败即停`、`D16：同步目录不能是数据目录` 等 14 项 | 有测试 + 有自检 |
| 「所有外发开关关闭时进程零网络请求」（2.4 隐私行） | — | **没有**自动化验证 | **缺（见 §5.2）** |

### 硬约束 7：数据目录 0700、排除 TM / Spotlight；库不进 iCloud

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 0700 | `core/Sources/BrosisCore/DataDirectory.swift` | core:`testDirectoryFlags`；app:`数据目录 0700` | 有测试 + 有自检 |
| 排除 Spotlight / Time Machine | 同上 | core:`testDirectoryFlags`；app:`排除 Spotlight / Time Machine` | 有测试 + 有自检 |
| 库不放 iCloud / 同步盘（D16） | `DataDirectory.validate` | core:`testRejectsSyncedDirectories`、`testDatabaseStillRejectedInSyncFolder`；app:`D16：同步目录不能是数据目录` | 有测试 + 有自检 |
| 只有同步段文件可以放 iCloud | `SyncController.defaultDirectory` | app:`出站：1 个段文件、1 条观察`、`段文件里没有明文（AES-256-GCM）`、`入站：B 导入 A 的观察并查得到、正文逐字节一致`；同一组自检还打印一行 `默认同步目录：iCloud Drive/brosis-sync/（UserDefaults 键 sync.directory…）` | 有自检 |

### 硬约束 8：自包含

| 子条 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| SQLite / SQLCipher 编进 app | `core/Sources/CBrosisSQLite`（SQLCipher 4.18.0）与 `CSqliteVec`（清单 `core/Package.swift` 的 systemLibrary/target，源码随包） | app:`SQLCipher 已链接：cipher 4.18.0 community / commoncrypto，SQLite 3.53.4`、`schema v4：… sqlite-vec v0.1.9，已注册 true` | 有自检 |
| 推理运行时编进 app | `BrosisModels`（mlx-swift 静态）+ `build_app.sh` 现编 `mlx.metallib` | app:`Metal 着色器库在位、GPU 真能算`；build:`4c 从 bundle 里跑 brosis-embed env` | 有自检 |
| **不依赖 Python / 外部服务** | 全仓库 | **本任务新增** app:`硬约束 5 / 8：主二进制直接链接的 51 个库…（无私有框架 / 无 Homebrew / 无 Python）` | **本任务补了自检** |
| app 不含模型、默认不下载 | `app/Sources/BrosisModels/ModelStore.swift`、`catalog.json` | app:`未安装嵌入模型时功能显示为「未启用」`、`模型目录默认在数据目录旁的 models/`、`清单里有两个已批准的模型` | 有自检 |
| 固定版本与哈希 | `catalog.json` + `BrosisModels/ModelStore.swift` 导入校验 | app:`清单项没有文件列表时导入被拒`、`模型清单随包读得到`；哈希校验本身的实测在 `m2_c_vectors_2026-09-08.md`（619 MiB 导入） | 有自检（哈希那一条只有实测记录） |
| OCR 用系统 Vision | `app/Sources/brosis/OCR/ViewportOCR.swift` | app:`视口 OCR 冒烟：… 组自绘图像`、`视口 OCR 端到端：自绘屏幕` | 有自检 |

---

## 5. 补了哪三条、没补哪些、为什么

### 5.1 补了三条（上限 5，用了 3）

1. **硬约束 6「不录音频」** → `Info.plist` 里没有 `NSMicrophoneUsageDescription` /
   `NSCameraUsageDescription` / `NSSpeechRecognitionUsageDescription`。
   选这个判据是因为它**可核对且是系统层面的**：macOS 上没有这几个键的 app 拿不到麦克风 TCC，
   比"代码里没写 `AVAudioEngine`"强。
2. **硬约束 5「只依赖公开 API」+ 8「不依赖 Python」** → 运行时读本进程主二进制的
   `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB`（等价 `otool -L`），
   断言 51 个直接依赖全在 `/System/Library/Frameworks/` `/usr/lib/` `@rpath/` 里，
   没有 `/PrivateFrameworks/`、`/opt`、`/usr/local`、Python。
   只看**直接**依赖：AppKit 自己会拉私有框架，那不是我们的选择。
3. **硬约束 6「默认不上传」的可自动化部分** → `SUEnableAutomaticChecks` /
   `SUAutomaticallyUpdate` 都是 `false`、`SUFeedURL` 是 https。更新检查也是一次出网。

### 5.2 没补的，以及为什么

| 缺口 | 为什么本轮不补 |
|---|---|
| 「所有外发开关关闭时进程零网络请求」（2.4 隐私行 / 硬约束 6） | 要真机长跑 + 网络监控（`nettop` / `tcpdump` / Little Snitch 之类），且必须在**用户在场**的解锁会话里跑几十分钟才有意义。自检里做不了，也不该在自检里起网络。**建议**：跟 14 天真机试用一起做，用 `nettop -p <pid>` 计数。 |
| `SCContentFilter` 排除真的生效 | 要真截图 + 真有窗口的应用；屏幕锁定下没有可截的内容，而且会触发屏幕录制 TCC。留给 GUI 验证清单。 |
| 安全输入触发器 | `IsSecureEventInputEnabled()` 的真值要有 app 真的开了 secure input（密码框 / 终端），无人值守下造不出来。 |
| 菜单栏可见状态、SMAppService 注册 | 纯 GUI，本批约定不启动 GUI。 |
| 「不存视频」 | 只能靠代码审查 + schema 审查（没有图像列、按需截图算完 dHash 就丢）。能想到的自动化判据（扫二进制找 `AVAssetWriter` 符号）会被 Swift 运行时的传递依赖污染，假阳性太多，不如如实写"只有代码审查"。 |
| 不可共享窗口的「已明确纳入的应用可覆盖」 | **功能没实现**，不是缺测试。要覆盖 `sharingType = .none` 需要另一条采集路径（AX 或窗口列表），是一次独立的设计决定，应当先在计划里定。 |
| 签名身份跨版本不变（D13） | 跨版本的事实，单次构建证明不了；证据在 `dist/RELEASE.md` 与发布流程里。 |
| 按下热键的端到端 | 不能在无人值守会话里模拟按键——用 `CGEvent` 合成正是我们不想申请的那类权限。留给 GUI 验证。 |
| Focus 联动的真机验证 | 本机没有完全磁盘访问，探针恒为 `unavailable`。要验证需要用户手动把 brosis 加进「完全磁盘访问」再开一个 Focus。 |

---

## 6. 主会话要接的两处（本任务**没改** `AppDelegate.swift`）

`applicationDidFinishLaunching(_:)` 里、`lock` 建好之后：

```swift
focus = FocusMonitor()                       // 存一个 private var focus: FocusMonitor?
focus?.install(lock: lock, recorder: recorder)

HotKeys.shared.install(recorder: recorder,
                       onPause: { [weak lock] in lock?.togglePause() },
                       onLock:  { [weak lock] in lock?.lockNow() })
```

`refreshMenu()` 里（权限那两行附近）：

```swift
menu.addItem(disabledItem(focus?.menuDescription ?? "Focus 联动：未启动"))
menu.addItem(disabledItem(HotKeys.shared.menuDescription))
```

`applicationWillTerminate` 里可选 `HotKeys.shared.uninstall()`（不调也不会漏到别的进程）。

**章节号**：写这份结果文件时 T15 与 T16 并行写作，`app/README.md` 里都用了「## 15.」。
收尾修复已经统一重排：**T15 = 第 15 节、T16 = 第 16 节、T18 = 第 17 节**（本文件对应第 17 节），
内部引用一并改过。

**接线状态**：上面这两段代码主会话已经加进 `AppDelegate.swift` 了（`applicationDidFinishLaunching`
里三处 + `refreshMenu()` 两行 + `applicationWillTerminate` 一行）。

---

## 6.5 顺带发现的一个**发布阻断级**问题（不是本任务引入，本任务也没改）

清 scratch（按纪律删掉 `arm64-apple-macosx`）之后再跑一次自检，**崩了**：

```
BrosisModels/resource_bundle_accessor.swift:12: Fatal error: could not load resource bundle:
from <SCRATCH>/brosis.app/brosis_BrosisModels.bundle
or   <SCRATCH>/arm64-apple-macosx/release/brosis_BrosisModels.bundle
```

SwiftPM 为 `BrosisModels` 生成的访问器**只看两个地方**（原文在
`<任一旧 scratch>/arm64-apple-macosx/release/BrosisModels.build/DerivedSources/resource_bundle_accessor.swift`）：

```swift
let mainPath  = Bundle.main.bundleURL.appendingPathComponent("brosis_BrosisModels.bundle").path
let buildPath = "<编译时的绝对构建目录>/brosis_BrosisModels.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { Swift.fatalError(...) }
```

而 `build_app.sh` 把资源 bundle 拷进的是 **`Contents/Resources/`**——
`Bundle.main.bundleURL` 对 `.app` 来说是 `brosis.app/` 本身，**不是** `Contents/Resources`。
于是：

| 状态 | 结果 |
|---|---|
| 构建机、构建目录还在 | 走 `buildPath` 兜底 → 正常（所以一直没被发现，`build_app.sh` 第 4c 步也照样绿） |
| **删掉构建目录**（或换一台机器 / 用户装 DMG） | `Bundle.module` 直接 `fatalError` |

**三步复现**（本任务实跑过，见 §3.3 之后的记录）：

```bash
S="$HOME/Library/Caches/brosis-build/m2-focus-app"
rm -rf "$S/arm64-apple-macosx"
"$S/brosis.app/Contents/MacOS/brosis" --self-check      # → fatalError
mkdir -p "$S/arm64-apple-macosx/release"
cp -R "$S/brosis.app/Contents/Resources/brosis_BrosisModels.bundle" "$S/arm64-apple-macosx/release/"
"$S/brosis.app/Contents/MacOS/brosis" --self-check      # → 自检通过（172 项）
```

**影响面**：凡是碰 `BrosisModels` 的 `Bundle.module` 的路径——模型清单、「模型」面板、
夜间嵌入任务、夜间叙述、MCP 检索的查询嵌入器、`brosis-embed`——在用户机器上会当场崩。
`swift-transformers_Hub.bundle`（tokenizer 配置）同理，而且它是第三方目标，改不了源码。

**当时不在本任务范围内**（属于 c 批 T11 的打包路径），已在 **d 批收尾修复**里做掉，
走的是当时列的 ② + ③（① 被否：`.app` 根目录下放东西过不了 `codesign`）：
`ModelResources` 自己按目录顺序找、`Bundle.module` 只在确认不会 fatalError 时才碰；
`build_app.sh` 第 4d 步把构建目录临时改名再跑一遍自检与 `brosis-embed`。
细节、复现与变异检验见 `tools/bench/results/m2_d_fix_2026-09-08.md` 第 1 节。

**对本任务数字的影响**：§3 的 172 项是在 `build_app.sh` 刚跑完（构建目录还在）时测的。
修复之后同样是 **172 项全过**，而且是在**构建目录改名**、`.app` 拷到无关目录的状态下测的
（`m2_d_fix_2026-09-08.md` §1.4）。验收者按 §2 的顺序跑即可。

---

## 7. 未做与原因（本任务范围内）

- **设置界面**：暂停名单与热键只有 `UserDefaults`，没有面板。产品化时进「设置」窗口，
  热键那一格还需要一个"录制组合"的控件（要在 GUI 里做）。
- **按 Focus 分档采集**（例如"工作模式只记事件"）：本轮只有"暂停 / 不暂停"两态。
  三档联动要和 3.12 的解析优先级合并，是另一次设计。
- **Focus 变化的推送式感知**：只有轮询。系统没有公开通知；文件监视（`DispatchSource` /
  FSEvents）在读不到目录的前提下也建立不起来。
- **热键冲突的跨进程检测**：Carbon 做不到（见 §3.2）。能做的上限是"注册返回值 + 事件 + 菜单"。

---

## 8. 对计划的影响（一句话）

4.2「暂停触发器……热键」与 3.5「显式锁定（菜单 / 热键）」可以划掉；4.1 M0 表里
「Focus 状态 JSON 是否可用」的答案是**本机不可用（TCC 完全磁盘访问，EPERM，不弹窗）**，
4.5 的「Focus 联动」代码已就位但要用户手动授予完全磁盘访问才生效；
4.2 验收里「2.2 硬约束逐条有测试记录」由本文第 4 节的表兑现，
表里还剩 §5.2 那八个缺口（其中「不可共享窗口可覆盖」是功能未做，其余要 GUI / 真机 / 网络监控）。
