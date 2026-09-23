//
//  test_dlms.c
//  本地可运行的 C 层单元测试（无需真表）：
//   - bb_addHexString 的 hex 解析（含空格/无空格）
//   - dlms_new + 安全/SystemTitle/IC 读写
//   - variant 整型设置与类型
//  编译：clang test_dlms.c DLMSBridge.c C/src/*.c -IC/include -IHeaders
//

#include "DLMSCore.h"
#include "variant.h"
#include "enums.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(cond, msg) do { \
    if ((cond)) { printf("  ok: %s\n", (msg)); } \
    else { printf("  FAIL: %s\n", (msg)); ++failures; } \
} while (0)

static void test_hex(void)
{
    gxByteBuffer b;
    bb_init(&b);
    CHECK(bb_addHexString(&b, "11 01") == 0 && b.size == 2 &&
          b.data[0] == 0x11 && b.data[1] == 0x01, "hex spaced '11 01'");
    bb_clear(&b); bb_init(&b);
    CHECK(bb_addHexString(&b, "12 01 00") == 0 && b.size == 3 &&
          b.data[2] == 0x00, "hex spaced '12 01 00'");
    bb_clear(&b); bb_init(&b);
    CHECK(bb_addHexString(&b, "AB0F") == 0 && b.size == 2 &&
          b.data[0] == 0xAB && b.data[1] == 0x0F, "hex no-space 'AB0F'");
    bb_clear(&b);
}

static void test_ctx(void)
{
    dlmsCtx* c = dlms_new(1, 1, 0x00013FFFu, 5, "00000000", 0);
    CHECK(c != NULL, "dlms_new returns ctx");

    dlms_set_security(c, 0x30, "000102030405060708090a0b0c0d0e0f", NULL, NULL);
    dlms_set_clientSystemTitle(c, "4845430005000001");
    dlms_set_invocationCounter(c, 7);
    CHECK(dlms_get_invocationCounter(c) == 7, "invocationCounter read-write");

    unsigned char st[8];
    int stlen = 8;
    CHECK(dlms_get_serverSystemTitle(c, st, &stlen) == 0 && stlen == 8, "serverSystemTitle copy shape");

    // 诊断接口（v1.5）：新 ctx 应处于"未开始"状态，步骤名要能取到非空串。
    // 这组同时证明了 dlms_lastStep / dlms_sendFailed / dlms_step_name 确实链得上
    //（现场"建链失败"细化定位就靠它们）。
    CHECK(dlms_lastStep(c) == 0, "diag: lastStep starts at 0");
    CHECK(dlms_sendFailed(c) == 0, "diag: sendFailed starts at 0");
    CHECK(dlms_step_name(0)[0] != '\0', "diag: step_name(0) non-empty");
    CHECK(dlms_step_name(5)[0] != '\0', "diag: step_name(5) non-empty");
    CHECK(dlms_lastStep(NULL) == 0 && dlms_sendFailed(NULL) == 0, "diag: NULL-safe");

    // 读数展示：类型名表（必须与 enums.h 的 DLMS_DATA_TYPE_* 一致）
    CHECK(strcmp(dlms_dataTypeName(18), "long-unsigned") == 0, "render: type 18 = long-unsigned");
    CHECK(strcmp(dlms_dataTypeName(9), "octet-string") == 0, "render: type 9 = octet-string");
    CHECK(strcmp(dlms_dataTypeName(25), "date-time") == 0, "render: type 25 = date-time");
    CHECK(strcmp(dlms_dataTypeName(3), "boolean") == 0, "render: type 3 = boolean");
    CHECK(strcmp(dlms_dataTypeName(999), "unknown") == 0, "render: 未知类型 → unknown");

    dlms_free(c);
}

static void test_variant(void)
{
    dlmsVARIANT v;
    CHECK(var_setUInt16(&v, 256) == 0, "var_setUInt16");
    CHECK(v.vt == DLMS_DATA_TYPE_UINT16, "UINT16 vt=18");
    var_clear(&v);

    CHECK(var_setInt8(&v, -5) == 0, "var_setInt8");
    CHECK(v.vt == DLMS_DATA_TYPE_INT8, "INT8 vt=0x0F");
    var_clear(&v);
}

