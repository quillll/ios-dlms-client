# DLMS/COSEM 知识库（源码核实版）

> **本文件的定位**：给 AI（以及人）查询的 DLMS/COSEM 事实库。
> 每条结论都标注了**证据来源**与**可信度**，未经核实的条目一律标记为 `❓未核实`，不混入已核实事实。

## 0. 怎么用这份文档（给 AI 的元指令）

1. **优先采信带 `[证据]` 的条目**，它们来自本项目 vendored 源码或 Gurux 官方参考实现，可直接引用行号。
2. **不要采信 `❓未核实` 的条目**作为结论，只可作为假设，需实测或查表验证。
3. 可信度三级：
   - `A 级 · 源码确认` —— 在本项目 `Sources/DLMSCore/C/` 或官方参考实现中读到确切代码/枚举值。
   - `B 级 · 多源一致` —— 标准文档与多个独立资料表述一致，且未与源码冲突。
   - `❓未核实` —— 未能在本项目源码中找到直接证据，或各资料说法冲突。
4. 涉及**具体表计行为**（OBIS 语义、厂商自定义字段、地址约定）时，
   本文件只能给出通用约定，**最终以表的 Association View（读 `0.0.40.0.0.255` attr 2）为准**。

### 证据来源代号

| 代号 | 路径 |
|---|---|
| `C:xxx` | 本项目 vendored 源码 `Sources/DLMSCore/C/xxx`（如 `C:client.h:226`） |
| `REF:communication.c:NNN` | Gurux 官方参考客户端 `D:\project\personal\dlms\GuruxDLMS.c\GuruxDLMSClientExample\src\communication.c` |
| `B:Bridge.c` | 本项目桥接 `Sources/DLMSCore/Bridge/DLMSBridge.c` |
| `STD:IEC 62056-x-x` | 标准文档（经多源交叉比对） |

### 配套文件

| 文件 | 用途 |
|---|---|
| `DLMS知识库.md` | **给人看的主文档**（本文件） |
| `DLMS知识库.jsonl` | **给 AI 检索用的语义块**，每行一个 JSON。改完 .md 后执行 `python tools/gen_kb_jsonl.py` 重新生成 |

`.jsonl` 每行的字段：

```json
{
  "id": "DLMS知识库-004",
  "doc": "DLMS知识库",
  "section_path": "1. 协议分层与核心术语 > 分层",
  "title": "分层",
  "level": 3,
  "tags": ["HDLC", "Wrapper", "分层"],
  "confidence": "A级-源码确认",
  "evidence": ["C:enums.h:1068", "C:enums.h:1070"],
  "chars": 325,
  "content": "..."
}
```

检索建议：先用 `tags` 粗筛，再用 `content` 做语义匹配，最后用 `evidence` 回源码复核；
**`confidence` 为 `未核实` 的块不要直接当结论用**。

---

## 1. 协议分层与核心术语

| 术语 | 含义 |
|---|---|
| **DLMS** | Device Language Message Specification，IEC 62056 系列的通信协议部分 |
| **COSEM** | Companion Specification for Energy Metering，对象建模部分（电表侧的数据模型） |
| **xDLMS** | DLMS 应用层服务（GET / SET / ACTION / ACCESS） |
| **APDU** | Application Protocol Data Unit，应用层报文 |
| **A-XDR** | DLMS 的编码规则（BER 的简化变体），本项目的 tag 表见 §11 |
| **OBIS** | 对象标识系统，6 字节标识符，见 §2 |
| **AA / Application Association** | 应用关联。客户端与服务器建立的"会话 + 角色 + 权限视图" |
| **逻辑设备** | 物理设备（表）内的抽象实体，一个物理设备可含多个逻辑设备 |
| **客户端 / 服务器** | 客户端 = 抄表主站（本 App）；**服务器 = 电表本身**（务必注意方向） |
| **LN / SN** | Logical Name / Short Name 两种引用方式，见 §4 |
| **AA 视图 / Association View** | 某 AA 下可见的 COSEM 对象清单 |

### 分层

```
应用层   COSEM 对象模型 + xDLMS 服务(GET/SET/ACTION) → APDU
表示层   A-XDR 编码（tag / length / value）
链路层   HDLC (IEC 62056-46)   |   Wrapper (IEC 62056-47, TCP/IP)   |   PLC / M-Bus ...
物理层   串口 / TCP / 光口 ...
```

> 本项目只做 **TCP**，链路层二选一：`DLMS_INTERFACE_TYPE_HDLC=0` / `WRAPPER=1`
> `[证据] C:enums.h:1068 / C:enums.h:1070` · `A 级`

---

## 2. 标识体系：OBIS（IEC 62056-6-1）

OBIS 是 **6 个字节** A.B.C.D.E.F，每字节 0–255。Gurux 里就是 `unsigned char name[6]`。

### 2.1 值组语义

