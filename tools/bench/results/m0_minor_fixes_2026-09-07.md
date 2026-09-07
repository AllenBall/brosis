# M0 验收 minor 问题清理（T9）· 2026-09-07

对上一轮验收官记录的 **25 条 minor** 逐条处理。**24 条已修，1 条按「补充披露、不改代码」处理**（编号 21，理由见表内与第 3 节）。

口径与约定：

- 体积一律 **2^10 进制**并把进制写进单位：`KiB = 1024 字节`、`MiB = 1024 KiB`、`GiB = 1024 MiB`；
  凡是与《实施计划》2.4 的「0.3 GB/月、5 GB 配额」对账的地方，**同时给出十进制 GB 口径**（2.4 没注明进制）。
- 由生成器产出的报告（`ocr_report.py` / `fts_compare.py` / `measure.py`）**一律改生成器后重跑**，
  没有手工编辑任何生成物；报告里的区间与倍数改成从原始 JSON 现算，不再手抄。
- `tools/probe` 的 LaunchAgent 全程保持运行，**没有卸载也没有重装**；改动后的二进制编到
  `~/Library/Caches/brosis-build/probe-t9/` 单独自测，**下次执行 `./install.sh` 才会生效**。
- 没有运行 `app/` 的 GUI，全程零 TCC 弹窗。项目目录内无编译产物（`find . -name .build -o -name __pycache__` 为空）。

## 1. 逐条处理结果

