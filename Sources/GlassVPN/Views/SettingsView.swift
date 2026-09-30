//
// SettingsView.swift
// GlassVPN
// 设置页: 连接参数、订阅更新、sing-box 内核、TUN 特权组件、开机启动。
//

import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var core: CoreManager

    @AppStorage(Settings.systemProxy) private var systemProxy = true
    @AppStorage(Settings.tun) private var tun = false
    @AppStorage(Settings.mixedPort) private var mixedPort = 7890
    @AppStorage(Settings.apiPort) private var apiPort = 19090
    @AppStorage(Settings.allowLAN) private var allowLAN = false
    @AppStorage(Settings.logLevel) private var logLevel = "info"
    @AppStorage(Settings.testURL) private var testURL = ConfigBuilder.defaultTestURL
    @AppStorage(Settings.githubMirror) private var githubMirror = ""
    @AppStorage(Settings.autoConnect) private var autoConnect = false
    @AppStorage(Settings.autoUpdateHours) private var autoUpdateHours = 12

    @State private var helperReady = false
    @State private var helperMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "设置", subtitle: "端口、TUN 等连接参数在重新连接后生效") {
                if vpn.state == .connected {
                    Button("重新连接") { Task { await vpn.reconnect() } }.glassButton(prominent: true)
                }
            }
            Form {
                connectionSection
                subscriptionSection
                coreSection
                helperSection
                generalSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task { await refreshHelper() }
    }

    // MARK: - 分区

    private var connectionSection: some View {
        Section("连接") {
            Toggle("设置为系统代理", isOn: $systemProxy)
            Toggle("TUN 模式（接管所有应用流量，需要特权组件）", isOn: $tun)
                .disabled(!helperReady && !tun)
            TextField("本地代理端口 (HTTP + SOCKS5)", value: $mixedPort, format: .number.grouping(.never))
            Toggle("允许局域网设备连接", isOn: $allowLAN)
            TextField("控制接口端口", value: $apiPort, format: .number.grouping(.never))
            Picker("日志等级", selection: $logLevel) {
                ForEach(["trace", "debug", "info", "warn", "error"], id: \.self) { Text($0) }
            }
            TextField("测速地址", text: $testURL)
        }
    }

    private var subscriptionSection: some View {
        Section("订阅") {
            Stepper(value: $autoUpdateHours, in: 0...168, step: 6) {
                Text(autoUpdateHours == 0 ? "自动更新：关闭" : "自动更新：每 \(autoUpdateHours) 小时")
            }
            TextField("GitHub 加速镜像", text: $githubMirror, prompt: Text("如 https://ghfast.top/ ，留空直连"))
            Text("镜像以前缀方式拼接在 GitHub 地址前，用于公开仓库订阅与内核下载。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var coreSection: some View {
        Section("sing-box 内核") {
            LabeledContent("当前版本") {
                if let v = core.version {
                    Text(v + (core.isOutdated ? "（过旧，需要 1.12+）" : ""))
                        .foregroundStyle(core.isOutdated ? Color.red : Color.primary)
                } else {
                    Text("未安装").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(core.isInstalled ? "更新到最新版" : "下载内核") {
                    Task { await core.download(mirror: githubMirror) }
                }
                .glassButton(prominent: !core.isInstalled)
                Button("导入本地文件…") { importCore() }.glassButton()
                if core.isInstalled {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.core])
                    }
                    .glassButton()
                }
                if core.busy { ProgressView().controlSize(.small) }
            }
            if let message = core.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("内核不随应用打包以保持安装包小巧，从 SagerNet/sing-box 官方 GitHub Releases 下载。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var helperSection: some View {
        Section("特权组件") {
            LabeledContent("状态") {
                Text(helperReady ? "已安装" : "未安装").foregroundStyle(helperReady ? Color.green : Color.secondary)
            }
            if helperReady, let root = core.rootVersion, let user = core.version, root != user {
                Text("组件内的内核（\(root)）与当前内核（\(user)）不一致，重新安装即可同步。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(helperReady ? "重新安装" : "安装") { installHelper() }
                    .glassButton(prominent: !helperReady)
                    .disabled(!core.isInstalled)
                if PrivilegedHelper.isInstalled {
                    Button("卸载", role: .destructive) { uninstallHelper() }.glassButton()
                }
            }
            if let helperMessage {
                Text(helperMessage).font(.caption).foregroundStyle(.red)
            }
            Text("TUN 模式需要以 root 运行内核；部分系统上设置系统代理也需要管理员权限。组件安装在 /Library/PrivilegedHelperTools，只接受启停内核与设置系统代理几个固定命令，安装时会请求一次管理员密码。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("通用") {
            Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            Toggle("启动后自动连接", isOn: $autoConnect)
            LabeledContent("版本") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            }
            Link("界面与功能参考 KaringX/karing", destination: URL(string: "https://github.com/KaringX/karing")!)
        }
    }

    // MARK: - 操作

    private func refreshHelper() async {
        helperReady = await Task.detached { PrivilegedHelper.isReady }.value
        if !helperReady && tun { tun = false }
    }

    private func installHelper() {
        helperMessage = nil
        // NSAppleScript 需在主线程执行, 授权对话框期间阻塞主线程属预期行为
        if let error = PrivilegedHelper.install(core: Paths.core.path) { helperMessage = error }
        Task {
            await refreshHelper()
            core.refresh()
        }
    }

    private func uninstallHelper() {
        helperMessage = nil
        Task {
            if tun, vpn.state == .connected { await vpn.disconnect() }
            if let error = PrivilegedHelper.uninstall() { helperMessage = error }
            tun = false
            await refreshHelper()
            core.refresh()
        }
    }

    private func importCore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "选择 sing-box 可执行文件或官方 darwin 版 .tar.gz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await core.importLocal(url) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            helperMessage = "登录时启动设置失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
