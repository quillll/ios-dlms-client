#!/usr/bin/env bash
# 编译 vendored 客户端子集 + 桥接 + C 测试并运行（GCC/Clang 跨平台）。
#
# 四层闸门（越靠前越便宜，本机与 Linux CI 都能跑）：
#   ① 单元测试  test_dlms     —— hex/variant/渲染/variant 构造 + 协议回放（桩 IO）
#   ② 端到端    local_e2e     —— DLMSBridge + **真实 TCP socket** ↔ tools/mock_meter
#   ③ 分片退化观察             —— 小分片下只验"不崩不挂 + 重试有界"
#   ④ 有界性     --scenario silent —— 对端不应答时必须**有界退出**，不挂死
#
# 用法: bash Tests/CTests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Sources/DLMSCore"
OUT="$ROOT/build/ctest"
CC="${CC:-gcc}"
PORT="${MOCK_PORT:-40599}"
mkdir -p "$OUT"

# 平台差异：Windows(MinGW) 需要 winsock；Linux/macOS 不需要
LIBS=(-lm)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS+=(-lws2_32) ;;
esac

CFLAGS=(-O0 -g -Wall -DDLMS_IGNORE_SERVER -DDLMS_IGNORE_SERIALIZER
        -I"$SRC/C/include" -I"$SRC/Headers" -I"$ROOT/tools")

# ── 编库（只编一次，两个测试共用）───────────────────────────────────────────
# gxserializer 由 -DDLMS_IGNORE_SERIALIZER 变成空壳，直接排除以免白编近万行。
OBJS=()
for f in "$SRC"/C/src/*.c; do
  b="$(basename "$f" .c)"
  case "$b" in server|serverevents|notify|gxserializer) continue ;; esac
  "$CC" "${CFLAGS[@]}" -c "$f" -o "$OUT/$b.o"
  OBJS+=("$OUT/$b.o")
done
"$CC" "${CFLAGS[@]}" -c "$SRC/Bridge/DLMSBridge.c" -o "$OUT/bridge.o"
OBJS+=("$OUT/bridge.o")

# ── ① 单元测试 ────────────────────────────────────────────────────────────
echo "=== ① 单元测试 test_dlms ==="
"$CC" "${CFLAGS[@]}" -c "$ROOT/Tests/CTests/test_dlms.c" -o "$OUT/test_dlms.o"
"$CC" "${OBJS[@]}" "$OUT/test_dlms.o" -o "$OUT/test_dlms" "${LIBS[@]}"
"$OUT/test_dlms"

# ── ② / ③ / ④ 端到端（真 socket ↔ 模拟表）──────────────────────────────────
echo
echo "=== ② 端到端 local_e2e（真 socket ↔ mock_meter）==="
"$CC" "${CFLAGS[@]}" -c "$ROOT/Tests/CTests/local_e2e.c" -o "$OUT/local_e2e.o"
"$CC" "${OBJS[@]}" "$OUT/local_e2e.o" -o "$OUT/local_e2e" "${LIBS[@]}"
"$CC" "${CFLAGS[@]}" "$ROOT/tools/mock_meter.c" -o "$OUT/mock_meter" "${LIBS[@]}"

MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 连接就绪不靠 sleep：local_e2e 内部有重试（慢机器/CI 上不会假失败）。
# E2E_ARGS：给 local_e2e 的额外参数（按场景设 recv 超时）。
run_e2e() {          # $1=scenario；其余参数转给 mock_meter
  local scenario="$1"; shift
  "$OUT/mock_meter" --port "$PORT" --quiet "$@" &
  MOCK_PID=$!
  # shellcheck disable=SC2086
  "$OUT/local_e2e" --port "$PORT" --scenario "$scenario" ${E2E_ARGS:-}
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

# ② 正常会话（整帧）：强断言 —— AARQ/AARE 必须过、dlms_read 必须端到端成功。
#    recv 超时用默认 3000ms（与 App 侧一致），因为这条路径不应出现超时。
E2E_ARGS=""
run_e2e basic

# ③ 分片场景（真实链路常态：响应被 TCP 拆成多段到达）—— 现在是**强断言**。
#    这一档曾长期"退化"（重试暴涨、卡在 AARQ/AARE），根因是桥接层 bufAppend 误用
#    bb_insert 做追加（它不更新 size、且把 index 当源偏移）—— 已修复，故按正常要求断言。
#    recv 超时压到 300ms 以保持闸门快：正常路径不该出现超时（实测每档都是 0 次超时）。
echo
echo "=== ③ 分片场景（8 / 16+5ms / 32 / 64 字节）==="
E2E_ARGS="--recv-timeout-ms 300"
run_e2e basic --frag 8
run_e2e basic --frag 16 --delay-ms 5
run_e2e basic --frag 32
run_e2e basic --frag 64

# ④ 对端应答 2 帧后静默：必须快速有界失败，不能挂死（同样用短超时保持闸门快）
echo
echo "=== ④ 有界性 local_e2e --scenario silent ==="
E2E_ARGS="--recv-timeout-ms 300"
run_e2e silent --silent-after 2

echo
echo "C tests passed."
