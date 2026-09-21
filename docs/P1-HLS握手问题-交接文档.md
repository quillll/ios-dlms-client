# P1 交接文档：HDLC/Wrapper + HLS-GMAC 握手失败

> 目的：把一个**自包含**的问题描述交给另一个 AI 继续排查。
> 文中所有"报文"均为现场抓包原文（逐字节照抄）；所有"结论"都标注了依据；
> **我走过的错误假设单独列在 §7，请勿重复**。

---

## 1. 环境与代码结构

| 项 | 说明 |
|---|---|
| 应用 | 自用现场抄表 iOS App（SwiftUI），近 GXDLMSDirector 的调试台形态 |
| 协议库 | **vendored Gurux.DLMS.c**（C 语言，GPLv2），位于 `Sources/DLMSCore/C/`（约 100 个 .c/.h，**不应改动**） |
| 桥接层 | `Sources/DLMSCore/Bridge/DLMSBridge.c` + `Sources/DLMSCore/Headers/DLMSCore.h`（Swift 唯一可见的 C 面） |
| Swift 传输 | `Sources/DLMSBridge/GXDLMSTransport.swift`（NWConnection TCP） |
| Swift 抄读器 | `Sources/DLMSBridge/GXDLMSReader.swift` |
| 构建 | 无 Mac，靠 GitHub Actions（XcodeGen `project.yml`）：Linux 跑 C 单测、macOS 跑模拟器编译+Swift 单测 |
| 本地可跑 | 有 Windows + TDM-GCC，**可以在本地编译全部 C 并跑 `Tests/CTests/test_dlms.c`**（不含 server/serverevents/notify/gxserializer） |

**编译本地测试的方式**（PowerShell 片段，供参考）：
```powershell
$cc="C:\TDM-GCC-32\bin\gcc.exe"
$fl=@("-O0","-g","-Wall","-DDLMS_IGNORE_SERVER","-DDLMS_IGNORE_SERIALIZER",
      "-I<repo>\Sources\DLMSCore\C\include","-I<repo>\Sources\DLMSCore\Headers")
# 编译 Sources/DLMSCore/C/src/*.c（排除上面四个）+ Bridge/DLMSBridge.c + Tests/CTests/test_dlms.c，链接后运行
```

---

## 2. 问题一句话

**App 在与真表建立关联（AARQ/AARE）后，无法完成 HLS-GMAC 挑战应答，导致抄表失败。**
`GXDLMSDirector`（.NET，同一台表、同一网络）**可以正常连接并抄表**。

---

## 3. 现场配置

| 参数 | 值 |
|---|---|
| 封装 | **Wrapper**（`00 01` 版本 + 2 字节源 + 2 字节目的） |
| 服务端地址 | **1001** = `0x03E9` |
| 客户端地址 | `0x0001` |
| 认证方式 | **HLS-GMAC** |
| 客户端 SystemTitle | `4142433132333435`（"ABC12345"） |
| 信息加密 | 见 §5（这是关键变量） |
| 表侧 SystemTitle | `4142433132333435`（"ABC12345"，AARE 的 `A4` 字段可见） |
| GUAK / GUEK | 16 字节全 0（GXDLMSDirector 侧）|

**GXDLMSDirector 的 Device Properties 设置页（用户提供截图，转录）**：
```
Security Suite: Suite0          Security: None
System title:   00000000        [ ] ASCII      [Certificate.]
Block Cipher Key:     00000000000000000000000000000000   [ ] ASCII
Authentication Key:   00000000000000000000000000000000   [ ] ASCII
Broadcast Key:        00000000000000000000000000000000   [ ] ASCII
[ ] Pre-established system      Signing: None
[ ] Ignore SNRM message
Dedicated Key: (空)             [ ] ASCII
Challenge: (空)
Invocation Counter: [ ] Read Automatically
Invocation Counter: (空)        Frame Counter LN: (空)
```

---

## 4. 报文原文（照抄，未改动）

> 说明：`TX/RX` 的视角在各段中不同，**只按字节内容判断方向**。
> Wrapper 头 = `00 01`(版本) + 源(2B) + 目的(2B) + 长度(2B)。

### 4.1 GXDLMSDirector 成功会话（Security = None，客户端 ST = "00000000"）

