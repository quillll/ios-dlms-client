//
//  DLMSModelsTests.swift
//  纯逻辑单测：hex 解析、OBIS 解析(多分隔符/16进制段)、枚举映射、地址格式化。
//

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
        XCTAssertTrue(SecurityMode.authEncryption.needsAKEK)
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
    }
}