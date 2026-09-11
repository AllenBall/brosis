# 飞书 Step 3：OCR 回退收口——弹窗只记标题、水印过滤、DOM 区域帧变不 OCR、剪点表情人名（0.7.3）

2026-09-11 11:4x–11:5x，M4 Air、飞书 Lark 7.74.21。依据 `feishu_capture_review_2026-09-11.md` §4 Step 3 与 0.7.2 装机后
的真机证据。构建 `~/Library/Caches/brosis-build/dist-app/brosis.app`（**0.7.3**，自检 **260 项全过**，签名 + 公证 Accepted + staple），
**已装到 /Applications**（11:49，正常退出 → 备份旧 app 到 `~/Library/Caches/brosis-build/installed-backup/` → ditto → 重开，开库成功）。
0.7.2 也在 11:39 用同一套流程装过一次，两次装机之间的真机数据见 §2。

一句话：**弹窗（搜索 / 转发 / 名片）现在只记标题、completeness = excluded、不 OCR；走到 OCR 的飞书 / 会议画面先剥平铺水印；
Chrome / 飞书 / 会议的 DOM 区域不再因帧变化排 OCR；飞书正文剪掉 `.message-reactions`。**

## 1. 改了什么

| 项 | 改动 | 依据 |
|---|---|---|
| 弹窗只记标题 | `AdapterRule.titleOnlyWindowPrefixes` + `skipsBody(windowTitle:)`；`EventSkeleton` 命中时不读正文、不排 OCR，`completenessWithoutScan(titleOnly:)` → `.excluded`；飞书填 `["ModalWebViewWidget - "]` | 0.7.2 真机 evidence 19456：用户名片弹窗触发整窗 OCR，把主窗口、侧栏、水印全记进去（2390 字节、`我 / 对方` 归属全错） |
| 水印过滤 | 新文件 `OCR/WatermarkFilter.swift`：从一帧识别结果里**学**水印（同一串归一化后 5–24 字、≥ 3 次、且分布在 ≥ 2 列 ≥ 2 行），或用 `defaults adapter.watermark.text`，或沿用上一次学到的；对每个识别条目按 token 剥（不长于水印 + 2 且七成字符落在水印字符集 ⇒ 残片；粘在正文头尾的整串剥掉），剥空的条目丢掉，再按阅读顺序重建文本与置信度；整块只剩水印 ⇒ 当没出字。`AdapterRule.watermarkFilter` 飞书 / 会议为 true，在 `CaptureCoordinator` 识别之后、归属与脱敏之前生效 | evidence 16514 / 4226 / 4157 / 19456 |
| DOM 区域帧变不 OCR | `webAreaRegions()`（Chrome / 会议）加 `ocrOnFrameChange: false`（飞书两块区域 Step 1 已加） | 复查 F3：15692 那次 OCR 就是 `frameChangedAXStable` 触发的 |
| 剪点表情人名 | `RegionRule.pruneClasses` / `pruneMaxDepth`（只对区域根下 12 层内的 AXGroup 读 class）；飞书正文剪 `message-reactions` | 0.7.2 真机 evidence 19481：`同事乙 ⏎ 同事乙`、`<用户名> ⏎ , ⏎ 同事己` 混在对话里 |
| 自检 | 弹窗 3 项 + excluded 映射、OCR 收口形状、水印学习 4 条、水印剥离 7 条（含两条误伤反例）；单聊 / 群聊合成树加了 `.message-reactions` 节点并断言不进库 | 256 → 260 项 |

没动：「1 条新消息」横幅（class 未量到）、会议增强形态（Step 6）、开关关的路径（Step 4）、`file://` URL（Step 5）。

## 2. 真机数据

**0.7.2（11:39 装机后，用户自己在用）**

| evidence | 窗口标题 | 内容 |
|---|---|---|
| 19481 / 19473 | 同事乙 | `我：… 同事乙：@… @… …逻辑如下… 我：…` —— 单聊前缀、链接预览卡、日期都在；`<用户名>` 独立行 = 点表情人名（本轮已剪） |
| 19457 | 某需求沟通群 | 群聊：发送者名自带，无前缀；`同事乙 ⏎ 同事乙` 是点表情人名 |
| 19456 | ModalWebViewWidget - main-window:userCardModal:default | **整窗 OCR 2390 字节**：侧栏、主窗口、水印 ×10 以上、`我 / 对方` 归属——本轮要消灭的目标 |

**0.7.3（11:49 装机后，computer use 点开 ⌘K 搜索弹窗）**

| evidence | 窗口标题 | completeness | captureMethod | 正文 |
|---|---|---|---|---|
| 19894 / 19891 / 19890 | ModalWebViewWidget - search:search-command-bar:default | **excluded** | ax | **空**（没有 OCR 片段） |
| 19887 | 某业务测试群 | partial | adapter | 会话名 + 消息（弹窗前那条） |

探针（构建目录二进制，群聊「某业务测试群」）：551 字 / 460 节点 / 48 ms，OCR 请求 0。

**没验到的**：水印过滤在真帧上的学习效果。现在 AX 通道通了，飞书主窗口不再走 OCR；能触发 OCR 的只剩图片查看器与会议窗口，
这次没有现成的图片可点。留到下一次自然出现 `ocr:feishu.*` / `ocr:feishu_meeting.*` 片段时核对：正文里不应再有「<用户名> <组织名>」的整串与残片。

## 3. 验收口径（复查 §4）与状态

| 口径 | 状态 |
|---|---|
| `adapter:feishu.body` = 当前会话可见消息，不含其它会话预览 | ✅ 0.7.2 / 0.7.3 真机 |
| `windows.title` 为会话名 | ✅（同事乙、某需求沟通群、某业务测试群、某外部用户群��） |
| `ocr:feishu.*` 无跨窗口内容 | ✅ 弹窗路径已封（19894）；主窗口不再 OCR；剩图片查看器 / 会议待自然验证 |
| 单次扫描 < 150 ms | ✅ 47–119 ms |
| 观察数 / 文本版本数下降 | 待 30 分钟以上真实使用后对比 |