```
TX: 00 01 00 01 03 E9 00 4C 60 4A A1 09 06 07 60 85 74 05 08 01 01 A6 0A 04 08 30 30 30 30 30 30 30 30 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 64 0D 3B 4E 48 22 2F 58 22 16 51 2A 3B 08 03 79 BE 10 04 0E 01 00 00 00 06 5F 1F 04 00 62 1E 5D FF FF

RX: 00 01 03 E9 00 01 00 58 61 56 A1 09 06 07 60 85 74 05 08 01 01 A2 03 02 01 00 A3 05 A1 03 02 01 0E A4 0A 04 08 41 42 43 31 32 33 34 35 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 64 38 59 6A 36 26 50 17 3F 5C 18 31 58 30 5A 68 BE 10 04 0E 08 00 06 5F 1F 04 00 00 00 1D 04 00 00 07

（客户端日志：Authenticating.）
TX: 00 01 00 01 03 E9 00 20 C3 01 C1 00 0F 00 00 28 00 00 FF 01 01 09 11 10 00 00 00 00 A8 50 A1 0F FD 94 02 8D BF 4B BE 66

RX: 00 01 03 E9 00 01 00 19 C7 01 C1 00 01 00 09 11 10 00 00 00 00 44 CA F7 33 BD 2D 0B 36 6D A3 F2 F5
```

**这一段的 HLS 应答是明文 APDU（注意 `C3`）**：
```
C3 01 C1 00 0F 00 00 28 00 00 FF 01 | 09 11 | 10 | 00 00 00 00 | A8 50 A1 0F FD 94 02 8D BF 4B BE 66
↑↑ action-request                    | OCTET | SC  | IC          | 12 字节 GMAC
   类=0x000F(15, Association LN), OBIS=0.0.40.0.0.255, 方法=1
```
- `SC = 0x10` = **DLMS_SECURITY_AUTHENTICATION（仅认证，不加密）**
- `C3` = **明文** action-request（若加密则是 `CB`）

### 4.2 GXDLMSDirector 成功会话（Security = 仅认证，客户端 ST = "00000000"）

```
TX: 00 01 00 01 03 E9 00 5F 60 5D A1 09 06 07 60 85 74 05 08 01 03 A6 0A 04 08 30 30 30 30 30 30 30 30 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 64 06 44 07 2F 51 51 30 63 42 6D 58 04 51 3E 16 BE 23 04 21 21 1F 10 00 00 00 00 01 00 00 00 06 5F 1F 04 00 62 1E 5D FF FF 21 19 0A 97 C0 A6 CD 55 DF 5E 05 01

RX: 00 01 03 E9 00 01 00 6B 61 69 A1 09 06 07 60 85 74 05 08 01 03 A2 03 02 01 00 A3 05 A1 03 02 01 0E A4 0A 04 08 41 42 43 31 32 33 34 35 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 17 33 40 20 42 4A 27 5F 6F 03 0F 20 76 0F 42 26 BE 23 04 21 28 1F 10 00 00 00 00 08 00 06 5F 1F 04 00 00 00 1D 04 00 00 07 07 22 7E 9F 6E 3F 26 62 6D 8F 54 2E

TX: 00 01 00 01 03 E9 00 33 CB 31 10 00 00 00 01 C3 01 C1 00 0F 00 00 28 00 00 FF 01 01 09 11 10 00 00 00 01 9B 8E B7 3B BB 8A 6A 84 10 5C 9F 0F 1C 42 E1 38 62 19 0E 19 9A 88 A0 BB

RX: 00 01 03 E9 00 01 00 2C CF 2A 10 00 00 00 02 C7 01 C1 00 01 00 09 11 10 00 00 00 01 95 42 55 ED 8D 00 73 DC AD 8C 6F C2 1E 84 FE 0B 49 2E 0F D1 BE 55 AE 80
```
- 注意：**这一档（仅认证）GXDLMSDirector 用的应用上下文是 `…08 01 03`（带加密上下文）**，
  HLS 应答是 `CB`（glo-action，加密壳）里面套明文 `C3`，`SC=0x10`、`IC=1`。
- 而同样这批设备，**`Security=None` 那一档用的是 `…08 01 01`**，HLS 应答是**纯明文 `C3`**。
- 两档都成功。

