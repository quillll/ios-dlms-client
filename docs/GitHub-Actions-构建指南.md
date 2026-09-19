# 无 Mac 开发 iOS App：GitHub Actions 出包 + Windows 装机

> 适用前提：**没有 Mac · 有 Windows · 只有免费 Apple ID（无 $99 付费开发者账号）**
> 本文只讲这条路径能跑通的做法，付费账号那套（签名证书 / TestFlight / App Store）另见 §8。

---

## 1. 先说结论：你的前提决定了唯一可行路径

| 你的前提 | 直接后果 |
|---|---|
| 没有 Mac | 本地无法编译 → **必须**用 GitHub Actions 的云端 macOS runner 编译，这是唯一路径 |
| 有 Windows | 签名与装机阶段在 Windows 上做（Sideloadly），不需要 Mac |
| 免费 Apple ID | 无法使用 TestFlight / App Store；只能**自签装机自用**，证书 **7 天**过期，且**同时最多 3 个**自签 App |

所以整条链路是这样分工的：

```
Windows 写代码
      │  git push
      ▼
GitHub Actions (云端 macOS)          ← CI 只负责"编译"，不碰任何签名材料
      │  1) 模拟器编译验证（每次 push 自动）
      │  2) 真机 Release 编译 → 打成"未签名 IPA"（手动触发）
      ▼
下载 .ipa 到 Windows
      │
      ▼
Sideloadly + 免费 Apple ID            ← 签名在这一步发生
      │
      ▼
iPhone 装上，7 天后重新签一次
```

**关键认知**：签名必须在 Windows 侧做，不能放在 CI 里。原因是免费 Apple ID 的证书必须绑定你**具体设备的 UDID**，而 GitHub 的临时 runner 上既没有你的设备，你也不应该把 Apple ID 凭据和私钥传到云端。

### 能做 / 不能做

| ✅ 能做 | ❌ 不能做 |
|---|---|
| 云端编译验证 | TestFlight 内测分发 |
| 产出装机包，装到**自己的** iPhone | 上架 App Store |
| 7 天有效期自签，到期重签 | 把包发给别人装（别人的设备不在你的证书里） |
| 调试、真机验证 | 推送通知、部分系统能力（需付费账号的 entitlement） |

---

## 2. 文件清单

| 文件 | 作用 |
|---|---|
| `.github/workflows/ci.yml` | **推送闸门**。每次 push 自动跑三道闸门，见下表 |
| `.github/workflows/build-ipa.yml` | **出包**。手动触发，编译真机 Release 版并打成未签名 IPA |
| `Tests/CTests/run.sh` | C 层单测脚本（跨平台，ubuntu 上跑，秒级） |
| `Tests/SwiftTests/` | Swift 托管单测（模拟器上跑） |
| `project.yml` | 工程定义（XcodeGen）。本轮补充了 C 编译选项，见 §7 |
| `.gitignore` | 排除 `*.xcodeproj`、构建产物、签名材料 |

`ci.yml` 里的三道闸门：

| 闸门 | 跑在哪 | 内容 |
|---|---|---|
| 闸门 2 | **ubuntu**（1x 计费，便宜） | C 桥接 + vendor 客户端子集纯单测 |
| 闸门 1 | macos-15（10x 计费） | 模拟器全量编译，验证"能编过" |
| 闸门 3 | macos-15 | Swift 托管单测 |

> 闸门 2 作为闸门 1/3 的 `needs` 前置 —— **C 层不过就直接不启动 macOS runner**，不浪费额度。
>
> `.xcodeproj` 被刻意排除在版本库外 —— 它由 `project.yml` 在 CI 里现场生成，这样避免二进制工程文件的合并冲突。

---

## 3. 首次接入 GitHub（三步）

项目当前**还不是 git 仓库**，所以要先初始化。

