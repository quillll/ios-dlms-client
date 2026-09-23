# DLMS 抄表调试台 iOS —— 详细方案（v1.7）

> 状态：**App 已在真机侧载运行，并与真表完成 HLS-GMAC 关联 + 抄表**（CI 三道闸门全绿 → 出未签名 IPA → Windows 用 Sideloadly 侧载）。
> 最新版本号 **1.2 (build 3)**（真源 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，主界面右上角常显）。
>
> **v1.7 变更**（本地拟真台 + 长帧/分片根治 + 解析面板 + 地址定宽 + OBIS 数据）：
> ㉕ **修掉「数据过长无法交互」的根因**：`bufAppend` 误用 `bb_insert` 做追加 → 分片到达时 `rx.size` 永不增长。详见 **R26**；现场四档分片矩阵复现并根治（`c6d1ff8`）；
> ㉖ 新增**本地拟真台**：`tools/mock_meter.c`（可控分片/延迟/静默的模拟表）+ `Tests/CTests/local_e2e.c`（真 socket 端到端），`run.sh` 一条命令跑四步 → **§17**；
> ㉗ 桥接层覆盖率 **34.83% → 70.87%**（项目总覆盖率 2.58% → 9.98%），`dlms_read/write/method/disconnect` 从 0% 全部拉起 → **§17.3**；
> ㉘ **解析面板重做**：改**两行格式**（行 1 = 带类型的原始 HEX、行 2 = `-> Type/Value` 人类可读）、**累积 + 独立滚动 + 自动跟随**、「解析使能」**真正生效**（此前拨了没反应）、两个面板都能**满屏** → **§8**；
> ㉙ **HDLC 通信地址宽度改为「输入字节数」决定**（1 字节=仅逻辑 / 2 字节=各 1 / 4 字节=各 2；3 字节标红），取代原「手动宽度选择器」→ **R25**、**§3.2**；
> ㉚ **OBIS 清单新增「请求数据」字段**：Set/Action 的固定参数随条目保存，选中 OBIS 时自动填入 → **§3.3**；
> ㉛ 修六个已核实的坑：`bufAppend` 误用 `bb_insert`（**R26**）· 写/action 崩溃（**R27**）·
> `ObisItem` 缺容错解码（**R28**）· 预读缓冲栈溢出（**R29**）· OBIS 写法差异匹配失败（**R30**）·
> 测试脚手架 HCS 算错导致的假死循环（**R31**）；
> ㉜ 对《代码审核报告 v2》逐条核对 → **§18**（其中 S2 报告判错：其实早已修）。
>
> **v1.6 变更**（安全时序 + 可观测性）：
> ㉒ **真表抄表失败根因定位并修复**：HLS-GMAC + `信息加密 = NONE` 时库拒绝算 GMAC → 桥接层照**官方示例手法**（临时改 `settings`、**打包前**立刻还原）切开「算 GMAC」与「打包 APDU」→ **现场真表 NONE 关联成功并抄表** → **§16**、**§5.2**、**§7.1**；
> ㉓ 建链失败可定位到**步骤号** + 区分「发送失败」：新增 `dlms_lastStep` / `dlms_sendFailed` / `dlms_step_name`；
> ㉔ 传输层加**预读缓冲**，止血「超时后晚到的字节永久丢失」（原 D5）。
>
> **v1.5 变更**：报文日志独立滚动 + 自动跟随（U1）· 结果与状态解耦（U3）· 导入补 `scaling`（U4）· 输入合法性实时提示（U5）· 修报文类型列空白（U6）→ §14。
>
> **v1.4 及更早**：类改输入框（10/16 进制）· 地址输入规则 · 报文 4 列固定宽度 · 修 `SNRM/DISC` tag 值 · 整数夹取 · 密钥 GUAK/GUEK 独立 · 桥接 P0 修正 → §12 风险登记 R1–R24。
>
> 性质：自用现场抄表 · 单表快速抄 · 近 GXDLMSDirector / 桌面 Test-Client 形态 · 仅 TCP
> 协议层：vendor 本地 `D:\project\personal\dlms\GuruxDLMS.c`（Gurux.DLMS.c，GPLv2，自用无分发风险）

---

## 0. 本轮先读这个（易踩的坑，都是花过代价的）

| # | 坑 | 正确做法 | 代价 |
|---|---|---|---|
| 1 | 拿 `bb_insert` 当「追加」用 | **不能** ✗。它的 `index` 同时是「目标插入点」和「源数据偏移」，且**从不更新 `target->size`**。追加请手工做：`bb_capacity` → `memcpy(rx->data + rx->size, …)` → `rx->size += len`。库里所有调用都传 `index=0` 才碰巧正确 | 现场「数据过长无法交互」（R26） |
| 2 | 用 `bb_set` 覆盖接收缓冲 | `bb_set` 本身就是**追加**（`memcpy(arr->data + arr->size, …); arr->size += count`）—— 这条曾被写反，导致改错方向 | 排查绕远 |
| 3 | 直接对 `NULL` 调 `bb_clear` | 它只检查 `arr->data`、**不检查 `arr` 本身** ✗。OCTET_STRING variant 的 `byteArr` 必须**堆分配**（`gxmalloc` + `bb_init`） | 写/action 一点就崩（R27） |
| 4 | 手抄截图里的报文做回放 | **别抄** ✗ —— 我在这上面抄错两次（FCS 对不上）。要测就**自己构造合法帧 + 自算 HCS/FCS**；HDLC 的 **HCS 必须覆盖真实长度字节**（先定长再算） | 回放死循环（R31） |
| 5 | 二进制报文用肉眼核对 | 用**长度域自校验**（`60 4A`=74、`61 56`=86 都能逐级相加验算），或**把本地代码实际发出的字节打出来** | 连续误判三次 |
| 6 | 改模型默认值 | 必须 grep 出**所有依赖默认值的构造点** —— 预置清单里「本该显式写 IC 却偷懒用默认值」的条目会被带偏 | 电量/功率被标成 Data(1) |
| 7 | 改 `Codable` 结构体字段 | 必须同步手写 `init(from:)`，**合成解码对「缺键 + 非 Optional」照样抛错** → 旧 JSON 整份失效、用户数据被静默重置 | R19 / R28 同源 |
| 8 | 把"只读不写"的旧键放进 `CodingKeys` | **不能** ✗ —— 合成 `encode(to:)` 会为**每一个 case** 去找同名存储属性，找不到就整份不满足 `Encodable`，而报错只落在 struct 声明行（**完全指不到那个 case**）。旧键要另开一个 enum（如 `LegacyKeys`）**只用于解码** | CI 红两次（R32） |

---

## 1. 交付节奏：三阶段（控险、先跑通）

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **P0 修桥** | 修现有桥接 bug：接收缓冲改为**ctx 上跨 recv 持久化的累积缓冲**（**手工追加**，不是 `bb_insert` ✗ —— 见 R26）并按 `maxPduSize+50` 动态分配 · Wrapper 不发 SNRM · 断链先 RLRQ(`releaseRequest2(sec!=NONE)`)再 DISC · 超时参数化(连接5s/recv取配置) | 现有 App 在 HDLC/NONE 下稳定读通大 PDU 不丢帧 |
| **P1 核心调试器** | 读/写(按 E1 修正)/执行(hex→variant 整型) · 认证三档(按 E2/E3/E4) · HDLC/Wrapper · 双窗口 · 全局OBIS库 · 超时 | 真表或 Gurux 模拟表读通 `1.0.1.8.0.255` + 报文日志见原始帧；CI 编译过 + 解析器单测过 |
| **P2 安全** | 信息加密四档(按 §7 修正映射) · IC 同步(M5) · Association View 列表(M10) · 明文 PDU trace(M9) | 对真表专项验证密钥映射 |
| **P3 增强** | 完整 ASN.1/全类型 hex→variant · 地址合成/解释器 · E-mode | 打磨 |

---

## 2. 默认值

| 项 | 默认 |
|---|---|
| IP | `10.10.10.1` |
| 端口 | `4059` |
| 接收超时 | `3000` ms |
| 封装 | HDLC |
| 客户端地址(HDLC) | `管理 0x01`（预设：管理1/公共0x10/只读2/预链接0x66/自定义，公共置于显眼位） |
| 通信地址(服务器)/HDLC | `00013FFF`（Wrapper 用 源/目标 = `0001/0001`） |
| 认证方式 | **`HLS-GMAC`**（独立下拉） |
| 信息加密 | **`NONE`**（独立下拉） |
| 密钥 · GUAK | **16 字节全 0**（32 位 hex），可改；留空按全 0 → `cipher.authenticationKey` |
| 密钥 · GUEK | **16 字节全 0**（32 位 hex），可改；留空按全 0 → `cipher.blockCipherKey` |
| 客户端SystemTitle | **`4142433031323334`**（ASCII "ABC01234"），可改；留空即用该默认（R13） |
| 密钥 · MK / GBEK | **暂不提供**（`dedicatedKey` 槽位预留；服务器 SystemTitle 自动捕获，不作输入） |
| 解析使能 | 开（**真正生效**：关闭时解析面板只留行 1 的原始 HEX，不做类型/值解析） |
| 接口类兜底 | **`1`（Data）** —— 解析失败 / 清单缺键时的回退值（模型默认值、导入缺省、编辑器初值、主界面回退四处一致） |
| 建链/断链 | 一键操作 → 一律自动建链→执行→自动断链（无自动会话开关） |
| 重复点按钮 | 串行队列 + busy 禁用按钮，不做硬中断（R8） |
| 版本号 | 从 `Info.plist` 读（真源 `project.yml`），主界面连接摘要右侧常显 `vX.Y (build)` |

> **认证方式 与 信息加密 是两个独立的、互不影响的下拉**：
> 认证方式默认 **HLS-GMAC**，信息加密默认 **NONE**。审计建议"认证默认 NONE"**未采纳**，按用户要求保留认证默认 HLS-GMAC（E4 决议 ⑦）。
> 依赖约束：认证=HLS-GMAC 时，客户端 SystemTitle 必须在 AARQ 前设置 → 该字段常显、选 HLS 时必填（R13）。
>
> ⚠️ **`信息加密 = NONE` + 认证 HLS-GMAC 的组合曾在真表上失败**，2026-09-21 定位并修复
> （**§16**）：库的 `cip_encrypt` 要求 `cipher.security != NONE` 才肯算 GMAC，
> 而桥接层把界面上的 `NONE` 原样传了进去 → 步骤 5「HLS 应答生成」直接返回 `INVALID_PARAMETER`。
> **修法**：照官方示例手法（`communication.c` 的 `com_updateInvocationCounter`）**临时**把
> `cipher.security` 置成 `AUTHENTICATION` 只覆盖「算 GMAC」那一步，**打包前立刻还原** ——
> 这样 GMAC 算得出来 ✓、APDU 仍是明文 `C3` ✓、应用上下文仍是 `…08 01 01` ✓，
> 与 .NET(GXDLMSDirector) 的成功报文逐字段一致。**现场真表已用 NONE 关联成功并抄表** ✓

---

## 3. UI（单屏纵向，顺序＝配→选→抄→看）

```
┌ 连接摘要（常驻）──────────────────────┐
│ 10.10.10.1 : 4059          [连接测试]   │
│ HDLC 客户端01 通信00013FFF       v1.2 (3) │ ← 版本号常显（排查时一眼知道打的哪版）
├ 操作对象 ───────────────────────────┤
│ 类[输入框 10/16 进制] · 属性[输入框]      │
│ OBIS[输入框 + 下拉：最近 OBIS ／ 全局清单] │
│   ↳ 选中时**同时**带入 接口类 · 属性 · 请求数据 │
│ 请求数据(HEX，写/执行用；清单里配了会自动填入)│
│   ↳ 两处实时合法性提示（图标 + 字节数 / 段数）│
├ 操作： [读] [写] [执行] ──────────────┤
├ 解析 / 报文（分段切换；各自带「满屏」+「清空」）│
│ 解析面板（**累积** + 独立滚动 + 自动跟随到底）│
│   09 03 31 32 33                     │ ← 行1：带类型的原始 HEX
│   -> Type: octet-string, Length: 3, Value: 123 │ ← 行2：人类可读
│   （「解析使能」关闭时只留行1）           │
│ 报文面板（时间│TX·RX│类型│HEX 四列 + 独立滚动 + 满屏）│
└──────────────────────────────────────┘
```

> 两个面板顶部共用同一套 `panelHeader`：**左＝本面板的开关/状态，右＝固定「清空」**。
> 「满屏」用 `fullScreenCover` —— 面板嵌在页面级 `ScrollView` 里高度会被压住，满屏才能看全。

### 3.1 操作对象输入规则
- **类：只提供输入框，不做下拉**。COSEM 类实际可能非常多（不止 Data/Register/Extended/ProfileGeneric 这几个），下拉既穷举不了也不可维护。支持 **10/16 进制自动识别**（`3` / `0x1F` / 含 `a-f` 视为 16 进制）。
  - 模型层 `ObisItem.objectClass` 为**任意 `Int`**（原来是从 4 个值的枚举），解析失败时保留原值而不是清零。
