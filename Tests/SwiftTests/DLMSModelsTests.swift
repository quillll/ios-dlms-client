//
//  DLMSModelsTests.swift
//  纯逻辑单测：hex 解析、OBIS 解析(多分隔符/16进制段)、枚举映射、地址格式化、
//  密钥默认值与配置解码容错。
//

import Foundation
import XCTest
@testable import DLMSApp

final class HexUtilTests: XCTestCase {
    func testSpacedHex() {
        XCTAssertEqual(HexUtil.bytes(fromHex: "11 01"), [0x11, 0x01])
        XCTAssertEqual(HexUtil.bytes(fromHex: "12 01 00"), [0x12, 0x01, 0x00])
    }
    func testNoSpaceHex() {
        XCTAssertEqual(HexUtil.bytes(fromHex: "AB0F"), [0xAB, 0x0F])
        XCTAssertEqual(HexUtil.bytes(fromHex: "ab0f"), [0xAB, 0x0F])
    }
    func testInvalidHex() {
        XCTAssertNil(HexUtil.bytes(fromHex: ""))
        XCTAssertNil(HexUtil.bytes(fromHex: "1"))     // 奇数长度
        XCTAssertNil(HexUtil.bytes(fromHex: "GG"))    // 非法字符
    }
    func testFormat() {
        XCTAssertEqual(HexUtil.format([0x11, 0x01]), "11 01")
        XCTAssertEqual(HexUtil.format([0xAB]), "AB")
    }
}

final class ObisUtilTests: XCTestCase {
    func testDot() { XCTAssertEqual(ObisUtil.parse("1.0.1.8.0.255"), [1,0,1,8,0,255]) }
    func testDashColonStar() {
        XCTAssertEqual(ObisUtil.parse("1-0:1.8.0*255"), [1,0,1,8,0,255])
    }
    func testComma() { XCTAssertEqual(ObisUtil.parse("1,0,1,8,0,255"), [1,0,1,8,0,255]) }
    func testHexSegment() { XCTAssertEqual(ObisUtil.parse("1.0.0x10.0.0.255"), [1,0,16,0,0,255]) }
    func testPartialPadded() { XCTAssertEqual(ObisUtil.parse("0.0.40.0.0"), [0,0,40,0,0,0]) }
    func testInvalid() {
        XCTAssertNil(ObisUtil.parse("1.0.1.8.0.300"))  // 超出 0-255
        XCTAssertNil(ObisUtil.parse(""))
        XCTAssertNil(ObisUtil.parse("1.2.3.4.5.6.7"))  // 超过6段
    }

    /// 归一形态：让「最近 OBIS」与清单条目能匹配上（两边写法可能不同）。
    func testComparisonKeyUnifiesSeparators() {
        XCTAssertEqual(ObisUtil.comparisonKey("1-0:1.8.0*255"), "1.0.1.8.0.255")
        XCTAssertEqual(ObisUtil.comparisonKey("1,0,1,8,0,255"), "1.0.1.8.0.255")
        XCTAssertEqual(ObisUtil.comparisonKey(" 1.0.1.8.0.255 "), "1.0.1.8.0.255")
        XCTAssertEqual(ObisUtil.comparisonKey("1.0.1.8.0.255"), "1.0.1.8.0.255")
        // 同一对象的不同写法 → 同一个 key（这是"回查清单能命中"的前提）
        XCTAssertEqual(ObisUtil.comparisonKey("1-0:1.8.0*255"),
                       ObisUtil.comparisonKey("1.0.1.8.0.255"))
        // 不同对象不能撞
        XCTAssertNotEqual(ObisUtil.comparisonKey("1.0.1.8.0.255"),
                          ObisUtil.comparisonKey("1.0.2.8.0.255"))
    }
}

/// 通信地址：输入（**字节数即宽度** + 逻辑/物理拆分）→ 编码后（喂 cl_init 的值）。
/// 关键用例是默认的 `00013FFF`：4 字节 → 逻辑 `0x0001` + 物理 `0x3FFF`，
/// 编码后应得 `0x7FFF`，线上地址域为 `00 02 FE FF`（末字节 bit0=1 表示地址域结束）。
final class ServerAddressEncodingTests: XCTestCase {
    private func cfg(_ hex: String) -> ConnectionConfig {
        var c = ConnectionConfig()
        c.serverAddressHex = hex
        return c
    }

