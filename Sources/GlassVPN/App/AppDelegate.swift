//
// AppDelegate.swift
// GlassVPN
// 菜单栏图标、弹出面板、主窗口, 以及启动恢复 / 退出清理。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private lazy var core = CoreManager()
    private lazy var store = ProfileStore()
    private lazy var vpn = VPNController(store: store, core: core)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Settings.defaults)
        vpn.recover()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }

        let host = NSHostingController(rootView: PopoverView(openMain: { [weak self] in self?.showMainWindow() })
            .environmentObject(vpn).environmentObject(store).environmentObject(core))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        vpn.$state.sink { [weak self] state in self?.refreshIcon(state) }.store(in: &cancellables)

        // 定时检查过期订阅; 实际是否更新由 autoUpdateHours 决定
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.updateAll(staleOnly: true) }
        }
        Task {
            await store.updateAll(staleOnly: true)
            if UserDefaults.standard.bool(forKey: Settings.autoConnect) { await vpn.connect() }
        }

        // 首次使用 (无内核或无订阅) 直接打开主窗口引导
        if !core.isInstalled || store.profiles.isEmpty { showMainWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        vpn.shutdownSync()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 菜单栏应用默认不是活跃应用, 需激活后 transient 弹窗才能在点击外部时自动关闭
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMainWindow() {
        popover.performClose(nil)
        if window == nil {
            let host = NSHostingController(rootView: MainView()
                .environmentObject(vpn).environmentObject(store).environmentObject(core))
            let w = NSWindow(contentViewController: host)
            w.title = "GlassVPN"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 980, height: 640))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // 主窗口打开期间显示 Dock 图标, 便于切换; 关闭后回到纯菜单栏形态
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func refreshIcon(_ state: VPNController.State) {
        let symbol: String
        switch state {
        case .connected, .connecting, .stopping: symbol = "shield.lefthalf.filled"
        case .failed: symbol = "exclamationmark.shield"
        case .idle: symbol = "shield"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GlassVPN")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        // 模板图片由系统按浅色/深色/液态玻璃菜单栏自动着色
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = state.busy
    }
}
