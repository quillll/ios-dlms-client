#!/usr/bin/env bash
# 本地 Swift 类型检查闸门（Windows）。
#
# 背景：本机原先没有 Swift 工具链，Swift 代码只能靠云端 CI 验证 —— 结果
# 连续三次 CI 红在同一条 `ConnectionConfig` 解码逻辑上（含 `try?` flatten、
# `Decoder.container` 漏 try）。装好 Swift for Windows 后，**纯 Foundation
# 且不依赖 Apple 独占框架**的那几个文件可以在本机直接校验。
#
# 覆盖范围（受 Windows SDK 限制）：
#   可查  : DLMSModels.swift / ObisImporter.swift / AppInfo.swift
#   不可查: Store.swift（import Combine，Apple 独占）
#           GXDLMSReader.swift（import DLMSCore，需 vendored C 框架）
#           GXDLMSTransport.swift（import Network，Apple 独占）
#           DLMSApp/*.swift（import SwiftUI，Apple 独占）
#           Tests/SwiftTests/*（依赖 XCTest + 上面这些）
#         这些仍必须靠 CI。
#
# 用法: bash tools/swift_typecheck.sh
# 退出码: 0 = 通过；1 = 有 error 或工具链不可用。

set -u

# ── 定位 swiftc ────────────────────────────────────────────────────────────
SWIFT_ROOT="${SWIFT_ROOT:-$LOCALAPPDATA/Programs/Swift}"
SWIFTC="$SWIFT_ROOT/Toolchains/6.4.0+Asserts/usr/bin/swiftc.exe"

if [ ! -x "$SWIFTC" ]; then
  # 退而求其次：PATH 里找
  SWIFTC="$(command -v swiftc.exe 2>/dev/null || true)"
fi
if [ -z "$SWIFTC" ] || [ ! -x "$SWIFTC" ]; then
  echo "[skip] 未找到 swiftc.exe（Swift for Windows 未安装？）—— 跳过本地类型检查"
  exit 0
fi

SDK="$SWIFT_ROOT/Platforms/6.4.0/Windows.platform/Developer/SDKs/Windows.sdk"
if [ ! -d "$SDK" ]; then
  echo "[skip] 未找到 Windows.sdk: $SDK —— 跳过本地类型检查"
  exit 0
fi

# ── 关键：必须去掉小写代理变量 ─────────────────────────────────────────────
# Swift 5.9+ 在构造 ProcessInfo.environment 时，**大小写敏感地**把环境变量塞进
# 一个字典；若同时存在 HTTP_PROXY 与 http_proxy（Windows 上很常见），
# swiftc 会直接 `Fatal error: Duplicate values for key` 崩掉，连 --version 都跑不了。
# 这里用 env -u 剔掉小写那一组（大写仍保留，代理照常工作）。
RUN=(env -u http_proxy -u https_proxy "$SWIFTC")

# 注意：-sdk 要传 Windows 风格路径，swiftc 对 Git Bash 的 /c/... 不认。
SDK_WIN="$(cygpath -w "$SDK" 2>/dev/null || echo "$SDK")"

FILES=(
  "Sources/DLMSModels/DLMSModels.swift"
  "DLMSApp/Support/ObisImporter.swift"
  "DLMSApp/Support/AppInfo.swift"
)

echo "── Swift 本地类型检查 ────────────────────────────────"
"${RUN[@]}" --version 2>&1 | head -1
echo "文件：${#FILES[@]} 个（联合编译，保证跨文件依赖可解析）"
echo

out="$("${RUN[@]}" -typecheck -sdk "$SDK_WIN" "${FILES[@]}" 2>&1)"
code=$?
printf '%s\n' "$out"

if [ $code -ne 0 ]; then
  echo
  echo "[FAIL] 类型检查未通过（exit=$code）"
  exit 1
fi

# 把 warning 也算作需要处理的东西：本仓刚因为漏 try / try? flatten 连续红过三次，
# 这类问题编译器多以 warning 形式提示（如「?? 右侧永不执行」）—— 不放过。
if printf '%s' "$out" | grep -q "warning:"; then
  echo
  echo "[WARN] 类型检查通过但有 warning，请逐条确认（本仓对此零容忍）"
  exit 1
fi

echo
echo "[OK] 类型检查通过，且无 warning"
exit 0