    func testWidthComesFromInputLength() {
        XCTAssertEqual(cfg("10").serverAddressBytes, 1)
        XCTAssertEqual(cfg("0010").serverAddressBytes, 2)
        XCTAssertEqual(cfg("00013FFF").serverAddressBytes, 4)
        XCTAssertTrue(cfg("10").serverAddressIsValid)
        XCTAssertTrue(cfg("0010").serverAddressIsValid)
        XCTAssertTrue(cfg("00013FFF").serverAddressIsValid)
        // 3 字节：能识别出长度，但**非法**（UI 标红）
        XCTAssertEqual(cfg("0001FF").serverAddressBytes, 3)
        XCTAssertFalse(cfg("0001FF").serverAddressIsValid)
        // 奇数位 / 非法字符 / 空 → 连长度都算不上
        XCTAssertEqual(cfg("00013FF").serverAddressBytes, 0)
        XCTAssertEqual(cfg("ZZZZ").serverAddressBytes, 0)
        XCTAssertEqual(cfg("").serverAddressBytes, 0)
        XCTAssertFalse(cfg("").serverAddressIsValid)
    }

    func testOneByteIsLogicalOnly() {
        let c = cfg("10")
        XCTAssertEqual(c.serverLogical, 0x10)
        XCTAssertEqual(c.serverPhysical, 0)              // 1 字节 = 只有逻辑地址
        XCTAssertEqual(c.serverAddressEncoded, 0x10)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 1)
        XCTAssertEqual(c.serverAddressWireHex, "21")
        XCTAssertTrue(c.serverAddressWidthMatched)
    }

    func testTwoByteSplitsOneAndOne() {
        let c = cfg("0105")
        XCTAssertEqual(c.serverLogical, 0x01)
        XCTAssertEqual(c.serverPhysical, 0x05)
        XCTAssertEqual(c.serverAddressEncoded, (0x01 << 7) | 0x05)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 2)
    }

    func testFourByteSplitsTwoAndTwo() {
        let c = cfg("00013FFF")
        XCTAssertEqual(c.serverLogical, 0x0001)
        XCTAssertEqual(c.serverPhysical, 0x3FFF)
        XCTAssertEqual(c.serverAddressEncoded, 0x7FFF)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 4)
        XCTAssertEqual(c.serverAddressWireHex, "0002FEFF")
        XCTAssertTrue(c.serverAddressWidthMatched)
    }

    func testWidthMismatchWhenLogicalIsZero() {
        // 输入 4 字节但逻辑地址为 0 → 值 < 0x4000，Gurux 只会用 2 字节。
        // UI 靠 widthMatched == false 提示这种情况。
        let c = cfg("00003FFF")
        XCTAssertEqual(c.serverAddressEncoded, 0x3FFF)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 2)
        XCTAssertFalse(c.serverAddressWidthMatched)
    }

    /// 2 字节输入但逻辑地址为 0 → encoded = 0x10 < 0x80 → Gurux 实际只发 **1 字节**。
    /// 这是"输入宽度 ≠ 实际宽度"的另一个实例（用户想按 2 字节发，实际发 1 字节）。
    func testTwoByteInputWithZeroLogicalDegradesToOneByte() {
        let c = cfg("0010")
        XCTAssertEqual(c.serverLogical, 0x00)
        XCTAssertEqual(c.serverPhysical, 0x10)
        XCTAssertEqual(c.serverAddressEncoded, 0x10)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 1)
        XCTAssertFalse(c.serverAddressWidthMatched)
    }

    func testSeparatorsAndCaseAreTolerated() {
        let c = cfg("00:01-3f FF")
        XCTAssertEqual(c.serverAddressBytes, 4)
        XCTAssertEqual(c.serverAddressEncoded, 0x7FFF)
    }

    func testTargetUsesEncodedValueForHDLC() {
        var c = cfg("00013FFF")
        c.framing = .hdlc
        XCTAssertEqual(c.target, 0x7FFF)
        c.framing = .wrapper
        c.wrapperTarget = 0x01
        XCTAssertEqual(c.target, 0x01)
    }

    /// 旧存档只有 `serverAddress`(UInt32) → 必须迁移成 8 位 hex，不能丢回默认值。
    /// （0x00013FFF = 81919）
    func testLegacyConfigMigratesAddress() throws {
        let json = #"{"serverAddress":81919}"#
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.serverAddressHex, "00013FFF")
        XCTAssertEqual(c.serverAddressEncoded, 0x7FFF)
    }

    func testDecodedEmptyAddressIsPreserved() throws {
        // 键存在但为空串 = 用户清空了输入框 → 不能被当成"旧存档"再迁移回来
        let json = #"{"serverAddressHex":"","serverAddress":81919}"#
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.serverAddressHex, "")
        XCTAssertEqual(c.serverAddressBytes, 0)
    }
}

