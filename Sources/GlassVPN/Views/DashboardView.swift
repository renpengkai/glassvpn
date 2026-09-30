//
// DashboardView.swift
// GlassVPN
// 概览页: 连接开关、实时速率、流量统计与订阅用量。
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var core: CoreManager
    @AppStorage(Settings.mode) private var mode = ProxyMode.rule.rawValue
    @AppStorage(Settings.tun) private var tun = false

    let goTo: (Pane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "概览", subtitle: tun ? "TUN 模式 · 接管全部流量" : "系统代理模式")
                    .padding(.horizontal, -24)

                if !core.isInstalled {
                    Banner(text: "尚未安装 sing-box 内核，请在设置中下载或导入。",
                           action: ("前往设置", { goTo(.settings) }))
                } else if store.profiles.isEmpty {
                    Banner(text: "还没有订阅，添加 Clash / V2ray / Sing-box / Shadowsocks / GitHub 订阅后即可连接。",
                           tint: .blue, action: ("添加订阅", { goTo(.profiles) }))
                }

                GlassStack(spacing: 14) {
                    hero
                    stats
                    chart
                    if let usage = store.current?.usage, usage.total > 0 {
                        usageCard(usage)
                    }
                }
            }
            .padding(24)
        }
    }

    private var hero: some View {
        HStack(spacing: 22) {
            ConnectButton(size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(vpn.state.title).font(.largeTitle.weight(.bold))
                if case .failed(let reason) = vpn.state {
                    Text(reason).font(.callout).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                } else {
                    Text(nodeSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Picker("模式", selection: Binding(get: { ProxyMode(stored: mode) }, set: { vpn.setMode($0) })) {
                    ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Spacer(minLength: 0)
        }
        .glassCard(cornerRadius: 24, padding: 22)
    }

    private var nodeSummary: String {
        let profile = store.current?.name ?? "未选择订阅"
        let selected = store.selectedTag ?? "auto"
        let node = selected == "auto" ? "自动选择" + (vpn.autoNow.map { " · \($0)" } ?? "") : selected
        return "\(profile) · \(node)"
    }

    private var stats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatCard(title: "上传", value: Format.speed(vpn.up), symbol: "arrow.up", tint: .orange)
            StatCard(title: "下载", value: Format.speed(vpn.down), symbol: "arrow.down", tint: .blue)
            StatCard(title: "本次流量", value: Format.bytes(vpn.totalUp + vpn.totalDown), symbol: "chart.bar.fill", tint: .purple)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatCard(title: "连接时长",
                         value: vpn.connectedAt.map { Format.duration(context.date.timeIntervalSince($0)) } ?? "--:--:--",
                         symbol: "clock", tint: .green)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时速率").font(.headline)
                Spacer()
                SpeedLine(up: vpn.up, down: vpn.down)
            }
            SpeedChart(samples: vpn.samples).frame(height: 140)
        }
        .glassCard(cornerRadius: 20, padding: 16)
    }

    private func usageCard(_ usage: Usage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("订阅流量").font(.headline)
                Spacer()
                if let expire = usage.expire {
                    Text("到期 \(expire.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: usage.fraction)
                .tint(usage.fraction > 0.9 ? .red : .accentColor)
            Text("已用 \(Format.bytes(usage.used)) / 共 \(Format.bytes(usage.total))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .glassCard(cornerRadius: 20, padding: 16)
    }
}
