//
// GlassVPNApp.swift
// GlassVPN
// 程序入口。AppDelegate 是 @MainActor 类型, 入口需同样处于主 actor 才能直接构造。
//

import AppKit

@main
enum GlassVPNApp {
    /// 保持对 delegate 的强引用: NSApplication.delegate 是弱引用
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // 纯菜单栏形态; 直接运行二进制 (无 Info.plist 的 LSUIElement) 时也保持一致
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