- OBIS：分隔符兼容 `, . - :` `*` 与空白；可下拉全局清单或手输。
- 属性/方法：与「类」一样支持 **10/16 进制自动识别**（`2` / `0x03`）。
- **选中一条 OBIS 时，「接口类」与「属性」必须一起更新** —— 类 / 逻辑名 / 属性是**一组**，只换逻辑名会拿错类去读，读出来就是别的对象。
  - `recentObis` 只存 code 字符串 → 按 code 回 OBIS 清单反查元数据；清单里**查不到**（手输未入库）时只更新逻辑名，不动类/属性，免得抹掉用户刚手填的值。
  - 首次进入主屏时按同一规则恢复「最近一条」，且**只做一次**（标志位），避免每次回到本页把手改的值覆盖掉。
- **键盘统一用系统默认键盘**：类 / 属性 / 逻辑名都**不再**限定 `numberPad` / `numbersAndPunctuation`（类与属性都可能填 16 进制，纯数字键盘反而是限制）。
  - 保留数值键盘的只有 ParamsView 里天然数值的字段：IP、端口、接收超时；地址类字段用 `asciiCapable`（要打 hex 字母）。
- 请求数据 = **ASN.1/BER 编码**的 HEX 字节（空格可有可无）。例：`11 01`=unsigned 数据 1；`12 01 00`=long unsigned 数据 256。

### 3.2 地址输入规则（HDLC）

| 字段 | 规则 |
|---|---|
| **客户端地址** | 预设下拉（管理 `0x01` / 公共 `0x10` / 只读 `0x02` / 预链接 `0x66` / 自定义）。**选中预设时该值只读显示、不可输入**；只有选「自定义」才出现可编辑输入框。客户端地址是 **1 字节** → **2 位 hex**，**可省略前导 0**（填 `1` → `01`）。 |
| **通信地址(服务器)** | **保留原始输入串**（不再固定 `%08X`）。**宽度 = 输入字节数**，由它自动决定：<br>• **1 字节** → 整串是**逻辑地址**（无物理地址）：`10` → 逻辑 `0x10`<br>• **2 字节** → 逻辑 1 + 物理 1：`0105` → 逻辑 `0x01` + 物理 `0x05`<br>• **4 字节** → 逻辑 2 + 物理 2：`00013FFF` → 逻辑 `0x0001` + 物理 `0x3FFF`<br>• **3 字节（及其它）** → **非法，标红**"地址只能 1 / 2 / 4 字节" |
| Wrapper 源 / 目标 | 各 4 位 hex，默认 `0001` / `0001`。 |

**参数页实时显示**（不用再去猜）：

```
通信地址(服务器)                        00013FFF
ⓘ 编码后 0002FEFF（4 字节）· 逻辑 0001 + 物理 3FFF · 末字节 bit0=1 表示地址域结束
```

- 输入不合法 → **红色**（"HEX 需偶数位且仅含 0-9 A-F" / "地址只能 1 / 2 / 4 字节，当前 N 字节"）。
- 输入的宽度 ≠ Gurux 实际发出的宽度时 → **黄**色提示
  （例：`0010` 是 2 字节输入，但逻辑为 0 → 编码值 `0x10 < 0x80` → Gurux 只发 **1 字节**）。

> ⚠️ **Gurux 按数值量级自动定宽**（`dlmssettings.h` 里**没有** `addressSize` 字段，已核实），
> 所以「输入宽度 ≠ 实际宽度」是**可能出现**的，UI 用 `serverAddressWidthMatched` 标出来 —— 见 R16 / R25。
> ⚠️ **别把输入的 `00013FFF` 直接喂给 `cl_init`** ✗：Gurux 会按 `v>>14` 解出逻辑 = `0x4F`，编码出完全错误的地址域。
> 桥接前的换算（模型层 `serverAddressEncoded`）：
> `1 字节 → logical & 0x7F`；`2 字节 → (logical&0x7F)<<7 | physical&0x7F`；
> `4 字节 → (logical&0x3FFF)<<14 | physical&0x3FFF`。
> 默认 `00013FFF` → `0x7FFF` → 线上 **`00 02 FE FF`**（**现场真表抓包验证过** ✓）。

### 3.3 添加 / 编辑 OBIS 的字段顺序

表单自上而下**固定**为：

1. **名称**
2. **接口类**（IC，输入框，10/16 进制自动识别；初值 `1`）
3. **逻辑名 OBIS**
4. **属性 / 方法**
5. 单位（可选）
6. 量纲 / 倍率（可选）
7. **请求数据**（可选，HEX，如 `11 01`）—— 单独成 Section

> 顺序即录入习惯：先认"这是什么" → 再定位"到哪里取" → 最后补"怎么换算 / 怎么下发"。
> 量纲单独成字段（`ObisItem.scaling`），便于后续把 `value × 10^scaler` 的换算做进展示层。
> ⚠️ 接口类输入框的占位文字写的是 `Data=1`，但该串含 `=` **无法被解析**（保存时会静默保留原值）—— 见 R24。

**「请求数据」字段（v1.7）**：

- 用途：**Set / Action 的固定参数**随 OBIS 一起存下来，免去每次手输。
- 落点：`ObisItem.data`（HEX 字符串，保留用户写的分隔空格，只做首尾去空白 + 大写）。
- 行为：主界面**从下拉选中该 OBIS 时自动填入**「请求数据」输入框。
  - 清单里**没配** ↔ **清空**输入框 —— 这是刻意的：切到另一条 OBIS 后若残留上一条的数据，
    很容易把值写到错的对象上。
  - 清单里**查不到**该 code（手输未入库）→ 只更新逻辑名，不动类/属性/数据，
    免得抹掉用户刚手填的值。
- 配套：JSON 导入支持 `data` 键；CSV 支持**第 6 列**（`code,name,unit,接口类,属性,请求数据`）。
- ⚠️ **`ObisItem` 必须手写 `init(from:)` 容错解码** —— 合成解码对「缺键 + 非 Optional」照样抛错，
  旧 `obis.json`（没有 `data` 键）会**整份解码失败** → `Store.load` 返回 nil →
  用户清单被静默重置成预置列表。**改字段必须同步该 init**（R28）。

---

## 4. 数据模型（JSON 文件存储）

三个文件都在 `Documents/`：`config.json` / `obis.json` / `recent.json`。

- **`ConnectionConfig`**：IP、端口、超时、封装(HDLC/Wrapper)、客户端地址(预设+自定义)、
  **通信地址(原始输入串 `serverAddressHex`)**、Wrapper 源/目标、认证、信息加密、
  三密钥(LLS密码/GUAK/GUEK)、客户端 SystemTitle、解析使能、**最近连接 `recentEndpoints`** —— **记住上次**。
  - 解码为**容错式**：`init(from:)` 逐项「缺键/类型不符 → 回退默认值」，字段增删不会让旧 `config.json` 整体失效。**改字段必须同步该 init**。
  - `CodingKeys` **只列与存储属性一一对应的键**（本项目**风格规定**）。
    ⚠️ **已淘汰的旧键不要放进去** —— **靠合成 `encode(to:)` 时**，编译器会为**每个 case**
    找同名存储属性，找不到就整份不满足 `Encodable`，而报错只落在 **struct 声明行**
    （`type 'ConnectionConfig' does not conform to protocol 'Encodable'`）、**指不到出问题的 case**。
    本项目 CI 已因此红过两次（先 `serverAddressWidth`，半修后又栽在 `serverAddress`）→ **R32**。
    严格说：**显式实现了 `encode(to:)`** 时多留一个 case 并不报错（本项目历史上就是这么绕过去的），
    但那把正确性挂在"必须记得别删掉显式 encode"上 —— 删了就立刻炸，
    所以风格统一走下面这种更稳的做法。
  - 旧键改走**单独的 `LegacyKeys`**（**只用于解码、不参与编码**）：
    `serverAddress`(UInt32) → 迁移成 8 位 hex；`serverAddressWidth` 读入后**直接忽略**
    （已由 `serverAddressHex` 的字节数取代）；`akekHex` 两个 enum 里都没有 —— 未知键本来就会被忽略。
  - `encode(to:)` 仍是**显式实现**的（只写真实字段）—— 它的本职是"声明会写出哪些键"，
    与上面那条风格规定互补：即使将来有人往 `CodingKeys` 里加回旧 case，也不会被写进 `config.json`。
  - ⚠️ 要区分「**键不存在**」与「**键存在但为空串**」：后者是用户清空了输入框，
    **不能**再当旧存档迁移回来（`serverAddressHex` 走 `decodeIfPresent` 判断键是否存在）。
  - 通信地址的计算属性：`serverAddressNormalized` / `serverAddressBytes` / `serverAddressIsValid` /
    `serverLogical` / `serverPhysical` / `serverAddressEncoded` / `serverAddressEffectiveWidth` /
    `serverAddressWidthMatched` / `serverAddressWireHex`（详见 §3.2）。
- **`ClientPreset`**：`管理=1 / 公共=0x10 / 只读=2 / 预链接=0x66 / 自定义`（HDLC 客户端下拉）。
- **`ObisItem`**（`obis.json`）：`code` / `name` / `unit` / **`objectClass`（兜底 `1`）** / `attribute` /
  `scaling` / **`data`（Set/Action 固定请求数据）** / `enabled`。手写 `init(from:)` 容错解码（R28）。
- **`recentObis`**（`recent.json`）：最近用过的 OBIS，填充下拉；**存归一形态**（见下）、不存数据值。
- **`parseEntries`**：解析面板的**累积**历史（**上限 200 条 / 高水位 250**，与 `logs` 同一套裁剪口径）。
  之所以是数组而不是一整串：面板要能滚动回看，且「解析使能」关闭时需**逐段**只取行 1，
  拼成一整串就分不清段落边界了。
- **`logs`**：报文日志（上限 **2000** / 高水位 2500，UI 只渲染最近 200 条）。

**OBIS 写法归一（`ObisUtil.comparisonKey`）**：
去空白 + 转大写 + 把 `- : * ,` 统一成 `.`。
「最近 OBIS」与清单条目的**匹配和去重都必须走它** —— 两边写法可能不同
（`1-0:1.8.0*255` vs `1.0.1.8.0.255`），直接用原文比较会**静默匹配失败**：
选中后类/属性/请求数据全带不过来，下拉里还会出现同一对象的两个变体（R30）。

枚举映射（已锁定）：
- 封装：`HDLC=0` / `Wrapper=1`
- 认证：`NONE=0` / `LLS(LOW)=1` / `HLS-GMAC(HIGH_GMAC)=5`
- 信息加密：`NONE=0` / `仅认证=0x10` / `仅加密=0x20` / `认证加密=0x30`
- 对象类（仅下拉预设用，实际可填任意 Int）：`Data=1` / `Register=3` / `ExtendedRegister=4` / `ProfileGeneric=7`

---

## 5. 操作与协议映射

| 按钮 | COSEM | Gurux C | 数据 |
|---|---|---|---|
| 读 | GET | `cl_readLN(settings, obis, class, attr, NULL, &msg)` | `GET_RESPONSE` → `var_toString` |
| 写 | SET | `cl_writeLN(settings, obis, class, attr, dlmsVARIANT* v, byteArray=1, &msg)` | hex 经 `bb_addHexString` 转字节，`byteArray=1` 原样透传（零解析器） |
| 执行 | ACTION | `cl_methodLN(settings, obis, class, index, dlmsVARIANT* v, &msg)` | 请求数据 **hex→variant 解析后** 传入；空→`NULL` |

点按钮 → **一律自动建链 → 执行 → 自动断链**（无"自动会话"开关）。超时用 `ConnectionConfig`。

### 5.1 写/执行差异（修正）
- **写**：`cl_writeLN` 第 5 参是 `dlmsVARIANT*`（**不是** `gxByteBuffer*`）、第 6 参 `byteArray` 决定语义（`client.h:225-232`）。
  - `byteArray=1`：把 `value->byteArr` 原样塞入（用户输入即透传）；`byteArray=0`：按 `vt` 现编 tag+值。
  - **P1 走 `byteArray=1`**，hex→bytes 用官方 `bb_addHexString`（用户无需写解析器）。
- **执行**：`cl_methodLN` 参数是 `dlmsVARIANT`，写一个 **hex→variant 解析器**；P1 仅整型+无参。
  - **P1 修正支持集（tag ↔ 类型，`enums.h:532-541`）**：`0x0F=INT8/0x10=INT16/0x11=UINT8/0x12=UINT16/0x05=INT32/0x06=UINT32` + `0x03=BOOL` + `0x09=OCTET_STRING` + `0x16=ENUM` + 无参(`NULL`)。
  - tag `7/8/11/14` 未使用 → 报"未知类型"；`0x80` 为 `DLMS_DATA_TYPE_BYREF` 掩码，判型前 `vt & ~0x80`。
  - 结构/数组/浮点/日期留 **P3**（注意 `cl_methodLN` vendor bug：ARRAY/STRUCTURE 分支恒假，见 R17）。

### 5.2 建链/断链状态机（P1 必做）
| 封装 | 建链 | 断链 |
|---|---|---|
| HDLC | `cl_init` → SNRM → UA → AARQ → AARE →（若 `isAuthenticationRequired`）`cl_getApplicationAssociationRequest` → 收 → `cl_parseApplicationAssociationResponse`（HLS challenge 由库封装，**非手读 0.0.40**） | `cl_releaseRequest2(sec!=NONE)`(RLRQ) → `cl_disconnectRequest`(DISC) → TCP close |
| Wrapper | 跳过 SNRM/UA，直接 AARQ → AARE →（HLS 同上） | 同上但无 DISC，直接 RLRQ→TCP close |

