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