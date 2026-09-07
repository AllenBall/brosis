# M1 第二轮 b 批 · T9：3.12 应用采集清单界面

日期：2026-09-08 ｜ 机器：M4 Air 16 GiB、macOS 26.6、Xcode 26.6、Swift 6.3.3、语言模式 v6
前置：T4（3.12 数据层：`CapturePolicy.swift`、`app_policies`、内置默认不采集清单、菜单快捷暂停）、
T8（适配规则表，用来判"有适配器"这一组）、T10（Sparkle 更新入口，本轮一并接进菜单）。

---

## 1. 做了什么

计划 3.12 的**全部条目**落地：界面（清单窗口）+ 界面需要而数据层还缺的两处（全局默认档可改、
新应用一次性提示）+ core 的四个查询。

| # | 3.12 的条目 | 落在哪 |
|---|---|---|
| 1 | 设置里一页"应用"，列出本机出现过的所有 GUI 应用，每个应用一行单独设采集模式 | `app/Sources/brosis/Policies/PoliciesWindow.swift`（AppKit `NSWindow` + `NSTableView`，每行一个 `NSPopUpButton`） |
| 2 | 数据源 = `app_policies` ∪ 最近 7 天 `observations` ∪ `NSWorkspace` 当前运行的 GUI 应用 | `PolicyList.merge`（纯函数）+ core 的 `appPolicies()` / `appObservationStats(since:)` / `appNames()` |
| 3 | 分组显示：有适配器（标规则 id）/ 通用采集 / 默认不采集 | `PolicyList.group`；表格里是**分组标题行 + 组内行**（`isGroupRow`） |
| 4 | 每行显示最近 7 天的观察数与完整性分布 | core 的一条聚合 SQL（四态计数 + `MAX(ts)`），窗口只显示 |
| 5 | 新应用按全局默认处理，菜单栏提示一次，可一键改档 | `CapturePolicyStore.noteNewApp` / `pendingNewAppNotices()` / `clearNewAppNotice`；`AppDelegate` 菜单里一行「新应用 X 已按默认档「…」记录（点此改档）」，点它打开窗口并**选中那一行** |
| 6 | 顶部全局默认档可选 | `CapturePolicyStore.globalDefault` / `setGlobalDefault`（UserDefaults `policy.globalDefault`，出厂 `events_and_content`） |
| 7 | 搜索框过滤 | `PolicyList.filtered`（应用名或 bundle id 的不区分大小写子串） |
| 8 | 改档走 `setMode`（`source = user`） | `PoliciesWindowController.applyMode`，改完把新档位推给 `CaptureController`（生效方式在采集时） |
| 9 | **改为更低档时询问是否删除该应用已有数据，默认不删** | `PolicyModeChange.plan` 状态机 + `NSAlert`（默认按钮是「保留数据」）；删走 `Store.deleteByApp(reason: .policy)`，删完显示条数与释放字节 |
| 10 | 需要库 unlocked；锁定时禁用改档并提示 | 状态机的 `blockedLocked` 分支：整列弹出菜单变灰 + 顶部橙色横幅 + 点击时弹框说明（并提示「今日暂停」不需要开库） |
| 11 | 存储在 `app_policies` | 权威存储不变（T4 就是这样），本轮只加了读全表的查询 |

另外按 T10 结果文件第 5 节，把「检查更新…」一行接进了 `AppDelegate`
（`menu.addItem(UpdaterController.shared.makeMenuItem())`，位置在「导出存储统计…」之后、
退出前那条分隔线之前）。T8 留给主会话的另一处（`CaptureCoordinator.currentStats` 进菜单）
**没做**，不在本任务范围。

### core 新增（`core/Sources/BrosisCore/Store+AppInventory.swift`，179 行）