- **必须按 `settings->interfaceType` 分支**：Wrapper 发 SNRM 是错误（R18）。`settings->connected` 仅在 `!isAuthenticationRequired` 时置 DLMS 态（`client.c:398-402`）。
- 错误区分（M11）：server 地址错→表不响应；client 地址错→认证错误；`APPLICATION_CONTEXT_NAME_NOT_SUPPORTED`→LN/SN 引用方式错；`INVOCATION_COUNTER_ERROR`→从 `reply.data` 读期望 IC；`READ_WRITE_DENIED`→换更高认证 client 地址。
- **并发（R8）**：串行队列 + busy 标志，执行期禁用按钮；不做硬中断（C 状态机非线程安全）。每次建链前 `cl_clear`+重新 `cl_init`（IC 复位，见 R14 限制）。超时由 Swift socket 层实现（见 §9）。

**★ HLS 应答：必须把「算 GMAC」和「打包 APDU」在时间上切开**（v1.6，现场验证 ✓）

库把两件事耦合在同一个字段 `cipher.security` 上：

| 用途 | 判定位置 | 行为 |
|---|---|---|
| ① APDU 是否加密打包 | `isCiphered()` = `security != NONE`（`dlmsSettings.c:439`） | 决定应用上下文 `…08 01 01`(明文) / `…08 01 03`(加密)，以及 action 打成 `C3` 还是 `CB` |
| ② 能否算 GMAC | `cip_encrypt` 的守卫 `security == NONE → INVALID_PARAMETER`（`ciphering.c:681`） | 即使 `dlms_secure` 已**显式传入** `DLMS_SECURITY_AUTHENTICATION`，仍被这道"查会话整体"的守卫拒掉 |

所以「临时把 `security` 置成 `0x10`」**不能**一路置到底 ✗ —— `0x10 != NONE` 会让 `isCiphered()` 变 **true**，
HLS 应答被打成 `CB … C3 …`（glo-action），而本表对加密上下文**永久拒绝**。

正确时序（`DLMSBridge.c` 的 `dlms_initialize`）：

```c
saved = cipher.security;
cipher.security = DLMS_SECURITY_AUTHENTICATION;
dlms_secure(...);                       /* ① 只为过那道守卫，算出 SC+IC+GMAC */
cipher.security = saved;                /* ★ 立刻还原 —— 打包前！ */
/* ② 打包：security 已是 NONE → 明文 C3，不是 CB */
cl_methodLN(settings, LN_0_0_40_0_0_255, ..., &data, &msg);
dlmsReadDataBlock(...);                 /* ③ 发送 + 收 */
cipher.security = DLMS_SECURITY_AUTHENTICATION;
cl_parseApplicationAssociationResponse(...);   /* parse 内部也调 dlms_secure，再开窗口 */
cipher.security = saved;
```

- 手法**出自官方示例** `GuruxDLMSClientExample/src/communication.c` 的 `com_updateInvocationCounter`
  （它自己就在运行时切 `settings` 再还原），不是自创的 hack ✓
- 产出报文与 .NET(GXDLMSDirector) 的成功报文**逐字段一致**：
  `C3 01 C1 00 0F 00 00 28 00 00 FF 01 | 09 11 | 10 <IC:4B> <GMAC:12B>`
  （明文 `C3` + 安全头 `SC=0x10`）✓ **现场真表 `信息加密=NONE` 已关联成功并抄表** ✓
- ⚠️ **不能**在整个会话期间把 `cipher.security` 改成非 NONE ✗ —— 那会让 AARQ 的应用上下文变成
  `…08 01 03` 而被表**永久拒绝**（`A2 03 02 01 01`）。
- 为什么「仅认证(0x10)」这条路在这台表上走不通：库把它也算作"已加密" → 上下文变 `…01 03` → 被拒。
  **所以就用 `NONE`**，让桥接层按上面的时序处理 ✓

---

## 6. 地址模型（已由源码证实）

- 客户端 = `clientAddress`；通信地址 = `serverAddress`（**运行期由 `serverAddressHex` 推导**）；
  两模式同样喂 `cl_init`，区别仅在帧内编码：
  - **Wrapper**：源/目标**直接用**（默认 `0001` / `0001`）。
  - **HDLC**：客户端为 `clientAddress`（预设下拉）；通信地址由**用户输入的原始串**决定宽度并拆分逻辑/物理，
    再**换算成 Gurux 期望的形态**后喂给 `cl_init`（见 §3.2、R25）。
- 喂进去的**不是** UI 那个 `00013FFF` ✗ —— Gurux 期望"已按目标宽度拼好的值"：
  `1B → logical & 0x7F`；`2B → (logical&0x7F)<<7 | physical&0x7F`；
  `4B → (logical&0x3FFF)<<14 | physical&0x3FFF`。
  然后由 Gurux 按 **7bit/字节 + bit0 扩展位**打包（`dlms.c:2420-2445`，按数值量级自动定宽）：
  默认 `00013FFF` → `0x7FFF` → 线上 **`00 02 FE FF`**（**现场真表抓包验证过** ✓）。
- `clientAddress:uint16_t`、`serverAddress:uint32_t`（`dlmssettings.h` 已确认，**无** `addressSize` 字段）。
- ⚠️ R16 提醒：`cl_getServerAddress` 返回 `uint16`，逻辑地址 ≥ 4 时会溢出 —— 桥接层不要走那个 helper，
  自己做位运算（上面三行）。

---

## 7. 安全（P2 重点，吸收 R1/R3）

- 信息加密四档映射为 **`DLMS_SECURITY`**（喂给 `settings->cipher.security`）：
  - `DLMS_SECURITY_NONE=0` / `DLMS_SECURITY_AUTHENTICATION=0x10`(仅认证) / **`DLMS_SECURITY_ENCRYPTION=0x20`**(仅加密,注意名是 ENCRYPTION 非 ENCRYPTED) / `DLMS_SECURITY_AUTHENTICATION_ENCRYPTION=0x30`(认证加密,用 GUEK)。`enums.h:736-751` 已核实。
  - **不要**喂 `DLMS_SECURITY_POLICY`（那是 Security Setup 对象位域 v0:1/2/3、v1:0x04..0x80）。
- 密钥约定映射（**已修正方向，P2 对真表锁定 R1**；v1.3 起按 GUAK/GUEK 口径命名）：
  - **GUAK**（全局单播认证密钥，16B）↔ `settings->cipher.authenticationKey` —— HLS-GMAC 的认证密钥
  - **GUEK**（全局单播加密密钥，16B）↔ `settings->cipher.blockCipherKey` —— 信息加密用
  - **MK / GBEK**：暂不提供（底层 `settings->cipher.dedicatedKey` 槽位预留，`dlms_set_security` 第 5 参传 NULL）
  - 落在桥接 `dlms_set_security(ctx, security, guekHex, guakHex, NULL)`（参数名沿历史命名，含义以头文件注释为准）
  - 三者默认值：GUAK/GUEK = 16 字节全 0，客户端 SystemTitle = `4142433031323334`；**留空 = 用默认值**
  - hex 输入归一化：去空白与 `:` `-` 后转大写；非法字符不静默丢弃，由 UI 的字节数校验提示（`HexUtil.normalize/isValid`）
- SystemTitle（**方向已修正，只管客户端；服务器自动**）：
  - **客户端自己的 SystemTitle** → `settings->cipher.systemTitle`（`client.c:443` 用它当 GMAC 密钥），**必须在 `cl_aarqRequest` 之前设置**，否则 AARQ 无 A6 字段、HLS 必然失败（R13）。
  - **服务器 SystemTitle** → `settings->sourceSystemTitle`（顶层 `unsigned char[8]`，**由 AARE 的 AP-title 自动回填**，`apdu.c:1737`），一般无需手填；仅 pre-established 才需手填。**不作为 UI 输入，捕获后显示在数据/日志区。**
- 相关字段（已确认 ciphering.h）：`security`、`suite`、`securityPolicy`、`encrypt`、`blockCipherKey`、`broadcastBlockCipherKey`、`systemTitle`、`invocationCounter`、`authenticationKey`、`dedicatedKey`。

### 7.1 四档在真表上的实测（2026-09-21，HDLC + HLS-GMAC + 4 字节地址）

| 信息加密 | 结果 | 原因 |
|---|---|---|
| `NONE` (0x00) | **✓ 可读表**（**经 v1.6 桥接修复后**） | 库不肯在 `security == NONE` 下算 GMAC → 桥接层按 §5.2 的"切开算/打包"时序处理，**APDU 仍是明文 `C3`、上下文仍是 `…01 01`** ✓ |
| `仅认证` (0x10) | ✗ **这台表拒绝** | 库把 `0x10` 也算作"已加密" → 应用上下文变 `…08 01 03` → 表回 `A2 03 02 01 01`（permanent-rejected） |
| `仅加密` (0x20) | ✓ 可读表 | 上下文 `…01 03`，本表接受 |
| `认证加密` (0x30) | ✓ 可读表 | 同上，也是 HLS-GMAC 的标准组合 |

> **结论：就用 `NONE`**（协议语义上 HLS-GMAC 配 NONE 是合法配置 ✓，用户判断正确；
> 是这一版 C 库的实现限制需要绕，**不是协议问题**）。
> 判据来自 `.NET(GXDLMSDirector)` 的 **GMAC + `Security: None` 成功报文**：
> 应用上下文 `…08 01 01`、HLS 应答是**明文 `C3` + `SC=0x10` + 12B GMAC** ✓
> —— 这正是我们修复后的产出形态，**现场已逐字节对上** ✓

---

## 8. 报文日志 & 数据解析

- **trace 通路**：桥接 C 增 **trace 回调**，发/收每帧回调 `(方向, 完整原始帧字节)`。
  - P1 在 bridge 的 send/recv 处抓全部原始帧（TCP 上报文必经）。
  - **零 patch 拿明文 PDU**（R9）：提供 `cip_tracePdu`（`ciphering.h:192`，需开 `gxignore.h:186` 的 `DLMS_TRACE_PDU` 一行）即可拿到**加解密后的明文**，优于 patch vendor。

- **显示规则（v1.4）**：每行 **4 列固定宽度** ——

  ```
  时间戳(74pt) │ TX·RX(26pt) │ 报文类型(92pt) │ 完整 HEX（自适应换行）
  00:01:23.456     TX            AARQ            7E A0 77 00 02 ...
  00:01:23.789     RX            AARE            7E A0 7A 61 00 ...
  00:01:24.001     TX            Get-Request     7E A0 1E 00 02 ...
  ```

  - **报文类型必须与 HEX 分列**，不能拼进同一个字符串。早前实现是 `"\(type)  \(hex)"`（两个空格拼接），而类型名长度不一（`AARQ`=4 字符 / `Get-Response`=12 字符）→ **HEX 起始位置每行都不同**。这正是用户报的"TX 后面两个空格导致上下不对齐"。
    → `LogEntry` 因此**单独增加 `label` 字段**承载类型，`text` 只放 `TX`/`RX`。
  - **报文类型清单**（HDLC 控制字段取值以 `enums.h` 为准，**勿凭记忆**）：
    - HDLC 链路层：`SNRM=0x93`(enums.h:1203) / `UA=0x73`(:1208) / `DISC=0x53`(:1223) / `DM=0x1F`(:1193)
    - APDU：`AARQ=0x60` / `AARE=0x61` / `RLRQ=0x62` / `RLRE=0x63` / `Get-Req=0xC0` / `Get-Resp=0xC4` / `Set-Req=0xC1` / `Set-Resp=0xC5` / `Action-Req=0xC3` / `Action-Resp=0xC7`
    - ⚠️ 早前误写 `SNRM=0x35` / `DISC=0x40` → 这两个报文**永远标注不出来**，且 `0x35`/`0x40` 会撞上 HDLC 地址/长度字段造成**误标**。
  - 颜色：**TX 绿 / RX 蓝 / 信息 灰**（以当前实现为准；早期文档写的"TX 红"与之不符 —— 若要改回红色需同时改代码与本节）。
  - **工具行（v1.4 补）**：两个面板顶部共用同一套 `panelHeader` 布局 —— **左＝本面板的开关/状态，右＝固定「清空」**。
    - 解析面板：左 `解析使能` 开关 + `满屏`，右清空 → `store.clearParsed()`；
      结果**累积**在 `store.parseEntries`（上限 200 条），独立滚动并自动跟随到底
    - 报文面板：左 **条数**（`共 N 条`；N>200 时标 `· 显示最近 200`），右清空 → `store.clearLogs()`
    - 条数必须显示：`Store` 最多留 **2000** 条，而列表只渲染 **最近 200** 条 —— 不标出来用户会以为"清空"删掉的和屏幕上的不是同一批。
    - 清空按钮在内容为空时 `disabled`（灰掉），避免误点后莫名无反馈。
    - 做成同一套布局是为了切面板时**视线不用重新找按钮**。（此前报文面板**根本没有**清空入口，`Store.clearLogs()` 实现了却从未被调用。）
  - 报文的 `>>>` 语义注解（R4）仍留 P3 加深。
  - **报文面板可满屏**：面板嵌在页面级 `ScrollView` 里，高度被压住拉不开；
    「满屏」用 `fullScreenCover` 展示。`logList(height:)` 已**参数化**（内嵌传 `260`，满屏传 `nil` 放开约束）
    —— 此前写死 `.frame(height: 260)`，满屏视图里列表也只有 260pt、下面一片空白 ✗。
  - ⚠️ **报文类型列是启发式识别，可能误标**：`classify` 扫前 16 字节里首个命中的 tag，
    HDLC 帧的第 8 字节是 HCS（如 `C0`）会**先于**真正 APDU 的 `0x60` 命中 →
    AARQ 被标成 `Get-Request`。**看日志时请忽略类型列**，精确化方案见 §13.2 / R20。