### 4.3 GXDLMSDirector 成功会话（仅认证，客户端 ST = "ABC12345"）

```
TX: 00 01 00 01 03 E9 00 5F 60 5D A1 09 06 07 60 85 74 05 08 01 03 A6 0A 04 08 41 42 43 31 32 33 34 35 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 45 06 35 4B 10 76 35 6C 03 45 17 41 49 08 2F 63 BE 23 04 21 21 1F 10 00 00 00 00 01 00 00 00 06 5F 1F 04 00 62 1E 5D FF FF 0D 3F 3C 0C 11 8A 5A 32 DD F0 C5 17

RX: 00 01 03 E9 00 01 00 6B 61 69 A1 09 06 07 60 85 74 05 08 01 03 A2 03 02 01 00 A3 05 A1 03 02 01 0E A4 0A 04 08 41 42 43 31 32 33 34 35 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 37 15 0A 23 1A 38 12 6F 47 53 41 60 6B 71 70 22 BE 23 04 21 28 1F 10 00 00 00 00 08 00 06 5F 1F 04 00 00 00 1D 04 00 00 07 07 22 7E 9F 6E 3F 26 62 6D 8F 54 2E

（客户端日志：Authenticating.）
TX: 00 01 00 01 03 E9 00 33 CB 31 10 00 00 00 01 C3 01 C1 00 0F 00 00 28 00 00 FF 01 01 09 11 10 00 00 00 01 96 D7 1D 8E AE 49 7C 9D 20 D9 2F 2F 1A A0 2A 2E DB A3 1F 69 39 20 21 AC

RX: 00 01 03 E9 00 01 00 2C CF 2A 10 00 00 00 02 C7 01 C1 00 01 00 09 11 10 00 00 00 01 CA 09 90 19 CF A2 96 F2 28 35 6A B1 4E 02 1F DE 37 07 55 5D 64 CA 05 E9
```
→ **说明客户端 SystemTitle 用 "ABC12345" 也同样成功**。

### 4.4 App 失败会话 A（地址 1001 + ST "ABC12345" 已改对；应用上下文 `…01 01`）

```
TCP/IP connection established.
RX: 00 01 00 01 03 E9 00 4C 60 4A A1 09 06 07 60 85 74 05 08 01 01 A6 0A 04 08 41 42 43 31 32 33 34 35 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 D1 E8 74 3A 9D CE 67 33 19 8C 46 23 11 88 44 A2 BE 10 04 0E 01 00 00 00 06 5F 1F 04 00 40 1E 1D FF FF
TX: 00 01 03 E9 00 01 00 58 61 56 A1 09 06 07 60 85 74 05 08 01 01 A2 03 02 01 00 A3 05 A1 03 02 01 0E A4 0A 04 08 41 42 43 31 32 33 34 35 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 34 25 1B 38 5E 4E 21 25 45 75 4E 6D 19 29 31 0A BE 10 04 0E 08 00 06 5F 1F 04 00 00 00 1D 04 00 00 07
TCP/IP connection closed.
```
**现象**：表**接受**了 AARQ（`A2 03 02 01 00` = result 0 ✓，`A3 05 A1 03 02 01 0E` = diagnostic 14 = authentication-required ✓），
AARE 里也给了服务端挑战（`AA 12 80 10 …`）。
**但 App 之后没有发出任何 HLS 应答**，直接关闭连接 ✗。
App 侧显示：`建链失败（步骤 5 · HLS 应答生成）：Invalid parameter.`

### 4.5 App 失败会话 B（应用上下文 `…01 03`）

```
TCP/IP connection established.
RX: 00 01 00 01 03 E9 00 5F 60 5D A1 09 06 07 60 85 74 05 08 01 03 A6 0A 04 08 41 42 43 31 32 33 34 35 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 6D 36 1B 0D 86 C3 61 B0 58 2C 16 0B 85 C2 E1 70 BE 23 04 21 21 1F 10 00 00 00 00 01 00 00 00 06 5F 1F 04 00 40 1E 1D FF FF 05 58 BA 27 C7 87 4C 31 FB 56 D4 31
TX: 00 01 03 E9 00 01 00 58 61 56 A1 09 06 07 60 85 74 05 08 01 01 A2 03 02 01 01 A3 05 A1 03 02 01 01 A4 0A 04 08 41 42 43 31 32 33 34 35 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 29 69 1A 28 3D 3A 48 35 39 24 57 29 68 27 6D 51 BE 10 04 0E 08 00 06 5F 1F 04 00 00 00 1D 04 00 00 07
TCP/IP connection closed.
```
**现象**：表**永久拒绝**（`A2 03 02 01 01` = result 1，`A3 05 A1 03 02 01 01` = diagnostic 1），
且 AARE 回显的应用上下文是 `…08 01 01`（表明表要的是**不加密**上下文）。

