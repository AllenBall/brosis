# tools/probe — D2 应用切换探针

**用途**：连续 3 天记录「哪个应用在前台、停留多久、其间有没有键鼠输入」，3 天后按前台停留时长排序，产出 `docs/实施计划.md` D2 需要的常用应用清单（飞书、微信固定入选，探针负责测出其余 6 名）。

**不需要任何 TCC 权限**：只调用 `NSWorkspace.frontmostApplication`（应用级信息）和 `CGEventSource.secondsSinceLastEventType`（键鼠空闲秒数）。不读窗口标题、不截屏、不用 Accessibility、不读浏览器 URL、不用 AppleScript，因此**不会弹出屏幕录制 / 辅助功能 / 自动化任何一个授权对话框**。安装过程也不需要管理员密码。

## 文件

| 文件 | 作用 |
|---|---|
| `appswitch.swift` | 探针本体，单文件，`swiftc -O` 直接编译 |
| `report.py` | 读 JSONL 出 Markdown 报告，只用 Python 标准库 |
| `com.brosis.probe.plist` | LaunchAgent 模板（4 个占位符由 `install.sh` 渲染成绝对路径） |
| `install.sh` | 编译 → 安装二进制 → 渲染并加载 LaunchAgent，幂等 |
| `uninstall.sh` | 反向卸载，默认保留已采集数据，`--purge` 连数据一起删 |
| `results/` | 冒烟与正式报告输出目录 |

编译产物放 `~/Library/Caches/brosis-build/probe/`，采集数据放 `~/Library/Application Support/brosis-probe/`，**都不在 iCloud 同步范围内**，项目目录里只有这 6 个文本文件（合计 49,426 字节 ≈ 48.3 KiB，加 `results/` 里的报告共 61.0 KiB）。

本文体积一律按 2^10 进制：**KiB = 1024 字节**、**MiB = 1024 KiB**。

## 一、公司机怎么装

1. 把整个 `tools/probe` 目录复制到公司机任意位置（U 盘、Git、AirDrop 均可，只有 6 个文本文件，合计 49,426 字节 ≈ 48.3 KiB）。
2. 确认有 Xcode 命令行工具：`swiftc --version`。没有就 `xcode-select --install`（这一步会弹系统自带的安装框，不是权限框）。
3. 安装并启动：

```bash
cd /path/to/tools/probe
./install.sh
```

`install.sh` 会：编译到 `~/Library/Caches/brosis-build/probe/appswitch` → 拷到 `~/Library/Application Support/brosis-probe/bin/` → 渲染 `~/Library/LaunchAgents/com.brosis.probe.plist` → `launchctl bootstrap gui/$(id -u)` 加载。重复执行会先 `bootout` 再加载，可以随时重跑。

4. 确认在跑：

```bash
launchctl print gui/$(id -u)/com.brosis.probe | head -12   # state = running
tail -5 ~/Library/Application\ Support/brosis-probe/probe.log
```

5. 想先看它到底记什么，不装服务也行（前台跑 30 秒后自动退出）：

```bash
swiftc -O appswitch.swift -o /tmp/appswitch
/tmp/appswitch --dir /tmp/probe-试跑 --duration 30 --verbose
cat /tmp/probe-试跑/appswitch.jsonl
```

## 二、3 天后怎么出报告

```bash
cd /path/to/tools/probe
python3 report.py --days 3 --top 20 > results/d2_$(date +%F).md
open results/d2_$(date +%F).md
```

参数：`--days N`（只统计最近 N 个自然日，含今天；`0`=全部）、`--top N`（排行条数，默认 20）、`--file 路径`（默认 `~/Library/Application Support/brosis-probe/appswitch.jsonl`）、`--no-exclude`（把 loginwindow 等系统项也放进主排行）。

两台机器的清单合并时，把各自 `appswitch.jsonl` 拷到一起分别出报告再人工合并即可（不要直接 `cat` 成一个文件——两台机器的时间区间会交叠，切换次数会算错）。

## 三、怎么卸载

```bash
cd /path/to/tools/probe
./uninstall.sh            # 停服务、删 LaunchAgent 与二进制，保留已采集的 JSONL
./uninstall.sh --purge    # 连 ~/Library/Application Support/brosis-probe 一起删掉
```

临时停一下、之后再开：

```bash
launchctl bootout gui/$(id -u)/com.brosis.probe      # 停
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.brosis.probe.plist   # 再开
```

## 四、数据格式

`~/Library/Application Support/brosis-probe/appswitch.jsonl`，一行一个前台停留区间：

```json
{"start":"2026-09-06T22:51:16+08:00","end":"2026-09-06T22:51:48+08:00","bundle_id":"com.apple.Safari","name":"Safari","dwell_s":32.0,"active_s":18.0,"end_reason":"switch"}
```

