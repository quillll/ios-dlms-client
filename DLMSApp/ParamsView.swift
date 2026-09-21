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
                HStack { Text("通信地址(服务器)"); Spacer(); hexDWordField($store.config.serverAddress) }
                // 地址宽度：Gurux 其实是**按数值大小自动定宽**的，所以这里选的和实际生效的
                // 可能不一致 —— 下面那行会把"编码后的真实字节"显示出来，直接对照即可。
                Picker("地址宽度", selection: $store.config.serverAddressWidth) {
                    Text("4 字节").tag(4)
                    Text("2 字节").tag(2)
                    Text("1 字节").tag(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: store.config.serverAddressEffectiveWidth == store.config.serverAddressWidth
                          ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    Text("编码后 \(store.config.serverAddressWireHex)（实际 \(store.config.serverAddressEffectiveWidth) 字节）"
                         + (store.config.serverAddressEffectiveWidth == store.config.serverAddressWidth
                            ? " · 末字节 bit0=1 表示地址域结束"
                            : " · 与所选 \(store.config.serverAddressWidth) 字节不符"))
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(store.config.serverAddressEffectiveWidth == store.config.serverAddressWidth
                                 ? Color.secondary : Color.orange)
            } else {
                HStack { Text("源地址(WR)"); Spacer(); hexField($store.config.wrapperSource) }
                HStack { Text("目标地址(WR)"); Spacer(); hexField($store.config.wrapperTarget) }
            }
        } header: {
            Text("地址 · 封装")
        } footer: {
            Text(store.config.framing == .hdlc
                 ? "HDLC：客户端=预设(仅「自定义」可手输，1 字节)；通信地址为逻辑+物理合成，4/2/1 字节，不省前导0"
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

    /// 通信地址(服务器)：固定 8 位 hex，前导 0 补齐（如 00013FFF），支持 4/2/1 字节。
    private func hexDWordField(_ binding: Binding<UInt32>) -> some View {
        TextField("00000000", text: Binding(
            get: { String(format: "%08X", binding.wrappedValue) },
            set: { n in
                let clean = String(n.filter { !$0.isWhitespace }).uppercased()
                if let v = UInt32(clean, radix: 16) { binding.wrappedValue = v }
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