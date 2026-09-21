//
//  DLMSCore.h
//  桥接头：Swift 唯一可见的 C 面。封装 vendored Gurux.DLMS.c 客户端
//  （HDLC/Wrapper 帧、COSEM APDU、OBIS get/set/action、建链/认证）。
//
//  职责分界：Swift 只做 TCP 传输与 UI；所有组帧/解析/建链状态机在本 C 层。
//  同步驱动：C 通过 send/recv 回调阻塞收发（见 GXDLMSTransport.swift）。
//  超时由 Swift socket 层承担（本层不做超时）。
//

#ifndef DLMSCore_h
#define DLMSCore_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque DLMS client context.
typedef struct dlmsCtx dlmsCtx;

// I/O 回调，Swift 实现（见 GXDLMSTransport.swift）。`user` 传 dlms_set_io 的 user。
//   send:    发送 len 字节。返回 0 成功，<0 失败。
//   receive: 读最多 cap 字节到 buf，写实际字节数到 *got（成功连接上不得为 0）。
//            返回 0 成功，<0 失败。
typedef int (*dlmsSendFn)(void* user, const unsigned char* data, int len);
typedef int (*dlmsRecvFn)(void* user, unsigned char* buf, int cap, int* got);

// trace 回调：direction 1=TX / 2=RX；frame 是补拼后的完整原始帧字节。
typedef void (*dlmsTraceFn)(void* user, int direction, const unsigned char* frame, int len);

// 认证：0=NONE 1=LOW 2=HIGH 3=HIGH_MD5 4=HIGH_SHA1 5=HIGH_GMAC 6=HIGH_SHA256 7=HIGH_ECDSA
// 信息加密(DLMS_SECURITY)：0=NONE 0x10=AUTHENTICATION 0x20=ENCRYPTION 0x30=AUTHENTICATION_ENCRYPTION
// 封装：0=HDLC 1=WRAPPER
dlmsCtx* dlms_new(int useLogicalNameReferencing,
                  uint16_t clientAddress,
                  uint32_t serverAddress,
                  int authentication,
                  const char* password,          // LLS 密码（可空，authentication=LOW 时用）
                  int interfaceType);

void dlms_free(dlmsCtx* ctx);

// 安全配置（须在 dlms_initialize 前调用；可多次调用覆盖）。
//   security: DLMS_SECURITY 值（见上）。
//   三个密钥 hex 的落点。**参数名已与语义对齐**（v1.5 前叫 akekHex / authKeyHex / ekHex，
//   名字与含义不符：`akekHex` 装的其实是 GUEK。两者都是 16 字节 hex，编译器拦不住传反，
//   只会表现为"建链失败且难排查"，所以改名而不是靠注释澄清）：
//     blockCipherKeyHex    → settings->cipher.blockCipherKey     （加密密钥；UI 的 GUEK）
//     authenticationKeyHex → settings->cipher.authenticationKey  （认证密钥；UI 的 GUAK）
//     dedicatedKeyHex      → settings->cipher.dedicatedKey       （预留；UI 暂不提供）
//   任一项传 NULL/空 → 该项保持库内现值，不覆盖。
//   注：C 参数名不影响 Swift 侧的位置调用，改名不需要改 Swift。
void dlms_set_security(dlmsCtx* ctx, int security,
                       const char* blockCipherKeyHex, const char* authenticationKeyHex,
                       const char* dedicatedKeyHex);

// 客户端自己的 SystemTitle(8B) hex → settings->cipher.systemTitle。须在 AARQ 之前设置（认证=HLS 时必填）。
// 空 / 非法 / 不足 8 字节时置 8 字节零。应用层留空时由 ConnectionConfig 回退到默认 8 字节。
void dlms_set_clientSystemTitle(dlmsCtx* ctx, const char* hex);

// IC：读/写 settings->cipher.invocationCounter（无公开 setter，直接赋值）。
uint32_t dlms_get_invocationCounter(dlmsCtx* ctx);
void     dlms_set_invocationCounter(dlmsCtx* ctx, uint32_t value);

// 服务器 SystemTitle（由 AARE 自动回填到 settings->sourceSystemTitle）。outLen 入=容量/出=长度(≤8)。
int dlms_get_serverSystemTitle(dlmsCtx* ctx, unsigned char* out, int* outLen);

// 绑定 IO 与 trace 回调（任何操作前调用）。
void dlms_set_io(dlmsCtx* ctx, void* user, dlmsSendFn send, dlmsRecvFn receive);
void dlms_set_trace(dlmsCtx* ctx, void* user, dlmsTraceFn trace);

// 建链：按 interfaceType 分支(HDLC: SNRM/UA → AARQ/AARE；Wrapper: 直连 AARQ/AARE)，
// 认证>LOW 时追加 HLS challenge。返回 0 成功。
int dlms_initialize(dlmsCtx* ctx);

// 读属性(attr=2 值 / attr=3 scaler_unit)。obis=6字节。out 收 NUL 结尾字符串。
//   outLen 入=容量/出=写入字节数(含 NUL)；返回 0 成功。
int dlms_read(dlmsCtx* ctx, const unsigned char* obis, uint16_t type, unsigned char attr,
              char* out, int* outLen);

// 写(byteArray=1 直传)：hex 为请求数据的 HEX 字节串(e.g. "11 01"，可空→数据区空)。
// 返回 0 成功；out 写入响应（可空）。
int dlms_write(dlmsCtx* ctx, const unsigned char* obis, uint16_t type, unsigned char attr,
               const char* hex, char* out, int* outLen);

// 执行方法(index)：hex 为空→NULL variant（无参）；否则按 P1 tag 集解析为 variant。
int dlms_method(dlmsCtx* ctx, const unsigned char* obis, uint16_t type, unsigned char index,
                const char* hex, char* out, int* outLen);

// 断链：先 RLRQ(security!=NONE 时受保护 release) 再 DISC，返回 0 成功。
int dlms_disconnect(dlmsCtx* ctx);

// 错误码转可读字符串（静态存储）。
const char* dlms_error_string(int code);

// ── 诊断查询（v1.5 新增）───────────────────────────────────────────────
// 背景：报文日志里**看不到"发送失败"** —— dlmsSendFrame 的 trace 只在发送成功后才调用。
// 所以只凭报文无法区分：(a) 请求没生成出来 (b) 生成出来了但 send 失败 (c) 发出去了但 recv 超时。
// 这三个接口把差别补上：
//   dlms_lastStep()   失败发生在 dlms_initialize 的哪一步（0 = 未开始）
//   dlms_sendFailed() 最近一次 send 是否失败（1 = 发不出去）
//   dlms_step_name()  步骤号 → 可读名称（静态字符串，中文）
int dlms_lastStep(dlmsCtx* ctx);
int dlms_sendFailed(dlmsCtx* ctx);
const char* dlms_step_name(int step);

#ifdef __cplusplus
}
#endif

#endif /* DLMSCore_h */