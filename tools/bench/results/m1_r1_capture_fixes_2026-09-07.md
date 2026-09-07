# M1 R1 · T1 采集端按 M0 实测数据修正

- 日期：2026-09-07
- 对应：`tools/bench/results/m0_closeout_2026-09-07.md` 第 4 节 A 组第 **1、4、5** 条（数字出处是该报告 2.2 / 2.3）；`docs/实施计划.md` 3.3
- 改动范围：**只有 `app/`**，4 个 `.swift` + `app/README.md`，没动 `docs/`、没动别的目录、没有 git 提交
- 机器：M4 Air（16 GiB / 无风扇），macOS 26.6，Xcode 26.6 / Swift 6.3.3（语言模式 v6）。
  `xcode-select` 指向 CommandLineTools，所以**所有** `swift build` / `xcrun` / `build_app.sh` 都加前缀
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；本轮**没有** `sudo`、**没有**改 `xcode-select`
- 产物与原始输出：`~/Library/Caches/brosis-build/m1-capture/`（SwiftPM scratch + `brosis.app`），
  原始输出在 `~/Library/Caches/brosis-build/m1-capture/results/`：
  `build_app.txt`（构建 + 签名七步）、`selfcheck.txt`（自检全文）、`periodic_interval.txt`（兜底间隔覆盖矩阵）、
  `clean_build.txt`（空 scratch 从零构建）、`framework_probe.txt`（Claude / 飞书 的 Frameworks 目录）。
  **项目目录里没有落任何构建产物**（`find` 查过 `.build` / `DerivedData` / `__pycache__` / `*.pyc` / `.swiftpm`，为空）
- 本轮**未启动 GUI、未触发任何 TCC 弹窗**：验证只用 `swift build`、`build_app.sh`、`--self-check` 与命令行

---

## 1. 做了什么

| # | 改动 | 文件 | M0 依据 |
|---|---|---|---|
| 1 | Chromium / Electron **通用检测**（显式清单之外加一路框架检测），命中就设 `AXManualAccessibility`，结果按 bundle id 缓存并写 `runtime_events` | `AXSupport.swift`、`EventSkeleton.swift` | 2.2：Claude 桌面版 74 条观察、AX 正文 **0 字符** |
| 2 | 定时兜底间隔 **5 s → 12 s**（`UserDefaults` 可覆盖，下限 3 s）+ **「刚因为事件截过图就跳过本次兜底」** | `CaptureController.swift` | 2.3：`periodic` 截图 129 张里 **111 张（86%）被门控**，平均变化面积 0.73% |
| 3 | AX BFS **按 bundle id 的限额表**（默认不变；`com.apple.finder` 400 节点 / 6 层），命中限额写 `runtime_events` | `AXSupport.swift`、`EventSkeleton.swift` | 2.2：访达 41 条观察里 9 条（**22%**）0.5 s 超时 |
| 4 | 自检加 **2 项 Electron 检测**（伪造 `.app` 正反两例）+ 打印真实应用探测与关键参数 | `SelfCheck.swift` | 任务要求；不触发任何 TCC |
| 5 | README 第 4 节自检项数 13 → **15**；第 8 节补通用检测与兜底间隔 | `app/README.md` | — |

### 1.1 Electron / CEF 通用检测

两路判定，命中任意一路就在读树前设 `AXManualAccessibility`：

| 路 | 依据 | `detection` |
|---|---|---|
| 1 | 显式清单 `AXSupport.chromiumFamilyBundleIDs`（本轮把 `com.anthropic.claudefordesktop` 加了进去） | `list` |
| 2 | `NSRunningApplication.bundleURL` 的 `Contents/Frameworks/` 下有 `Electron Framework.framework` 或 `Chromium Embedded Framework.framework` | `framework` |
| — | 两路都没命中 | `none` |

- 检测函数 `AX.bundleContainsElectronFramework(at:)` **只做 `FileManager.fileExists`**：不发 AX 消息、
  不需要辅助功能权限、不启动被检测的应用，所以 `--self-check` 可以直接调用它做断言。
- 结果**按 bundle id 缓存**（`AX.DetectionCache`，`NSLock` 保护，文件系统探测在锁外做）。
  缓存同时决定要不要写事件：**每个 bundle id 只在第一次判定时**写一条
  `runtime_events(kind='ax_manual_accessibility')`，detail 形如
  `bundle=<id> detection=list|framework|none set=ok|failed|skipped AXError=<n>`。
  不这么控频的话，M0 那种 50 分钟 104 次 `app_activated` 的节奏会把 `runtime_events` 刷满。

