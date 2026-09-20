# DLMS 抄表调试台 iOS —— 详细方案（v1.4）

> 状态：**App 已在真机侧载运行**（CI 三道闸门全绿 → 出未签名 IPA → Windows 用 Sideloadly + 免费 Apple ID 装机成功）。
> v1.4 变更（UI 交互细化 + 本轮审核发现）：
> ⑨ §3.1 **类改为输入框**（不用下拉：COSEM 类实际可能非常多，下拉无法穷举），支持 10/16 进制自动识别；`ObisItem.objectClass` 由受限枚举改为**任意 Int**；
> ⑩ 新增 **§3.2 地址输入规则**：HDLC 客户端「非自定义只读、仅自定义可输入、1 字节 = 2 位 hex、可省前导 0」；通信地址「4/2/1 字节、默认 4 字节 `00013FFF`、**不省前导 0**」；
> ⑪ 新增 **§3.3 OBIS 添加字段顺序**：名称 → 接口类 → 逻辑名 → 属性 → 单位（可选）→ 量纲（可选）；
> ⑫ §8 报文日志改为 **4 列固定宽度**（时间 | TX·RX | 报文类型 | HEX）。类型与 HEX **必须分列**——早前把类型拼进 HEX 串中间加两个空格，类型名长度不一（`AARQ` 4 字符 vs `Get-Response` 12 字符）会把 HEX 挤错位，这正是"TX 后两个空格导致上下不对齐"的根因；
> ⑬ **修正报文类型表**：HDLC 控制字段以 `enums.h` 为准 —— `SNRM=0x93`、`DISC=0x53`（原误写 `0x35`/`0x40`，导致这两个报文**永远不会被标注**，且可能撞地址字段产生误标）；
> ⑭ 整数越界由 **trap 崩溃** 改为 `clamping` 夹取（`UInt16(clamping:)`/`UInt8(clamping:)`）：类填 `99999`、属性填 `300`、端口填 `99999` 不再闪退；
> ⑮ 风险登记新增 **R20–R24**；
> v1.3 变更（密钥可配置化，用户口径）：
> ⑧ 设置页密钥区改为 **GUAK / GUEK 两条独立输入**（取代原「aKEK/EM 主密钥」单条）；
>    **GUAK → `settings->cipher.authenticationKey`**，**GUEK → `settings->cipher.blockCipherKey`**；
>    两者默认均为 **16 字节全 0（AES-128）**，留空同样按全 0 处理；**MK / GBEK 暂不提供**（`dedicatedKey` 槽位预留）；
>    客户端 SystemTitle 默认改为 **`4142433031323334`（ASCII "ABC01234"）**，留空即用该默认；
>    hex 输入在交给 C 之前统一归一化（去空白与 `:` `-` 并转大写）；`ConnectionConfig` 解码改为「缺键回退默认」，
>    旧 `config.json` 不再因字段增删而整份失效。风险登记新增 **R19**。
> v1.2 变更（原《审查与改进》已并入本文件，已对 vendored 源码核实）：
> ① 新增 **P0 修桥**（现有 `DLMSBridge.c` 3 处 bug：接收缓冲覆盖、512B 过小、Wrapper 误发 SNRM、断链缺 RLRQ、超时未参数化）；
> ② **修正 `cl_writeLN` 签名**（第5参 `dlmsVARIANT*`、第6参 `byteArray`，写走 `byteArray=1`+`bb_addHexString`）；
> ③ **修正 HLS challenge** 为 `cl_getApplicationAssociationRequest/parse...Response`；
> ④ **修正 SystemTitle 方向**：客户端→`cipher.systemTitle`、服务器→`sourceSystemTitle`(AARE回填)，此前 v1.1 写反；
> ⑤ **修正 hex→variant tag 表**（INT8=0x0F/INT16=0x10/UINT8=0x11/UINT16=0x12/INT32=5/UINT32=6）；
> ⑥ 新增风险 R10–R18（帧覆盖/R11 缓冲/R12 HLS/R13 客户端ST/R14 IC/R15 cip_init IC/R16 地址溢出/R17 methodLN bug/R18 wrapper SNRM）；
> ⑦ E4 决议：**认证方式与信息加密为两个独立下拉**；认证默认 **HLS-GMAC**（审计"认证默认 NONE"**未采纳**），信息加密默认 **NONE**；认证=HLS 时客户端 SystemTitle 常显必填（R13）。
> 性质：自用现场抄表 · 单表快速抄 · 近 GXDLMSDirector / 桌面 Test-Client 形态 · 仅 TCP
> 协议层：vendor 本地 `D:\project\personal\dlms\GuruxDLMS.c`（Gurux.DLMS.c，GPLv2，自用无分发风险）