- **数据解析（v1.7 重做：两行格式 + 累积滚动）**

  桥接层 `dlms_renderValue` 输出**恰好两行**，UI 直接显示：

  ```
  09 03 31 32 33
  -> Type: octet-string, Length: 3, Value: 123
  ```

  | 行 | 内容 | 规则 |
  |---|---|---|
  | **行 1** | 带类型的**原始 HEX** | 变长类型（octet-string / visible-string / utf8-string / **bit-string**）→ `tag + 长度 + 内容`；定长类型 → `tag + 内容`（整数**大端**对齐到宽度）。长度按 A-XDR 编码：`<0x80` → 1 字节；`≤0xFF` → `0x81`+1；`≤0xFFFF` → `0x82`+2；否则 `0x83`+3 |
  | **行 2** | `-> Type: <名字>, [Length: N,] Value: <可读>` | 整数/浮点/枚举交 `var_toString`；`boolean` → `true/false`；octet-string 全可打印 → 直接给 ASCII，否则 `（非文本）`；date-time / array / structure 交库 |

  - `bit-string` 的 `bitArray.size` 是**位数**、而编码里的长度是**字节数** → `(size + 7) / 8`
    （此前 `hasExplicitLength` 声明了它有长度字节、`lengthPrefixedBytes` 却不处理它 →
    行 1 输出假长度 `04 00`，真实位串整个丢掉 ✗）。
  - 复合/未知类型（FLOAT / DATE / TIME / DELTA_*）**只输出 tag** —— 这是"不做编码回推"，不是丢数据。
  - **累积显示**：结果 push 进 `store.parseEntries`（不是每次替换），面板独立滚动 + 新结果自动跟随到底，
    右上「清空」清历史。
  - **「解析使能」真正生效**：关闭时**逐段**只留行 1（原始 HEX），不做类型/值解析
    —— 此前这个开关**没有任何地方读取它**，拨了完全没反应 ✗。
  - 类型名表以 `enums.h` 为准（`INT32=0x05` 是 **double-long** 不是 "long"；`UINT32=0x06` 同理）。

---

## 9. 桥接 C 增量（`Sources/DLMSCore/Headers/DLMSCore.h` 的**实际**公开面）

```
生命周期   dlms_new / dlms_free
配置       dlms_set_security(security, guek, guak, dedicated=NULL)
           dlms_set_clientSystemTitle(hex)        ← 必须在 AARQ 前（R13）
           dlms_set_invocationCounter(value)      ← P2
查询       dlms_get_serverSystemTitle(out, &len)  ← AARE 回填的服务器 SystemTitle
I/O        dlms_set_io(user, sendFn, recvFn)  /  dlms_set_trace(user, traceFn)
会话       dlms_initialize / dlms_read / dlms_write / dlms_method / dlms_disconnect
诊断       dlms_lastStep / dlms_sendFailed / dlms_step_name(int step)
           dlms_rxSize / dlms_rxPosition         ← 只读；排查分片/游标问题用（v1.7）
错误/渲染  dlms_error_string(code)  /  dlms_dataTypeName(int)
```

- `dlmsCtx` 在公开头里是 **opaque 类型**，所以给它加字段（如诊断用的 `lastStep`/`sendFailed`）
  **不影响 ABI，也不影响 Swift 侧**。
- 参数名以头文件为准：`dlms_set_security` 的第 3/4 参历史上叫 `akekHex`/`authKeyHex`，
  含义是 **GUEK / GUAK**（见 §7、R21）。
- `dlms_initialize` 按 `interfaceType` 分支（Wrapper 不发 SNRM，R18）+ HLS challenge（§5.2，
  **含 v1.6 的"切开算/打包"时序**）。每步失败会记 `lastStep`；`dlmsSendFrame` 的 send 失败记 `sendFailed`。
- **`dlms_sendFrame` 的两道有界性闸门**（防死循环 + 防内存无限增长）：
  - `DLMS_MAX_RECV_ROUNDS = 256` —— **轮次**上限。之所以必须有：`fail` 在"收到数据"时归零，
    若对端持续有字节到达却始终构不成一个会被接受的帧，唯一的守卫就失效了 → 死循环 + `rx` 无限增长。
  - `DLMS_MAX_RX_BYTES = 256KB` —— **字节**上限（轮次管不了总量）。
- `dlms_write` / `dlms_method` 的失败路径会 `var_clear(&v)` 释放已建的 variant
  （`dlms_write` 里必须先补 `var_init(&v)`，否则失败路径的 `var_clear` 会读未初始化内存）—— 见 R27。
- `dlms_renderValue` **刻意不进头文件**（避免 Swift 侧看到 `dlmsVARIANT` 类型），
  只在 C 内部 + 测试里自行声明 —— 这样单测能构造 variant 直接断言渲染结果。

- **`dlms_set_timeout` 删除**：vendor 无此符号，超时由 **Swift socket 层**实现（连接超时 5s；recv 取 `ConnectionConfig.recvTimeoutMs` 默认 3000；整体操作/TM 分隔）。
- **P0 修桥（首要）**：接收缓冲改为 **ctx 上跨 recv 持久化的累积缓冲**。
  ⚠️ **追加必须手工做**，**不要用 `bb_insert`** ✗ —— 它的 `index` 参数同时被当作「目标插入点」和「源数据偏移」（实现是 `memmove(target->data + index, src + index, count)`），且**从不更新 `target->size`**；库里所有调用都传 `index=0` 才碰巧正确。正确写法见 `DLMSBridge.c` 的 `bufAppend`：
  `bb_capacity(rx, rx->size+len+256)` → `memcpy(rx->data + rx->size, src, len)` → `rx->size += len`（**R26**，这是现场「数据过长无法交互」的根因）。
  容量按 `maxPduSize + 50` 动态分配（非 512B 固定；官方原话：有些表会多发几个字节）；Wrapper 不发 SNRM；断链先 `cl_releaseRequest2(sec!=NONE)` 再 `cl_disconnectRequest`。
- **socket 归属写死**：Swift 持有 socket；bridge 暴露「给报文→收响应」的阻塞式接口；HDLC 帧边界用 `cl_getData` 的 `reply->complete` 判定，Receiver Ready / data-block 续传循环放 bridge 层（照抄 `GuruxDLMSClientExample/src/communication.c`）。
- **会话复位（R8）**：每次建链前 `cl_clear`+重新 `cl_init`（`invocationCounter` 复位；P1 文档化"IC 从 1 起可能被真表拒"，P2 加 IC 同步 M5）。
- **trace（M9/R9）**：优先**零 patch**——bridge 的 send/recv 抓原始帧 + 提供 `cip_tracePdu`(见 `ciphering.h:192`)接管明文 PDU；仅需在 `gxignore.h:186` 开 `DLMS_TRACE_PDU` 一行（可脚本化）。

---

## 10. 构建 / CI（**已跑通**）

> 现状：**全部达成** —— CI 三道闸门全绿 → 出未签名 IPA → Windows 真机侧载成功。以下为契约与经验记录。

- XcodeGen `project.yml` + GitHub Actions，三道闸门：

  | 闸门 | 位置 | 内容 |
  |---|---|---|
  | 2 | `ubuntu-latest`（1x 计费，**先跑**） | `Tests/CTests/run.sh`：C 桥接 + vendor 客户端子集纯单测 |
  | 1 | `macos-15`（10x 计费） | 模拟器全量编译（不签名） |
  | 3 | `macos-15` | Swift 托管单测（`@testable import DLMSApp`，需先装宿主 App） |

  - 闸门 2 是闸门 1/3 的 `needs` 前置：C 层挂了就不启动 macOS，省额度。
- **出包**：`build-ipa.yml`，**打 tag（`v*`）自动触发**或手动 Run workflow → 真机 Release 编译 → 打未签名 IPA（标准 `Payload/` 结构）→ 产物 `dlms-unsigned-ipa`。
- **装机**：Windows + Sideloadly + 免费 Apple ID。必装 **iTunes 官网版**（提供 Apple Mobile Device Support 驱动，Store 版不行）；iOS 16+ 需先开「开发者模式」；证书 **7 天**，续期只需重签、不用重编、数据保留。
- ⚠️ 仓库是 **public** → macOS runner 免费不限时；若是 private，Free 计划 2000 分钟 ÷ 10 倍率 ≈ 每月仅 200 macOS 分钟。

### 10.1 CI 踩过的坑（均已修，勿重犯）

| 现象 | 根因 | 修法 |
|---|---|---|
| `'DLMSCore.h' file not found` | `HEADER_SEARCH_PATHS` 缺 `Sources/DLMSCore/Headers` | 补上（framework 自身编得过 ≠ App 侧能找到） |
| `Undefined symbols: _SERIALIZER_LOAD/_SAVE/_SIZE` | Apple 不在「Windows/Linux 用 FILE 流」分支，`gxserializer.c` 会调应用须实现的钩子 | 定义 `-DDLMS_IGNORE_SERIALIZER`（该 `.c` 整个文件被此宏包住，故够用） |
| `attribute can only be applied to types, not declarations` | `@convention(c)` **不能作用于函数声明** | 改成「非捕获闭包赋给 C 函数指针类型常量」：`let f: dlmsSendFn = { … }` |
| `umbrella header 'DLMSCore.h' not found` | 桥接头没进 Headers 构建阶段 → 没被复制进 `DLMSCore.framework/Headers/` | project.yml 的 `headers:` **顶层键不生效**，必须写成 `sources` 条目 + `buildPhase: headers` + `headerVisibility: public` |
| `Section(_:content:footer:)` 编译失败 | SwiftUI **没有**这个重载 | 带标题+footer 必须写 `Section { } header: { } footer: { }` |
| 模拟器装不上：`Failed to load Info.plist` | **framework target 没有 Info.plist**（既无 `INFOPLIST_FILE` 也无 `GENERATE_INFOPLIST_FILE` 时 Xcode 不生成）；且报错路径会被**截断**，容易误判成 App 的 plist | `DLMSCore` 加 `GENERATE_INFOPLIST_FILE: YES`；App / 测试 bundle 用显式 plist |
| `cannot convert value of type 'UInt16' to expected argument type 'Int'` | 调用方多包了一层 `UInt16(...)` | `classVal` 本就是 `Int`，直接传；`UInt16` 转换只在 C 边界做**一次** |
| tag 出包时 C 单测被**静默跳过** | `workflow_dispatch` 的 `inputs.*` 在 `push` 事件下不可用 → 求值为假 | `if: ${{ github.event_name == 'push' \|\| inputs.run_ctest }}`。**任何 inputs 条件扩展成也能自动触发时都要复查** |

### 10.2 远端排查 CI 失败（零凭据）

公开仓库下：**运行 / 作业 / 步骤状态** 与 **check-run annotations** 可匿名读；**job 日志与 artifact 需鉴权**（实测 401 / 0 字节）。
因此 `ci.yml` 失败时把关键报错行打成 `::error::` **注解** —— 就能匿名取到**完整**报错（比 GitHub 自动生成的 `exit code 65` 有用得多，也是靠它才发现"缺 plist 的是 framework 而非 App"）。

> ⛔ **不要**用 `git credential fill` 去取 token 拉日志：本机凭据未缓存时**每次都会弹浏览器登录**。

### 10.3 本地测试（拟真台，一条命令）

```bash
CC=/c/TDM-GCC-32/bin/gcc.exe bash Tests/CTests/run.sh     # Windows / MinGW
CC=clang bash Tests/CTests/run.sh                          # Linux / macOS（CI 用）
```

`run.sh` 编排四步（跨平台，gcc/clang 均可）：

| 步 | 内容 | 断言强度 |
|---|---|---|
| ① | 单测 `test_dlms`（含**协议回放**：桩 send/recv + 自造合法帧） | 强（`DLMS_SKIP_REPLAY=1` 可跳） |
| ② | 端到端 `local_e2e`（**真 TCP socket** ↔ `tools/mock_meter`，整帧） | 强 |
| ③ | 分片观察（8 / 16+5ms / 32 / 64 字节） | 强（修掉 R26 后分片已能正常重组） |
| ④ | 有界性（对端静默） | 强（必须**快速有界失败**，不得挂死） |

- 窗口/平台差异由 `tools/sock_compat.h` 收敛；MinGW 需 `-lws2_32`（`run.sh` 按 `uname` 自动加）。
- 本机 loopback 监听**不弹防火墙**；模拟表能精确复现"长帧被 TCP 拆开"。
- 实测耗时（用 `-O0 -g`）：编译 43 个 `.c` + 桥接 + 测试 + 链接 ≈ **15 s**；加 `--coverage` 插桩 ≈ **65 s**；
  **测试体本身 < 0.1 s** —— 慢在编译，不在测试。建议用后台任务跑以免等待。
