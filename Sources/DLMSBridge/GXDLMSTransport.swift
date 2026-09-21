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
        guard let connection = conn else { return nil }

        // 先把上一轮"晚到"攒下的字节消费掉，避免白白再等一次（也避免丢数据）。
        pendingLock.lock()
        if !pending.isEmpty {
            let data = pending
            pending = Data()
            pendingLock.unlock()
            return data
        }
        pendingLock.unlock()

        let sem = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, _ in
            // 关键改动：**无论本次是否已经超时**，收到的字节都先入队。
            // 超时了也不丢 —— C 层下一轮 recv 会在开头从 pending 里取到它。
            if let data, !data.isEmpty {
                self.pendingLock.lock()
                self.pending.append(data)
                self.pendingLock.unlock()
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .milliseconds(recvTimeoutMs))

        pendingLock.lock()
        if pending.isEmpty {
            pendingLock.unlock()
            return nil          // 真没数据：C 层按重试处理
        }
        let data = pending
        pending = Data()
        pendingLock.unlock()
        return data
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