### 4.6 更早的 App 侧抓包（HDLC 与 Wrapper 两种封装都失败）

用户曾提供 4 张 App 屏幕截图（`IMG_9231.PNG` ~ `IMG_9234.PNG`）与 `IMG_9237.PNG`，
其中可见 HDLC（`7E A0 …`）与 Wrapper（`00 01 …`）两种封装下都出现同一失败：
AARQ → AARE(authentication-required) → **无 HLS 应答** → 断链。

其中一帧（HDLC，App 侧）：
```
TX SNRM: 7E A0 07 03 03 93 8C 11 7E
RX UA  : 7E A0 1E 03 03 73 40 CC 81 80 12 05 01 80 06 01 80 07 04 00 00 00 01 08 04 00 00 00 01 53 3B 7E
TX AARQ: 7E A0 58 03 03 10 F0 C0 E6 E6 00 60 4A A1 09 06 07 60 85 74 05 08 01 01 A6 0A 04 08 41 42 43 30 31 32 33 34 8A 02 07 80 8B 07 60 85 74 05 08 02 05 AC 12 80 10 <16B> BE 10 04 0E 01 00 00 00 06 5F 1F 04 00 40 1E 1D FF FF
RX AARE: 7E A0 64 03 03 30 34 3A E6 E7 00 61 56 A1 09 06 07 60 85 74 05 08 01 01 A2 03 02 01 00 A3 05 A1 03 02 01 0E A4 0A 04 08 48 58 45 03 00 00 14 88 88 02 07 80 89 07 60 85 74 05 08 02 05 AA 12 80 10 <16B> BE 10 04 0E 08 00 06 5F 1F 04 00 40 1C 1D 00 7D 00 07 F5 EA 7E
```
（该帧的 FCS 已用 CRC-16/X-25 独立验算：UA 算出 `3B53` 与抓包一致 ✓）

---

## 5. 已经由报文确认的事实

1. **链路层、AARQ/AARE 结构、机制 OID 都没问题**：
   双方 mechanism-name 都是 `60 85 74 05 08 02 05`（= HIGH_GMAC(5)）✓
2. **表要的是"不加密"上下文** `…08 01 01`：
   当 App 发 `…01 03` 时，表回 result=1（永久拒绝）并回显 `…01 01`（§4.5）；
   当 App 发 `…01 01` 时，表接受并进入认证阶段（§4.4）✓
3. **`Security = None` 在 .NET 客户端下完全可用**：
   GXDLMSDirector §4.1 全程明文（`…01 01` + 明文 `C3` + `SC=0x10` + 12B GMAC），可正常抄表 ✓
4. **App 的失败点固定在第 5 步（HLS 应答生成）**，错误码 `INVALID_PARAMETER`；
   此时**一个字节都没发出去**（报文可见）✓
5. **客户端 SystemTitle 不是问题**：`00000000`、`ABC12345` 都能通 ✓
6. **GUAK/GUEK 全 0 也能通**（GXDLMSDirector 侧就是全 0）✓

---

## 6. 库源码定位（vendored Gurux.DLMS.c，均已实际读过）

