//
//  MainView.swift
//  主调试台（方案 A / v1.2）：
//   连接摘要 + 连接测试 + ⚙参数页 | 操作对象(类/OBIS/属性/请求数据) | 读/写/执行
//   数据解析窗(解析开关) | 报文日志(TX/RX/信息多色)
//

import SwiftUI

@MainActor
final class SessionModel: ObservableObject {
    @Published var isBusy = false
    @Published var state = "未连接"
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @StateObject private var session = SessionModel()

    @State private var currentClass: ObisClass = .register
    @State private var currentObis = "1.0.1.8.0.255"
    @State private var currentAttr = "2"
    @State private var requestHex = ""
    @State private var showParams = false
    @State private var panel: Panel = .data

    enum Panel: String, CaseIterable { case data = "解析"; case log = "报文" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    objectEditor
                    actionButtons
                    statusBar
                    resultPanel
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("DLMS 调试台")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button { showParams = true } label: { Image(systemName: "gearshape") } }
            }
            .sheet(isPresented: $showParams) { ParamsView().environmentObject(store) }
            .onAppear {
                currentObis = store.recentObis.first ?? currentObis
            }
        }
    }

    // MARK: - 连接摘要 + 测试
    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(store.config.ip) : \(store.config.port)")
                    .font(.title3).bold()
                Spacer()
                Button { start(op: nil) } label: {
                    Label(session.isBusy ? "…" : "连接测试", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered).disabled(session.isBusy)
            }
            Text(store.config.addressSummary)
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - 操作对象
    private var objectEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("类", selection: $currentClass) {
                    ForEach(ObisClass.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                TextField("属性", text: $currentAttr)
                    .keyboardType(.numberPad).frame(width: 48).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("OBIS（支持 , . - : 与16进制段）", text: $currentObis)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Menu {
                    ForEach(store.recentObis, id: \.self) { code in
                        Button(code) { currentObis = code }
                    }
                    if !store.obisLibrary.isEmpty {
                        Divider()
                        ForEach(store.obisLibrary) { item in
                            Button(item.displayName) { currentObis = item.code }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                }
            }
            TextField("请求数据 (HEX，e.g. 11 01)", text: $requestHex)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - 读 / 写 / 执行
    private var actionButtons: some View {
        HStack(spacing: 10) {
            button("读", .primaryColor, .read)
            button("写", .blue, .write)
            button("执行", Color.secondary.opacity(0.35), .method)
        }
        .disabled(session.isBusy)
    }

    private func button(_ title: String, _ color: Color, _ op: DLMSOp) -> some View {
        Button { start(op: op) } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .foregroundStyle(.white).background(color).cornerRadius(12)
    }

    // MARK: - 状态
    private var statusBar: some View {
        HStack {
            Circle().fill(session.isBusy ? .orange : .green).frame(width: 9, height: 9)
            Text(session.state).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 解析 / 报文
    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("面板", selection: $panel) { ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)

            if panel == .data {
                HStack {
                    Toggle("解析", isOn: $store.config.parseEnabled).labelsHidden()
                    Spacer()
                    Button("清空") { store.parsedText = "" }
                }
                Text(store.parsedText.isEmpty ? "（暂无数据）" : store.parsedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            } else {
                logList
            }
        }
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.logs.isEmpty {
                Text("（暂无报文）").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(store.logs.suffix(200))) { e in
                HStack(alignment: .top, spacing: 6) {
                    Text(e.time.dlmsLogText).font(.caption2).foregroundStyle(.tertiary)
                    Text(e.text).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(color(for: e.kind))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .tx: return .green
        case .rx: return .blue
        case .info: return .secondary
        }
    }

    // MARK: - 执行
    private func start(op: DLMSOp?) {
        guard !session.isBusy else { return }
        if op != nil, ObisUtil.parse(currentObis) == nil {
            store.log(.info, "OBIS 无效")
            return
        }
        session.isBusy = true
        session.state = "连接中…"
        let opName = op.map { $0 == .read ? "读" : ($0 == .write ? "写" : "执行") } ?? "连接测试"
        store.log(.info, opName)
        if op != nil { store.rememberObis(currentObis) }

        let cfg = store.config
        let reader = GXDLMSReader(
            config: cfg,
            onTrace: { e in DispatchQueue.main.async {
                store.log(e.kind, (e.hex.map { "\(e.text)  \($0)" } ?? e.text))
            } },
            onState: { s in DispatchQueue.main.async {
                session.state = s
                if s.hasPrefix("完成 · ") {
                    store.parsedText = String(s.dropFirst("完成 · ".count))
                }
            } }
        )
        reader.run(op: op,
                   obis: op == nil ? nil : ObisUtil.parse(currentObis),
                   classVal: currentClass.rawValue,
                   attr: Int(currentAttr) ?? 2,
                   hex: requestHex) {
            session.isBusy = false
            store.persist()
        }
    }
}

extension DLMSOp: Equatable {
    static func == (a: DLMSOp, b: DLMSOp) -> Bool {
        switch (a, b) {
        case (.read, .read), (.write, .write), (.method, .method): return true
        default: return false
        }
    }
}