| 字段 | 含义 |
|---|---|
| `start` / `end` | 区间起止，ISO 8601 带本地时区偏移 |
| `bundle_id` | 前台应用 bundle id；取不到时为 `unknown`，完全没有前台应用时为 `none` |
| `name` | `localizedName`，只作显示用，排序一律按 `bundle_id` |
| `dwell_s` | **前台停留秒数**（上界口径） |
| `active_s` | **有输入的活跃秒数**（下界口径），`active_s ≤ dwell_s` |
| `end_reason` | 区间为何收口：`switch` 切换 / `rotate` 满 30 分钟切段 / `screen_locked` 锁屏 / `idle` 空闲兜底 / `gap` 采样空档 / `shutdown` 正常退出 / `recovered` 崩溃后恢复 |

`end_reason` 不是 D2 需要的字段，`report.py` 也不用它，只为排查问题保留。

同目录还有 `current.json`（未收口区间的断点续写状态，正常退出后自动删除）、`probe.log` / `probe.err.log`（运行日志）。

## 五、采集口径（对应评审 F7：停留 / 活跃 / 未知三态分开）

- **前台停留 `dwell_s`**：每 2 秒采样一次 `frontmostApplication`，把相邻两次采样之间的秒数记给**上一次采样看到的应用**，收口于发现切换的时刻。因此每次切换的归属误差 ≤ 1 个轮询间隔（2 秒）；一天几百次切换，总误差在分钟量级，对排序不影响。
- **有输入活跃 `active_s`**：同一段秒数，只有当采样时刻「距上次键鼠事件 < 60 秒」才计入。它是注意力的保守下界，**不要**当成"用了多久"。
- **未知 / 不计入的时间**：下面五种情况不产生任何记录，所以「前台停留合计」天然小于开机时长，两者的差就是未知状态。

## 六、锁屏 / 睡眠怎么排除（含兜底，重要）

按可靠性从高到低共四路，任何一路生效都会立刻收口当前区间并停止累计；必须**所有**暂停来源都解除后才恢复记录。

| # | 信号 | 覆盖场景 | 可靠性 |
|---|---|---|---|
| 1 | **前台应用 = `com.apple.loginwindow`** | 锁屏、登录窗口、快速用户切换后的登录界面 | 最高：直接观测，不依赖通知投递 |
| 2 | `NSWorkspace` 通知：`willSleep` / `didWake`、`screensDidSleep` / `screensDidWake`、`sessionDidResignActive` / `sessionDidBecomeActive` | 系统睡眠、显示器睡眠、快速用户切换 | 高，但命令行进程收不到通知时会漏 |
| 3 | 分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | 锁屏 | 中：私有通知，不保证投递 |
| 4 | **兜底一：采样空档 > 10 秒** | 系统睡眠、合盖、进程被挂起——睡眠期间定时器根本不触发 | 高：只看两次心跳的时间差 |
| 5 | **兜底二：键鼠空闲 ≥ 15 分钟** | 上面全都没生效时（屏保、通知被丢弃、外接屏锁屏行为异常） | 中 |

两条兜底的具体行为：

- **采样空档**：发现两次采样间隔超过 10 秒，说明进程被挂起过，按**上一次心跳时刻**收口，中间这段完全不计。
- **空闲兜底**：连续 15 分钟没有任何键鼠事件时暂停记录，并把区间结束时刻**回拨到最后一次输入的时刻**，把这段空闲从 `dwell_s` 里扣掉；检测到新输入即恢复。
- **防卡死**：如果解锁 / 唤醒类通知丢了，探针会永久停在暂停态。因此增加了强制恢复：暂停中连续 15 次采样（30 秒）都检测到「空闲 < 5 秒」且前台不是登录窗口，就清掉所有暂停来源继续记录。

**已知偏差**（写进报告口径，不要当成 bug）：

1. 连续 15 分钟零键鼠输入的**被动使用**（长视频、长文档阅读）会被空闲兜底截断，`dwell_s` 偏小。要保留这类时间，把阈值调大：`--suspend-idle 3600`。
2. 锁屏期间前台变成 `loginwindow`，探针会把锁屏前那一刻当作切换点收口，误差同样 ≤ 2 秒。
3. **双屏不重复计时**：探针只有"一个前台应用"的概念，副屏上同时可见的窗口不单独计时——这正是评审 F7 提醒的重复计时问题，本探针不存在。反过来说，它也不知道副屏上你在看什么。
4. 一个应用连续占据前台超过 30 分钟会切段落盘（`end_reason=rotate`），防止崩溃丢数据；`report.py` 只在 `bundle_id` 变化时才计一次切换，切段不会虚增切换次数。
5. 没有 bundle id 的进程记成 `unknown`，`report.py` 默认把它和 `loginwindow` 一起移出主排行，但会单列一张表，不静默丢弃。
6. **满 30 分钟切段与空闲兜底的交互**：切段那一刻如果已经空闲了 ≥ 活跃阈值（60 秒），旧段收口在「最后一次输入」的时刻，这段空闲挪到新段上（新段 `start` 与旧段 `end` 相同，`dwell` 预置为这段空闲秒数），因此之后若真的空闲满 15 分钟，兜底回拨仍能把它整段扣掉。切段时空闲不足 60 秒的那一小段（< 1 分钟）留在旧段里，属可忽略的上界偏差。
   *这条是 2026-09-07 的修正*：在此之前切段一律收口在「当前时刻」，空闲被永久留在已落盘的段里，极端情况一段最多多记约 15 分钟 `dwell`。**已安装的二进制不会自动更新，下次执行 `./install.sh` 时才生效。**