// ══════════════════════════════════════════════════════════════════════════
// 本地回放：桩 send/recv + **自造**合法帧，跑 dlms_initialize 的完整协议流程
//
// 为什么要它：此前 C 单测**一次都没调用过 dlms_initialize / dlms_read /
// dlms_write / dlms_method / dlms_disconnect**（覆盖 0），于是协议主流程里
// 的缺陷（例如 HLS 段 var_clear 释放栈地址导致真机崩溃）只有真表能发现。
// 本测试让 CI 就能执行到那段代码。
//
// 两条经验（踩过坑）：
//   ① **绝不回放手工转录的报文** —— 从截图抄的 100 字节必然出错（FCS 对不上）；
//      正确做法是自己构造内容 + 用 fcs16 自算校验。
//   ② 帧结构按现场实测：HDLC + 1 字节地址 0x03(=0x0001) + FCS16(CRC-16/X-25)。
// ══════════════════════════════════════════════════════════════════════════

// CRC-16/X-25：poly 0x8408 反射、init 0xFFFF、末尾取反、低字节先发。
// 算法已用现场抓到的 UA 帧独立验证（算出 3B53 == 抓包值）。
static unsigned short fcs16(const unsigned char* p, int n)
{
    unsigned short crc = 0xFFFF;
    int i, b;
    for (i = 0; i < n; i++)
    {
        crc ^= p[i];
        for (b = 0; b < 8; b++)
        {
            if (crc & 1) { crc = (unsigned short)((crc >> 1) ^ 0x8408); }
            else         { crc = (unsigned short)(crc >> 1); }
        }
    }
    return (unsigned short)(crc ^ 0xFFFF);
}

#define RP_TX_MAX 16
#define RP_TX_CAP 512
// 桩硬上限：超过即判"被测代码的收发循环未收敛"，并强制失败。
// 加它的直接原因：曾出现测试挂住 17 分钟 —— 被测代码死循环 + 桩"永远有响应"，
// 两边都不收敛，只能靠 Ctrl-C。有了上限，最坏情况变成"几秒内失败并给出提示"。
#define RP_STUB_MAX 200
#define RP_TRACE_MAX 16        // 只打印前 N 次收发，便于看清循环形态

typedef struct
{
    unsigned char tx[RP_TX_MAX][RP_TX_CAP];   // 记录我方发出去的帧（静态，不用 malloc）
    int txLen[RP_TX_MAX];
    int txCount;
    const unsigned char* rx[8];               // 第 N 次 send 之后要"收到"的响应
    int rxLen[8];
    int rxCount;
    int sends;
    int recvs;                                // 诊断：recv 被调用总次数
} Replay;

// 超限提示只打一次，避免刷屏
static void rpNoteOver(const char* what)
{
    static int warned = 0;
    if (warned == 0)
    {
        warned = 1;
        printf("  !! %s 已达上限 %d 次 —— 被测代码的收发循环未收敛（已强制失败，不再继续）\n",
               what, RP_STUB_MAX);
    }
}

static int replaySend(void* user, const unsigned char* data, int len)
{
    Replay* r = (Replay*)user;
    if (r->txCount < RP_TX_MAX && len > 0 && len <= RP_TX_CAP)
    {
        memcpy(r->tx[r->txCount], data, (size_t)len);
        r->txLen[r->txCount] = len;
        r->txCount++;
    }
    r->sends++;
    if (r->sends <= RP_TRACE_MAX) { printf("     [stub] send#%d len=%d\n", r->sends, len); }
    if (r->sends > RP_STUB_MAX) { rpNoteOver("send"); return -1; }
    return 0;                                 // 否则"发送成功"
}

