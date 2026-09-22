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
    /// 报文类型（启发式识别：AARQ / Get-Request / SNRM …）；仅 TX/RX 行有值。
    /// 单独成字段而不是拼进 hex 串，这样 UI 能给它一个固定宽度列，
    /// 报文 HEX 才能上下对齐（拼字符串时类型名长度不同会错位）。
    var label: String = ""
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
    var serverAddress: UInt32 = 0x00013FFF      // HDLC 通信地址(服务器)：编码前形态 = 逻辑(高16位)+物理(低16位)
    /// 通信地址宽度（字节）：4 / 2 / 1，默认 4。
    /// ⚠️ Gurux 是**按数值大小自动选宽度**的（见 `serverAddressEncoded`），
    /// 所以这个选择只在"数值量级刚好落在该宽度区间"时才真正生效 —— UI 里会显示实际生效的宽度。
    var serverAddressWidth: Int = 4
    var wrapperSource: UInt32 = 0x01
    var wrapperTarget: UInt32 = 0x01

    /// 最近成功连接过的 `IP:端口`（新的在前，最多 8 条）。参数页下拉选择用。
    /// 只在**连接成功**时记录（见 MainView 的 onFinish），避免把打错的地址记进去。
    var recentEndpoints: [String] = []

    /// 记住当前 `IP:端口`：去重、新的在前、最多 8 条。
    /// 用 Swift 的 split 按最后一个冒号切分（IPv6 字面量也能容忍）。
    mutating func rememberEndpoint() {
        let host = ip.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let key = "\(host):\(port)"
        var list = recentEndpoints.filter { $0 != key }
        list.insert(key, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentEndpoints = list
    }

    /// 把一条 `IP:端口` 拆回 ip / port（供下拉选择时回填）。
    static func splitEndpoint(_ s: String) -> (String, Int)? {
        guard let idx = s.lastIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<idx])
        let portStr = String(s[s.index(after: idx)...])
        guard !host.isEmpty, let p = Int(portStr) else { return nil }
        return (host, p)
    }
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
        serverAddressWidth = c.dlmsValue(.serverAddressWidth, serverAddressWidth)
        wrapperSource = c.dlmsValue(.wrapperSource, wrapperSource)
        wrapperTarget = c.dlmsValue(.wrapperTarget, wrapperTarget)
        recentEndpoints = c.dlmsValue(.recentEndpoints, recentEndpoints)
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
    /// 运行时 target/server 地址（封装相关）。HDLC 必须用**编码后**的值，见下。
    var target: UInt32 { framing == .wrapper ? wrapperTarget : serverAddressEncoded }

    // MARK: - 通信地址：编码前（逻辑+物理）→ 编码后（喂 cl_init）

    /// 编码**前**的形态：高 16 位 = 逻辑地址，低 16 位 = 物理地址。
    /// 默认 `00013FFF` = 逻辑 `0x0001` + 物理 `0x3FFF`。
    var serverLogical: UInt32 { (serverAddress >> 16) & 0xFFFF }
    var serverPhysical: UInt32 { serverAddress & 0xFFFF }

    /// 喂给 `cl_init` 的 serverAddress。
    ///
    /// Gurux 在 `dlms.c:2420` 按 **7bit/字节 + bit0 扩展位**打包，而且**按数值大小自动选宽度**：
    ///   `< 0x80` → 1 字节；`< 0x4000` → 2 字节；否则 → 4 字节。
    /// 它期望的输入是"已按目标宽度拼好的值"：
    ///   - 4 字节：共 28 位 = 逻辑 14 位 + 物理 14 位 → `logical << 14 | physical`
    ///   - 2 字节：共 14 位 = 逻辑  7 位 + 物理  7 位 → `logical <<  7 | physical`
    ///   - 1 字节：只有物理 7 位
    /// 所以**不能**把 UI 的 `00013FFF` 直接喂进去 —— Gurux 会按 `v>>14` 解出逻辑=0x4F，编码出错误的地址域。
    var serverAddressEncoded: UInt32 {
        switch serverAddressWidth {
        case 1:  return serverPhysical & 0x7F
        case 2:  return ((serverLogical & 0x7F) << 7) | (serverPhysical & 0x7F)
        default: return ((serverLogical & 0x3FFF) << 14) | (serverPhysical & 0x3FFF)
        }
    }

    /// Gurux **实际**会用的地址宽度（按数值量级推断，可能与 `serverAddressWidth` 不同）。
    /// 例：选了 4 字节但逻辑地址为 0 → 值 < 0x4000 → 实际只有 2 字节。UI 用它提示。
    var serverAddressEffectiveWidth: Int {
        let v = serverAddressEncoded
        if v < 0x80 { return 1 }
        if v < 0x4000 { return 2 }
        return 4
    }

    /// 编码后地址域的实际字节（大端；**末字节 bit0=1 表示地址域结束**）。
    /// 仅供 UI 预览 —— 可以直接拿去和表的期望值对照，省得靠猜。
    var serverAddressWireHex: String {
        let v = serverAddressEncoded
        switch serverAddressEffectiveWidth {
        case 1:
            return String(format: "%02X", (v << 1) | 1)
        case 2:
            return String(format: "%04X", (v & 0x3F80) << 2 | (v & 0x7F) << 1 | 1)
        default:
            return String(format: "%08X",
                          (v & 0xFE00000) << 4 | (v & 0x1FC000) << 3 | (v & 0x3F80) << 2 | (v & 0x7F) << 1 | 1)
        }
    }
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