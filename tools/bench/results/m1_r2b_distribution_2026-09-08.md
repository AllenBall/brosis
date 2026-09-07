# M1 第二轮 b 批 · T10 分发管线（DMG、Sparkle 2 签名更新、发布流程）

日期：2026-09-08　机器：M4 Air / 16 GiB / 无风扇 / macOS 26.6　Swift 6.3.3（语言模式 v6）
对应计划：4.2「打包与分发管线：Developer ID 签名、公证、DMG、签名更新（Sparkle 或同类），
签名身份跨版本保持不变」、4.2.1 的 R2「分发管线」。

> **口径**：MiB = 2^20，GiB = 2^30。字节数一律 `stat -f%z`，目录体积 `du -sk`（KiB）。
> 所有原始输出在 `~/Library/Caches/brosis-build/m1-dist/results/`，本文每个数字都能在那儿找到出处。
> 构建产物一律在 `~/Library/Caches/brosis-build/` 下，项目目录里没有任何构建产物（第 6 节有 `find` 记录）。

---

## 1. 做了什么

| # | 东西 | 位置 |
|---|---|---|
| 1 | Sparkle 2 作为 SwiftPM 依赖（`exact "2.9.6"`），锁进 `Package.resolved` | `app/Package.swift`、`app/Package.resolved`（新增） |
| 2 | `Info.plist` 四个 `SU*` 键：`SUFeedURL` / `SUPublicEDKey`（占位符）/ `SUEnableAutomaticChecks=false` / `SUAutomaticallyUpdate=false`，另加 `SUScheduledCheckInterval`、`SUEnableJavaScriptInReleaseNotes=false` | `app/Support/Info.plist` |
| 3 | `UpdaterConfig`（纯函数配置检查）+ `UpdaterController`（懒创建 Sparkle、「检查更新…」菜单入口）**没有改 `AppDelegate.swift`** | `app/Sources/brosis/Updater.swift`（新增，183 行） |
| 4 | `build_app.sh`：拷 `Sparkle.framework` 进 `Contents/Frameworks/`、补 rpath、注入更新公钥、逐个签 Sparkle 内嵌代码、逐个 Mach-O 核 Team ID、从 bundle 跑一次 `--version` | `app/build_app.sh` |
| 5 | DMG 管线：`build_app.sh` → 压缩 DMG（含 `/Applications` 快捷方式）→ 签 DMG → 公证（可跳过）→ `spctl` 评估 → sha256 + `manifest.json` | `dist/build_dmg.sh`（新增） |
| 6 | appcast 生成：找 `generate_appcast`、查私钥、生成并自检签名 | `dist/make_appcast.sh`（新增） |
| 7 | 发布清单（一次性配置、七步流程、两台机器安装验证、TCC 不丢的判据） | `dist/RELEASE.md`（新增） |
| 8 | README 分发章节 3.2 | `app/README.md` |

### 1.1 三条设计口径（写进代码注释与 README，不只是这份文件里的话）

1. **默认不联网。** `SUEnableAutomaticChecks=false`、`SUAutomaticallyUpdate=false`，
   而且 `AppDelegate` 启动时**不创建** updater——`SPUStandardUpdaterController` 只在用户
   点「检查更新…」的那一刻才 `init(startingUpdater: false, …)` 再自己 `try updater.start()`。
   Sparkle 的更新周期是 `start()` 之后的下一个 runloop 才起的，没被创建就一个字节都不发。
   对齐 2.2 硬约束 6「默认不上传」的精神：更新检查也是一次出网，必须由人显式发起。
2. **fail-closed。** 仓库里的 `SUPublicEDKey` 是占位符 `__SUPublicEDKey__`——**故意不是合法 base64**。
   没注真公钥的构建：`UpdaterConfig.issues` 当场拦下并弹框说明，Sparkle 的 `start()` 也会失败，
   `dist/make_appcast.sh` 还会拒绝为它生成 appcast。也就是**装不上任何"更新"**，
   而不是"没验签就装"。真公钥由用户用 `generate_keys` 生成、放在
   `~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt`，
   `build_app.sh` 组装时注入并核对解出来正好 32 字节；**私钥只在用户自己的钥匙串里**，
   不进仓库、不经过任何脚本变量。