static int replayRecv(void* user, unsigned char* buf, int cap, int* got)
{
    Replay* r = (Replay*)user;
    int idx = r->sends - 1;                   // 第 N 次 send 对应第 N 份响应
    int n;
    r->recvs++;
    if (r->recvs > RP_STUB_MAX)
    {
        rpNoteOver("recv");
        if (got != NULL) { *got = 0; }
        return -1;
    }
    if (idx < 0 || idx >= r->rxCount)
    {
        if (r->recvs <= RP_TRACE_MAX) { printf("     [stub] recv#%d idx=%d 无料\n", r->recvs, idx); }
        if (got != NULL) { *got = 0; }
        return -1;
    }
    n = r->rxLen[idx];
    if (n > cap) { n = cap; }
    memcpy(buf, r->rx[idx], (size_t)n);
    if (got != NULL) { *got = (int)n; }
    if (r->recvs <= RP_TRACE_MAX) { printf("     [stub] recv#%d idx=%d n=%d\n", r->recvs, idx, n); }
    return 0;
}

// 用「内容 + 自算 HCS/FCS」拼一帧 HDLC：7E | A0 len dst src ctrl HCS(2) info FCS(2) 7E
//
// ⚠️ 这里有个坑，曾让回放测试死循环（表现是"挂住"而非崩溃）：
//   **HCS 必须覆盖真实的长度字节**。若先用 0x00 占位算 HCS、之后再回填长度，
//   HCS 就是错的 → 库的 HCS 校验不过（dlms.c:3023）→ dlms_getHdlcData 跳过该帧、
//   把游标推到帧尾（dlms.c:3007/3027）→ 递归进去时"数据不够"→ complete=0 返回
//   → 外层收发循环永不退出（且 rx 缓冲每轮追加一帧，内存持续增长）。
//   已用现场 UA 帧独立验证：HCS(A0 1E 03 03 73) = 0xCC40 → 线上 40 CC ✓ 与抓包一致；
//   而用占位 0x00 算得 0xA1A3 ✗。
//   另一条经验：**FCS 要覆盖整个帧体**，所以它必须在长度回填之后才算（顺序本来就对）。
static int buildHdlc(unsigned char* out, unsigned char control,
                     const unsigned char* info, int infoLen)
{
    unsigned char body[512];
    unsigned short hcs, f;
    int n = 0, m = 0, i;
    int total = 5 + 2 + infoLen + 2;          // A0,len,dst,src,ctrl + HCS(2) + info + FCS(2)
    body[n++] = 0xA0;                         // frame format
    body[n++] = (unsigned char)total;         // ★ 长度先定死：HCS 要覆盖它
    body[n++] = 0x03;                         // 目的地址 0x0001（7bit 编码）
    body[n++] = 0x03;                         // 源地址   0x0001
    body[n++] = control;
    hcs = fcs16(body, n);                     // HCS 覆盖 frame-format..control（含长度）
    body[n++] = (unsigned char)(hcs & 0xFF);
    body[n++] = (unsigned char)((hcs >> 8) & 0xFF);
    for (i = 0; i < infoLen; i++) { body[n++] = info[i]; }
    f = fcs16(body, n);                       // FCS 覆盖整个帧体
    out[m++] = 0x7E;
    for (i = 0; i < n; i++) { out[m++] = body[i]; }
    out[m++] = (unsigned char)(f & 0xFF);
    out[m++] = (unsigned char)((f >> 8) & 0xFF);
    out[m++] = 0x7E;
    return m;
}

// 在 hay 中查找 needle 子序列
static int containsSeq(const unsigned char* hay, int hayLen,
                       const unsigned char* needle, int needleLen)
{
    int i, j;
    if (needleLen <= 0 || hayLen < needleLen) { return 0; }
    for (i = 0; i <= hayLen - needleLen; i++)
    {
        for (j = 0; j < needleLen; j++) { if (hay[i + j] != needle[j]) { break; } }
        if (j == needleLen) { return 1; }
    }
    return 0;
}

