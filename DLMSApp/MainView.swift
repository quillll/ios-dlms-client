//
//  MainView.swift
//  主调试台（v1.5）：
//   连接摘要 + 连接测试 + ⚙参数页 | 操作对象(类/OBIS/属性/请求数据，带合法性提示)
//   读 / 写 / 执行（**不做二次确认** —— 用户明确不需要，现场操作要快）
//   数据解析窗(解析开关 + 清空) | 报文日志(独立滚动 + 自动跟随；时间|TX·RX|类型|HEX 四列对齐；清空)
//

import SwiftUI

final class SessionModel: ObservableObject {
    @Published var isBusy = false
    @Published var state = "未连接"
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @StateObject private var session = SessionModel()

    @State private var currentClassText = "1"
    @State private var currentObis = "1.0.1.8.0.255"
    @State private var currentAttr = "2"
    @State private var requestHex = ""
    @State private var showParams = false
    @State private var panel: Panel = .data
    /// 满屏查看的目标面板（nil = 不显示）。做成可选是为了让解析/报文共用同一个满屏入口。
    @State private var fullScreenPanel: Panel?
    /// 「最近一条 OBIS」只在首次出现时恢复一次，避免每次回到本页覆盖用户手改的类/属性。
    @State private var didRestoreRecent = false