| 值组 | 作用 | 常用取值 |
|---|---|---|
| **A** | 介质 / 能源类型 | 0=抽象对象，1=电，6=热，7=气，8=水，15=其他/保留 |
| **B** | 通道号 | 0=未指定通道，1–64=具体通道，128–199=厂商自定义 |
| **C** | 物理量 / 数据项 | 见 2.2 |
| **D** | 处理方法 | 0=周期平均，7=**瞬时值**，8=**时间积分1（累计量）**，128–254=厂商自定义 |
| **E** | 进一步分类 | 0=总计，1..n=费率 n，124=THD，128–254=厂商自定义 |
| **F** | 历史值 / 计费周期 | 0=当前，1–99=历史周期，**255=最新/当前值** |

> `B 级` —— 多份 IEC 62056-6-1 解读一致。

### 2.2 A=1（电能）时 C 的常用值

| C | 含义 | 示例 OBIS |
|---|---|---|
| 1 | 正向有功 (+A) | `1.0.1.8.0.255` = 正向有功总电能 |
| 2 | 反向有功 (−A) | `1.0.2.8.0.255` = 反向有功总电能 |
| 3 | 正向无功 (+R) | `1.0.3.8.0.255` |
| 4 | 反向无功 (−R) | `1.0.4.8.0.255` |
| 31 | **电流**（L1） | `1.0.31.7.0.255` |
| 32 | **电压**（L1） | `1.0.32.7.0.255` |
| 33 | 功率因数 | `1.0.33.7.0.255` |

> `B 级` —— 与本项目预设（`Sources/DLMSModels/DLMSModels.swift:95-106`）一致，
> 且符合现场惯例（如 SML `1-0:32.7.0` = L1 电压）。
> ⚠️ 个别资料把 31 记为电压、51 记为电流，**存在冲突**；现场以 Association View 为准。

### 2.3 常用"抽象对象"（A=0）

| OBIS | 含义 | 可信度 |
|---|---|---|
| `0.0.1.0.0.255` | 逻辑设备名 | A 级（本项目预设，实测常用） |
| `0.0.40.0.0.255` | **Association LN 对象（class 15）**：attr 2 = 对象清单；**method 1 = reply_to_HLS_authentication** | A 级 `[证据] C:client.c:502-504` |
| `0.0.43.0.0.255` | Security Setup（class 64） | ❓未核实（常见约定，未在本项目源码中找到硬编码） |
| `0.0.96.1.0.255` | 设备 ID（制造商 + 序列号） | B 级 |

> 本项目预设清单见 `Sources/DLMSModels/DLMSModels.swift:95-106`。

---

## 3. COSEM 对象模型

每个 COSEM 对象 = **(接口类 class_id, 逻辑名 OBIS, 属性 1..n, 方法 1..n)**。

- **属性 1 恒为 `logical_name`**（所有接口类共有）。
- 属性 2 通常是"值"，属性 3 常见是 scaler/unit。
- 方法从 1 开始编号。

### 3.1 常用接口类（`DLMS_OBJECT_TYPE`，`A 级 · C:enums.h:292-345`）

| class_id | 名称 | 枚举名 |
|---|---|---|
| 1 | Data | `DLMS_OBJECT_TYPE_DATA` |
| 3 | Register | `DLMS_OBJECT_TYPE_REGISTER` |
| 4 | Extended Register | `DLMS_OBJECT_TYPE_EXTENDED_REGISTER` |
| 5 | Demand Register | `DLMS_OBJECT_TYPE_DEMAND_REGISTER` |
| 6 | Register Activation | `DLMS_OBJECT_TYPE_REGISTER_ACTIVATION` |
| 7 | Profile Generic | `DLMS_OBJECT_TYPE_PROFILE_GENERIC` |
| 8 | Clock | `DLMS_OBJECT_TYPE_CLOCK` |
| 9 | Script Table | `DLMS_OBJECT_TYPE_SCRIPT_TABLE` |
| 12 | Association Short Name | `DLMS_OBJECT_TYPE_ASSOCIATION_SHORT_NAME` |
| 15 | **Association Logical Name** | `DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME` |
| 17 | SAP Assignment | `DLMS_OBJECT_TYPE_SAP_ASSIGNMENT` |
| 18 | Image Transfer | `DLMS_OBJECT_TYPE_IMAGE_TRANSFER` |
| 40 | Push Setup | `DLMS_OBJECT_TYPE_PUSH_SETUP` |
| 41 | TCP/UDP Setup | `DLMS_OBJECT_TYPE_TCP_UDP_SETUP` |
| 64 | **Security Setup** | `DLMS_OBJECT_TYPE_SECURITY_SETUP` |
| 70 | Disconnect Control | `DLMS_OBJECT_TYPE_DISCONNECT_CONTROL` |

### 3.2 关键类的属性布局

