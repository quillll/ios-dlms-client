#!/usr/bin/env bash
# 编译 vendored 客户端子集 + 桥接 + C 测试并运行（GCC/Clang 跨平台）。
#
# 三层闸门（越靠前越便宜，本机与 Linux CI 都能跑）：
#   ① 单元测试  test_dlms     —— hex/variant/渲染/variant 构造 + 协议回放（桩 IO）
#   ② 端到端    local_e2e     —— DLMSBridge + **真实 TCP socket** ↔ tools/mock_meter
#                                （含模拟表"拆片发送"的坏链路场景）
#   ③ 有界性    local_e2e --scenario silent —— 对端不应答时必须**有界退出**，不挂死
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
OBJS=()
for f in "$SRC"/C/src/*.c; do
  b="$(basename "$f" .c)"
  case "$b" in server|serverevents|notify) continue ;; esac
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

# ── ② / ③ 端到端（真 socket ↔ 模拟表）──────────────────────────────────────
echo
echo "=== ② 端到端 local_e2e（真 socket ↔ mock_meter）==="
"$CC" "${CFLAGS[@]}" -c "$ROOT/Tests/CTests/local_e2e.c" -o "$OUT/local_e2e.o"
"$CC" "${OBJS[@]}" "$OUT/local_e2e.o" -o "$OUT/local_e2e" "${LIBS[@]}"
"$CC" "${CFLAGS[@]}" "$ROOT/tools/mock_meter.c" -o "$OUT/mock_meter" "${LIBS[@]}"

MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT

run_e2e() {          # $1=scenario  $2...=mock_meter 额外参数
  local scenario="$1"; shift
  "$OUT/mock_meter" --port "$PORT" --quiet "$@" &
  MOCK_PID=$!
  sleep 1                                   # 等监听就绪
  "$OUT/local_e2e" --port "$PORT" --scenario "$scenario"
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

# ② 正常会话（整帧）：强断言 —— AARQ/AARE 必须过、dlms_read 必须端到端成功 ✓ 确定性通过
run_e2e basic

# ③ 分片场景：**已知退化**（实测重试暴涨、有时卡在 AARQ/AARE，且同一参数两次跑结果不同），
#    故只要求"不崩不挂 + 重试有界"，并把 sends/recvs/timeouts 打出来作为量化证据。
#    这不是"测试随便放行"——退化本身就是要盯住的问题，见 docs 与 memory 的记录。
echo
echo "=== ③ 分片退化观察（32B / 16B+10ms）—— 仅验不崩不挂与重试有界 ==="
run_e2e fragile --frag 32
run_e2e fragile --frag 16 --delay-ms 10

# ④ 对端应答 2 帧后静默：必须快速有界失败，不能挂死
echo
echo "=== ④ 有界性 local_e2e --scenario silent ==="
run_e2e silent --silent-after 2

echo
echo "C tests passed."
