// local_e2e.c —— 本地端到端：DLMSBridge + **真实 TCP socket** ↔ tools/mock_meter
//
// 为什么需要它：绝大多数真 bug 都不在 UI，而在“协议 + 传输”这条链上
// （写/action 崩溃、HLS 明文/加密之争、长响应被 TCP 拆开丢数据…）。
// 但这条链过去只有两条验证途径：① 桩回放（不经真实 socket）② 真表（慢、不可控）。
// 这个程序补上中间那层：**真 socket + 可控的坏链路行为**，在本机即可复现。
//
// 用法（由 Tests/CTests/run.sh 编排）：
//   local_e2e [--port N] [--scenario basic|fragile|silent] [--recv-timeout-ms N]
//             [--dump-rx] [--dump-frames] [--auth none|gm]
//     --dump-frames：打印每个 TX/RX 帧的原始十六进制（排查"卡在第几步"用）
//     --auth none   ：跳过 HLS 挑战应答（mock 不链接 DLMS 库、算不出 GMAC，
//                     所以 HLS-GMAC 那条路径在本地桩上结构性验不了）
//     basic  ：正常会话（connect → 读 → 写 → 执行 → 断开），**强断言**
//     fragile：分片退化观察，只断言"不崩不挂 + 重试有界"
//     silent ：模拟表若干帧后不再应答 —— 验证客户端**有界退出**（不挂死）
//     --recv-timeout-ms：单次 recv 等待上限（默认 3000，与 App 侧一致）
//
// 退出码：0 全过；非 0 = 失败数。

#include "DLMSCore.h"
#include "enums.h"
#include "errorcodes.h"   // DLMS_ERROR_CODE_* 在这里（DLMSCore.h 只暴露不透明类型，不含它）
#include "sock_compat.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if ((cond)) { printf("  ok: %s\n", (msg)); } \
    else { printf("  FAIL: %s\n", (msg)); ++failures; } \
} while (0)

typedef struct
{
    sock_t fd;
    int sends;
    int recvs;
    int txBytes;
    int recvTimeouts;
    int recvTimeoutMs;
    int traceTx;                       // trace 回调收到的 TX/RX 次数
    int traceRx;
    int dump;                          // --dump-rx：逐次打印接收缓冲的 size/position
    int dumpFrames;                    // --dump-frames：打印每个 TX/RX 帧的原始十六进制
    dlmsCtx* ctx;                      // 供诊断查询（dlms_rxSize/dlms_rxPosition）
} Io;

// 与 dlmsSendFn 对齐
static int ioSend(void* user, const unsigned char* data, int len)
{
    Io* io = (Io*)user;
    int off = 0;
    while (off < len)
    {
        int n = send(io->fd, (const char*)data + off, len - off, 0);
        if (n <= 0) { return -1; }
        off += n;
    }
    io->sends++;
    io->txBytes += len;
    return 0;
}

// 与 dlmsRecvFn 对齐。**必须带超时**，否则测试会永久阻塞
//（App 侧 receive(max:) 超时返回 nil 就是这个语义）。
static int ioRecv(void* user, unsigned char* buf, int cap, int* got)
{
    Io* io = (Io*)user;
    int n;
    if (got != NULL) { *got = 0; }
    if (!sock_wait_readable(io->fd, io->recvTimeoutMs))
    {
        io->recvTimeouts++;
        return -1;
    }
    n = recv(io->fd, (char*)buf, cap, 0);
    if (n <= 0) { return -1; }
    if (got != NULL) { *got = n; }
    io->recvs++;
    if (io->dump)
    {
        // 打印的是**本次 append 之前**的累积状态：若库在"数据不够"时正确回退了游标，
        // 这里应看到 size 递增而 position 恒为 0。
        printf("     [rx] recv#%d got=%d  ->  size=%d position=%d\n",
               io->recvs, n, dlms_rxSize(io->ctx), dlms_rxPosition(io->ctx));
    }
    return 0;
}