| 类 | 关键属性 | 可信度 |
|---|---|---|
| Data (1) | attr 2 = value | A 级 |
| Register (3) | attr 2 = value；**attr 3 = scaler_unit**（`value × 10^scaler`） | A 级（Gurux 标准对象定义） |
| Extended Register (4) | attr 2 = value；attr 3 = scaler_unit；attr 4 = status；attr 5 = capture_time | B 级 |
| Clock (8) | attr 2 = time；attr 3 = time_zone | B 级 |
| Profile Generic (7) | attr 2 = buffer；attr 3 = capture_objects（列定义）；attr 4 = capture_period；attr 7 = entries_in_use；attr 8 = profile_entries；**method 1 = reset，method 2 = capture** | B 级（列定义/方法号以 Association View 为准） |
| Association LN (15) | attr 2 = **object_list（对象清单 = Association View）**；attr 6 = authentication_mechanism_name；attr 7 = secret；**method 1 = reply_to_HLS_authentication** | A 级 `[证据] C:client.c:613-630`（attr2 为对象清单）、`C:client.c:502-504`（method1） |

---

## 4. 引用方式：LN vs SN

| 方式 | 定位手段 | 请求命令字 |
|---|---|---|
| **LN（逻辑名）** | 6 字节 OBIS + class_id | `GET_REQUEST = 0xC0` / `SET_REQUEST = 0xC1` / `METHOD_REQUEST = 0xC3` |
| **SN（短名）** | 16 位基址 + 属性偏移 | `READ_REQUEST = 0x05` / `WRITE_REQUEST = 0x06` |

> `A 级 · C:enums.h:1143/1151/1162/1172/1182`
> 本项目固定用 **LN**（`cl_init` 第 2 参 `useLogicalNameReferencing=1`）。

---

## 5. 传输层

### 5.1 HDLC（IEC 62056-46）

- 帧结构：`7E [格式+长度] [目标地址] [源地址] [控制] [HCS] [LLC] [信息] [FCS] 7E`
- 链路层命令：`SNRM 0x93` / `UA 0x73` / `DISC 0x53` / `DM 0x1F`
  `A 级 · C:enums.h:1203/1208/1223/1193`
- 地址由 `clientAddress` / `serverAddress` 决定，**无需外部 addressSize**（Gurux 按值自动推断字节数）。

### 5.2 Wrapper（IEC 62056-47，TCP/IP 上的 COSEM 传输层）

- 帧头：`0x0001`（版本号）+ 源 wPort(2B) + 目标 wPort(2B) + 长度(2B) + 数据
- **没有 SNRM/UA**，直接进 AARQ/AARE；断链也无 DISC。

### 5.3 分帧与"更多数据"

- 大响应会分块，用 **Receiver Ready (RR)** 续传。
- Gurux 侧判据：`reply->moreData` / `reply_isMoreData()`，续传用 `cl_receiverReady()`。
  `A 级 · C:replydata.h:143`、`C:client.h:266`

---

## 6. 应用层服务（xDLMS）

| 服务 | 请求 | 响应 | Gurux 函数 |
|---|---|---|---|
| GET（读） | `0xC0` | `0xC4` | `cl_readLN` |
| SET（写） | `0xC1` | `0xC5` | `cl_writeLN` |
| ACTION（执行） | `0xC3` | `0xC7` | `cl_methodLN` |

> `A 级 · C:enums.h:1162/1167/1172/1177/1182/1187`、`C:client.h:131/226/350`

每种服务有 normal / with-list / with-first-block 等子类型，**本项目用 normal**。

---

## 7. 建链与断链流程（★ 最容易写错的地方）

### 7.1 完整序列

```
HDLC:
  1. cl_snrmRequest              → 收全帧 → cl_parseUAResponse
  2. cl_aarqRequest              → 收全帧 → cl_parseAAREResponse
  3. ★ if (settings->isAuthenticationRequired)      ← 应用层必须自己判断
         cl_getApplicationAssociationRequest
         → 收全帧 → cl_parseApplicationAssociationResponse
  4. 业务 GET / SET / ACTION
  5. cl_releaseRequest2(settings, msg, security != NONE)   ← RLRQ (0x62)
  6. cl_disconnectRequest                                   ← DISC (0x53)
  7. TCP close + cl_clear

Wrapper:
  跳过第 1 步与第 6 步，其余相同。
```

> `A 级 · REF:communication.c:1067-1112`（建链）、`REF:communication.c:864-886`（断链）

### 7.2 三个必须记住的点

1. **`cl_parseAAREResponse` 不会自动做 HLS challenge**。它只做三件事：判 result、
   置 `settings->isAuthenticationRequired`、仅在**不需要**认证时置 `DLMS_CONNECTION_STATE_DLMS`。
   `A 级 · C:client.c:380-409`
2. **CtoS / StoC challenge 是自动的**：
   `cl_aarqRequest` 自动生成并发送 `ctoSChallenge`（`C:client.c:348-355`）；
   AARE 里的 `stoCChallenge` 由 `apdu_parsePDU` 自动抽取（`C:apdu.c:1746-1755`）。
   → **应用层不需要自己去"读 challenge"**。