### 1.2 定时兜底 12 s + 跳过「刚截过」

| 项 | 值 | 代码 |
|---|---|---|
| 默认间隔 | **12 s** | `CaptureController.periodicIntervalDefault` |
| 覆盖 | `UserDefaults` 键 `capture.periodicInterval` | `capture.periodicInterval` |
| 下限 | **3 s**（低于它夹到 3 s） | `periodicIntervalMinimum` |
| 非法值（≤ 0 / 非数字） | 回落默认 12 s | `resolvePeriodicInterval` |
| 来源标记 | `default` / `defaults` / `defaults_clamped` / `defaults_invalid`，写进 `capture_armed` 的 detail | `periodicIntervalSource` |

跳过规则：定时兜底触发时，若距最近一次**非纯定时**截图（事件触发、`armed`、`queued`）不足一个兜底间隔，
本次兜底不截，只累加 `stats.skippedRecent`；该计数与原有的锁屏 / 安全输入 / 空闲跳过一起出现在
`capture_progress`（每 50 张）与 `capture_disarmed` 的 detail 里：
`…跳过 锁屏 a / 安全输入 b / 空闲 c / 刚截过 d`。
合并后的 `trigger` 只要不是纯 `periodic`（例如 `app_activated+periodic`）就算事件触发。

### 1.3 访达 BFS 限额

`AXSupport.bfsLimitsByBundleID`，**默认值一个字没改**（1500 节点 / 12 层），目前只有一条：
`com.apple.finder` → **400 节点 / 6 层**。同一份限额也管窗口 URL 搜索那趟 `AXWebArea` BFS
（节点取 `min(400, maxNodes)`，深度用同一个上限）——访达永远搜不到 `AXWebArea`，
这趟 BFS 在 M0 里是每条观察都白跑一遍的。

**命中限额记进 `runtime_events`，不动 `ax_texts.completeness`**（任务给的二选一，选前者），两条理由：

1. `completeness` 是计划 3.2 的固定枚举（`complete` / `partial` / `unavailable` / `excluded`），
   M0 阶段还只是「非空 = partial」的占位值。为「这次没遍历完」新增一个取值，M1 收敛到
   `tools/proto/schema.sql` 的 v1 schema 时要再改一次口径，得不偿失；
2. 一次遍历会写 **4 行** `ax_texts`（四个文本角色共享同一次 BFS），把「这次被限额截断了」这一个事实
   重复四遍没有意义。

事件形如 `kind='ax_bfs_limit_hit'`、
`detail='bundle=com.apple.finder limits=nodes=400 depth=6 visited=400 hit=node+depth count=<n>'`，
频次沿用已有的 `ax_element_notifications_throttled` 写法：每个 bundle id 第一次写，之后每 50 次写一条。
`hit=depth` 的判定是「有元素被取出时深度已达上限」，**故意不去取它的 children 来确认**——
为记一个标志位多发一轮 AX 消息，与这条改动的目的（减少访达上的 AX 开销）背道而驰。

### 1.4 自检

原有 13 项一项没动、全部仍然 PASS；新增 2 项：在临时目录 `mkdir` 出两个假 `.app`
（一个带 `Contents/Frameworks/Electron Framework.framework`、一个只有空的 `Contents/Frameworks/`），
断言检测函数分别返回 `true` / `false`，跑完删掉临时目录。
另外**打印**（不参与通过判定，因为各机器装的应用不同）`/Applications` 下 Claude / 飞书的真实探测结果，
以及定时兜底间隔与 AX BFS 限额——这样不跑 GUI 也能核对参数。

---

## 2. 怎么跑（可复制粘贴）

