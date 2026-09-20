//
//  MainView.swift
//  主调试台（方案 A / v1.2）：
//   连接摘要 + 连接测试 + ⚙参数页 | 操作对象(类/OBIS/属性/请求数据) | 读/写/执行
//   数据解析窗(解析开关) | 报文日志(TX/RX/信息多色)
//

import SwiftUI

final class SessionModel: ObservableObject {
    @Published var isBusy = false
    @Published var state = "未连接"
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @StateObject private var session = SessionModel()

    @State private var currentClassText = "3"
    @State private var currentObis = "1.0.1.8.0.255"
    @State private var currentAttr = "2"
    @State private var requestHex = ""
    @State private var showParams = false
    @State private var panel: Panel = .data
    /// 「最近一条 OBIS」只在首次出现时恢复一次，避免每次回到本页覆盖用户手改的类/属性。
    @State private var didRestoreRecent = false

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
                // 首次出现时把「最近一条 OBIS」连同它的类/属性一起恢复
                // （三者必须一致，否则会拿错类去读）。只做一次，
                // 免得每次回到本页都把用户手改的类/属性冲掉。
                if !didRestoreRecent {
                    didRestoreRecent = true
                    if let code = store.recentObis.first { selectObis(code: code) }
                }
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
                // 键盘统一用系统默认：类与属性都可能填 16 进制（如 0x1F），
                // 限定纯数字键盘反而是限制。
                TextField("类 (10/16进制, 如 3 / 0x1F)", text: $currentClassText)
                    .textFieldStyle(.roundedBorder)
                TextField("属性", text: $currentAttr)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("OBIS（支持 , . - : 与16进制段）", text: $currentObis)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Menu {
                    ForEach(store.recentObis, id: \.self) { code in
                        Button(code) { selectObis(code: code) }
                    }
                    if !store.obisLibrary.isEmpty {
                        Divider()
                        ForEach(store.obisLibrary) { item in
                            Button(item.displayName) { selectObis(code: item.code) }
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

    /// 选中一个 OBIS：**同时**把「接口类」与「属性」一起带过去。
    /// 之前只写 currentObis，导致换条 OBIS 后类/属性还是上一条的，读出来就是错的对象。
    /// `recentObis` 只存了 code 字符串，所以按 code 回 OBIS 清单里反查元数据；
    /// 清单里查不到该 code（例如手输且未入库）时只更新逻辑名，不动类/属性，
    /// 免得把用户刚手填的值抹成默认。
    private func selectObis(code: String) {
        currentObis = code
        guard let item = store.obisLibrary.first(where: { $0.code == code }) else { return }
        currentClassText = "\(item.objectClass)"
        currentAttr = "\(item.attribute)"
    }

    // MARK: - 读 / 写 / 执行
    private var actionButtons: some View {
        HStack(spacing: 10) {
            button("读", .purple, .read)
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
                panelHeader(clearEnabled: !store.parsedText.isEmpty) {
                    HStack(spacing: 6) {
                        Toggle("解析", isOn: $store.config.parseEnabled).labelsHidden()
                        Text("解析使能").font(.caption2).foregroundStyle(.tertiary)
                    }
                } clear: {
                    store.parsedText = ""
                }
                Text(store.parsedText.isEmpty ? "（暂无数据）" : store.parsedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            } else {
                panelHeader(clearEnabled: !store.logs.isEmpty) {
                    Text(logStatusText).font(.caption2).foregroundStyle(.tertiary)
                } clear: {
                    store.clearLogs()
                }
                logList
            }
        }
    }

    /// 两个面板共用的标题行：左边是本面板的开关/状态，右边**固定**是「清空」。
    /// 做成同一套布局，是为了切面板时视线不用重新找按钮 —— 之前报文面板压根没有清空入口。
    private func panelHeader<Leading: View>(clearEnabled: Bool = true,
                                            @ViewBuilder leading: () -> Leading,
                                            clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            Button(action: clear) {
                Label("清空", systemImage: "trash").font(.caption2)
            }
            .disabled(!clearEnabled)
        }
    }

    /// 报文条数提示。`Store` 最多留 2000 条，但列表只渲染最近 200 条 ——
    /// 必须让用户看得见这个差别，否则会以为"清空"删掉的和屏幕上的不是同一批。
    private var logStatusText: String {
        let total = store.logs.count
        guard total > 0 else { return "" }   // 空的时候让下方占位文字说话，避免重复
        return total > 200 ? "共 \(total) 条 · 显示最近 200" : "共 \(total) 条"
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.logs.isEmpty {
                Text("（暂无报文）").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(store.logs.suffix(200))) { e in
                HStack(alignment: .top, spacing: 6) {
                    Text(e.time.dlmsLogText).font(.caption2)
                        .foregroundStyle(.tertiary).frame(width: 74, alignment: .leading)
                    Text(e.text).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(color(for: e.kind)).frame(width: 26, alignment: .leading)
                    // 报文类型单独占一列、固定宽度，这样 HEX 的起始 x 才是恒定的。
                    // 早前把类型拼进 hex 串中间加两个空格：类型名长度不一
                    // （AARQ 4 字符 / Get-Response 12 字符）就又把 HEX 挤错位了。
                    Text(e.label).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                    Text(e.hex ?? "")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(color(for: e.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                store.log(e.kind, e.text, hex: e.hex)
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
                   // NumberInput.parse 返回 Int?，?? 3 之后已是 Int；
                   // GXDLMSReader.run 的 classVal 参数就是 Int（内部再转 UInt16 给 C）。
                   // 这里不要再包一层 UInt16(...)，否则报 cannot convert 'UInt16' to 'Int'。
                   classVal: NumberInput.parse(currentClassText) ?? 3,
                   // 属性与「类」用同一套 10/16 进制识别（键盘已放开，用户可能填 0x03）
                   attr: NumberInput.parse(currentAttr) ?? 2,
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