// mock_meter.c —— 本地“模拟表”：在 loopback 上监听，按规则应答 Wrapper 帧。
//
// 目的：让协议/传输层能在**本机**（以及 Linux CI）被端到端驱动，不必依赖真表和 App。
// 它刻意模仿真表的“怪癖”——尤其是**把一帧拆成多段、段间还留间隔**——因为
// “长响应被 TCP 拆开导致丢数据/解析失败”正是真机上最难复现的那类问题（P2）。
//
// 用法：
//   mock_meter [--port N] [--frag N] [--delay-ms N] [--silent-after N] [--quiet] [--no-auth]
//     --no-auth     AARQ 用**不要求认证**的 AARE 应答（配合 local_e2e --auth none，
//                   让建链+读/写/执行/断链整条链路在本地真正跑通）
//     --port        监听端口（默认 40599）
//     --frag        每个响应按 N 字节分片发送（0/缺省 = 一次性整帧；建议 8~16 做压力）
//     --delay-ms    分片之间的间隔毫秒（默认 0）
//     --silent-after 发完 N 个响应后不再应答（用来验证客户端有界退出/超时重试）
//     --quiet       不打印逐帧日志
//
// 说明：本工具只做 Wrapper 封装（生产实际用的就是它），且**只实现到“让客户端能走下去”
// 的程度**——它的价值在传输行为，不在做一台完整合规的 DLMS 服务器。
//
// 退出码：0 正常（打印统计）；1 参数/套接字错误。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sock_compat.h"

#define ACC_CAP 8192

// 8 字节 Wrapper 头：00 01 | source(2) | target(2) | length(2)，随后是 length 字节 payload。
// 返回整帧长度；放不下时返回 -1（**不静默溢出**）。
static int wrapFrame(unsigned char* out, int cap, const unsigned char* pl, int plLen,
                     int src, int tgt)
{
    if (plLen < 0 || 8 + plLen > cap)
    {
        return -1;
    }
    out[0] = 0x00; out[1] = 0x01;
    out[2] = (unsigned char)((src >> 8) & 0xFF); out[3] = (unsigned char)(src & 0xFF);
    out[4] = (unsigned char)((tgt >> 8) & 0xFF); out[5] = (unsigned char)(tgt & 0xFF);
    out[6] = (unsigned char)((plLen >> 8) & 0xFF); out[7] = (unsigned char)(plLen & 0xFF);
    memcpy(out + 8, pl, (size_t)plLen);
    return 8 + plLen;
}

// AARE：accepted + result-source-diagnostic=14(要求认证) + 服务端 SystemTitle
//       + 机制 HighGMAC(…02 05) + 16 字节挑战 + initiate-response。
// 与 Tests/CTests/test_dlms.c 里用的是同一份内容（自造、非手抄）。
static unsigned char AARE_PL[] = {
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
    0x1F, 0x04, 0x00, 0x40, 0x1C, 0x1D, 0x00, 0x7D, 0x00, 0x07
};

// **不要求认证**的 AARE（`--no-auth` 时用它）。
//
// 为什么必须有这一份：`apdu.c:1267` 在解析 AARE 时会按 `89` 机制字段**覆写**
// `settings->authentication` —— 所以哪怕客户端配置成 NONE，只要 AARE 里带
// `89 07 60 85 74 05 08 02 05`(HighGMAC)，客户端仍会被改成 HLS-GMAC 并进入挑战应答；
// 而本 mock **不链接 DLMS 库**、算不出 GMAC（客户端会逐字节校验 17B 的 SC+IC+GMAC），
// 于是永远卡在建链第 6 步。
//
// 与 AARE_PL 的差别只有三处：
//   ① 诊断 `14`(authentication-required) → `00`(无原因，即不要求认证)
//   ② **删掉 `89` 机制字段**（它就是覆写 authentication 的元凶）
//   ③ 删掉 `AA`(server-to-client challenge) —— 不要求认证时服务端不下发挑战
// 长度：11+5+7+12+4+18 = 57 = 0x39。
static unsigned char AARE_NONE_PL[] = {
    0x61, 0x39,
    0xA1, 0x09, 0x06, 0x07, 0x60, 0x85, 0x74, 0x05, 0x08, 0x01, 0x01,
    0xA2, 0x03, 0x02, 0x01, 0x00,
    0xA3, 0x05, 0xA1, 0x03, 0x02, 0x01, 0x00,
    0xA4, 0x0A, 0x04, 0x08, 0x41, 0x42, 0x43, 0x31, 0x32, 0x33, 0x34, 0x35,
    0x88, 0x02, 0x07, 0x80,
    0xBE, 0x10, 0x04, 0x0E, 0x08, 0x00, 0x06, 0x5F,
    0x1F, 0x04, 0x00, 0x40, 0x1C, 0x1D, 0x00, 0x7D, 0x00, 0x07
};