| API | 口径 |
|---|---|
| `appObservationStats(since:) -> [AppObservationStats]` | 按应用聚合 `[since, ∞)` 的观察数 + `completeness` 四态分布 + `MAX(ts)`；**只算未删除**（`deleted_at IS NULL`）、**只算本机**（`device_id`）；按观察数倒序 |
| `appObservationStatsPlan() -> [String]` | 同一条 SQL 的 `EXPLAIN QUERY PLAN` 原文，只给测试与本文件用（SQL 只有一处定义，测的计划与跑的语句不会漂移） |
| `appObservationCount(bundleID:) -> Int` | 某应用**全库**未删除的观察数；决定"降档时要不要弹那个删数据的框" |
| `appPolicies() -> [AppPolicyRecord]` | `app_policies` 全表（bundle_id / mode / source / updated_at），按 bundle id 排序 |
| `appNames() -> [String: String]` | `apps` 表的 bundle_id → name，给"有策略行但最近 7 天没观察"的应用取显示名 |

**为什么放 core 而不是在 app 里扫全表**：12 个月的库里 `observations` 是百万行量级
（`tools/proto/results/capacity_2026-09-06.md`），把行拉进采集端再分组等于每开一次窗口
读一遍整张表。实测见第 3 节。

### 三条不显然的设计取舍（复核时重点看这三条）

1. **分组按"出厂分类"而不是"当前档位"**。用户把某个密码管理器显式改成「事件 + 内容」之后，
   它仍然留在「默认不采集」组里，只是状态列标「你设的」——这样"这台机器上哪些应用是
   默认被挡掉的"始终一眼看得全。分组顺序是**内置清单 > 有适配器 > 通用**：一个应用
   既在内置清单又碰巧有适配规则时，用户最需要看到的是"它默认不被采集"。
2. **只有降档才问删数据，而且"这个应用一条数据都没有"时不弹框**。判定用的是**全库**计数
   （`appObservationCount`），不是列表里那个 7 天数字——7 天没动过不等于库里没有它的东西。
3. **改全局默认不动任何已有的 `app_policies` 行**。那些行是"已经定过的应用"，其中还包括
   用户显式设过的档；全局默认只对"以后才第一次出现的应用"生效。它和 `policy.pausedToday`
   一样放 UserDefaults 而不是库里，因为库没开（`locked`）时冒出来的新应用也要按它做临时判定。

---

## 2. 怎么跑（可直接复制粘贴）

```bash
cd "<项目目录>"            # 本文件里一律不写绝对路径
SCRATCH="$HOME/Library/Caches/brosis-build/m1-ui-app"

# 1) core 测试（132 个用例）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path core --scratch-path "$HOME/Library/Caches/brosis-build/m1-ui-core"

# 2) 构建 + 签名 app（零 warning）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SCRATCH="$SCRATCH" ./app/build_app.sh

# 3) 自检（90 项，退出码 0）。不弹 GUI、不碰 TCC、不碰钥匙串
"$SCRATCH/brosis.app/Contents/MacOS/brosis" --self-check

# 4) 判定表转储：第 12 节是清单的合并 / 分组 / 排序，第 13 节是改档状态机 8 条
"$SCRATCH/brosis.app/Contents/MacOS/brosis" --dump-vectors
```

原始输出留在 `~/Library/Caches/brosis-build/m1-ui-app/results/`：
`build.log`、`selfcheck.txt`、`dump_vectors.md`、`core_tests.log`、`query_probe.txt`。

### 查询规模探针（第 3 节那组数字的出处）

一次性探针，**只在 scratch 里，不进仓库**：
`~/Library/Caches/brosis-build/m1-ui-app/probe/`（`Package.swift` + `Sources/probe/main.swift`，
路径依赖 `core`，产物落 `~/Library/Caches/brosis-build/m1-ui-probe/`）。

```bash
cd "$HOME/Library/Caches/brosis-build/m1-ui-app/probe"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release --scratch-path "$HOME/Library/Caches/brosis-build/m1-ui-probe"
OBS=200000 APPS=40 "$HOME/Library/Caches/brosis-build/m1-ui-probe/release/probe"
```

