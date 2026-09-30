//
// ProfileStore.swift
// GlassVPN
// 订阅配置的增删改、刷新与持久化; 每个配置记住自己选中的节点。
//

import Foundation

@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var selectedID: UUID?
    /// 配置 id → 选中的节点 tag ("auto" 表示自动选择)
    @Published private(set) var selectedNodes: [String: String] = [:]
    @Published private(set) var updating: Set<UUID> = []
    /// 当前配置下各节点延迟, -1 表示超时
    @Published var latency: [String: Int] = [:]
    @Published var message: String?

    private struct Snapshot: Codable {
        var profiles: [Profile]
        var selected: UUID?
        var nodes: [String: String]
    }

    init() {
        load()
    }

    var current: Profile? { profiles.first { $0.id == selectedID } ?? profiles.first }
    var nodes: [ProxyNode] { current?.nodes ?? [] }
    var selectedTag: String? { current.flatMap { selectedNodes[$0.id.uuidString] } }

    func select(profile id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        latency.removeAll()
        save()
    }

    func select(node tag: String) {
        guard let p = current else { return }
        selectedNodes[p.id.uuidString] = tag
        save()
    }

    func addRemote(name: String, url: String, userAgent: String, token: String) async throws {
        var p = Profile(name: name.trimmingCharacters(in: .whitespaces), kind: .remote,
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        userAgent: userAgent, githubToken: token.trimmingCharacters(in: .whitespaces))
        try await fetch(&p)
        profiles.append(p)
        if selectedID == nil { selectedID = p.id }
        save()
    }

    func addLocal(name: String, text: String) throws {
        let parsed = SubscriptionParser.parse(text)
        guard !parsed.nodes.isEmpty else { throw AppError(Self.emptyReason(parsed)) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = Profile(name: trimmed.isEmpty ? "本地配置" : trimmed, kind: .local, nodes: parsed.nodes, updatedAt: Date())
        profiles.append(p)
        if selectedID == nil { selectedID = p.id }
        save()
    }

    func importFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try addLocal(name: url.deletingPathExtension().lastPathComponent, text: String(decoding: data, as: UTF8.self))
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = trimmed
        save()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        selectedNodes.removeValue(forKey: id.uuidString)
        if selectedID == id {
            selectedID = profiles.first?.id
            latency.removeAll()
        }
        save()
    }

    func update(_ id: UUID) async {
        guard let idx = profiles.firstIndex(where: { $0.id == id }), profiles[idx].kind == .remote,
              !updating.contains(id) else { return }
        updating.insert(id)
        defer { updating.remove(id) }
        var p = profiles[idx]
        do {
            try await fetch(&p)
            // 拉取期间配置可能已被删除, 重新定位
            if let i = profiles.firstIndex(where: { $0.id == id }) {
                profiles[i] = p
                save()
            }
            message = nil
        } catch {
            message = "「\(p.name)」更新失败：\(error.localizedDescription)"
        }
    }

    /// staleOnly 为 true 时只更新超过自动更新间隔的订阅
    func updateAll(staleOnly: Bool = false) async {
        let hours = UserDefaults.standard.integer(forKey: Settings.autoUpdateHours)
        if staleOnly && hours <= 0 { return }
        for p in profiles where p.kind == .remote {
            if staleOnly, let t = p.updatedAt, Date().timeIntervalSince(t) < Double(hours) * 3600 { continue }
            await update(p.id)
        }
    }

    // MARK: - 内部

    private func fetch(_ p: inout Profile) async throws {
        let mirror = UserDefaults.standard.string(forKey: Settings.githubMirror) ?? ""
        let r = try await SubscriptionFetcher.fetch(url: p.url, userAgent: p.userAgent, token: p.githubToken, mirror: mirror)
        let parsed = SubscriptionParser.parse(r.text)
        guard !parsed.nodes.isEmpty else { throw AppError(Self.emptyReason(parsed)) }
        p.nodes = parsed.nodes
        p.usage = r.usage
        p.updatedAt = Date()
        if p.name.isEmpty {
            p.name = r.title ?? URL(string: p.url)?.host ?? "订阅"
        }
    }

    private static func emptyReason(_ r: ParseResult) -> String {
        r.skipped > 0
            ? "识别到 \(r.skipped) 个节点，但都是 sing-box 不支持的协议（如 SSR、xhttp）"
            : "内容中没有识别到节点，请确认是 Clash / V2ray / Sing-box / Shadowsocks 订阅或分享链接"
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.state),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        profiles = s.profiles
        selectedID = s.selected
        selectedNodes = s.nodes
    }

    private func save() {
        let s = Snapshot(profiles: profiles, selected: selectedID, nodes: selectedNodes)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: Paths.state, options: .atomic)
        // 含节点密码与 GitHub 令牌, 仅当前用户可读
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.state.path)
    }
}