3. **HLS 是独立的一轮请求/响应**，不是"一个 AARE 完事"。Gurux 内部实现是调
   `0.0.40.0.0.255` 的 method 1（`reply_to_HLS_authentication`），
   `A 级 · C:client.c:502-504`。

### 7.3 断链细节

- 必须**先 RLRQ 再 DISC**。
- `useProtectedRelease` 参数 = **是否用了加密**：`settings.cipher.security != DLMS_SECURITY_NONE`。
  `A 级 · REF:communication.c:871`

---

## 8. 认证机制（mechanism_id）

| mechanism_id | 名称 | Gurux 枚举 | 值 |
|---|---|---|---|
| 0 | 最低安全（无认证） | `DLMS_AUTHENTICATION_NONE` | 0 |
| 1 | LLS（密码） | `DLMS_AUTHENTICATION_LOW` | 1 |
| 2 | HLS（印度标准） | `DLMS_AUTHENTICATION_HIGH` | 2 |
| 3 | HLS MD5 | `DLMS_AUTHENTICATION_HIGH_MD5` | 3 |
| 4 | HLS SHA-1 | `DLMS_AUTHENTICATION_HIGH_SHA1` | 4 |
| **5** | **HLS GMAC（最常用）** | `DLMS_AUTHENTICATION_HIGH_GMAC` | **5** |
| 6 | HLS SHA-256 | `DLMS_AUTHENTICATION_HIGH_SHA256` | 6 |
| 7 | HLS ECDSA | `DLMS_AUTHENTICATION_HIGH_ECDSA` | 7 |

> `A 级 · C:enums.h:1023-1061`；与 DLMS 标准 mechanism_id 表一致（`B 级`）。
> ⚠️ `HIGH_GMAC` 与 `HIGH_SHA256/ECDSA` 受条件编译保护：
> 若定义 `DLMS_IGNORE_HIGH_GMAC`，该枚举值**不存在**（本项目 `C:gxignore.h:53` 未定义，可用）。
> mechanism 3 与 4 标准已不推荐用于新实现。

### HLS-GMAC 的四步互相认证

1. 客户端把 CtoS challenge 放 AARQ 的 `calling-authentication-value`
2. 服务器把 StoC challenge 放 AARE 的 `responding-authentication-value`
3. 客户端用 GMAC 算 `f(StoC)`，通过 method 1 回传；服务器比对
4. 服务器算 `f(CtoS)` 回送；客户端比对

> `B 级` —— 与 Gurux 源码实现路径一致（`C:client.c:439-597`）。

---

## 9. 安全：套件 / 策略 / 密钥 / 帧计数

### 9.1 传输安全四档（`DLMS_SECURITY`，喂给 `settings->cipher.security`）

| 名称 | 值 | 含义 |
|---|---|---|
| `DLMS_SECURITY_NONE` | 0x00 | 不加密 |
| `DLMS_SECURITY_AUTHENTICATION` | 0x10 | 仅认证 |
| `DLMS_SECURITY_ENCRYPTION` | 0x20 | 仅加密 |
| `DLMS_SECURITY_AUTHENTICATION_ENCRYPTION` | 0x30 | 认证+加密 |

> `A 级 · C:enums.h:736-751`
> ⚠️ 名称是 `ENCRYPTION` 不是 `ENCRYPTED`。
> ⚠️ **不要**用 `DLMS_SECURITY_POLICY` 喂这个字段 —— 那是 Security Setup 对象的属性位域，编码不同。

### 9.2 安全套件（`DLMS_SECURITY_SUITE`）

| suite | 认证加密 | 签名 | 密钥协商 | 哈希 | 密钥传输 | 压缩 |
|---|---|---|---|---|---|---|
| 0 | AES-GCM-128 | — | — | — | AES-128 key wrap | — |
| 1 | AES-GCM-128 | ECDSA P-256 | ECDH P-256 | SHA-256 | AES-128 key wrap | V.44 |
| 2 | AES-GCM-256 | ECDSA P-384 | ECDH P-384 | SHA-384 | AES-256 key wrap | V.44 |

> `A 级 · C:enums.h:164-172`，与 DLMS 官方套件表一致（`B 级`）。
> Suite 1/2 需 `gxignore.h:197/200` 打开 `DLMS_SECURITY_SUITE_1/2`（本项目默认未开）。

### 9.3 安全策略（`DLMS_SECURITY_POLICY`，Security Setup 对象属性，可 OR）

| 值 | 名称 | 版本 |
|---|---|---|
| 0 | NOTHING | |
| 1 | AUTHENTICATED | v0 |
| 2 | ENCRYPTED | v0 |
| 3 | AUTHENTICATED_ENCRYPTED | v0 |
| 0x04 / 0x08 / 0x10 | AUTHENTICATED_REQUEST / ENCRYPTED_REQUEST / DIGITALLY_SIGNED_REQUEST | v1 |
| 0x20 / 0x40 / 0x80 | AUTHENTICATED_RESPONSE / ENCRYPTED_RESPONSE / DIGITALLY_SIGNED_RESPONSE | v1 |