它造 20 万条观察（40 个应用、摊在 180 天里、`completeness` 六选一循环、每 3 条一段正文），
`checkpoint()` 之后各量 20 次取平均。探针源码若被删掉，照上面重建即可（内容见
`results/query_probe.txt` 顶部打印的库规模，可核对是否是同一份输入）。

---

## 3. 实测数字

### 3.1 测试与自检

| 项 | 数字 | 出处 |
|---|---|---|
| core 用例 | **132 个，0 失败**（本轮 +6：`AppInventoryTests`） | `results/core_tests.log` |
| app 自检 | **90 项，0 失败**（本轮 +14，从 76 → 90） | `results/selfcheck.txt` |
| `build_app.sh` | **exit 0，warning 0**（`grep -ci warning build.log` = 0） | `results/build.log` |
| app bundle | **9.10 MiB**（不含 D19 模型） | `du -sk` |
| 新增代码 | core 179 行 + core 测试 204 行 + app 399 + 490 行 = **1,272 行新文件**；改动共享文件 3 个（`CapturePolicy.swift` / `AppDelegate.swift` / `CaptureController.swift`） | `wc -l` |

本轮新增的 14 项自检（原文）：

```
[PASS] 清单数据源三处合并（app_policies ∪ 最近 7 天观察 ∪ 运行中的 GUI 应用）：6 行：策略表 5 + 观察 3 + 运行中 2，去重后 6
[PASS] 分组判定（内置清单 > 有适配器 > 通用）：Safari/微信=有适配器（safari / wechat），终端与全新应用=通用，1Password=默认不采集
[PASS] 既在内置清单又有适配器时归「默认不采集」（顺序不能反）：com.tencent.WeChat 命中适配规则 wechat，但仍归 默认不采集；适配器列显示 (空)
[PASS] 没有策略行的应用按全局默认显示，且与采集端同一个 decide()：全新应用 events_and_content/default，运行中=true，最近 7 天观察 0
[PASS] 改全局默认只影响没有策略行的应用：全新应用跟着变，Safari（库里有 default 行）不动
[PASS] 排序：先分组，组内按最近 7 天观察数倒序、再按最近出现倒序、最后按 bundle id：com.apple.Safari → com.tencent.xinWeChat → com.apple.Terminal → com.example.brand-new → com.1password.1password → com.tencent.WeChat
[PASS] 搜索框过滤：应用名 / bundle id，不区分大小写：「微信」命中中文名；「APPLE.TERM」命中 bundle id；无命中返回空表
[PASS] 今日临时暂停不改存下来的那一档，只改生效档：弹出菜单显示「事件 + 内容」，这一刻生效的是「不采集」
[PASS] 改档状态机 8 条（锁定挡下 / 只有降档问删数据 / 没数据不弹框）：档位高低：不采集 0 < 只记事件 1 < 事件 + 内容 2
[PASS] 最近 7 天的观察数与完整性分布（一条聚合 SQL，不扫全表）：窗口内 5 条 = 完整 2 / 部分 1 / 不可用 1 / 排除 1；30 天前那条没被数进来（全库 6 条）
[PASS] 清单统计走 idx_obs_live 部分索引：SEARCH o USING INDEX idx_obs_live (device_id=? AND ts>?) | SEARCH a USING INTEGER PRIMARY KEY (rowid=?) | USE TEMP B-TREE FOR GROUP BY | USE TEMP B-TREE FOR ORDER BY
[PASS] 降档删数据端到端（deleteByApp reason=policy → 统计归零、策略行还在）：全库 6 条 → 删 6 条观察 / 5 个文本版本 / 5 行索引，释放 45 字节；清单里这个应用的统计行消失，策略行保留
[PASS] 全局默认档往返（出厂值 → 用户设的值）：出厂 events_and_content → 设成 events_only（存 UserDefaults 的 policy.globalDefault，库没开也读得到）
[PASS] 新应用菜单提示只出一次，点掉后不再出现：第一次落库时进提示队列，再遇见不重复提示，clear 之后为空
```

