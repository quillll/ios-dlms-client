//
//  DLMSBridge.c
//  在 vendored Gurux.DLMS.c 上层实现 DLMSCore.h 声明的客户端面。
//  所有组帧/APDU/建链状态机都在这里；Swift 仅通过 send/recv 回调提供 TCP 字节。
//
//  v1.2 要点：
//   - 接收缓冲为 ctx 上跨 recv 持久化的累积缓冲，追加语义（见 bufAppend 里为何
//     不能用 bb_insert），不覆盖(bb_set)，
//     容量按需增长，杜绝大 PDU 分段丢帧(R10/R11)。
//   - 建链按 interfaceType 分支，Wrapper 不发 SNRM(R18)；认证>LOW 追加 HLS challenge(R12)。
//   - 断链先 RLRQ(release2) 再 DISC(M1)。
//   - 写走 byteArray=1 + bb_addHexString 直传(E1)。
//

#include "DLMSCore.h"

#include "client.h"
#include "dlmssettings.h"
#include "dlms.h"
#include "enums.h"
#include "errorcodes.h"
#include "message.h"
#include "replydata.h"
#include "bytebuffer.h"
#include "gxmem.h"
#include "variant.h"
#include "date.h"
#include "helpers.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>

// The DLMS library requires the application to supply the current time.
void time_now(gxtime* value)
{
    time_initUnix(value, (unsigned long)time(NULL));
}

struct dlmsCtx
{
    dlmsSettings settings;
    gxByteBuffer rx;               // 跨 recv 持久化的接收累积缓冲
    void* user;
    dlmsSendFn send;
    dlmsRecvFn recv;
    dlmsTraceFn trace;
    void* traceUser;
    // ── 诊断字段（v1.5 加）──────────────────────────────────────────────
    // 起因：现场日志只报 "Data receive failed"，无法区分下面三种情况：
    //   (a) 请求压根没生成出来   (b) 生成出来了但 send 失败   (c) 发出去了但 recv 超时
    // 而 dlmsSendFrame 的 trace 只在**发送成功之后**才调用，
    // 所以 (b) 这条路径在报文日志里一个字节都不留 —— 必须单独记。
    int lastStep;                  // dlms_initialize 卡在哪一步（见 DLMS_STEP_*）
    int sendFailed;                // 最近一次 dlmsSendFrame 的 send 是否失败
};

// dlms_initialize 的步骤号。应用层据此把"建链失败"细化成"第几步失败"。
enum
{
    DLMS_STEP_NONE = 0,
    DLMS_STEP_SNRM_REQUEST,        // 1 生成 SNRM 请求
    DLMS_STEP_SNRM_RESPONSE,       // 2 SNRM 收发 + 解析 UA
    DLMS_STEP_AARQ_REQUEST,        // 3 生成 AARQ
    DLMS_STEP_AARE_RESPONSE,       // 4 AARQ 收发 + 解析 AARE
    DLMS_STEP_HLS_REQUEST,         // 5 生成 HLS 应答（0.0.40.0.0.255 method 1）
    DLMS_STEP_HLS_RESPONSE         // 6 HLS 应答收发 + 解析
};

// 追加到 rx 末尾，必要时先扩容。
// 单帧累积字节上限。
// `DLMS_MAX_RECV_ROUNDS` 只约束"收几轮"、约束不了"收多少字节"：异常对端持续吐数据时
// rx 缓冲会一直增长。256KB 远超任何合法单帧（maxPduSize 一般 ≤ 64KB，
// 且按 1448B 分段也才 ~45 轮），所以只在异常情况下触发。
#define DLMS_MAX_RX_BYTES (256u * 1024u)

static int bufAppend(dlmsCtx* c, const unsigned char* src, uint32_t len)
{
    if (len == 0)
    {
        return 0;
    }
    gxByteBuffer* rx = &c->rx;
    if (rx->size + len > DLMS_MAX_RX_BYTES)
    {
        return DLMS_ERROR_CODE_RECEIVE_FAILED;
    }
    if (rx->size + len > rx->capacity)
    {
        int r = bb_capacity(rx, rx->size + len + 256);
        if (r != 0)
        {
            return r;
        }
    }
    // ⚠️ 这里**不能**用 bb_insert 做追加 —— 它并不是"追加"语义：
    //     · 实现是 memmove(target->data + index, src + index, count)，
    //       第四个参数 index 同时被当作「目标插入点」和「**源数据偏移**」；
    //     · 而且它**不更新 target->size**。
    //    库里所有调用都传 index=0（bb_insert(LLC_REPLY_BYTES, 3, data, 0) 等），
    //    此时 memmove 才退化为正确的 (dst, src, count)。
    //    我们原来传的是 index = rx->size(≠0) → 源偏移错 + size 永不增长
    //    → 表现为"响应一旦被 TCP 拆开就再也收不全"（长数据无法交互的根因）。
    //    改为手工追加，语义一目了然。
    memcpy(rx->data + rx->size, src, len);
    rx->size += len;
    return 0;
}

// 单帧接收的**总轮次上限**。
//
// 为什么必须有：下面的 do-while 只有两个退出条件 —— ① recv 连续失败 4 次；
// ② reply->complete 置位。而 `fail` 在"收到数据"时会被归零（见循环内 D2 的说明），
// 于是**对端只要持续有字节到达、却始终构不成一个会被接受的帧**（垃圾数据、别的表的
// 应答、共享 TCP 流上的其它报文、或帧号/CRC 校验不过的帧），两个条件就都不成立 →
// 无限循环，而且 rx 缓冲每轮都在追加 → 内存持续增长。
// 真机上这是"异常对端/弱网"场景，会让 App 卡死（不是报错）；本地表现为测试挂住。
// 256 轮远大于正常需求（64KB 响应按 1448B 分段也才 ~45 轮），不会误伤大帧。
#define DLMS_MAX_RECV_ROUNDS 256

