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
    /// 数据解析输出（**累积**，每条操作追加一段，直到「清空」）。
    ///
    /// 为什么是数组而不是单个字符串：解析面板要像报文面板那样滚动查看历史，
    /// 且「解析使能」关闭时需**逐段**只取第一行 —— 拼成一整串后就分不清段落边界了。
    @Published var parseEntries: [String] = []
    /// 解析历史条数上限（与 logs 同理，防长会话无限增长）。
    static let parseEntryLimit = 200

    /// 追加一条解析结果（空白串忽略）。
    func appendParsed(_ block: String) {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        parseEntries.append(trimmed)
        if parseEntries.count > Store.parseEntryLimit {
            parseEntries.removeFirst(parseEntries.count - Store.parseEntryLimit)
        }
    }

    /// 清空解析历史（面板右上角「清空」）。
    func clearParsed() { parseEntries.removeAll() }
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
    /// 写盘队列：**串行** + **原子写**。
    /// 串行是为了保证「后一次 persist 覆盖前一次」的顺序不被异步打乱
    ///（否则旧快照可能后落盘，把新配置写回去）；原子写避免写到一半被读。
    /// 编码仍留在调用线程（很快），只把真正的磁盘 I/O 挪走。
    private static let saveQueue = DispatchQueue(label: "dlms.store.save")

    private static func save<T: Encodable>(_ v: T, to url: URL) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        // P2：原来是主线程同步写盘（Store 是 @MainActor，每次操作完都会调 persist）。
        // 文件虽小，但低端机或磁盘繁忙时仍可能造成掉帧。
        saveQueue.async { try? d.write(to: url, options: .atomic) }
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

    /// 日志保留上限（UI 只渲染最近 200 条，见 `MainView.logStatusText`）。
    private static let logLimit = 2000
    /// 高水位：超过它才做一次裁剪。P1 的关键就在这个滞后量 ——
    /// 见 `log()` 里的说明。
    private static let logHighWater = 2500

    /// `label` 是报文类型（AARQ / Get-Request / SNRM …）。
    /// 必须透传：View 的 trace 回调是用 LogEntry 重建一条再存进来的，
    /// 这里漏掉 label 的话，报文面板的"类型"列会整列空白。
    func log(_ kind: LogEntry.Kind, _ text: String, hex: String? = nil,
             label: String = "", level: LogEntry.Level = .debug) {
        let e = LogEntry(time: Date(), level: level, kind: kind, text: text, label: label, hex: hex)
        logs.append(e)
        // P1：不要用 `removeFirst(1)` 逐条裁。到上限后每追加一条都要前移约 2000 个元素
        //（O(n)），报文高频时这是实打实的主线程热点（叠加 @Published 触发 UI 刷新）。
        // 改成「超过高水位才一次性切回上限」，把那次 O(n) 摊薄到每 500 条一次。
        if logs.count > Store.logHighWater {
            logs = Array(logs.suffix(Store.logLimit))
        }
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