/// `--no-auth`：AARQ 用不要求认证的 AARE 应答（配合 local_e2e --auth none）。
static int gNoAuth = 0;

// Action-Response-Normal。布局同 GET/SET：`<tag> <type> <invoke-id> <result> …`
//（`dlms_handleMethodResponse` 先读 type、再读 invokeId，`dlms.c` 内 `Get type.` 那段）。
//
// ⚠️ 旧值 `C7 01 C1 00 01 00` 同样是**按猜的**：invokeId=0xC1 ✗ 且多 2 字节。
// 改成 `C7 01 01 00` 后，e2e 里那条 `dlms_method` 才真的在验"action-response 解析"。
//
// ⚠️ 但 HLS 建链那一步**仍然过不去**：`cl_parseApplicationAssociationResponse` 要求应答里带
// 一段 17 字节的 OCTET STRING（服务端 SC+IC+GMAC）并**逐字节校验**，
// 而本 mock 不链接 DLMS 库、算不出 GMAC → 这条路径在本地桩上**结构性验不了**
//（真表已验过，见方案文档里程碑）。这里只把布局改对，不再让"格式错"掩盖"算不出 GMAC"。
static unsigned char HLS_OK_PL[] = { 0xC7, 0x01, 0x01, 0x00 };
// Get-Response：invoke-id=1、result=0(data)，data = octet-string(1 字节 0x2A)。
// Get-Response-Normal。布局同 SET：`<tag> <type> <invoke-id> <result> <data…>`
//（`dlms_handleGetResponse` 先读 type、再读 invokeId，`dlms.c:3929/3938`）。
//
// ⚠️ 旧值 `C4 01 C1 00 01 00 09 01 2A` 是**按猜的**写的：解析成 type=1 ✓、invokeId=0xC1 ✗，
// result=0，随后把 `01 00` 当成 **array(0 个元素)**，`09 01 2A` 成了没人消费的尾巴 →
// 读出来的"值"是 `-> Type: array, Value: {}`（**空壳**），而 `read ret=0` 照样成立。
// 即"read 是有效断言"也是错的 —— 它一直在验一个空数组。改成正确布局后才会真的验到 octet-string。
static unsigned char GET_OK_PL[] = { 0xC4, 0x01, 0x01, 0x00, 0x09, 0x01, 0x2A };
// Set-Response-Normal。布局是 `<tag> <type> <invoke-id> <result>` ——
// `dlms_handleSetResponse` **先读 type、再读 invokeId**（`dlms.c:4561/4568`），
// 所以 invoke-id 在**第二个**字节，不是第一个。
//
// ⚠️ 旧值 `C5 01 00` 只有 3 字节：type=1 ✓、invokeId=0 ✗、且**缺 result 字节** →
// 解析时 `bb_getUInt8` 读越界 → 直接返回 `OUTOFMEMORY(260)`（见 `bytebuffer.c` 的
// `if (arr->position >= arr->size) return OUTOFMEMORY;`）。
// 这正是长期挂着的 **`dlms_write ret=260`** 的根因 —— **是桩的报文错了，不是产品代码**。
static unsigned char SET_OK_PL[] = { 0xC5, 0x01, 0x01, 0x00 };
// Release-Response。依据 enums.h:1228/1233：RELEASE_REQUEST=0x62 / RELEASE_RESPONSE=0x63。
// 注意方向：0x62 才是**请求**、0x63 是**响应** —— 客户端不会把 0x63 当请求发出来，
// 所以下面不为 0x63 配规则（早期版本写成 0x63→0x64，两个都不是 release 语义，是错的）。
// 内容：`<tag 63> <result 00=accepted>`（Release-Response 没有 invoke-id 字段）。
// 注：客户端侧 `dlms.c:5260` 对 RELEASE_RESPONSE 直接 `break`（**完全不解析内容**），
// 所以这里改成标准形态只是保真，不影响行为。
static unsigned char REL_OK_PL[] = { 0x63, 0x00 };