// 与 dlmsTraceFn 对齐（direction 1=TX / 2=RX）。挂上它同时覆盖 dlms_set_trace。
static void ioTrace(void* user, int direction, const unsigned char* frame, int len)
{
    Io* io = (Io*)user;
    int i;
    if (direction == 1) { io->traceTx++; }
    else { io->traceRx++; }
    // --dump-frames：把每个 TX/RX 帧的原始十六进制打出来。
    // 排查"建链卡在第几步"时**必须看到实际字节** —— 光有 ret= 只能知道失败，
    // 看不出客户端发的是明文 `C3` 还是密文 `CB`（HLS 那一步的关键区别）。
    if (io->dumpFrames && frame != NULL && len > 0)
    {
        printf("[frame] %s len=%d ", direction == 1 ? "TX" : "RX", len);
        for (i = 0; i < len; ++i)
        {
            printf("%02X", frame[i]);
            if (i + 1 < len) { printf(" "); }
        }
        printf("\n");
    }
}

// 0.0.40.0.0.255 —— Association LN
static const unsigned char OBIS_ASSOC[6] = { 0, 0, 40, 0, 0, 255 };

int main(int argc, char** argv)
{
    int port = 40599, i, tryConnect;
    int authHighGmac = 1;              // --auth none 时置 0（跳过 HLS）
    const char* scenario = "basic";
    sock_t fd = SOCK_INVALID;
    struct sockaddr_in a;
    Io io;
    dlmsCtx* c;
    char out[4096];
    int outLen, r1, r2, r3, r4, r5;

    setvbuf(stdout, NULL, _IONBF, 0);
    memset(&io, 0, sizeof(io));
    io.recvTimeoutMs = 3000;              // 默认对齐 App 侧；压力场景由 run.sh 调小
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) { port = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--scenario") && i + 1 < argc) { scenario = argv[++i]; }
        else if (!strcmp(argv[i], "--recv-timeout-ms") && i + 1 < argc) { io.recvTimeoutMs = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--dump-rx")) { io.dump = 1; }
        else if (!strcmp(argv[i], "--dump-frames")) { io.dumpFrames = 1; }
        else if (!strcmp(argv[i], "--auth") && i + 1 < argc)
        {
            // none = 跳过 HLS（本地能验完整链路）；gm = HLS-GMAC（需服务端算 GMAC，桩验不了）
            authHighGmac = strcmp(argv[++i], "gm") == 0;
        }
        else { printf("e2e: 未知参数 %s\n", argv[i]); return 1; }
    }
    // scenario 白名单：未知值直接报错退出，避免悄悄按某个分支跑
    if (strcmp(scenario, "basic") != 0 && strcmp(scenario, "silent") != 0)
    {
        printf("e2e: 未知 scenario '%s'（应为 basic/silent）\n", scenario);
        return 1;
    }
    printf("[e2e] scenario=%s port=%d recvTimeout=%dms\n", scenario, port, io.recvTimeoutMs);

    if (sock_init() != 0) { printf("e2e: socket init failed\n"); return 1; }
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");

    // 重试连接：不再依赖外层脚本 `sleep`（慢机器/CI 上会变成假失败）
    for (tryConnect = 0; tryConnect < 50; tryConnect++)
    {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd == SOCK_INVALID) { printf("e2e: socket() failed\n"); return 1; }
        if (connect(fd, (struct sockaddr*)&a, sizeof(a)) == 0) { break; }
        sock_close(fd);
        fd = SOCK_INVALID;
        sock_sleep_ms(100);
    }
    if (fd == SOCK_INVALID)
    {
        printf("e2e: 连不上 127.0.0.1:%d（重试 %d 次后放弃）——mock_meter 起了吗？\n", port, tryConnect);
        return 1;
    }
    io.fd = fd;
    printf("[e2e] connected\n");

    // 配置与现场一致：Wrapper / 客户端 1 / 服务端 1 / HLS-GMAC / 信息加密 = NONE / ST = ABC12345
    //
    // ⚠️ `--auth none` 的意义：HLS-GMAC 下 `cl_parseApplicationAssociationResponse` 要求服务端
    //    回一个 17 字节的 OCTET STRING（SC+IC+GMAC）并**逐字节校验**它。
    //    而 `tools/mock_meter.c` **不链接 DLMS 库**、算不出 GMAC → 无论如何都过不了这一步。
    //    所以那条路径在本地桩上**结构性地验不了**（真表验过，见方案文档里程碑）。
    //    把认证换成 NONE 就能跳过 HLS，让建链 + 读/写/执行/断链整条链路**在本地真正跑通**。
    c = dlms_new(1, 0x01, 0x0001, authHighGmac ? DLMS_AUTHENTICATION_HIGH_GMAC
                                               : DLMS_AUTHENTICATION_NONE, "",
                 DLMS_INTERFACE_TYPE_WRAPPER);
    CHECK(c != NULL, "e2e: dlms_new(Wrapper) 成功");
    if (c == NULL) { return 1; }
    dlms_set_security(c, DLMS_SECURITY_NONE,
                      "00000000000000000000000000000000",   // GUEK
                      "00000000000000000000000000000000",   // GUAK
                      NULL);
    dlms_set_clientSystemTitle(c, "4142433132333435");       // "ABC12345"
    dlms_set_io(c, &io, ioSend, ioRecv);
    dlms_set_trace(c, &io, ioTrace);
    io.ctx = c;                        // 供 --dump-rx 查询接收缓冲状态

    printf("[e2e] 建链…\n");
    r1 = dlms_initialize(c);
    printf("[e2e] initialize ret=%d(%s) step=%d(%s) sendFailed=%d sends=%d recvs=%d timeouts=%d\n",
           r1, dlms_error_string(r1), dlms_lastStep(c), dlms_step_name(dlms_lastStep(c)),
           dlms_sendFailed(c), io.sends, io.recvs, io.recvTimeouts);
    // 能执行到这里本身就证明了"未崩溃、未挂死"（崩了/挂了都到不了这行）——
    // 所以下面不再用 CHECK(1,...) 制造"看起来验证过"的假象，只把事实打出来。
    printf("  ·  dlms_initialize 已返回（未崩溃/未挂死）\n");

    if (strcmp(scenario, "silent") != 0)
    {
        // 建链断言**按认证方式分开**（"能断言就必须断言"）：
        //
        // · auth=NONE：整条建链必须**真返回 0**。这才是"验到实质"。
        //   此前从没有过这条 —— 于是"建链到底通不通"在 CI 里**从未被验证过**。
        //
        // · HLS-GMAC（默认）：**在本地桩上结构性无法成功**，别拿它当真失败：
        //   服务端必须回一个 17 字节的 OCTET STRING（SC+IC+GMAC），
        //   而客户端在 `cl_parseApplicationAssociationResponse` 里会**逐字节校验**它
        //   （用服务端 SystemTitle 作密钥重算 GMAC）；`tools/mock_meter.c` 不链接
        //   DLMS 库、算不出 GMAC → 永远过不了第 6 步。
        //   所以这里只断言"已越过 AARQ/AARE"（step>=5 意味着 AARE 已被接受并已发起 HLS）
        //   —— 这是该场景下**能拿到的最强证据**。真表上的 HLS 关联已通过（方案文档里程碑）。
        //
        // 分片到货同样成立 —— 分片曾是长期"已知退化"，根因是桥接层 bufAppend 误用
        // bb_insert（它不更新 size、把 index 当源偏移），已修复。
        if (authHighGmac)
        {
            CHECK(dlms_lastStep(c) >= 5,
                  "e2e: Wrapper 建链已越过 AARQ/AARE（HLS-GMAC 在桩上结构性验不了，见注释）");
        }
        else
        {
            CHECK(r1 == DLMS_ERROR_CODE_OK,
                  "e2e: Wrapper 建链**成功**（auth=NONE：AARQ/AARE 全程真返回 0）");
        }

        outLen = (int)sizeof(out);
        out[0] = '\0';
        r2 = dlms_read(c, OBIS_ASSOC, DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME, 2, out, &outLen);
        printf("[e2e] read ret=%d(%s) outLen=%d\n", r2, dlms_error_string(r2), outLen);
        // 把**解析出来的值**打出来。只断言"ret==0 且有 -> 行"是不够的 ——
        // 桩若把响应的类型/长度字节写错，解析出的可能是个**空数组**之类的空壳，
        // 照样满足那两条断言（实测踩过：与 SET 同源的布局错误）。
        printf("[e2e] read 解析结果:\n%s\n", out);
        printf("  ·  dlms_read 已返回（未崩溃/未挂死）\n");
        CHECK(r2 == DLMS_ERROR_CODE_OK && outLen > 0,
              "e2e: dlms_read 端到端成功（收到响应并渲染出可读文本）");
        CHECK(strstr(out, "\n-> ") != NULL,
              "e2e: 解析面板拿到值树块（含类型标签 HEX + -> 类型行）");
        // ★ 断言**解析出来的值本身**，而不只是"有类型行"。
        //
        // 只验"ret==0 且有 -> 行"是不够的：桩的 Get-Response 布局曾写错
        // （`C4 01 C1 00 01 00 09 01 2A`），解析出的"值"其实是 **`01 00` = 空数组**，
        // 渲染成 `-> array(0)` —— ret=0、断言全过但值是空的。
        // 改成正确布局 `C4 01 01 00 09 01 2A` 后才真解析出 octet-string(0x2A)。
        CHECK(strstr(out, "09 01 2A") != NULL && strstr(out, "octet-string") != NULL
              && strstr(out, "-> octet-string(1) *") != NULL,
              "e2e: dlms_read 解析出的值正确（09 01 2A -> -> octet-string(1) \"*\"）");

        outLen = (int)sizeof(out);
        r3 = dlms_write(c, OBIS_ASSOC, DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME, 2,
                        "01020304", out, &outLen);
        printf("[e2e] write ret=%d(%s)\n", r3, dlms_error_string(r3));
        // 强断言：写必须**端到端成功**。
        //
        // 原来这里只写 `r3 != INVALID_PARAMETER` —— 于是 `write ret=260(OUTOFMEMORY)`
        // 长期被放行、CI 全绿。260 的真相：**桩的 Set-Response 报文缺了 result 字节**
        // （旧常量 `C5 01 00`，而布局是 `<tag> <type> <invoke-id> <result>`），
        // 解析时 `bb_getUInt8` 读越界 → 直接返回 OUTOFMEMORY。
        // **是桩错了，不是产品代码** —— 修 SET_OK_PL 后 write 各档全返回 0。
        CHECK(r3 == DLMS_ERROR_CODE_OK,
              "e2e: dlms_write 端到端成功（Set-Response 已正确解析）");

        outLen = (int)sizeof(out);
        r4 = dlms_method(c, OBIS_ASSOC, DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME, 1,
                         "0908112233", out, &outLen);
        printf("[e2e] method ret=%d(%s)\n", r4, dlms_error_string(r4));
        CHECK(r4 == DLMS_ERROR_CODE_OK,
              "e2e: dlms_method 端到端成功");
    }
    else
    {
        // 模拟表已不应答：必须**快速有界失败**，不能挂住。
        // 有界性来自两处：recv 超时 4 次（fail>3）+ dlmsSendFrame 的总轮次上限。
        outLen = (int)sizeof(out);
        r2 = dlms_read(c, OBIS_ASSOC, DLMS_OBJECT_TYPE_ASSOCIATION_LOGICAL_NAME, 2, out, &outLen);
        printf("[e2e] silent 场景 read ret=%d(%s)，timeouts=%d\n",
               r2, dlms_error_string(r2), io.recvTimeouts);
        CHECK(r2 != DLMS_ERROR_CODE_OK, "e2e: 对端静默时返回错误（而非挂死）");
        CHECK(io.recvTimeouts > 0, "e2e: 走的是超时路径");
    }

    printf("[e2e] 断链…\n");
    r5 = dlms_disconnect(c);
    printf("[e2e] disconnect ret=%d(%s)\n", r5, dlms_error_string(r5));
    // 强断言：断链必须正常返回 0（原来同样只排除 INVALID_PARAMETER，过弱）。
    CHECK(r5 == DLMS_ERROR_CODE_OK,
          "e2e: dlms_disconnect 正常断开（RLRQ/RLRE 或 DISC）");

    // trace 回调被真正调用了（同时覆盖 dlms_set_trace）
    CHECK(io.traceTx > 0 && io.traceRx > 0, "e2e: trace 回调有 TX/RX（dlms_set_trace 生效）");
    printf("[e2e] 收发统计: send=%d recv=%d txBytes=%d timeouts=%d trace=%d/%d rx=%d/%d\n",
           io.sends, io.recvs, io.txBytes, io.recvTimeouts, io.traceTx, io.traceRx,
           dlms_rxSize(c), dlms_rxPosition(c));

    dlms_free(c);
    sock_close(fd);
    sock_fini();
    if (failures == 0) { printf("[e2e] ALL PASS\n"); return 0; }
    printf("[e2e] FAILED=%d\n", failures);
    return 1;
}
