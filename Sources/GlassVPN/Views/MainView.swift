//
// MainView.swift
// GlassVPN
// 主窗口: 侧边栏导航 (macOS 26 上自动呈现为悬浮玻璃侧栏) + 各功能页。
//

import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case dashboard, nodes, profiles, logs, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .nodes: return "节点"
        case .profiles: return "订阅"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .nodes: return "globe.asia.australia"
        case .profiles: return "tray.full"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var store: ProfileStore
    @State private var pane: Pane? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            switch pane ?? .dashboard {
            case .dashboard: DashboardView(goTo: { pane = $0 })
            case .nodes: NodesView()
            case .profiles: ProfilesView()
            case .logs: LogsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private var sidebarStatus: some View {
        HStack(spacing: 10) {
            ConnectButton(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(vpn.state.title).font(.caption.weight(.semibold))
                Text(store.current?.name ?? "未添加订阅").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