3. **签名身份跨版本不变（D13）。** TCC 授权绑 `bundle id + Designated Requirement`。
   `build_app.sh` 的 `--identifier com.brosis.app` 是写死的；`build_dmg.sh` 会把
   Team ID 记进 `manifest.json`，`RELEASE.md` 第 7 节给了升级后逐条核对的命令
   （`codesign -dv --verbose=4` 的 `Identifier` / `TeamIdentifier` / `Authority`，
   以及 `codesign -d --requirements -`）。

### 1.2 Sparkle 怎么进的 bundle（三个坑）

- **rpath**：SwiftPM 把 `Sparkle.framework` 拷到 bin 目录，主程序只链出一条 `@loader_path`
  的 rpath（裸二进制跑得通，框架就在它旁边）。装进 bundle 后 `@loader_path` 是
  `Contents/MacOS`，找不到框架。`build_app.sh` 用
  `install_name_tool -add_rpath @executable_path/../Frameworks` 补一条并当场 `otool -l` 核对。
  **没走 `Package.swift` 的 `.unsafeFlags`**：带 `unsafeFlags` 的清单不能被别的包按版本引用。
- **逐个签，不用 `--deep`**：顺序由内向外——`Installer.xpc` / `Downloader.xpc` →
  `Updater.app` → `Autoupdate` → `Sparkle.framework` → 外层 bundle。反了的话外层的
  `CodeResources` 封印立刻作废。每一件都 `--options runtime --timestamp`
  （公证要求**所有**内嵌代码都带安全时间戳）。
- **一个真踩到的 bug**：第一版用 `case "$item" in *.xpc/*|*.app/*) continue ;; esac`
  过滤"在内嵌 bundle 里的文件"，结果**绝对路径里有 `brosis.app/`**，把所有文件都排掉了，
  `Autoupdate` 漏签（脚本的 `≥ 5 件` 断言当场抓到）。改成先取框架内部的相对路径再匹配。
  这个断言与随后的「逐个 Mach-O 核 Team ID」是两道独立的网，缺一个就漏。

---

## 2. 怎么跑

```bash
# 0) 前置：core 的 vendor 源码就位（一次即可）
sh <项目目录>/core/setup.sh

# 1) 构建 + 签名（首次要能访问 github.com：Sparkle 是远端 binaryTarget）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/m1-dist-app" \
  <项目目录>/app/build_app.sh

# 2) 自检（不弹框、不联网、不碰钥匙串）
"$HOME/Library/Caches/brosis-build/m1-dist-app/brosis.app/Contents/MacOS/brosis" --self-check

# 3) DMG 全流程（本机屏幕锁定，公证做不了）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/dist-app" \
  <项目目录>/dist/build_dmg.sh --skip-notarize

# 4) appcast（没有私钥时走错误路径；有私钥时加 --ed-key-file 或用钥匙串）
<项目目录>/dist/make_appcast.sh
```

`SCRATCH` 必须是绝对路径（用 `$HOME`，不要 `~`）；两个脚本都会当场检查，
并且拒绝把产物写进项目目录。

---

## 3. 实测数字

### 3.1 依赖与体积

| 项 | 值 | 出处 |
|---|---|---|
| Sparkle 版本 | 2.9.6（`exact`），revision `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a` | `app/Package.resolved` |
| `Sparkle.framework` | 3 060 KiB（2.99 MiB），88 个文件，5 个 Mach-O | `du -sk` / `find` |
| 5 个 Mach-O | `Sparkle`（977 808 B）、`Autoupdate`、`Updater.app/…/Updater`、`Downloader.xpc/…/Downloader`、`Installer.xpc/…/Installer` | `final_build_app.log` |
| `brosis.app` 整包 | 9 080 KiB（8.87 MiB）；扣掉 Sparkle 是 6 020 KiB | `du -sk` |
| `Contents/MacOS/brosis` | 4 757 952 B | `stat -f%z` |
| `Contents/MacOS/brosis-mcp` | 452 064 B | `stat -f%z` |
| DMG | 3 827 976 B（3.65 MiB），sha256 `e3c6aed998cadf2b5e2b16fe64a94870d5990517e649fdf056a11288ace80574` | `manifest.json` / `SHA256SUMS.txt` |
| DMG 挂载后 `.app` 占用 | 9 116 KiB（HFS+ 块对齐，比 APFS 上的 9 080 KiB 略大） | `du -sk`（`manifest.json` 的 `installed_kib`） |