| # | 任务 | 问题摘要 | 处理 | 验证命令与结果 |
|---|---|---|---|---|
| 1 | T1 探针 | `smoke_2026-09-06.md` 把「真实应用切换」记成部分通过/未完成，验收时实测已通过，结果文件过时 | **已修**。第 2 节测试 A 改为**通过**，补记 23:14:28–23:15:03 的实测：临时实例 3 条区间（Claude 8.4 / 计算器 10.0 / 访达 13.6 秒，末条被 `--duration` 截断）；已安装的 agent 独立记下同样 3 次前台变化（23:14:37 → 计算器 10.0 秒 → 访达 16.0 秒 → 23:15:03 回 Claude）。结论段与第 6 节的「未完成」项删掉并重新编号；第 4 节补记解锁后的 50 条真实区间与两次真实锁屏/解锁日志 | `grep -E '"start":"2026-09-06T23:1[45]' ~/Library/Application\ Support/brosis-probe/appswitch.jsonl` → 计算器 10.0 s、访达 16.0 s 两条原始记录；`python3 tools/probe/report.py --days 3 --top 8` → 58 条区间、8 个应用排行正常出表 |
| 2 | T1 探针 | 体积数字三处不一致（README「不到 40 KB」/ 报告「60 KB」/ 实测 46,988 字节）；结论写「8 组测试」而表里 14 项 | **已修**。所有体积改成 `wc -c` 实测并标 KiB，交付物表逐文件给字节数；「8 组」改为「14 项：真机 A–E 5 项 + 确定性 S1–S4 4 项 + 安装 I1–I5 5 项」。修订后 6 个交付文件 **49,426 字节 = 48.3 KiB**，加 `results/` 报告 **62,889 字节 = 61.4 KiB**（数字用定点迭代算到自洽，写进文档后再测仍是这两个值） | `for f in appswitch.swift report.py com.brosis.probe.plist install.sh uninstall.sh README.md; do wc -c < $f; done` 合计 49,426，加报告 62,889；`grep -c "@@" README.md results/smoke_2026-09-06.md` → 0（无残留占位符） |
| 3 | T1 探针 | `install.sh` 的 `sed` 把模板首行注释里的 `__BIN__` 等字面量也替换成绝对路径 | **已修**。plist 注释改成「二进制路径、数据目录、stdout、stderr 四个占位符由 install.sh 渲染成绝对路径」，并加一句「占位符字面量不要写进注释，否则会被 sed 一并替换」；README 文件表同步 | `sed -e "s\|__BIN__\|/tmp/bin/appswitch\|g" ... com.brosis.probe.plist > 渲染件 && plutil -lint` → `OK`；`grep "<!--" 渲染件` → 注释里不再出现任何绝对路径 |
| 4 | T1 探针 | 满 30 分钟 `rotate` 切段时若已空闲数分钟，这段空闲被永久留在已落盘的段里，极端情况一段多记约 15 分钟 `dwell` | **已修（代码 + README）**。切段时若空闲 ≥ 活跃阈值，旧段收口在「最后一次输入」，新段以同一时刻开始并把这段空闲预置为 `dwell`——之后真空闲满 15 分钟时兜底回拨仍能整段扣掉，且不丢时间。README 第六节「已知偏差」新增第 6 条并注明**下次 `install.sh` 生效**，第九节加了这条的回归自测 | `swiftc -O appswitch.swift -o ~/Library/Caches/brosis-build/probe-t9/appswitch`（146,280 字节）；`appswitch --rotate 12 --fake-idle 4 --active-idle 3 --simulate "com.test.A:20"` → 2 条区间 dwell **8.2 + 12.0 = 20.2 s**（标称 20 s，不丢时间），第 2 条 `start` == 第 1 条 `end`；对照组 `--fake-idle 1 --active-idle 60` → 12.2 + 8.0，行为不变；S1/S2/S3 三项原自测全部复跑通过 |
| 5 | T2 OCR | 结论 3.4 的 fast 语言纠错耗时代价写「1.76×–3.10×」，实为 1.76×–4.07×；「CER 无改善，最大 −0.85 pp」也不对 | **已修（改生成器，不再手抄）**。`ocr_report.py` 新增 `compute_facts()`，从 JSON 现算 15 组开/关的 p50 比值与 CER 差，结论文件改用 `{{占位符}}`；有未定义占位符时脚本直接报错退出。现在输出：耗时 **1.76×–4.07×**（最贵 4.07×，`code_small` @ 1728x1117）、CER **−0.33 pp ~ +2.40 pp**（最大改善 0.33 pp，最大恶化 2.40 pp `dense_page` @ 1728x1117） | `python3 tools/bench/ocr_report.py results/ocr_bench_2026-09-06.json` → 重新生成 27,459 字节；报告 3.4 表内数字与 JSON 现算值一致 |
| 6 | T2 OCR | 结论 3.3 第 2 条把 `code_small` 严格 CER 里的 6.26 pp 全归给全角标点 | **已修**。改为三段拆解并全部由 `compute_facts()` 现算：严格 8.33% → 去空白 6.91%（**1.42 pp 是空白与换行差异**）→ 宽度折叠 2.07%（**4.84 pp 才是全角标点折叠**），合计 6.26 pp | 同上一条命令；报告 3.3 第 2 条现为「**6.26 pp** 是排版规范化…其中 **4.84 pp 才是全角标点折叠**…另外 **1.42 pp 是空白与换行差异**」 |
| 7 | T2 OCR | 结论 3.5「实测每字符 0.25–0.35 ms」与原始数据、与执行者自己的汇总都对不上 | **已修**。改为现算：正常样式 **0.24–0.36 ms/字符**，稀疏页因固定开销单列为 **0.44–0.47 ms/字符**；每识别块 **6.1–16.1 ms**；同段的 p50/p95 区间、`p95/p50 ≤ 1.13`、fast 与 accurate 的倍数（**1/22 到 1/7**，原文写的 1/12–1/16 也是错的）一并改成现算 | 同上；`compute_facts` 单测打印 `acc_ms_per_char = 0.24–0.36 ms`、`acc_ms_per_char_sparse = 0.44–0.47 ms`、`acc_ms_per_obs = 6.1–16.1 ms` |
| 8 | T2 OCR | `dense_page` 样式名与规格写「约 4000 字符」，真值 3522 字符 | **已修（不重跑基准）**。`ocr_bench.swift` 的样式名改为「密集页（约 3500 字符）」并加注释说明真值实测 3522；同时给 `ocr_report.py` 加了通用校验：解析样式名里的「约 N 字符」与 `truth_chars` 比对，**偏差 > 5% 就在样式表下自动列出**。没有重跑基准（720 次 OCR / 约 7 分钟），因为改行数会改变真值、连带 60 组耗时与 CER 全部失效，而结论里引用了大量这些数字；JSON 里仍是旧样式名，报告会把这个偏差显式写出来 | 生成的报告第 47 行：「本轮偏差超过 5% 的样式：`dense_page` 名义 4000、实测 **3522**（-11.9%）」 |
| 9 | T3 FTS | §9.4 建表注释里写死「§7 实测差 112 倍」，而 §7 是脚本实时算的（本次 106 倍），复跑还会抖 | **已修**。`render_md` 的 §9.4 注释改为从 `payload['collate_probe']` 现算，与 §7 用**同一次**探针数据，两处永远一致；README 改成写量级（100–120 倍）不写定值 | `uv run --with jieba python tools/bench/fts_compare.py` → §7「差 **110 倍**（0.378 ms vs 0.003 ms）」与 §9.4「§7 实测差 **110 倍**」完全一致；`grep -rn "112 倍" tools/ app/` → 无匹配 |
| 10 | T3 FTS | 规格 E) 要求 app 独立列 + 按应用限定的扫描回退，实际只测了 7 天时间窗口；规格写 `instr` 实际用 `LIKE` 未说明 | **已修**。新增 `app_scope_probe()`：对 10 条 1–2 字正例，按「窗口内相关文档最多的应用」当作用户指定范围，实测 `ts >= ? AND app = ? AND text LIKE ?`。报告 §6 新增一节给出窗口内该应用文档数、范围内召回、热 p50/p95 与只限时间的对照；EQP 抽样新增「app 等值 + 时间窗口」「正文限时 + 限应用扫描」两条；§1 口径补 `LIKE` 替代 `instr` 的理由（语义等价，但 `LIKE` 对 ASCII 大小写不敏感，与精确字段列的 `COLLATE NOCASE` 同口径）；§9.5 写明「app 列本轮只测了限定扫描范围这一种用法」 | 同上重跑。报告 §6：10 条查询在指定范围内**召回全部为 100.0%**，热 p50 0.02–0.10 ms，比只限时间窗口再快 **1.4×–11.7×**；查询计划 `SEARCH docs USING INDEX idx_docs_app_ts (app=? AND ts>?)` |
| 11 | T3 FTS | B+E+V 的子串复核对 exact + scan + fts 的并集整体做，精确字段通道的命中会被正文过滤误删 | **已修**。`Searcher.search` 改成只对 FTS 候选 `_verify`，精确字段与扫描通道的命中直接保留；`_verify` 的 docstring 写明原因；§9.4 查询规划伪码同步改成「第 5 步只对第 4 步的 FTS 候选生效」并加一段说明 | 同上重跑：B+E+V 仍是 R@10 **97.0%** / P@10 **100.0%** / 报错 0（本轮语料里 url/path 文档正文含该串，指标不变，符合验收官预期），改动没有引入回归 |
| 12 | T3 FTS | `human_bytes` 用 2^20 却标 MB，与执行者报告的十进制 MB 混用（违反 F8 统一口径） | **已修**。`human_bytes` 改标 **MiB**，`render_md` / `render_conclusion` 里所有 `/1024/1024` 的标签、扫描吞吐 MiB/s、100 MiB / 1 GiB 的外推、写死的「1.82 MB 语料」全部改掉；§1 口径新增一条把进制写死。README 结论速览同步 | 同上重跑；`grep -n "[0-9] MB\b" results/fts_compare_2026-09-06.md` → 无残留（正文 1.82 MiB、基准库 2.66 MiB、B 索引 0.99 MiB） |
| 13 | T4 schema | README 写「`tools/bench/results/` 还没有 T3 结论」，但该目录已有 T3 报告 | **已修**。「换分词方案」一节改为引用 `tools/bench/results/fts_compare_2026-09-06.md`，写明它 §9.2 推荐 B+E+V（R@10 97.0% / 索引 0.99 MiB）对比占位的 trigram（81.0% / 3.42 MiB），并说明**为什么 schema 现在仍不改**：T3 报告没有「选定分词」定稿段落、E2 在线部分未跑；同时点明 `measure.py` 默认已是 bigram，两边不一致是有意的 | `sed -n '/### 换分词方案/,+12p' tools/proto/README.md` → 已引用报告路径与两组对比数字 |
| 14 | T4 schema | 执行者报告引用的确定性摘要 `c68531d9…` 与当前代码输出不符 | **已修**。README「怎么跑」一节新增回归基线表，记录**当前代码实测**的两个摘要，并要求改动 `gen_synth.py` 后同步更新 | `python3 gen_synth.py --days 7 --per-day 120 --seed 20260906 --devices 2 --digest` 连跑两次均为 `03e4e382635b134c7de5581c5e2e0df55a3e93048d6dceabfd2f3602ab64b54f`；`--seed 7` 为 `23544b0fa180236d16db6368c73c1c294563830e051424a68706c367c8ff0f19` |
| 15 | T4 schema | `deletions.fts_rows_deleted` 在两条删除路径里都直接复制 `text_versions_deleted`，审计字段失去独立核验意义 | **已修**。`user_delete()` 与 `quota_expire()` 都在事务内删除前后各查一次 `SELECT COUNT(*) FROM text_fts_docsize`，取差值写入；S3 / S5 各新增一条断言，把审计字段与场景层独立测到的 FTS 行减少量对账 | `python3 tools/proto/test_correctness.py` → **7/7 场景通过**，S3 12→**13** 项、S5 8→**9** 项断言；报告里 `deletions.fts_rows_deleted` = 41 行（S3）/ 396 行（S5），与场景层实测差值一致 |
| 16 | T4 schema | 两字文本（「备注」「已阅」）在 trigram 下无法被 FTS 命中，测试与 README 未提及 | **已修**。README「范围之外」新增一条，写明长度 < 3 的版本进得了索引但 phrase 永不命中、由 3.4 的限定范围扫描覆盖（并引用 T3 §6 的实测：限定「7 天 + 指定应用」后这类查询召回 100%），因此 S3 的「删除后 FTS 不再命中」对这类短文本不适用；S7 新增一行**口径说明**（不作断言）统计这类版本数 | 同上运行。报告 S7：「长度 < 3 的 text_version（trigram 索引不到，走扫描路径）**4 个**，其中 4 个有 FTS 行但 phrase 查询永远不命中；样例：「备注」、「已阅」」 |
| 17 | T5 容量 | 报告 §1 称「热 20 个样本」，实际有查询被时间预算缩减到 7 / 18 | **已修**。§1 的 p50/p95 口径改成现算：写明缩减规则 `max(3, reps × 200 / 单次毫秒)`、本轮实际热样本 **7–20 个**、冷样本 10 个；§5 表下自动列出被缩减的查询与逐规模 n | `python3 measure.py --report-only --date 2026-09-06`；报告 §5 脚注：`路径命中 0 行…`（12m: n=7）、`中文三字以上…`（12m: n=18）、`中英混排短语…`（12m: n=18），其余满 20 |
| 18 | T5 容量 | 与 2.4 的「0.3 GB/月」对比时只按 GiB 算，2.4 未注明进制，倍数与「撑几个月」两处依赖进制解释 | **已修**。§7 对比表与 §8 验收对照表**同时给出两套口径**：0.567 GiB/月 = 609 MB/月；对 0.3 GB 目标 **1.89×（GiB）/ 2.03×（十进制 GB）**；对 1 GB 上限 57% / 61%；5 GB 配额 **8.8 个月（5 GiB）/ 8.2 个月（5 GB 十进制）**；12 个月 6.795 GiB = 7.30 GB。并写明建议在 2.4 里把进制定死 | 换算复核：`580.9 MiB × 2^20 / 1e6 = 609.1 MB`、`609/300 = 2.03`、`5000/609 = 8.2`、`6.795 GiB = 7.30 GB`，与报告一致 |
| 19 | T5 容量 | `--max-build-min` 帮助文字写「超过则跳过并线性外推」，代码里只有 `continue`，外推路径没实现 | **已修（实现 + 实跑验证）**。新增 `extrapolate_scale()`：超时不实建，按天数线性放大行数、正文字节与库文件字节，条目打 `extrapolated=True`；`write_report` 把这类条目**只放进 §2** 并标「**线性外推**，未实建」，§3–§5 各表一律不含它，§5 另有一句说明；帮助文字与 README 参数表同步改写。顺带新增 `--results-dir`，试跑不会覆盖 `results/` 存档 | `python3 measure.py --scales 1,3 --days-per-month 2 --max-build-min 0.02 --cold-rounds 2 --hot-reps 3 --date probe-extrap --build-dir ~/Library/Caches/brosis-build/proto-t9 --results-dir ~/Library/Caches/brosis-build/proto-t9` → 日志「跳过实建 3 个月…改为按天数线性外推」；报告 §2 出现「3 个月（**线性外推**，未实建）… 建库耗时 —」，§5 出现「3 个月是线性外推的规模…不在这张表里」。**正式交付的 2026-09-06 那份三个规模都是实建，不受影响** |
| 20 | T5 容量 | 原报告 §6.2 的 8640 次/天是「12 h ÷ 5 s」，容量模式铺满 24 h，对 24 h 窗口查询的行数分布不同 | **已修**。§1 口径新增一条，写明两种铺法捕获数与字节数一致（**容量结论不受影响**）、受影响的是 `get_context(hours=24)` 这类按时间窗口取行的查询、本报告这几个延迟数字偏保守；`tools/proto/README.md` 的口径表同步加一行 | `python3 measure.py --report-only --date 2026-09-06`；报告 §1 第 2 条即为该说明 |
| 21 | T5 容量 | 冷测子进程在计时前先跑 `load_params()`，会预热部分文件缓存，冷数字是下界 | **不改代码，改为补充披露**（理由见第 3 节）。§1 的「冷」口径把这条成因写进去：`load_params()` 内含 `ORDER BY ts DESC LIMIT 20`、`MIN(vrow) WHERE created_at >= ?`，会把部分索引页与 `observations` 尾部数据页读进 OS 文件缓存，等于部分预热；与「没清 macOS 文件缓存」方向一致，真实冷启动只会更慢 | 同上；报告 §1「冷」条目已含「还有第二个成因：…等于给后面的冷查询做了部分预热」 |
| 22 | T6 app | `EventSkeleton` 把 `sessionDidResignActive/DidBecomeActive` 当锁屏订阅，而它们只在快速用户切换时触发，真锁屏时 `trigger=screen_locked` 永远写不进去 | **已修**。锁屏改成两路信号并用一个标志位去重：① **前台应用 = `com.apple.loginwindow`** 直判（`didActivateApplication` 里判，登录窗口不做 AX 附着），② 分布式通知 `com.apple.screenIsLocked` / `Unlocked` 作补充；启动时用 `SystemState.screenLocked()`（`CGSessionCopyCurrentDictionary`）初始化标志位、不补记事件。`sessionDidResignActive/DidBecomeActive` 保留但改记新 trigger **`user_switched_away` / `user_switched_back`**（`BuildInfo.ObservationTrigger` 新增两项）。app README 第 8 节改写成一张两路信号表，并注明与 `tools/probe/appswitch.swift` 是同一套判定 | `swift build --scratch-path ~/Library/Caches/brosis-build/app-t9` → `Build complete!` 无警告；`./build_app.sh` 七步全过；`codesign --verify --deep --strict` → `valid on disk` + `satisfies its Designated Requirement`；`brosis --self-check` → **13 项全过**，退出码 0。**未运行 GUI**。旁证：`tools/probe` 的 LaunchAgent 在本机实际收到过 `com.apple.screenIsLocked/Unlocked`（23:54 与 00:04–00:08 两次成对），日志已抄进 smoke 报告第 4 节 |
| 23 | T6 app | 菜单状态只在事件回调里刷新，用户在系统设置里授权后回到菜单仍显示「未授权」；README 第 5 步与实际行为不符；屏幕录制首次授权要重开 app 未提 | **已修**。`AppDelegate` 实现 `NSMenuDelegate`，菜单挂 `delegate`；`menuWillOpen` 重新取权限快照刷新两行状态，若权限已补齐且采集流未运行则**自动 `startCapture` + 起事件骨架**并把状态改成运行中；`requestPermissions` 在快照仍缺权限时记一条 `permission_request_pending` 日志说明这是正常路径。README 第 5 节第 3 步改成「点弹窗那一刻两行状态不会变…在系统设置里拨完开关后回到菜单栏重新展开一次菜单即可，不需要再点一次请求权限」，并新增「**屏幕录制首次授权通常要求退出重开 app**」的说明 | 同上构建 / 签名 / 自检全过（自检不启动 GUI，不触发 TCC）。行为改动属 GUI 路径，按约束**未做人工 GUI 验证**，留给 E4 手工验收 |
| 24 | T6 app | `app_skeleton_2026-09-06.md` 第 34 行写「1,813 行，+98 行」，第 231 行写「净增 95 行（1,715 → 1,810）」 | **已修**。第 231 行改为「净增 **98 行（1,715 → 1,813）**，与第 2 节的行数表一致」；同时在第 2 节标注 T9 之后的实测行数，并在文末新增修订记录 | `wc -l app/Sources/brosis/*.swift` → T9 后 **1,898 行**（T9 前 1,813 行）；修订记录里同时记了签名后可执行文件 362,048 字节 / `.app` 376 KiB |
| 25 | T6 app | 结果文件自定的「全文不出现该符号」口径没贯彻，第 21 / 300 行仍写出 `CGWindowListCreateImage` 字面量 | **已修**。两处改成「不出现已废弃的旧版窗口截图 API（`CGWindowList*` 家族）」，并明确写出**约束的范围是 `app/` 目录与签名后的二进制**，报告为说清约束而写出符号名属于描述不是引用 | `grep -rn CGWindowList app/` → 0 处；`nm -u`、`strings` 在签名后的可执行文件里各 0 处 |

