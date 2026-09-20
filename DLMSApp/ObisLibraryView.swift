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

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.obisLibrary) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName).font(.body)
                            Text(item.unit.isEmpty ? item.code : "\(item.code) · \(item.unit)")
                                .font(.caption).monospaced().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { editing = item; showEditor = true } label: { Image(systemName: "pencil") }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("OBIS 清单")
            .toolbar { toolbarItems }
            .sheet(isPresented: $showEditor) { ObisEditorSheet(item: $editing).environmentObject(store) }
            .sheet(isPresented: $showPresets) { presetSheet }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in handleImport(result) }
            .alert(alertTitle, isPresented: $showAlert) { Button("好", role: .cancel) {} } message: { Text(alertText) }
        }
    }

    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showPresets = true } label: { Image(systemName: "sparkles") }
            Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            Button { editing = nil; showEditor = true } label: { Image(systemName: "plus") }
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

    private func delete(at offsets: IndexSet) {
        for i in offsets { store.remove(obisID: store.obisLibrary[i].id) }
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

    @State private var code = "1.0.1.8.0.255"
    @State private var name = ""
    @State private var unit = ""
    @State private var scaling = ""
    @State private var icText = "3"
    @State private var attr = "2"
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    // 键盘统一用系统默认：接口类与属性都可能填 16 进制，
                    // 限定纯数字键盘反而让用户打不出来。
                    TextField("接口类(IC，10/16进制，如 3 / 0x1F)", text: $icText)
                    TextField("逻辑名 OBIS（如 1.0.1.8.0.255）", text: $code)
                        .font(.system(.body, design: .monospaced))
                    TextField("属性/方法", text: $attr)
                    TextField("单位（可选）", text: $unit)
                    TextField("量纲/倍率（可选）", text: $scaling)
                }
            }
            .navigationTitle(item == nil ? "添加 OBIS" : "编辑 OBIS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .alert("无法保存", isPresented: $showError) { Button("好", role: .cancel) {} } message: {
                Text("OBIS 需为 6 段，如 1.0.1.8.0.255")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let item else { return }
        code = item.code; name = item.name; unit = item.unit
        icText = "\(item.objectClass)"; attr = "\(item.attribute)"; scaling = item.scaling
    }

    private func save() {
        guard ObisUtil.parse(code) != nil else { showError = true; return }
        var it = item ?? ObisItem(code: code)
        it.code = code
        it.name = name.isEmpty ? code : name
        it.unit = unit
        it.scaling = scaling
        if let ic = NumberInput.parse(icText) { it.objectClass = ic }
        // 属性用同一套 10/16 进制识别，与「类」保持一致。
        // （键盘限制取消后用户可能填 0x10，若还用 Int() 会解析失败并静默回落到 2。）
        it.attribute = NumberInput.parse(attr) ?? 2
        store.upsert(obis: it)
        dismiss()
    }
}