# 发布清单（brosis / 计划 4.2 打包与分发管线）

一次发版从头到尾要做的事。**打钩式**：每一步都有一条能复制粘贴的命令和一个"怎么算过"的判据。

> 三条底线，任何一步都不能破：
> 1. **签名身份跨版本不变**（D13）。TCC 授权（屏幕录制、辅助功能）绑的是
>    `bundle id + 签名的 Designated Requirement`。换证书、换 Team、换 bundle id
>    都会让用户已经给过的授权作废，重装后要重新点一遍系统设置。
>    证书到期换新证书时**必须**是同一个 Team 的 Developer ID，不能换 Team。
> 2. **Sparkle 私钥只在你自己的钥匙串里**。不进仓库、不进 CI、不发给任何人（包括我）。
>    丢了就没法给已经装了旧版的机器推更新，只能让用户手动下载新 DMG。
> 3. **构建产物不落项目目录**（项目目录在同步盘里）。一律
>    `~/Library/Caches/brosis-build/…`。

---

## 0. 一次性配置（只做一次，之后每次发版都跳过）

这三件事**只有你本人能做**，都会弹系统框，我做不了。

### 0.1 Developer ID 证书

钥匙串里要有 `Developer ID Application: <公司名> (<TEAMID>)` 且**带私钥**。
`app/build_app.sh` 自动探测，探不到会直接失败。

```bash
security find-identity -v -p codesigning     # 应该能看到 Developer ID Application 那一条
```

### 0.2 公证凭据（notarytool 的钥匙串配置）

二选一，配一次就行；`<TEAMID>` 用上面那条身份括号里的：

```bash
xcrun notarytool store-credentials brosis \
    --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>
# 或者用 App Store Connect API key
xcrun notarytool store-credentials brosis \
    --key <AuthKey_XXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
```

App 专用密码在 appleid.apple.com 生成。

> **屏幕锁定时这份凭据读不到**：它存在 data-protection 钥匙串里，`ioreg` 的
> `IOConsoleLocked = true` 时 `notarytool` 会报 "No Keychain password item found"。
> `dist/build_dmg.sh` 会先自己判一次并直接报错，不会白传一遍包。
> **公证、装新版、重启 app 都只能在屏幕解锁时做。**

### 0.3 Sparkle 的 Ed25519 密钥对

`generate_keys` 随 Sparkle 的 SwiftPM 依赖一起解压在构建 scratch 里（不在仓库里）：

```bash
KEYGEN=~/Library/Caches/brosis-build/dist-app/artifacts/sparkle/Sparkle/bin/generate_keys
"$KEYGEN"          # 会弹钥匙串授权框；私钥存进登录钥匙串，公钥打印在屏幕上
```

把它打印的那一串**公钥**（44 个字符的 base64）写进：

```bash
mkdir -p ~/Library/Application\ Support/brosis-dev
printf '%s' '<公钥>' > ~/Library/Application\ Support/brosis-dev/sparkle_public_ed_key.txt
```

`build_app.sh` 会把它写进 `Info.plist` 的 `SUPublicEDKey`，并核对它解出来正好 32 字节。

**没做这一步会怎样**：`SUPublicEDKey` 保持仓库里的占位符 `__SUPublicEDKey__`，
`build_app.sh` 打印一段告警，app 里的「检查更新…」会弹框说"这份构建没有更新公钥"，
**并且拒绝做任何更新**（fail-closed，不是"不验签就装"）。`dist/make_appcast.sh`
也会拒绝为这样的构建生成 appcast。

**备份 / 换机器**：`generate_keys -x <文件>` 导出私钥，`-f <文件>` 在另一台机器上导入。
导出的文件是明文，用完删掉。家里机也要有同一把私钥，否则两台机器发出来的更新
互相验不过。

---

## 1. 定版本号

**唯一来源**是 `app/Sources/brosis/BuildInfo.swift` 的 `static let version`。
`Info.plist` 里是 `__VERSION__` 占位符，`build_app.sh` 组装时替换；
`dist/build_dmg.sh` 与 `dist/make_appcast.sh` 读的也是同一处。

- Sparkle 比较的是 `CFBundleVersion`，本项目让它和 `CFBundleShortVersionString` 同串。
- **只能往上走**：Sparkle 用 `SUStandardVersionComparator` 比，`0.2.0 < 0.2.1 < 0.3.0`。
  发出去之后不要回退版本号，否则旧机器不会认为有更新。

改完提交，然后：

