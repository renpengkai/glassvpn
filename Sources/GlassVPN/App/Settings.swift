//
// Settings.swift
// GlassVPN
// UserDefaults 键与默认值。界面用 @AppStorage 绑定, 控制器直接读 UserDefaults。
//

import Foundation

enum Settings {
    static let mode = "mode"
    static let tun = "tun"
    static let systemProxy = "systemProxy"
    static let mixedPort = "mixedPort"
    static let apiPort = "apiPort"
    static let allowLAN = "allowLAN"
    static let logLevel = "logLevel"
    static let testURL = "testURL"
    /// GitHub 订阅与内核下载使用的前缀式加速镜像
    static let githubMirror = "githubMirror"
    static let autoConnect = "autoConnect"
    /// 远程订阅自动更新间隔 (小时), 0 表示关闭
    static let autoUpdateHours = "autoUpdateHours"
    /// 本应用是否改过系统代理; 异常退出后下次启动据此恢复
    static let proxyApplied = "proxyApplied"
    /// 用户态内核的 pid; 应用崩溃后下次启动据此清理遗留进程
    static let corePID = "corePID"

    static let defaults: [String: Any] = [
        mode: ProxyMode.rule.rawValue,
        tun: false,
        systemProxy: true,
        mixedPort: 7890,
        apiPort: 19090,
        allowLAN: false,
        logLevel: "info",
        testURL: ConfigBuilder.defaultTestURL,
        githubMirror: "",
        autoConnect: false,
        autoUpdateHours: 12,
        proxyApplied: false,
    ]
}
