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

int main(void)
{
    printf("[hex]\n"); test_hex();
    printf("[ctx]\n"); test_ctx();
    printf("[variant]\n"); test_variant();
    if (failures == 0)
    {
        printf("ALL PASS\n");
        return 0;
    }
    printf("TOTAL FAILED=%d\n", failures);
    return 1;
}