> `A 级 · C:enums.h:119-155`

### 9.4 密钥类型

| 缩写 | 全称 | 作用 | Gurux 字段 | 可信度 |
|---|---|---|---|---|
| **MK / KEK** | Master Key / Key Encryption Key | 包裹（加密传输）其它密钥，出厂预置 | `settings->kek` | A 级字段位置；语义 B 级 |
| **EK / GUEK** | Global Unicast Encryption Key = **Block cipher key** | AES-GCM 加解密 | `settings->cipher.blockCipherKey` | A 级字段；语义 B 级 |
| **GBEK** | Global Broadcast Encryption Key | 广播加解密 | `settings->cipher.broadcastBlockCipherKey` | A 级字段；语义 B 级 |
| **DK** | Dedicated Key（会话密钥） | 单次 AA 内的加解密 | `settings->cipher.dedicatedKey`（`gxByteBuffer*`） | A 级字段；语义 B 级 |
| **AK** | Authentication Key | 作为 AAD 参与认证 | `settings->cipher.authenticationKey` | A 级字段；语义 B 级 |

> ⚠️ **EK↔blockCipherKey 的映射目前是"合理推定"，尚未在真表上验证**（项目风险 R1）。

### 9.5 双 SystemTitle（★ 方向极易搞反）

| 字段 | 位置 | 真实含义 |
|---|---|---|
| `settings->cipher.systemTitle` | `C:ciphering.h:83` | **客户端自己的** SystemTitle（8 字节） |
| `settings->sourceSystemTitle` | `C:dlmssettings.h:117`（`unsigned char[8]`，**顶层，不在 cipher 里**） | **服务器的** SystemTitle（由 AARE 的 responding-AP-title 自动回填） |

> `A 级` 证据：
> - `C:client.c:443` —— HLS-GMAC 分支把 `cipher.systemTitle` 当作 GMAC 的密钥使用 → 它是"我自己的"
> - `C:apdu.c:1717` —— `PDU_TYPE_CALLING_AP_TITLE` 分支写入 `settings->sourceSystemTitle` → 它来自对端
>
> ⚠️ **必须在 `cl_aarqRequest` 之前设置客户端 SystemTitle**，否则 AARQ 不带 A6 字段。
> AARE 诊断值 `DLMS_SOURCE_DIAGNOSTIC_CALLING_AP_TITLE_NOT_RECOGNIZED = 3`（注释原文
> "Client system title is missing"，`C:enums.h:71`）就是缺/错客户端 ST 的直接信号。

### 9.6 Invocation Counter（IC，帧计数）

- 字段：`settings->cipher.invocationCounter`，类型 **`uint32_t`**，`C:ciphering.h:91`
- **没有公开的 setter**，复位只能直接赋值。
- ⚠️ `cip_init` 设为 **0**（`C:ciphering.c:335`），`cip_clear` 设为 **1**（`C:ciphering.c:362`），**两者不一致**。
- 加密时库会**自动递增**（`C:ciphering.c:613`）。
- **真表会拒绝 IC 过低的帧**，返回 `INVOCATION_COUNTER_ERROR` 并带回期望值
  （`REF:communication.c:1067-1077`）。
- 官方推荐从表同步：临时以 NONE 认证 + client 16 建链，读存放 IC 的 Data 对象，然后
  `settings.cipher.invocationCounter = 1 + var_toInteger(&d.value)`（`REF:communication.c:914-1020`）。

---

## 10. Gurux C API 参考（本项目 vendored 版本）

> 全部 `A 级`，行号来自 `Sources/DLMSCore/C/`。

### 10.1 读 / 写 / 执行

```c
int cl_readLN(dlmsSettings* settings,
              const unsigned char* name,        // 6 字节 OBIS
              DLMS_OBJECT_TYPE interfaceClass,
              unsigned char attributeOrdinal,   // 必须 >= 1
              gxByteBuffer* data,               // 选择性访问参数；普通读传 NULL
              message* messages);               // client.h:131
```

```c
int cl_writeLN(dlmsSettings* settings,
               const unsigned char* name,
               DLMS_OBJECT_TYPE interfaceClass,
               unsigned char index,             // 必须 >= 1
               dlmsVARIANT* data,               // ← 注意：是 variant，不是 gxByteBuffer*
               unsigned char byteArray,         // ← 第 6 参：1=透传 data->byteArr，0=按 data->vt 现编
               message* messages);              // client.h:226
```

```c
int cl_methodLN(dlmsSettings* settings,
                const unsigned char* name,
                DLMS_OBJECT_TYPE objectType,
                unsigned char index,
                dlmsVARIANT* data,              // 可传 NULL（写 0x00 = 无参数）
                message* messages);             // client.h:350
```