> **sha256 与字节数每次构建都会变**：Developer ID 签名里带安全时间戳，DMG 里也带构建时刻，
> 所以同一份源码两次构建的 DMG 不是逐字节相同的。验收时对得上的是**流程与判定**
> （`spctl` 的 rejected/accepted、`--verify --deep --strict`、item 数 == edSignature 数），
> 不是这一串 sha256。另外本批 T8 与 T10 并行改 `app/`，二进制大小随 T8 的进度浮动。

> **口径**：`Contents/MacOS/brosis` 这个数字里含了 T8 同批加进来的适配器与 OCR 代码
> （两个任务并行改同一个包），不是"Sparkle 让主程序涨了多少"。
> Sparkle 对包体的贡献就是那 3 060 KiB 的框架目录。

### 3.2 构建与签名（`final_build_app.log`）

- `swift build`（release，干净 scratch）：**33.85 s**；`brosis-mcp`：4.13 s。
- **warning 数 = 0**（`grep -c 'warning:'`）。
- `Info.plist 十二个必备键齐全（含四个 Sparkle 键；两个自动开关都是 false，源是 https）`
- `Sparkle 内嵌代码共签 5 件`；`Sparkle 的 5 个 Mach-O 全部由同一个 Team ID 签名`
- `codesign --verify --deep --strict` 通过（外层与 `brosis-mcp` 各一次），
  `--verify` 的 `--validated` 行里能看到 `Autoupdate` / `Updater.app` / 两个 `.xpc` 都被验到。
- rpath 两条：`@loader_path` 与 `@executable_path/../Frameworks`（`otool -l`）。
- 从 bundle 里跑 `--version` 成功 → dyld 真的按 rpath 找到了框架。
- `spctl -a -t exec`：`rejected / source=Unnotarized Developer ID`（**预期**，未公证）。

### 3.3 DMG 全流程（`final_build_dmg_skip.log`，干净 scratch）

- 端到端（含从零编译 core + app）：**54.5 s**（`time`，wall clock；三次干净跑 56.43 / 56.41 / 54.52 s）。
- DMG：`UDZO / zlib-level=9 / HFS+`，卷名 `brosis 0.2.0`，3 827 976 B。
- `codesign --verify` DMG：`valid on disk` + `satisfies its Designated Requirement`。
- `spctl -a -t open --context context:primary-signature` DMG：
  `rejected / source=Unnotarized Developer ID`（**预期**）。
- 挂载后：`brosis.app` + `Applications -> /Applications` 符号链接 + `安装说明.txt` 都在；
  `codesign --verify --deep --strict` 里面那份 **通过**；`spctl -a -t exec` `rejected`（**预期**）。
- 挂载后 `brosis.app/Contents/MacOS/brosis --version` 跑得起来 →
  框架随包走、rpath 在 DMG 里也成立；里面 5 个 Sparkle Mach-O 的 Team ID 逐个核过，全一致。
- 产物：`dist/0.2.0/{brosis-0.2.0.dmg, manifest.json, SHA256SUMS.txt}` +
  硬链到 `dist/appcast/brosis-0.2.0.dmg`。

### 3.4 公证的错误路径（`build_dmg_notarize_locked.log`）

不加 `--skip-notarize` 时，脚本在**做 DMG 之前**就停住：

```
==> 3. 公证前置检查
ERROR: 屏幕当前锁定：data-protection 钥匙串不可用，取不到 notarytool 的凭据。
      解锁屏幕后再跑，或者加 --skip-notarize 先出一个未公证的 DMG。
```

判断依据是 `ioreg -n Root -d1 -a` 的 `IOConsoleLocked`。屏幕解锁但没配过 notarytool
钥匙串配置时，走的是另一条分支（`xcrun notarytool history` 探一次），会把
`store-credentials` 两种写法原样打出来。另外还有一道：签名没有安全时间戳
（`TIMESTAMP=none` 构建的）时直接拒绝进公证——那种包公证一定被退。

