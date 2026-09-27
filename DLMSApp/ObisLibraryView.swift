//
//  ObisLibraryView.swift
//  全局 OBIS 清单：新增/编辑、JSON/CSV 导入、常用预置（按 code 覆盖去重）。
//

import SwiftUI
import UniformTypeIdentifiers

struct ObisLibraryView: View {
    @EnvironmentObject var store: Store
    @State private var editing: ObisItem?
    @State private var showEditor = false
    @State private var showPresets = false
    @State private var showImporter = false
    @State private var alertTitle = ""
    @State private var alertText = ""
    @State private var showAlert = false
    /// 搜索词（名称或 OBIS 代码）
    @State private var query = ""
    /// 复制（duplicate）模式的源条目；此时 `editing` 必须为 nil。
    @State private var copySource: ObisItem? = nil

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Text(store.obisLibrary.isEmpty
                         ? "（清单为空：点右上角 ＋ 新增，或用 ✦ 从常用项里挑一条）"
                         : "没有匹配的条目")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(filtered) { item in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            // 与**下拉菜单同一套格式**（用户定的）：
                            //   行1 = 标题（名称；无名称时用逻辑名）
                            //   行2 = 身份部分 `类*逻辑名*属性[*请求数据]`
                            // 两处都派生自 `ObisItem.identityLabel`，不可能不一致。
                            //
                            // 之前是「名称 · code」+「类N 属N」徽标 +「→ 数据」三行，
                            // 既和下拉不统一，请求数据还重复显示了一次。
                            Text(item.name.isEmpty ? item.code : item.name).font(.body)
                            Text(item.identityLabel)
                                .font(.caption).monospaced().foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        // **复制一条**：以本条为模板打开编辑器，保存时作为**新条目**插入
                        //（保存前会按「类 + 逻辑名 + 属性」查重，重复则拦下）。
                        // 注：**滑动删除本来就有**（下面的 .onDelete），不必再加。
                        // ⚠️ `.buttonStyle(.borderless)` **不能省**：
                        // SwiftUI 的 List 行里放多个 Button 时，默认样式下**不做命中区分** ——
                        // 点哪个都可能触发到另一个（现象：点"复制"却弹出"编辑"界面，
                        // 早期版本表现为"复制点了没反应"，其实是被行吞了去开编辑）。
                        Button {
                            copySource = item; editing = nil; showEditor = true
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        Button {
                            editing = item; copySource = nil; showEditor = true
                        } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                    }
                    // 放大点击目标（原来贴得较紧，单手现场操作不好点）
                    .padding(.vertical, 7)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("OBIS 清单")
            .searchable(text: $query, prompt: "搜索名称或 OBIS 代码")
            .toolbar { toolbarItems }
            .sheet(isPresented: $showEditor, onDismiss: {
                // 每次关闭都清空两个源：下次打开必定是干净状态。
                // （不清的话，上次编辑残留的 `editing` 会让下一次变成"编辑"模式。）
                editing = nil
                copySource = nil
            }) {
                ObisEditorSheet(item: $editing, template: copySource).environmentObject(store)
            }
            .sheet(isPresented: $showPresets) { presetSheet }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in handleImport(result) }
            .alert(alertTitle, isPresented: $showAlert) { Button("好", role: .cancel) {} } message: { Text(alertText) }
        }
    }

    /// 搜索过滤：名称不区分大小写包含；OBIS 代码按**归一形态**匹配
    ///（否则 `1-0:1.8.0*255` 这种写法搜不出来 —— 见 `ObisUtil.comparisonKey`）。
    private var filtered: [ObisItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.obisLibrary }
        let key = ObisUtil.comparisonKey(q)
        return store.obisLibrary.filter { item in
            if item.name.localizedCaseInsensitiveContains(q) { return true }
            return ObisUtil.comparisonKey(item.code).contains(key)
        }
    }

    // 「复制」按钮的含义是**复制一条记录**（duplicate），不是"复制到剪贴板" ——
    // 列表语境配 `doc.on.doc` 图标就是这个意思。原实现把 code+名称写进剪贴板，
    // 但拼出来的串会被 `ObisUtil.parse` 拒绝（它按空白也切段，拼上名称就成了 7 段），
    // 等于复制了也贴不回主界面。已改为打开编辑器预填。

    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showPresets = true } label: { Image(systemName: "sparkles") }
            Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            Button { editing = nil; copySource = nil; showEditor = true } label: { Image(systemName: "plus") }
        }
    }

    private var presetSheet: some View {
        NavigationStack {
            List {
                ForEach(ObisItem.presets) { p in
                    Button { store.upsert(obis: p); showPresets = false } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).foregroundStyle(.primary)
                            if !p.unit.isEmpty { Text(p.unit).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("常用 OBIS")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showPresets = false } } }
        }
    }

    /// ⚠️ 必须按**过滤后**的列表取索引 —— `offsets` 是过滤后列表的下标，
    /// 搜索状态下直接用 `store.obisLibrary[i]` 会删错条目。
    private func delete(at offsets: IndexSet) {
        let list = filtered
        for i in offsets {
            guard i >= 0 && i < list.count else { continue }
            store.remove(obisID: list[i].id)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let items = try ObisImporter.importResult(from: url)
                store.importObis(items)
                alertTitle = "导入完成"; alertText = "导入 \(items.count) 条（按 code 覆盖去重）"
            } catch {
                alertTitle = "导入失败"; alertText = error.localizedDescription
            }
        case .failure(let e):
            alertTitle = "导入失败"; alertText = e.localizedDescription
        }
        showAlert = true
    }
}

