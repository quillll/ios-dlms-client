//
//  DLMSModels.swift
//  数据模型 + 纯逻辑工具（可单测，不依赖 UIKit/C）。
//  遵循方案 v1.2：单表调试台 · 全局 OBIS · 认证/加密/密钥独立。
//

import Foundation

// MARK: - 认证方式（对应 DLMS_AUTHENTICATION，rawValue 即 C 值 / mechanism_id）
enum Auth: Int, Codable, CaseIterable, Identifiable {
    case none = 0
    case low = 1
    case high = 2
    case highMD5 = 3
    case highSHA1 = 4
    case highGMAC = 5
    case highSHA256 = 6
    case highECDSA = 7

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "NONE"
        case .low: return "LLS"
        case .high: return "HLS"
        case .highMD5: return "HLS-MD5"
        case .highSHA1: return "HLS-SHA1"
        case .highGMAC: return "HLS-GMAC"
        case .highSHA256: return "HLS-SHA256"
        case .highECDSA: return "HLS-ECDSA"
        }
    }
    /// P1 支持路径；其余显示"暂不支持"。
    var isSupportedP1: Bool { self == .none || self == .low || self == .highGMAC }
}

// MARK: - 封装协议（DLMS_INTERFACE_TYPE）
enum Framing: Int, Codable, CaseIterable, Identifiable {
    case hdlc = 0
    case wrapper = 1
    var id: Int { rawValue }
    var title: String { self == .hdlc ? "HDLC" : "Wrapper" }
}

// MARK: - 信息加密（DLMS_SECURITY，rawValue 即 cipher.security 值）
enum SecurityMode: Int, Codable, CaseIterable, Identifiable {
    case none = 0
    case authentication = 0x10
    case encryption = 0x20
    case authEncryption = 0x30

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "NONE"
        case .authentication: return "仅认证"
        case .encryption: return "仅加密"
        case .authEncryption: return "认证加密"
        }
    }
    var needsAKEK: Bool { self == .authEncryption }
}

// MARK: - HDLC 客户端地址预设（IEC 62056 常用子集）
enum ClientPreset: Int, Codable, CaseIterable, Identifiable {
    case management = 0x01
    case publicClient = 0x10
    case readOnly = 0x02
    case preLink = 0x66
    case custom = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .management: return "管理 0x01"
        case .publicClient: return "公共 0x10"
        case .readOnly: return "只读 0x02"
        case .preLink: return "预链接 0x66"
        case .custom: return "自定义"
        }
    }
    var value: UInt32? { rawValue >= 0 ? UInt32(rawValue) : nil }
}

// MARK: - 对象类（DLMS_OBJECT_TYPE）
enum ObisClass: Int, Codable, CaseIterable, Identifiable {
    case data = 1
    case register = 3
    case extendedRegister = 4
    case profileGeneric = 7
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .data: return "Data(1)"
        case .register: return "Register(3)"
        case .extendedRegister: return "ExtRegister(4)"
        case .profileGeneric: return "ProfileGeneric(7)"
        }
    }
}

// MARK: - OBIS 条目（全局清单）
struct ObisItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var code: String                 // 任意分隔，如 1.0.1.8.0.255
    var name: String = ""
    var unit: String = ""
    var objectClass: ObisClass = .register
    var attribute: Int = 2
    var enabled: Bool = true

    var displayName: String { name.isEmpty ? code : "\(name) · \(code)" }
}

// MARK: - 报文日志条目
struct LogEntry: Identifiable, Equatable {
    enum Level: String, CaseIterable { case debug, info, warn, error }
    enum Kind: Int { case info = 0, tx = 1, rx = 2 }
    var id = UUID()
    var time: Date
    var level: Level = .debug
    var kind: Kind = .info
    var text: String
    var hex: String?                 // TX/RX 原始 HEX（可选，供展开）
}

