//
// Profile.swift
// GlassVPN
// 节点、订阅配置与代理模式。
//

import Foundation

struct ProxyNode: Codable, Hashable, Identifiable {
    /// 在 sing-box 配置中作为 outbound tag, 同一配置内唯一
    var tag: String
    /// 不含 tag 的 sing-box outbound
    var outbound: JSON

    var id: String { tag }
    var type: String { outbound["type"]?.stringValue ?? "" }
    var server: String { outbound["server"]?.stringValue ?? "" }
    var port: Int { outbound["server_port"]?.intValue ?? 0 }

    /// 基于 UDP/QUIC 的协议, 未连接时无法用 TCP 握手测延迟
    var isUDP: Bool { ["hysteria", "hysteria2", "tuic"].contains(type) }

    var typeLabel: String {
        switch type {
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        case "vless": return "VLESS"
        case "trojan": return "Trojan"
        case "hysteria": return "Hysteria"
        case "hysteria2": return "Hy2"
        case "tuic": return "TUIC"
        case "socks": return "SOCKS"
        case "http": return "HTTP"
        case "anytls": return "AnyTLS"
        default: return type.uppercased()
        }
    }
}

/// 机场通过 `subscription-userinfo` 响应头下发的流量信息
struct Usage: Codable, Hashable {
    var upload: Int64
    var download: Int64
    var total: Int64
    var expire: Date?

    var used: Int64 { upload + download }
    var fraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }
}

struct Profile: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        /// 远程订阅 (含 GitHub), 可刷新
        case remote
        /// 粘贴或导入的本地内容
        case local
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var url = ""
    var userAgent = ""
    /// 仅 GitHub 私有仓库使用, 请求 github 域名时作为 Authorization 发送
    var githubToken = ""
    var nodes: [ProxyNode] = []
    var updatedAt: Date?
    var usage: Usage?
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule
    case global
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }

    init(stored: String?) {
        self = ProxyMode(rawValue: stored ?? "") ?? .rule
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
