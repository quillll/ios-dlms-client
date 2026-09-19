# DLMS 抄表调试台 iOS —— 详细方案（v1.2）

> 状态：已完成外部技术审查并就源码逐条核实，更新到 v1.2，等待开工（P0→P1 先行）
> v1.2 变更（依据 `docs/DLMS调试台-方案-审查与改进.md`，已对 vendored 源码核实）：
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
| 密钥 | 仅 **LLS密码 + aKEK + 客户端SystemTitle**（无 HLS密钥/AK/EK；服务器SystemTitle自动捕获） |
| 客户端SystemTitle | 常显（默认 HLS-GMAC 需它在 AARQ 前设置，见 R13）；认证选 HLS 时标为必填 |
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
│       信息加密 NONE/仅加密/仅认证/认证加密(aKEK)   │
│       LLS密码·HLS密钥·EM(aKEK)·AK·EK·服务器SystemTitle·客户端SystemTitle │
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
- 类 / OBIS / 属性/方法：支持 **10/16 进制切换**输入，并**自动识别**（含 `a-f` → 视为 16 进制、无前缀 hex）。
- OBIS 分隔符兼容 `, . - :`；可下拉全局清单或手输。
- 请求数据 = **ASN.1/BER 编码**的 HEX 字节（空格可有可无）。例：`11 01`=unsigned 数据 1；`12 01 00`=long unsigned 数据 256。

---

## 4. 数据模型（JSON 文件存储）

- **`ConnectionConfig`**：IP、端口、超时、封装(HDLC/Wrapper)、客户端地址(预设+自定义)、通信地址/源/目标、认证、信息加密、五密钥、双 SystemTitle、日志级别、解析使能 —— **记住上次**。
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
  - `DLMS_SECURITY_NONE=0` / `DLMS_SECURITY_AUTHENTICATION=0x10`(仅认证) / **`DLMS_SECURITY_ENCRYPTION=0x20`**(仅加密,注意名是 ENCRYPTION 非 ENCRYPTED) / `DLMS_SECURITY_AUTHENTICATION_ENCRYPTION=0x30`(认证加密,用 aKEK)。`enums.h:736-751` 已核实。
  - **不要**喂 `DLMS_SECURITY_POLICY`（那是 Security Setup 对象位域 v0:1/2/3、v1:0x04..0x80）。
- 密钥约定映射（**已修正方向，P2 对真表锁定 R1**）：
  - EM/aKEK ↔ `settings->cipher.blockCipherKey`
  - AK ↔ `settings->cipher.authenticationKey`
  - EK：先按 `blockCipherKey`；GMAC 预留 `settings->cipher.dedicatedKey`
- SystemTitle（**方向已修正，只管客户端；服务器自动**）：
  - **客户端自己的 SystemTitle** → `settings->cipher.systemTitle`（`client.c:443` 用它当 GMAC 密钥），**必须在 `cl_aarqRequest` 之前设置**，否则 AARQ 无 A6 字段、HLS 必然失败（R13）。
  - **服务器 SystemTitle** → `settings->sourceSystemTitle`（顶层 `unsigned char[8]`，**由 AARE 的 AP-title 自动回填**，`apdu.c:1737`），一般无需手填；仅 pre-established 才需手填。**不作为 UI 输入，捕获后显示在数据/日志区。**
- 相关字段（已确认 ciphering.h）：`security`、`suite`、`securityPolicy`、`encrypt`、`blockCipherKey`、`broadcastBlockCipherKey`、`systemTitle`、`invocationCounter`、`authenticationKey`、`dedicatedKey`。

---

## 8. 报文日志 & 数据解析

- **报文日志**：桥接 C 增 **trace 回调**，发/收每帧回调 `(方向, 原始HEX, 语义注释)`；Swift 渲染时间戳 + Send/Receive + `Original:` 注解 + 完整 HEX + 四色(TX红/RX蓝/信息绿/服务橙) + 级别过滤。
  - **trace 实现（R4/R9）**：P1 在 bridge 的 send/recv 处抓全部原始帧（TCP 上报文必经），语义注解 `>>>` 逐版加深；若需 patch vendor 源码则用脚本管理并纳入 CI，接受升级重打补丁成本。
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

## 10. 构建 / CI

- XcodeGen `project.yml` + GitHub Actions：
  - `simulator` 目标：验证可编译，产出 `.app`
  - `device` 目标：出未签名 `.ipa`（改装机再本地签名）
- **首个闸门 = simulator 编译通过**（预期 1~2 次 C/modulemap 修正属正常）。
- **第二闸门 = hex→variant 解析器单元测试**（纯函数，不依赖真表，成本低收益直接）。

---

## 11. 明确不做（P1/P2/P3 之外）

循环/批次 · Profile Generic 曲线 · 自动枚举/目录树 · 串口 · 商用分发（自用，GPL 无碍）。

---

## 12. 风险登记（实现时逐一核销）

| 编号 | 风险 | 处置 |
|---|---|---|
| R1 | EM/AK/EK ↔ Gurux `blockCipherKey/authenticationKey/dedicatedKey` 映射 | P2 对真表专项验证后锁定 |
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
| R13 | 客户端 SystemTitle 未设 → AARQ 无 A6、HLS 失败 | P1：UI 常显 + 8 字节校验 + 选 HLS 标必填 |
| R14 | P1 无 IC 同步，IC=1 可能被真表拒 | P1 文档化；P2 加 IC 同步 + 持久化 |
| R15 | `cip_init` IC=0 vs `cip_clear` IC=1 不一致 | P2：显式赋值，不依赖库初值 |
| R16 | `cl_getServerAddress` 返回 uint16，logical≥4 溢出 | P3：UI 合成器校验 |
| R17 | `cl_methodLN` vendor bug（ARRAY/STRUCTURE 分支恒假） | P3：先确认版本 |
| R18 | Wrapper 模式误发 SNRM | P0：按 interfaceType 分支 |

---

## 13. 待核符号（实现时在源码逐一确认）

- `cl_writeLN` / `cl_methodLN` 精确签名（client.h 已见声明，需读实现确认参数语义）
- **`DLMS_SECURITY` 取值**（enums.h 已核实：0 / 0x10 / 0x20 / 0x30；**非** `DLMS_SECURITY_POLICY`）
- association/HLS 建链函数（`cl_snrmRequest`/`cl_aarqRequest`/`cl_parseUAResponse`/`cl_parseAAREResponse` + HLS challenge：读 0.0.40.0.0.255 ⇒ GMAC ⇒ ACTION）
- `cl_methodLN` 的 variant 入参如何构造（hex→variant 解析，P1 仅整型+无参）
- HDLC 地址字节数自动推断逻辑（dlms.c 帧构造）
- `DLMS_DATA_TYPE` 枚举值（hex tag ↔ 类型映射表，供 hex→variant）

---

*本方案为最终实现契约。批准后从 P1 开工，首个里程碑：`dlms-ios-app/` 可在 CI 完成 simulator 编译。*