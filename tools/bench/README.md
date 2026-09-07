# tools/bench — 本机实测脚本

实验工具，不进产品路径、不碰真实数据库密钥（《实施计划》3.1）。
**所有编译产物写 `~/Library/Caches/brosis-build/<任务名>/`，不要在项目目录里生成中间文件**（项目目录在 iCloud Drive 里）。

| 文件 | 用途 | 运行 |
|---|---|---|
| `fts_compare.py` | **M0 T3**：全文检索分词方案对照（计划 3.4 / 实验 E2 离线部分，评审 F3）。合成 3200 条观察语料 + 68 条固定查询，跑 A/B/C/C0/D/E/扫描共 13 档，出 Recall@10、Precision@10、Recall_all、报错率、索引体积、建索引耗时、冷热延迟 | 见下方「T3 怎么跑」 |
| `fts_queries.json` | T3 的固定查询集：68 条、9 类、每类含负例，附种植规格（每条查询要种进几篇、哪种文本） | 数据文件，被 `fts_compare.py` 读取 |
| `nl_tokenize_probe.swift` | T3 附加实测：Swift 侧 `NLTokenizer` / `CFStringTokenizer` 的中文分词质量与吞吐，判断「显式分词」在产品里可不可行（jieba 是 Python 库，进不了 Swift app） | 见下方 |
| `fts_review_probe.py` | 评审 F3 的最小复现：三种分词配置各插一条 `项目计划与知识图谱 research` 再搜三个词。**只读参考，不要改** | `python3 tools/bench/fts_review_probe.py` |
| `ocr_bench.swift` | **M0 T2**（v2，已按 F6 重做）：同一张 3456×2234 位图高质量下采样到 2560×1664 / 1728×1117，5 种样式 × 3 分辨率 × accurate/fast × 语言纠错开关 = 60 组，出 CER（严格/去空白/宽度折叠）、标识符召回、p50/p95。结论见 `results/ocr_bench_2026-09-06.md` | 见下方「T2 怎么跑」 |
| `ocr_report.py` | 把 `ocr_bench` 的 JSON 渲染成 Markdown，并把 `ocr_report_conclusions.md` 拼在后面。结论里的数字用 `{{占位符}}` 写，由 `compute_facts()` 从 JSON 现算（有未定义的占位符直接报错退出） | `python3 ocr_report.py results/ocr_bench_2026-09-06.json` |
| `ocr_report_conclusions.md` | OCR 报告 §3 起的结论段落（人写的），**数字一律用占位符**，不要手抄 | 被 `ocr_report.py` 读取 |
| `fm_check.swift` | 探测 Apple Foundation Models 可用性并跑一次分类 | `swiftc -O -parse-as-library fm_check.swift -o ~/Library/Caches/brosis-build/fm/fm_check && ~/Library/Caches/brosis-build/fm/fm_check` |
| `extract_prompt.txt` / `extract_prompt_long.txt` | 结构化抽取提示词（短/长观察） | 用 `uvx --from mlx-lm python` 调 `mlx_lm.load()` + `generate()`，`apply_chat_template(..., enable_thinking=False)` |
| `powermetrics_pair.sh` | **M0 T5**：E7 成对资源测量**模板**（记录器开 / 关跑同一任务，采 `powermetrics` 与 `ps`，出 CSV）。记录器还不存在，现在只保证 `--dry-run` 能走通 | 见下方「E7 成对资源测量怎么跑」 |

结果：T3 见 `tools/bench/results/fts_compare_2026-09-06.md`；
T5 容量与延迟见 `tools/proto/results/capacity_2026-09-06.md`（脚本在 `tools/proto/measure.py`）；
OCR 与 FM 见 `docs/可行性调研报告.md` 第 2 节。

`results/` 里还放了两份**代码不在本目录**的实验结果，别去这里找脚本：

| 结果文件 | 实验 | 代码在哪 |
|---|---|---|
| `results/app_skeleton_2026-09-06.md` | T6 · E4 采集骨架的构建与签名 | `app/` |
| `results/e9_runtime_2026-09-07.md` / `.json` | **T7 · E9 内嵌推理运行时、模型管理器与分发验证**（mlx-swift-lm 嵌入、HF 下载器与 sha256 校验、Developer ID + hardened runtime、MRL 截断、与 Python 参考对照） | `tools/e9/`（见 `tools/e9/README.md`） |