/// 最近连接（IP:端口）列表：记录、去重、限量、回填解析。
final class RecentEndpointTests: XCTestCase {
    func testRememberPutsNewestFirst() {
        var c = ConnectionConfig()
        c.ip = "192.168.1.10"; c.port = 4059
        c.rememberEndpoint()
        c.ip = "10.0.0.5"; c.port = 4059
        c.rememberEndpoint()
        XCTAssertEqual(c.recentEndpoints.first, "10.0.0.5:4059")
        XCTAssertEqual(c.recentEndpoints.count, 2)
    }

    func testRememberDeduplicates() {
        var c = ConnectionConfig()
        c.ip = "192.168.1.10"; c.port = 4059
        c.rememberEndpoint()
        c.ip = "10.0.0.5"; c.port = 4059
        c.rememberEndpoint()
        c.ip = "192.168.1.10"; c.port = 4059
        c.rememberEndpoint()                       // 回到第一条 → 应移到最前且不重复
        XCTAssertEqual(c.recentEndpoints, ["192.168.1.10:4059", "10.0.0.5:4059"])
    }

    func testRememberCapsAtEight() {
        var c = ConnectionConfig()
        for i in 1...10 {
            c.ip = "10.0.0.\(i)"; c.port = 4059
            c.rememberEndpoint()
        }
        XCTAssertEqual(c.recentEndpoints.count, 8)
        XCTAssertEqual(c.recentEndpoints.first, "10.0.0.10:4059")
    }

    func testRememberIgnoresEmptyHost() {
        var c = ConnectionConfig()
        c.ip = "   "; c.port = 4059
        c.rememberEndpoint()
        XCTAssertTrue(c.recentEndpoints.isEmpty)
    }

    func testSplitEndpoint() {
        let ok = ConnectionConfig.splitEndpoint("192.168.1.10:4059")
        XCTAssertEqual(ok?.0, "192.168.1.10")
        XCTAssertEqual(ok?.1, 4059)
        XCTAssertNil(ConnectionConfig.splitEndpoint("192.168.1.10"))     // 没端口
        XCTAssertNil(ConnectionConfig.splitEndpoint("host:abc"))          // 端口非数字
        XCTAssertNil(ConnectionConfig.splitEndpoint(":4059"))             // 空主机
    }
}

final class EnumTests: XCTestCase {
    func testAuthRawValues() {
        XCTAssertEqual(Auth.none.rawValue, 0)
        XCTAssertEqual(Auth.low.rawValue, 1)
        XCTAssertEqual(Auth.highGMAC.rawValue, 5)
        XCTAssertTrue(Auth.highGMAC.isSupportedP1)
        XCTAssertFalse(Auth.highECDSA.isSupportedP1)
    }
    func testFraming() { XCTAssertEqual(Framing.hdlc.rawValue, 0); XCTAssertEqual(Framing.wrapper.rawValue, 1) }
    func testSecurity() {
        XCTAssertEqual(SecurityMode.none.rawValue, 0)
        XCTAssertEqual(SecurityMode.authentication.rawValue, 0x10)
        XCTAssertEqual(SecurityMode.encryption.rawValue, 0x20)
        XCTAssertEqual(SecurityMode.authEncryption.rawValue, 0x30)
        // 仅加密 / 认证加密 依赖 GUEK；仅认证不依赖
        XCTAssertTrue(SecurityMode.encryption.needsGUEK)
        XCTAssertTrue(SecurityMode.authEncryption.needsGUEK)
        XCTAssertFalse(SecurityMode.authentication.needsGUEK)
        XCTAssertFalse(SecurityMode.none.needsGUEK)
    }
    func testClientPreset() {
        XCTAssertEqual(ClientPreset.management.value, 1)
        XCTAssertEqual(ClientPreset.publicClient.value, 0x10)
        XCTAssertEqual(ClientPreset.preLink.value, 0x66)
        XCTAssertNil(ClientPreset.custom.value)
    }
    func testConfigDefault() {
        let c = ConnectionConfig()
        XCTAssertEqual(c.ip, "10.10.10.1")
        XCTAssertEqual(c.auth, .highGMAC)     // 认证默认 HLS-GMAC
        XCTAssertEqual(c.security, .none)      // 信息加密默认 NONE
        XCTAssertEqual(c.port, 4059)
        // GUAK / GUEK 默认 16 字节全 0；客户端 SystemTitle 默认 ABC01234
        XCTAssertEqual(c.guakHex, ConnectionConfig.zeroAES128Key)
        XCTAssertEqual(c.guekHex, ConnectionConfig.zeroAES128Key)
        XCTAssertEqual(c.clientSystemTitleHex, "4142433031323334")
        XCTAssertTrue(HexUtil.isValid(c.guakEffective, byteCount: 16))
        XCTAssertTrue(HexUtil.isValid(c.clientSystemTitleEffective, byteCount: 8))
    }
}