### 10.2 建链 / 断链 / 数据块

| 函数 | 签名要点 | 位置 |
|---|---|---|
| `cl_init` | `(settings, useLN, clientAddress:uint16_t, serverAddress:uint32_t, auth, password:const char*, interfaceType)` | `C:dlmssettings.h:357` |
| `cl_clear` | `(settings)` —— 内部 `cip_clear` | `C:dlmssettings.h:367` |
| `cl_snrmRequest` | `(settings, message*)` —— **受 `DLMS_IGNORE_HDLC` 保护** | `C:client.h:66` |
| `cl_parseUAResponse` | `(settings, gxByteBuffer*)` —— 同上 | `C:client.h:70` |
| `cl_aarqRequest` | `(settings, message*)` | `C:client.h:82` |
| `cl_parseAAREResponse` | `(settings, gxByteBuffer*)` | `C:client.h:86` |
| `cl_getApplicationAssociationRequest` | `(settings, message*)` | `C:client.h:90` |
| `cl_parseApplicationAssociationResponse` | `(settings, gxByteBuffer*)` | `C:client.h:94` |
| `cl_getObjectsRequest` | `(settings, message*)` —— 读 `0.0.40.0.0.255` attr 2 | `C:client.h:99` |
| `cl_parseObjectCount` | `(gxByteBuffer*, uint16_t*)` | `C:client.h:111` |
| `cl_parseNextObject` | `(settings, gxByteBuffer*, gxObject*)` | `C:client.h:117` |
| `cl_getData2` | `(settings, gxByteBuffer* reply, gxReplyData*, gxReplyData* notify, unsigned char* isNotify)` | `C:client.h:53` |
| `cl_receiverReady` | `(settings, DLMS_DATA_REQUEST_TYPES, gxByteBuffer*)` | `C:client.h:266` |
| `cl_releaseRequest2` | `(settings, message*, unsigned char useProtectedRelease)` | `C:client.h:286` |
| `cl_disconnectRequest` | `(settings, message*)` | `C:client.h:292` |
| `cl_getKeepAlive` | `(settings, message*)` | `C:client.h:151` |
| `cl_getServerAddress` | `(logical:uint16_t, physical:uint16_t, addressSize) → uint16_t` | `C:client.h:438` |

### 10.3 地址合成

```c
// client.c:2285-2301
if (addressSize < 4 && physical < 0x80 && logical < 0x80)
    value = logical << 7  | physical;      // 小址
else if (physical < 0x4000 && logical < 0x4000)
    value = logical << 14 | physical;      // 大址
```

> ⚠️ 返回 `uint16_t`，`logical ≥ 4` 的大址会**溢出**。
> 广播地址物理部分：`0x7F`（1 字节）/ `0x3FFF`（2 字节），`C:dlms.c:2405`。

---

## 11. 数据类型（`DLMS_DATA_TYPE`，A-XDR tag）

> `A 级 · C:enums.h:525-558`。这是做 hex↔variant 解析的权威表。

| tag | 枚举名 | 说明 | 定长 |
|---|---|---|---|
| 0x00 | `NONE` | 无 | — |
| 0x01 | `ARRAY` | 数组 | 变长 |
| 0x02 | `STRUCTURE` | 结构 | 变长 |
| 0x03 | `BOOLEAN` | 布尔 | 1 |
| 0x04 | `BIT_STRING` | 位串 | 变长 |
| 0x05 | `INT32` | 有符号 32 | 4 |
| 0x06 | `UINT32` | 无符号 32 | 4 |
| 0x09 | `OCTET_STRING` | 字节串 | 变长 |
| 0x0A | `STRING` | ASCII 串 | 变长 |
| 0x0C | `STRING_UTF8` | UTF-8 串 | 变长 |
| 0x0D | `BINARY_CODED_DESIMAL` | BCD | 变长 |
| 0x0F | `INT8` | 有符号 8 | 1 |
| 0x10 | `INT16` | 有符号 16 | 2 |
| 0x11 | `UINT8` | 无符号 8 | 1 |
| 0x12 | `UINT16` | 无符号 16 | 2 |
| 0x13 | `COMPACT_ARRAY` | 紧凑数组 | 变长 |
| 0x14 | `INT64` | 有符号 64 | 8 |
| 0x15 | `UINT64` | 无符号 64 | 8 |
| 0x16 | `ENUM` | 枚举 | 1 |
| 0x17 | `FLOAT32` | 单精度 | 4 |
| 0x18 | `FLOAT64` | 双精度 | 8 |
| 0x19 | `DATETIME` | 日期时间 | 12 |
| 0x1A | `DATE` | 日期 | 5 |
| 0x1B | `TIME` | 时间 | 4 |
| 0x1C–0x21 | `DELTA_INT8…DELTA_UINT32` | 增量值 | — |
| 0x80 | `BYREF` | **掩码**，非独立类型 | — |

