# M1 R1 · T4 采集端接入加密存储核心（app/ → core/）

> **本文件是 R1 验收复核后的修订版**（同日第二遍）。第一遍验收未通过，问题与逐条修法见 **1.3**；
> 第 3 节的所有数字都是**修完之后重新跑出来的**，出处指向本轮新的原始输出，不是上一遍的。

- 日期：2026-09-07
- 对应：`docs/实施计划.md` 4.2.1 的 **R1 / T4**；口径出自 **2.2 硬约束 1–3 与 7**、**3.3**、**3.5**、**3.12**、**4.2**
- 依赖：T1（`tools/bench/results/m1_r1_capture_fixes_2026-09-07.md`）、T2（`tools/bench/results/m1_r1_core_store_2026-09-07.md`）
- 改动范围：**只有 `app/`**——`Package.swift`、`Resources/exclusions.txt`、`README.md`、
  13 个 `.swift`（新增 4、改写 8、删除 1）。**没动 `docs/`、没动 `core/`、没有 git 提交**
- 机器：M4 Air（16 GiB / 无风扇），macOS 26.6，Xcode 26.6 / Swift 6.3.3（语言模式 v6，严格并发）。
  `xcode-select` 指向 CommandLineTools，所以**所有** `swift build` / `build_app.sh` 都加前缀
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；本轮**没有** `sudo`、**没有**改 `xcode-select`
- 产物与原始输出：`~/Library/Caches/brosis-build/m1-app/`（SwiftPM scratch + `brosis.app`），
  原始输出在 `~/Library/Caches/brosis-build/m1-app/results/`：
  `build_app.txt`（构建 + 签名七步）、`selfcheck.txt`（自检全文 38 项）、
  `dump_vectors.txt`（脱敏 / 三档 / 状态机 / 补做 / 内置清单六节判定表）、
  `clean_build.txt`（空 scratch 从零构建 + `/usr/bin/time -l`）、`selfcheck_time.txt`（自检 3 次计时与内存）、
  **`sizes.txt`（`stat` / `du` 的原始输出——3.1 里每个体积数字的出处）**。
  **项目目录里没有落任何构建产物**（`find` 查过 `.build` / `DerivedData` / `__pycache__` / `*.pyc` /
  `.swiftpm`，为空；`app/` 下也没有生成 `Package.resolved`——纯路径依赖不需要解析）
- 单位：**MiB = 2²⁰、GiB = 2³⁰**；内存看 `/usr/bin/time -l` 的 `peak memory footprint`
- 本轮**未启动 GUI、未触发任何 TCC 弹窗、未碰钥匙串**：验证只用 `swift build`、`build_app.sh`、
  `--self-check`、`--dump-vectors`

---

## 1. 做了什么

| # | 项 | 文件 | 计划出处 |
|---|---|---|---|
| 1 | `app` 依赖 `../core`；**删掉 M0 明文 `Store.swift`**，四张表全部搬进 core | `Package.swift`、`Recorder.swift`（新） | 3.1「单一存储服务持钥」、评审 F1 |
| 2 | **AX 正文本身入库** `text_versions` / `occurrences`，`region` = AX 角色 | `AXSupport.swift`、`EventSkeleton.swift` | 3.2 / 3.3；M0 只存统计 |
| 3 | **钥匙串取钥**（`KeychainKeyProvider`）接进 `unlocking` 第一步 | `LockController.swift`（新） | 3.5 / D25 |
| 4 | **3.5 锁定状态机**：`locked → unlocking → unlocked → locking` + `paused` 子状态，纯函数 `LockPolicy` + 21 条转移用例 + 7 条补做用例 | `LockController.swift` | 3.5 |
| 5 | **3.12 三档采集策略数据层**（**只插不改** + 库没开只给临时判定）+ 内置默认不采集清单（25 个 bundle id）+ 菜单快捷暂停（今天 / 永久） | `CapturePolicy.swift`（新）、`Resources/exclusions.txt`、`AppDelegate.swift` | 3.12 |
| 6 | **入库前规则脱敏**：8 条规则（gitleaks 子集 + Luhn 卡号 + 验证码启发式），**正文 + 窗口标题 + URL + 文件路径**四样都过，33 条测试向量 | `Redaction.swift`（新）、`EventSkeleton.swift` | 2.2 硬约束 2、4.2 |
| 7 | 暂停触发器加**屏保**（分布式通知）与**私密浏览**（尽力；命中时正文 / 标题 / URL / 路径都不存） | `LockController.swift`、`CapturePolicy.swift`、`EventSkeleton.swift` | 4.2 |
| 8 | 自检从 15 项扩到 **38 项**；新增 `--dump-vectors` 判定表转储（六节） | `SelfCheck.swift` | 任务要求 |
| 9 | 菜单栏状态改成 **录制 / 暂停 / 锁定 / 权限缺失**，一键暂停保留，加「锁定 / 解锁数据库」 | `AppDelegate.swift` | 2.2 硬约束 2–3 |
| 10 | README 全面重写并按 1.3 的六处修订同步 | `app/README.md` | — |