| 位置 | 内容 |
|---|---|
| `Sources/DLMSCore/C/src/client.c:411` | `cl_getApplicationAssociationRequest()` —— 生成 HLS 应答（第 5 步） |
| `Sources/DLMSCore/C/src/client.c:429` | 该函数开头：`if (authentication != HIGH_ECDSA && authentication != HIGH_GMAC && password.size == 0) return INVALID_PARAMETER;`（`DLMS_IGNORE_HIGH_GMAC` **未定义**，故此路对本问题不生效） |
| `Sources/DLMSCore/C/src/client.c:440-448` | GMAC 时 `pw = &settings->cipher.systemTitle`（**客户端自己的 SystemTitle** 作为 GMAC 的 secret） |
| `Sources/DLMSCore/C/src/client.c:482` | `dlms_secure(settings, settings->cipher.invocationCounter, &settings->stoCChallenge, pw, &challenge)` |
| `Sources/DLMSCore/C/src/dlms.c:6589` | `dlms_secure()` |
| `Sources/DLMSCore/C/src/dlms.c:6676` | HIGH_GMAC 分支：`cip_encrypt(&settings->cipher, DLMS_SECURITY_AUTHENTICATION, DLMS_COUNT_TYPE_TAG, ic, GET_AUTH_TAG(cipher), secret->data, &cipher.blockCipherKey, data)` ← **显式传了 `DLMS_SECURITY_AUTHENTICATION`** |
| **`Sources/DLMSCore/C/src/ciphering.c:681`** | **`cip_encrypt()` 内的守卫**：`if (settings->security == DLMS_SECURITY_NONE \|\| bb_available(&settings->authenticationKey) != keySize) return DLMS_ERROR_CODE_INVALID_PARAMETER;` ← **看的是结构体字段 `settings->security`，而不是函数收到的 `security` 参数** |
| `Sources/DLMSCore/C/include/ciphering.h:125` | `cip_encrypt()` 是**公开接口**（可从桥接层直接调用） |
| `Sources/DLMSCore/C/include/gxaes.h:56` | `gxaes_encrypt(aes, data, secret, out)` —— 只有 AES 分组加密，**没有 GCM 的 AAD/tag**，不足以自己实现 GMAC |
| `Sources/DLMSCore/C/src/dlms.c:2305` | `dlms_getServerAddress()`：`address < 0x4000` 时 `logical=v>>7, physical=v&0x7F`；否则 `logical=v>>14, physical=v&0x3FFF` |
| `Sources/DLMSCore/C/src/dlms.c:2420-2445` | HDLC 地址编码（7bit/字节 + bit0 扩展位），**长度按数值大小自动选**：`<0x80`→1B、`<0x4000`→2B、否则→4B |
| `Sources/DLMSCore/C/include/enums.h:1203/1208/1223` | `SNRM=0x93` / `UA=0x73` / `DISC=0x53` |
| `Sources/DLMSCore/C/include/enums.h:736` | `DLMS_SECURITY`：`NONE=0 / AUTHENTICATION=0x10 / ENCRYPTION=0x20 / AUTHENTICATION_ENCRYPTION=0x30` |

**桥接层现状**（`Sources/DLMSCore/Bridge/DLMSBridge.c`）：
- `dlms_new()` → `cl_init(..., (DLMS_AUTHENTICATION)authentication, ...)`
- `dlms_set_security(ctx, security, blockCipherKeyHex, authenticationKeyHex, dedicatedKeyHex)`
  → 分别写入 `cipher.blockCipherKey` / `cipher.authenticationKey` / `cipher.dedicatedKey`，并设 `cipher.security = security`
- `dlms_initialize()`：HDLC 走 SNRM/UA → AARQ/AARE → HLS；Wrapper 跳过 SNRM/UA；
  HLS 段为 `if (authentication > DLMS_AUTHENTICATION_LOW) { cl_getApplicationAssociationRequest(); dlmsReadDataBlock(); cl_parseApplicationAssociationResponse(); }`
- 诊断接口：`dlms_lastStep()` / `dlms_sendFailed()` / `dlms_step_name()`（用于定位失败步骤）

---

## 7. ⚠️ 我走过的错误假设（请勿重复）

排查过程中我提出过以下结论，**均已被报文证伪**：