---

## 1. 交付节奏：三阶段（控险、先跑通）

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **P0 修桥** | 修现有桥接 bug：接收缓冲跨 recv 追加(`bb_insert`)并按 `maxPduSize+50` 动态分配 · Wrapper 不发 SNRM · 断链先 RLRQ(`releaseRequest2(sec!=NONE)`)再 DISC · 超时参数化(连接5s/recv取配置) | 现有 App 在 HDLC/NONE 下稳定读通大 PDU 不丢帧 |
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
| 解析使能 | 开 |
| 建链/断链 | 一键操作 → 一律自动建链→执行→自动断链（无自动会话开关） |
| 重复点按钮 | 串行队列 + busy 禁用按钮，不做硬中断（R8） |

> **认证方式 与 信息加密 是两个独立的、互不影响的下拉**：
> 认证方式默认 **HLS-GMAC**，信息加密默认 **NONE**。审计建议"认证默认 NONE"**未采纳**，按用户要求保留认证默认 HLS-GMAC（E4 决议 ⑦）。
> 依赖约束：认证=HLS-GMAC 时，客户端 SystemTitle 必须在 AARQ 前设置 → 该字段常显、选 HLS 时必填（R13）。

---

## 3. UI（单屏纵向，顺序＝配→选→抄→看）

```
┌ 连接参数（可折叠）────────────────────┐
│ 传输：IP · 端口 · 接收超时(ms)           │
│ 地址（随封装联动）：                     │
│   HDLC : 客户端[预设下拉+自定义hex] · 通信地址(服务器) hex（如 00013FFF）│
│   Wrapper: 源(默认0001) · 目标(默认0001，逻辑地址固定) │
│ 应用：认证 NONE/LLS/HLS-GMAC            │
│       信息加密 NONE/仅加密/仅认证/认证加密(GUEK)   │
│       LLS密码 · GUAK(16B) · GUEK(16B) · 客户端SystemTitle │
│ 其它：日志级别 · 解析使能(开关) · 手动连/断 · 更多设置 │
├ 操作对象 ───────────────────────────┤
│ 类[×] · OBIS[下拉全局清单/手输] · 属性/方法[×]    │
│ 请求数据(HEX，写/执行用) · 自动会话控制(开关)      │
├ 操作： [读] [写] [执行] ──────────────┤
├ 数据解析： 原始HEX → 类型/长度/值（受解析使能 · 带清空）│
├ 报文日志：时间戳·Send/Receive·Original:注解·完整HEX·TX红/RX蓝/信息绿/服务橙·级别过滤 │
└──────────────────────────────────────┘
```

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
| **客户端地址** | 预设下拉（管理 `0x01` / 公共 `0x10` / 只读 `0x02` / 预链接 `0x66` / 自定义）。**选中预设时该值只读显示、不可输入**；只有选「自定义」才出现可编辑输入框。客户端地址是 **1 字节** → **2 位 hex**（不是 4 位），**可省略前导 0**（填 `1` → `01`）。 |
| **通信地址(服务器)** | 允许 **1 / 2 / 4 字节**；默认 **4 字节 `00013FFF`**。**不允许省略前导 0**：固定 `%08X` 显示（填 `1` → 显示 `00000001`），免得"宽度"信息被视觉抹掉。 |
| Wrapper 源 / 目标 | 各 4 位 hex，默认 `0001` / `0001`。 |

> ⚠️ **1/2 字节的区分由数值大小决定**：Gurux 按 `serverAddress` 的量级自动推断帧内地址字节数，`dlmssettings.h` 里**没有** `addressSize` 字段（已核实）。
> 所以**数值相同的 1 字节与 2 字节写法无法区分**（`01` 与 `0001` 都等于 `0x01`）。若某台表要求 2 字节地址字段而值恰为 `0x0001`，当前模型表达不了 —— 见 R16。

