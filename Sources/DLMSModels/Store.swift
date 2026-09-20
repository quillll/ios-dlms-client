//
//  Store.swift
//  应用数据仓库：连接配置(记住上次) + 全局 OBIS 清单 + 最近读过的 OBIS + 日志。
//  JSON 文件持久化，数据量小。
//

import Combine
import Foundation

@MainActor
final class Store: ObservableObject {
    /// 连接配置（单表）。
    @Published var config: ConnectionConfig
    /// 全局 OBIS 清单。
    @Published var obisLibrary: [ObisItem] = []
    /// 最近读过的 OBIS 代码（填充下拉，不存值）。
    @Published var recentObis: [String] = []
    /// 报文 / 数据日志。
    @Published var logs: [LogEntry] = []
    /// 最近一次数据解析输出。
    @Published var parsedText: String = ""
    /// 连接状态描述。
    @Published var connectionState: String = "未连接"

    private let fileURLs: (config: URL, obis: URL, recent: URL)

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURLs = (dir.appendingPathComponent("config.json"),
                    dir.appendingPathComponent("obis.json"),
                    dir.appendingPathComponent("recent.json"))
        config = Store.load(fileURLs.config) ?? ConnectionConfig()
        obisLibrary = Store.load(fileURLs.obis) ?? ObisItem.presets
        recentObis = Store.load(fileURLs.recent) ?? []
    }

    // MARK: - 持久化

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func save<T: Encodable>(_ v: T, to url: URL) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: url)
    }
    func persist() {
        Store.save(config, to: fileURLs.config)
        Store.save(obisLibrary, to: fileURLs.obis)
        Store.save(recentObis, to: fileURLs.recent)
    }

    // MARK: - OBIS 管理（覆盖式去重）

    func upsert(obis: ObisItem) {
        if let i = obisLibrary.firstIndex(where: { $0.id == obis.id || $0.code == obis.code }) {
            var m = obis; m.id = obisLibrary[i].id; obisLibrary[i] = m
        } else {
            obisLibrary.append(obis)
        }
        persist()
    }
    func remove(obisID: UUID) {
        obisLibrary.removeAll { $0.id == obisID }
        persist()
    }
    func importObis(_ items: [ObisItem]) {
        for it in items { upsert(obis: it) }
        persist()
    }

    // MARK: - 日志 / 状态

    /// `label` 是报文类型（AARQ / Get-Request / SNRM …）。
    /// 必须透传：View 的 trace 回调是用 LogEntry 重建一条再存进来的，
    /// 这里漏掉 label 的话，报文面板的"类型"列会整列空白。
    func log(_ kind: LogEntry.Kind, _ text: String, hex: String? = nil,
             label: String = "", level: LogEntry.Level = .debug) {
        let e = LogEntry(time: Date(), level: level, kind: kind, text: text, label: label, hex: hex)
        logs.append(e)
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }
    func clearLogs() { logs.removeAll() }

    func rememberObis(_ code: String) {
        recentObis.removeAll { $0 == code }
        recentObis.insert(code, at: 0)
        if recentObis.count > 30 { recentObis = Array(recentObis.prefix(30)) }
        persist()
    }
}

// 内置常用 OBIS 预置。
extension ObisItem {
    static let presets: [ObisItem] = [
        ObisItem(code: "0.0.1.0.0.255", name: "逻辑设备名", objectClass: 1),
        ObisItem(code: "1.0.1.8.0.255", name: "正向有功总电量", unit: "kWh"),
        ObisItem(code: "1.0.2.8.0.255", name: "反向有功总电量", unit: "kWh"),
        ObisItem(code: "1.0.1.7.0.255", name: "当前功率", unit: "kW"),
        ObisItem(code: "1.0.32.7.0.255", name: "电压L1", unit: "V"),
        ObisItem(code: "1.0.31.7.0.255", name: "电流A", unit: "A"),
        ObisItem(code: "0.0.96.1.0.255", name: "设备ID"),
    ]
}