// 发送一个请求缓冲，循环接收直到 reply->complete（Gurux readDLMSPacket 逻辑）。
static int dlmsSendFrame(dlmsCtx* c, gxByteBuffer* data, gxReplyData* reply)
{
    int ret, fail = 0;
    int rounds = 0;
    if (data->size == 0)
    {
        return DLMS_ERROR_CODE_OK;
    }
    // 新请求重置接收游标（保留容量以复用）。
    c->rx.size = 0;
    c->rx.position = 0;
    reply->complete = 0;

    if (c->send(c->user, data->data, (int)data->size) != 0)
    {
        // 记下来：这次 send 失败。报文日志里看不到它（trace 在成功后才有），
        // 只能靠这个标志让应用层区分"发不出去"和"发出去没回应"。
        c->sendFailed = 1;
        return DLMS_ERROR_CODE_SEND_FAILED;
    }
    c->sendFailed = 0;
    if (c->trace != NULL)
    {
        c->trace(c->traceUser, 1, data->data, (int)data->size);
    }

    gxReplyData notify;
    reply_init(&notify);
    unsigned char isNotify = 0;
    unsigned char tmp[2048];

    do
    {
        int got = 0;
        if (++rounds > DLMS_MAX_RECV_ROUNDS)
        {
            // 有字节持续到达但始终构不成一帧 → 有界退出（防死循环 + 内存增长）。
            ret = DLMS_ERROR_CODE_RECEIVE_FAILED;
            break;
        }
        if (c->recv(c->user, tmp, (int)sizeof(tmp), &got) != 0 || got <= 0)
        {
            if (++fail > 3)
            {
                ret = DLMS_ERROR_CODE_RECEIVE_FAILED;
                break;
            }
            // D1：重发前必须丢掉已累积的残帧 —— 重发在语义上是「重新收一遍」。
            // 否则本次已收到的半截字节会和新响应拼在一起，cl_getData2 会解析出坏帧。
            // 触发条件是「大帧需要多次 recv 且中途超时」，弱网下最难排查的那类偶发失败。
            // 这里刻意与函数开头的「新请求重置」保持一致：只重置接收缓冲与 complete，
            // **不动 reply 的累积数据** —— more-data 序列里 reply 是跨帧复用的，
            // 清掉它会丢掉前面几帧已解析出的数据。
            c->rx.size = 0;
            c->rx.position = 0;
            reply->complete = 0;
            // 重发（Gurux 例程行为）。
            if (c->send(c->user, data->data, (int)data->size) != 0)
            {
                c->sendFailed = 1;
                ret = DLMS_ERROR_CODE_SEND_FAILED;
                break;
            }
            c->sendFailed = 0;
            continue;
        }
        if (c->trace != NULL)
        {
            c->trace(c->traceUser, 2, tmp, got);
        }
        // D2：收到数据即视为「本轮成功」，失败计数归零。
        // 原来 fail 只在 recv 失败时自增、成功路径从不归零，于是
        // 「整帧生命周期内累计 3 次瞬时超时」就会被当成致命失败提前中止
        // —— 抖动链路上会过早放弃本可抄成功的读。
        fail = 0;
        if ((ret = bufAppend(c, tmp, (uint32_t)got)) != 0)
        {
            break;
        }
        ret = cl_getData2(&c->settings, &c->rx, reply, &notify, &isNotify);
        if (ret != 0 && ret != DLMS_ERROR_CODE_FALSE)
        {
            break;
        }
    } while (reply->complete == 0);

    reply_clear(&notify);
    return ret;
}

// 发送（可能多帧的）请求并处理 more-data（Gurux readDataBlock 逻辑）。
static int dlmsReadDataBlock(dlmsCtx* c, message* messages, gxReplyData* reply)
{
    int pos, ret = DLMS_ERROR_CODE_OK;
    if (messages->size == 0)
    {
        return DLMS_ERROR_CODE_OK;
    }
    gxByteBuffer rr;
    bb_init(&rr);
    for (pos = 0; pos < (int)messages->size; ++pos)
    {
        ret = dlmsSendFrame(c, messages->data[pos], reply);
        if (ret != DLMS_ERROR_CODE_OK)
        {
            break;
        }
        while (reply_isMoreData(reply))
        {
            ret = cl_receiverReady(&c->settings, reply->moreData, &rr);
            if (ret != DLMS_ERROR_CODE_OK)
            {
                break;
            }
            ret = dlmsSendFrame(c, &rr, reply);
            bb_clear(&rr);
            if (ret != DLMS_ERROR_CODE_OK)
            {
                break;
            }
        }
        if (ret != DLMS_ERROR_CODE_OK)
        {
            break;
        }
    }
    return ret;
}

dlmsCtx* dlms_new(int useLogicalNameReferencing,
                  uint16_t clientAddress,
                  uint32_t serverAddress,
                  int authentication,
                  const char* password,
                  int interfaceType)
{
    dlmsCtx* c = (dlmsCtx*)calloc(1, sizeof(dlmsCtx));
    if (c == NULL)
    {
        return NULL;
    }
    bb_init(&c->rx);
    const char* pwd = password != NULL ? password : "";
    cl_init(&c->settings,
            (unsigned char)(useLogicalNameReferencing ? 1 : 0),
            clientAddress,
            serverAddress,
            (DLMS_AUTHENTICATION)authentication,
            pwd,
            (DLMS_INTERFACE_TYPE)interfaceType);
    return c;
}

void dlms_free(dlmsCtx* c)
{
    if (c != NULL)
    {
        cl_clear(&c->settings);
        bb_clear(&c->rx);
        free(c);
    }
}

// ── 诊断查询（v1.5 新增）──────────────────────────────────────────────
// 现场日志只报 "Data receive failed" 时，靠这三个函数才知道卡在哪一步、是不是发送失败。
// 建议展示成：建链失败（步骤 5 · HLS 应答生成）：<dlms_error_string(code)>
// 其中若 dlms_sendFailed() 为 1，说明是**发不出去**；否则是发出去但没等到回应。
// （报文日志天然看不到"send 失败"——trace 只在发送成功后调用。）

int dlms_lastStep(dlmsCtx* c)
{
    return (c == NULL) ? 0 : c->lastStep;
}

int dlms_sendFailed(dlmsCtx* c)
{
    return (c == NULL) ? 0 : c->sendFailed;
}