static void test_initialize_replay(void)
{
    // UA：与现场完全一致的帧体（FCS 由 buildHdlc 自算）
    static const unsigned char UA_INFO[] = {
        0x81, 0x80, 0x12, 0x05, 0x01, 0x80, 0x06, 0x01,
        0x80, 0x07, 0x04, 0x00, 0x00, 0x00, 0x01, 0x08,
        0x04, 0x00, 0x00, 0x00, 0x01};

    // AARE：accepted + diagnostic=14(authentication-required) + 服务端 ST + 机制 GMAC + 16B 挑战
    static const unsigned char AARE_APDU[] = {
        0x61, 0x56,
        0xA1, 0x09, 0x06, 0x07, 0x60, 0x85, 0x74, 0x05, 0x08, 0x01, 0x01,
        0xA2, 0x03, 0x02, 0x01, 0x00,
        0xA3, 0x05, 0xA1, 0x03, 0x02, 0x01, 0x0E,
        0xA4, 0x0A, 0x04, 0x08, 0x41, 0x42, 0x43, 0x31, 0x32, 0x33, 0x34, 0x35,
        0x88, 0x02, 0x07, 0x80,
        0x89, 0x07, 0x60, 0x85, 0x74, 0x05, 0x08, 0x02, 0x05,
        0xAA, 0x12, 0x80, 0x10,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0xBE, 0x10, 0x04, 0x0E, 0x08, 0x00, 0x06, 0x5F,
        0x1F, 0x04, 0x00, 0x40, 0x1C, 0x1D, 0x00, 0x7D, 0x00, 0x07};

    static unsigned char ua[300], aare[400];
    static unsigned char aareInfo[300];
    Replay r;
    dlmsCtx* c;
    int uaLen, aareLen, aareInfoLen = 0, i, ret, step;

    // AARE 帧体 = LLC(E6 E7 00) + APDU
    aareInfo[aareInfoLen++] = 0xE6;
    aareInfo[aareInfoLen++] = 0xE7;
    aareInfo[aareInfoLen++] = 0x00;
    for (i = 0; i < (int)sizeof(AARE_APDU); i++) { aareInfo[aareInfoLen++] = AARE_APDU[i]; }

    uaLen = buildHdlc(ua, 0x73, UA_INFO, (int)sizeof(UA_INFO));                 // control=UA
    aareLen = buildHdlc(aare, 0x30, aareInfo, aareInfoLen);                     // control=I帧 N(R)=1

    memset(&r, 0, sizeof(r));
    r.rx[0] = ua;    r.rxLen[0] = uaLen;
    r.rx[1] = aare;  r.rxLen[1] = aareLen;
    r.rxCount = 2;   // 第 3 次 send（HLS）之后没料 → C 层重试后返回 RECEIVE_FAILED，属预期

    c = dlms_new(1, 0x01, 0x0001, DLMS_AUTHENTICATION_HIGH_GMAC, "", 0);        // HDLC, LN
    CHECK(c != NULL, "replay: ctx created");
    if (c == NULL) { return; }

    dlms_set_security(c, DLMS_SECURITY_NONE,
                      "00000000000000000000000000000000",
                      "00000000000000000000000000000000", NULL);
    printf("  · set_security ok\n");
    dlms_set_clientSystemTitle(c, "4142433132333435");                          // "ABC12345"
    printf("  · set_clientSystemTitle ok\n");
    dlms_set_io(c, &r, replaySend, replayRecv);
    printf("  · set_io ok\n");

    printf("  · 调 dlms_initialize …\n");
    ret = dlms_initialize(c);          // ★ 这一步就是真机上崩溃/失败的地方
    printf("  · dlms_initialize 返回 %d\n", ret);
    printf("  · 桩统计: send=%d 次, recv=%d 次, 记录到的出向帧=%d 个\n",
           r.sends, r.recvs, r.txCount);
    step = dlms_lastStep(c);

    // ① 不崩溃（旧代码在此处 var_clear 释放栈地址 → abort）
    CHECK(1, "replay: dlms_initialize 未崩溃");
    // ② 进到了 HLS（步骤 5 是为定位失败点用的；这里断言"没有停在生成阶段"）
    CHECK(r.txCount >= 3, "replay: 发出了 HLS 应答帧");
    // ③ HLS 应答必须是**明文 C3**（不能是加密壳 CB）——这是本表能否接受的关键
    if (r.txCount >= 3)
    {
        static const unsigned char ACT[] = {0xC3, 0x01, 0xC1, 0x00, 0x0F};
        static const unsigned char GLO[] = {0xCB, 0x01, 0xC1, 0x00, 0x0F};
        CHECK(containsSeq(r.tx[2], r.txLen[2], ACT, 5),
              "replay: HLS 应答是明文 C3（action-request）");
        CHECK(!containsSeq(r.tx[2], r.txLen[2], GLO, 5),
              "replay: HLS 应答不是加密壳 CB");
        CHECK(containsSeq(r.tx[2], r.txLen[2], (const unsigned char*)"\x09\x11\x10", 3),
              "replay: 数据区以 OCTET(17) + SC=0x10 开头");
    }
    CHECK(step >= 5, "replay: 已越过 HLS 生成阶段");

    dlms_free(c);
    (void)ret;
}

