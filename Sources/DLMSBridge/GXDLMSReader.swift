//
//  GXDLMSReader.swift
//  高层抄读器：把 ConnectionConfig + 操作包装成 C 桥接调用，并转发日志/trace。
//  建链状态机在 C(DLMSBridge.c)；本层负责生命周期与线程串行化(R8)。
//

import Foundation
import DLMSCore

// MARK: - 操作类型
enum DLMSOp { case read, write, method }

// MARK: - C 回调（convention(c)）

@convention(c)
private func dlmsTransportSend(_ user: UnsafeMutableRawPointer?,
                               _ data: UnsafePointer<UInt8>?,
                               _ len: Int32) -> Int32 {
    guard let user, let data, len > 0 else { return -1 }
    let t: GXDLMSTransport = Unmanaged.fromOpaque(user).takeUnretainedValue()
    return t.send(Data(bytes: data, count: Int(len))) ? 0 : -1
}

@convention(c)
private func dlmsTransportRecv(_ user: UnsafeMutableRawPointer?,
                               _ buf: UnsafeMutablePointer<UInt8>?,
                               _ cap: Int32,
                               _ got: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let user, let buf, let got, cap > 0 else { return -1 }
    let t: GXDLMSTransport = Unmanaged.fromOpaque(user).takeUnretainedValue()
    guard let d = t.receive(max: Int(cap)) else { return -1 }
    d.copyBytes(to: buf, count: d.count)
    got.pointee = Int32(d.count)
    return 0
}

@convention(c)
private func dlmsTransportTrace(_ user: UnsafeMutableRawPointer?,
                                _ dir: Int32,
                                _ frame: UnsafePointer<UInt8>?,
                                _ len: Int32) {
    guard let user, let frame, len > 0 else { return }
    let r: GXDLMSReader = Unmanaged.fromOpaque(user).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: frame, count: Int(len)))
    r.emitTrace(direction: dir == 2 ? .rx : .tx, hex: HexUtil.format(bytes))
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

    func emitTrace(direction: LogEntry.Kind, hex: String) {
        onTrace?(LogEntry(time: Date(), kind: direction, text: direction == .tx ? "TX" : "RX", hex: hex))
    }
    private func state(_ s: String) { onState?(s) }

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
        dlms_set_security(ctx, Int32(config.security.rawValue), config.akekHex, nil, nil)
        if !config.clientSystemTitleHex.isEmpty {
            dlms_set_clientSystemTitle(ctx, config.clientSystemTitleHex)
        }

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
                dlms_write(ctx, p.baseAddress, UInt16(classVal), UInt8(attr), hex, &out, &outLen)
            }
        case .method:
            state("执行 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_method(ctx, p.baseAddress, UInt16(classVal), UInt8(attr), hex, &out, &outLen)
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