### 3.5 appcast（`make_appcast_errors.log` / `make_appcast_success.log` / `appcast_signature_verify.log`）

三条错误路径都实跑过，都是 `exit 1` + 一段能照着做的说明：

| 路径 | 触发 | 结果 |
|---|---|---|
| A | 归档目录不存在 | `ERROR: 归档目录不存在：…　先跑 dist/build_dmg.sh` |
| B | 归档里有 DMG，但这份构建的 `SUPublicEDKey` 是占位符 | `ERROR: … 还是占位符（见 manifest.json）`，并给出生成密钥对的完整步骤 |
| C | 公钥已配置，但钥匙串里没有私钥 | `ERROR: 钥匙串里没有 Sparkle 的 Ed25519 私钥（service https://sparkle-project.org，account ed25519）` + `generate_keys` 用法 |

> C 的存在性检查用 `security find-generic-password`（**不加 `-w`**），
> 所以不需要读出密文、**不会弹钥匙串授权框**。真正读私钥是 `generate_appcast` 自己干的，
> 那一步会弹一次框，需要用户点「允许」——这一点写在 README 与 RELEASE.md 里。

**成功路径也实跑了**（用一把**临时生成、只存在于 scratch 的**测试密钥，
生成脚本 `results/genkey.swift`，密钥本身运行时生成、不入库、跑完删除）：

- `generate_appcast` 产出 1 个 `<item>`、1 个 `sparkle:edSignature`，脚本的
  「item 数 == edSignature 数」自检通过；
- `enclosure url` = `https://github.com/AllenBall/brosis/releases/download/v0.2.0/brosis-0.2.0.dmg`；
- `sparkle:minimumSystemVersion` = `26.0`，`sparkle:hardwareRequirements` = `arm64`
  （Sparkle 从 bundle 自己推出来的）；
- **用 app 的 `Info.plist` 里那把 `SUPublicEDKey` 去验 DMG 的字节，签名通过**
  （`results/verify_sig.swift`，CryptoKit `Curve25519.Signing`）：
  `signature verifies against the app's SUPublicEDKey: true`；
  **反例**：把 DMG 中间一个字节 XOR 0xFF 之后 `tampered DMG verifies: false`。
- 顺带确认了一条重要行为：**公钥对不上时 `generate_appcast` 干脆不写签名**
  （只打一句 warning），于是 appcast 里 0 个 `edSignature`。脚本的自检当场抓到并
  `exit 1`——这正是不能只看 `generate_appcast` 退出码的原因。

### 3.6 自检

- 只有我的改动在树上时（T8 的适配器 / OCR 尚未落盘）：`brosis.app` 里跑
  **55 项 PASS / 0 FAIL / 0 SKIP，退出码 0**（`selfcheck.txt`）。
- 本文定稿时（T8 的新项已经进来并修完）：**74 项 PASS / 0 FAIL / 0 SKIP，退出码 0**
  （`final_selfcheck.log`），同一次构建 **warning 数 = 0**。
- 从 bundle 跑与从裸二进制跑的差别仍然只有「版本号单一来源」那一项（裸二进制 `[SKIP]`），
  Sparkle 没有引入任何新的 SKIP：裸二进制的 rpath `@loader_path` 指向 bin 目录，
  框架就在那儿，`--self-check` 照常跑得起来。
- **自检不联网**：`Updater.swift` 里没有任何东西在自检路径上被执行；
  Sparkle 只是被链接，不 `start()` 就不会发请求。

### 3.7 变异检验（都实跑过，原始输出在 `results/mutations.log` 与 `mutations.log.2`）

做法：**把 `app/` 复制到 scratch 再改**（`cp -R <项目目录>/app $M/app`，
`ln -s <项目目录>/core $M/core`），项目目录本身一个字节没动。