// 接收缓冲的 size/position（只读诊断）。见 DLMSCore.h 的说明。
int dlms_rxSize(dlmsCtx* c)
{
    return (c == NULL) ? 0 : (int)c->rx.size;
}

int dlms_rxPosition(dlmsCtx* c)
{
    return (c == NULL) ? 0 : (int)c->rx.position;
}

const char* dlms_step_name(int step)
{
    switch (step)
    {
    case DLMS_STEP_SNRM_REQUEST:  return "SNRM 请求生成";
    case DLMS_STEP_SNRM_RESPONSE: return "SNRM/UA 收发";
    case DLMS_STEP_AARQ_REQUEST:  return "AARQ 生成";
    case DLMS_STEP_AARE_RESPONSE: return "AARQ/AARE 收发";
    case DLMS_STEP_HLS_REQUEST:   return "HLS 应答生成";
    case DLMS_STEP_HLS_RESPONSE:  return "HLS 应答收发";
    default:                      return "未开始";
    }
}

// 解析 hex 字符串（含空格）至 gxByteBuffer；返回 0 成功。
static int hexToBytes(gxByteBuffer* out, const char* hex)
{
    if (hex == NULL || *hex == '\0')
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    return bb_addHexString(out, hex) == 0 ? DLMS_ERROR_CODE_OK : DLMS_ERROR_CODE_INVALID_PARAMETER;
}

void dlms_set_security(dlmsCtx* c, int security,
                       const char* blockCipherKeyHex, const char* authenticationKeyHex,
                       const char* dedicatedKeyHex)
{
    if (c == NULL)
    {
        return;
    }
    c->settings.cipher.security = (DLMS_SECURITY)security;
    gxByteBuffer key;
    if (blockCipherKeyHex != NULL && *blockCipherKeyHex != '\0')
    {
        bb_init(&key);
        if (hexToBytes(&key, blockCipherKeyHex) == DLMS_ERROR_CODE_OK)
        {
            bb_clear(&c->settings.cipher.blockCipherKey);
            bb_set(&c->settings.cipher.blockCipherKey, key.data, key.size);
        }
        bb_clear(&key);
    }
    if (authenticationKeyHex != NULL && *authenticationKeyHex != '\0')
    {
        bb_init(&key);
        if (hexToBytes(&key, authenticationKeyHex) == DLMS_ERROR_CODE_OK)
        {
            bb_clear(&c->settings.cipher.authenticationKey);
            bb_set(&c->settings.cipher.authenticationKey, key.data, key.size);
        }
        bb_clear(&key);
    }
    if (dedicatedKeyHex != NULL && *dedicatedKeyHex != '\0')
    {
        bb_init(&key);
        if (hexToBytes(&key, dedicatedKeyHex) == DLMS_ERROR_CODE_OK)
        {
            if (c->settings.cipher.dedicatedKey == NULL)
            {
                c->settings.cipher.dedicatedKey = (gxByteBuffer*)gxmalloc(sizeof(gxByteBuffer));
                if (c->settings.cipher.dedicatedKey != NULL)
                {
                    bb_init(c->settings.cipher.dedicatedKey);
                }
            }
            if (c->settings.cipher.dedicatedKey != NULL)
            {
                bb_clear(c->settings.cipher.dedicatedKey);
                bb_set(c->settings.cipher.dedicatedKey, key.data, key.size);
            }
        }
        bb_clear(&key);
    }
}

void dlms_set_clientSystemTitle(dlmsCtx* c, const char* hex)
{
    if (c == NULL)
    {
        return;
    }
    gxByteBuffer st;
    bb_init(&st);
    if (hex != NULL && *hex != '\0' && hexToBytes(&st, hex) == DLMS_ERROR_CODE_OK && st.size >= 8)
    {
        bb_clear(&c->settings.cipher.systemTitle);
        bb_set(&c->settings.cipher.systemTitle, st.data, 8);
    }
    else
    {
        // 空/非法则置 8 字节零（HLS 时仍应显式设置）。
        bb_clear(&c->settings.cipher.systemTitle);
        static const unsigned char zeros[8] = {0};
        bb_set(&c->settings.cipher.systemTitle, zeros, 8);
    }
    bb_clear(&st);
}

uint32_t dlms_get_invocationCounter(dlmsCtx* c)
{
    return c != NULL ? c->settings.cipher.invocationCounter : 0;
}

void dlms_set_invocationCounter(dlmsCtx* c, uint32_t value)
{
    if (c != NULL)
    {
        c->settings.cipher.invocationCounter = value;
    }
}