    enum Panel: String, CaseIterable, Identifiable {
        case data = "解析"
        case log = "报文"
        var id: String { rawValue }        // 满屏用 fullScreenCover(item:) 需要 Identifiable
    }

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.config.addressSummary)
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // 版本号放在常驻的主界面上（而不是只在设置页），排查时一眼能看到打的是哪版
                Text(AppInfo.versionBadge)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
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
                TextField("类 (10/16进制, 如 1 / 0x1F)", text: $currentClassText)
                    .textFieldStyle(.roundedBorder)
                TextField("属性", text: $currentAttr)
                    .frame(width: 64).textFieldStyle(.roundedBorder)
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
            obisHint
            TextField("请求数据 (HEX，e.g. 11 01)", text: $requestHex)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            requestHexHint
        }
    }

    /// 选中一个 OBIS：**同时**把「接口类」「属性」「请求数据」一起带过去。
    /// 之前只写 currentObis，导致换条 OBIS 后类/属性还是上一条的，读出来就是错的对象。
    /// `recentObis` 只存了 code 字符串，所以按 code 回 OBIS 清单里反查元数据；
    /// **比较前必须先归一** —— 清单里是点分形态（`1.0.1.8.0.255`），
    /// 而最近列表可能是用户当初的写法（`1-0:1.8.0*255`），不归一会查不到。
    /// 清单里确实没有该 code（手输且未入库）时只更新逻辑名，不动类/属性/数据，
    /// 免得把用户刚手填的值抹成默认。
    private func selectObis(code: String) {
        currentObis = code
        let key = ObisUtil.comparisonKey(code)
        guard let item = store.obisLibrary.first(where: { ObisUtil.comparisonKey($0.code) == key }) else { return }
        currentClassText = "\(item.objectClass)"
        currentAttr = "\(item.attribute)"
        // 请求数据跟着 OBIS 一起切：清单里配了就填，没配就**清空** ——
        // 否则切到另一条 OBIS 后，上一条残留的数据会被误发出去（写错对象）。
        requestHex = item.data
    }

    // MARK: - 输入合法性提示
    //
    // 原来只有点了按钮才知道输入能不能用（靠日志里蹦一句"OBIS 无效"）。
    // 这里提前给反馈，样式沿用密钥字段那套「图标 + 字节数」。

    private var obisHint: some View {
        let parsed = ObisUtil.parse(currentObis)
        return HStack(spacing: 4) {
            Image(systemName: parsed != nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
            Text(parsed != nil
                 ? "6 段已识别"
                 : (currentObis.isEmpty ? "如 1.0.1.8.0.255" : "OBIS 需 6 段、每段 0-255"))
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(parsed != nil ? Color.secondary : Color.orange)
    }

    private var requestHexHint: some View {
        let digits = HexUtil.normalize(requestHex).count
        let ok = requestHex.isEmpty || HexUtil.bytes(fromHex: requestHex) != nil
        return HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
            Text(requestHex.isEmpty
                 ? "写/执行用的 HEX（如 11 01）；留空 = 无参数。选 OBIS 时会按清单自动填入"
                 : (ok ? "\(digits / 2) 字节" : "HEX 需偶数位且仅含 0-9 A-F"))
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(ok ? Color.secondary : Color.orange)
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

    /// 解析面板里**单段**的正文。
    /// 「解析使能」关闭时只保留该段第一行（含类型的原始 HEX），不做类型/值解析 ——
    /// 这个开关原先没有任何地方读取（只有两处 Toggle 在写），拨了完全没反应。
    private func parseBlockText(_ block: String) -> String {
        guard !store.config.parseEnabled else { return block }
        return block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? block
    }

    /// 解析面板：**累积 + 独立滚动 + 自动跟随到底**（与报文面板同一套做法）。
    /// 原来只有一个 Text、每次操作整体替换，而且跟着整页一起滚 —— 攒不了历史、
    /// 新结果落在下方也看不到。`height = nil` 时用于满屏。
    private func parseList(height: CGFloat?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.parseEntries.isEmpty {
                        Text("（暂无数据）").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(store.parseEntries.enumerated()), id: \.offset) { idx, block in
                        Text(parseBlockText(block))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                            .id(idx)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: height)
            // 有新结果就自动滚到底（一次操作结束后不再有新内容，此时可自由上翻历史）
            .onChange(of: store.parseEntries.count) { _ in
                guard !store.parseEntries.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(store.parseEntries.count - 1, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("面板", selection: $panel) { ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)

            if panel == .data {
                panelHeader(clearEnabled: !store.parseEntries.isEmpty) {
                    HStack(spacing: 6) {
                        Toggle("解析", isOn: $store.config.parseEnabled).labelsHidden()
                        Text("解析使能").font(.caption2).foregroundStyle(.tertiary)
                        Button { fullScreenPanel = .data } label: {
                            Label("满屏", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                        }
                    }
                } clear: {
                    store.clearParsed()
                }
                parseList(height: 260)
            } else {
                panelHeader(clearEnabled: !store.logs.isEmpty) {
                    HStack(spacing: 8) {
                        Text(logStatusText).font(.caption2).foregroundStyle(.tertiary)
                        Button { fullScreenPanel = .log } label: {
                            Label("满屏", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                        }
                    }
                } clear: {
                    store.clearLogs()
                }
                logList
            }
        }
        // 解析/报文都嵌在外层 ScrollView 里，高度被压住、也拉不开 —— 给它们一个整屏入口
        .fullScreenCover(item: $fullScreenPanel) { p in fullScreenView(p) }
    }

    /// 解析/报文的满屏视图（复用同一套渲染与自动跟随；高度放开，见 logList 的说明）。
    private func fullScreenView(_ p: Panel) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if p == .data { parseList(height: nil) } else { logList(height: nil) }
            }
            .padding(.horizontal)
            .navigationTitle(p == .data ? "解析 · \(store.parseEntries.count) 条"
                                        : "报文 · \(store.logs.count) 条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { fullScreenPanel = nil }
                }
                ToolbarItem(placement: .primaryAction) {
                    if p == .data {
                        Button { store.clearParsed() } label: { Label("清空", systemImage: "trash") }
                            .disabled(store.parseEntries.isEmpty)
                    } else {
                        Button { store.clearLogs() } label: { Label("清空", systemImage: "trash") }
                            .disabled(store.logs.isEmpty)
                    }
                }
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

    private var logList: some View { logList(height: 260) }

    /// `height = nil` 时不加高度约束（满屏用）。
    /// ⚠️ 内嵌时写死 260pt；满屏时必须放开，否则"满屏"里只有 260pt 高、下面大片空白
    ///（上一版就是这样，等于满屏没生效）。
    private func logList(height: CGFloat?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.logs.isEmpty {
                        Text("（暂无报文）").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(store.logs.suffix(200))) { e in
                        logRow(e).id(e.id)
                    }
                }
                .padding(.vertical, 2)
            }
            // 日志是**无限追加**的：以前它跟着整页一起滚，新报文落在下方根本看不到，
            // 攒到 200 行时整页被拉得极长。这里给它「独立滚动 + 固定高度」，
            // 有新报文时自动滚到底。
            // （一次操作结束后不再有新流量，所以此时可以自由向上翻阅历史。）
            .frame(height: height)
            .onChange(of: store.logs.count) { _ in
                guard let last = store.logs.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    /// 单行报文：**首行**放「时间 | TX·RX | 报文类型」，**HEX 另起一行、从行首铺满整宽**。
    ///
    /// 原来 HEX 挤在首行右侧：三列固定宽已占掉约 192pt，窄屏上只剩一百多点宽，
    /// 稍长的报文就被压成窄窄一条竖着折行，基本没法读。
    /// 现在 HEX 独占整宽（约能放 40 字符 ≈ 13 字节/行），可读性高得多。
    private func logRow(_ e: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                Text(e.time.dlmsLogText).font(.caption2)
                    .foregroundStyle(.tertiary).frame(width: 74, alignment: .leading)
                if let hex = e.hex, !hex.isEmpty {
                    // 报文行：TX/RX 与报文类型各占固定列，HEX 放下一行独占整宽。
                    Text(e.text).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(color(for: e.kind)).frame(width: 26, alignment: .leading)
                    Text(e.label).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    // 信息行：`text` 本身就是整句消息（如"建链失败: Data receive failed."），
                    // 必须给它整行宽度。
                    // 之前一律套用 26pt 的 TX/RX 列宽 → 长消息被逐字折成一列竖条，完全没法读。
                    Text(e.text).font(.caption2)
                        .foregroundStyle(color(for: e.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let hex = e.hex, !hex.isEmpty {
                Text(hex)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color(for: e.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .tx: return .green
        case .rx: return .blue
        case .info: return .secondary
        }
    }

    // MARK: - 执行

    /// 入口（读/写/执行按钮 + 连接测试都走这里）。
    /// 刻意**不做**写/执行的二次确认 —— 用户明确不需要（现场操作要快）。
    private func start(op: DLMSOp?) {
        guard !session.isBusy else { return }
        if op != nil, ObisUtil.parse(currentObis) == nil {
            store.log(.info, "OBIS 无效，无法执行", level: .error)
            return
        }
        session.isBusy = true
        session.state = "连接中…"
        let opName = op.map { $0 == .read ? "读" : ($0 == .write ? "写" : "执行") } ?? "连接测试"
        store.log(.info, opName)
        // 存**归一形态**：否则同一对象按不同写法会进"最近"列表两条，
        // 且回查清单时匹配不上（见 selectObis）。
        if op != nil { store.rememberObis(ObisUtil.comparisonKey(currentObis)) }

        let cfg = store.config
        let reader = GXDLMSReader(
            config: cfg,
            onTrace: { e in DispatchQueue.main.async {
                // label 必须一起透传，否则报文面板的"类型"列会整列空白
                store.log(e.kind, e.text, hex: e.hex, label: e.label)
            } },
            onState: { s in DispatchQueue.main.async {
                session.state = s
            } },
            onFinish: { value, err in DispatchQueue.main.async {
                // 结果与状态分开走：不再靠"完成 · "前缀从状态文本里拆值
                if let value {
                    store.appendParsed(value)
                    // 连上了才记入"最近连接"（参数页下拉用）；失败的地址不进列表。
                    store.config.rememberEndpoint()
                }
                // 注意：第一个参数是 LogEntry.Kind（只有 info/tx/rx）；
                // 错误级别走 level: —— `error` 是 LogEntry.Level 的成员，别传错位置。
                if let err { store.log(.info, err, level: .error) }
            } }
        )
        reader.run(op: op,
                   obis: op == nil ? nil : ObisUtil.parse(currentObis),
                   // NumberInput.parse 返回 Int?；兜底默认 **1 类**（与 ObisItem.objectClass 一致）。
                   // GXDLMSReader.run 的 classVal 参数就是 Int（内部再转 UInt16 给 C）。
                   // 这里不要再包一层 UInt16(...)，否则报 cannot convert 'UInt16' to 'Int'。
                   classVal: NumberInput.parse(currentClassText) ?? 1,
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