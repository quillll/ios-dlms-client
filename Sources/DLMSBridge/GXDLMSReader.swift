//
//  GXDLMSReader.swift
//  高层抄读器：把 ConnectionConfig + 操作包装成 C 桥接调用，并转发日志/trace。
//  建链状态机在 C(DLMSBridge.c)；本层负责生命周期与线程串行化(R8)。
//

import Foundation
import DLMSCore

// MARK: - 操作类型
enum DLMSOp { case read, write, method }

// MARK: - C 回调（C 函数指针）
//
// 注意：这里不能写成 `@convention(c) private func ...`。
// 较新的 Swift 工具链上 `@convention(c)` 只能作用于「类型」，作用于函数声明会报：
//   error: attribute can only be applied to types, not declarations
// 正确写法：把「非捕获闭包」赋给带 C 函数指针类型别名的常量。

private let dlmsTransportSend: dlmsSendFn = { user, data, len in
    guard let user, let data, len > 0 else { return -1 }
    let t: GXDLMSTransport = Unmanaged.fromOpaque(user).takeUnretainedValue()
    return t.send(Data(bytes: data, count: Int(len))) ? 0 : -1
}

private let dlmsTransportRecv: dlmsRecvFn = { user, buf, cap, got in
    guard let user, let buf, let got, cap > 0 else { return -1 }
    let t: GXDLMSTransport = Unmanaged.fromOpaque(user).takeUnretainedValue()
    guard let d = t.receive(max: Int(cap)) else { return -1 }
    d.copyBytes(to: buf, count: d.count)
    got.pointee = Int32(d.count)
    return 0
}

private let dlmsTransportTrace: dlmsTraceFn = { user, dir, frame, len in
    guard let user, let frame, len > 0 else { return }
    let r: GXDLMSReader = Unmanaged.fromOpaque(user).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: frame, count: Int(len)))
    r.emitTrace(direction: dir == 2 ? .rx : .tx, frame: bytes)
}

// MARK: - 抄读器

final class GXDLMSReader {
    private enum Kind { case connectOnly, read, write, method }

    private let config: ConnectionConfig
    private let transport: GXDLMSTransport
    private let workQueue = DispatchQueue(label: "dlms.reader.work")
    private var onTrace: ((LogEntry) -> Void)?
    private var onState: ((String) -> Void)?

    init(config: ConnectionConfig, onTrace: @escaping (LogEntry) -> Void, onState: @escaping (String) -> Void) {
        self.config = config
        self.transport = GXDLMSTransport()
        self.onTrace = onTrace
        self.onState = onState
    }

    func emitTrace(direction: LogEntry.Kind, frame: [UInt8]) {
        let type = Self.classify(frame)
        onTrace?(LogEntry(
            time: Date(), kind: direction,
            text: direction == .tx ? "TX" : "RX",
            hex: type.isEmpty ? HexUtil.format(frame) : "\(type)  \(HexUtil.format(frame))"))
    }

    /// 从帧头区(地址/控制之后)找 COSEM/HDLC 顶层 tag，识别报文类型。
    /// 纯启发式：只看前 16 字节里首个命中的 tag，供日志快速标注，非精确解码。
    static func classify(_ f: [UInt8]) -> String {
        let tags: [(UInt8, String)] = [
            (0x60, "AARQ"), (0x61, "AARE"), (0x62, "RLRQ"), (0x63, "RLRE"),
            (0xC0, "Get-Request"), (0xC4, "Get-Response"),
            (0xC1, "Set-Request"), (0xC5, "Set-Response"),
            (0x35, "SNRM"), (0x73, "UA"), (0x40, "DISC"),
        ]
        for b in f.prefix(16) {
            if let m = tags.first(where: { $0.0 == b }) { return m.1 }
        }
        return ""
    }
    private func state(_ s: String) { onState?(s) }

    /// Swift String → C `const char*`（空串→NULL；仅在调用期间有效）。
    private func cStr(_ s: String) -> UnsafePointer<CChar>? {
        s.isEmpty ? nil : (s as NSString).utf8String
    }