| # | 改什么 | 预期 | 实测 |
|---|---|---|---|
| M0 | 不改（基线） | 通过 | `exit=0`，`Sparkle 内嵌代码共签 5 件` |
| M1 | `Info.plist` 的 `SUEnableAutomaticChecks` 改成 `true` | 拒绝 | `exit=1`　`ERROR: Info.plist 的 SUEnableAutomaticChecks = true，必须为 false（默认不自动联网）` |
| M2 | `SUFeedURL` 改成 `http://` | 拒绝 | `exit=1`　`ERROR: SUFeedURL 必须是 https` |
| M3 | 注入一个 **31 字节**的假公钥 | 拒绝 | `exit=1`　`ERROR: Sparkle 公钥不是 32 字节（解出 31 字节，来源 环境变量 BROSIS_SPARKLE_PUBKEY）` |
| M4 | 删掉 `install_name_tool -add_rpath` 那一行 | 拒绝 | `exit=1`　`ERROR: rpath @executable_path/../Frameworks 没加上` |
| M5 | 删掉「裸 Mach-O 签名循环」（`Autoupdate` 漏签） | 拒绝 | `exit=1`　`ERROR: Sparkle 内嵌代码只签了 4 件（预期 ≥ 5…）` |
| M6 | M5 之上再把「≥ 5 件」放松到「≥ 1 件」 | 第二道网兜住 | `exit=1`　第 4 步 `--verify --deep --strict` **通过**了，第 4a 步 `ERROR: Autoupdate 的 Team ID 是 not set，应为 <TEAMID>（漏签或签错身份）` |
| M7 | 干净副本上删掉 rpath 那一行**和**它的 `otool` 核对 | 第二道网兜住 | `exit=134`　第 4b 步 `dyld[…]: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle` |

**M6 是这一节最有信息量的一条**：`codesign --verify --deep --strict` 对一个
**adhoc 签名**的内嵌 Mach-O 是**不报错**的（Sparkle 发布的框架本来就是 adhoc 签的）。
只靠 `--deep --strict` 会把"漏签 `Autoupdate`"放过去，到公证或运行时才炸。
所以「逐个 Mach-O 问 `TeamIdentifier`」不是重复劳动，是那一层真正的检查。

同理 M7 说明：光有「签名对不对」不够，还得证明**dyld 真的能加载**——
所以第 4b 步从 bundle 里跑一次 `--version`。

另外 3.5 里已经记过一条同类的：`generate_appcast` 在公钥对不上时
**只打 warning、退出码 0、但不写 `edSignature`**，靠 `make_appcast.sh` 的
「item 数 == edSignature 数」自检才抓得住。

---

---

## 4. 未做与原因

| 未做 | 原因 |
|---|---|
| **公证 DMG** | 本机屏幕锁定、用户不在场：notarytool 凭据在 data-protection 钥匙串里，锁屏时读不到。脚本已实现 `submit --wait` + `stapler staple` + `validate`，并在锁屏 / 缺凭据时明确报错。解锁后重跑一次即可（`RELEASE.md` 第 3 节有判据）。 |
| **生成真正的 Ed25519 密钥对** | `generate_keys` 会弹钥匙串授权框，只有用户本人能点。本轮用一把临时测试密钥把签名链路走通了（3.5），但**产品的公钥还是占位符**。 |
| **GitHub Release、两台机器安装验证、TCC 授权不丢的实测** | 都要真人操作 + 联网发布。清单在 `dist/RELEASE.md` 第 5–8 节，逐条有判据。 |
| **把「检查更新…」接进菜单** | 硬约束：本批 T8 与 T10 并行改 `app/`，两边都不改 `AppDelegate.swift`。入口函数已就位，主会话加**一行**即可（见第 5 节）。 |
| **DMG 背景图与窗口布局** | 任务里写的是"背景可略"。当前是纯功能性 DMG：一个 `.app` + `/Applications` 快捷方式 + 一行安装说明。要做的话得起 Finder 摆窗口，会触发 GUI，本轮明确不做。 |
| **delta 更新（BinaryDelta）** | `generate_appcast` 有能力做，但要至少两个版本的归档才有意义。等发第二个版本时自然会生成（`--maximum-deltas` 默认 5）。 |
| **对 DMG 里的 `.app` 再 staple 一次** | 公证的是 DMG，ticket 贴在 DMG 上。装到 `/Applications` 后那份 `.app` 自己没有 ticket，但 Gatekeeper 会走在线校验，够用。要让 `.app` 也带 ticket 就得公证后拆包再重打包，本轮不做（`README` 3.2 与 `RELEASE.md` 第 3 节都写明了）。 |
| **沙盒化所需的 XPC 权利** | brosis 不沙盒（辅助功能权限拿不到）。两个 `.xpc` 留在框架里并已签名，只是用不到；真要沙盒化时才需要给它们签 `app-sandbox` + `network.client` 权利。 |