```bash
grep 'static let version' app/Sources/brosis/BuildInfo.swift
```

---

## 2. 构建并签名 .app

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/dist-app" \
  <项目目录>/app/build_app.sh
```

判据（脚本自己会 fail，这里是给你复核的）：

- [ ] 零 warning、零 error
- [ ] `Sparkle.framework <版本> 已放进 Contents/Frameworks/，rpath 已补`
- [ ] `Sparkle 更新公钥：已写入（来源 …）`——**不是**"保持占位符"
- [ ] `Info.plist 十二个必备键齐全（含四个 Sparkle 键；两个自动开关都是 false，源是 https）`
- [ ] `Sparkle 内嵌代码共签 5 件`（2 个 XPC + Updater.app + Autoupdate + 框架）
- [ ] `Sparkle 的 5 个 Mach-O 全部由同一个 Team ID 签名`
- [ ] `codesign --verify --deep --strict` 通过
- [ ] 第 5 步 `codesign -dv` 里有 `Timestamp=…`（没有时间戳就公证不了）

再跑一次自检（安全，不弹任何框、不联网）：

```bash
"$HOME/Library/Caches/brosis-build/dist-app/brosis.app/Contents/MacOS/brosis" --self-check
```

- [ ] 退出码 0，末行 `自检通过`

---

## 3. 打 DMG 并公证

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SCRATCH="$HOME/Library/Caches/brosis-build/dist-app" \
  <项目目录>/dist/build_dmg.sh
```

（屏幕锁定 / 还没配公证凭据时先用 `--skip-notarize` 出一个只能自己装的包。）

脚本做的事：`build_app.sh` → 组 staging（`brosis.app` + `/Applications` 快捷方式 +
一行安装说明）→ `hdiutil create -format UDZO -imagekey zlib-level=9 -fs HFS+` →
`codesign` 签 DMG → `notarytool submit --wait` → `stapler staple` + `validate` →
`spctl` 评估 DMG 与挂载后里面的 .app → 写 `manifest.json` 与 `SHA256SUMS.txt` →
把 DMG 硬链进 `dist/appcast/` 归档目录。

判据：

- [ ] 公证那一步 `status: Accepted`
- [ ] `stapler validate` 说 `The validate action worked!`
- [ ] `DMG：… accepted source=Notarized Developer ID`
- [ ] `里面的 .app：… accepted source=Notarized Developer ID`
- [ ] `DMG 里：brosis <版本>，Sparkle <版本>，更新源 https://…/appcast.xml，公钥 已配置（…）`
- [ ] `~/Library/Caches/brosis-build/dist/<版本>/` 下有 `.dmg`、`manifest.json`、`SHA256SUMS.txt`

> 公证的是 **DMG**，`stapler staple` 也贴在 DMG 上。装到 `/Applications` 之后
> 那份 .app 自己没有 ticket，但 Gatekeeper 会走在线校验；要让 .app 也带 ticket，
> 就在公证后对 DMG 里的 .app 再 staple 一次并重打包——本项目**不做**，
> 用户装完是联网的，够用。

---

## 4. 生成 appcast

```bash
<项目目录>/dist/make_appcast.sh
```

- 会弹**一次钥匙串授权框**（`generate_appcast` 读私钥），点「始终允许」。
- 换机器 / 用导出的私钥文件时加 `--ed-key-file <文件>`。

判据：

- [ ] `item 数 1，enclosure 数 1，edSignature 数 1`（三个数都必须是 1）。
      本项目**只发全量包，不发增量包（delta）**：`make_appcast.sh` 里 `MAX_DELTAS=0`。
      增量包省流量，但每个都是一条必须跟着一起上传的资产，漏传一个，停在那个版本的
      机器就去下一个 404；全量包是唯一一条"少传就当场看得见"的路。脚本会断言
      appcast 里一条 delta 都没有。
- [ ] 打印出来的每个 `url=` 都指向**它自己那个 tag**
      （`…/releases/download/v<该 item 的版本>/brosis-<该版本>.dmg`）。
      `generate_appcast` 只给**新**条目套 `--download-url-prefix`，老条目原样保留；
      万一被改了，手工改回去再重跑一次（脚本会重新签）。
- [ ] `sparkle:minimumSystemVersion` 是 `26.0`，`sparkle:hardwareRequirements` 是 `arm64`

---

## 5. 发 GitHub Release

tag 用 `v<版本>`（和第 4 步的 `--download-url-prefix` 一致）。
**两个资产都要传，一个都不能少**：