**注意事项**：
- tag **7 / 8 / 11 / 14 未使用**，遇到应报"未知类型"。
- 判类型前先 `vt & ~DLMS_DATA_TYPE_BYREF` 去掉 0x80 掩码。
- 实际线路上 DATETIME 常以 OCTET_STRING(0x09) 承载。

---

## 12. 命令字（`DLMS_COMMAND`）

> `A 级 · C:enums.h:1127-1351`

| 值 | 命令 | 值 | 命令 |
|---|---|---|---|
| 0x00 | NONE | 0xC0 | GET_REQUEST |
| 0x05 | READ_REQUEST (SN) | 0xC1 | SET_REQUEST |
| 0x06 | WRITE_REQUEST (SN) | 0xC3 | METHOD_REQUEST |
| 0x0E | CONFIRMED_SERVICE_ERROR | 0xC4 | GET_RESPONSE |
| 0x0F | DATA_NOTIFICATION | 0xC5 | SET_RESPONSE |
| 0x1F | DISCONNECT_MODE / DM | 0xC7 | METHOD_RESPONSE |
| 0x53 | DISC | 0xD8 | EXCEPTION_RESPONSE |
| 0x60 | AARQ | 0xDB | GENERAL_GLO_CIPHERING |
| 0x61 | AARE | 0xDC | GENERAL_DED_CIPHERING |
| 0x62 | RELEASE_REQUEST | 0xDD | GENERAL_CIPHERING |
| 0x63 | RELEASE_RESPONSE | 0x73 | UA |
| 0x93 | SNRM | | |

---

## 13. 错误码与诊断

### 13.1 `DLMS_ERROR_CODE_*`（`A 级 · C:errorcodes.h:57-144`）

| 名称 | 值 |
|---|---|
| `DLMS_ERROR_CODE_FALSE` | -1 |
| `DLMS_ERROR_CODE_OK` | 0 |
| `DLMS_ERROR_CODE_READ_WRITE_DENIED` | 3 |
| `DLMS_ERROR_CODE_OTHER_REASON` | 250 |
| `DLMS_ERROR_CODE_SEND_FAILED` | 枚举序（具体值见 errorcodes.h:97） |
| `DLMS_ERROR_CODE_RECEIVE_FAILED` | errorcodes.h:99 |
| `DLMS_ERROR_CODE_INVALID_PARAMETER` | errorcodes.h:112 |
| `DLMS_ERROR_CODE_INVALID_CLIENT_ADDRESS` | errorcodes.h:122 |
| `DLMS_ERROR_CODE_INVALID_SERVER_ADDRESS` | errorcodes.h:124 |
| `DLMS_ERROR_CODE_INVALID_VERSION_NUMBER` | errorcodes.h:128 |
| `DLMS_ERROR_CODE_REJECTED_PERMAMENT` | errorcodes.h:141 |
| `DLMS_ERROR_CODE_REJECTED_TRANSIENT` | errorcodes.h:142 |
| `DLMS_ERROR_CODE_APPLICATION_CONTEXT_NAME_NOT_SUPPORTED` | errorcodes.h:144 |

### 13.2 AARE 源诊断（`DLMS_SOURCE_DIAGNOSTIC`，`A 级 · C:enums.h:65-93`）

| 值 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 无原因 |
| 2 | Application context name 不支持（**LN/SN 选错**） |
| 3 | **Calling AP title 未识别 —— 客户端 SystemTitle 缺失/错误** |
| 11 | 认证机制名不识别 |
| 12 | 需要认证机制名 |
| 13 | 认证失败 |
| 14 | 需要认证（→ 触发 HLS 那一轮） |

### 13.3 连接状态（`DLMS_CONNECTION_STATE`，`A 级 · C:enums.h:2955-2961`）

`NONE=0` / `HDLC=1` / `DLMS=2` / `IEC=4`

### 13.4 现场排错速查

| 现象 | 排查方向 |
|---|---|
| 表完全不响应 | **server 地址错**（Gurux 原话） |
| 认证错误 | **client 地址错**（Gurux 原话） |
| AARE diagnostic = 3 | 客户端 SystemTitle 缺失或错误 |
| AARE diagnostic = 2 | LN/SN 引用方式选错 |
| `INVOCATION_COUNTER_ERROR` | IC 过低，从 `reply.data` 读回期望值（`REF:communication.c:1070-1077`） |
| `READ_WRITE_DENIED` | 权限不足，换更高等级的 client 地址 |

---

## 14. 本项目桥接层铁律

> 这些是本项目特有的实现约束，任何改动都必须遵守。

1. **接收必须追加，不能覆盖**。
   `dlms_getHdlcData` 用 `reply->position` 作游标，未收全时原样返回不消费
   （`C:dlms.c:2882`、`C:dlms.c:2889-2893`）。
   → 累积缓冲必须放在 ctx 上跨 recv 持久化，每次 recv 用 `bb_insert(...)` 追加，
   只在**发起新请求时**重置。官方做法 `REF:communication.c:695-704`。