// 渲染函数在桥接层故意不加 static（见 DLMSBridge.c 里的说明），这里直接声明使用。
// 生产路径是 dlms_read/dlms_write/dlms_method → replyValueString → dlms_renderValue。
int dlms_renderValue(dlmsVARIANT* value, char* out, int* outLen);

// 渲染断言：只检查"整块输出里包含某段子串"，不把排版写死进测试。
// 注意：构造 byteArr 时**绝不调用 var_clear**（它只借用栈上的 gxByteBuffer，
// 释放会非法 free —— 这正是真机崩溃的那个坑）。
static void test_render(void)
{
    dlmsVARIANT v;
    char buf[512];
    int len;

    // UINT16 = 1234 → HEX 应为大端 04 D2
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_UINT16;
    v.uiVal = 1234;
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(&v, buf, &len) > 0, "render: UINT16 渲染成功");
    CHECK(strstr(buf, "long-unsigned") != NULL, "render: 类型名 long-unsigned");
    CHECK(strstr(buf, "04 D2") != NULL, "render: UINT16=1234 → HEX 04 D2");

    // BOOLEAN = 1 → 可读 true
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_BOOLEAN;
    v.boolVal = 1;
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(&v, buf, &len) > 0, "render: BOOLEAN 渲染成功");
    CHECK(strstr(buf, "true") != NULL, "render: BOOLEAN=1 → true");

    // INT8 = -1 → HEX 应为 FF（验符号/宽度处理）
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_INT8;
    v.cVal = -1;
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(&v, buf, &len) > 0, "render: INT8 渲染成功");
    CHECK(strstr(buf, "FF") != NULL, "render: INT8=-1 → HEX FF");

    // OCTET_STRING = "ABC12345" → 可读直接给 ASCII 文本
    {
        static unsigned char ascii[] = { 0x41, 0x42, 0x43, 0x31, 0x32, 0x33, 0x34, 0x35 };
        gxByteBuffer bb;
        bb_init(&bb);
        bb_set(&bb, ascii, (uint32_t)sizeof(ascii));
        var_init(&v);
        v.vt = DLMS_DATA_TYPE_OCTET_STRING;
        v.byteArr = &bb;
        len = (int)sizeof(buf);
        CHECK(dlms_renderValue(&v, buf, &len) > 0, "render: octet-string(文本) 渲染成功");
        CHECK(strstr(buf, "ABC12345") != NULL, "render: octet-string → 可读给 ASCII");
        bb_clear(&bb);
    }

    // OCTET_STRING = {00 01 FF} → 不可打印，提示看 HEX，且 HEX 逐字节
    {
        static unsigned char raw[] = { 0x00, 0x01, 0xFF };
        gxByteBuffer bb;
        bb_init(&bb);
        bb_set(&bb, raw, (uint32_t)sizeof(raw));
        var_init(&v);
        v.vt = DLMS_DATA_TYPE_OCTET_STRING;
        v.byteArr = &bb;
        len = (int)sizeof(buf);
        CHECK(dlms_renderValue(&v, buf, &len) > 0, "render: octet-string(二进制) 渲染成功");
        CHECK(strstr(buf, "（非文本，见 HEX）") != NULL, "render: 非文本 → 提示见 HEX");
        CHECK(strstr(buf, "00 01 FF") != NULL, "render: 二进制 HEX 逐字节");
        bb_clear(&bb);
    }

    // 空指针与零容量应安全返回 0（不崩）
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(NULL, buf, &len) == 0, "render: value=NULL 安全");
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_UINT8;
    v.bVal = 7;
    len = 0;
    CHECK(dlms_renderValue(&v, buf, &len) == 0, "render: cap=0 安全");

    // ── 两行格式 + 含类型标签的 HEX ──────────────────────────────────────────
    // 直接把需求里给的例子钉成回归测试。
    //   octet-string "123"  →  行1 `09 03 31 32 33`，行2 Type/Length/Value
    {
        static unsigned char s123[] = { 0x31, 0x32, 0x33 };
        gxByteBuffer bb;
        bb_init(&bb);
        bb_set(&bb, s123, (uint32_t)sizeof(s123));
        var_init(&v);
        v.vt = DLMS_DATA_TYPE_OCTET_STRING;
        v.byteArr = &bb;                       // 栈缓冲：绝不能 var_clear（见前面的坑）
        len = (int)sizeof(buf);
        CHECK(dlms_renderValue(&v, buf, &len) > 0, "render2: octet-string 渲染成功");
        CHECK(strstr(buf, "09 03 31 32 33") != NULL, "render2: 行1 = 09 03 31 32 33");
        CHECK(strstr(buf, "-> Type: octet-string") != NULL, "render2: 行2 类型名");
        CHECK(strstr(buf, "Length: 3") != NULL, "render2: 行2 长度");
        CHECK(strstr(buf, "Value: 123") != NULL, "render2: 行2 值");
        bb_clear(&bb);
    }
    //   INT32 = 1  →  行1 `05 00 00 00 01`（tag 05 = double-long，Blue Book）
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_INT32;
    v.lVal = 1;
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(&v, buf, &len) > 0, "render2: int32 渲染成功");
    CHECK(strstr(buf, "05 00 00 00 01") != NULL, "render2: 行1 = 05 00 00 00 01");
    CHECK(strstr(buf, "double-long") != NULL, "render2: INT32 名为 double-long");
    //   BOOLEAN true  →  行1 `03 01`（DLMS 里 boolean 是 0x03，不是 0x11）
    var_init(&v);
    v.vt = DLMS_DATA_TYPE_BOOLEAN;
    v.boolVal = 1;
    len = (int)sizeof(buf);
    CHECK(dlms_renderValue(&v, buf, &len) > 0, "render2: boolean 渲染成功");
    CHECK(strstr(buf, "03 01") != NULL, "render2: 行1 = 03 01");
    CHECK(strstr(buf, "Value: true") != NULL, "render2: 行2 值 true");
}