    /// 在后台串行执行一次完整会话（建链→操作→断链）。
    func run(op: DLMSOp?, obis: [UInt8]?, classVal: Int, attr: Int, hex: String?, completion: @escaping () -> Void = {}) {
        workQueue.async {
            do {
                let value = try self.syncRun(op: op, obis: obis, classVal: classVal, attr: attr, hex: hex)
                self.state("完成 · \(value)")
            } catch {
                self.state("失败 · \(error.localizedDescription)")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func syncRun(op: DLMSOp?, obis: [UInt8]?, classVal: Int, attr: Int, hex: String?) throws -> String {
        transport.recvTimeoutMs = max(config.recvTimeoutMs, 500)

        try transport.connect(host: config.ip, port: UInt16(config.port))
        defer { transport.cancel() }
        state("已连接")

        // 构造上下文（cl_init）。
        var ctx: OpaquePointer?
        let pwd = config.auth == .low ? config.passwordHex : ""
        pwd.withCString { pc in
            ctx = dlms_new(1, UInt16(clamp32(config.source)), config.target, Int32(config.auth.rawValue), pc, Int32(config.framing.rawValue))
        }
        guard let ctx else { throw DLMSReaderError.allocFailed }
        defer {
            dlms_disconnect(ctx)
            dlms_free(ctx)
        }

        // 安全 / 客户端 SystemTitle / IC（可扩展 P2）。
        // 密钥映射：GUEK(全局单播加密密钥) → blockCipherKey(第 3 参)；
        //           GUAK(全局单播认证密钥) → authenticationKey(第 4 参)。
        // 留空时 ConnectionConfig 已回退到默认值（全 0 AES-128 / 默认 SystemTitle），
        // 所以这两个 effective 串不会为空，不需要再加空值判断。
        dlms_set_security(ctx, Int32(config.security.rawValue),
                          cStr(config.guekEffective), cStr(config.guakEffective), nil)
        dlms_set_clientSystemTitle(ctx, cStr(config.clientSystemTitleEffective))

        let tUser = Unmanaged<GXDLMSTransport>.passUnretained(transport).toOpaque()
        dlms_set_io(ctx, tUser, dlmsTransportSend, dlmsTransportRecv)
        let rUser = Unmanaged<GXDLMSReader>.passUnretained(self).toOpaque()
        dlms_set_trace(ctx, rUser, dlmsTransportTrace)

        state("建链中")
        try check(dlms_initialize(ctx), step: "建链")

        // 连接测试模式：只建链即返回。
        guard let op else { return "连接成功" }

        guard let obis else { throw DLMSReaderError.noObis }
        let codeHex = HexUtil.format(obis, upper: false)

        var out = [CChar](repeating: 0, count: 512)
        var outLen: Int32 = 512
        var ret: Int32
        let value: String
        switch op {
        case .read:
            state("读 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_read(ctx, p.baseAddress, UInt16(classVal), UInt8(attr), &out, &outLen)
            }
        case .write:
            state("写 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_write(ctx, p.baseAddress, UInt16(classVal), UInt8(attr), cStr(hex ?? ""), &out, &outLen)
            }
        case .method:
            state("执行 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_method(ctx, p.baseAddress, UInt16(classVal), UInt8(attr), cStr(hex ?? ""), &out, &outLen)
            }
        }

        guard ret == 0 else { throw DLMSReaderError.dlmsFailed(errorText(ret)) }
        value = outLen > 0 ? String(cString: out) : ""
        state("断链")
        return value
    }

    private func check(_ code: Int32, step: String) throws {
        guard code == 0 else { throw DLMSReaderError.step("\(step)失败: \(errorText(code))") }
    }
    private func errorText(_ code: Int32) -> String {
        if let p = dlms_error_string(code) { return String(cString: p) }
        return "\(code)"
    }
    private func clamp32(_ v: UInt32) -> UInt32 { min(v, UInt32(UInt16.max)) }
}

enum DLMSReaderError: LocalizedError {
    case allocFailed
    case noObis
    case step(String)
    case dlmsFailed(String)
    var errorDescription: String? {
        switch self {
        case .allocFailed: return "初始化 DLMS 客户端失败"
        case .noObis: return "OBIS 无效（需 6 段）"
        case .step(let m), .dlmsFailed(let m): return m
        }
    }
}