## 2. 顺带修的一致性问题（不在 25 条清单里）

| 项 | 改动 | 验证 |
|---|---|---|
| F8 单位口径扩到其余脚本 | `measure.py` 的 `human()` / `mb()` / `gb()`、进度打印、`gen_synth.py --digest` 的统计打印、`test_correctness.py` 报告表头，全部由 `KB/MB/GB`（实为 2^10/2^20/2^30）改成 `KiB/MiB/GiB`；`capacity_conclusions.md` 里 14 处同类标签一并改 | `grep -n "[0-9] MB\b" tools/proto/results/capacity_2026-09-06.md` → 只剩显式标注「十进制」的那几处 |
| `tools/bench/README.md` 的 OCR 行过时 | 原文还写着「测 3840×2160 …评审 F6 指出没做同源缩放，结论待重做」，实际 v2 已按 F6 重做。改为 T2 的正确描述，并新增「T2 怎么跑」一节（含「只改结论文字时不用重跑基准」的说明）与 `ocr_report.py` / `ocr_report_conclusions.md` 两行 | 人工核对 `tools/bench/results/ocr_bench_2026-09-06.md` 的实际内容 |
| `measure.py` 新增 `--results-dir` | 试跑不再有覆盖 `results/` 存档的风险；README 参数表与示例同步 | 编号 19 的验证命令即用了它 |

