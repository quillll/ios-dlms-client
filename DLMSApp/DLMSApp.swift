//
//  DLMSApp.swift
//  简易 DLMS 抄表工具：设备管理 + OBIS 管理 + TCP 抄读 + 报表导出。
//

import SwiftUI

@main
struct DLMSApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
        }
    }
}