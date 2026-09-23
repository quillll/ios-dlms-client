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
    // 兜底夹紧：`buf` 是 C 侧固定大小的栈数组，而 `copyBytes` 不做边界检查。
    // `receive` 已按 cap 截断，这里再挡一道，防止将来换实现时把这条约束丢掉。
    let n = min(Int(cap), d.count)
    d.copyBytes(to: buf, count: n)
    got.pointee = Int32(n)
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
    private let config: ConnectionConfig
    private let transport: GXDLMSTransport
    private let workQueue = DispatchQueue(label: "dlms.reader.work")
    private var onTrace: ((LogEntry) -> Void)?
    private var onState: ((String) -> Void)?
    /// 会话结束回调：(成功值, 失败描述)，两者恰有一个非 nil。
    /// 之前没有这个回调，而是把结果拼进状态文本（`"完成 · xxx"`）再由 View 拆前缀 —— 
    /// 一旦状态文案里出现同样字样就会误判，太脆。
    private var onFinish: ((String?, String?) -> Void)?

    init(config: ConnectionConfig,
         onTrace: @escaping (LogEntry) -> Void,
         onState: @escaping (String) -> Void,
         onFinish: @escaping (String?, String?) -> Void = { _, _ in }) {
        self.config = config
        self.transport = GXDLMSTransport()
        self.onTrace = onTrace
        self.onState = onState
        self.onFinish = onFinish
    }

    func emitTrace(direction: LogEntry.Kind, frame: [UInt8]) {
        onTrace?(LogEntry(
            time: Date(), kind: direction,
            text: direction == .tx ? "TX" : "RX",
            label: Self.classify(frame),
            hex: HexUtil.format(frame)))
    }

    /// 从帧头区(地址/控制之后)找 COSEM/HDLC 顶层 tag，识别报文类型。
    /// 纯启发式：只看前 16 字节里首个命中的 tag，供日志快速标注，非精确解码。
    ///
    /// ⚠️ HDLC 链路层控制字段取值必须照 enums.h 来（已逐一核实）：
    ///      SNRM = 0x93 (enums.h:1203)
    ///      UA   = 0x73 (enums.h:1208)
    ///      DISC = 0x53 (enums.h:1223)
    ///      DM   = 0x1F (enums.h:1193)
    ///    这里曾误写成 SNRM=0x35 / DISC=0x40 —— 后果是这两个报文永远标不出来，
    ///    而且 0x35/0x40 会撞上 HDLC 地址/长度字段产生**误标**。
    ///
    /// 进一步的改进方向：C 层其实已经精确解出了命令（gxReplyData.command / DLMS_COMMAND），
    /// 让 bridge 把命令号一起回传即可去掉这份启发式。当前先保持启发式。
    static func classify(_ f: [UInt8]) -> String {
        let tags: [(UInt8, String)] = [
            (0x60, "AARQ"), (0x61, "AARE"), (0x62, "RLRQ"), (0x63, "RLRE"),
            (0xC0, "Get-Request"), (0xC4, "Get-Response"),
            (0xC1, "Set-Request"), (0xC5, "Set-Response"),
            (0xC3, "Action-Request"), (0xC7, "Action-Response"),
            (0x93, "SNRM"), (0x73, "UA"), (0x53, "DISC"), (0x1F, "DM"),
        ]
        for b in f.prefix(16) {
            if let m = tags.first(where: { $0.0 == b }) { return m.1 }
        }
        return ""
    }
    private func state(_ s: String) { onState?(s) }

    /// Swift String → C `const char*`（空串→NULL）。
    ///
    /// ⚠️ **仅限同步调用**：指针来自 `(s as NSString).utf8String`，有效期依赖 NSString
    /// 临时对象的自动释放。当前所有调用都是"C 函数在调用期间消费完指针"，所以安全；
    /// 若将来要把指针交给异步的、或会保存它的 C 接口，必须改用 `withCString`
    ///（参见 `syncRun` 里 `pwd.withCString` 的正确写法），否则会 use-after-free。
    private func cStr(_ s: String) -> UnsafePointer<CChar>? {
        s.isEmpty ? nil : (s as NSString).utf8String
    }

    /// 在后台串行执行一次完整会话（建链→操作→断链）。
    func run(op: DLMSOp?, obis: [UInt8]?, classVal: Int, attr: Int, hex: String?, completion: @escaping () -> Void = {}) {
        workQueue.async {
            do {
                let value = try self.syncRun(op: op, obis: obis, classVal: classVal, attr: attr, hex: hex)
                self.state("完成")
                self.onFinish?(value, nil)
            } catch {
                let msg = error.localizedDescription
                self.state("失败 · \(msg)")
                self.onFinish?(nil, msg)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// 读/写/执行的输出缓冲上限。C 层 `replyValueString` 按 `cap-1` 截断写入，
    /// 原来只有 512 字节 → 长响应会被静默截断。这里给足余量。
    private static let outBufferSize = 4096

    private func syncRun(op: DLMSOp?, obis: [UInt8]?, classVal: Int, attr: Int, hex: String?) throws -> String {
        transport.recvTimeoutMs = max(config.recvTimeoutMs, 500)

        try transport.connect(host: config.ip, port: UInt16(clamping: config.port))
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
        // 建链失败时把"卡在第几步""是不是发送失败"一起报出来。
        // 报文日志天然看不到"send 失败"（trace 只在发送成功之后才调用），
        // 所以只凭报文分不清「请求没生成」「生成但发不出去」「发出去了没回应」—— 这两个接口补上。
        let initCode = dlms_initialize(ctx)
        if initCode != 0 {
            let step = dlms_lastStep(ctx)
            let stepName = String(cString: dlms_step_name(step))
            let sendNote = dlms_sendFailed(ctx) != 0 ? "，发送失败（日志里不会有这帧）" : ""
            throw DLMSReaderError.step(
                "建链失败（步骤 \(step) · \(stepName)\(sendNote)）：\(errorText(initCode))")
        }

        // 连接测试模式：只建链即返回。
        guard let op else { return "连接成功" }

        guard let obis else { throw DLMSReaderError.noObis }
        let codeHex = HexUtil.format(obis, upper: false)

        var out = [CChar](repeating: 0, count: Self.outBufferSize)
        var outLen: Int32 = Int32(Self.outBufferSize)
        var ret: Int32
        switch op {
        case .read:
            state("读 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_read(ctx, p.baseAddress, UInt16(clamping: classVal), UInt8(clamping: attr), &out, &outLen)
            }
        case .write:
            state("写 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_write(ctx, p.baseAddress, UInt16(clamping: classVal), UInt8(clamping: attr), cStr(hex ?? ""), &out, &outLen)
            }
        case .method:
            state("执行 \(codeHex)")
            ret = obis.withUnsafeBufferPointer { p in
                dlms_method(ctx, p.baseAddress, UInt16(clamping: classVal), UInt8(clamping: attr), cStr(hex ?? ""), &out, &outLen)
            }
        }

        guard ret == 0 else { throw DLMSReaderError.dlmsFailed(errorText(ret)) }
        // D4：检出「被 C 层截断」。replyValueString 的 outLen 语义是「写入字节数(含 NUL)」，
        // 截断时 n = cap-1，于是 outLen == cap —— 据此判断，不需要改 C。
        // 原来只是静默截断：长响应（OCTET_STRING / ProfileGeneric 曲线）显示残缺却毫无提示。
        let truncated = outLen >= Int32(Self.outBufferSize)
        var text = outLen > 0 ? String(cString: out) : ""
        if truncated {
            text += "\n\n⚠️ 响应超过 \(Self.outBufferSize) 字节上限，已截断显示"
        }
        state("断链")
        return text
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