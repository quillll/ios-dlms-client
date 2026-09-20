//
//  DLMSBridge.c
//  在 vendored Gurux.DLMS.c 上层实现 DLMSCore.h 声明的客户端面。
//  所有组帧/APDU/建链状态机都在这里；Swift 仅通过 send/recv 回调提供 TCP 字节。
//
//  v1.2 要点：
//   - 接收缓冲为 ctx 上跨 recv 持久化的累积缓冲，追加(bb_insert)而非覆盖(bb_set)，
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
};

// 追加到 rx 末尾，必要时先扩容。
static int bufAppend(dlmsCtx* c, const unsigned char* src, uint32_t len)
{
    if (len == 0)
    {
        return 0;
    }
    gxByteBuffer* rx = &c->rx;
    if (rx->size + len > rx->capacity)
    {
        int r = bb_capacity(rx, rx->size + len + 256);
        if (r != 0)
        {
            return r;
        }
    }
    return bb_insert(src, len, rx, rx->size);
}

// 发送一个请求缓冲，循环接收直到 reply->complete（Gurux readDLMSPacket 逻辑）。
static int dlmsSendFrame(dlmsCtx* c, gxByteBuffer* data, gxReplyData* reply)
{
    int ret, fail = 0;
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
        return DLMS_ERROR_CODE_SEND_FAILED;
    }
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
                ret = DLMS_ERROR_CODE_SEND_FAILED;
                break;
            }
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
        ret = cl_snrmRequest(&c->settings, &msg);
        if (ret == DLMS_ERROR_CODE_OK)
        {
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
    ret = cl_aarqRequest(&c->settings, &msg);
    if (ret == DLMS_ERROR_CODE_OK)
    {
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
    if (c->settings.authentication > DLMS_AUTHENTICATION_LOW)
    {
        reply_init(&reply);
        mes_init(&msg);
        ret = cl_getApplicationAssociationRequest(&c->settings, &msg);
        if (ret == DLMS_ERROR_CODE_OK)
        {
            ret = dlmsReadDataBlock(c, &msg, &reply);
        }
        if (ret == DLMS_ERROR_CODE_OK)
        {
            ret = cl_parseApplicationAssociationResponse(&c->settings, &reply.data);
        }
        mes_clear(&msg);
        reply_clear(&reply);
        if (ret != DLMS_ERROR_CODE_OK)
        {
            return ret;
        }
    }
    return DLMS_ERROR_CODE_OK;
}

// 从 reply 取出值字符串写入 out。
static int replyValueString(gxReplyData* reply, char* out, int* outLen)
{
    int written = 0;
    if (out != NULL && outLen != NULL && *outLen > 0)
    {
        gxByteBuffer bb;
        bb_init(&bb);
        if (var_toString(&reply->dataValue, &bb) == 0)
        {
            char* s = bb_toString(&bb);
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
        }
        bb_clear(&bb);
        *outLen = written;
    }
    return written;
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

static int buildBytesVariant(dlmsVARIANT* v, const char* hex)
{
    // 写路径：OCTET_STRING variant 承载原始字节，byteArray=1 直传。
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
    var_init(v);
    v->vt = DLMS_DATA_TYPE_OCTET_STRING;
    bb_clear(v->byteArr);
    bb_set(v->byteArr, payload.data, payload.size);
    bb_clear(&payload);
    return DLMS_ERROR_CODE_OK;
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
    ret = buildBytesVariant(&v, hex);
    if (ret != DLMS_ERROR_CODE_OK)
    {
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
static int buildVariantFromHex(const char* hex, dlmsVARIANT* v)
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
    {
        var_init(v);
        v->vt = DLMS_DATA_TYPE_OCTET_STRING;
        r = var_addBytes(v, &b.data[1], (uint16_t)(b.size - 1));
        break;
    }
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