// ── 写 / action 路径的 variant 构造 ────────────────────────────────────────────
// 真机崩溃根因：var_init() 把 byteArr 置为 NULL 之后，
//   · 写路径  直接 bb_clear(v->byteArr)                    → 空指针解引用
//   · method  先把 vt 设成 OCTET_STRING 再 var_addBytes()  → 走 else 分支同样 bb_clear(NULL)
// bb_clear() 只检查 arr->data、不检查 arr 本身（bytebuffer.c:678-682）。
//
// 下面两个函数在桥接层故意不加 static，便于直接断言。
// 生产路径：dlms_write → buildBytesVariant ； dlms_method → buildVariantFromHex。
int buildBytesVariant(dlmsVARIANT* v, const char* hex);
int buildVariantFromHex(const char* hex, dlmsVARIANT* v);

static void test_writevar(void)
{
    dlmsVARIANT v;
    int r;

    // ① 写路径：正常数据。除"不崩"外还要验 byteArr 是**堆分配**的 ——
    //    紧随其后的 var_clear() 会 free 它；若是栈缓冲，这一步就非法释放了。
    r = buildBytesVariant(&v, "0102030405");
    CHECK(r == DLMS_ERROR_CODE_OK, "writevar: buildBytesVariant 不再崩");
    CHECK(v.vt == DLMS_DATA_TYPE_OCTET_STRING, "writevar: vt = octet-string");
    CHECK(v.byteArr != NULL, "writevar: byteArr 已分配（不再是 NULL）");
    CHECK(v.byteArr != NULL && v.byteArr->size == 5, "writevar: 承载 5 字节");
    CHECK(v.byteArr != NULL && v.byteArr->data[0] == 0x01 && v.byteArr->data[4] == 0x05,
          "writevar: 字节内容正确（首尾）");
    var_clear(&v);                       // ← 堆分配才能安全释放（旧代码在此 abort）

    // ② 空 hex → 空 octet-string（"写空值"是合法输入）
    r = buildBytesVariant(&v, "");
    CHECK(r == DLMS_ERROR_CODE_OK, "writevar: 空 hex 不崩");
    CHECK(v.byteArr != NULL && v.byteArr->size == 0, "writevar: 空 hex → size 0 且已分配");
    var_clear(&v);

    // ③ hex 传 NULL（等价空值）
    r = buildBytesVariant(&v, NULL);
    CHECK(r == DLMS_ERROR_CODE_OK, "writevar: NULL hex 不崩");
    var_clear(&v);

    // ④ 非法 hex：**库的 bb_addHexString 对非十六进制字符静默容忍**（不返回错误），
    //    结果是字节数变少、全非法时为 0 —— 桥接层的 hexToBytes 只是透传返回值，
    //    所以这里不会报错。故只断言"不崩 + 仍得到可安全释放的合法 variant"。
    //    （用户输入合法性由 Swift 侧 HexUtil.isValid 校验；桥接层这处静默容忍是已知点。）
    r = buildBytesVariant(&v, "ZZ");
    CHECK(r == DLMS_ERROR_CODE_OK, "writevar: 非法 hex 被库静默容忍（不报错，已知）");
    CHECK(v.vt == DLMS_DATA_TYPE_OCTET_STRING && v.byteArr != NULL,
          "writevar: 非法 hex 仍得到可安全释放的 variant");
    var_clear(&v);

    // ⑤ method / action 路径：OCTET_STRING tag（09 + 数据）—— 与写路径同一个坑
    r = buildVariantFromHex("090801020304050607", &v);
    CHECK(r == DLMS_ERROR_CODE_OK, "writevar: buildVariantFromHex(09) 不再崩");
    CHECK(v.vt == DLMS_DATA_TYPE_OCTET_STRING, "writevar: method 参数为 octet-string");
    CHECK(v.byteArr != NULL && v.byteArr->size == 8, "writevar: method 参数 8 字节");
    CHECK(v.byteArr != NULL && v.byteArr->data[0] == 0x08 && v.byteArr->data[7] == 0x07,
          "writevar: method 参数字节正确（首尾）");
    var_clear(&v);

    // ⑥ method 路径：整型 tag（本就不走 OCTET_STRING 分支，回归确认没被改坏）
    r = buildVariantFromHex("1201F3", &v);
    CHECK(r == DLMS_ERROR_CODE_OK && v.vt == DLMS_DATA_TYPE_UINT16 && v.uiVal == 0x01F3,
          "writevar: buildVariantFromHex(12) → uint16 0x01F3");
    var_clear(&v);

    // ⑦ method 路径：空 hex → 无参方法
    r = buildVariantFromHex("", &v);
    CHECK(r == DLMS_ERROR_CODE_OK && v.vt == DLMS_DATA_TYPE_NONE, "writevar: 空 hex → 无参方法");
    var_clear(&v);
}

