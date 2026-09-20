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
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
            if let data, !data.isEmpty { result = data }
            else if error != nil || isComplete { result = nil }
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + .milliseconds(recvTimeoutMs))
        // 超时视为无数据（C 层按重试处理）；取消挂起回调，避免残留。
        if waited != .success { result = nil }
        return result
    }

    func cancel() {
        conn?.cancel()
        conn = nil
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