### 1.1 M0 四张表的去向

| M0 明文库 | M1 加密库（core） | 说明 |
|---|---|---|
| `observations` | `observations` + `apps` / `windows` / `urls` / `files` | 规范化对象拆开；`ts` 从 Unix 秒（REAL）改成 Unix **毫秒**（INTEGER） |
| `ax_texts`（角色 / 节点数 / 字符数） | `text_versions` + `occurrences` | **正文本身入库**，`region` = AX 角色，`ord` = 角色顺序 |
| `frame_stats` | `capture_stats` | 列一一对应，`status` 多了 `skipped` / `ax` / `private_browsing` |
| `runtime_events` | `jobs`（`type = 'runtime_event:<kind>'`） | core 提供的事件表，**54 种 kind** 分八组列在 `app/README.md` 第 9 节 |

**M0 库 `~/Library/Application Support/brosis-m0/` 一个字节都没动，也不迁移**：schema 与 v1 差得太远，
迁移的收益抵不上污染 v1 库的风险。新数据目录默认 `~/Library/Application Support/brosis/`
（D16，UserDefaults 键 `data.directory` 可改；写成同步盘会被 `DataDirectory.validate` 拒绝、开库失败并在菜单里报错，不静默降级）。

### 1.2 三处"没照抄 M0"的设计取舍

1. **系统级事件不再写 `observations`，只写运行期事件**。schema 的 `trigger` 有 CHECK，七个取值里
   没有"睡眠 / 锁屏"，硬塞成 `manual` 会让台账把它们当成一次用户主动记录。采集端细分的
   `ObservationTrigger` 通过 `coreTrigger` 收敛（应用激活/失活 → `app_switch`，焦点窗口/标题 →
   `window_change`，焦点元素 → `ax_notification`），细分值保留在 `capture_stats."trigger"` 与事件 kind 里。
   **时间轴上的空档要 T3 结合运行期事件补**——这条口径请主会话转告 T3。
2. **内置不采集清单从"文件覆盖代码"改成"文件 ∪ 代码"**。覆盖语义在这里是错的：
   用户往 `exclusions.txt` 里加一个自己的应用，不该把密码管理器整类默默放开。
3. **同一 AX 角色的多个节点拼成一个片段**。AX 树里一段正文常被拆成几十个 `AXStaticText`，
   逐节点入库会把 `text_versions` 打成碎片、也让 bigram 检索失去上下文。
   每角色上限 20 000 字符，命中上限记 `hit=chars`，不静默截断。

### 1.3 R1 验收复核提的问题与逐条修法