第三行那一项是**做完变异检验之后补上的**：原来的合成向量里，"在内置清单里"的应用
（1Password）和"有适配规则"的应用（Safari / 微信）**不重叠**，所以把
`PolicyList.group` 的两个判断换个顺序，当时那 13 项自检一个都不会红。补了
`com.tencent.WeChat`（微信规则的第二个 bundle id，假设用户把它写进了 `exclusions.txt`）
这一行之后，那条变异会当场被两项抓到。见第 6 节。

### 3.2 查询规模：20 万条观察、40 个应用的加密库

库：观察 200,000 条 / 40 个应用 / 文本版本 66,667 / 主库文件 118,079,488 字节（112.61 MiB）；
写入耗时 7.1 s。7 天窗口内的观察是 7,778 条（占全库 3.9%，因为 20 万条摊在 180 天里）。

| 查询 | 平均耗时（20 次） | 说明 |
|---|---:|---|
| `appObservationStats(最近 7 天)` | **2.83 ms** | 窗口每次刷新调它 |
| `appObservationStats(全库，对照)` | 82.77 ms | 只作对照，界面不用；**7 天窗口比它快 29.2×** |
| `appObservationCount(单个应用，全库)` | **0.84 ms** | 只在降档、真要弹框之前问一次 |
| `appPolicies()` 全表 | 0.01 ms | 40 行 |
| `appNames()` 全表 | 0.01 ms | 40 行 |

`EXPLAIN QUERY PLAN`（自检里也断言它含 `idx_obs_live`）：

```
SEARCH o USING INDEX idx_obs_live (device_id=? AND ts>?)
SEARCH a USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR GROUP BY
USE TEMP B-TREE FOR ORDER BY
```

`idx_obs_live(device_id, ts) WHERE deleted_at IS NULL` 是**部分索引**，条件正好是查询里的
`deleted_at IS NULL`，所以 7 天窗口是一次范围扫；`GROUP BY` / `ORDER BY` 的两个临时 b-tree
只作用在扫出来的那几千行上。出处：`results/query_probe.txt`。

### 3.3 改档状态机（`--dump-vectors` 第 13 节，8 条全 PASS）

| # | 用例 | 原档 → 新档 | 库开着 | 全库观察数 | 结果 |
|---|---|---|---|---:|---|
| 1 | 库锁着 · 任何改档都被挡 | 事件+内容 → 不采集 | false | 100 | `blockedLocked` |
| 2 | 库锁着 · 连升档也挡 | 不采集 → 事件+内容 | false | 0 | `blockedLocked` |
| 3 | 同一档 | 只记事件 → 只记事件 | true | 50 | `unchanged` |
| 4 | 升档 | 只记事件 → 事件+内容 | true | 50 | `apply`（不问删数据） |
| 5 | 升档 | 不采集 → 只记事件 | true | 50 | `apply` |
| 6 | 降一档 | 事件+内容 → 只记事件 | true | 37 | `applyThenAskDelete(37)` |
| 7 | 降两档 | 事件+内容 → 不采集 | true | 1 | `applyThenAskDelete(1)` |
| 8 | 降档但没有数据 | 事件+内容 → 不采集 | true | 0 | `apply`（**不弹框**） |

档位高低：不采集 0 < 只记事件 1 < 事件 + 内容 2。

### 3.4 合成数据源合并的结果（`--dump-vectors` 第 12 节）

| # | 分组 | 应用 | 采集模式 | 来源 | 最近 7 天 | 完整性分布 | 状态 |
|---|---|---|---|---|---:|---|---|
| 1 | 有适配器 · safari | Safari | 事件 + 内容 | default | 40 | 完整 30 · 部分 8 · 不可用 2 · 排除 0 | 运行中 |
| 2 | 有适配器 · wechat | 微信 | 只记事件 | user | 12 | 完整 0 · 部分 0 · 不可用 0 · 排除 12 | 你设的 |
| 3 | 通用采集 | 终端 | 事件 + 内容 | default | 12 | 完整 12 · 部分 0 · 不可用 0 · 排除 0 | — |
| 4 | 通用采集 | 全新应用 | 事件 + 内容 | default | 0 | — | 运行中 |
| 5 | 默认不采集 | com.1password.1password | 不采集 | builtin_denylist | 0 | — | 内置清单 |
| 6 | 默认不采集 | com.tencent.WeChat | 不采集 | builtin_denylist | 0 | — | 内置清单 |

