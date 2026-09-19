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
                HStack { Text("客户端(值)"); Spacer(); hexField($store.config.clientAddress) }
                HStack { Text("通信地址(服务器)"); Spacer(); hexField($store.config.serverAddress) }
            } else {
                HStack { Text("源地址(WR)"); Spacer(); hexField($store.config.wrapperSource) }
                HStack { Text("目标地址(WR)"); Spacer(); hexField($store.config.wrapperTarget) }
            }
        } header: {
            Text("地址 · 封装")
        } footer: {
            Text(store.config.framing == .hdlc
                 ? "HDLC：客户端来自预设，通信地址为逻辑+物理合成值"
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
            HStack { Text("LLS 密码"); Spacer(); TextField("00000000", text: $store.config.passwordHex)
                .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced)) }
            HStack { Text("aKEK (EM 主密钥)"); Spacer(); TextField("32位hex", text: $store.config.akekHex)
                .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced)) }
            HStack { Text("客户端 SystemTitle"); Spacer(); TextField("8字节hex", text: $store.config.clientSystemTitleHex)
                .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced)) }
        } header: {
            Text("密钥 · SystemTitle（独立，常显）")
        } footer: {
            Text("认证=HLS 时，客户端 SystemTitle 必须在建链前设置（8 字节，16 位 hex）。服务器 SystemTitle 由 AARE 自动回填。")
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
}