| # | 严重度 | 问题 | 怎么修的 | 复测证据 |
|---|---|---|---|---|
| A | 高（验收项 4 未通过） | `CapturePolicy` 的 `pendingPersist`：库关着时 `resolve()` 读不到 `app_policies`，按"新应用"给默认档并攒起来，开库后用 `ON CONFLICT DO UPDATE` 补写，把用户设的「永久不采集」改回「事件 + 内容」 | ① 落库改成**只插不改**——先 `appPolicy(bundleID:)`，确实没有这一行才 `setAppPolicy`，两步在同一把 `dbLock` 下，绝不 UPDATE 已有行；② **库没开 / 读库失败只给临时判定**（`Resolution.provisional = true`，不缓存、不落库、不记事件）；③ 覆盖只保留一条路径：用户显式 `setMode`；④ 用户在锁定期间改的档进 `pendingUserChoices`，下次开库补写（这条不能丢） | 自检两条新断言：`用户策略经「锁定 → 解锁」往返后不变`（库里 `none/user`，解析 `none/user`）、`库没开时的判定是临时的：不缓存、不落库`（锁定期间解析过的 bundle id 没写进 `app_policies`）——`selfcheck.txt` |
| B | 中（隐私） | 私密浏览命中时 `completeness=excluded` 且不存正文，但**窗口标题、URL、文件路径照存** | 命中时这三样一律置 `nil`，只留 `app + ts + completeness=excluded`；自检文案与 `README` 8.4 同步改成"正文 / 标题 / URL / 文件路径一个都不存" | `EventSkeleton.record` 里 `if !privateBrowsing` 才构造这三个字段；自检 `私密浏览（Safari 标题含无痕标记）` 一行的 detail |
| C | 中（脱敏覆盖面） | 只有 AX 正文过 `Redactor`，窗口标题与 URL 不过（`Your verification code is …`、`?access_token=…` 会明文进 `windows` / `urls`，对 `events_only` 档同样） | `info.title` / `info.url` / `kAXDocument` 路径都过 `Redactor`，命中计进同一份 `redaction` 事件；URL 的 `kind` / `host` 仍用**原始**串判定（占位符里的 `[` `]` 会让 URL 解析失败），入库的定位串是脱敏后的；新增 3 条元数据向量 | 正例从 18 增到 **21**（标题里的验证码、URL 里的 `access_token`、标题里的卡号），`dump_vectors.txt` §1 逐条 PASS |
| D | 低（硬约束 7） | 3.1 的「可执行文件 3,650,912 字节」在任何原始输出里都找不到出处，且体积随 scratch 路径 / 签名 blob 变化，不可逐字节复现 | 3.1 改成引用 `build_app.txt` 里的**未签名**字节数，并把 `stat` / `du` 的原始输出存成 `results/sizes.txt`；同时**明写波动范围**（不同 scratch 路径 / 签名时间戳会差 ~±2 KiB），不再当成可复现常量 | 3.1 表格的"出处"列；`results/sizes.txt` |
| E | 低（README 数字） | README §9 写 46 种 kind，代码实际 52 种（漏了 `PermissionGuide` 的 6 种）；`ObservationTrigger.captureStopped` 无调用点 | kind 一览按八组重写并补齐，**现在是 54 种**（52 + 新增的 `store_unlocked`、`lock_unlock_deferred`）；删掉 `captureStopped` 这个没有生产者的枚举值 | `app/README.md` 第 9 节；`grep -rn captureStopped app/Sources` 为空 |
| F | 低（状态机健壮性） | `systemDidWake` 只在 `phase == .locked` 时生效；关库（异步 checkpoint + close）还没回调 `lockCompleted` 时到达的唤醒被丢掉，之后停在 `locked` 直到手动 ⌘L | 新增纯函数 `LockPolicy.deferredUnlock(from:on:strictScreenLock:)`：`locking` 期间到达的 `systemDidWake` / `menuUnlock` / 严格模式下的 `screenUnlocked` 记进 `pendingUnlock`，`apply` 在相位真正变成 `locked` 之后补做一次，并写 `runtime_event:lock_unlock_deferred` | 7 条纯函数用例，自检 1 项 + `dump_vectors.txt` §5 逐条 PASS |
| G | 低（事件语义） | `onUnlocked` 每次进入 `unlocked` 都写 `app_launched` + `ax_global_timeout_installed`，醒来 / 解锁后重复出现 | `app_launched` 与 `ax_global_timeout_installed` 只在本次进程**第一次**开库成功时写；之后每次解锁写 `store_unlocked` | `AppDelegate.didLogLaunch`；README 第 9 节生命周期那一组 |
| H | 设计取舍 | 系统级事件只写 `jobs` 不写 `observations`；截图时对所有运行中应用 `resolve()` 会把大量 helper bundle id 登记进 `app_policies` | 前者维持原判（理由见 1.2 第 1 条），已在 1.2 与本文件里点名请主会话转告 T3；后者**不改行为**（3.12 要求新应用要有默认档与事件），但登记改成"只插不改"，并在 README 8.6 写清楚"第二轮的清单窗口要按 `NSWorkspace` 运行记录过滤" | README 8.6 |