```bash
P="<项目目录>"                       # 例如 ~/…/brosis
S=~/Library/Caches/brosis-build/m1-capture
mkdir -p "$S/results"

# ① 构建 + 组装 + Developer ID 签名 + 验证（钥匙串里自动探测身份；不装到 /Applications、不启动）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SCRATCH="$S" \
  "$P/app/build_app.sh" 2>&1 | tee "$S/results/build_app.txt"

# ② 自检（不触发任何 TCC 弹窗）
"$S/brosis.app/Contents/MacOS/brosis" --self-check | tee "$S/results/selfcheck.txt"
echo "exit=$?"

# ③ 兜底间隔覆盖矩阵（用 NSArgumentDomain，不落任何持久化偏好）
B="$S/brosis.app/Contents/MacOS/brosis"
"$B" --self-check                              | grep 定时兜底   # 12.0 s / default
"$B" --self-check -capture.periodicInterval 5  | grep 定时兜底   # 5.0 s  / defaults
"$B" --self-check -capture.periodicInterval 1  | grep 定时兜底   # 3.0 s  / defaults_clamped（夹到下限）
"$B" --self-check -capture.periodicInterval 0  | grep 定时兜底   # 12.0 s / defaults_invalid

# ④ 零警告复核（空 scratch 从零构建）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$P/app" \
  --scratch-path ~/Library/Caches/brosis-build/m1-capture-clean -c release 2>&1 \
  | tee "$S/results/clean_build.txt" | grep -ci "warning:" || echo "0 条警告"

# ⑤ 项目目录不该有构建产物
cd "$P" && find . -name .build -o -name DerivedData -o -name __pycache__ \
  -o -name '*.pyc' -o -name .swiftpm | grep -v '^./.git/'   # 期望无输出
```

持久化覆盖写法（会写用户偏好，验完记得删）：

```bash
defaults write com.brosis.app capture.periodicInterval -float 8
defaults delete com.brosis.app capture.periodicInterval
```

---

## 3. 实测数字

### 3.1 构建与签名（`results/build_app.txt`，退出码 0）

| 项 | 值 |
|---|---|
| 编译 | `swift build -c release` **零 error、零 warning**；空 scratch 从零构建耗时 **5.65 s**（`clean_build.txt`，`grep -c "warning:"` = **0**） |
| 二进制 | **433,992 字节** |
| bundle 内容 | 6 个文件：`MacOS/brosis`、`Resources/exclusions.txt`、`Resources/AppIcon.icns`、`Library/LaunchAgents/com.brosis.agent.plist`、`Info.plist`、`PkgInfo`；Info.plist 六个必备键齐全 |
| 签名 | `<Developer ID Application 身份>`，hardened runtime，带 Apple 安全时间戳；`codesign --verify --deep --strict` → `valid on disk` + `satisfies its Designated Requirement` |
| entitlements | `com.apple.security.app-sandbox = false`、`com.apple.security.automation.apple-events = true`（与改动前一致） |
| `spctl` | `rejected / source=Unnotarized Developer ID`——**符合预期**，公证是 E9 的事 |

### 3.2 自检（`results/selfcheck.txt`，退出码 **0**）

**15 项全 PASS**（原有 13 + 新增 2）：

```
[PASS] Electron 检测（伪造带框架的 .app）：WithElectron.app/Contents/Frameworks/Electron Framework.framework → true（期望 true）
[PASS] Electron 检测（伪造不带框架的 .app）：NativeApp.app/Contents/Frameworks/（空目录） → false（期望 false）
       Claude 桌面版：bundle=com.anthropic.claudefordesktop 依据=list 框架检测=true（未启动，仅读目录）
       飞书 Lark：bundle=com.bytedance.macos.feishu 依据=list 框架检测=false（未启动，仅读目录）
定时兜底间隔：12.0 s（来源 default，默认 12.0 s，下限 3.0 s，UserDefaults 键 capture.periodicInterval）
AX BFS 限额：默认 nodes=1500 depth=12；com.apple.finder nodes=400 depth=6
```

原有 13 项的输出与改动前逐字一致（自检库路径、库分离、SQLite **3.51.0**、`journal_mode=wal`、
`foreign_keys=1`、5 张表、observations rowid=1、ax_texts 2 行、unavailable 1 行、
dHash 稳定 `aaa9a0b382cf8693`、不同图汉明距离 **44 bit**、frame_stats 3 行、排除清单 8 个 bundle id
来自 `Contents/Resources/exclusions.txt`）。

### 3.3 通用检测对两个真实应用的结果（`results/framework_probe.txt`）

| 应用 | bundle id | `Contents/Frameworks/` 里 | 通用框架检测 | 最终 `detection` |
|---|---|---|---|---|
| Claude 桌面版 | `com.anthropic.claudefordesktop` | **`Electron Framework.framework`** | **true** | `list`（本轮已加进显式清单，两路都能命中） |
| 飞书 | `com.bytedance.macos.feishu` | `Lark Framework.framework`（**改了名**） | **false** | `list`（只能靠显式清单兜底） |