- 覆盖率工具链：`gcov` 在 MinGW 里有（`C:\TDM-GCC-32\bin\gcov.exe`）；跑完 exe 后到 `.gcno/.gcda` 目录
  `gcov <name>.gcda`，函数级明细加 `-f`。

> ⚠️ 一条踩过的坑：`gdb` 在 TDM-GCC 里**没有** ✗，`nm`/`objdump` 的输出也常被吞 ✗。
> 这类排查**最可靠的手段是"给桩加计数和上限 + 逐句打印 + `setvbuf(stdout, NULL, _IONBF, 0)`"**
> —— `setvbuf` 必须加，否则进程崩溃会丢掉所有缓冲输出，只能看到一个空结果。

### 10.4 本地静态自查：对付"报错指不到出问题的地方"的一类错误

本机没有 Swift 工具链，所以有一类错误**只能等 CI**；但如果它的判据是**纯文本可判**的，
就值得写成脚本在本地拦住 —— 尤其是那些"编译器的报错落在别处、指不到真正的问题行"的错误。

**`tools/chk_codingkeys.py`**（本机 / CI 均可跑，纯标准库，退出码 0/1）：

```bash
python3 tools/chk_codingkeys.py          # 从脚本位置推断仓库根
python3 tools/chk_codingkeys.py <repo根> # 显式指定
```

判据：`CodingKeys` 的每个 case 都必须能对应到一个**存储属性**（非 `static`、非计算属性）。
理由 —— 合成 `Encodable` 会为每个 case 找同名属性，找不到就整份不满足协议，
而报错**只落在 struct 声明行**（`does not conform to protocol 'Encodable'`）、**完全指不到那个 case**。
本项目 CI 已因此红过 **两次**（先 `serverAddressWidth`、半修后又栽在 `serverAddress`）→ **R32**。

> 已淘汰、**只读不写**的旧键要另开一个 enum（如 `LegacyKeys`）只用于解码 ——
> 别的名字不参与合成 Codable，所以那里 case 无对应属性是**故意的**；
> 脚本**只检查名为 `CodingKeys` 的那个 enum**。
>
> 脚本自身也踩过一个坑值得记：解析 `case` 行时**必须逐行做** ——
> 用单个正则 `case\s+([\w\s,]*)` 时字符类里的 `\s` **含换行**，
> 会把后面几行连着吞成一次匹配，只取首行就**漏检**（正是它一开始"报 OK"的原因）。

---

## 11. 明确不做（P1/P2/P3 之外）

循环/批次 · Profile Generic 曲线 · 自动枚举/目录树 · 串口 · 商用分发（自用，GPL 无碍）。

---

## 12. 风险登记（实现时逐一核销）

| 编号 | 风险 | 处置 |
|---|---|---|
| R1 | GUAK/GUEK ↔ Gurux `authenticationKey/blockCipherKey` 映射（原 EM/AK/EK 口径） | P2 对真表专项验证后锁定 |
| R2 | 写=BER 字节直传；执行=需解析成 variant | 写 hex→variant 解析器（P1 基础/P3 完善） |
| R3 | SystemTitle：客户端 App 设置(sourceSystemTitle) vs 服务器 AARE 返回(cipher.systemTitle) | 服务器自动捕获显示，不作为输入；客户端可留空 |
| R4 | 报文 `>>>` 语义注解需 C 侧解析 APDU | P1 简化注解，P3 完善 |
| R5 | 首次 macOS/Xcode 编译可能报错（C/modulemap） | 设为首个 CI 闸门，预期修正 |
| R6 | 桌面 "HLS_ES_GMAC" vs Gurux `HIGH_GMAC(5)` 是否同义 | 先按(5)，对表失败再调 |
| R7 | OBIS hex 自动识别启发式（含 a-f→16进制）可能误判 | 十进制 OBIS 无字母，接受此启发式 |
| R8 | 重复建链下 invocation counter / 会话状态复位 | 每次连接前 `cl_clear`+重新 `cl_init`；串行+busy，禁硬中断 |
| R9 | vendor trace patch 维护 | **降级**：优先零 patch（bridge 抓帧 + `cip_tracePdu` 接管明文） |
| R10 | 接收帧跨 TCP 分段被覆盖（原 `bb_set`） | **P0 已修 ✓**：改为 ctx 上跨 recv 持久化的累积缓冲。⚠️ 但修的时候**误把 `bb_insert` 当追加用**，反而引入 R26 —— 见下 |
| R11 | 接收缓冲 512B 过小 | P0：按 `maxPduSize+50` 动态分配 |
| R12 | HLS 缺 challenge 回合 | P1：`isAuthenticationRequired` → `cl_getApplicationAssociationRequest` |
| R13 | 客户端 SystemTitle 未设 → AARQ 无 A6、HLS 失败 | P1：UI 常显 + 8 字节校验 + 选 HLS 标必填；v1.3：默认 `4142433031323334`，留空不再落成空值 |
| R14 | P1 无 IC 同步，IC=1 可能被真表拒 | P1 文档化；P2 加 IC 同步 + 持久化 |
| R15 | `cip_init` IC=0 vs `cip_clear` IC=1 不一致 | P2：显式赋值，不依赖库初值 |
| R16 | `cl_getServerAddress` 返回 uint16，logical≥4 溢出 | P3：UI 合成器校验 |
| R17 | `cl_methodLN` vendor bug（ARRAY/STRUCTURE 分支恒假） | P3：先确认版本 |
| R18 | Wrapper 模式误发 SNRM | P0：按 interfaceType 分支 |
| R19 | 密钥字段改名（aKEK/AK/EK → GUAK/GUEK）使旧 `config.json` 键失效 | v1.3：`ConnectionConfig.init(from:)` 容错解码，缺键回退默认 → 旧 IP/端口/认证等全部保留；仅密钥本身回落到默认全 0，需按现场重填 |
| R20 | 报文类型标注是**启发式**（扫前 16 字节里首个命中的 tag），可能误标 | v1.4 已修正表值（`SNRM=0x93`/`DISC=0x53`，原 `0x35`/`0x40` 永不命中且会撞地址字段）。精确做法：让 bridge 回传 C 层已解析的 `gxReplyData.command` → §13.2 |
| R21 | `dlms_set_security` 参数名仍叫 `akekHex`/`authKeyHex`，而 aKEK 口径已废 | 纯改名不影响行为（C 参数名不影响 ABI，也不影响 Swift 调用）。建议改为 `guekHex`/`guakHex`；当前靠 `DLMSCore.h` 注释兜底 |
| R22 | **密钥长度未校验**：`hexToBytes` 走 `bb_addHexString`，任意长度都接受 | AES-128 需 **16 字节**。UI 已有字节数提示（`HexUtil.isValid`），但 bridge 未拦截 → 建议 bridge 校验长度并返回错误码，别让错长度密钥进到 cipher |
| R23 | 整数越界曾直接 **trap 崩溃**（`UInt16(x)`/`UInt8(x)` 是非夹取转换） | v1.4 已修：C 边界统一 `UInt16(clamping:)` / `UInt8(clamping:)`（类填 99999、属性填 300、端口填 99999 不再闪退） |
| R24 | OBIS 编辑器接口类占位符写 `Data=1`，该串含 `=` **无法解析** → 保存时静默保留旧值 | v1.4 已改为可解析的示例（`3 / 0x1F`） |
| R25 | 地址"1 字节 / 2 字节"**无法用数值区分**（`01` 与 `0001` 都是 `0x01`） | **v1.6 已解决 ✓**：`serverAddress` 不再用 `UInt32`，改为**保留原始输入串** `serverAddressHex` —— 宽度 = 输入字节数（1/2/4；3 字节等非法，UI 标红）。拆分规则：1 字节=仅逻辑地址；2 字节=逻辑/物理各 1；4 字节=各 2。Gurux 仍按数值量级定宽，故 UI 用 `serverAddressWidthMatched` 提示"输入宽度 ≠ 实际宽度"（见 R16） |
| **R26** | **`bb_insert` 被当作"追加"用** —— 它的 `index` 同时是「目标插入点」和「源数据偏移」（`memmove(target->data+index, src+index, count)`），且**从不更新 `target->size`**。库里所有调用都传 `index=0` 才碰巧正确 | **已修 ✓**（`c6d1ff8`）。`bufAppend` 改为手工追加（`bb_capacity` → `memcpy` → `size += len`）。**症状特征：短响应（一次 recv 到齐）正常，一旦被 TCP 拆开就永远收不全** —— 这正是现场报的「数据过长无法交互」✓ 定位靠**分片矩阵实验**（8/16/32 字节全挂、96 字节=整帧才成功）+ `dlms_rxSize` 打印出 `size` 卡在首片长度 |
| **R27** | **`bb_clear` 不检查 `arr` 本身**（只查 `arr->data`），而 `var_init` 把 `byteArr` 置 `NULL` → `bb_clear(NULL)` 读 `NULL->data` 崩溃。两条路径：写（`buildBytesVariant`）、action（`buildVariantFromHex` 先设了 `vt` → `var_addBytes` 跳过分配分支走 else） | **已修 ✓**（`7e9770e`）。新增 `setOctetStringVariant()`：照库自身约定 `gxmalloc(sizeof(gxByteBuffer))` + `bb_init` + `bb_set`；两处调用点统一用它。**判据**：OCTET_STRING variant 的 `byteArr` **必须堆分配** —— 写/action 一点就崩、读路径没事（读不构造 variant） |
| **R28** | **`ObisItem` 新增 `data` 字段后没同步手写 `init(from:)`** → 合成解码对「缺键 + 非 Optional」照样抛错 → 旧 `obis.json` **整份解码失败** → `Store.load` 返回 nil → 用户清单**被静默重置成预置列表** | **已修 ✓**（`8c16bcc`）。手写容错 `init(from:)`（与 `ConnectionConfig` 同一口径）。**这是 R19 的同类坑在第二个模型上重演** —— 凡是 `Codable` 结构体加/改字段，必须同步 init |
| **R29** | **预读缓冲的两处内存隐患**（审核报告 v2 的 N1/N2）：① `receive` 两处排空 `pending` **都无视 `max`**，而 recv 回调 `copyBytes(to:count:)` 是**无边界检查写入**、C 侧缓冲是固定 `tmp[2048]` 栈数组 → **栈破坏**；② `pending` 无字节上限 | **已修 ✓**（`a71adba`）。① 新增 `takePending(buf:max:)`：按 `max` 截断、**余量留在 pending**；回调再加 `min(cap, d.count)` 兜底。② `pendingLimit = 256KB`（对齐 C 侧 `DLMS_MAX_RX_BYTES`），超限丢最旧。**关键放大器**：`connection.receive` 的 completion **超时后无法取消**（Network.framework 无单次取消 API），而 `dlmsSendFrame` 允许重试 256 轮 → 可累积 N 个挂起 completion，一次排空可达 `256×2048`，**不是报告说的 2×2048** |
| **R30** | **OBIS 写法差异导致静默匹配失败**：清单里是点分归一形态（`1.0.1.8.0.255`），「最近 OBIS」存的是用户当初的输入原文（可能 `1-0:1.8.0*255`）→ 按原文比较**永远查不到** → 选中后类/属性/请求数据全带不过来；下拉里同一对象还会出现两条 | **已修 ✓**（`8c16bcc`）。新增 `ObisUtil.comparisonKey`（去空白 + 大写 + `- : * ,` → `.`），**匹配与记录两处都走它**。凡涉及 OBIS 的比较/去重一律用它 |
| **R31** | **测试脚手架 `buildHdlc` 的 HCS 算错**（先用 `0x00` 占位算 HCS、之后才回填长度，而 HDLC 的 **HCS 必须覆盖真实长度字节**）→ 库校验不过**静默跳过该帧** → `reply->complete` 恒为 0 → `dlmsSendFrame` **死循环**（`fail` 在"收到数据"时归零，唯一守卫失效） | **已修 ✓**（`af449aa`）。先定长再算 HCS。**用现场真实 UA 帧独立验证**：`HCS(A0 1E 03 03 73)=CC40` → 线上 `40 CC` ✓ 与抓包一致。生产侧同时加 `DLMS_MAX_RECV_ROUNDS=256` 兜底（防"对端持续吐数据却构不成可接受帧"）|
| **R32** | **`CodingKeys` 里放了没有对应存储属性的键** → 合成的 `encode(to:)` 为每个 case 找同名属性、找不到就整份不满足 `Encodable`；**报错只落在 struct 声明行，完全指不到那个 case** | **已修 ✓**（`f...`，2026-09-24）。已淘汰、只读不写的旧键移到独立的 `LegacyKeys`（只解码不编码）。**CI 为此红过两次**（先是 `serverAddressWidth`，半修后又栽在 `serverAddress`）；判据已写成脚本 `tools/chk_codingkeys.py` 可在本地/CI 拦住 —— **见 §10.4** |


---

## 13. 符号核实台账

### 13.1 已核实（逐条读 vendored 源码确认，可当契约用）