---

## 2. 怎么跑（可复制粘贴）

```sh
D=/Applications/Xcode.app/Contents/Developer
P=<项目目录>
S=~/Library/Caches/brosis-build/m1-app     # 复核请换成你自己的 scratch

# 0. 前置：core 的 vendor 源码（一次即可，已装过可跳过）
sh "$P/core/setup.sh"

# 1. 从零构建 + 组装 .app + Developer ID 签名 + 验证（七步）
rm -rf "$S" && mkdir -p "$S/results"
DEVELOPER_DIR=$D SCRATCH="$S" bash "$P/app/build_app.sh" > "$S/results/build_app.txt" 2>&1; echo "exit=$?"
grep -cE 'warning:' "$S/results/build_app.txt"     # 期望 0
grep -cE 'error:'   "$S/results/build_app.txt"     # 期望 0

# 2. 自检（38 项；不触发 TCC、不碰钥匙串、不创建 NSApplication）
"$S/brosis.app/Contents/MacOS/brosis" --self-check > "$S/results/selfcheck.txt" 2>&1; echo "exit=$?"
grep -c '^\[PASS\]' "$S/results/selfcheck.txt"     # 期望 38
grep -c '^\[FAIL\]' "$S/results/selfcheck.txt"     # 期望 0

# 3. 判定表逐条转储（脱敏 21 正 + 12 反 / 三档开关 / 21 条转移 / 7 条补做 / 内置清单）
"$S/brosis.app/Contents/MacOS/brosis" --dump-vectors > "$S/results/dump_vectors.txt" 2>&1
grep -c 'FAIL |' "$S/results/dump_vectors.txt"     # 期望 0

# 4. 零 warning 复核：空 scratch 从零编一遍并计时
rm -rf "$S-clean"
/usr/bin/time -l env DEVELOPER_DIR=$D swift build --package-path "$P/app" \
  --scratch-path "$S-clean" -c release > "$S/results/clean_build.txt" 2>&1
grep -cE 'warning:|error:' "$S/results/clean_build.txt"   # 期望 0
rm -rf "$S-clean"

# 5. 体积（3.1 每个数字的出处都在这个文件里）
{ stat -f '%N %z' "$S/release/brosis"; stat -f '%N %z' "$S/brosis.app/Contents/MacOS/brosis";
  du -sk "$S/brosis.app"; } > "$S/results/sizes.txt"

# 6. 项目目录没有构建产物
find "$P" \( -name .build -o -name DerivedData -o -name __pycache__ -o -name '*.pyc' -o -name .swiftpm \) -print
```

---

## 3. 实测数字（全部是本轮修完之后重新跑的）

### 3.1 构建与体积