第 6 行就是"既在内置清单又有适配规则"的那一行：它命中微信的适配规则，但仍然归
「默认不采集」组、适配器列留空。

「最近出现」那一列是相对时间（"N 天前"），随跑的日子变，**故意没放进转储表**，
免得同一份代码今天和明天转出来的表不一样；它的判定在 `PolicyListRow.lastSeenLabel`。

---

## 4. 未做与原因

1. **窗口本身没有在 GUI 里跑过**。硬约束禁止启动 GUI / 触发 TCC，本轮所有验证都是
   "纯函数 + 临时加密库"这一层。窗口代码（布局、表头、分组行、弹出菜单、`NSAlert`）
   编译通过、零 warning，但**没有一次真实渲染**。第 5 节列了需要真人看的 8 条。
2. **没有列"本机装过但从没运行过、也没被采集端碰到过"的应用**。3.12 说的数据源就是
   "NSWorkspace 的运行记录和本系统自己的观察记录"两处，扫 `/Applications` 不在其中，
   而且会把一堆用户根本不开的应用塞进清单。想先设好某个还没开过的应用，
   现在的做法是先开一次（它会作为"运行中"出现在清单里）。
3. **适配器那一组没显示"适配器版本与近期完整性统计"里的版本号**。`AdapterRule` 目前
   没有版本字段（T8 的规则是纯数据、跟着 app 版本走），所以只显示规则 id。
   近期完整性统计是有的（就是每行那一列）。要真正的规则版本得先给 `AdapterRule` 加版本，
   属于 T8 的面，本轮不擅自改。
4. **`capture_audit` 的覆盖率没进清单**。T8 的采样审计是低频的（默认每 50 条 AX 非空观察
   才做一次），大部分应用在 7 天里一条采样都没有，摊在每一行上会是一片空白，
   不如放在存储统计导出里。`Store.captureCoverageByApp(since:)` 已经有了，随时能接。
5. **没做"按住选中多行批量改档"**。3.12 没要求；一次改一个也符合"降档要单独问删数据"。
6. **T8 留下的另一处菜单接线（`CaptureCoordinator.currentStats` 进菜单）没做**，
   不在本任务范围，仍然挂在 `app/README.md` 的 8.6 节。

---

## 5. 需要真人在 GUI 里验证的（已写进 `app/README.md` 第 11 节第 8b / 8c 条）

1. 菜单栏 →「应用采集清单…」能打开窗口，三组都在、组标题行显示每组条数，跑一阵之后
   「最近 7 天观察」与「完整性分布」有数字。
2. 搜索框：中文应用名与 bundle id 片段（大小写混着打）都能过滤。
3. 顶部「新应用的全局默认档」改成「只记事件」，再打开一个从没用过的应用，
   库里那条 `app_policy_new_app` 的 `mode` 应是 `events_only`；已经在清单里的应用不受影响。
4. 升档不弹框；降档弹框且**默认按钮是「保留数据」**。选「保留」→ 库里多一条
   `app_policy_downgrade_kept_data`；选「删除这 N 条」→ 窗口底部显示删了多少、释放多少字节，
   库里多一条 `app_policy_downgrade_deleted`，该应用观察数归零、策略行还在。
5. ⌘L 锁库后打开窗口：橙色横幅出现、整列弹出菜单变灰；这时菜单栏的
   「暂停采集当前应用 → 今天」应该照常能用。
6. 新应用提示：第一次遇到某个应用时菜单栏出现一行「新应用 … 已按默认档「…」记录（点此改档）」，
   点它打开窗口并**选中那一行**；点过之后不再出现（重启 app 也不再出现）。