| 符号 / 事实 | 结论 | 出处 |
|---|---|---|
| `DLMS_SECURITY` | `NONE=0` / `AUTHENTICATION=0x10` / **`ENCRYPTION=0x20`**（不是 ENCRYPTED）/ `AUTHENTICATION_ENCRYPTION=0x30`；**不是** `DLMS_SECURITY_POLICY`（那是 Security Setup 对象位域） | `enums.h:736-751` |
| `DLMS_DATA_TYPE` tag 表 | `INT8=0x0F` / `INT16=0x10` / `UINT8=0x11` / `UINT16=0x12` / `INT32=0x05` / `UINT32=0x06` / `BOOL=0x03` / `OCTET_STRING=0x09` / `ENUM=0x16`；`0x80` = `BYREF` 掩码（tag 7/8/11/14 未使用） | `enums.h:525-558` |
| `cl_writeLN` / `cl_methodLN` | 第 5 参是 **`dlmsVARIANT*`**（**非** `gxByteBuffer*`）；`cl_writeLN` 另有第 6 参 `byteArray` 决定语义 | `client.h:226-233` / `client.h:350-356` |
| HLS challenge 流程 | **不是**手读 `0.0.40.0.0.255` 再自己算 GMAC。`cl_parseAAREResponse` 只置 `settings->isAuthenticationRequired`，应用层须再走 `cl_getApplicationAssociationRequest` → 收帧 → `cl_parseApplicationAssociationResponse`（Gurux 内部才去调 `0.0.40.0.0.255` method 1） | `client.c:380-409`、`client.c:502`、`REF:communication.c:1099` |
| SystemTitle 方向 | **客户端自己的** → `cipher.systemTitle`（`client.c:443` 拿它当 GMAC 密钥，须在 AARQ 前设）；**服务器的** → 顶层 `unsigned char sourceSystemTitle[8]`（AARE 自动回填，`apdu.c:1717`） | `dlmssettings.h:117`、`ciphering.h:83` |
| 密钥落点 | GUEK → `cipher.blockCipherKey`；GUAK → `cipher.authenticationKey`；`dedicatedKey` 为预留槽位 | `DLMSCore.h:48-50` + `DLMSBridge.c:216-260` |
| HDLC 控制字段 | `SNRM=0x93` / `UA=0x73` / `DISC=0x53` / `DM=0x1F` | `enums.h:1203/1208/1223/1193` |
| HDLC 地址字节数 | 库里按 `serverAddress` **量级自动推断**；`dlmssettings.h` 中**无** `addressSize` 字段 → 所以桥接层必须**先把输入按目标宽度拼成 28/14/7 位**再喂进去（v1.6 起由 `serverAddressHex` 的字节数决定宽度，见 R25） | `dlmssettings.h:132/134` + `dlms.c:2420-2445` |
| `cip_tracePdu` | `extern` 弱符号、库不实现 → 自己提供同名函数即可拿到**明文 PDU**；只需开 `gxignore.h:186` 的 `DLMS_TRACE_PDU` | `ciphering.h:192` |
| 抓原始帧 | 在 bridge 的 send/recv 处汇总即可（TCP 上报文必经），无需 patch vendor | — |

### 13.2 仍待确认 / 待做

- `cl_methodLN` 的复杂入参（ARRAY / STRUCTURE / 浮点 / 日期）→ P3；注意 R17 的 vendor bug（分支条件恒假）。
- **精确报文类型标注**：让 bridge 把 C 层已解析的 `gxReplyData.command`（`DLMS_COMMAND`）随 trace 回传，
  即可去掉启发式误标风险（R20）。**当前 `classify` 会把 AARQ 标成 `Get-Request`**（HCS 的 `C0` 先命中）。
- ~~地址宽度显式表达~~ → **v1.6 已实现 ✓**（`serverAddressHex` 保留输入字节数）。
- **密钥长度在 bridge 侧拦截**（R22）：AES-128 需恰好 16 字节，错长度会以同一个 `INVALID_PARAMETER` 失败，难排查。
- **mock 的 Set-Response 保真度**：`local_e2e` 里 `dlms_write` 目前只能弱断言（"非 `INVALID_PARAMETER`"），
  实测返回 `260 (RECEIVE_FAILED)` —— 判定为 mock 回的最小 `C5 01 00` 不足以让库接受，**非生产 bug**。
  补全后 write 才能做成强断言（否则写路径的端到端正确性实际没被闸门守住）。
- **`pending` 的根治**（R29 的后续）：`prefix(max)` 只防溢出，`pending` 仍可能增长。
  更根本的做法是**常驻接收循环**（一次只挂一个 completion，收到就入队、永不因超时丢弃）
  —— Network.framework 的惯用法。改动面较大，需单独评估。
- `Store.load/save` 现在会把"文件损坏"记一条 warn（v1.7）；但**写盘失败**仍是静默的（异步队列里的 `try?`）。
- **S1 密钥入 Keychain**：仍是明文存 `config.json`（自用调试台，待定）。
- **M5 `ObisImporter` 单测**：仍是缺口（含 `parseBare` 不处理 RFC4180 转义引号 `""`）。

---

## 14. v1.5 批量优化（UI / 交互）

> 动机：报文面板"清空"缺失只是表象，真正的问题是**日志区根本没有独立滚动**。
> 用户要求同类问题一次性改完（避免多次"推送—编译"往返）。

### 14.1 本轮已落地

| # | 问题 | 处置 |
|---|---|---|
| U1 | **报文日志无独立滚动**：日志无限追加，却跟着**页面级外层 `ScrollView`** 一起滚 —— 新报文落在下方看不到，攒到 200 行整页被拉极长 | 日志区改**独立 `ScrollView`**；用 `ScrollViewReader` 在新报文到达时**自动滚到底**（一次操作结束后没有新流量，此时可自由向上翻阅历史）。v1.7 补：高度**参数化**（内嵌 260pt / 满屏放开）+ 加「满屏」入口 —— 原来写死 260pt，满屏视图里也只有 260pt、下面一片空白 ✗ |
| ~~U2~~ | ~~写(Set) / 执行(Action) 加二次确认~~ | **已撤销** —— 用户明确表示**不需要**：现场操作要快，误点风险自担。代码里 `start()` 直接执行，不做确认弹窗。**本条不再实施** |
| U3 | 结果与状态耦合在**字符串前缀**（`"完成 · "`）上，View 靠拆前缀取值 —— 状态文案里一旦出现同样字样就误判 | `GXDLMSReader` 新增 `onFinish(value, error)` 回调；状态栏只显示状态，解析结果走 `onFinish` |
| U4 | **JSON 导入丢 `scaling`（量纲）**：`ImportEntry` 没有这个字段 | 补 `scaling`；同时 CSV 支持**可选的第 4/5 列（接口类、属性）**，与 JSON 口径对齐 |
| U5 | 请求数据 / OBIS **只有点了按钮才知道输入能不能用**（靠日志蹦一句"OBIS 无效"） | 两处都加实时提示（图标 + 字节数 / 段数），样式沿用密钥字段那一套 |
| U6 | 报文类型列会**整列空白** | `Store.log` 缺 `label` 参数 —— View 的 trace 回调是用 `LogEntry` **重建**一条再存进来的，不透传就丢了。已补 |
| U7 | 属性输入框宽 52pt，三位数就挤 | 放宽到 64pt |
| U8 | 文件头注释过时（`DLMSApp.swift` 仍写"设备管理 + 抄读 + 报表"，那些页面早已删除） | 更新 |

### 14.2 记录在案、本轮不改

- 日志上限 **2000** 而列表渲染 **200**：已用条数提示说明差别；若要"翻页回看更早"需另设计
- CSV 只认**逗号**分隔（不支持分号 / 制表符导出）
- `ObisImporter.isValid` 要求**恰好 6 段**，而编辑器 `ObisUtil.parse` 允许 ≤6 段并补 0 —— 两处规则不一致
- 操作对象（类 / 属性 / 请求数据）**未持久化**，App 重启回默认值
- 每次操作都新建 `GXDLMSReader`（含新 `DispatchQueue`），可复用
- 自动跟随会**打断**向上翻阅历史（当前靠"操作结束就没有新报文"来回避）；彻底解决需 iOS 17 的 `scrollPosition`，而部署目标是 iOS 16

---

## 15. 《代码审核报告》逐条核验与处置（v1.5）

对 `docs/代码审核报告.md` 的 16 项结论逐条到源码复核（**不照单全收**）。结论分三类：
**已修** / **报告有误或需修正理解** / **确认但转你决定**。

### 15.1 已修（本轮落地）

| 编号 | 核验结论 | 处置 |
|---|---|---|
| D1 | ✅ 真实。重发分支（`DLMSBridge.c` 原 106-112 行）确实没重置 `c->rx`，半截字节会和新响应拼接 | 重发前重置 `c->rx.size/position` 与 `reply->complete`，**与函数开头的"新请求重置"保持一致** |
| D2 | ✅ 真实。`fail` 只在失败时自增、成功路径从不归零 | 收到数据即 `fail = 0`，使阈值语义回到"连续失败" |
| D3 | ✅ 真实（C11 6.5.7p4 有符号左移溢出 UB；clang 实践正确但不可移植）。UINT32 分支本就用了无符号中间量，INT32 没跟上 | INT32/INT16 统一改无符号中间量 |
| D4 | ✅ 真实。且**可在 Swift 侧检出**：`replyValueString` 的 `outLen` 语义是"写入字节数(含 NUL)"，截断时 `n = cap-1` → `outLen == cap` | 缓冲 512 → **4096**（提为命名常量），并在截断时于结果末尾追加提示 |
| D6 | ✅ 真实。`conn = connection` 直接覆盖旧连接；失败/超时分支也不 cancel、handler 不清 | `connect` 开头 `conn?.cancel()`；失败路径清 `stateUpdateHandler` 再 `cancel` 并置空 `conn` |
| P1 | ✅ 真实，且比报告描述更严重：到达上限后是**每追加一条**都 O(n)（`removeFirst(1)` 每次前移 ~2000 元素） | 改为"超过高水位 2500 再一次性切回 2000"，把 O(n) 摊薄到每 500 条一次 |
| P2 | ✅ 真实（`Store` 是 `@MainActor`，`save` 同步写盘） | 写盘挪到**串行**队列 + **原子写**（串行保证快照顺序，原子避免写一半被读） |
| M1 | ✅ 真实。我已独立核实：`akekHex` 装入的是 `blockCipherKey`（GUEK），名实不符是活陷阱 | 参数改名 `blockCipherKeyHex / authenticationKeyHex / dedicatedKeyHex`（`.c` + `.h`） |
| M3 | ✅ 事实成立（依赖 NSString 自动释放） | 把"仅限同步调用；若交异步接口必须改 `withCString`"写进注释 |
| S2 | ✅ 真实（无上限全量读入） | 导入前查 `fileSize`，超 1 MB 拒绝并提示（新增 `ImporterError.tooLarge`） |

### 15.2 报告有误 / 需修正理解

- **D1 的修法建议有误**：报告称重发时应"**同步重置 `reply` 状态**"。但 `reply` 在 more-data 序列里是**跨帧复用**的（`dlmsReadDataBlock` 对每帧调一次 `dlmsSendFrame`，只重置 `complete`
  、不清 `data`）——照报告清掉 `reply` 会**丢掉前面几帧已解析的数据**。正确做法只重置接收缓冲与 `complete`。
- **M1 说"同步更新 `GXDLMSReader.swift` 调用处"是不必要的**：C 参数名不影响 Swift 的位置调用，实际无需改 Swift（已核实）。
- **D2 细节偏差**：`++fail > 3` 是**第 4 次**失败才中止（即允许 3 次重发），不是"3 次失败即中止"。
- **D5 的注释描述与代码不符**：`receive` 里注释写"取消挂起回调，避免残留"，但**代码没有任何取消动作**。
- **M3 部分不准确**：原注释已写明"仅在调用期间有效"，风险**已被记录**；且全部调用均为同步 → 并非未识别的缺陷。
- **S3（正面评价）准确** ✓：已核对 `replyValueString` 的 `memcpy(out, s, n)` 确实按 `cap-1` 截断并补 NUL，边界正确。

### 15.3 确认但转你决定（本轮未改）

| 编号 | 为什么没直接改 |
|---|---|
| **D5** 传输层预读缓冲 | 真实缺陷（超时后晚到字节**永久丢失**），但修法要改**收发关键路径**——这是当前唯一"在真表上跑通"的链路，我不想在未经你确认时动它。改法：completion 里无论是否超时都入队到持久缓冲，下次 `receive` 先消费队列 |
| **S1** 密钥入 Keychain | 真实（明文在 `config.json`，备份可导出），但改动面大（Codable 拆分 + Keychain 读写 + 迁移），且这是**自用调试台**。要不要做请你定 |
| **P3** `suffix(200)` 每次复制 | 事实成立但**收益有限**：可见集合本身每条都在变，缓存未必更优；≤200 行的 diff 开销可忽略。建议不动 |
| **M2** 报文类型启发式 | 已文档化（§8 + R20），且报告自己也说是"改进项、非缺陷"。精确化需 bridge 回传 `gxReplyData.command` |
| **M4** 魔数提取 / 扩展位置 | 风格问题，收益低、改动面广。本轮只把因 D4 顺带产生的输出缓冲提为常量 |
| **M5** ObisImporter 单测 | 真实缺口（含 `parseBare` 不处理 RFC4180 转义引号 `""`）。补测试有价值，但属新增交付，等你确认再排 |

### 15.4 验证方式

