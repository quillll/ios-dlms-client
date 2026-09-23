//
//  ParamsView.swift
//  连接参数页：传输 / 地址·封装 / 认证 / 信息加密 / 密钥与SystemTitle（均独立）。
//

import SwiftUI

struct ParamsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                transportSection
                addressSection
                authSection
                securitySection
                keysSection
                toggleSection
            }
            .navigationTitle("连接参数")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onDisappear { store.persist() }
        }
    }

    private var transportSection: some View {
        Section("传输") {
            TextField("IP", text: $store.config.ip)
                .keyboardType(.numbersAndPunctuation)
            HStack {
                Text("端口")
                Spacer()
                TextField("4059", value: $store.config.port, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            // 最近连接：点一下就回填上面的 IP + 端口（只在连接成功时才会被记入）。
            if !store.config.recentEndpoints.isEmpty {
                Menu {
                    ForEach(store.config.recentEndpoints, id: \.self) { ep in
                        Button(ep) {
                            if let (host, prt) = ConnectionConfig.splitEndpoint(ep) {
                                store.config.ip = host
                                store.config.port = prt
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("最近连接")
                        Spacer()
                        Text(store.config.recentEndpoints.first ?? "")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Text("接收超时(ms)")
                Spacer()
                TextField("3000", value: $store.config.recvTimeoutMs, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
        }
    }

    private var addressSection: some View {
        Section {
            Picker("封装协议", selection: $store.config.framing) {
                ForEach(Framing.allCases) { Text($0.title).tag($0) }
            }
            if store.config.framing == .hdlc {
                Picker("客户端地址", selection: $store.config.clientPreset) {
                    ForEach(ClientPreset.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: store.config.clientPreset) { preset in
                    if let v = preset.value { store.config.clientAddress = v }
                }
                if store.config.clientPreset == .custom {
                    HStack { Text("客户端(值·HEX)"); Spacer(); hexByteField($store.config.clientAddress) }
                } else {
                    HStack {
                        Text("客户端(值)")
                        Spacer()
                        Text(String(format: "%02X", store.config.clientAddress & 0xFF))
                            .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                HStack { Text("通信地址(服务器)"); Spacer(); serverAddressField }
                serverAddressHint
            } else {
                HStack { Text("源地址(WR)"); Spacer(); hexField($store.config.wrapperSource) }
                HStack { Text("目标地址(WR)"); Spacer(); hexField($store.config.wrapperTarget) }
            }
        } header: {
            Text("地址 · 封装")
        } footer: {
            Text(store.config.framing == .hdlc
                 ? "HDLC：客户端=预设(仅「自定义」可手输，1 字节)；通信地址按「输入字节数」定宽 —— 1 字节=仅逻辑地址，2 字节=逻辑/物理各 1，4 字节=各 2（如 00013FFF = 逻辑 0001 + 物理 3FFF），其它字节数非法"
                 : "Wrapper：源/目标直接写入（默认 0001/0001）")
        }
    }

    private var authSection: some View {
        Section("认证（独立项）") {
            Picker("认证方式", selection: $store.config.auth) {
                ForEach(Auth.allCases) { a in
                    Text(a.isSupportedP1 ? a.title : "\(a.title) (暂不支持)").tag(a)
                }
            }
        }
    }

    private var securitySection: some View {
        Section("信息加密（独立项）") {
            Picker("信息加密", selection: $store.config.security) {
                ForEach(SecurityMode.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var keysSection: some View {
        Section {
            HStack {
                Text("LLS 密码")
                Spacer()
                TextField("00000000", text: $store.config.passwordHex)
                    .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced))
            }
            KeyFieldRow(title: "GUAK · 全局单播认证密钥",
                        note: "→ authenticationKey",
                        bytes: 16,
                        text: $store.config.guakHex)
            KeyFieldRow(title: "GUEK · 全局单播加密密钥",
                        note: "→ blockCipherKey",
                        bytes: 16,
                        text: $store.config.guekHex)
            KeyFieldRow(title: "客户端 SystemTitle",
                        note: "服务器由 AARE 回填",
                        bytes: 8,
                        text: $store.config.clientSystemTitleHex)
        } header: {
            Text("密钥 · SystemTitle（独立，常显）")
        } footer: {
            Text("GUAK / GUEK 各 16 字节（32 位 hex），默认全 0；留空同样按全 0 处理。"
                 + "认证＝HLS-GMAC 用 GUAK，信息加密用 GUEK。"
                 + "客户端 SystemTitle 8 字节，留空按默认 \(ConnectionConfig.defaultClientSystemTitle)。"
                 + "MK / GBEK 暂不提供。")
        }
    }

    private var toggleSection: some View {
        Section {
            Toggle("解析使能", isOn: $store.config.parseEnabled)
        }
    }

    /// 通信地址(服务器) 输入框：**保留原始输入**（宽度由字节数决定，不能用 UInt32 存）。
    /// 只做归一化（去空白/分隔符、转大写），非法字符原样留着让下面的提示标红。
    private var serverAddressField: some View {
        TextField("00013FFF", text: Binding(
            get: { store.config.serverAddressHex },
            set: { store.config.serverAddressHex = HexUtil.normalize($0) }
        ))
        .keyboardType(.asciiCapable).textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced))
    }

    /// 地址合法性与编码预览。
    ///
    /// 规则（宽度 = 输入字节数，不再是单独的选择器）：
    ///   1 字节 → 整串是**逻辑**地址（无物理地址）
    ///   2 字节 → 逻辑 1 字节 + 物理 1 字节
    ///   4 字节 → 逻辑 2 字节 + 物理 2 字节
    ///   其它（如 3 字节）→ 非法，标红
    private var serverAddressHint: some View {
        let parts = serverAddressHintParts(store.config)
        return HStack(alignment: .top, spacing: 4) {
            Image(systemName: parts.icon)
            Text(parts.text)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(parts.color)
    }

    private func serverAddressHintParts(_ c: ConnectionConfig) -> (icon: String, color: Color, text: String) {
        let n = c.serverAddressNormalized
        if n.isEmpty {
            return ("exclamationmark.triangle.fill", .orange,
                    "如 00013FFF（4 字节 = 逻辑 00 01 + 物理 3F FF）")
        }
        let bytes = c.serverAddressBytes
        if bytes == 0 {
            return ("exclamationmark.triangle.fill", .red,
                    "HEX 需偶数位且仅含 0-9 A-F（当前 \(n.count) 位）")
        }
        if !c.serverAddressIsValid {
            return ("xmark.octagon.fill", .red,
                    "地址只能 1 / 2 / 4 字节，当前 \(bytes) 字节")
        }
        let width = bytes == 2 ? "%02X" : "%04X"
        let split = bytes == 1
            ? "仅逻辑 \(String(format: "%02X", c.serverLogical))（无物理地址）"
            : "逻辑 \(String(format: width, c.serverLogical)) + 物理 \(String(format: width, c.serverPhysical))"
        let matched = c.serverAddressWidthMatched
        let tail = matched
            ? " · 末字节 bit0=1 表示地址域结束"
            : " · 实际按 \(c.serverAddressEffectiveWidth) 字节发（Gurux 按值定宽）"
        return (matched ? "checkmark.circle" : "exclamationmark.triangle.fill",
                matched ? .secondary : .orange,
                "编码后 \(c.serverAddressWireHex)（\(c.serverAddressEffectiveWidth) 字节）· \(split)\(tail)")
    }

    private func hexField(_ binding: Binding<UInt32>) -> some View {
        TextField("", text: Binding(
            get: { String(format: "%04X", binding.wrappedValue) },
            set: { n in
                let clean = String(n.filter { !$0.isWhitespace }).uppercased()
                if let v = UInt32(clean, radix: 16) { binding.wrappedValue = v }
            }
        ))
        .keyboardType(.asciiCapable).multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))
    }

    /// 1 字节客户端地址：占 2 位 hex，输入可不带前导 0（1 → 0x01），越界只取低字节。
    private func hexByteField(_ binding: Binding<UInt32>) -> some View {
        TextField("xx", text: Binding(
            get: { String(format: "%02X", binding.wrappedValue & 0xFF) },
            set: { n in
                let clean = String(n.filter { !$0.isWhitespace }).uppercased()
                if let v = UInt32(clean, radix: 16) { binding.wrappedValue = v & 0xFF }
            }
        ))
        .keyboardType(.asciiCapable).textInputAutocapitalization(.characters)
        .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced))
    }
}

// MARK: - 单条密钥输入行
//
// 32 位 hex 塞不进「标签 + 右对齐输入框」的一行（手机上会被挤没），
// 所以标签另起一行、输入框独占整宽，并在下面给字节数/合法性提示。
private struct KeyFieldRow: View {
    let title: String
    let note: String
    let bytes: Int
    @Binding var text: String

    private var normalized: String { HexUtil.normalize(text) }
    private var ok: Bool { HexUtil.isValid(text, byteCount: bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline)
            TextField(String(repeating: "0", count: bytes * 2), text: $text)
                .font(.system(.footnote, design: .monospaced))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 5) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text(ok ? "\(bytes) 字节" : "需 \(bytes * 2) 位 hex（当前 \(normalized.count)）")
                Spacer()
                Text(note).foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(ok ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }
}