| 项 | 实测 | 出处 |
|---|---|---|
| `build_app.sh` 七步 | 全过，退出码 **0**，warning **0**，error **0** | `results/build_app.txt` |
| 其中 `swift build` | `Build complete! (32.29s)` | `build_app.txt` 第 16 行 |
| 空 scratch 从零构建（release，单独跑一遍） | `Build complete! (31.29s)`；`/usr/bin/time -l`：**31.64 real / 34.76 user / 1.99 sys** | `results/clean_build.txt` |
| 该次构建 warning + error | **0** | `grep -cE 'warning:\|error:' clean_build.txt` |
| **未签名**可执行文件 | **3,671,704 字节 = 3.502 MiB** | `build_app.txt` 第 17 行 + `results/sizes.txt` |
| 签名后 `Contents/MacOS/brosis` | **3,669,440 字节 = 3.499 MiB** | `results/sizes.txt` |
| `brosis.app` 总体积 | **4,496 KiB = 4.391 MiB**（其中 `AppIcon.icns` 913,353 字节 = 0.871 MiB） | `results/sizes.txt`（`du -sk`） |
| 签名 | Developer ID + hardened runtime + 安全时间戳；`codesign --verify --deep --strict` 通过（身份写作 `<Developer ID Application 身份>`） | `build_app.txt` 第 4–6 步 |
| `spctl` | `rejected / source=Unnotarized Developer ID`（**预期**，公证不在本轮） | `build_app.txt` 第 7 步 |

> **体积不是可逐字节复现的常量。** 二进制里带 scratch 路径（调试信息里的绝对路径）、
> 签名 blob 里带时间戳，换一个 scratch 目录或换一次签名时间就会差 ~±2 KiB。
> 复核请对 `results/sizes.txt` 里的数量级与 `du -sk` 的 KiB 数，不要要求逐字节相同。
> （上一遍结果文件里的 3,650,912 字节没有出处，本轮已作废。）

链进来的存储核心：**SQLCipher 4.18.0 community / commoncrypto，SQLite 3.53.4**（`selfcheck.txt` 第 1 行）。

### 3.2 自检

| 项 | 实测 |
|---|---|
| 通过 / 失败 | **38 PASS / 0 FAIL**，退出码 **0** |
| 运行时间（3 次） | **0.09 / 0.06 / 0.06 s** |
| peak memory footprint（3 次） | **61.36 / 61.33 / 61.30 MiB**（64,340,640 / 64,307,872 / 64,275,080 字节） |
| 自检加密库 | 观察 1 / 文本版本 2 / 出现 2 / FTS 2 行，原文净载荷 **155 字节**，库文件 **16,384 字节**（= 一页，`cipher_page_size` 16384） |

出处：`results/selfcheck.txt`、`results/selfcheck_time.txt`。

38 项分组：core 往返 **19**、入库前脱敏 2、3.12 三档 8、3.5 状态机 **3**、私密浏览 2、dHash 2、Electron / CEF 2。
（比上一遍多 3 项：core 往返里新增"用户策略经锁定→解锁往返后不变"与"库没开时的判定是临时的"，
状态机里新增"`locking` 期间的开库触发会被补做"。）

**core 往返这一组核到的具体值**（都在 `selfcheck.txt` 里）：
`cipher_page_size = 16384`、`journal_mode = wal`、`auto_vacuum = 2`、`foreign_keys = 1`、
编译期 `TEMP_STORE = 3`（D25）、数据目录 `0700` + `.metadata_never_index` + 排除 Time Machine、
按 `ord` 读回 **98 个字符**逐字符相同、13 项悬空引用 **13/13** + `integrity_check = ok` +
`foreign_key_check = 0` + FTS `integrity-check = ok`、关库后 `SecureKey.wasZeroized && isAllZero`。

### 3.3 明文泄漏扫描（2.2 硬约束 1 + 2）

自检在 `wal_checkpoint(TRUNCATE)` 之后、关库之前，对 `brosis.db` / `-wal` / `-shm` 三个文件的**原始字节**
搜三个金丝雀：脱敏前的 `api_key` 值、脱敏前的卡号、窗口标题里的中文。

