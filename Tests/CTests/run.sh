#!/usr/bin/env bash
# 编译 vendored 客户端子集 + 桥接 + C 单测并运行（GCC/Clang 跨平台）。
# 用法: bash Tests/CTests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Sources/DLMSCore"
OUT="$ROOT/build/ctest"
CC="${CC:-gcc}"
mkdir -p "$OUT"

OBJS=()
for f in "$SRC"/C/src/*.c; do
  b="$(basename "$f" .c)"
  case "$b" in server|serverevents|notify) continue ;; esac
  "$CC" -O0 -g -DDLMS_IGNORE_SERVER -DDLMS_IGNORE_SERIALIZER -I"$SRC/C/include" -I"$SRC/Headers" -c "$f" -o "$OUT/$b.o"
  OBJS+=("$OUT/$b.o")
done

"$CC" -O0 -g -DDLMS_IGNORE_SERVER -I"$SRC/C/include" -I"$SRC/Headers" -c "$SRC/Bridge/DLMSBridge.c" -o "$OUT/bridge.o"
OBJS+=("$OUT/bridge.o")

"$CC" -O0 -g -DDLMS_IGNORE_SERVER -I"$SRC/C/include" -I"$SRC/Headers" -c "$ROOT/Tests/CTests/test_dlms.c" -o "$OUT/test.o"
OBJS+=("$OUT/test.o")

"$CC" "${OBJS[@]}" -o "$OUT/test_dlms" -lm
"$OUT/test_dlms"
echo "C tests passed."