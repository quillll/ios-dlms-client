//
//  DLMSModels.swift
//  数据模型 + 纯逻辑工具（可单测，不依赖 UIKit/C）。
//  遵循方案（v1.3）：单表调试台 · 全局 OBIS · 认证/加密/密钥独立；
//  密钥口径 GUAK(认证)/GUEK(加密)，默认全 0，客户端 SystemTitle 有默认值。
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
    /// 是否依赖加密密钥（GUEK）：仅加密 / 认证加密均需 GUEK，仅认证走 GUAK。
    var needsGUEK: Bool { self == .encryption || self == .authEncryption }
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
    var objectClass: Int = 3         // 接口类(IC)，可为任意值（10/16 进制）
    var attribute: Int = 2
    var scaling: String = ""         // 量纲/倍率（可选，仅展示）
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
//
// ⚠️ 改这个结构体的字段（改名/新增）时，必须同步下面的 `init(from:)`：
//    那里按「缺键 → 用默认值」逐项兜底，否则旧的 config.json 会整份解码失败，
//    用户的 IP/端口/密钥会被静默重置回默认。
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
    var passwordHex: String = "00000000"        // LLS 密码（按 ASCII 直传给 cl_init）
    var guakHex: String = ConnectionConfig.zeroAES128Key
    // ↑ GUAK 全局单播认证密钥(16B) → settings->cipher.authenticationKey
    var guekHex: String = ConnectionConfig.zeroAES128Key
    // ↑ GUEK 全局单播加密密钥(16B) → settings->cipher.blockCipherKey
    var clientSystemTitleHex: String = ConnectionConfig.defaultClientSystemTitle
    // ↑ 客户端自己的 SystemTitle(8B) → settings->cipher.systemTitle（HLS 须在 AARQ 前设置，R13）
    var parseEnabled: Bool = true

    /// 全 0 AES-128 密钥（32 位 hex）—— GUAK / GUEK 默认值。
    static let zeroAES128Key = "00000000000000000000000000000000"
    /// 客户端 SystemTitle 默认值（8 字节 = ASCII "ABC01234"）。
    static let defaultClientSystemTitle = "4142433031323334"

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.dlmsValue(.id, id)
        ip = c.dlmsValue(.ip, ip)
        port = c.dlmsValue(.port, port)
        recvTimeoutMs = c.dlmsValue(.recvTimeoutMs, recvTimeoutMs)
        framing = c.dlmsValue(.framing, framing)
        clientPreset = c.dlmsValue(.clientPreset, clientPreset)
        clientAddress = c.dlmsValue(.clientAddress, clientAddress)
        serverAddress = c.dlmsValue(.serverAddress, serverAddress)
        wrapperSource = c.dlmsValue(.wrapperSource, wrapperSource)
        wrapperTarget = c.dlmsValue(.wrapperTarget, wrapperTarget)
        auth = c.dlmsValue(.auth, auth)
        security = c.dlmsValue(.security, security)
        passwordHex = c.dlmsValue(.passwordHex, passwordHex)
        guakHex = c.dlmsValue(.guakHex, guakHex)
        guekHex = c.dlmsValue(.guekHex, guekHex)
        clientSystemTitleHex = c.dlmsValue(.clientSystemTitleHex, clientSystemTitleHex)
        parseEnabled = c.dlmsValue(.parseEnabled, parseEnabled)
    }

    // MARK: 密钥取值（留空 → 默认值；顺带做 hex 归一化）
    //
    // 归一化只去掉空白与 `:` `-` 分隔符，非法字符原样保留，
    // 这样「AB CD EF…」能直接用，而「GG」不会被悄悄当成空值吞掉。

    /// GUAK 认证密钥 hex；留空按全 0 AES-128。
    var guakEffective: String { Self.effectiveKey(guakHex, fallback: Self.zeroAES128Key) }
    /// GUEK 加密密钥 hex；留空按全 0 AES-128。
    var guekEffective: String { Self.effectiveKey(guekHex, fallback: Self.zeroAES128Key) }
    /// 客户端 SystemTitle hex；留空按默认 8 字节。
    var clientSystemTitleEffective: String { Self.effectiveKey(clientSystemTitleHex, fallback: Self.defaultClientSystemTitle) }

    private static func effectiveKey(_ raw: String, fallback: String) -> String {
        let n = HexUtil.normalize(raw)
        return n.isEmpty ? fallback : n
    }

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

// 缺键 / 类型不符 → 回退默认值（Decodable 合成实现不会这么做，故手写）。
private extension KeyedDecodingContainer {
    func dlmsValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        guard let v = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return v ?? fallback
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
    /// 归一化 hex 文本：去掉空白与 `:` `-` 分隔符并转大写（交给 C 之前统一处理）。
    /// 非法字符原样保留（不做静默丢弃），便于上层做长度/合法性校验。
    static func normalize(_ string: String) -> String {
        String(string.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }).uppercased()
    }
    /// 归一化后是否为「指定字节数 + 全合法 hex」。
    static func isValid(_ string: String, byteCount: Int) -> Bool {
        let n = normalize(string)
        return n.count == byteCount * 2 && n.allSatisfy { $0.isHexDigit }
    }
}

/// 数值输入：自动识别 16/10 进制（含 a-f 或 0x 前缀 → 16 进制）。用于类/属性等。
enum NumberInput {
    static func parse(_ s: String) -> Int? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let low = raw.lowercased()
        let isHex = low.contains { "abcdef".contains($0) } || low.hasPrefix("0x")
        let base = isHex ? 16 : 10
        return Int(isHex && low.hasPrefix("0x") ? String(low.dropFirst(2)) : low, radix: base)
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