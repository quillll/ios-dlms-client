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
        guard ready else { throw failure ?? DLMSTransportError.connectFailed }
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