| 错误假设 | 证伪依据 |
|---|---|
| ~~两端 mechanism OID 不一致（`02 02` vs `02 05`）~~ | 委托方重新读图后确认**两边都是 `02 05`**；是我**读截图十六进制读错** |
| ~~HLS 必须带"加密位"（只有 0x20/0x30 能通）~~ | §4.1 证明 `Security=None` 全程明文也能通 |
| ~~库不支持 `NONE`（结论层面）~~ | 表述不当：库**确实**在 `security==NONE` 时拒绝算 GMAC，但那**不是协议要求**；`.NET` 无此限制 |
| ~~客户端 SystemTitle 应填 `00000000`~~ | §4.3 证明 `ABC12345` 也能通 |
| ~~地址/SystemTitle 是 AARQ 被拒的原因~~ | 改对后表确实接受了 AARQ（§4.4），真正的卡点是紧接着的 HLS 应答生成 |
| ~~必须调用加密机制才能算 GMAC，所以无法"直接组报文"~~ | 表述错误：GMAC 是**认证标签**，明文 APDU 后面照常可以带（§4.1 即如此）。只是库把"算标签"和"会话加密"绑在了一起 |

**另一个方法论教训**：我曾试图用手抄的截图报文做本地回放测试，
但 **AARE 的 FCS 怎么改都对不上（至少两处抄错）** → **不要回放手工转录的报文**，
应自己构造合法帧（内容自己写 + 用 CRC-16/X-25 算 FCS；
FCS16 算法已用现场 UA 帧验证：poly `0x8408`、init `0xFFFF`、末尾取反、低字节先发）。

---

## 8. 根因与最终修法（**已选 (b) 并实施**；3fd01ee 的错误补丁已撤回）

**根因（源码级，已核验）**：`cipher.security` 这一个字段**同时管两件事**：

| 作用 | 判定位置 | 行为 |
|---|---|---|
| ① APDU 是否加密打包 | `dlmsSettings.c:439` `isCiphered()` = `security != NONE` | `apdu.c:161` 决定应用上下文 `…08 01 01 / 03`；`dlms.c` 决定 action-request 打成 `C3` 还是 `CB` |
| ② 能否算 GMAC | `ciphering.c:681` 守卫 `settings->security == NONE → INVALID_PARAMETER` | 即使 `dlms.c:6676` 的 `dlms_secure()` 已**显式传入** `DLMS_SECURITY_AUTHENTICATION`，仍被这道"查会话整体"的守卫拒掉 |

→ `NONE` → 算不出 GMAC（步骤 5 报错）；改成 `0x10` → 能算了，但 `isCiphered()=true`，整条会话被当成"已加密"，上下文变 `…01 03`、报文变 `CB`，被本表永久拒绝。`.NET` 库没有这道守卫，所以 GXDLMSDirector 用 None+GMAC 照跑。vendored 副本与上游**逐字节一致**（SHA256 核过），不是移植缺失。

### 已撤回的错误补丁（3fd01ee，**勿再使用**）

第一版做法是"在 `cl_getApplicationAssociationRequest` 之前临时置 0x10、之后还原"。**注释里写错了 `isCiphered()` 的行为**：误以为 0x10 不含加密位 → false，实际 `isCiphered()` 就是 `security != NONE`（`dlmsSettings.c:439`），0x10 时为 **true**。
后果：临时置 0x10 后**没有在打包前还原** → 库内部打包 HLS 应答时仍把它当加密 → 打成 `CB … C3 …`（glo-action）→ 表收到不认识的加密壳 → 回错误应答 → 关闭。
**现场实测表现**：NONE 报错"老样子"，但报文里能看到 HLS 应答发出去了（`CB 31 10 … C3 01 C1 00 0F …`）—— 说明 GMAC 算出来了，**只是被打包成加密壳了**。这就是 3fd01ee 的直接错误。

### 最终修法 (b)：桥接层切开"算 GMAC"与"打包"（已实施，3fd01ee 被覆盖）

`dlms_secure`（`dlms.h:274`）和 `cl_methodLN`（`client.h:350`）都是公开接口。
**只在调 `dlms_secure` 那一刻临时置 0x10、调完立刻还原**；打包时 `security` 已回 NONE → `isCiphered()=false` → 明文 `C3`。

