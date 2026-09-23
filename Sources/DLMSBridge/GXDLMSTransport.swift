//
//  GXDLMSTransport.swift
//  基于 Network.framework 的 TCP 传输。DLMS 桥接(C)是同步驱动，
//  这里用 DispatchSemaphore 在后台队列阻塞等待 I/O 完成（M3：超时已参数化）。
//

import Foundation
import Network

final class GXDLMSTransport {
    private let ioQueue = DispatchQueue(label: "dlms.transport.io")
    private var conn: NWConnection?
    /// 预读缓冲：**超时之后才到**的字节先存在这里，下次 `receive` 先消费它。
    ///
    /// 起因：原实现超时就把局部 `result` 丢掉，而 `NWConnection.receive` 的 completion
    /// 仍会因晚到的数据触发 —— 那些字节写进已失效的局部变量后**永久丢失**。
    /// 长帧被 TCP 分段时尤其致命：丢一段就再也拼不出完整帧，只能整个重传。
    /// （= 《代码审核报告》D5；用户现场遇到的"数据过长就没法交互"。）
    private var pending = Data()
    private let pendingLock = NSLock()
    /// 单次 recv 读取超时（ms），由 ConnectionConfig 提供。
    var recvTimeoutMs: Int = 3000
    /// 连接超时（ms）。
    var connectTimeoutMs: Int = 5000
    /// 预读缓冲的字节上限，与 C 侧 `DLMS_MAX_RX_BYTES`(256KB) 对齐。
    ///
    /// 为什么需要这道闸门：`connection.receive` 的 completion 在超时后**无法取消**
    ///（Network.framework 没有"取消单个 receive"的 API，只能 cancel 整个连接），
    /// 所以 C 层每超时重试一次就多留一个挂起的 completion
    /// （`dlmsSendFrame` 允许重试到 `DLMS_MAX_RECV_ROUNDS = 256`）。
    /// 对端一次发来长数据时它们会接连触发、把数据全塞进 `pending` —— 没有上限就能长到几百 KB。
    private static let pendingLimit = 256 * 1024

    // MARK: - 连接

    func connect(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DLMSTransportError.invalidPort(port)
        }
        // D6：先把可能残留的旧连接收掉再建新的。
        // 原来是直接 `conn = connection` 覆盖：旧 NWConnection 既不 cancel、
        // 也不释放它的 stateUpdateHandler，多次连接会累积泄漏与残留回调。
        conn?.cancel()
        conn = nil
        clearPending()
        let connection = NWConnection(host: .init(host), port: endpointPort, using: .tcp)
        conn = connection
        let sem = DispatchSemaphore(value: 0)
        var ready = false
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready = true; sem.signal()
            case .failed(let e): failure = e; sem.signal()
            case .cancelled: sem.signal()
            default: break
            }
        }
        connection.start(queue: ioQueue)
        _ = sem.wait(timeout: .now() + .milliseconds(connectTimeoutMs))
        if !ready {
            // D6：连接失败/超时也要收尾 —— 原来直接 throw，连接会停在 .connecting 挂着。
            // 先清 handler 再 cancel，避免 cancel 触发回调（此时信号量已超时，无意义）。
            connection.stateUpdateHandler = nil
            connection.cancel()
            if conn === connection { conn = nil }
            throw failure ?? DLMSTransportError.connectFailed
        }
    }

    // MARK: - 同步收发（供 C 回调）

    func send(_ data: Data) -> Bool {
        guard let connection = conn else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        connection.send(content: data, completion: .contentProcessed { error in
            ok = (error == nil); sem.signal()
        })
        _ = sem.wait(timeout: .now() + .milliseconds(recvTimeoutMs))
        return ok
    }

    func receive(max: Int) -> Data? {
        guard let connection = conn, max > 0 else { return nil }

        // 先把上一轮"晚到"攒下的字节消费掉，避免白白再等一次（也避免丢数据）。
        // ⚠️ 必须按 `max` **截断**、余量留在缓冲里：调用方（C 桥接）给的接收缓冲是
        // 固定的栈数组（`DLMSBridge.c` 的 `unsigned char tmp[2048]`），而 Swift 侧
        // `copyBytes(to:count:)` 是无边界检查写入 —— 整份排空会直接写爆它。
        // 而且超时后挂起的 completion 会累积多个（见 `pendingLimit` 注释），
        // 一次排空完全可能远大于 `max`。
        pendingLock.lock()
        if !pending.isEmpty {
            let data = Self.takePending(&pending, max: max)
            pendingLock.unlock()
            return data
        }
        pendingLock.unlock()

        let sem = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, _ in
            // 关键改动：**无论本次是否已经超时**，收到的字节都先入队。
            // 超时了也不丢 —— C 层下一轮 recv 会在开头从 pending 里取到它。
            if let data, !data.isEmpty {
                self.appendPending(data)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .milliseconds(recvTimeoutMs))

        pendingLock.lock()
        if pending.isEmpty {
            pendingLock.unlock()
            return nil          // 真没数据：C 层按重试处理
        }
        let data = Self.takePending(&pending, max: max)
        pendingLock.unlock()
        return data
    }

    /// 从 `pending` 头部取出至多 `max` 字节，**余量留在缓冲里**供下次取用
    ///（这才符合"预读"的语义；旧实现整份排空，是 N1 栈溢出的直接原因）。
    /// 复制一份而不是返回 slice，避免一小段数据把整块底层存储留住。
    ///
    /// 刻意**不加 `private`** —— 单测要直接断言它（这是防栈溢出的关键一步，
    /// 而 `GXDLMSTransport` 依赖 Network.framework，端到端不好在单测里跑）。
    static func takePending(_ buf: inout Data, max: Int) -> Data {
        let n = min(max, buf.count)
        let out = Data(buf.prefix(n))
        buf.removeFirst(n)
        return out
    }

    /// 预读入队，并守住字节上限。
    /// 超限时**丢弃最旧的** —— 走到这一步说明对端在异常推送，新数据更可能是
    /// 当前请求的响应；丢老数据能让 C 层通过超时重试自然重来，而不是无限涨内存。
    private func appendPending(_ data: Data) {
        pendingLock.lock()
        pending.append(data)
        if pending.count > Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit)
        }
        pendingLock.unlock()
    }

    func cancel() {
        conn?.cancel()
        conn = nil
        clearPending()
    }

    /// 清空预读缓冲 —— 新会话不该继承上一轮的残留字节。
    private func clearPending() {
        pendingLock.lock()
        pending = Data()
        pendingLock.unlock()
    }
}

enum DLMSTransportError: LocalizedError {
    case invalidPort(UInt16)
    case connectFailed
    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "无效端口: \(p)"
        case .connectFailed: return "TCP 连接失败或超时"
        }
    }
}