| 项 | 实测 |
|---|---|
| 扫描文件数 | **3** |
| 命中 | **0** |
| 阳性对照（同一扫描器扫一个明文文件） | **3/3 命中** |

阳性对照是必须的——不然"什么都没搜到"可能只是扫描器坏了。

### 3.4 入库前脱敏

| 项 | 实测 | 出处 |
|---|---|---|
| 规则条数 | **8** | `dump_vectors.txt` §1–2 |
| 正例 | **21 条，全部 PASS**（要求 ≥ 12） | 同上 |
| 反例 | **12 条，全部 PASS、0 命中、原样返回**（要求 ≥ 8） | 同上 |
| 过脱敏的字段 | **AX 正文片段 + 窗口标题 + URL + `kAXDocument` 文件路径**（本轮扩的，见 1.3 问题 C） | `EventSkeleton.record` |

覆盖的类型：`private_key`（PEM 块）、`aws_access_key`、`github_token`、`slack_token`、
`generic_secret`（`api_key`/`secret`/`token`/`password` + 显式 `=`/`:` + ≥8 位值）、
`card_number`（Luhn）、`verification_code`（两个方向各一条规则）。

**新增的三条元数据正例**（它们正是复核指出的漏网场景）：

| 正例 | 输入 | 输出 |
|---|---|---|
| 窗口标题里的验证码 | `Your verification code is 482913 — 收件箱` | `Your verification code is [REDACTED:verification_code] — 收件箱` |
| URL 查询串里的 access_token | `https://mail.example.invalid/oauth/callback?access_token=ya29.a0AfB_byB1234567890` | `…?access_token=[REDACTED:generic_secret]` |
| 窗口标题里的卡号 | `结算 4111 1111 1111 1111 — 收银台` | `结算 [REDACTED:card_number] — 收银台` |

**反例里最要紧的三条**，它们长得都像卡号，只有 Luhn 能区分：

| 反例 | 位数 | Luhn | 结果 |
|---|---|---|---|
| `订单号 1234567812345678` | 16 | 不过 | 0 命中 |
| `时间戳 1757000000000` | 13 | 不过 | 0 命中 |
| `联系电话 13800138000` | 11 | 长度不够 | 0 命中 |

命中替换成 `[REDACTED:<类型>]` 固定占位符，**不保留前后几位**——保留几位就等于泄漏几位。
命中数按类型累计，每 20 条写一条 `runtime_event:redaction`，detail 里**只有类型与条数**。

### 3.5 3.12 三档

`--dump-vectors` §3 的开关表（自检逐项断言）：

| 模式 | 记事件 | 读正文 | 进 SCContentFilter 排除 |
|---|---|---|---|
| `none` | false | false | **true** |
| `events_only` | true | **false** | false |
| `events_and_content` | true | true | false |

解析优先级 5 条用例全过（`selfcheck.txt`）：
今日临时暂停 **>** 库里已有策略 **>** 内置默认不采集清单 **>** 全局默认 `events_and_content`。

**落库口径（本轮改的，见 1.3 问题 A）**：

| 场景 | 行为 |
|---|---|
| 库开着 + 库里没有这一行 | 插入（`source = default` / `builtin_denylist`）并记 `app_policy_new_app` |
| 库开着 + 库里已有 | 直接用库里的，**绝不 UPDATE** |
| 库没开（`locked` / `locking` / `unlocking`）或读库失败 | 只给**临时判定**（`provisional = true`）：不缓存、不落库、不记事件；菜单标注"（库未打开，临时判定）" |
| 用户显式改档（菜单 / 第二轮的清单窗口） | 唯一会覆盖已有行的路径；库没开时进 `pendingUserChoices`，下次开库补写 |