static int contains(const unsigned char* hay, int n, const unsigned char* needle, int m)
{
    int i, j;
    if (m <= 0 || n < m) { return 0; }
    for (i = 0; i <= n - m; i++)
    {
        for (j = 0; j < m; j++) { if (hay[i + j] != needle[j]) { break; } }
        if (j == m) { return 1; }
    }
    return 0;
}

// 按请求内容挑一个响应。返回响应 payload 长度，*respOut 指向 payload（0 = 不应答）。
// 入参/出参**刻意用不同名字**：早期版本写成 `plLen = pickResponse(pl, plLen, &pl)`，
// 实参与出参同名 —— C 语义正确（实参先求值）但极易被后来人改错。
static int pickResponse(const unsigned char* req, int reqLen, unsigned char** respOut)
{
    static const unsigned char HLS_ACT[] = { 0xC3, 0x01, 0xC1, 0x00, 0x0F };
    static const unsigned char HLS_GLO[] = { 0xCB, 0x01, 0xC1, 0x00, 0x0F };
    if (reqLen <= 0) { return 0; }
    if (req[0] == 0x60)                                                             // AARQ → AARE
    {
        if (gNoAuth) { *respOut = AARE_NONE_PL; return (int)sizeof(AARE_NONE_PL); }
        *respOut = AARE_PL; return (int)sizeof(AARE_PL);
    }
    if (contains(req, reqLen, HLS_ACT, 5) || contains(req, reqLen, HLS_GLO, 5))
    { *respOut = HLS_OK_PL; return (int)sizeof(HLS_OK_PL); }                        // HLS 认证
    // tag 取值已核对 enums.h：GET_REQUEST=0xC0、SET_REQUEST=0xC1、RELEASE_REQUEST=0x62。
    if (req[0] == 0xC0) { *respOut = GET_OK_PL; return (int)sizeof(GET_OK_PL); }    // Get-Request
    if (req[0] == 0xC1) { *respOut = SET_OK_PL; return (int)sizeof(SET_OK_PL); }    // Set-Request
    if (req[0] == 0x62) { *respOut = REL_OK_PL; return (int)sizeof(REL_OK_PL); }    // Release-Request
    return 0;                                                                       // 其他：不应答
}