- **C 层（D1/D2/D3/M1）**：本地 `gcc -Wall` 全量编译 + 链接 + 跑 `Tests/CTests/test_dlms.c`
  → `LINK_EXIT=0`、`ALL PASS`、`DLMSBridge.c` **零告警**（且能过编译本身即证明改名无遗漏）。
- **Swift 层（D4/D6/P1/P2/M3/S2）**：本机无 Swift 工具链，只能靠 CI（`macOS` 模拟器编译 + Swift 单测）兜底。

---

## 16. 真表抄表失败 + 长帧交互 诊断与修复（2026-09-21）

> 本章按时间顺序保留**诊断过程**（含被证伪的假设 —— 留着是为了不再重犯）。
> （小节号按写作顺序追加，故 **16.4 排在 16.3 前面**，引用时按编号找即可。）
> **处置结果**：P1「抄表失败」= **HLS-GMAC + `信息加密=NONE`** 被库拒绝算 GMAC →
> 已按 §5.2 的"切开算/打包"时序修复，**现场真表已用 `NONE` 关联成功并抄表** ✓；
> P2「数据过长无法交互」= **R26（`bufAppend` 误用 `bb_insert`）** → 已根治 ✓；
> P3「地址编码」= **R25** → 已按输入字节数定宽 ✓。

现场：HDLC · 客户端 `01` · 通信地址 `0001` · 读 `1.0.1.8.0.255`。依据 4 张真机日志截图。

### 16.1 已定位的三个问题

**P1（根因范围已收窄）AARE 之后，HLS 应答一个字节都没发出去**

```
14:47:30.793  TX  SNRM  7E A0 07 03 03 93 8C 11 7E
14:47:31.239  RX  UA    7E A0 1E 03 03 73 40 CC 81 80 12 05 01 … 53 3B 7E
14:47:31.268  TX  AARQ  7E A0 58 03 03 10 F0 C0 E6 E6 00 60 4A A1 09 …
14:47:31.729  RX  AARE  7E A0 64 03 03 30 34 3A E6 E7 00 61 56 A1 09 …
14:47:31.959  RX  1D 00 7D 00 07 CB A0 7E      ← AARE 尾段（TCP 分段）
14:47:43.977  TX  DISC  7E A0 07 03 03 53 80 D7 7E   ← 中间 12 秒无任何 TX
14:47:55.994  建链失败: Data receive failed.
```

**逐字节核验（用长度自校验，不是靠肉眼扫）**：

| 帧 | 校验 | 结论 |
|---|---|---|
| **SNRM** | 内容 `03 03 93 8C 11` = 5，长度域 `07` = 5+2 ✓ | 地址 `03 03` = 服务端 0x0001 + 客户端 0x0001 ✓（7bit 编码 `(1<<1)\|1 = 0x03`）**正确** |
| **AARQ** | `60 4A` = 74；`A1 09`+`A6 0A`+`8A 02`+`8B 07`+`AC 12`+`BE 10` 各级相加 = **74 严丝合缝** ✓ | 结构完全合法 |
| AARQ 机制 | `8B 07 60 85 74 05 08 02 **05**` | **= HIGH_GMAC(5)，与配置一致** ✓ |
| **AARE** | `61 56` = 86；`A1 09`+`A2 03`+`A3 05`+`A4 0A`+`88 02`+`89 07`+`AA 12`+`BE 10` = **86 ✓** | 完整、合法 |
| AARE 诊断 | `A3 05 A1 03 02 01 0E` = **14 = authentication-required** | 表要求走 HLS 挑战应答 |
| AARE 服务器标题 | `A4 0A 04 08 48 58 45 03 00 00 14 88` | `48 58 45 03 00 00 14 88` |
| AARE 服务器挑战 | `AA 12 80 10 35 FC 74 0C AC 03 8F C6 61 39 4C E0 03 AB 09 EC` | 16 字节 |

**P1 根因已确定（2026-09-21 现场复现）：「认证=HLS-GMAC + 信息加密=NONE」这个组合 Gurux 执行不了**

加了步骤级诊断后，现场报错直接指向了位置：

```
失败 · 建链失败（步骤 5 · HLS 应答生成）：Invalid parameter.
```

`步骤 5` = `cl_getApplicationAssociationRequest` **在生成阶段就返回了 `INVALID_PARAMETER`**，
请求一个字节都没发出去。

追到确切代码 —— `cip_encrypt`（`ciphering.c:680-686`）：

```c
    unsigned char keySize = settings->suite == DLMS_SECURITY_SUITE_V2 ? 32 : 16;
    if (settings->security == DLMS_SECURITY_NONE ||                  // ← 就是这一条
        bb_available(&settings->authenticationKey) != keySize)
    {
        //Invalid system title.
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
```

HLS-GMAC 算挑战应答时会走 `dlms_secure` → `cip_encrypt`（`dlms.c:6676`），
而 `settings->security == DLMS_SECURITY_NONE` 直接被拒 ✗。
**配置里「信息加密」是 `NONE`，但 HLS-GMAC 需要 `security != NONE`。**

> DLMS 语义上，HLS-GMAC 配「**仅认证**」（`DLMS_SECURITY_AUTHENTICATION = 0x10`）才是对的 ——
> 它只认证、**不加密报文**；而 `NONE` 表示"完全没开安全"，Gurux 因此拒绝算 GMAC。

**修复方向**（**已由现场逐项实测，结果如下**）：

| 信息加密 | 实测结果 | 说明 |
|---|---|---|
| `NONE` (0x00) | ✗ 读不了 | 已定因：`cip_encrypt`（`ciphering.c:681`）拒绝 `security == NONE` |
| `仅认证` (0x10) | ✗ 读不了 | 非 NONE 却仍失败 → 还有第二道与"加密位"相关的关卡（**未定死**） |
| `加密` (0x20) | ✓ **正常** | 带加密位 |
| `认证加密` (0x30) | ✓ **正常** | 带加密位；HLS-GMAC 的**标准**组合 |

**规律（据最终报文结论，见 §16.4）**：表要的是**不加密的上下文 `…08 01 01`** ✓，
即界面上的 `信息加密 = NONE` ✓；而 C 库在 `security == NONE` 时**拒绝算 GMAC** ✗（`ciphering.c:681`），
把它设成 `仅认证(0x10)` 又会让库认为"已加密"、上下文变成 `…08 01 03` ✗ → 表直接拒绝 ✗。
**两条路都堵死** —— 需要在库里打一行补丁（见 §16.4）。

**⇒ 现状下唯一能跑的是 `加密(0x20)` / `认证加密(0x30)`**（现场实测可读表 ✓），
但它们与这台表"只认不加密上下文"的事实相冲突（hmm — 实测能读表，说明该表也支持 `…01 03` 的场合存在）；
**推荐修好之后再统一用 `NONE`** ✓，与 .NET 客户端行为一致 ✓

**待确认的代码修正**：
1. 默认值：认证 ∈ {HLS-GMAC, SHA256, ECDSA} 时，信息加密默认取 **认证加密(0x30)** 而非 `NONE`
   （§2 现默认 `NONE`，与 HLS-GMAC 组合**根本不可用** —— 这是**默认值本身的缺陷**）
2. UI 校验：该组合为 `NONE` 或 `仅认证` 时**明确提示**（实测这两种都读不了），别让人反复踩
3. 顺带：`authenticationKey`(GUAK) 必须**恰好 16 字节**，长度不对会报同一个错 —— 也要在 UI 拦

> **踩坑记录（值得记）**：我起初两次靠"读截图里的十六进制"下结论，**都读错了**
> （先说机制 OID 不一致，后又说不清 AARQ 内容）。
> 教训：**二进制报文必须用长度域自校验**（`60 4A`=74、`61 56`=86 都能逐级相加验算），
> 或者**直接把本地代码实际发出的字节打出来**——都比肉眼看图可靠。
> 最终定位靠的是"步骤级诊断（定位到步骤 5）+ 现场逐项改配置实测"，而不是读图。

---

**⚠️ 更正**（早前误判，已撤回）：本报告曾称"机制 OID 不一致（`02 02` vs `02 05`）"——
**那是读图错误**。两侧机制都是 `…02 05` ✓。同批被撤回的还有"`8B 07` 后有孤立字节"的判断（长度自校验证明没有）。

**真正确凿的结论**：
1. 地址、SNRM/UA、AARQ、AARE **全部正确**，表也正常应答并进入 HLS 挑战阶段 ✓
2. **AARE 之后 12 秒内没有任何 TX** ✗ —— 即 `DLMSBridge.c:407-427` 里
   `cl_getApplicationAssociationRequest` → `dlmsReadDataBlock` 那一步**没有发出任何请求** ✗
3. **12 秒 = 4 × 3 秒**，正好是 `dlmsSendFrame` 的 `++fail > 3` + recv 超时 3s ✓
   → 说明**卡在 recv 上**，不是"发出去被拒"
4. 之后 DISC 又花 12 秒（同样 4×3s）→ 最终报 `Data receive failed` ✓

**为什么还不能定死**：`dlmsSendFrame` 的 trace 在**发送成功之后**才调用
（`DLMSBridge.c:82-89`）—— 所以"发送本身失败"这条路径**在日志里不留任何痕迹** ✗。
即：无法只用报文区分「请求没生成出来」和「生成出来了但 send 失败」。

**顺带从报文里发现的两件事**：
- **报文类型列不可信**：AARQ 被标成了 `Get-Request` ✗ —— `classify` 扫前 16 字节时，
  第 8 个字节 HCS 的 `C0` 先命中，而真正的 APDU `0x60` 在第 12 字节 ✗。
  这是 R20（启发式误标）的**实测复现**，看日志时别信类型列。
- **长帧确实被 TCP 分段**：AARE 104 字节分成 2 段（94 + 尾段）到达 ✓ 印证 P2。

**P2 长帧被 TCP 分段 + 超时丢弃晚到字节**

日志里出现 `RX 07`（1 字节）、`RX 1D 00 7D 00 07 CB A0 7E`（8 字节）这类**碎片**：
AARE 约 104 字节，被 TCP 拆成多段到达。
而当前接收模型是"每次 `recv` 一个超时"，**超时后晚到的字节被永久丢弃**
（`GXDLMSTransport.receive` 的 `result` 是局部变量，回调晚到写进去也没人读）
—— 这正是《代码审核报告》的 **D5**，当时标为"确认但转用户决定、未改"。
→ 用户提的「**字符间超时断帧**」就是对症的解法。

**P3 HDLC 地址：能编 4 字节，但语义口径与用户约定不一致**

Gurux **已经**实现了 bit0 扩展位 + 7bit/字节（`dlms.c:2420-2445`）：

```c
if (value < 0x80)            { address = value << 1 | 1;                      size = 1; }
else if (value < 0x4000)     { address = (v&0x3F80)<<2 | (v&0x7F)<<1 | 1;     size = 2; }
else if (value < 0x10000000) { address = 4 字节形式;                          size = 4; }
```

**长度按数值大小自动选** → `0x00013FFF` 会走 4 字节分支 ✓ **机制本身没问题**。
问题在**拆分口径**：`dlms_getServerAddress`（`dlms.c:2305`）按 **14 位**拆
（`logical = v >> 14`，`physical = v & 0x3FFF`），
而用户口径是 **16 位**拆（`00013FFF` = 逻辑 `0001` + 物理 `3FFF`，即 `logical<<16 | physical`）
→ 同一个值两边解释不同（Gurux 会算出 logical=0x4F）✗

> ⚠️ 另外：**当前配置里通信地址是 `0001`（1 字节）**，而且表正常回了 UA / 地址 `03 03`
> → 说明**地址不是本次抄表失败的直接原因**。要上 4 字节地址时才需要对口径。

### 16.2 地址口径（**已由用户澄清 → 与本方案一致**）

用户口径（2026-09-21）：**`00013FFF` 是编码前的值**，编码后逻辑/物理**各 14 位**，
**默认 4 字节**，可设 2 / 1 字节。

- 4 字节 = 4×7bit = 28 位 = **逻辑 14 + 物理 14** ✓
- 这与 Gurux 的 `dlms_getServerAddress`（`logical = v>>14` / `physical = v & 0x3FFF`）**完全吻合** ✓
- 因此要喂给 `cl_init` 的值 = `logical << 14 | physical`。
  默认 `00013FFF` → 逻辑 `0x0001` + 物理 `0x3FFF` → **`0x7FFF`** → 编码出 4 字节 `00 02 FE FF`
  （末字节 `0xFF` 的 bit0=1 → 地址域结束 ✓）
- ⚠️ 之前是把 `00013FFF` **原样**喂进去的 → Gurux 会按 `v>>14` 解出逻辑 `0x4F`，地址域全错。

> 遗留限制：Gurux **没有**显式宽度参数，宽度由数值量级推断
> （`<0x80`→1B、`<0x4000`→2B、否则 4B）。所以「选 4 字节但逻辑地址为 0」时实际只会出 2 字节。
> UI 因此额外显示**编码后的真实字节**与**实际生效宽度**，不一致时标黄提示。

### 16.4 成功报文对照（用户提供的现场抓包，从**表侧**看）

方向说明：`RX` = 表收到（客户端发的），`TX` = 表发出的 ✓
（证据：`Client Connected.` 紧跟在 AARE 之后，且 SNRM 是"表→客户端"方向）

**唯一关键差异 = 应用上下文的加密位**：