// MARK: - 连接配置（单表 · 记住上次）
struct ConnectionConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var ip: String = "10.10.10.1"
    var port: Int = 4059
    var recvTimeoutMs: Int = 3000
    var framing: Framing = .hdlc
    var clientPreset: ClientPreset = .custom
    var clientAddress: UInt32 = 0x01            // HDLC 客户端 / Wrapper 源
    var serverAddress: UInt32 = 0x00013FFF      // HDLC 通信地址(服务器)
    var wrapperSource: UInt32 = 0x01
    var wrapperTarget: UInt32 = 0x01
    var auth: Auth = .highGMAC                  // 认证默认 HLS-GMAC
    var security: SecurityMode = .none          // 信息加密默认 NONE
    var passwordHex: String = "00000000"        // LLS 密码
    var akekHex: String = ""                    // aKEK/EM 主密钥
    var clientSystemTitleHex: String = ""       // 客户端自己的 SystemTitle(8B)，HLS 必填
    var parseEnabled: Bool = true

    /// 运行时 source/client 地址（封装相关）。
    var source: UInt32 { framing == .wrapper ? wrapperSource : clientAddress }
    /// 运行时 target/server 地址（封装相关）。
    var target: UInt32 { framing == .wrapper ? wrapperTarget : serverAddress }
    var addressSummary: String {
        framing == .wrapper
            ? "Wrapper 源\(wrapperSource.hex2) 目标\(wrapperTarget.hex2)"
            : "HDLC 客户端\(clientAddress.hex2) 通信\(serverAddress.hex4)"
    }
}

// MARK: - 纯逻辑工具（可单测）

enum HexUtil {
    /// "11 01" / "11 01 00" / "AB0F" → [0x11, 0x01, ...]；非法返回 nil。
    static func bytes(fromHex string: String) -> [UInt8]? {
        let s = string.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty, s.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var it = s.makeIterator()
        while let hi = it.next(), let lo = it.next(),
              let h = hexVal(hi), let l = hexVal(lo) {
            out.append(UInt8(h << 4 | l))
        }
        return (out.count * 2 == s.count) ? out : nil
    }
    private static func hexVal(_ c: Character) -> Int? {
        switch c {
        case "0"..."9": return Int(c.asciiValue! - 48)
        case "a"..."f": return Int(c.asciiValue! - 87)
        default: return nil
        }
    }
    /// 把 hex 字节数组格式化为日志空格分隔串。
    static func format(_ bytes: [UInt8], upper: Bool = true) -> String {
        bytes.map { String(format: upper ? "%02X" : "%02x", $0) }.joined(separator: " ")
    }
}

enum ObisUtil {
    /// 分隔符兼容 `* , . - :`；段内含 a-f 或 0x 前缀 → 16 进制，否则十进制。
    /// 返回 6 字节；非法段或份数不足报 nil。
    static func parse(_ code: String) -> [UInt8]? {
        let parts = code.split { $0 == "," || $0 == "." || $0 == "-" || $0 == ":" || $0 == "*" || $0.isWhitespace }
        guard !parts.isEmpty, parts.count <= 6 else { return nil }
        var out = [UInt8](repeating: 0, count: 6)
        for (i, p) in parts.prefix(6).enumerated() {
            guard let v = parseSegment(String(p)) else { return nil }
            out[i] = v
        }
        return out
    }
    private static func parseSegment(_ s: String) -> UInt8? {
        let t = s.lowercased()
        let isHex = t.contains { "abcdef".contains($0) } || t.hasPrefix("0x")
        let base = isHex ? 16 : 10
        var body = t
        if base == 16 && t.hasPrefix("0x") { body = String(t.dropFirst(2)) }
        guard let n = UInt8(body, radix: base) else { return nil }
        return n
    }
}

// MARK: - 格式化小工具
extension UInt32 {
    /// 2 位 hex（源/目标地址无 ANSI 前缀处理器）。
    var hex2: String { String(format: "%02X", self) }
    var hex4: String { String(format: "%04X", self) }
}

extension Date {
    var dlmsLogText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: self)
    }
}