## 3. 唯一一条「不改」的理由（编号 21）

把 `load_params()` 挪到父进程、用 argv/stdin 把参数传给冷测子进程，这个改法本身没问题，但会**让已交付的冷延迟数字与代码对不上**：
`capacity_2026-09-06.json` 里的冷数字是改动前的代码测出来的，要保持一致就得重测；而 12 个月规模单是建库就 **11 分 29 秒**，
三个规模加敏感性变体重跑一轮之后，`capacity_conclusions.md` 里 §7 起所有人写的结论数字（每月 580.9 MiB、索引 0.786 倍、
压缩比 0.597 等等）全部要跟着改一遍——为一条「补充成因」付这个代价不划算。

报告本来就已经把冷数字标成**下界**（§1 与 §10.4），这条补充只是把第二个成因也写清楚，**方向与已有披露一致，不会让读者高估冷性能**。
真要拿冷延迟当验收数，正确做法是 M1 在能提权的环境里 `purge` 之后重测，而不是只挪一次 `load_params()`。

## 4. 改动清单

**代码**

- `tools/probe/appswitch.swift`（rotate 收口）、`tools/probe/com.brosis.probe.plist`（注释）
- `tools/bench/ocr_report.py`（`compute_facts()` + 占位符替换 + 样式名偏差校验）、`tools/bench/ocr_bench.swift`（样式名）
- `tools/bench/fts_compare.py`（复核作用域、`app_scope_probe()`、MiB、§9.4 现算、§1/§6/§9.5 文案）
- `tools/proto/test_correctness.py`（`fts_rows_deleted` 实测 + 2 条断言 + S7 短文本口径行 + 单位）
- `tools/proto/gen_synth.py`（单位）、`tools/proto/measure.py`（口径 3 条、`extrapolate_scale()`、`--results-dir`、单位）
- `app/Sources/brosis/BuildInfo.swift`（2 个新 trigger）、`app/Sources/brosis/EventSkeleton.swift`（锁屏两路信号）、
  `app/Sources/brosis/AppDelegate.swift`（`NSMenuDelegate.menuWillOpen`）