## 七、资源与容量（本机实测，2026-09-06）

| 项 | 实测值 | 口径 |
|---|---|---|
| 二进制大小 | 146,280 字节 = 142.9 KiB | `swiftc -O` 单文件，arm64（2026-09-07 改过 rotate 收口后重编） |
| 常驻内存 RSS | 14.7 MB | `ps -o rss`，运行 1 分钟后 |
| CPU 占用 | 累计 0.17 秒 / 运行 562 秒 = 0.030 % | `ps -o time`，2 秒轮询、锁屏暂停态 |
| 单条记录 | 平均 181 字节（UTF-8，含换行） | 7 条冒烟样本实测 |
| 日增数据量 | 按每天 300–600 次切换估算 = 53–106 KB/天；3 天 0.16–0.31 MB | 未实测满 3 天，属估算 |

`ProcessType=Background` 已在 plist 里声明，系统会按后台优先级调度；日志按行追加，3 天量级不需要轮转。

## 八、命令行参数

```
appswitch [选项]
  --dir <目录>          数据目录，默认 ~/Library/Application Support/brosis-probe
  --file <路径>         JSONL 输出文件，默认 <数据目录>/appswitch.jsonl
  --interval <秒>       轮询间隔，默认 2
  --active-idle <秒>    活跃判定阈值，默认 60
  --suspend-idle <秒>   空闲兜底暂停阈值，默认 900
  --rotate <秒>         单区间最长时长，默认 1800
  --checkpoint <秒>     未完成区间的状态落盘间隔，默认 30
  --duration <秒>       跑满该秒数后退出（冒烟用），默认常驻
  --verbose             每写一条区间打印一行
  --version / --help
```

## 九、自测（不依赖屏幕状态）

`--simulate` 用脚本序列代替真实前台应用，`--fake-idle` 用固定值代替真实空闲秒数，两者都不接触 `NSWorkspace` / `CGEventSource`，所以在锁屏、无人值守、CI 里都能跑，用来验证区间切分与时长口径：

```bash
# 切换记账：A 6 秒 → B 6 秒 → A 6 秒 → C 6 秒，全程算活跃
./appswitch --dir /tmp/t1 --interval 1 --fake-idle 3 \
            --simulate "com.test.A:6,com.test.B:6,com.test.A:6,com.test.C:6" --verbose
# 期望：4 条区间，序列 A→B→A→C，dwell 合计约 24 秒，active == dwell

# 活跃口径：同样 6 秒，空闲 120 秒时 active_s 应为 0
./appswitch --dir /tmp/t2 --interval 1 --fake-idle 120 --simulate "com.test.A:6"

# 空闲兜底：空闲 1000 秒 > 900 秒阈值，应一条不记
./appswitch --dir /tmp/t3 --interval 1 --fake-idle 1000 --simulate "com.test.A:5" --verbose

# 切段收口（已知偏差 6 的回归）：rotate 12 秒、空闲 4 秒、活跃阈值 3 秒
./appswitch --dir /tmp/t5 --interval 1 --rotate 12 --fake-idle 4 --active-idle 3 \
            --simulate "com.test.A:20" --verbose
# 期望：2 条区间，第 1 条 dwell 8.2 秒（收口在 now-4s），第 2 条 start 与它的 end 相同、
#       dwell 12.0 秒（含预置的 4 秒空闲）；两条合计 ≈ 20 秒，不丢时间
```

**解锁状态下的真机复核**（30 秒，会短暂抢一次焦点）：

```bash
~/Library/Caches/brosis-build/probe/appswitch --dir /tmp/probe-复核 --duration 30 --verbose &
sleep 8; open -a Calculator; sleep 10; open -a Finder; sleep 14
cat /tmp/probe-复核/appswitch.jsonl     # 期望 >= 3 条区间，bundle_id 依次变化
```

注意：**锁屏时做不了这个复核**——锁屏期间前台恒为 `com.apple.loginwindow`，`open -a` 也不会把应用切到前台。

## 十、隐私边界

采集内容只有：**应用 bundle id、应用显示名、时间戳、两个秒数**。不含窗口标题、文件名、URL、剪贴板、截图、按键内容——键盘只用到"距上次事件多少秒"这一个数，读不到按了什么键。数据只写本机 `~/Library/Application Support/brosis-probe/`，不联网、不写 iCloud。要停就 `./uninstall.sh --purge`，一条命令删干净。
