//
// LogsView.swift
// GlassVPN
// 日志页: 每秒读取内核日志末尾并自动滚动到底部。
//

import AppKit
import Combine
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var vpn: VPNController
    @State private var text = ""
    @State private var follow = true

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "日志", subtitle: vpn.logURL.path) {
                Toggle("自动滚动", isOn: $follow).toggleStyle(.button).glassButton()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([vpn.logURL])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .glassButton()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty ? "暂无日志" : text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .glassCard(cornerRadius: 18, padding: 0)
                .padding([.horizontal, .bottom], 24)
                .onReceive(timer) { _ in
                    let latest = LogReader.tail(vpn.logURL)
                    guard latest != text else { return }
                    text = latest
                    if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .onAppear { text = LogReader.tail(vpn.logURL) }
    }
}