```c
DLMS_SECURITY savedSecurity = c->settings.cipher.security;

/* ① 算 GMAC：只在这一刻临时置 0x10，过 ciphering.c:681 守卫 */
gxByteBuffer challenge;  bb_init(&challenge);
c->settings.cipher.security = DLMS_SECURITY_AUTHENTICATION;
ret = dlms_secure(&c->settings,
                  (int32_t)c->settings.cipher.invocationCounter,
                  &c->settings.stoCChallenge,            /* 服务端挑战 */
                  &c->settings.cipher.systemTitle,       /* secret = 客户端 ST */
                  &challenge);                           /* → SC+IC+GMAC = 17B */
c->settings.cipher.security = savedSecurity;             /* ★ 立刻还原 */

/* ② 打包：security 已是 NONE → isCiphered()=false → 明文 C3，不是 CB */
dlmsVARIANT data; var_init(&data);
data.vt = DLMS_DATA_TYPE_OCTET_STRING; data.byteArr = &challenge;
static const unsigned char LN[6] = {0,0,40,0,0,255};
ret = cl_methodLN(&c->settings, LN, DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME, 1, &data, &msg);
var_clear(&data); bb_clear(&challenge);

/* ③ 发送 + 收尾：parse 内部也会调 dlms_secure，再开一次 0x10 窗口（无出向 APDU）*/
ret = dlmsReadDataBlock(c, &msg, &reply);
c->settings.cipher.security = DLMS_SECURITY_AUTHENTICATION;
ret = cl_parseApplicationAssociationResponse(&c->settings, &reply.data);
c->settings.cipher.security = savedSecurity;
```

产出报文逐字段应等于 §4.1：`C3 01 C1 00 0F 00 00 28 00 00 FF 01 01 09 11 10 <IC:4B> <12B>`。
若用户真选了加密（`security != NONE`），走原 `cl_getApplicationAssociationRequest` 路径，不受影响。

### 备选 (a)（未采用）

把 `ciphering.c:681` 的 `settings->security` 改成形参 `security`（一行）。语义最正，但动 vendor 库、要脚本化维护，故未选。

### 验证标准

- 本地桩测：自造合法 AARE（不回放手工转录报文），`security=NONE` 跑一遍，断言出向是 `C3` 而非 `CB`，且 `dlms_lastStep()` 不再停在"步骤 5"
- 基准只认 §4.1。§4.2/§4.3 的 `01 03` 成功样本**不适用于本表**（§4.5 已证伪）
- GUAK 必须 16 字节（守卫第二条同样会报 INVALID_PARAMETER）；Swift 侧传的是 `guakEffective`，理论上 OK，上真表前建议把 `bb_available(authenticationKey)` 打进日志确认一次
- IC 初值：`cip_init` 设 0，与 §4.1 的 `IC=0` 一致

---

## 9. 仍然开放的问题

1. **GMAC 的输入与 .NET 是否完全一致**：
   `.NET` 用 `Challenge = 空` + `InvocationCounter` 未读自动 → 报文里 `IC = 0`；
   App 侧 `cipher.invocationCounter` 的初值是多少？会不会导致 GMAC 不同？
   （库 `cip_init` 设 0、`cip_clear` 设 1，两者不一致——需要确认 App 走的是哪个）
2. **`authenticationKey`（GUAK）长度**：`cip_encrypt` 还要求 `bb_available(authenticationKey) == 16`（Suite0）；
   App 侧若填了非 16 字节的值，会报**同一个错**，需要排除
3. **本表对 `…01 03` 的态度**：§4.2/§4.3 显示同款表（同 SystemTitle）在 .NET 下接受 `…01 03` 且成功，
   但 §4.5 中 App 发 `…01 03` 却被永久拒绝 —— 这个差异**尚未解释**
   （可能是地址/其它字段差异，也可能是表对某些组合敏感；需要同状态下的对照抓包）
4. 表侧是否要求 `SC` 之外的字段完全一致（如 `IC` 必须为 0 / 必须递增）

---

## 10. 给接手方的建议下一步

1. **先在本地复现**（不需要真表）：用桩 `send/recv` + **自己构造**的合法 AARE
   （结构照 §4.4 的 AARE，FCS 自算），跑 `dlms_initialize`，
   分别用 `security = NONE / 0x10 / 0x20 / 0x30`，打印 `dlms_lastStep()` 与错误码。
   → 可精确复现"步骤 5 · INVALID_PARAMETER"，并验证修法是否有效（本地可迭代，比现场快得多）
2. 用 §4.1 的成功报文作为**逐字段对照基准**
3. 若选择修法 (b)，注意 `cip_encrypt` 是公开接口（`ciphering.h:125`），可直接调用