---

## 5. 与 T8 并行的说明（验收者请注意）

本批 T8（适配器与视口 OCR）与 T10 同时改 `app/`。分工按任务书：
T8 动 `AXSupport/EventSkeleton/CaptureController/SelfCheck/Recorder.swift` 与新增
`Adapters/`、`OCR/`；T10 只动 `app/Package.swift` 的依赖块、新增
`app/Sources/brosis/Updater.swift`、`app/Support/Info.plist` 的 `SU*` 键、
`app/build_app.sh`、新增 `dist/`、`app/README.md` 的分发章节。**两边都没有改
`AppDelegate.swift`。**

因此：

1. **「检查更新…」菜单项由主会话接入。** 在 `AppDelegate.menuWillOpen` 里
   「导出存储统计…」之后、`.separator()` 之前加一行：

   ```swift
   menu.addItem(UpdaterController.shared.makeMenuItem())
   ```

   菜单项自带 target/action 与可用性判定；`UpdaterController.shared` 是 `@MainActor`
   单例，`menuWillOpen` 本身就在主线程。想再显示一行只读状态就用
   `UpdaterController.shared.statusLine()`（不联网）。

2. **`UpdaterConfig.issues(in:)` 可以直接进自检**，但 `SelfCheck.swift` 是 T8 的文件，
   本轮没有动它。要加的话，一项就够：
   `UpdaterConfig.issues(in: Bundle.main.infoDictionary)` 在**注了真公钥**的构建上应为空，
   在占位符构建上应恰好返回一条（提示公钥是占位符）。
   构建期的等价检查已经在 `build_app.sh` 里做了（十二个必备键 + 两个自动开关必须 false +
   源必须 https + 公钥必须解出 32 字节）。

3. **自检数字的口径**：只含 T10 改动的那次（T8 的新文件尚未落盘）是 **55 / 55 全过**；
   本文定稿时 T8 的新项已经进来并修完，是 **74 / 74 全过、零 warning**。
   中途我曾看到 2 项 FAIL（「气泡归属」与「视口 OCR 冒烟」），**都在 T8 的新项里**、
   与分发管线无关，T8 随后修掉了。T10 引入的代码在自检里没有任何项
   （`SelfCheck.swift` 是 T8 的文件，本轮没有动它），也没有让原有任何一项变红。
   验收时以最新一次为准。

---

## 6. 干净性检查

```
$ find . -name '.build' -o -name 'DerivedData' -o -name '__pycache__' -o -name '*.pyc' \
       -o -name '.swiftpm' -o -name '*.dmg' -o -name 'Sparkle.framework' -o -name 'artifacts' \
  | grep -v '^./.git/'
（无输出）
```

新增进仓库的文件：`app/Package.resolved`、`app/Sources/brosis/Updater.swift`、
`dist/{build_dmg.sh,make_appcast.sh,RELEASE.md}`；改动：`app/Package.swift`、
`app/Support/Info.plist`、`app/build_app.sh`、`app/README.md`。
逐个 `grep` 过：没有主机名、`/Users/<用户名>` 路径、iCloud 路径、代理端口、公司名、Apple Team ID；
测试用的密钥串全部运行时生成、只落在 scratch 里、跑完删除。

Sparkle 的远端 binaryTarget 解压在 `<scratch>/artifacts/sparkle/`（**不在项目目录**），
`generate_appcast` / `generate_keys` / `sign_update` 这三个工具也在那儿，仓库里不带二进制。

---

## 7. 对计划的影响

一句话：计划 4.2「打包与分发管线」的 **DMG + Sparkle 签名更新 + 发布流程**这三件已经可跑可复现
（DMG 端到端 56.4 s、appcast 签名经 CryptoKit 正反例验证），
**只剩三件必须由用户本人做的收尾**：生成 Ed25519 密钥对、解锁屏幕后公证一次 DMG、
发一次 GitHub Release 并在两台机器上验证 TCC 授权不丢——这三件都写进了 `dist/RELEASE.md`
的打钩清单，不需要再改计划。
