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
    var objectClass: Int = 1         // 接口类(IC)，可为任意值（10/16 进制）；兜底默认 1
    var attribute: Int = 2
    var scaling: String = ""         // 量纲/倍率（可选，仅展示）
    /// Set / Action 用的**固定请求数据**（HEX，如 `11 01`）。
    /// 选中该 OBIS 时会自动填进主界面的「请求数据」，省去每次手输；
    /// 留空表示无参数（写空值 / 执行无参方法）。
    var data: String = ""
    var enabled: Bool = true

    var displayName: String { name.isEmpty ? code : "\(name) · \(code)" }

    /// 显式声明（而非依赖合成），键名一目了然，也不受"合成 CodingKeys 可见性"规则影响。
    /// 注意：在类型体内声明嵌套类型**不会**抑制 memberwise init（抑制它的是自定义 init）。
    enum CodingKeys: String, CodingKey {
        case id, code, name, unit, objectClass, attribute, scaling, data, enabled
    }
}

extension ObisItem {
    /// ⚠️ **手写解码**：缺键必须回退默认值，不能用合成实现。
    /// 否则旧的 `obis.json`（没有 `data` 字段）会**整份解码失败** →
    /// `Store.load` 返回 nil → 用户的清单被静默重置成预置列表。
    /// 与 `ConnectionConfig.init(from:)` 同一套容错口径。
    ///
    /// 放在 extension 里而不是 struct 体内：这样编译器仍会合成
    /// memberwise init（`ObisItem(code:name:…)`），不必为每处调用补参数。
    init(from decoder: Decoder) throws {
        self.init(code: "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.dlmsValue(.id, id)
        code = c.dlmsValue(.code, code)
        name = c.dlmsValue(.name, name)
        unit = c.dlmsValue(.unit, unit)
        objectClass = c.dlmsValue(.objectClass, objectClass)
        attribute = c.dlmsValue(.attribute, attribute)
        scaling = c.dlmsValue(.scaling, scaling)
        data = c.dlmsValue(.data, data)
        enabled = c.dlmsValue(.enabled, enabled)
    }
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
    /// HDLC 通信地址(服务器)的**原始输入**（编码前形态，逻辑+物理合成）。
    ///
    /// 为什么保留原串而不是 `UInt32`：地址宽度**由输入的字节数决定**，
    /// 而 `UInt32` 区分不了 `01`（1 字节）与 `0001`（2 字节）—— 两者数值相同但线上编码不同。
    /// 拆分规则见 `serverLogical` / `serverPhysical`：
    ///   1 字节 → 整串是逻辑地址（无物理地址）
    ///   2 字节 → 逻辑 1 字节 + 物理 1 字节
    ///   4 字节 → 逻辑 2 字节 + 物理 2 字节
    /// 其它字节数（如 3 字节）非法，UI 标红。
    var serverAddressHex: String = "00013FFF"
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

    /// ⚠️ 手写 CodingKeys（不用合成）：`serverAddress` / `serverAddressWidth` 是**已淘汰的旧字段**，
    /// 新版本不再写出，但要能**读进来做迁移** —— 否则旧 `config.json` 里的通信地址会丢回默认值。
    enum CodingKeys: String, CodingKey {
        case id, ip, port, recvTimeoutMs, framing, clientPreset, clientAddress
        case serverAddressHex
        case serverAddress            // 旧：UInt32 合并形态 → 迁移为 serverAddressHex
        case serverAddressWidth       // 旧：手动宽度 → 已由输入字节数取代（读入后忽略）
        case wrapperSource, wrapperTarget, recentEndpoints
        case auth, security, passwordHex, guakHex, guekHex, clientSystemTitleHex, parseEnabled
    }

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
        // 通信地址：新字段 `serverAddressHex` 才是真源 —— 它保留了**输入的字节数**，
        // 而 UInt32 区分不了 `01`(1 字节) 与 `0001`(2 字节)。
        // 旧存档只有 `serverAddress`(UInt32) → 按 8 位 hex 迁移过来（默认 00013FFF）。
        if let stored = try? c.decodeIfPresent(String.self, forKey: .serverAddressHex), let stored {
            serverAddressHex = stored          // 键存在（含用户清空的空串）→ 原样保留
        } else {
            serverAddressHex = String(format: "%08X", c.dlmsValue(.serverAddress, UInt32(0x00013FFF)))
        }
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

    // MARK: - 通信地址：输入（逻辑+物理，宽度由字节数定）→ 编码后（喂 cl_init）

    /// 归一化后的输入（去空白/`:`/`-`、转大写）。非法字符**原样保留**，便于 UI 判定。
    var serverAddressNormalized: String { HexUtil.normalize(serverAddressHex) }

    /// 输入字节数 —— **地址宽度就是它**。
    /// 仅在「偶数位 + 全合法 hex」时有效；否则返回 0（UI 据此标红）。
    var serverAddressBytes: Int {
        let n = serverAddressNormalized
        guard !n.isEmpty, n.count % 2 == 0, n.allSatisfy({ $0.isHexDigit }) else { return 0 }
        return n.count / 2
    }

    /// 输入是否可用：**只认 1 / 2 / 4 字节**（3 字节等一律非法）。
    var serverAddressIsValid: Bool { [1, 2, 4].contains(serverAddressBytes) }

    /// 输入拆成的字节数组（按 2 位 hex 一组；非法时为空）。
    var serverAddressInputBytes: [UInt8] {
        let n = serverAddressNormalized
        guard !n.isEmpty, n.count % 2 == 0 else { return [] }
        var out: [UInt8] = []
        var i = n.startIndex
        while i < n.endIndex {
            let j = n.index(i, offsetBy: 2)
            guard let b = UInt8(n[i..<j], radix: 16) else { return [] }
            out.append(b)
            i = j
        }
        return out
    }

    /// 逻辑地址：1 字节时是整串；2 字节时取第 1 字节；4 字节时取前 2 字节。
    var serverLogical: UInt32 {
        let b = serverAddressInputBytes
        switch b.count {
        case 1:  return UInt32(b[0])
        case 2:  return UInt32(b[0])
        case 4:  return UInt32(b[0]) << 8 | UInt32(b[1])
        default: return 0
        }
    }

    /// 物理地址：**1 字节时没有物理地址**（为 0）；2 字节取第 2 字节；4 字节取后 2 字节。
    var serverPhysical: UInt32 {
        let b = serverAddressInputBytes
        switch b.count {
        case 1:  return 0
        case 2:  return UInt32(b[1])
        case 4:  return UInt32(b[2]) << 8 | UInt32(b[3])
        default: return 0
        }
    }

    /// 编码前形态的合并值（高 16 位逻辑 + 低 16 位物理）。仅供展示/兼容旧代码 ——
    /// 真源是 `serverAddressHex`（它能表达输入字节数）。
    var serverAddress: UInt32 { (serverLogical << 16) | serverPhysical }

    /// 喂给 `cl_init` 的 serverAddress。
    ///
    /// Gurux 在 `dlms.c:2420` 按 **7bit/字节 + bit0 扩展位**打包，而且**按数值大小自动选宽度**：
    ///   `< 0x80` → 1 字节；`< 0x4000` → 2 字节；否则 → 4 字节。
    /// 它期望的输入是"已按目标宽度拼好的值"：
    ///   - 4 字节：共 28 位 = 逻辑 14 位 + 物理 14 位 → `logical << 14 | physical`
    ///   - 2 字节：共 14 位 = 逻辑  7 位 + 物理  7 位 → `logical <<  7 | physical`
    ///   - 1 字节：只有逻辑 7 位
    /// 所以**不能**把输入的 `00013FFF` 直接喂进去 —— Gurux 会按 `v>>14` 解出逻辑=0x4F，编码出错误的地址域。
    var serverAddressEncoded: UInt32 {
        switch serverAddressBytes {
        case 1:  return serverLogical & 0x7F
        case 2:  return ((serverLogical & 0x7F) << 7) | (serverPhysical & 0x7F)
        case 4:  return ((serverLogical & 0x3FFF) << 14) | (serverPhysical & 0x3FFF)
        default: return 0
        }
    }

    /// Gurux **实际**会用的地址宽度（按数值量级推断，可能与输入宽度不同）。
    /// 例：输入 4 字节但逻辑地址为 0 → 值 < 0x4000 → 实际只有 2 字节。UI 用它提示。
    var serverAddressEffectiveWidth: Int {
        let v = serverAddressEncoded
        if v < 0x80 { return 1 }
        if v < 0x4000 { return 2 }
        return 4
    }

    /// 输入宽度与 Gurux 实际宽度是否一致（不一致时 UI 标黄提示）。
    var serverAddressWidthMatched: Bool {
        serverAddressIsValid && serverAddressEffectiveWidth == serverAddressBytes
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
            : "HDLC 客户端\(clientAddress.hex2) 通信\(serverAddressNormalized.isEmpty ? "--" : serverAddressNormalized)"
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
    /// 比较/去重用的归一形态：去空白 + 转大写 + 把 `- : * ,` 统一成 `.`。
    ///
    /// 用于「最近 OBIS」与清单条目的匹配 —— 两边写法可能不同
    /// （`1-0:1.8.0*255` vs `1.0.1.8.0.255`），不归一就查不到，
    /// 导致选中后类/属性/请求数据都带不过来，下拉里还会出现同一个对象的两个变体。
    static func comparisonKey(_ code: String) -> String {
        code.filter { !$0.isWhitespace }.uppercased()
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "*", with: ".")
            .replacingOccurrences(of: ",", with: ".")
    }

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