// 手动新增/编辑 OBIS。
struct ObisEditorSheet: View {
    @EnvironmentObject var store: Store
    @Binding var item: ObisItem?
    @Environment(\.dismiss) private var dismiss

    @State private var code = "0.0.1.0.0.255"
    @State private var name = ""
    @State private var unit = ""
    @State private var scaling = ""
    /// ⚠️ **空着开始**，不预填 "1"。
    /// 原来预填 "1" 且保存时静默采纳 → 新增 `0.0.42.x`（应为 42 类）会被存成 1 类、
    /// 之后读到的就是别的对象（见 docs/UI评审-核对报告.md §3.2）。
    /// 「属性」保留预填 2：它是最通用的"读值"属性，且现在有常驻标签、看得见。
    @State private var icText = ""
    @State private var attr = "2"
    @State private var data = ""
    @State private var showError = false
    @State private var errorMsg = ""
    @State private var errorTitle = ""
    var template: ObisItem? = nil

    var body: some View {
        NavigationStack {
            Form {
                // 每个字段都给**常驻标签**。
                // 原来这 6 个框只靠 placeholder 当标签，而默认值（"1" / "0.0.1.0.0.255" / "2"）
                // 一填就把 placeholder 顶掉了 → 新增时满屏是「1」「0.0.1.0.0.255」「2」三个裸行，
                // 完全看不出哪个是接口类（真机截图 IMG_9249 就是这个样子）。
                Section("基本信息") {
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("名称")
                        TextField("如 正向有功总电量", text: $name)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("接口类 IC")
                        // 键盘统一用系统默认：接口类与属性都可能填 16 进制，
                        // 限定纯数字键盘反而让用户打不出来。
                        TextField("如 1（Data）/ 3（Register）/ 42（SAP Assignment）", text: $icText)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("逻辑名 OBIS")
                        TextField("如 1.0.1.8.0.255", text: $code)
                            .font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("属性 / 方法")
                        TextField("如 2（读值）", text: $attr)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("单位（可选）")
                        TextField("如 kWh", text: $unit)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("量纲 / 倍率（可选）")
                        TextField("如 -1", text: $scaling)
                    }
                }
                Section {
                    TextField("如 11 01", text: $data)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("请求数据（可选）")
                } footer: {
                    Text("Set / Action 的固定参数（HEX）。选中本条目时会自动填入主界面的「请求数据」，"
                         + "免去每次手输。留空 = 无参数。")
                }
            }
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            // ⚠️ 这里**只能有一个 `.alert`** —— 同一视图上挂多个时 SwiftUI 只认最后一个。
            // 所以「校验失败」与「重复被拦下」共用它，靠 `errorTitle` 区分。
            .alert(errorTitle, isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMsg)
            }
        }
        .onAppear(perform: load)
    }

    /// 输入框的**常驻标签**（与主界面同一套样式）。
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func load() {
        if let item {
            // 编辑：用当前值，id 不变 → `store.save` 会原地更新
            code = item.code; name = item.name; unit = item.unit
            icText = "\(item.objectClass)"; attr = "\(item.attribute)"; scaling = item.scaling
            data = item.data
            return
        }
        if let t = template {
            // 复制：以它为初值新建一条。
            // ⚠️ **不能把 `t.id` 带过来** —— `var it = item ?? ObisItem(code: code)`
            // 会生成新 UUID，所以保存出来的一定是新条目（不会改到源条目）。
            code = t.code
            name = (t.name.isEmpty ? t.code : t.name) + " 副本"
            unit = t.unit
            icText = "\(t.objectClass)"
            attr = "\(t.attribute)"
            scaling = t.scaling
            data = t.data
        }
    }

    /// 标题：新增 / 复制 / 编辑 三种模式。
    private var titleText: String {
        if item != nil { return "编辑 OBIS" }
        return template == nil ? "添加 OBIS" : "复制 OBIS"
    }

    private func save() {
        guard ObisUtil.parse(code) != nil else {
            errorTitle = "无法保存"
            errorMsg = "OBIS 需为 6 段，如 1.0.1.8.0.255"
            showError = true
            return
        }
        // ⚠️ 接口类**必须显式给出** —— 这里刻意不再有"解析失败就沿用旧值/默认 1"的路。
        // 原来预填 "1" + 静默采纳，会让新增的 `0.0.42.x`（应为 42 类）被存成 1 类，
        // 之后按这条去读就是**另一个对象**（见 docs/UI评审-核对报告.md §3.2）。
        guard let ic = NumberInput.parse(icText) else {
            errorTitle = "无法保存"
            errorMsg = "接口类需填数字（如 1 / 3 / 42，也可写 0x1F）。"
                     + "留空不保存，避免被当成 1 类用。"
            showError = true
            return
        }
        guard let at = NumberInput.parse(attr) else {
            errorTitle = "无法保存"
            errorMsg = "属性 / 方法需填数字（如 2）"
            showError = true
            return
        }

        // 重复检查：按**身份键（类 + 逻辑名 + 属性）**。命中就**拦下不许保存**
        //（用户定的口径：不去重，但重复时直接拦下）。
        // 编辑时排除自己 —— 只改动名称/单位不该被判为重复。
        let key = ObisUtil.identityKey(code: code, objectClass: ic, attribute: at)
        let selfID = item?.id
        var conflict: ObisItem? = nil
        for e in store.obisLibrary {
            if e.identityKey != key { continue }
            if let sid = selfID, e.id == sid { continue }
            conflict = e
            break
        }
        if let other = conflict {
            errorTitle = "已存在重复条目"
            errorMsg = "清单里已有一条「类 \(other.objectClass) · \(other.code) · 属性 \(other.attribute)」："
                     + "\(other.displayName)。\n"
                     + "请改动接口类 / 逻辑名 / 属性后再保存。"
            showError = true
            return
        }

        var it = item ?? ObisItem(code: code)
        it.code = code
        it.name = name.isEmpty ? code : name
        it.unit = unit
        it.scaling = scaling
        // 只做首尾去空白 + 大写：**保留用户写的分隔空格**（如 "11 01"），
        // 免得在列表里显示成 "1101" 让人以为自己填错了。
        // 解析侧本来就容忍空格（`hlp_hexToBytes` 会跳过非 hex 字符）。
        it.data = data.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        it.objectClass = ic
        it.attribute = at
        // ⚠️ 用 `save` 而不是 `upsert`：前者只按 id 定位（编辑原地改、复制则追加），
        // 后者会按身份键覆盖 —— 复制一条时那会把**源条目改掉**。
        store.save(obis: it)
        dismiss()
    }
}