```bash
cd D:/project/personal/ios/dlms-client/dlms-ios-app

git init -b main
git add .
git commit -m "DLMS 抄表调试台：初始提交"

# 在 GitHub 网页上新建一个空仓库（不要勾选 README/.gitignore），然后：
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

推送成功后，去仓库的 **Actions** 标签页，应该能看到 `CI · 编译验证` 正在跑。

> **仓库设为 public 还是 private？** 这直接影响花不花钱，见 §6。

---

## 4. 日常工作流

### 4.1 平时改代码 → 自动过三道闸门

```bash
git add .
git commit -m "..."
git push
```

→ `ci.yml` 自动跑。预计 **C 单测 30 秒~1 分钟**，**iOS 编译+单测 4~8 分钟**。
若变红，**Job Summary 里会直接列出报错行**，一般不用下载日志。

### 4.2 要装机包时 → 手动出包

1. 仓库页 → **Actions** → 左侧选 **出包 · 未签名 IPA**
2. 右侧 **Run workflow** → 分支选 `main` → 点绿色按钮
3. 等约 5–10 分钟
4. 进这次运行的结果页，底部 **Artifacts** → 下载 `dlms-unsigned-ipa`
5. 解压得到 `DLMSApp-unsigned-<时间戳>-run<N>.ipa`（另附 `.sha256` 校验值）

### 4.3 装机（Windows 侧，见下节详细步骤）

用 Sideloadly 把 IPA 签进手机。

---

## 5. Windows 侧装机：Sideloadly + 免费 Apple ID

### 5.1 准备（第一次做，约 20 分钟）

| 项目 | 说明 |
|---|---|
| **Sideloadly** | 从官网 `sideloadly.io` 下载。**只从官网下**，第三方站点常有捆绑 |
| **iTunes** | ⚠️ **必须装 Apple 官网的"网页版"安装包**（`apple.com/itunes/download/win64`），**不能用 Microsoft Store 版本**。Store 版缺少需要驱动组件，Sideloadly 会认不到设备 |
| **iCloud** | 同样建议装官网版（部分场景需要） |
| **Apple ID** | 现有的免费账号即可，无需付费 |
| 数据线 | 原装或质量可靠的 Lightning/USB-C 线 |

> 如果你之前装过 Microsoft Store 版的 iTunes / iCloud，**先卸载干净**再装官网版，否则会冲突。

### 5.2 装机步骤

1. **右键以管理员身份运行** Sideloadly
2. 首次启动会提示下载 **Anisette** → 点 **Yes**（这是苹果认证服务所需的组件）
3. 数据线连上 iPhone，手机上弹「信任此电脑」→ 点**信任**，并输入手机密码
4. **iOS 16 及以上必须开开发者模式**（这一步最容易漏）：
   手机 → **设置 → 隐私与安全性 → 开发者模式** → 打开 → **重启手机** → 重启后再次确认打开
   > 如果找不到「开发者模式」这一项，先连一次 Sideloadly / 用 Xcode 类工具连接一次，该项才会出现。
5. 在 Sideloadly 里把下载好的 `.ipa` **拖进去**（或点 Browse 选）
6. **Apple ID** 填你的免费账号
7. 点 **Start**，等待签名+安装完成
8. 手机上如果提示「不受信任的开发者」：
   **设置 → 通用 → VPN与设备管理 → 开发者 App → 信任**
9. 回到桌面打开 App

### 5.3 免费账号的三个硬限制（务必知道）

| 限制 | 数值 |
|---|---|
| **App 有效期** | **7 天**，到期后 App 打不开 |
| **同时安装数量** | 最多 **3 个**自签 App（iOS 10+） |
| 每 7 天可注册的 App ID | 约 10 个（超了要等，或用 Sideloadly 的「导出签名后 IPA」模式复用） |

**到期了怎么办？** 不用重新编译、不用删 App —— 数据线和电脑连上，**再点一次 Sideloadly 的 Start** 即可续期 7 天，App 内的数据保留。

> Sideloadly 带一个「自动刷新」守护进程，能在到期前自动重签。但前提是你的电脑和手机在同一个 Wi-Fi 下（或插着线）并且那台电脑开着。

### 5.4 小技巧

- **Bundle ID 冲突**：Sideloadly 高级选项里可以改 Bundle ID，用来绕开"同一 Bundle ID 已存在"或让同一 App 装多份
- **2FA 问题**：Apple ID 开了双重认证时，Sideloadly 会弹窗要验证码，输入即可；若一直失败，去 `appleid.apple.com` 生成一个 **App 专用密码**再填
- **想固定 7 天不被踢**：保持电脑开着 + Sideloadly 后台运行，开启自动刷新

---

## 6. 成本：macOS runner 的额度怎么算

**这是无 Mac 方案里唯一可能花钱的地方，务必看清楚。**

| 仓库类型 | macOS runner 费用 |
|---|---|
| **Public（公开）** | **完全免费、不限时长**（所有计划都一样） |
| **Private（私有）** | 从月度额度里扣，且 **macOS 按 10 倍计算** |

私有仓库 Free 计划的额度换算：

```
Free 计划：2,000 分钟/月（Linux 等效分钟）
macOS 倍率：10×
→ 实际可用 macOS 时间 ≈ 2,000 ÷ 10 = 200 分钟/月
```

本项目的单次构建预估：

| 场景 | 耗时（估） | 消耗额度 |
|---|---|---|
| `ci.yml` 模拟器编译（含装 XcodeGen） | 4–8 min | 40–80 min |
| `build-ipa.yml` 真机 Release + 打包 | 5–10 min | 50–100 min |

→ 私有仓库大约 **每月 20–40 次构建**。日常够用，但如果你一天推十几次就很快见底（超出后 macOS 按 $0.08/分钟计费）。

### 已做的省额度设计

- `ci.yml` 里 `paths-ignore` 排除了 `**.md` / `docs/**`，纯文档改动不触发构建
- 只用**一个 job**（GitHub 对每个 job 的用量**向上取整到整分钟**，拆多 job 更贵）
- 给每个 job 设了 `timeout-minutes`，卡住不会一直烧
- 出包做成**手动触发**，不会被无意义的 push 带跑
- `concurrency` + `cancel-in-progress`：连续推送时自动取消上一次

### 建议

- 如果你不介意公开代码 → **设为 public，成本归零**（本项目 vendor 的是 GPLv2 的 Gurux.DLMS.c，公开源码本身就符合 GPL 的分发要求，没有额外许可风险）
- 如果想保持私有 → 按上面估算，控制推送频率即可

---

## 7. 本轮对 `project.yml` 的两处改动（重要）

这两处不修的话，云端构建**第一次就会失败**，而且你没有 Mac，排查会很痛苦。

### 7.1 显式声明 scheme（不修必挂）

**问题**：XcodeGen **默认不会自动生成 scheme**，只在 target 写了 `scheme:` 或工程里显式声明 `schemes:` 时才生成。
而两个工作流都用了 `xcodebuild -scheme DLMSApp` —— 没有 scheme 会直接报：

```
xcodebuild: error: The project 'DLMSApp' does not contain a scheme named 'DLMSApp'.
```

**修复**：`project.yml` 顶层已有 `schemes:` 段（声明了 `DLMSApp` 与 `DLMSAppTests`，`test` action 指向单测 target）。工作流里也保留了 `xcodebuild -list` 这一步，万一还有问题，日志里能直接看到实际生成了哪些 scheme。

### 7.2 降低新版 clang 的诊断级别

**问题**：Xcode 15/16 起搭载的 clang 15+/16+ 把若干旧式 C 写法从「警告」**升级成了默认错误**，例如隐式函数声明、隐式 int、指针类型不兼容。vendored 的 Gurux 源码代码风格较老，在云端较新的 Xcode 上有中断编译的风险。

**修复**：给 `DLMSCore` target 的 `OTHER_CFLAGS` 追加了：

```
-Wno-implicit-function-declaration
-Wno-implicit-int
-Wno-int-conversion
-Wno-incompatible-pointer-types
-Wno-incompatible-function-pointer-types
```

这些**只影响诊断级别，不改变任何代码行为**，可以放心长期保留。

### 7.3 另外两处顺手修的、会直接让 CI 挂掉的问题

**(a) C 单测链接缺 `-lm`**

`Sources/DLMSCore/C/src/helpers.c:891` 用了 `pow()`。glibc 下 `pow` 在独立的 libm 里，
而 `Tests/CTests/run.sh` 原来的链接命令是：

```bash
"$CC" "${OBJS[@]}" -o "$OUT/test_dlms"          # ← 缺 -lm
```

在 ubuntu 上会以 `undefined reference to 'pow'` 失败。已改为：

```bash
"$CC" "${OBJS[@]}" -o "$OUT/test_dlms" -lm
```

（`-lm` 在 macOS / MinGW 上同样无害，可以一直留着。）

**(b) 别硬编码模拟器机型名**

第二个工作流原来写的是：

```yaml
-destination 'platform=iOS Simulator,name=iPhone 14'
```

**机型名在不同 runner 镜像上会变**（macos-15 上是 iPhone 16 系列，找不到 iPhone 14 就直接报
`Unable to find a device matching the provided destination specifier`）。已改为从
`xcrun simctl list devices available` 里动态挑第一个可用 iPhone 的 UDID：

```bash
UDID="$(xcrun simctl list devices available | grep -E "iPhone" | head -1 | grep -oE "[0-9A-Fa-f-]{36}")"
xcodebuild ... -destination "id=$UDID" test
```

---

## 8. 常见报错排查

| 报错 | 原因 | 处理 |
|---|---|---|
| `does not contain a scheme named 'DLMSApp'` | project.yml 没声明 scheme | 已修（§7.1）；若仍报，看日志里 `xcodebuild -list` 的输出 |
| `undefined reference to 'pow'` | C 单测链接缺 `-lm` | 已修（§7.3a） |
| `Unable to find a device matching the provided destination specifier` | 硬编码了模拟器机型名 | 已修（§7.3b） |
| `No signing certificate "iOS Development" found` | 忘了关签名 | 工作流已加 `CODE_SIGNING_ALLOWED=NO` 等一组参数 |
| `implicit declaration of function 'xxx'` 变成 error | 新 clang 收紧诊断 | 已修（§7.2）；若还有别的诊断项，把报错发我，加一行 `-Wno-...` 即可 |
| `error: unable to find utility "xcodegen"` | brew 安装失败 | 重跑一次；日志里搜 `brew` |
| 构建超时 | 网络/brew 慢 | 手动重跑；已设 `timeout-minutes` |
| **Sideloadly 认不到 iPhone** | 装的是 Microsoft Store 版 iTunes | 卸载 Store 版，装 Apple 官网版 iTunes（§5.1） |
| `Untrusted Developer` / App 打不开 | 忘了信任证书 | 设置 → 通用 → VPN与设备管理 → 信任 |
| Sideloadly 报 signing 失败 | Apple ID 凭据 / 2FA | 用 App 专用密码；确认账号能正常登录 iCloud |
| App 装上了但一开就闪退 | 常见于内嵌 framework 未正确重签 | 先用 Sideloadly 的「导出签名后 IPA」再装一次；若持续，考虑把 `DLMSCore` 改为静态 framework（联系我） |
| 7 天后 App 打不开 | 免费证书到期 | 正常现象，重新 Sideloadly 签一次（§5.3） |

---

## 9. 将来如果买了付费账号（$99/年）

**到那一步之前，上面这些都不用改。** 只有当你确实需要 TestFlight 或上架时，才需要在现有基础上补：

1. 导出 iOS Distribution 证书（`.p12`）+ Provisioning Profile（`.mobileprovision`）
2. 创建 App Store Connect API Key（`.p8` + Key ID + Issuer ID）
3. 把这些存进仓库 Secrets（`IOS_CERTIFICATE_BASE64` 等）
4. 在 `build-ipa.yml` 里加一段「导入证书到临时 keychain」的步骤，并把 `build` 换成 `archive` + `-exportArchive`
5. 加一个上传步骤（`xcrun altool` 或 `xcrun notarytool`/`xcrun iTMSTransporter`）推 TestFlight

⚠️ 注意：付费账号下，签名私钥要作为 Secret 传到 GitHub。这是可接受的（GitHub Secrets 是加密的），但**免费账号完全不需要这么做**，也是我们把它排除在 CI 之外的原因。

---

## 10. 参考

| 资源 | 位置 |
|---|---|
| 官方参考实现（协议链路以它为准） | `D:\project\personal\dlms\GuruxDLMS.c\GuruxDLMSClientExample\src\communication.c` |
| 方案审查与改进 | `docs/DLMS调试台-方案-审查与改进.md` |
| DLMS 知识库 | `docs/DLMS知识库.md` |
| Sideloadly 官网 | https://sideloadly.io/ |
| Apple 官网版 iTunes（Windows） | https://www.apple.com/itunes/download/win64 |