---

## T3 怎么跑

### 完整跑（含方案 D，需要 jieba）

```bash
cd "<项目目录>"
export UV_CACHE_DIR="$HOME/Library/Caches/brosis-build/uv-cache"   # 别让 uv 缓存落进项目目录
export PYTHONWARNINGS=ignore                                        # jieba 有 SyntaxWarning
uv run --no-project --python "$(which python3)" --with jieba python tools/bench/fts_compare.py
```

`--python "$(which python3)"` 是必须的：`uv` 默认会挑自己的 Python 3.11（SQLite 3.50.4），
指定本机 python3 才能用到 3.14.7 + SQLite 3.53.4，和报告里的环境一致。

### 只跑标准库部分（跳过方案 D）

```bash
python3 tools/bench/fts_compare.py
```

脚本检测不到 jieba 时会打印 `jieba : 不可用（方案 D 跳过）`，其余 12 档照跑，报告里 D 相关的行自动消失。

### 常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--build-dir` | `~/Library/Caches/brosis-build/t3-fts` | 中间数据库目录（每档一个 `.sqlite`，跑完保留，方便自己拿 sqlite3 CLI 复查） |
| `--out-dir` | `tools/bench/results` | 报告输出目录 |
| `--date` | `2026-09-06` | 输出文件名里的日期 |
| `--deep-limit` | `5000` | 算 `Recall_all` 时取多少条候选；调小会让 `Recall_all` 偏低 |
| `--cold-reps` / `--hot-reps` | `5` / `20` | 每条查询的冷/热延迟采样次数 |

整轮约 12 秒（M4 Max，含 jieba）。输出两个文件：`fts_compare_<date>.md`（人读）和 `.json`（逐查询原始数据，含每条查询走了哪些通道、`app_scope_scan` 限定应用的扫描实测、`collate_probe`）。

报告里所有数字都由脚本从本次运行算出，**不要手工编辑生成的 `.md`**：改了结论要改 `render_md` / `render_conclusion` 再重跑。

### 结果可复现

语料由 `fts_queries.json` 里的 `seed`（20260906）确定性生成，同一台机器上重跑逐字节一致，只有延迟数字会抖。
真值不是靠「种了几篇」推断的，而是语料生成后用全表扫描重算；负例如果被污染，脚本直接退出码 2 并打印是哪条。

### 改查询集

编辑 `fts_queries.json`：

- `q` 查询串，`class` 类别（必须在顶层 `classes` 里），`expect` 是 `hit` 或 `none`；
- 可选的 `plant`：`{"count": N, "kinds": [...]}`，把 `q` 种进 N 篇指定类型的文档。
  `kinds` 取值见 `fts_compare.py` 的 `KIND_COUNTS`：`zh_doc` / `mixed` / `code` / `url` / `path` / `chat_feishu` / `chat_wechat` / `terminal`。
- 不写 `plant` 就完全靠语料里自然出现（适合 `sqlite`、`帧` 这种高频词）。
- 加负例时如果不小心撞上了语料里的词，脚本会报「负例被污染」并列出 id。

### 跑 Swift 分词探针

```bash
mkdir -p ~/Library/Caches/brosis-build/t3-fts
swiftc -O tools/bench/nl_tokenize_probe.swift -o ~/Library/Caches/brosis-build/t3-fts/nl_probe
~/Library/Caches/brosis-build/t3-fts/nl_probe
```

它的输出是手工抄进 `fts_compare.py` 的 `NL_OUTPUT` / `NL_PROBE` 常量的（报告 §10 那两张表）。
换机器或换 Xcode 版本后如果数字变了，要同步更新那两个常量再重跑 `fts_compare.py`。

---

## T3 结论速览（2026-09-06，本机实跑）

- 原可行性报告选的 `trigram, detail=column`：68 条查询里 **54 条报 `phrase queries are not supported`**，Recall@10 = 0。评审 F3 成立。
- `unicode61` 原样对中文基本无效：中文两字词 Recall@10 **8.3%**，三字以上 **16.7%**，单字 **0%**；英文/标识符/URL/路径/错误码 100%。
- **推荐 B+E+V**：汉字 bigram 预处理 + `unicode61` + 精确字段列 + 单字补扫描 + 候选子串复核。
  Recall@10 **97.0%**、Precision@10 **100%**、索引净增 **0.99 MiB（正文的 0.55 倍）**、热查询 p95 **0.9 ms**（3200 条 / 1.82 MiB 正文）。
  子串复核**只作用于 FTS 候选**，精确字段与扫描通道的命中直接保留（否则 urls/files 命中而正文不含该串的结果会被误删）。