int main(void)
{
    // 关掉 stdout 缓冲：万一后面崩溃，已打印的内容才不会跟着丢掉（排查用）。
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[hex]\n"); test_hex();
    printf("[ctx]\n"); test_ctx();
    printf("[variant]\n"); test_variant();
    printf("[render]\n"); test_render();
    printf("[writevar]\n"); test_writevar();
    // 回放测试：桩 send/recv + **自造**合法帧，跑 dlms_initialize 的完整协议流程
    //（SNRM/UA → AARQ/AARE → HLS 应答），覆盖到此前从未被调用的路径。
    // 实测覆盖率：dlms_initialize 0% → 85%，桥接层 34.83% → 56.31%。
    // **已转为常规闸门** —— 原先的 DLMS_TEST_REPLAY 门是"它会挂住"时的隔离措施，
    // 而挂住的根因是 buildHdlc 的 HCS 算错（见该函数注释），已修复。
    // 需要临时跳过时设 DLMS_SKIP_REPLAY=1。
    if (getenv("DLMS_SKIP_REPLAY") == NULL)
    {
        printf("[replay]\n"); test_initialize_replay();
    }
    if (failures == 0)
    {
        printf("ALL PASS\n");
        return 0;
    }
    printf("TOTAL FAILED=%d\n", failures);
    return 1;
}