内置默认不采集清单：**25 个 bundle id**，代码内 25 ∪ `Resources/exclusions.txt` 25（两份内容一致，
并集仍是 25）。五类：密码管理器 11、钥匙串访问 1、验证器 5、银行/券商 6、远程屏幕 2
（逐条列在 `dump_vectors.txt` §6 与 `app/README.md` 8.2）。
**银行 / 券商类的 bundle id 没有在本机逐一核对**（本机没装这些客户端），它们是"给个起点"；
漏掉的应用首次出现会写一条 `app_policy_new_app` 事件，用户能看见并一键改档。

### 3.6 3.5 锁定状态机

`--dump-vectors` §4：**21 条转移用例全部 PASS**。覆盖计划 3.5 的每一条触发：

- 启动 / 菜单解锁 / 唤醒 → `unlocking`；开库成功 → `unlocked`，失败 → `locked`
- 系统睡眠、注销（`willPowerOff`）、菜单锁定、**磁盘剩余 < 2 GiB**（阈值 **2,147,483,648 字节**，自检断言）、
  热状态 `critical` → `locking`；`lockCompleted` → `locked`
- 屏幕锁定 → **`paused`，库保持打开**；`lock.strict = true` 时同一触发改走 `locking`
- 屏保启停 → 进 / 出 `paused`
- 边界三条：`locking` 期间再来锁定触发是空操作；`unlocking` 期间的睡眠**要生效**；
  锁定期间**保留暂停原因**（否则醒来会在锁屏状态下恢复采集）

`--dump-vectors` §5（**本轮新增**，见 1.3 问题 F）：**7 条"`locking` 期间的开库触发要补做"用例全部 PASS**。
关库是异步的，赶在 `lockCompleted` 之前到的 `systemDidWake` / `menuUnlock` /（严格模式下的）
`screenUnlocked` 先记进 `pendingUnlock`，等相位真的落到 `locked` 再补做一次，并写
`runtime_event:lock_unlock_deferred`；`screensaverStopped`、非严格模式的 `screenUnlocked`、
以及不在 `locking` 相位的同类触发都**不补**。
反向判定也进了同一条自检：关库过程中再来锁定类触发（⌘L / 锁屏 / 睡眠 / 低磁盘 / 热 critical）
会**取消**已经攒下的补做（`LockPolicy.cancelsDeferredUnlock`）。

暂停原因是**集合**（`user` / `screenLocked` / `screensaver` / `secureInput`）不是布尔：
用户按了暂停、屏幕又锁了，解锁只去掉 `screenLocked` 那一路，采集仍然停着。

### 3.7 私密浏览（尽力）

自检 2 项：Safari 标题含 `无痕浏览` / `Private Browsing` 时命中；
非浏览器（`com.apple.Notes` 标题写着"关于无痕浏览的笔记"）与普通标题都不误伤。

**命中时存什么**（本轮收紧，见 1.3 问题 B）：只存 `app` + `ts` + `completeness = excluded`
+ `source_state`，**正文、窗口标题、URL、`kAXDocument` 文件路径一个都不存**，
另写一行 `capture_stats.status = 'private_browsing'`。台账上仍有这一段时间，但看不出"在看什么"。

---

## 4. 未做与原因