- trigram `detail=full` 能做到精确子串且不需要复核，但索引是正文的 **1.88 倍**（B 的 3.4 倍），本轮因体积不选。
- 单个汉字必须走限定时间/应用范围的 `LIKE` 扫描，三种索引在单字上召回都是 0。
  限定「最近 7 天 + 指定应用」后，10 条一两字查询在范围内召回 **100%**，热 p50 0.02–0.10 ms，比只限时间再快 1.4×–11.7×（走 `docs(app, ts)` 复合索引，见报告 §6）。
- schema 细节：`COLLATE NOCASE` 要写在**列**上而不是只写在索引上，否则 `host = ?` 走不了索引，20,000 行上**差两个数量级**（实测 100–120 倍，0.38 ms → 0.003 ms 量级；这个比值每次运行都会抖，所以报告 §7 与 §9.4 的建表注释都由脚本从**同一次** `collate_probe` 计算，两处永远一致，README 这里只写量级）。
- 体积一律 2^20 进制并标 **MiB**（评审 F8），字节原值同时给出。

完整数字、口径与建表语句见 `results/fts_compare_2026-09-06.md`。

---

## T2 怎么跑（OCR 基准）

```bash
cd "<项目目录>/tools/bench"
mkdir -p ~/Library/Caches/brosis-build/ocr
swiftc -O -o ~/Library/Caches/brosis-build/ocr/ocr_bench ocr_bench.swift
~/Library/Caches/brosis-build/ocr/ocr_bench \
  --out "$PWD/results" --samples ~/Library/Caches/brosis-build/ocr/samples \
  --runs 12 --warmup 2 --date 2026-09-06
python3 ocr_report.py results/ocr_bench_2026-09-06.json    # 只重渲染报告，不重跑 OCR
```

整轮 720 次 OCR 调用、约 7 分钟。**只改结论文字时不用重跑基准**，改完
`ocr_report_conclusions.md` 直接跑第二条命令即可。

结论里需要新的数字时，在 `ocr_report.py` 的 `compute_facts()` 里加一项，
再在结论里用 `{{名字}}` 引用——不要把数字手抄进 Markdown。

---

## E7 成对资源测量怎么跑（`powermetrics_pair.sh`）

对应《实施计划》2.4 验收口径的「资源」行与附录 A 的 **E7**：
同一任务成对运行（记录器开 / 关），接电与电池各一次，记录全进程 CPU、WindowServer、
内存、磁盘增长、能耗。

### 现在能跑到哪一步

M1 的记录器还不存在，所以这个脚本目前是**模板**：

- `--dry-run` **可以完整走通**（本机已实跑），验证参数解析、目录布局、两个臂的时序、
  `ps` 采样、磁盘与电池快照、汇总 CSV 的列和差值计算；
- `--dry-run` 下**不采 `powermetrics`**，`power_A.csv` / `power_B.csv` 只有表头，
  `power_*.log` 里写着「正式测量会执行哪条命令」；
- `--recorder-start` 留空时脚本会明确警告：A/B 两个臂做的是同一件事，差值只反映测量噪声。

### 需要 sudo（必须由你本人操作）

`powermetrics` 只能以 root 运行，否则直接报 `must be invoked as the superuser`。
正式测量时二选一：

```bash
sudo ./tools/bench/powermetrics_pair.sh --task '...' --minutes 30 --label plugged
# 或者先拿票据，再普通运行（脚本会自己给 powermetrics 加 sudo -n）
sudo -v && ./tools/bench/powermetrics_pair.sh --task '...' --minutes 30 --label plugged
```

**密码提示必须由你输入**，脚本不代劳，Agent 也不能代劳。这是 T5 留给你的唯一手工步骤。

### dry-run（不需要 sudo，几十秒跑完）

```bash
cd "<项目目录>"
./tools/bench/powermetrics_pair.sh --dry-run --minutes 9 --interval 3 \
    --label dryrun-demo --task 'sleep 9' \
    --data-dir ~/Library/Caches/brosis-build/proto
```