- [ ] `brosis-<版本>.dmg`
- [ ] `appcast.xml`

原因：app 里的 `SUFeedURL` 是
`https://github.com/AllenBall/brosis/releases/latest/download/appcast.xml`，
`latest/download/<资产名>` 指向**最新那个 release 的同名资产**。
新 release 里没带 `appcast.xml` 的话，更新源会一直停在上一版那份。

- [ ] Release 说明里贴 `SHA256SUMS.txt` 的那行 sha256
- [ ] 传完后原样验一次：
      `curl -sL https://github.com/AllenBall/brosis/releases/latest/download/appcast.xml | head`

---

## 6. 两台机器安装验证

公司机（M4 Air）与家里机（M4 Max）各做一遍：

- [ ] 从 Release 页面下载 DMG（**不要**用本地那份：要连 quarantine 属性一起验）
- [ ] 双击挂载 → 把 `brosis.app` 拖进 `Applications`
- [ ] **不用**右键「打开」，直接双击就能起来（公证过的包不该再问）
      - 起不来就 `spctl -a -vv -t exec /Applications/brosis.app` 看它说什么
- [ ] 菜单栏出现图标；「数据库：unlocked」（第一次会弹一次钥匙串授权，点「始终允许」）
- [ ] `/Applications/brosis.app/Contents/MacOS/brosis --self-check` 退出码 0
- [ ] 菜单「检查更新…」点一次：应当能拉到 appcast 并说"已是最新版本"
      （这是**唯一**一次联网；不点就一个字节都不发）

---

## 7. TCC 授权没丢（签名身份不变的验收）

这是 D13 那条约束的实测。**升级安装**（覆盖已有的 `/Applications/brosis.app`）之后：

- [ ] 系统设置 → 隐私与安全性 → 屏幕录制：brosis 还在列表里、还是开着的
- [ ] 系统设置 → 隐私与安全性 → 辅助功能：同上
- [ ] app 菜单里「屏幕录制：已授权 / 辅助功能：已授权」
- [ ] **没有**重新弹授权框

如果掉了，八成是这三件事之一变了，去查：

```bash
codesign -dv --verbose=4 /Applications/brosis.app 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
codesign -d --requirements - /Applications/brosis.app
```

- `Identifier` 必须一直是 `com.brosis.app`
- `TeamIdentifier` 必须和上一版一样
- `Authority=Developer ID Application: …` 必须是同一个主体

> 换证书（旧证书到期）时：只要还是**同一个 Team** 的 Developer ID，
> Designated Requirement 里的 `certificate leaf[subject.OU] = <TEAMID>` 不变，
> TCC 授权就还在。换 Team 一定丢。

---

## 8. 更新通道自身的验证（发第二个版本时才做得了）

第一次发版没得可验；等有了 `<版本 N>` 和 `<版本 N+1>` 之后做一次：

- [ ] 机器上装的是 N，Release 上最新是 N+1
- [ ] 菜单「检查更新…」→ 弹出 N+1 的更新说明 → 「安装更新」
- [ ] 装完自动重启，菜单里版本号变成 N+1
- [ ] **TCC 授权还在**（第 7 节那四条）
- [ ] 故意做一个反例：把 appcast 里某个 `sparkle:edSignature` 改一个字符再让 app 去拉，
      预期 Sparkle 拒绝安装并报签名错误——证明验签这一环是活的

---

## 附：产物与目录

| 路径 | 是什么 |
|---|---|
| `~/Library/Caches/brosis-build/dist-app/brosis.app` | 签名好的 .app（`build_app.sh` 的产物） |
| `~/Library/Caches/brosis-build/dist/<版本>/brosis-<版本>.dmg` | 要发的 DMG |
| `~/Library/Caches/brosis-build/dist/<版本>/manifest.json` | 版本、sha256、Team ID、公证状态、Gatekeeper 判定 |
| `~/Library/Caches/brosis-build/dist/<版本>/SHA256SUMS.txt` | 贴到 Release 说明里的那行 |
| `~/Library/Caches/brosis-build/dist/appcast/` | 历次 DMG 的归档 + `appcast.xml`（`generate_appcast` 的输入与输出） |
| `~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt` | Sparkle 公钥（**不进仓库**） |
| `~/Library/Application Support/brosis-dev/brosis.provisionprofile` | Developer ID 描述文件（**不进仓库**） |
| 登录钥匙串 `https://sparkle-project.org / ed25519` | Sparkle 私钥（**只在你这儿**） |
