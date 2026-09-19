# DLMS 抄表调试台 (iOS)

近 GXDLMSDirector / 桌面 Test-Client 形态的 DLMS/COSEM 电表调试台。自用现场抄表、单表快速抄、仅 TCP。

- 读 / 写 / 执行 一键自动建链→操作→断链
- 封装：HDLC / Wrapper（地址按封装联动）
- 认证三档（NONE / LLS / HLS-GMAC），信息加密四档（NONE / 仅认证 / 仅加密 / 认证加密）
- 客户端地址预设（管理/公共/只读/预链接/自定义）+ 通信地址
- 全局 OBIS 清单（下拉/手输/导入 JSON·CSV/预置），OBIS 分隔符兼容 `* , . - :`
- 数据解析窗 + 报文日志（TX/RX/信息多色）
- 协议层 vendor 本地 Gurux.DLMS.c（GPLv2，自用无分发风险）

## 结构

```
dlms-ios-app/
├── project.yml                  # XcodeGen（Windows 纯手写，CI 生成 .xcodeproj）
├── .github/workflows/build-ipa.yml
├── Sources/
│   ├── DLMSCore/                # 协议核心 framework
│   │   ├── C/src · C/include    # vendored Gurux.DLMS.c（客户端子集，DLMS_IGNORE_SERVER）
│   │   ├── Headers/DLMSCore.h   # Swift 唯一桥接面
│   │   └── Bridge/DLMSBridge.c  # 帧解析/建链/写/方法/安全/SystemTitle/IC/trace
│   ├── DLMSBridge/              # GXDLMSTransport(TCP·超时可配) + GXDLMSReader(状态机)
│   └── DLMSModels/              # ConnectionConfig / ObisLibrary / 枚举映射 / 工具
├── DLMSApp/                     # SwiftUI：MainView(调试台) / ParamsView(参数) / ObisLibraryView
└── Tests/
    ├── CTests/                  # C 层单测（本地/CI 可跑）
    └── SwiftTests/              # Swift 纯逻辑单测（CI 跑）
```

## 构建与测试

```bash
# 1) C 层单测（无需 Xcode，跨平台）：42 个 vendored 源 + 桥接 + 断言
bash Tests/CTests/run.sh

# 2) 生成工程 + 编译（macOS）
xcodegen generate
xcodebuild -project DLMSApp.xcodeproj -scheme DLMSApp -destination 'generic/platform=iOS Simulator' build

# 3) 托管单测
xcodebuild -project DLMSApp.xcodeproj -scheme DLMSApp -destination 'platform=iOS Simulator,name=iPhone 14' test
```

GitHub Actions：`c-test`（Linux，快）与 `ios`（macOS，编译+单测+出包）双闸门。

## 关键实现口径（对应 docs/DLMS调试台-方案.md）

- 认证方式与信息加密是两个独立下拉：认证默认 HLS-GMAC，信息加密默认 NONE。
- HLS 时客户端 SystemTitle 必须在 AARQ 前设置（→ parma 页常显）。
- 服务器 SystemTitle 由 AARE 自动回填（显示，非输入）。
- 写走 `cl_writeLN(..., byteArray=1)` + `bb_addHexString` 直传；执行走 hex→variant（P1 整型+无参）。
- 接收缓冲跨 recv 累积追加(`bb_insert`)并按需扩容，杜绝大 PDU 分段丢帧。
- 断链先 RLRQ(release2) 再 DISC；Wrapper 不发 SNRM。
- invocation counter 直接赋值 `settings->cipher.invocationCounter`（P2 加同步）。

## 许可

`Sources/DLMSCore/C/` 为 Gurux.DLMS.c，遵循 GNU GPL v2（自用无分发影响；商用分发前请评估）。其余桥接/模型/UI 为本项目自有代码。