int main(int argc, char** argv)
{
    int port = 40599, frag = 0, delayMs = 0, silentAfter = 0, quiet = 0, i;
    int replies = 0, reqs = 0;
    sock_t srv, cli;
    struct sockaddr_in a;
    unsigned char acc[ACC_CAP];
    int accLen = 0;
    unsigned char out[4096];

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) { port = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--frag") && i + 1 < argc) { frag = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--delay-ms") && i + 1 < argc) { delayMs = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--silent-after") && i + 1 < argc) { silentAfter = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--quiet")) { quiet = 1; }
        else if (!strcmp(argv[i], "--no-auth")) { gNoAuth = 1; }
        else { printf("unknown arg: %s\n", argv[i]); return 1; }
    }

    if (sock_init() != 0) { printf("mock: socket init failed\n"); return 1; }
    srv = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (srv == SOCK_INVALID) { printf("mock: socket() failed\n"); return 1; }
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    {
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (const char*)&one, sizeof(one));
    }
    if (bind(srv, (struct sockaddr*)&a, sizeof(a)) != 0) { printf("mock: bind %d failed\n", port); return 1; }
    if (listen(srv, 1) != 0) { printf("mock: listen failed\n"); return 1; }
    printf("mock: listening 127.0.0.1:%d (frag=%d delay=%dms silentAfter=%d)\n",
           port, frag, delayMs, silentAfter);
    cli = accept(srv, NULL, NULL);
    if (cli == SOCK_INVALID) { printf("mock: accept failed\n"); return 1; }
    printf("mock: client connected\n");

    // 主循环：累积字节 → 凑出一个完整 Wrapper 帧 → 按规则应答（可分段）
    for (;;)
    {
        int n, plLen, respLen, total;
        unsigned char* pl = NULL;
        unsigned char* respPl = NULL;
        if (!sock_wait_readable(cli, 2000))
        {
            printf("mock: idle timeout, closing (reqs=%d replies=%d)\n", reqs, replies);
            break;
        }
        n = recv(cli, (char*)acc + accLen, ACC_CAP - accLen, 0);
        if (n <= 0)
        {
            printf("mock: peer closed (reqs=%d replies=%d)\n", reqs, replies);
            break;
        }
        accLen += n;
        // 凑帧：8 字节头 + 声明长度
        if (accLen < 8) { continue; }
        plLen = (acc[6] << 8) | acc[7];
        if (accLen < 8 + plLen) { continue; }        // 还没收全（这正是真链路上的常态）
        reqs++;
        pl = acc + 8;
        if (!quiet)
        {
            printf("mock: req#%d len=%d tag=%02X\n", reqs, plLen, (plLen > 0 ? pl[0] : 0));
        }

        // ★ 必须在消费该帧**之前**决定响应。
        //   下面的 memmove 会把后续字节前移：只要缓冲区里堆了两帧（客户端重传/粘包时很常见），
        //   pl 指向的内容就会被覆盖，拿被覆盖的字节去匹配规则会给出错误响应。
        //   早期版本先 memmove 再 pickResponse —— 只有"缓冲区里恰好只有一帧"时才碰巧正确，
        //   这很可能就是分片场景下 mock 行为不稳定的来源。
        respLen = 0;
        if (silentAfter > 0 && replies >= silentAfter)
        {
            if (!quiet) { printf("mock: 已达 --silent-after=%d，不再应答（测客户端有界退出）\n", silentAfter); }
        }
        else
        {
            respLen = pickResponse(pl, plLen, &respPl);
        }

        // 消费该帧（把剩余字节前移）—— 此后 pl 不再有效
        memmove(acc, acc + 8 + plLen, (size_t)(accLen - 8 - plLen));
        accLen -= 8 + plLen;

        if (respLen <= 0) { if (!quiet) { printf("mock: 无匹配规则，不应答\n"); } continue; }
        total = wrapFrame(out, (int)sizeof(out), respPl, respLen, 1, 1);
        if (total <= 0) { printf("mock: 响应放不下缓冲，丢弃\n"); continue; }
        if (frag > 0)
        {
            int off = 0, k = 0;
            while (off < total)
            {
                int chunk = (total - off < frag) ? (total - off) : frag;
                if (send(cli, (const char*)out + off, chunk, 0) <= 0) { break; }
                off += chunk; k++;
                if (delayMs > 0) { sock_sleep_ms(delayMs); }
            }
            if (!quiet) { printf("mock: 应答 %d 字节，分 %d 片发出\n", total, k); }
        }
        else
        {
            send(cli, (const char*)out, total, 0);
            if (!quiet) { printf("mock: 应答 %d 字节（整帧）\n", total); }
        }
        replies++;
    }

    sock_close(cli);
    sock_close(srv);
    sock_fini();
    printf("MOCK_DONE reqs=%d replies=%d\n", reqs, replies);
    return 0;
}
