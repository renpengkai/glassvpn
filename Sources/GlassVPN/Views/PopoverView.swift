//
// PopoverView.swift
// GlassVPN
// 菜单栏弹窗: 一键连接、模式、配置与节点快速切换。
//

import AppKit
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var store: ProfileStore
    @AppStorage(Settings.mode) private var mode = ProxyMode.rule.rawValue
    @AppStorage(Settings.tun) private var tun = false
    @AppStorage(Settings.systemProxy) private var systemProxy = true

    let openMain: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("GlassVPN").font(.headline)
                Spacer()
                StatusPill(state: vpn.state)
            }

            GlassStack(spacing: 10) {
                HStack(spacing: 14) {
                    ConnectButton(size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vpn.state.title).font(.title3.weight(.semibold))
                        if case .failed(let reason) = vpn.state {
                            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(3)
                        } else {
                            SpeedLine(up: vpn.up, down: vpn.down)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    Picker("模式", selection: modeBinding) {
                        ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    profileMenu
                    nodeMenu

                    HStack {
                        Toggle("系统代理", isOn: reconnecting($systemProxy))
                        Spacer()
                        Toggle("TUN", isOn: reconnecting($tun))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .glassCard()
            }

            HStack {
                Button("打开主界面", action: openMain).glassButton()
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.glassButton()
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(get: { ProxyMode(stored: mode) }, set: { vpn.setMode($0) })
    }

    /// 端口、入站类型变化只能重启内核生效
    private func reconnecting(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            Task { await vpn.reconnect() }
        })
    }

    private var profileMenu: some View {
        Menu {
            ForEach(store.profiles) { p in
                Button {
                    vpn.switchProfile(p.id)
                } label: {
                    if p.id == store.current?.id {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            Label(store.current?.name ?? "未添加订阅", systemImage: "tray.full")
        }
        .menuStyle(.borderlessButton)
        .disabled(store.profiles.isEmpty)
    }

    private var nodeMenu: some View {
        let selected = store.selectedTag ?? "auto"
        return Menu {
            Button {
                vpn.select("auto")
            } label: {
                if selected == "auto" { Label("自动选择", systemImage: "checkmark") } else { Text("自动选择") }
            }
            Divider()
            ForEach(store.nodes) { n in
                Button {
                    vpn.select(n.tag)
                } label: {
                    if selected == n.tag { Label(n.tag, systemImage: "checkmark") } else { Text(n.tag) }
                }
            }
        } label: {
            Label(nodeTitle(selected), systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .disabled(store.nodes.isEmpty)
    }

    private func nodeTitle(_ selected: String) -> String {
        guard selected == "auto" else { return selected }
        return vpn.autoNow.map { "自动选择 · \($0)" } ?? "自动选择"
    }
}