| OID | 含义 | 谁在用 |
|---|---|---|
| `60 85 74 05 08 01 01` | LN 引用、**不加密** | 我方（失败）✗ |
| `60 85 74 05 08 01 03` | LN 引用、**带加密** | 成功报文 ✓ |

完整成功链：
```
表收 SNRM(93) → 表发 UA(73)
表收 AARQ     → 表发 AARE(61 69；diagnostic=0E authentication-required)
表收 HLS 应答 → CB 31 30 00 00 00 02 …   ← CB = glo-action（**加密的** ACTION 请求）
                "Client Connected."
表收 GET(C8…) → 表发 GET 应答 → … → DISC(53) → UA
```

**`CB` 是关键旁证**：`C8~CB` 是 glo-（加密）族的 get/set/event/action，
说明**成功路径上 HLS 挑战应答是按"加密"方式发的**，而非"仅认证"那种明文 `C3` ✓

**结论（按现场报文，最终版）**：

| 界面设置 | 应用上下文 | 库能否算 GMAC | 表的反应 |
|---|---|---|---|
| `NONE` (0x00) | `…08 01 01` ✓ **表要的** | **不能** ✗ `cip_encrypt` 拒 `security == NONE` | 接受 AARQ（result 0 + 要求认证）✓ 但**等不到 HLS 应答** ✗ |
| `仅认证` (0x10) | `…08 01 03` ✗ 表拒绝 | 能 ✓（库把它当"已加密"✗） | **永久拒绝** `result 1` ✗ |

**⇒ 两条路都堵死** ✗ —— 而 `.NET` 客户端（GXDLMSDirector）用 `NONE` + `…01 01` + 明文 `C3` + `SC=0x10` + 12B GMAC **跑得通** ✓
→ 说明 **`.NET` 库没有 `cip_encrypt` 那道检查**，是 **C 库实现层的差异** ✓（不是协议问题 ✓）

**建议修法（待批准）**：给 `ciphering.c:681` 打一行补丁 —— 该校验应看**显式传入的 `security` 参数**
（HLS-GMAC 走 `dlms_secure` 时传的就是 `DLMS_SECURITY_AUTHENTICATION` ✓），而不是看结构体字段 ✗。
这样 `NONE` 时：上下文仍是 `…01 01` ✓（`cipher.security` 未变 ✓）+ GMAC 能算 ✓ = 与 .NET 成功报文一致 ✓

**已撤回的错误结论**（本线程反复过，留档避免再犯）：
- ~~机制 OID 不一致~~ ✗ 两边都是 `…02 05` ✓
- ~~必须带加密位（0x20/0x30 才通）~~ ✗ 表恰恰只认不加密的 `…01 01` ✓
- ~~SystemTitle 该填 `00000000`~~ ✗ `ABC12345` 也行 ✓
- ~~地址/SystemTitle 是拒绝原因~~ ✗ 改对后表接受 AARQ ✓，真正的卡点在 HLS 应答生成 ✓

顺带确认：机制两边都是 `…02 05` ✓（早前"机制不一致"确系读图错误）；
成功这台的地址是 客户端 `00 02 FE FF`（4 字节 = 逻辑 1 + 物理 0x3FFF ✓ 即 `00013FFF`）+ 服务端 `03`（0x0001）✓

---

| 步骤 | 状态 |
|---|---|
| ① 可观测性（步骤码 + 区分"发送失败"） | ✅ **已实现**（见下） |
| ② 修 HLS 应答 | ✅ **已实现**（v1.6）—— 根因是 `cip_encrypt` 的守卫拒绝 `security == NONE`；修法见 **§5.2**，真表实测结果见 **§7.1**（`信息加密 = NONE` 已关联成功并抄表） |
| ③ 传输层预读缓冲 + 字符间超时断帧 | ✅ **已实现**（= 报告 D5） |
| ④ 地址口径对齐 + **宽度按输入字节数自动判定**（v1.6 重做，取代原"手动宽度选择器"） | ✅ 已实现（见 R25） |

### 16.3 实施进度

**① 可观测性——为什么必须做**：
`dlmsSendFrame` 的 trace 在**发送成功之后**才调用（`DLMSBridge.c` 原 82-89 行），
所以"send 失败"这条路径**在报文日志里一个字节都不留**。只凭报文无法区分：
(a) 请求没生成出来 (b) 生成出来了但 send 失败 (c) 发出去了但 recv 超时。

实现：
- `dlmsCtx` 增加两个诊断字段（`dlmsCtx` 在公开头里是 **opaque**，加字段不影响 ABI/Swift）
  - `lastStep` —— `dlms_initialize` 的步骤号（`DLMS_STEP_*`），失败时停在哪一步
  - `sendFailed` —— 最近一次 `dlmsSendFrame` 的 send 是否失败
- 新增三个查询接口（`DLMSCore.h`）：`dlms_lastStep` / `dlms_sendFailed` / `dlms_step_name`
- 步骤粒度刻意做到"生成 vs 收发"两级：
  `SNRM请求生成 / SNRM·UA收发 / AARQ生成 / AARQ·AARE收发 / HLS应答生成 / HLS应答收发`
  —— 生成失败 ⇒ 停在 `*_请求生成`；收发失败 ⇒ 停在 `*_收发`，再看 `sendFailed` 区分发/收
- Swift 侧报错变成：
  `建链失败（步骤 5 · HLS 应答生成）：<错误码文本>`
  若 send 失败会追加"，发送失败（日志里不会有这帧）"

**③ 传输层预读缓冲**：
`GXDLMSTransport` 增加带锁的 `pending: Data`；`receive` 的 completion **无论是否超时都先入队**，
`receive` 开头先消费队列。这样"超时后晚到的字节"不再永久丢失（原实现丢在已失效的局部变量里）。

> ⚠️ **v1.7 补正**：这版实现有**内存安全问题**（**R29**，审核报告 v2 的 N1）——
> `receive` 两处排空 `pending` 都**无视 `max`**，而回调 `copyBytes` 是无边界检查写入、
> C 侧缓冲又是固定 `tmp[2048]` 栈数组 → **栈破坏**。
> 已修为 `takePending(buf:max:)`（按 `max` 截断、余量留在 pending）+ 回调 `min(cap, count)` 兜底 +
> `pendingLimit = 256KB`。**"预读"的语义本就是"取走本次要用的、余量留下"**，而不是整份排空。
`connect()` / `cancel()` 会清空缓冲，避免新会话继承残留。

---

## 17. 本地拟真台（v1.7，**本轮最有价值的工程投入**）

### 17.1 动机

历史事实：**所有真 bug 都在「协议 + 传输」这条链上**，UI 类问题（日志被挤成竖条）看一眼截图就够了、
不值得自动化。但本机是 Windows（**没有 Swift 工具链、没有 iOS 模拟器**），而
「回放测试一次给全帧」永远测不出**传输层**的问题 —— 于是形成了固定的循环：

> 只有真机能发现的 bug → 跑一趟现场 → 改 → 再跑一趟现场

拟真台把这个循环压成**本机 50 秒可复现**。

### 17.2 组成

| 文件 | 作用 |
|---|---|
| `tools/sock_compat.h` | Winsock / POSIX 差异收敛 + **带超时的可读等待**（对齐 App 侧 `receive` 的超时语义） |
| **`tools/mock_meter.c`** | **本地模拟表**：按请求类型应答，且能制造坏链路 —— `--frag N` 分片、`--delay-ms` 间隔、`--silent-after N` 静默 |
| **`Tests/CTests/local_e2e.c`** | **`DLMSBridge` + 真实 TCP** 跑完整会话：initialize → read → write → method → disconnect |
| `Tests/CTests/run.sh` | 编排四步（见 §10.3） |

- 只绑 **loopback**，Windows 下**不弹防火墙** ✓
- 真 socket 的收包分段是**可控**的：服务端分 3 段发，客户端确实收 `2 bytes / 2 bytes`
  —— 这正是"长帧被 TCP 拆开"的复现手段 ✓
- 客户端连接**内部重试**（不用 `sleep 1` 等服务端起监听）→ 避免 CI 上偶发假失败。

### 17.3 覆盖率（实测，`gcov`）

| | 项目 `.c` 总覆盖率 | 桥接层 `DLMSBridge.c` | 0% 文件数 |
|---|---|---|---|
| 仅默认闸门 | 2.58% | 34.83% | 26 |
| \+ 协议回放 | 8.45% | 56.31% | 18 |
| **\+ 端到端（拟真台）** | **9.98%** | **70.87%** | 16 |

**此前"从未被调用"的四个函数全部被拉起**：

```
dlms_read       0% → 92.9%      dlms_write   0% → 88.2%
dlms_method     0% → 85.7%      dlms_disconnect 0% → 80%
dlms_initialize 0% → 85%        ciphering.c  8.41% → 48.60%    apdu.c 0% → 33.29%
```

口径提醒：gcov 统计的是**可执行行**（`DLMSBridge.c` 约 511 行），不是物理行数（约 1235 行）。

### 17.4 它抓到的第一个真 bug

**R26（`bb_insert` 误用）** 就是靠它定位的 —— 而这个问题**在桩回放里永远不出现**（桩一次给全帧 →
`size == 0` → 走 `bb_set` 分支，碰巧正确）。用 `--frag` 跑矩阵：

| frag | 修复前 | 修复后（每档跑 2 次） |
|---|---|---|
| 8 / 16 / 16+5ms / 32 / 32+5ms | **step=4 ✗** 卡在 AARQ/AARE，send 20~66、超时 19~65 | **step=6 ✓ 2 send / 0 超时** |
| 64 | step=4~6 抖动 | **step=6 ✓ 2 send** |
| 96（= 整帧长度） | step=6 ✓ | step=6 ✓ |

"只有整帧能通"这个形状 + `dlms_rxSize` 打印出 `size` 卡在首片长度 → 直接锁到 `bufAppend`。

### 17.5 已知限制

- **UI 渲染**（SwiftUI 视图/排版）本机**永远测不了** ✗ —— 但 bug 密度最低。
- **Swift 传输层**（`GXDLMSTransport`）跑不了，但**行为能复现**（分段/超时是"字节流怎么切"的问题，
  与用什么语言写无关）。纯逻辑部分（如 `takePending`）已用 Swift 单测覆盖。
- 分片场景在 **R26 修复后**已从"已知退化/弱断言"升为**强断言**。

---

## 18. 《代码审核报告 v2》核对与处置（2026-09-24）

对 `docs/代码审核报告-v2.md` **逐条 grep/读原文核实**（不采信报告的自述）。
结论：**绝大部分属实，1 条判错、1 条低估**。

### 18.1 核实属实（并已处置）

- v1 对照里判"已修"的 **D1 / D2 / D3 / D4 / D5 / D6 / P1 / P2 / M1** 逐条对上了源 ✓
- 新发现 **N1 / N2 / N3 / N4 / N5** 的事实描述**全部属实** ✓，处置见 **R29** 与下表：

| 编号 | 处置 |
|---|---|
| **N1** 栈溢出 | **已修 ✓**（`a71adba`）—— 见 R29。⚠️ 报告的修法两条都对，但**低估了严重性**：它说"连续两次超时 → 4096"，实际因 completion 无法取消 + 可重试 256 轮，可达 `256×2048` |
| **N2** `pending` 无上限 | **已修 ✓** —— `pendingLimit = 256KB`，超限丢最旧 |
| **N3** `parseEntries` 裁剪口径不一致 | **已修 ✓** —— 改用与 `logs` 相同的高水位裁剪（`parseHighWater = 250`） |
| **N4** 死代码 | **已修 ✓** —— 删除 `private enum Kind` 与 `check(_:step:)`（grep 确认两者都只有定义、无调用） |
| **N5** 静默吞错 | **已修 ✓** —— `Store.load` 区分「文件不存在」（首次运行，静默）与「**存在但解析失败**」（记 warn）。写盘失败仍静默，已记入 §13.2 |

### 18.2 ⚠️ 报告判错一条：S2

报告把 **S2「导入文件无大小上限」标为「❌ 未改」** —— **实际早已修**：
`ObisImporter.swift:14` `maxImportBytes = 1024*1024`、`:19` 超限即 `throw ImporterError.tooLarge`、
`:139/144` 有对应错误文案。

> **方法论**：对"未改 / 不存在"这类**否定性结论**要额外警惕 ——
> 它只能证明"没找到"，不能证明"没有"。

### 18.3 报告漏掉的

- **N1 的放大器**（挂起的 completion 累积）—— 见 R29 的说明。
- **`selectObis` 用原文匹配清单**（R30）—— 同批修掉。

### 18.4 未纳入本轮

报告里的 M2（trace 回传 command）、M5（ObisImporter 单测）、S1（Keychain）、
mock Set-Response 保真度 —— 属"新增能力/加固"，非"已核实的问题"，留在 §13.2 待排期。

---

*本方案为最终实现契约。**里程碑**：CI 三道闸门全绿（C 单测 / 模拟器编译 / Swift 单测）→ 出未签名 IPA → Windows 用 Sideloadly 真机侧载 → **与真表完成 HLS-GMAC 关联 + 抄表（`信息加密 = NONE`）** ✓*
*下一步按 §1 推进：P2（GUAK/GUEK 对真表验证密钥映射 · IC 同步 · Association View 列表 · 明文 PDU trace），并核销 §12 中 R20–R25。*