final class KeyHexTests: XCTestCase {
    func testNormalizeStripsSeparators() {
        XCTAssertEqual(HexUtil.normalize("41 42 43 30 31 32 33 34"), "4142433031323334")
        XCTAssertEqual(HexUtil.normalize("41:42-43"), "414243")
        XCTAssertEqual(HexUtil.normalize(" ab\tcd \n"), "ABCD")
    }
    func testNormalizeKeepsIllegalChars() {
        // 非法字符不静默丢弃，交给上层校验时能看出来
        XCTAssertEqual(HexUtil.normalize("GG"), "GG")
    }
    func testIsValid() {
        XCTAssertTrue(HexUtil.isValid("41 42 43 30 31 32 33 34", byteCount: 8))
        XCTAssertFalse(HexUtil.isValid("4142433031323334", byteCount: 16))  // 字节数不足
        XCTAssertFalse(HexUtil.isValid("", byteCount: 16))
        XCTAssertFalse(HexUtil.isValid("GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG", byteCount: 16))
    }
    func testEmptyKeyFallsBackToDefault() {
        var c = ConnectionConfig()
        c.guakHex = ""
        c.guekHex = "   "
        c.clientSystemTitleHex = ""
        XCTAssertEqual(c.guakEffective, ConnectionConfig.zeroAES128Key)
        XCTAssertEqual(c.guekEffective, ConnectionConfig.zeroAES128Key)
        XCTAssertEqual(c.clientSystemTitleEffective, ConnectionConfig.defaultClientSystemTitle)
    }
    func testSeparatedKeyIsNormalizedOnUse() {
        var c = ConnectionConfig()
        c.guakHex = "01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef"
        XCTAssertEqual(c.guakEffective, "0123456789ABCDEF0123456789ABCDEF")
    }
}

/// OBIS 条目：新增字段（data）**不能让旧 `obis.json` 整份失效**。
/// `Store.load` 一旦解码失败就返回 nil → 用户的整份清单被静默重置成预置列表，
/// 所以这里钉住"缺键回退默认值"的容错口径。
final class ObisItemCodableTests: XCTestCase {
    func testDefaults() {
        let it = ObisItem(code: "1.0.1.8.0.255")
        XCTAssertEqual(it.objectClass, 1)        // 兜底默认 1 类
        XCTAssertEqual(it.attribute, 2)
        XCTAssertEqual(it.data, "")              // 无请求数据
        XCTAssertTrue(it.enabled)
        XCTAssertEqual(it.displayName, "1.0.1.8.0.255")   // name 为空时退回 code
    }

    func testDecodeLegacyJSONWithoutDataKey() throws {
        let json = #"[{"code":"1.0.1.8.0.255","name":"电量","unit":"kWh","objectClass":3,"attribute":2}]"#
        let items = try JSONDecoder().decode([ObisItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "电量")
        XCTAssertEqual(items[0].objectClass, 3)  // 存档里的值优先于兜底默认
        XCTAssertEqual(items[0].data, "")        // 缺键 → 默认空
        XCTAssertTrue(items[0].enabled)
    }

    func testDecodeWithRequestData() throws {
        let json = #"[{"code":"0.0.40.0.0.255","data":"09 11 10"}]"#
        let items = try JSONDecoder().decode([ObisItem].self, from: Data(json.utf8))
        XCTAssertEqual(items[0].data, "09 11 10")
        XCTAssertEqual(items[0].objectClass, 1)  // 缺键 → 1
    }

    func testDecodeBrokenTypeFallsBackInsteadOfThrowing() throws {
        let json = #"[{"code":123,"objectClass":"3"}]"#
        let items = try JSONDecoder().decode([ObisItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].code, "")        // 类型不符 → 默认
        XCTAssertEqual(items[0].objectClass, 1)
    }

    func testRoundTrip() throws {
        let it = ObisItem(code: "1.0.1.8.0.255", name: "电量", unit: "kWh",
                          objectClass: 3, attribute: 2, scaling: "",
                          data: "11 01", enabled: true)
        let back = try JSONDecoder().decode(ObisItem.self, from: try JSONEncoder().encode(it))
        XCTAssertEqual(back, it)
    }

    /// 兜底默认值从 3 改成 1 之后，**预置清单里没显式写 IC 的条目会被带偏** ——
    /// 电量/功率/电压/电流全是 Register(3)。这条断言把预置钉住。
    func testPresetsCarryTheirOwnObjectClass() {
        let registers = ObisItem.presets.filter { $0.code.hasPrefix("1.0.") }
        XCTAssertFalse(registers.isEmpty)
        XCTAssertTrue(registers.allSatisfy { $0.objectClass == 3 },
                      "预置的电量/功率/电压/电流必须是 Register(3)，不能吃模型兜底值")
        XCTAssertEqual(ObisItem.presets.first { $0.code == "0.0.1.0.0.255" }?.objectClass, 1)
    }
}

/// 预读缓冲的取用逻辑。
///
/// 这是防「写爆 C 侧 2048 字节栈缓冲」的关键一步：调用方给的缓冲固定大小，
/// 而 Swift 侧 `copyBytes` 不做边界检查。旧实现整份排空 `pending` →
/// 超时挂起的多个 completion 累积起来的数据被一次性写入 → 栈破坏。
final class TransportPendingTests: XCTestCase {
    func testTakeTruncatesToMax() {
        var buf = Data([1, 2, 3, 4, 5, 6])
        let out = GXDLMSTransport.takePending(&buf, max: 4)
        XCTAssertEqual([UInt8](out), [1, 2, 3, 4])   // 只取 max 个
        XCTAssertEqual([UInt8](buf), [5, 6])         // 余量**留在**缓冲里
    }

