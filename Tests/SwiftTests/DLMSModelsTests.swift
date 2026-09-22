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
}

/// 通信地址：编码前（逻辑 16 位 + 物理 16 位）→ 编码后（喂 cl_init 的值）。
/// 关键用例是默认的 `00013FFF`：逻辑 `0x0001` + 物理 `0x3FFF`，
/// 4 字节下应得到 `0x7FFF`，线上地址域为 `00 02 FE FF`（末字节 bit0=1 表示地址域结束）。
final class ServerAddressEncodingTests: XCTestCase {
    private func cfg(_ addr: UInt32, _ width: Int) -> ConnectionConfig {
        var c = ConnectionConfig()
        c.serverAddress = addr
        c.serverAddressWidth = width
        return c
    }

    func testDefaultSplitsLogicalAndPhysical() {
        let c = cfg(0x00013FFF, 4)
        XCTAssertEqual(c.serverLogical, 0x0001)
        XCTAssertEqual(c.serverPhysical, 0x3FFF)
    }

    func testFourByteEncodedValue() {
        let c = cfg(0x00013FFF, 4)
        XCTAssertEqual(c.serverAddressEncoded, 0x7FFF)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 4)
    }

    func testFourByteWireBytes() {
        XCTAssertEqual(cfg(0x00013FFF, 4).serverAddressWireHex, "0002FEFF")
    }

    func testTwoByte() {
        let c = cfg((0x01 << 16) | 0x05, 2)
        XCTAssertEqual(c.serverAddressEncoded, (0x01 << 7) | 0x05)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 2)
    }

    func testOneByte() {
        let c = cfg(0x10, 1)
        XCTAssertEqual(c.serverAddressEncoded, 0x10)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 1)
        XCTAssertEqual(c.serverAddressWireHex, "21")
    }

    func testWidthMismatchWhenLogicalIsZero() {
        // 选了 4 字节但逻辑地址为 0 → 值 < 0x4000，Gurux 只会用 2 字节。
        // UI 靠 effectiveWidth != serverAddressWidth 提示这种情况。
        let c = cfg(0x00003FFF, 4)
        XCTAssertEqual(c.serverAddressEncoded, 0x3FFF)
        XCTAssertEqual(c.serverAddressEffectiveWidth, 2)
    }

    func testTargetUsesEncodedValueForHDLC() {
        var c = cfg(0x00013FFF, 4)
        c.framing = .hdlc
        XCTAssertEqual(c.target, 0x7FFF)
        c.framing = .wrapper
        c.wrapperTarget = 0x01
        XCTAssertEqual(c.target, 0x01)
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