| # | 未做 | 原因 |
|---|---|---|
| 1 | **钥匙串取钥没有实跑** | `KeychainKeyProvider` 首次访问会弹钥匙串授权框，本轮硬约束禁止触发任何 GUI / 授权弹窗。只保证编译通过与代码审查，实跑列进第 5 节交给用户 |
| 2 | **3.12 应用清单窗口** | 任务明确划到第二轮；本轮只做数据层、内置清单与菜单快捷项。第二轮要顺手做一件事：按 `NSWorkspace` 运行记录过滤掉截图排除列表登记进来的 helper bundle id |
| 3 | **改低档时询问是否删数据** | 属于应用清单窗口（3.12 最后一条），随第 2 项一起到第二轮 |
| 4 | **查询时那一道脱敏** | 计划 4.2 是"入库前一道、查询时一道"，查询侧属于 T3 的检索层。`Redactor` 是纯函数，T3 直接复用 |
| 5 | **视口裁剪** | 计划 3.3 要求只入库视口内实际显示的内容，那要 E5 的适配规则。本轮先用单角色 20 000 字符的粗上限兜住内存与库体积，命中写事件、不静默截断 |
| 6 | **低磁盘 / 热状态 critical 的真实触发** | 前者要把卷填到 2 GiB 以下（不建议为它填盘），后者在无风扇 Air 上 E9 实测持续负载只到 `fair`。转移逻辑本身有纯函数用例覆盖 |
| 7 | **私密浏览对 Chromium 系基本无效** | Chrome 无痕窗口的标题就是页面标题，"（无痕模式）"只在窗口边角徽章上，AX 读不到。三条局限如实写进代码注释与 README 8.4；真要挡住只能靠 3.12 改档或 M3 的域名清单 |
| 8 | **AX 0.5 s 超时的端到端计时** | AX 没有读回超时的 API，也没有现成的挂死应用。沿用 M0 的口径（SDK 文档 + 对 system-wide 元素返回 `.success`），真正验证归 E5 |
| 9 | **`lock_unlock_deferred` 事件本身写不进库** | 它发生在 `locking` 期间（`Recorder` 已经摘掉库指针），会被计进"锁定期间丢弃"的事件数，下次开库由 `recorder_dropped` 汇总。补做逻辑本身有纯函数用例，不受影响 |
| 10 | **公证** | 归分发管线；`spctl` 预期 `rejected: Unnotarized Developer ID` |

---

## 5. 需要用户在 GUI 里验证的（本轮全部没跑）

1. **钥匙串授权与取钥**：首次运行弹一次「brosis 想使用您存储在钥匙串中的机密信息」，
   点「始终允许」后菜单里「数据库：」应从 `unlocking` 变成 `unlocked`。
2. **ACL 是否真的限住本应用**：换个进程（如 `security find-generic-password -s com.brosis.store`）
   读同一条目应被拒或要求单独授权。
3. **锁定状态机的真实触发**：合盖睡眠 → 醒来、注销、菜单「锁定 / 解锁数据库」（⌘L）、
   屏保启停、锁屏，以及 `defaults write com.brosis.app lock.strict -bool true` 后的锁屏。
4. **睡眠后立刻唤醒**（本轮新修的补做逻辑）：关库还没落地就醒，预期最终回到 `unlocked`
   而不是停在 `locked`；库里能看到 `lock_transition`，`lock_unlock_deferred` 会计进丢弃数。
5. **两项 TCC 权限**与**屏幕录制月度再授权**（README 第 6 节）。
6. **AX 正文真的入库**：授权后跑一会儿，菜单「写入：」的观察数在涨。
7. **3.12 三档的实际效果**：改成「不采集」的应用不再产生观察；「只记事件」的应用有观察但
   `completeness = excluded`。**外加一次回归**：给某个应用点「永久（不采集）」→ ⌘L 锁库 →
   切到该应用 → 解锁，档位必须还是「不采集」（这正是复核抓到的 bug）。
8. **菜单快捷项**「暂停采集当前应用（今天 / 永久）」与「恢复采集」。
9. **私密浏览**：Safari 开无痕窗口，该窗口的观察应为 `completeness = excluded`，
   且没有正文、没有窗口标题、没有 URL。
10. **SMAppService 登录项批准**（README 第 7 节）。
11. **锁定期间的丢弃计数**：锁一次再解锁，应看到一条 `runtime_event:recorder_dropped`。

---

## 6. 对计划的影响

**一句话：R1 复核提的 A–G 七条已全部改完并有复测证据（自检 38 项全过、零 warning），
T4 的代码面到此闭合；计划本身不需要改，只是把"钥匙串取钥 + 锁定状态机 / 三档策略的真实触发"
从"待实现"挪成"待用户在 GUI 里点一次"，另把"系统级事件只写运行期事件"这条口径转告 T3。**
