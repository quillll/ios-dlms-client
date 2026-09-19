//
//  RootTabView.swift
//  两个 Tab：调试台 · OBIS 清单（去掉设备/抄读/报表，回归单表调试台形态）
//

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            MainView()
                .tabItem { Label("调试台", systemImage: "terminal.fill") }
            ObisLibraryView()
                .tabItem { Label("OBIS", systemImage: "list.bullet.rectangle.portrait") }
        }
    }
}