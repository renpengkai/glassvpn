//
// ProfilesView.swift
// GlassVPN
// 订阅页: 列表、切换、更新、重命名、删除, 以及添加订阅面板。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfilesView: View {
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var store: ProfileStore
    @State private var showAdd = false
    @State private var renaming: Profile?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "订阅", subtitle: "\(store.profiles.count) 个配置 · 点击切换") {
                Button {
                    Task { await store.updateAll() }
                } label: {
                    Label("全部更新", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .disabled(!store.updating.isEmpty)
                Button {
                    showAdd = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .glassButton(prominent: true)
            }

            ScrollView {
                VStack(spacing: 12) {
                    if let message = store.message {
                        Banner(text: message, tint: .red, action: ("知道了", { store.message = nil }))
                    }
                    if store.profiles.isEmpty {
                        emptyState
                    } else {
                        GlassStack(spacing: 12) {
                            ForEach(store.profiles) { p in
                                ProfileRow(profile: p, isCurrent: store.current?.id == p.id,
                                           updating: store.updating.contains(p.id),
                                           onSelect: { vpn.switchProfile(p.id) },
                                           onUpdate: { Task { await store.update(p.id) } },
                                           onRename: { newName = p.name; renaming = p },
                                           onDelete: { store.remove(p.id) })
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProfileSheet().environmentObject(store)
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let p = renaming { store.rename(p.id, to: newName) }
                renaming = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("还没有订阅").font(.title3.weight(.semibold))
            Text("支持 Clash、V2ray/V2fly、Sing-box、Shadowsocks、Base64 订阅，以及 GitHub 上的配置文件")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("添加订阅") { showAdd = true }.glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct ProfileRow: View {
    let profile: Profile
    let isCurrent: Bool
    let updating: Bool
    let onSelect: () -> Void
    let onUpdate: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var isGitHub: Bool {
        SubscriptionFetcher.isGitHub(URL(string: profile.url)?.host)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Text(profile.kind == .local ? "本地" : isGitHub ? "GitHub" : "订阅")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if profile.kind == .remote {
                    Text(profile.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 12) {
                    Label("\(profile.nodes.count) 个节点", systemImage: "server.rack")
                    if let t = profile.updatedAt {
                        Label(t.formatted(.relative(presentation: .named)), systemImage: "clock")
                    }
                    if let expire = profile.usage?.expire {
                        Label("到期 \(expire.formatted(date: .numeric, time: .omitted))", systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let u = profile.usage, u.total > 0 {
                    ProgressView(value: u.fraction).tint(u.fraction > 0.9 ? .red : .accentColor)
                    Text("\(Format.bytes(u.used)) / \(Format.bytes(u.total))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if updating {
                ProgressView().controlSize(.small)
            }
            Menu {
                if profile.kind == .remote {
                    Button("更新", action: onUpdate)
                    Button("复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(profile.url, forType: .string)
                    }
                }
                Button("重命名", action: onRename)
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .glassCard(cornerRadius: 16, padding: 14, tint: isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }
}

struct AddProfileSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case url = "订阅链接"
        case github = "GitHub"
        case text = "粘贴内容"
        case file = "本地文件"

        var id: Self { self }
    }

    static let agents = ["clash.meta", "mihomo", "sing-box", "v2rayN/7.0", "Shadowrocket"]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ProfileStore
    @State private var source: Source = .url
    @State private var name = ""
    @State private var url = ""
    @State private var userAgent = "clash.meta"
    @State private var token = ""
    @State private var text = ""
    @State private var busy = false
    @State private var failure: String?

    private var canSubmit: Bool {
        switch source {
        case .url, .github: return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加配置").font(.title2.weight(.semibold))
            Picker("来源", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                TextField("名称", text: $name, prompt: Text("可选，默认取服务端提供的名称"))
                switch source {
                case .url:
                    TextField("地址", text: $url, prompt: Text("https://…"))
                    Picker("User-Agent", selection: $userAgent) {
                        ForEach(Self.agents, id: \.self) { Text($0) }
                    }
                    Text("自动识别 Clash / V2ray / Sing-box / Shadowsocks(SIP008) / Base64 链接列表。多数机场按 User-Agent 返回格式，clash.meta 协议最全。")
                        .font(.caption).foregroundStyle(.secondary)
                case .github:
                    TextField("文件地址", text: $url, prompt: Text("https://github.com/用户/仓库/blob/分支/config.yaml"))
                    SecureField("访问令牌", text: $token, prompt: Text("私有仓库需要，公开仓库留空"))
                    Text("支持 github.com 文件页、raw.githubusercontent.com 与 Gist。公开仓库可在「设置」中配置加速镜像；带令牌时始终直连 GitHub。")
                        .font(.caption).foregroundStyle(.secondary)
                case .text:
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 170)
                    Text("可粘贴分享链接（每行一个）、Clash YAML、sing-box / V2ray JSON 或 Base64 内容。")
                        .font(.caption).foregroundStyle(.secondary)
                case .file:
                    Text("选择 .yaml / .json / .txt 配置文件导入为本地配置。").font(.callout)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "添加中…" : source == .file ? "选择文件…" : "添加") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(busy || !canSubmit)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func submit() {
        failure = nil
        switch source {
        case .url, .github:
            busy = true
            let isGitHub = source == .github
            Task {
                do {
                    try await store.addRemote(name: name, url: url,
                                              userAgent: isGitHub ? "" : userAgent,
                                              token: isGitHub ? token : "")
                    dismiss()
                } catch {
                    failure = error.localizedDescription
                }
                busy = false
            }
        case .text:
            do {
                try store.addLocal(name: name, text: text)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        case .file:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.yaml, .json, .plainText, .data]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let file = panel.url else { return }
            do {
                try store.importFile(file)
                if !name.trimmingCharacters(in: .whitespaces).isEmpty, let last = store.profiles.last {
                    store.rename(last.id, to: name)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