### 3.3 添加 / 编辑 OBIS 的字段顺序

表单自上而下**固定**为：

1. **名称**
2. **接口类**（IC，输入框，10/16 进制自动识别）
3. **逻辑名 OBIS**
4. **属性 / 方法**
5. 单位（可选）
6. 量纲 / 倍率（可选）

> 顺序即录入习惯：先认"这是什么" → 再定位"到哪里取" → 最后补"怎么换算"。
> 量纲单独成字段（`ObisItem.scaling`），便于后续把 `value × 10^scaler` 的换算做进展示层。
> ⚠️ 接口类输入框的占位文字写的是 `Data=1`，但该串含 `=` **无法被解析**（保存时会静默保留原值）—— 见 R24。

---

## 4. 数据模型（JSON 文件存储）

- **`ConnectionConfig`**：IP、端口、超时、封装(HDLC/Wrapper)、客户端地址(预设+自定义)、通信地址/源/目标、认证、信息加密、三密钥(LLS密码/GUAK/GUEK)、客户端 SystemTitle、解析使能 —— **记住上次**。
  - 解码为**容错式**：`init(from:)` 逐项「缺键/类型不符 → 回退默认值」，字段增删不会让旧 `config.json` 整体失效。**改字段必须同步该 init**。
- **`AddressPreset`**：`管理=1 / 公共=0x10 / 只读=2 / 预链接=0x66 / 自定义`（HDLC 客户端下拉；数值可改）。
- **`ObisLibrary`**：全局 OBIS 清单（下拉选、手输、导入、预置）。
- **`recentObis`**：最近读过的 OBIS，填充下拉；**不存数据值**。

枚举映射（已锁定）：
- 封装：`HDLC=0` / `Wrapper=1`
- 认证：`NONE=0` / `LLS(LOW)=1` / `HLS-GMAC(HIGH_GMAC)=5`
- 对象类：`Data=1` / `Register=3` / `ExtendedRegister=4` / `ProfileGeneric=7`

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

---

## 6. 地址模型（已由源码证实）

- 客户端=`clientAddress`；通信地址=`serverAddress`；两模式同样喂 `cl_init`，区别仅在帧内编码：
  - **Wrapper**：源/目标**直接用**（默认 `0001` / `0001`）。
  - **HDLC**：客户端为 clientAddress（预设下拉）；通信地址为服务器地址（hex，`00013FFF` 型，即**逻辑+物理合成值**）；帧内由 Gurux 按 serverAddress 大小**自动推断地址字节数**，无需外部 `addressSize`。
- 合成便捷项（P3）：`cl_getServerAddress(logical, physical, size)` = 小址 `logical<<7|physical` / 大址 `logical<<14|physical`，生成 `通信地址`。
- `clientAddress:uint16_t`、`serverAddress:uint32_t`（dlmssettings.h 已确认，无 addressSize 字段）。

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
    - 解析面板：左 `解析使能` 开关，右清空 → `store.parsedText = ""`
    - 报文面板：左 **条数**（`共 N 条`；N>200 时标 `· 显示最近 200`），右清空 → `store.clearLogs()`
    - 条数必须显示：`Store` 最多留 **2000** 条，而列表只渲染 **最近 200** 条 —— 不标出来用户会以为"清空"删掉的和屏幕上的不是同一批。
    - 清空按钮在内容为空时 `disabled`（灰掉），避免误点后莫名无反馈。
    - 做成同一套布局是为了切面板时**视线不用重新找按钮**。（此前报文面板**根本没有**清空入口，`Store.clearLogs()` 实现了却从未被调用。）
  - 报文的 `>>>` 语义注解（R4）仍留 P3 加深。
- **数据解析**：解析使能开时，把 `var_toString` 结果 + ASN.1 `Tag/长度/值` 拆解显示；窗口带「清空」。

---

## 9. 桥接 C 增量（相对现有 `DLMSBridge.c`）

