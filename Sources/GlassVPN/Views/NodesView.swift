//
// NodesView.swift
// GlassVPN
// 节点页: 卡片网格、搜索、延迟测试与排序。
//

import SwiftUI

struct NodesView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var store: ProfileStore
    @State private var query = ""
    @State private var sortByLatency = false

    private var selected: String { store.selectedTag ?? "auto" }

    private var nodes: [ProxyNode] {
        var list = store.nodes
        if !query.isEmpty {
            list = list.filter { $0.tag.localizedCaseInsensitiveContains(query) || $0.typeLabel.localizedCaseInsensitiveContains(query) }
        }
        if sortByLatency {
            list.sort { rank($0) < rank($1) }
        }
        return list
    }

    /// 未测排在超时之前, 超时排最后
    private func rank(_ n: ProxyNode) -> Int {
        guard let ms = store.latency[n.tag] else { return Int.max - 1 }
        return ms < 0 ? Int.max : ms
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "节点", subtitle: "\(store.nodes.count) 个节点 · \(store.current?.name ?? "未选择订阅")") {
                TextField("搜索节点", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Toggle("按延迟排序", isOn: $sortByLatency)
                    .toggleStyle(.button)
                    .glassButton()
                Button {
                    Task { await vpn.testLatency() }
                } label: {
                    Label(vpn.testing ? "测速中…" : "测速", systemImage: "bolt.horizontal.fill")
                }
                .glassButton(prominent: true)
                .disabled(vpn.testing || store.nodes.isEmpty)
                .help(vpn.state == .connected ? "通过节点请求测试地址" : "未连接时测 TCP 握手延迟，UDP 协议节点跳过")
            }

            if store.nodes.isEmpty {
                Spacer()
                Text("当前没有节点，请先在「订阅」中添加").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        NodeCard(title: "自动选择",
                                 subtitle: vpn.autoNow ?? "按延迟自动切换最快节点",
                                 badge: "AUTO", latency: nil, selected: selected == "auto") {
                            vpn.select("auto")
                        }
                        ForEach(nodes) { n in
                            NodeCard(title: n.tag, subtitle: "\(n.server):\(n.port)", badge: n.typeLabel,
                                     latency: store.latency[n.tag], selected: selected == n.tag) {
                                vpn.select(n.tag)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}

struct NodeCard: View {
    let title: String
    let subtitle: String
    let badge: String
    let latency: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    LatencyText(ms: latency)
                }
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 14, tint: selected ? Color.accentColor.opacity(0.18) : nil)
    }
}
