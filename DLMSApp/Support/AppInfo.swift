//
//  AppInfo.swift
//  应用版本信息。
//
//  来源是「编译期注入的 Info.plist」，不是硬编码字符串 —— 免得代码里的版本号和
//  真正打出来的包对不上：
//    · project.yml 里 MARKETING_VERSION / CURRENT_PROJECT_VERSION 是唯一真源；
//    · DLMSApp/Info.plist 用 $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) 占位，
//      Xcode 编译时展开；所以运行时读 Bundle 拿到的就是真实版本。
//
import Foundation

enum AppInfo {
    /// 形如 "1.1 (2)"。取不到时回退 "?"（例如在没有 app bundle 的环境里）。
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// 界面上显示的短标签。
    static var versionBadge: String { "v" + versionString }
}
