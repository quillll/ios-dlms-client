//
//  DLMSApp.swift
//  DLMS 抄表调试台：单表 TCP 调试（读/写/执行 + 报文日志 + 数据解析）+ 全局 OBIS 清单。
//  两个 Tab：调试台 / OBIS 清单。
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