`dlms_initialize`(按 interfaceType 分支 + HLS challenge,见 §5.2) · `dlms_read` · **`dlms_write`**(hex→`bb_addHexString`, `byteArray=1`) · **`dlms_method`**(hex→variant) · `dlms_set_security(DLMS_SECURITY, 密钥)` · `dlms_set_clientSystemTitle`(→`cipher.systemTitle`, AARQ 前) · `dlms_get/set_invocationCounter`(→`cipher.invocationCounter`, P2) · `dlms_disconnect`(先 RLRQ 再 DISC) · `dlms_set_trace` · 地址预设即预填数值 · 建链后**捕获服务器 SystemTitle**(AARE→`sourceSystemTitle`)随数据/日志显示。

- **`dlms_set_timeout` 删除**：vendor 无此符号，超时由 **Swift socket 层**实现（连接超时 5s；recv 取 `ConnectionConfig.recvTimeoutMs` 默认 3000；整体操作/TM 分隔）。
- **P0 修桥（首要）**：接收缓冲改为 **ctx 上跨 recv 持久化的累积缓冲** + `bb_insert` **追加**（当前 `bb_set` 是覆盖，大 PDU 丢帧）；容量按 `maxPduSize + 50` 动态分配（非 512B 固定）；Wrapper 不发 SNRM；断链先 `cl_releaseRequest2(sec!=NONE)` 再 `cl_disconnectRequest`。
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
| R10 | 接收帧跨 TCP 分段被覆盖（当前 `bb_set`） | P0：改跨 recv 持久化累积缓冲 + `bb_insert` 追加 |
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
| R25 | 地址"1 字节 / 2 字节"**无法用数值区分**（`01` 与 `0001` 都是 `0x01`） | Gurux 按 `serverAddress` 量级推断字节数、无 `addressSize`。若真表要求 2 字节字段而值恰为 `0x0001`，需 P3 引入显式地址宽度（与 R16 同源） |

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
| HDLC 地址字节数 | 按 `serverAddress` **量级自动推断**；`dlmssettings.h` 中**无** `addressSize` 字段 | `dlmssettings.h:132/134` + `dlms.c` 帧构造 |
| `cip_tracePdu` | `extern` 弱符号、库不实现 → 自己提供同名函数即可拿到**明文 PDU**；只需开 `gxignore.h:186` 的 `DLMS_TRACE_PDU` | `ciphering.h:192` |
| 抓原始帧 | 在 bridge 的 send/recv 处汇总即可（TCP 上报文必经），无需 patch vendor | — |

### 13.2 仍待确认 / 待做

- `cl_methodLN` 的复杂入参（ARRAY / STRUCTURE / 浮点 / 日期）→ P3；注意 R17 的 vendor bug（分支条件恒假）
- **精确报文类型标注**：让 bridge 把 C 层已解析的 `gxReplyData.command`（`DLMS_COMMAND`）随 trace 回传，即可去掉启发式误标风险（R20）
- **地址宽度显式表达**（1/2/4 字节区分）→ P3，与 R16 / R25 同源
- 密钥长度在 bridge 侧拦截（R22）

---

## 14. v1.5 批量优化（UI / 交互）

> 动机：报文面板"清空"缺失只是表象，真正的问题是**日志区根本没有独立滚动**。
> 用户要求同类问题一次性改完（避免多次"推送—编译"往返）。

### 14.1 本轮已落地

| # | 问题 | 处置 |
|---|---|---|
| U1 | **报文日志无独立滚动**：日志无限追加，却跟着**页面级外层 `ScrollView`** 一起滚 —— 新报文落在下方看不到，攒到 200 行整页被拉极长 | 日志区改**独立 `ScrollView` + 固定高度 260pt**；用 `ScrollViewReader` 在新报文到达时**自动滚到底**（一次操作结束后没有新流量，此时可自由向上翻阅历史） |
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

*本方案为最终实现契约。**首个里程碑已达成**：CI 三道闸门全绿（C 单测 / 模拟器编译 / Swift 单测）→ 出未签名 IPA → Windows 用 Sideloadly 真机侧载成功。*
*下一步按 §1 推进：P2（GUAK/GUEK 对真表验证密钥映射 · IC 同步 · Association View 列表 · 明文 PDU trace），并核销 §12 中 R20–R25。*