**这是本轮最值得记下来的一条负面结果**：飞书把 Electron 框架重命名成 `Lark Framework.framework`，
按名字匹配的通用检测**抓不到它**。它确实是 Chromium 内核——同一目录的 `Resources/` 里有
`chrome_100_percent.pak`、`chrome_200_percent.pak`、`resources.pak`、`icudtl.dat`。
所以**显式清单不能删**，通用检测只是补漏（对 Claude 这种"没人往清单里加"的新应用有效）。

### 3.4 兜底间隔覆盖矩阵（`results/periodic_interval.txt`）

| 输入 | 实测间隔 | `periodic_source` |
|---|---|---|
| 不设 | **12.0 s** | `default` |
| `-capture.periodicInterval 5` | **5.0 s** | `defaults` |
| `-capture.periodicInterval 1` | **3.0 s**（夹到下限） | `defaults_clamped` |
| `-capture.periodicInterval 0` | 12.0 s | `defaults_invalid` |
| `-capture.periodicInterval abc` | 12.0 s | `defaults_invalid` |
| `defaults write com.brosis.app capture.periodicInterval -float 8` | **8.0 s** | `defaults` |
| 上一行 `defaults delete` 之后 | 12.0 s | `default`（域已删除，`defaults read com.brosis.app` 报 `does not exist`） |

### 3.5 按 M0 数据推算的预期效果（**推算，不是实测**）

M0 的 11.8 分钟窗口：`periodic` 129 张（门控 111 张 / 86%）+ 事件触发 50 张 = 179 张。

- 只把间隔 5 s → 12 s：兜底张数按比例约 129 × 5/12 ≈ **54 张**，总量 179 → 约 **104 张（−42%）**；
- 再叠加「刚截过就跳过」：事件触发那 50 张各自会盖住其后一个 12 s 窗口，兜底还会更少。
  具体降到多少**必须实跑才有数**，本轮没有这个数字（见第 4 节）。

---

## 4. 未做与原因

1. **没有 GUI 实跑，所以三类运行时数字都拿不到**：`skippedRecent` 的真实计数、
   `ax_manual_accessibility` / `ax_bfs_limit_hit` 两种事件的真实写入、以及 Claude 桌面版设上
   `AXManualAccessibility` 之后 AX 正文是不是真的从 0 变成非 0。
   原因：这些都要求 app 从 Finder 启动、拿到辅助功能 + 屏幕录制授权，**会触发 TCC 弹窗**，本任务明确禁止。
   验收方式只能是：把 `brosis.app` 装到 `/Applications` 后由人手动跑一段，再查
   `SELECT kind, detail FROM runtime_events WHERE kind IN ('ax_manual_accessibility','ax_bfs_limit_hit','capture_armed','capture_progress');`
   与按应用分组的 `ax_texts` 字符数（口径同 `m0_closeout` 2.2）。
2. **访达 22% 超时没有「修好了」的证据**，本轮只是把开销降下来。口径要说清楚：那 22% 的
   `source_state='timeout'` 发生在 `kAXFocusedWindow` **那一次调用**上，BFS 限额改的是同一条路径上
   后续遍历的开销（含每条观察都白跑的 `AXWebArea` 搜索），**不直接决定那一次调用会不会超时**。
   400 / 6 这两个数是按「访达的正文在窗口前几层」拍的，需要授权后跑一段访达再和 M0 的 22% 对比才算数。
3. **通用检测只按框架目录名匹配**，改了名的（飞书）抓不到。想抓要改成看框架里有没有
   `chrome_*.pak` / `icudtl.dat`，那是「读别人 app 内部文件」的启发式，误判代价与维护成本都更高，
   本轮不做；显式清单继续保留就够用。
4. **没有加 `completeness = complete` 的判定**（`m0_closeout` A 组第 6 条）、
   没有动 `app_deactivated` 是否降为纯事件（A 组第 7 条）、没有做飞书 / 微信适配器（A 组第 2、3 条）。
   都超出 T1 范围，且第 2、3 条按 M0 收口结论要等 09-09 的 D2 正式清单。
5. **没有 git 提交**（按约定由主会话统一提交）；**没有装到 `/Applications`**、没有启动过 `brosis.app` 的图形界面。

---

## 5. 对计划的影响

一句话：**`m0_closeout` 第 4 节 A 组的第 1、4、5 条在代码层面已经落地并可编译可自检，但它们的效果数字
（Claude AX 覆盖率、访达超时率、截图张数下降）仍然是空的——M1 第一次真人授权跑机时必须补这三组对照，
在此之前 E5 的适配器名单不要按"Claude 已修好"来排。**