`--dry-run` 把 `--minutes` 当秒用，所以上面这条每个臂各跑 9 秒。

### 记录器就位后的正式跑法

```bash
sudo ./tools/bench/powermetrics_pair.sh \
    --minutes 30 --interval 5 --label plugged --power-source plugged \
    --task 'osascript tools/bench/tasks/task_5min.scpt' \
    --recorder-start 'launchctl kickstart -k gui/$(id -u)/com.brosis.recorder' \
    --recorder-stop  'launchctl kill SIGTERM gui/$(id -u)/com.brosis.recorder' \
    --data-dir ~/Library/Application\ Support/brosis
# 拔掉电源，再跑一遍
sudo ./tools/bench/powermetrics_pair.sh ... --label battery --power-source battery
```

`--power-source` 只是标签，脚本**不会**替你切换电源——插拔电源线要你自己动手。

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--task` | 必填 | 两个臂里跑的同一个任务；只测空载就传 `'sleep 1800'` |
| `--minutes` | `30` | 每个臂的时长（`--dry-run` 下当秒用） |
| `--interval` | `5` | 采样间隔（秒），同时决定 `powermetrics -i` |
| `--label` / `--power-source` | `pair` / `plugged` | 目录名与标签 |
| `--recorder-start` / `--recorder-stop` | 空 | B 臂前后拉起 / 停掉记录器 |
| `--data-dir` | `~/Library/Application Support/brosis` | 算磁盘增长的目录 |
| `--watch` | `WindowServer\|brosis\|Xcode\|python3` | `ps` 里要单独留行的进程名正则 |
| `--out` | `~/Library/Caches/brosis-build/power` | 输出根目录 |

### 输出

写到 `<out>/<label>-<时间戳>/`：

| 文件 | 内容 |
|---|---|
| `summary.csv` | A/B 配对汇总与差值——这份是写进报告的那张表 |
| `power_A.csv` / `power_B.csv` | `powermetrics` 解析后的时序：`ts,arm,metric,value,unit`，metric 含 `combined_power` / `cpu_power` / `gpu_power` / `ane_power` / `dram_power`（mW） |
| `power_A.log` / `power_B.log` | `powermetrics` 原始输出，保留以便复核解析（`--show-process-energy` 的逐进程能耗只在原始日志里） |
| `ps_A.csv` / `ps_B.csv` | `ts,arm,pid,pcpu,pmem,rss_kb,command`；`pid=-1` 那行是全进程 CPU / MEM / RSS 之和 |
| `disk.csv` | 两个臂前后 `du -sk` 的数据目录字节数 |
| `battery.csv` | 两个臂前后的 `pmset -g batt` 快照 |
| `meta.txt` | 参数、机型、系统版本、`pmset -g therm` 热状态 |

### 已知限制

- **CPU 口径**：`ps` 的 `%CPU` 是进程生命周期均值不是瞬时值，长期驻留的进程会被低估；
  真正的瞬时能耗以 `powermetrics` 的 `combined_power` 为准，`ps` 只用来定位是谁在跑。
- **配对噪声**：A/B 两个臂是**先后**跑的，不是同时；机器上其他活动会直接进差值。
  正式测量前请关掉别的重活，两个臂之间脚本已经留了 10 秒回基线。
- **热状态**：只在 `meta.txt` 里记了起始的 `pmset -g therm`，没有做逐采样的热压力时序。
  Air 上做 E9 时需要补这一项。
- **内存口径（`rss_kb` 会低估 GPU 工作负载）**：`ps` 的 RSS **不含 Metal 缓冲**。
  Apple Silicon 是统一内存，Metal / MLX 的缓冲计入进程的 `phys_footprint` 而不计入 RSS，
  E9 实测批量嵌入时两者差约 8 倍（RSS 766 MiB vs footprint 6.21 GiB，见
  `results/e9_runtime_2026-09-07.md` 第 3.5 节）。**凡是臂里跑了 GPU 推理，内存结论要以
  `/usr/bin/time -l` 的 `peak memory footprint`（或 `task_info(TASK_VM_INFO)` 的
  `ledger_phys_footprint_peak`）为准**，`ps_*.csv` 的 `rss_kb` 只当参考。