int dlms_get_serverSystemTitle(dlmsCtx* c, unsigned char* out, int* outLen)
{
    if (c == NULL || out == NULL || outLen == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int n = 8;
    if (*outLen < 8)
    {
        n = *outLen;
    }
    memcpy(out, c->settings.sourceSystemTitle, (size_t)n);
    *outLen = n;
    return DLMS_ERROR_CODE_OK;
}

void dlms_set_io(dlmsCtx* c, void* user, dlmsSendFn send, dlmsRecvFn receive)
{
    if (c == NULL)
    {
        return;
    }
    c->user = user;
    c->send = send;
    c->recv = receive;
}

void dlms_set_trace(dlmsCtx* c, void* user, dlmsTraceFn trace)
{
    if (c == NULL)
    {
        return;
    }
    c->traceUser = user;
    c->trace = trace;
}

int dlms_initialize(dlmsCtx* c)
{
    if (c == NULL || c->send == NULL || c->recv == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int ret;
    gxReplyData reply;
    message msg;

    // Wrapper 无链路层，跳过 SNRM/UA。
    if (c->settings.interfaceType != DLMS_INTERFACE_TYPE_WRAPPER)
    {
        reply_init(&reply);
        mes_init(&msg);
        c->lastStep = DLMS_STEP_SNRM_REQUEST;
        ret = cl_snrmRequest(&c->settings, &msg);
        if (ret == DLMS_ERROR_CODE_OK)
        {
            c->lastStep = DLMS_STEP_SNRM_RESPONSE;
            ret = dlmsReadDataBlock(c, &msg, &reply);
        }
        if (ret == DLMS_ERROR_CODE_OK)
        {
            ret = cl_parseUAResponse(&c->settings, &reply.data);
        }
        mes_clear(&msg);
        reply_clear(&reply);
        if (ret != DLMS_ERROR_CODE_OK)
        {
            return ret;
        }
    }

    // AARQ -> AARE。
    reply_init(&reply);
    mes_init(&msg);
    c->lastStep = DLMS_STEP_AARQ_REQUEST;
    ret = cl_aarqRequest(&c->settings, &msg);
    if (ret == DLMS_ERROR_CODE_OK)
    {
        c->lastStep = DLMS_STEP_AARE_RESPONSE;
        ret = dlmsReadDataBlock(c, &msg, &reply);
    }
    if (ret == DLMS_ERROR_CODE_OK)
    {
        ret = cl_parseAAREResponse(&c->settings, &reply.data);
    }
    mes_clear(&msg);
    reply_clear(&reply);
    if (ret != DLMS_ERROR_CODE_OK)
    {
        return ret;
    }

    // HLS challenge（认证 > LOW）。
    //
    // ── 为什么不能直接调 cl_getApplicationAssociationRequest ──────────────
    // cipher.security 这一个字段在库里**同时管两件事**：
    //   ① APDU 是否加密打包：isCiphered()（dlmsSettings.c:439）= (security != NONE)
    //      → 决定 HLS 应答打成明文 C3 还是加密壳 CB
    //   ② 能否算 GMAC：cip_encrypt()（ciphering.c:681）的守卫
    //      `if (settings->security == NONE || ...) return INVALID_PARAMETER`
    //      即使 dlms_secure()（dlms.c:6676）已显式传入 DLMS_SECURITY_AUTHENTICATION，
    //      仍被这道查"会话整体"的守卫拒掉 → security=NONE 时算不出 GMAC。
    // .NET 库没有这道守卫，所以 GXDLMSDirector 用 None+GMAC 能正常关联；
    // C 库这里把两件事耦合在一个字段上，必须**在时间上切开**：
    //   · 算 GMAC 那一刻：临时置 0x10 → 过守卫 → 算出 17B（SC+IC+GMAC）→ 立刻还原
    //   · 打包 APDU 那一刻：security 已回到 NONE → isCiphered()=false → 明文 C3 ✓
    // 手法出处：官方示例 GuruxDLMSClientExample/src/communication.c 的
    // com_updateInvocationCounter —— "先把 settings 存起来，临时改动，做完还原"。
    if (c->settings.authentication > DLMS_AUTHENTICATION_LOW)
    {
        reply_init(&reply);
        mes_init(&msg);
        DLMS_SECURITY savedSecurity = c->settings.cipher.security;

        // ① 算 GMAC：只在这一刻临时置 0x10，仅为过 ciphering.c:681 的守卫。
        gxByteBuffer challenge;
        bb_init(&challenge);
        c->settings.cipher.security = DLMS_SECURITY_AUTHENTICATION;
        int r1 = dlms_secure(&c->settings,
                             (int32_t)c->settings.cipher.invocationCounter,
                             &c->settings.stoCChallenge,            // 服务端挑战（AARE 里 AA 12 80 10 …）
                             &c->settings.cipher.systemTitle,       // GMAC 的 secret = 客户端自己的 SystemTitle
                             &challenge);                           // → SC(0x10|suite) + IC(4B) + GMAC(12B) = 17B
        c->settings.cipher.security = savedSecurity;                 // ★ 立刻还原：打包前 security 已回 NONE

        if (r1 != 0)
        {
            c->lastStep = DLMS_STEP_HLS_REQUEST;
            ret = r1;
        }
        else
        {
            // ② 打包：此时 security 已是 NONE → isCiphered()=false → 明文 C3，不是 CB。
            //    逐字段应等于现场 .NET 成功报文：
            //    C3 01 C1 00 0F 00 00 28 00 00 FF 01 09 11 10 <IC:4B> <GMAC:12B>
            dlmsVARIANT data;
            var_init(&data);
            data.vt = DLMS_DATA_TYPE_OCTET_STRING;
            data.byteArr = &challenge;
            static const unsigned char LN[6] = { 0, 0, 40, 0, 0, 255 };
            c->lastStep = DLMS_STEP_HLS_REQUEST;
            ret = cl_methodLN(&c->settings, LN,
                              DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME,
                              1, &data, &msg);
            // ⚠️ 这里**绝不能**调 var_clear(&data)：
            // data.byteArr 指向的是**栈上**的 challenge，而 var_clear() 对 OCTET_STRING
            // 变体会去释放 byteArr → free 一个栈地址 → 非法释放直接崩溃。
            // 官方 cl_getApplicationAssociationRequest 同样只做 var_init + 赋值、不做 clear。
            // 该缓冲区在本块末尾统一释放（见下面的 bb_clear）。
        }

        if (ret == DLMS_ERROR_CODE_OK)
        {
            c->lastStep = DLMS_STEP_HLS_RESPONSE;
            ret = dlmsReadDataBlock(c, &msg, &reply);
        }
        if (ret == DLMS_ERROR_CODE_OK)
        {
            // ③ 解析服务端回的 HLS 应答确认：parse 内部也会调 dlms_secure，
            //    同样需要 0x10 窗口（此路径无出向 APDU，安全）。
            c->settings.cipher.security = DLMS_SECURITY_AUTHENTICATION;
            ret = cl_parseApplicationAssociationResponse(&c->settings, &reply.data);
            c->settings.cipher.security = savedSecurity;
        }
        bb_clear(&challenge);   // 发送与解析都已完成，这里才释放 GMAC 缓冲
        mes_clear(&msg);
        reply_clear(&reply);
        if (ret != DLMS_ERROR_CODE_OK)
        {
            return ret;
        }
    }
    return DLMS_ERROR_CODE_OK;
}

// ── 读数展示（v1.6）：类型 / 值 / 可读 / HEX ─────────────────────────────
// 起因：原来只输出 var_toString 的"值"，看不出数据类型、也不好读。
// 类型名按 enums.h 的 DLMS_DATA_TYPE_* 逐项列出（不猜名字）。
const char* dlms_dataTypeName(int dataType)
{
    switch (dataType)
    {
    case DLMS_DATA_TYPE_NONE:                 return "none";
    case DLMS_DATA_TYPE_ARRAY:                return "array";
    case DLMS_DATA_TYPE_STRUCTURE:            return "structure";
    case DLMS_DATA_TYPE_BOOLEAN:              return "boolean";
    case DLMS_DATA_TYPE_BIT_STRING:           return "bit-string";
    // Blue Book：0x05 = double-long(INT32)、0x06 = double-long-unsigned(UINT32)；
    // 0x10 / 0x12 才是 long / long-unsigned。原来这两行误用了 16 位的名字。
    case DLMS_DATA_TYPE_INT32:                return "double-long";
    case DLMS_DATA_TYPE_UINT32:               return "double-long-unsigned";
    case DLMS_DATA_TYPE_OCTET_STRING:         return "octet-string";
    case DLMS_DATA_TYPE_STRING:               return "visible-string";
    case DLMS_DATA_TYPE_STRING_UTF8:          return "utf8-string";
    case DLMS_DATA_TYPE_BINARY_CODED_DESIMAL: return "bcd";
    case DLMS_DATA_TYPE_INT8:                 return "integer";
    case DLMS_DATA_TYPE_INT16:                return "long";
    case DLMS_DATA_TYPE_UINT8:                return "unsigned";
    case DLMS_DATA_TYPE_UINT16:               return "long-unsigned";
    case DLMS_DATA_TYPE_COMPACT_ARRAY:        return "compact-array";
    case DLMS_DATA_TYPE_INT64:                return "long64";
    case DLMS_DATA_TYPE_UINT64:               return "long64-unsigned";
    case DLMS_DATA_TYPE_ENUM:                 return "enum";
    case DLMS_DATA_TYPE_FLOAT32:              return "float32";
    case DLMS_DATA_TYPE_FLOAT64:              return "float64";
    case DLMS_DATA_TYPE_DATETIME:             return "date-time";
    case DLMS_DATA_TYPE_DATE:                 return "date";
    case DLMS_DATA_TYPE_TIME:                 return "time";
    case DLMS_DATA_TYPE_DELTA_INT8:           return "delta-integer";
    case DLMS_DATA_TYPE_DELTA_INT16:          return "delta-long";
    case DLMS_DATA_TYPE_DELTA_INT32:          return "delta-long";
    case DLMS_DATA_TYPE_DELTA_UINT8:          return "delta-unsigned";
    case DLMS_DATA_TYPE_DELTA_UINT16:         return "delta-long-unsigned";
    case DLMS_DATA_TYPE_DELTA_UINT32:         return "delta-long-unsigned";
    default:                                  return "unknown";
    }
}

static void bbAppendStr(gxByteBuffer* bb, const char* s)
{
    if (s != NULL)
    {
        bb_set(bb, (const unsigned char*)s, (uint32_t)strlen(s));
    }
}

// 可读渲染：
//   boolean → true/false
//   octet-string → 全可打印则按 ASCII 文本（如序列号），否则提示看 HEX
//   visible-string / utf8-string → 直接文本
//   其它（数值、时间、复合类型）→ 交给 var_toString（它本身就会给出可读表示）
static void appendReadable(dlmsVARIANT* v, gxByteBuffer* bb)
{
    switch (v->vt)
    {
    case DLMS_DATA_TYPE_BOOLEAN:
        bbAppendStr(bb, v->boolVal ? "true" : "false");
        return;
    case DLMS_DATA_TYPE_OCTET_STRING:
        if (v->byteArr == NULL || v->byteArr->size == 0)
        {
            return;      // 空值：可读留空，别误导成"非文本"
        }
        {
            uint32_t i;
            int printable = 1;
            for (i = 0; i < v->byteArr->size; i++)
            {
                unsigned char ch = v->byteArr->data[i];
                if (ch < 0x20 || ch > 0x7E) { printable = 0; break; }
            }
            if (printable)
            {
                bb_set(bb, v->byteArr->data, v->byteArr->size);
                return;
            }
        }
        bbAppendStr(bb, "（非文本，见 HEX）");
        return;
    case DLMS_DATA_TYPE_STRING:
    case DLMS_DATA_TYPE_STRING_UTF8:
    {
        gxByteBuffer* s = (v->vt == DLMS_DATA_TYPE_STRING) ? v->strVal : v->strUtfVal;
        if (s != NULL && s->size > 0)
        {
            bb_set(bb, s->data, s->size);
            return;
        }
        break;
    }
    default:
        break;
    }
    if (var_toString(v, bb) != 0)
    {
        bbAppendStr(bb, "(无法渲染)");
    }
}

// 原始字节：整数按大端对齐到其宽度；octet-string 逐字节（最多 32 个）；其余不算。
static void appendHex(dlmsVARIANT* v, gxByteBuffer* bb)
{
    unsigned char tmp[8];
    uint64_t u = 0;
    int n = 0, i;
    switch (v->vt)
    {
    // BOOLEAN 原来漏在这个分支表里 → 行1 会只剩 tag、丢掉值字节（03 01 变成 03）。
    case DLMS_DATA_TYPE_BOOLEAN:u = v->boolVal ? 1 : 0;                     n = 1; break;
    case DLMS_DATA_TYPE_UINT8:
    case DLMS_DATA_TYPE_ENUM:   u = (uint64_t)v->bVal;                      n = 1; break;
    case DLMS_DATA_TYPE_INT8:   u = (uint64_t)(uint8_t)v->cVal;             n = 1; break;
    case DLMS_DATA_TYPE_UINT16: u = (uint64_t)v->uiVal;                     n = 2; break;
    case DLMS_DATA_TYPE_INT16:  u = (uint64_t)(uint16_t)v->iVal;            n = 2; break;
    case DLMS_DATA_TYPE_UINT32: u = (uint64_t)v->ulVal;                     n = 4; break;
    case DLMS_DATA_TYPE_INT32:  u = (uint64_t)(uint32_t)v->lVal;            n = 4; break;
    case DLMS_DATA_TYPE_UINT64: u = v->ullVal;                              n = 8; break;
    case DLMS_DATA_TYPE_INT64:  u = (uint64_t)v->llVal;                     n = 8; break;
    case DLMS_DATA_TYPE_OCTET_STRING:
        if (v->byteArr != NULL && v->byteArr->size > 0)
        {
            uint32_t k, lim = v->byteArr->size < 32 ? v->byteArr->size : 32;
            char hx[4];
            for (k = 0; k < lim; k++)
            {
                if (k > 0) { bbAppendStr(bb, " "); }
                snprintf(hx, sizeof(hx), "%02X", v->byteArr->data[k]);
                bbAppendStr(bb, hx);
            }
            if (v->byteArr->size > lim) { bbAppendStr(bb, " …"); }
            return;
        }
        bbAppendStr(bb, "-");
        return;
    default:
        bbAppendStr(bb, "-");
        return;
    }
    for (i = 0; i < n; i++)
    {
        char hx[4];
        tmp[i] = (unsigned char)((u >> (8 * (n - 1 - i))) & 0xFF);
        snprintf(hx, sizeof(hx), "%02X", tmp[i]);
        if (i > 0) { bbAppendStr(bb, " "); }
        bbAppendStr(bb, hx);
    }
}

// 把 1 个值渲染成多行文本（UI 的"解析"面板直接显示）：
//   类型   long-unsigned (18)
//   值     1234
//   可读   1234
//   HEX    04 D2
//
// **故意不加 static**：让 C 单测能直接构造 dlmsVARIANT 断言渲染结果
//（见 Tests/CTests/test_dlms.c 的 [render] 段）。生产路径由下面的
// replyValueString() 调用，不对外暴露到 DLMSCore.h（避免 Swift 侧多看到 C 类型）。
// 变长类型：编码里带显式长度字节（Blue Book 的 octet-string / visible-string /
// utf8-string / bit-string 都是 tag + 长度 + 内容）。
static int hasExplicitLength(DLMS_DATA_TYPE vt)
{
    return vt == DLMS_DATA_TYPE_OCTET_STRING || vt == DLMS_DATA_TYPE_STRING ||
           vt == DLMS_DATA_TYPE_STRING_UTF8 || vt == DLMS_DATA_TYPE_BIT_STRING;
}

// 取变长类型的「内容」指针与长度（只读，不分配）。
static const unsigned char* lengthPrefixedBytes(dlmsVARIANT* v, uint32_t* len)
{
    *len = 0;
    if (v->vt == DLMS_DATA_TYPE_OCTET_STRING)
    {
        if (v->byteArr != NULL) { *len = v->byteArr->size; return v->byteArr->data; }
        return NULL;
    }
    if (v->vt == DLMS_DATA_TYPE_STRING)
    {
        if (v->strVal != NULL) { *len = v->strVal->size; return v->strVal->data; }
        return NULL;
    }
    if (v->vt == DLMS_DATA_TYPE_STRING_UTF8)
    {
        if (v->strUtfVal != NULL) { *len = v->strUtfVal->size; return v->strUtfVal->data; }
        return NULL;
    }
    return NULL;
}

// 第一行：**含类型标签**的 HEX。规则按现场报文习惯：
//   · 变长类型：tag + 长度 + 内容        例 09 03 31 32 33（octet-string "123"）
//   · 定长类型：tag + 内容（大端对齐）   例 05 00 00 00 01 / 12 12 34 / 11 01
//   · 复合/未知类型：只能给 tag（variant 里没有原始编码，无法回推）
static void appendTypedHex(dlmsVARIANT* v, gxByteBuffer* bb)
{
    char seg[8];
    snprintf(seg, sizeof(seg), "%02X", (int)(v->vt & 0xFF));
    bbAppendStr(bb, seg);

    if (hasExplicitLength(v->vt))
    {
        uint32_t len = 0, i;
        const unsigned char* p = lengthPrefixedBytes(v, &len);
        snprintf(seg, sizeof(seg), " %02X", (int)(len & 0xFF));
        bbAppendStr(bb, seg);
        for (i = 0; p != NULL && i < len; i++)
        {
            snprintf(seg, sizeof(seg), " %02X", p[i]);
            bbAppendStr(bb, seg);
        }
        return;
    }

    // 定长类型：复用 appendHex（整数按宽度大端）。它对未支持的类型会写一个 "-"，
    // 这里要当作"没写"，否则末尾会多出 "01 -" 这种尾巴。
    {
        gxByteBuffer th;
        bb_init(&th);
        appendHex(v, &th);
        if (th.size > 0 && !(th.size == 1 && th.data[0] == '-'))
        {
            bbAppendStr(bb, " ");
            bb_set(bb, th.data, th.size);      // 注意：bb_set 是**追加**（写在末尾并增长 size）
        }
        bb_clear(&th);
    }
}

// 渲染为**两行**（UI 的"解析"面板直接显示；"解析使能"关闭时只取第一行）：
//   第一行：含类型标签的 HEX
//   第二行：-> Type: <类型名>[, Length: n], Value: <可读值>
int dlms_renderValue(dlmsVARIANT* value, char* out, int* outLen)
{
    int written = 0;
    if (value == NULL || out == NULL || outLen == NULL || *outLen <= 0)
    {
        return 0;
    }
    {
        gxByteBuffer bb;
        char* s;
        bb_init(&bb);

        // 第一行：含类型标签的 HEX
        appendTypedHex(value, &bb);
        // 第二行：解析结果
        bbAppendStr(&bb, "\n-> Type: ");
        bbAppendStr(&bb, dlms_dataTypeName((int)value->vt));
        if (hasExplicitLength(value->vt))
        {
            uint32_t len = 0;
            char tmp[24];
            (void)lengthPrefixedBytes(value, &len);
            snprintf(tmp, sizeof(tmp), ", Length: %u", (unsigned)len);
            bbAppendStr(&bb, tmp);
        }
        bbAppendStr(&bb, ", Value: ");
        appendReadable(value, &bb);
        bbAppendStr(&bb, "\n");

        bb_setUInt8(&bb, 0);          // 收尾 NUL：bb_toString 要求缓冲区以 0 结尾
        // 注意：bb_toString 返回的是**新 malloc 出来的副本**，所以下面必须 free(s)；
        // 若将来改成直接用 (char*)bb.data（更直接），则**必须同时删掉 free**，否则非法释放。
        s = bb_toString(&bb);
        if (s != NULL)
        {
            int cap = *outLen;
            size_t need = strlen(s);
            int n = need < (size_t)(cap - 1) ? (int)need : (cap - 1);
            memcpy(out, s, (size_t)n);
            out[n] = '\0';
            written = n + 1;
            free(s);
        }
        bb_clear(&bb);
        *outLen = written;
    }
    return written;
}

static int replyValueString(gxReplyData* reply, char* out, int* outLen)
{
    return dlms_renderValue(&reply->dataValue, out, outLen);
}

int dlms_read(dlmsCtx* c, const unsigned char* obis, uint16_t type, unsigned char attr,
              char* out, int* outLen)
{
    if (c == NULL || obis == NULL || out == NULL || outLen == NULL ||
        c->send == NULL || c->recv == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int ret;
    gxReplyData reply;
    message msg;
    reply_init(&reply);
    mes_init(&msg);

    ret = cl_readLN(&c->settings, obis, (DLMS_OBJECT_TYPE)type, attr, NULL, &msg);
    if (ret == DLMS_ERROR_CODE_OK)
    {
        ret = dlmsReadDataBlock(c, &msg, &reply);
    }
    if (ret == DLMS_ERROR_CODE_OK)
    {
        replyValueString(&reply, out, outLen);
    }
    mes_clear(&msg);
    reply_clear(&reply);
    return ret;
}

// 把原始字节装进 OCTET_STRING variant（写 / method 两条路共用）。
//
// ⚠️ 必须按库的约定**堆分配** byteArr。不能 var_init 之后直接 bb_clear/bb_set：
//   · var_init() 会把 v->byteArr 置为 NULL（variant.c:297）；
//   · bb_clear(arr) 只检查 arr->data、**不检查 arr 本身**（bytebuffer.c:678-682），
//     所以 bb_clear(NULL) 会去读 NULL->data → 解引用空指针，直接崩溃。
//   · 库自己的 var_addBytes() 在 vt != OCTET_STRING 时正是先 gxmalloc 出
//     gxByteBuffer 再填数据（variant.c:246-248）—— 这里照同一约定做。
//   （"写 / action 一点就崩"的根因，就是漏了这一步分配。）
//   注意：分配出来的 byteArr 之后由 var_clear() 负责释放（variant.c:346-355）。
static int setOctetStringVariant(dlmsVARIANT* v, const unsigned char* data, uint32_t size)
{
    var_init(v);
    v->byteArr = (gxByteBuffer*)gxmalloc(sizeof(gxByteBuffer));
    if (v->byteArr == NULL)
    {
        return DLMS_ERROR_CODE_OUTOFMEMORY;
    }
    bb_init(v->byteArr);
    v->vt = DLMS_DATA_TYPE_OCTET_STRING;
    if (data != NULL && size > 0)
    {
        return bb_set(v->byteArr, data, size);
    }
    return DLMS_ERROR_CODE_OK;
}

// 写路径：OCTET_STRING variant 承载原始字节，byteArray=1 直传。
// 故意不加 static：C 单测要直接调它守住"不再崩"（见 test_dlms.c 的 [writevar]）。
int buildBytesVariant(dlmsVARIANT* v, const char* hex)
{
    gxByteBuffer payload;
    bb_init(&payload);
    if (hex != NULL && *hex != '\0')
    {
        int r = hexToBytes(&payload, hex);
        if (r != DLMS_ERROR_CODE_OK)
        {
            bb_clear(&payload);
            return r;
        }
    }
    int r = setOctetStringVariant(v, payload.data, payload.size);
    bb_clear(&payload);
    return r;
}

int dlms_write(dlmsCtx* c, const unsigned char* obis, uint16_t type, unsigned char attr,
               const char* hex, char* out, int* outLen)
{
    if (c == NULL || obis == NULL || c->send == NULL || c->recv == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int ret;
    dlmsVARIANT v;
    gxReplyData reply;
    message msg;
    // 先 var_init：这样失败路径可以无条件 var_clear，不会读到未初始化内存。
    var_init(&v);
    ret = buildBytesVariant(&v, hex);
    if (ret != DLMS_ERROR_CODE_OK)
    {
        // ★ 必须释放：buildBytesVariant 在返回错误前**可能已经分配了 byteArr**
        //   （setOctetStringVariant 里 gxmalloc 成功、随后 bb_set 失败的情形）。
        //   直接 return 会漏掉那个 gxByteBuffer。
        //   注意顺序 —— 若没有上面的 var_init，这里的 var_clear 会读未初始化内存。
        var_clear(&v);
        return ret;
    }
    reply_init(&reply);
    mes_init(&msg);
    ret = cl_writeLN(&c->settings, obis, (DLMS_OBJECT_TYPE)type, attr, &v, 1, &msg);
    if (ret == DLMS_ERROR_CODE_OK)
    {
        ret = dlmsReadDataBlock(c, &msg, &reply);
    }
    if (ret == DLMS_ERROR_CODE_OK && out != NULL && outLen != NULL)
    {
        replyValueString(&reply, out, outLen);
    }
    var_clear(&v);
    mes_clear(&msg);
    reply_clear(&reply);
    return ret;
}

// 按 P1 tag 集把 hex 解析为 variant（供 method）。
// 故意不加 static：C 单测直接调它守住"不再崩"（见 test_dlms.c 的 [writevar]）。
int buildVariantFromHex(const char* hex, dlmsVARIANT* v)
{
    gxByteBuffer b;
    bb_init(&b);
    if (hex == NULL || *hex == '\0')
    {
        // 无参方法。
        var_init(v);
        v->vt = DLMS_DATA_TYPE_NONE;
        bb_clear(&b);
        return DLMS_ERROR_CODE_OK;
    }
    int r = hexToBytes(&b, hex);
    if (r != DLMS_ERROR_CODE_OK)
    {
        bb_clear(&b);
        return r;
    }
    if (b.size < 2)
    {
        bb_clear(&b);
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    unsigned char tag = b.data[0];
    r = DLMS_ERROR_CODE_INVALID_PARAMETER;
    switch (tag)
    {
    case DLMS_DATA_TYPE_BOOLEAN:
        if (b.size == 2)
        {
            r = var_setBoolean(v, b.data[1] != 0);
        }
        break;
    case DLMS_DATA_TYPE_INT8:
        if (b.size == 2)
        {
            r = var_setInt8(v, (char)b.data[1]);
        }
        break;
    case DLMS_DATA_TYPE_INT16:
        if (b.size == 3)
        {
            // 与 INT32 一样走无符号中间量（`b.data[1] << 8` 在 int 上不会溢出，
            // 严格说不算 UB，但两处写法统一更不容易再踩坑）。
            uint16_t u = (uint16_t)(((uint16_t)b.data[1] << 8) | (uint16_t)b.data[2]);
            r = var_setInt16(v, (int16_t)u);
        }
        break;
    case DLMS_DATA_TYPE_INT32:
        if (b.size == 5)
        {
            // D3：先用无符号中间量组装，最后再转有符号。
            // `(int32_t)b.data[1] << 24` 当 b.data[1] >= 0x80 时会把 1 移进符号位，
            // 按 C11 6.5.7p4 属**未定义行为**（有符号左移溢出）。clang 实际按位翻转处理、
            // 结果虽对，但不可移植且静态分析会告警。UINT32 分支本来就是无符号写法，这里统一。
            uint32_t u = ((uint32_t)b.data[1] << 24) | ((uint32_t)b.data[2] << 16) |
                         ((uint32_t)b.data[3] << 8) | (uint32_t)b.data[4];
            r = var_setInt32(v, (int32_t)u);
        }
        break;
    case DLMS_DATA_TYPE_UINT8:
        if (b.size == 2)
        {
            r = var_setUInt8(v, b.data[1]);
        }
        break;
    case DLMS_DATA_TYPE_UINT16:
        if (b.size == 3)
        {
            uint16_t val = (uint16_t)((b.data[1] << 8) | b.data[2]);
            r = var_setUInt16(v, val);
        }
        break;
    case DLMS_DATA_TYPE_UINT32:
        if (b.size == 5)
        {
            uint32_t val = ((uint32_t)b.data[1] << 24) | ((uint32_t)b.data[2] << 16) |
                           ((uint32_t)b.data[3] << 8) | b.data[4];
            r = var_setUInt32(v, val);
        }
        break;
    case DLMS_DATA_TYPE_ENUM:
        if (b.size == 2)
        {
            r = var_setEnum(v, b.data[1]);
        }
        break;
    case DLMS_DATA_TYPE_OCTET_STRING:
        // 与写路径同一个坑：不能先 var_init 再把 vt 设成 OCTET_STRING ——
        // 那样 var_addBytes() 会走 else 分支，对仍为 NULL 的 byteArr 调 bb_clear → 崩。
        // 统一交给 setOctetStringVariant 显式堆分配（见其注释）。
        r = setOctetStringVariant(v, &b.data[1], b.size - 1);
        break;
    default:
        r = DLMS_ERROR_CODE_INVALID_PARAMETER;
        break;
    }
    bb_clear(&b);
    return r;
}

int dlms_method(dlmsCtx* c, const unsigned char* obis, uint16_t type, unsigned char index,
                const char* hex, char* out, int* outLen)
{
    if (c == NULL || obis == NULL || c->send == NULL || c->recv == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int ret;
    dlmsVARIANT v;
    var_init(&v);
    gxReplyData reply;
    message msg;
    const dlmsVARIANT* param;
    if (hex != NULL && *hex != '\0')
    {
        ret = buildVariantFromHex(hex, &v);
        if (ret != DLMS_ERROR_CODE_OK)
        {
            // 同 dlms_write：失败前可能已分配 byteArr，必须释放（v 已 var_init，安全）。
            var_clear(&v);
            return ret;
        }
        param = &v;
    }
    else
    {
        param = NULL; // 无参方法。
    }
    reply_init(&reply);
    mes_init(&msg);
    ret = cl_methodLN(&c->settings, obis, (DLMS_OBJECT_TYPE)type, index, (dlmsVARIANT*)param, &msg);
    if (ret == DLMS_ERROR_CODE_OK)
    {
        ret = dlmsReadDataBlock(c, &msg, &reply);
    }
    if (ret == DLMS_ERROR_CODE_OK && out != NULL && outLen != NULL)
    {
        replyValueString(&reply, out, outLen);
    }
    var_clear(&v);
    mes_clear(&msg);
    reply_clear(&reply);
    return ret;
}

int dlms_disconnect(dlmsCtx* c)
{
    if (c == NULL || c->send == NULL || c->recv == NULL)
    {
        return DLMS_ERROR_CODE_INVALID_PARAMETER;
    }
    int ret;
    gxReplyData reply;
    message msg;

    // 先 RLRQ（加密会话用受保护 release）。
    reply_init(&reply);
    mes_init(&msg);
    ret = cl_releaseRequest2(&c->settings, &msg,
                             c->settings.cipher.security != DLMS_SECURITY_NONE);
    if (ret == DLMS_ERROR_CODE_OK)
    {
        ret = dlmsReadDataBlock(c, &msg, &reply);
    }
    mes_clear(&msg);
    reply_clear(&reply);

    // 再 DISC（仅 HDLC 有链路层）。
    reply_init(&reply);
    mes_init(&msg);
    if (c->settings.interfaceType != DLMS_INTERFACE_TYPE_WRAPPER)
    {
        ret = cl_disconnectRequest(&c->settings, &msg);
        if (ret == DLMS_ERROR_CODE_OK)
        {
            (void)dlmsReadDataBlock(c, &msg, &reply);
        }
    }
    mes_clear(&msg);
    reply_clear(&reply);
    return ret;
}

const char* dlms_error_string(int code)
{
    return hlp_getErrorMessage(code);
}