**文档 / README**

- `tools/probe/README.md`、`tools/bench/README.md`、`tools/proto/README.md`、`app/README.md`
- `tools/bench/ocr_report_conclusions.md`、`tools/proto/capacity_conclusions.md`

**重新生成的结果文件**（全部由脚本产出，无手工编辑）

- `tools/bench/results/ocr_bench_2026-09-06.md`
- `tools/bench/results/fts_compare_2026-09-06.md` / `.json`
- `tools/proto/results/correctness_2026-09-06.md`
- `tools/proto/results/capacity_2026-09-06.md`

**手工编辑的结果文件**（本身就是人写的记录，不是生成物）

- `tools/probe/results/smoke_2026-09-06.md`（含修订记录）
- `tools/bench/results/app_skeleton_2026-09-06.md`（含修订记录）

## 5. 需要你操作的事（blockers）

1. **探针二进制要重装才生效**：编号 4 改了 `appswitch.swift`，本机 LaunchAgent 跑的仍是旧二进制。
   3 天数据采集还在进行中，**现在不要重装**（重装会重启进程，虽然 `current.json` 能恢复未收口区间，但没必要冒险）。
   2026-09-09 出完 D2 清单后再执行一次 `tools/probe/install.sh` 即可。
2. **`app/` 的菜单与锁屏改动没有做 GUI 验证**（约束里不允许运行 GUI）。E4 手工验收时请重点看两条：
   ① 在系统设置里拨完开关后**重新展开一次菜单**，两行状态应变「已授权」且状态变「运行中」（屏幕录制可能要退出重开 app）；
   ② 锁一次屏再解锁，`observations` 里应出现 `trigger=screen_locked` 与 `screen_unlocked` 各一条；
   快速用户切换才会出现 `user_switched_away` / `user_switched_back`。