7. 改完档立刻生效：把当前前台应用改成「不采集」，它不该再产生新观察（不用等切换应用）。
8. 「检查更新…」（T10 的入口，本轮接进菜单）：点一次应弹「更新功能未启用：SUPublicEDKey
   还是占位符…」，除非已按 `dist/RELEASE.md` 配好真公钥再构建。点它之前不应有任何出网。

---

## 6. 变异检验（本轮实跑过，验收可照做）

**做法：把 `core/` 与 `app/` 整个复制到 scratch 再改，项目目录一个字节都不动。**
`core/Vendor/` 里那两个符号链接指向构建缓存的绝对路径，`cp -R` 保留符号链接，复制过去照样能编。

```bash
MUT="$HOME/Library/Caches/brosis-build/<你的任务名>-mut"
rm -rf "$MUT"; mkdir -p "$MUT"
cd "<项目目录>"; cp -R core "$MUT/core"; cp -R app "$MUT/app"
```

四条已实跑的变异，以及它们被谁抓到：

| # | 改哪里（在 `$MUT` 里改） | 怎么改 | 实测被抓 |
|---|---|---|---|
| 1 | `core/Sources/BrosisCore/Store+AppInventory.swift` 的 `appObservationStatsSQL` | 删掉 ` AND o.deleted_at IS NULL` | `swift test` **3 个用例红**：`testStatsCountsAndDistribution`（墓碑行进了统计）、`testDeleteByAppClearsStatsButKeepsPolicy`、`testStatsUsesPartialIndex`（计划退化成 `sqlite_autoindex_observations_1`） |
| 2 | `app/Sources/brosis/Policies/PolicyList.swift` 的 `PolicyModeChange.plan` | 把最后那行 `return existingObservations > 0 ? .applyThenAskDelete(...) : .apply` 换成 `return .apply` | `--self-check` **2 项红**：「改档状态机 8 条」（降一档 / 降两档两条用例）与「降档删数据端到端」 |
| 3 | 同上文件的 `PolicyList.group` | 把 `isDenylisted` 与 `adapterID` 两个 `if` 调换顺序 | `--self-check` **2 项红**：「既在内置清单又有适配器时归「默认不采集」（顺序不能反）」与「排序：先分组…」 |
| 4 | `Store+AppInventory.swift` 的 `WHERE o.device_id = ?` | 改成 `WHERE (o.device_id = ? OR 1)` | `swift test` **2 个用例红**：`testStatsAreDeviceScoped`、`testStatsUsesPartialIndex`（计划退化成 `SCAN o USING INDEX idx_obs_app_ts`） |

编译与跑法（app 那两条不用签名，直接 `swift build -c release` 出裸二进制就够）：

```bash
cd "$MUT/core" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   swift test --scratch-path "$HOME/Library/Caches/brosis-build/<任务名>-mut-core"
cd "$MUT/app"  && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   swift build -c release --scratch-path "$HOME/Library/Caches/brosis-build/<任务名>-mut-app"
"$HOME/Library/Caches/brosis-build/<任务名>-mut-app/release/brosis" --self-check | grep '^\[FAIL\]'
```

**变异 3 一开始没被抓到**（补这一行之前，本轮那 13 项自检全绿），原因写在第 3.1 节：合成向量里
"内置清单"和"有适配器"两组不重叠。补了 `com.tencent.WeChat` 这一行之后才红。
这条是本轮唯一一次"测试没覆盖到"的实例，已修。

**没有被自动化覆盖、只能靠人看的**：`NSAlert` 的按钮顺序（默认按钮必须是「保留数据」）、
弹出菜单变灰、横幅文字、表头与分组标题行的渲染。它们在第 5 节的人工清单里。

---

## 7. 对计划的影响

3.12 的全部条目（三档、分组、7 天统计与完整性分布、新应用默认档与菜单提示、
降档询问删数据、`app_policies` 存储）已经实现并有自检覆盖，**M1 的 R2 出口条目"3.12 界面"
可以进入用户 GUI 验证**；界面本身没有在 GUI 里跑过，第 5 节那 8 条是唯一剩下的口子。