2. **接收缓冲按 `settings->maxPduSize + 50` 分配**。
   官方注释：有些表会多发几个字节（`REF:communication.c:990-992`）。
3. **断链顺序**：`cl_releaseRequest2(security != NONE)` → `cl_disconnectRequest`（Wrapper 无后者）。
4. **Wrapper 不发 SNRM**，`dlms_initialize` 必须按 `interfaceType` 分支。
5. **C 状态机非线程安全**：Swift 侧串行队列 + busy 标志，**禁止硬中断**。
6. **每次建链前 `cl_clear` + 重新 `cl_init`**，防 IC / 会话状态错乱。

### 14.1 官方已提供的工具函数（不要重复造轮子）

| 函数 | 用途 | 位置 |
|---|---|---|
| `bb_addHexString(bb, const char* str)` | **hex 字符串 → 字节**（请求数据解析直接用它） | `C:bytebuffer.h:409` |
| `bb_addHexString2(bb, str)` | no-malloc 变体 | `C:bytebuffer.h:415` |
| `bb_toHexString2(bb, buffer, size)` | 字节 → hex 字符串（日志渲染） | `C:bytebuffer.h:425` |
| `bb_insert(src, count, target, index)` | 在指定位置插入（index=size 即追加） | `C:bytebuffer.h:238` |
| `var_setUInt8/16/32/64`、`var_setInt8/16/32/64` | variant 构造 | `C:variant.h:250-288` |
| `var_addBytes(v, bytes, count)` | OCTET_STRING 构造 | `C:variant.h:382` |
| `var_toString(item, bb)` | variant → 字符串（数据解析窗口用） | `C:variant.h:506` |

### 14.2 抓报文的零 patch 方案

- **原始帧**：在 bridge 的 send / recv 处回调即可（TCP 上报文必经）。
- **明文 PDU（加密时最有价值）**：`cip_tracePdu(unsigned char encrypt, gxByteBuffer* pdu)`
  在 `C:ciphering.h:192` 是 `extern` 声明但**库不实现** —— 在**自己的桥接 .c**
  提供同名函数即可接管，拿到"加密前的明文 / 解密后的明文"。
  前提是打开 `C:gxignore.h:186` 的 `// #define DLMS_TRACE_PDU`（唯一需改 vendor 的一行）。
- `settings->trace` / `GX_TRACE_LEVEL` 在本版本是**死代码**（`C:enums.h:2584-2613` 定义但无人使用），不要用。

---

## 15. 已知的坑（踩过的 / 源码实证的）

| # | 坑 | 证据 |
|---|---|---|
| 1 | `cip_init` IC=0，`cip_clear` IC=1，**不一致** | `C:ciphering.c:335` / `C:ciphering.c:362` |
| 2 | `ciphering.h` 无 `cipher_reset` / `cipher_setInvocationCounter`，复位只能直接赋值 | 全文件无此符号 |
| 3 | `cip_decrypt` 输出 IC 是 `uint64_t*`，但字段是 `uint32_t`，赋值回来会截断 | `C:ciphering.h:91/150` |
| 4 | `cipheringenums.h` 是**空文件**，安全枚举全在 `enums.h` | 文件为空 |
| 5 | `cl_getServerAddress` 返回 `uint16_t`，大址 `logical≥4` 溢出 | `C:client.c:2285` |
| 6 | `cl_methodLN` 有 vendor bug：`(vt==ARRAY \|\| vt==STRUCTURE) && vt==OCTET_STRING` 恒假 | `C:client.c:2067-2068` |
| 7 | `bb_set` 是**覆盖**不是追加 | `C:bytebuffer.h:156` 注释 "Set new data" |
| 8 | `cl_snrmRequest` / `cl_parseUAResponse` 受 `DLMS_IGNORE_HDLC` 保护 | `C:client.h:65/70` |
| 9 | `DLMS_SECURITY_ENCRYPTED` 不存在，正确名是 `ENCRYPTION` | `C:enums.h:746` |
| 10 | `var_setString` / `var_addBytes` / `var_attach` 需 `!DLMS_IGNORE_MALLOC`（本项目可用） | `C:variant.h:382/389/396` |

---

## 16. 参考位置

| 资源 | 路径 |
|---|---|
| vendored 协议核心 | `Sources/DLMSCore/C/` |
| 本项目桥接 | `Sources/DLMSCore/Bridge/DLMSBridge.c` |
| Swift 可见面 | `Sources/DLMSCore/Headers/DLMSCore.h` |
| **官方权威参考实现** | `D:\project\personal\dlms\GuruxDLMS.c\GuruxDLMSClientExample\src\communication.c` |
| 官方示例主流程 | `D:\project\personal\dlms\GuruxDLMS.c\GuruxDLMSClientExample\src\main.c` |

> **优先照抄官方参考实现，不要照抄网上片段。**