    func testTakeReturnsAllWhenSmallerThanMax() {
        var buf = Data([1, 2, 3])
        let out = GXDLMSTransport.takePending(&buf, max: 2048)
        XCTAssertEqual([UInt8](out), [1, 2, 3])
        XCTAssertTrue(buf.isEmpty)
    }

    func testTakeEmptyBuffer() {
        var buf = Data()
        XCTAssertTrue(GXDLMSTransport.takePending(&buf, max: 10).isEmpty)
        XCTAssertTrue(buf.isEmpty)
    }

    /// 连续取用必须能拼回原数据（不丢不重）——
    /// 这正是「分片 + 超时叠加」场景的核心契约。
    func testSuccessiveTakesReassembleOriginal() {
        let original = Data((0..<10).map { UInt8($0) })
        var buf = original
        let first = GXDLMSTransport.takePending(&buf, max: 4)
        let second = GXDLMSTransport.takePending(&buf, max: 4)
        let third = GXDLMSTransport.takePending(&buf, max: 4)
        XCTAssertEqual(first + second + third, original)
        XCTAssertTrue(buf.isEmpty)
    }

    /// 单次取用**永远不超过 max** —— 旧的"整份排空"就是在这条上失守的。
    func testNeverExceedsMax() {
        var buf = Data(repeating: 0xAB, count: 8192)   // 4 个 2048 的 completion 堆在一起
        let out = GXDLMSTransport.takePending(&buf, max: 2048)
        XCTAssertLessThanOrEqual(out.count, 2048)
        XCTAssertEqual(buf.count, 8192 - 2048)
    }
}

final class ConfigCodableTests: XCTestCase {
    /// 旧存档（缺新字段、且含已删除的 akekHex）不应让整份配置被重置回默认。
    func testDecodeLegacyJSONKeepsExistingValues() throws {
        let json = """
        {"ip":"192.168.1.9","port":4060,"auth":5,"security":0,
         "passwordHex":"12345678","akekHex":"AABB"}
        """
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.ip, "192.168.1.9")      // 旧值保留
        XCTAssertEqual(c.port, 4060)
        XCTAssertEqual(c.auth, .highGMAC)
        XCTAssertEqual(c.passwordHex, "12345678")
        XCTAssertEqual(c.guakHex, ConnectionConfig.zeroAES128Key)   // 缺键 → 默认
        XCTAssertEqual(c.guekHex, ConnectionConfig.zeroAES128Key)
        XCTAssertEqual(c.clientSystemTitleHex, ConnectionConfig.defaultClientSystemTitle)
    }

    func testRoundTrip() throws {
        var c = ConnectionConfig()
        c.ip = "10.0.0.7"
        c.guekHex = "0123456789ABCDEF0123456789ABCDEF"
        let back = try JSONDecoder().decode(ConnectionConfig.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testDecodeBrokenTypeFallsBackInsteadOfThrowing() throws {
        let json = #"{"ip":123,"port":"4059"}"#     // 类型全错
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.ip, "10.10.10.1")
        XCTAssertEqual(c.port, 4059)
    }
}