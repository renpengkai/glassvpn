//
// Components.swift
// GlassVPN
// 通用界面组件: 格式化、连接按钮、状态标签、统计卡片、速率曲线、页面标题栏。
//

import SwiftUI

enum Format {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .binary)
    }

    static func speed(_ v: Int) -> String {
        bytes(Int64(v)) + "/s"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(Int(t), 0)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

extension VPNController.State {
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .stopping: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }
}

struct ConnectButton: View {
    @EnvironmentObject private var vpn: VPNController
    var size: CGFloat = 72

    private var connected: Bool { vpn.state == .connected }

    var body: some View {
        Button {
            Task { await vpn.toggle() }
        } label: {
            ZStack {
                if vpn.state.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: size * 0.36, weight: .semibold))
                }
            }
            .frame(width: size, height: size)
            .foregroundStyle(connected ? Color.white : Color.primary)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle(tint: connected ? Color.green.opacity(0.85) : nil)
        .disabled(vpn.state.busy)
        .help(connected ? "断开" : "连接")
        .animation(.easeInOut(duration: 0.25), value: vpn.state)
    }
}

struct StatusPill: View {
    let state: VPNController.State

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(state.color.opacity(0.14), in: Capsule())
    }
}

struct SpeedLine: View {
    let up: Int
    let down: Int

    var body: some View {
        HStack(spacing: 12) {
            Label(Format.speed(up), systemImage: "arrow.up").foregroundStyle(.orange)
            Label(Format.speed(down), systemImage: "arrow.down").foregroundStyle(.blue)
        }
        .font(.caption.monospacedDigit())
    }
}

struct LatencyText: View {
    let ms: Int?

    var body: some View {
        Group {
            if let ms {
                if ms < 0 {
                    Text("超时").foregroundStyle(.red)
                } else {
                    Text("\(ms) ms").foregroundStyle(ms < 300 ? Color.green : ms < 800 ? Color.orange : Color.red)
                }
            } else {
                Text("--").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, padding: 14)
    }
}

/// 最近 60 秒的上下行速率曲线
struct SpeedChart: View {
    let samples: [TrafficSample]

    var body: some View {
        GeometryReader { geo in
            let peak = max(samples.map { max($0.up, $0.down) }.max() ?? 0, 16 * 1024)
            ZStack {
                area(samples.map(\.down), size: geo.size, peak: peak)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                line(samples.map(\.down), size: geo.size, peak: peak)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                line(samples.map(\.up), size: geo.size, peak: peak)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }

    private func points(_ values: [Int], size: CGSize, peak: Int) -> [CGPoint] {
        let capacity = VPNController.sampleCapacity
        // 数据不足一分钟时靠右对齐, 曲线从右侧"长"出来
        let offset = capacity - values.count
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i + offset) / CGFloat(capacity - 1),
                    y: size.height * (1 - CGFloat(v) / CGFloat(peak)))
        }
    }

    private func line(_ values: [Int], size: CGSize, peak: Int) -> Path {
        Path { p in
            let pts = points(values, size: size, peak: peak)
            guard let first = pts.first else { return }
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
    }

    private func area(_ values: [Int], size: CGSize, peak: Int) -> Path {
        Path { p in
            let pts = points(values, size: size, peak: peak)
            guard let first = pts.first, let last = pts.last else { return }
            p.move(to: CGPoint(x: first.x, y: size.height))
            pts.forEach { p.addLine(to: $0) }
            p.addLine(to: CGPoint(x: last.x, y: size.height))
            p.closeSubpath()
        }
    }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.bold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Banner: View {
    let text: String
    var tint: Color = .orange
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run).glassButton()
            }
        }
        .glassCard(cornerRadius: 14, tint: tint.opacity(0.12))
    }
}
