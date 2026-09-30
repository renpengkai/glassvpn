//
// ClashParser.swift
// GlassVPN
// Clash / Clash.Meta (mihomo) 配置中的 proxies 转为 sing-box outbound。
//

import Foundation

enum ClashParser {

    static func looksLike(_ text: String) -> Bool {
        text.range(of: #"(?m)^proxies\s*:"#, options: .regularExpression) != nil
    }

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        guard let list = MiniYAML.topLevel("proxies", in: text) as? [Any] else { return result }
        for item in list {
            result.add(YMap(any: item).flatMap { node($0) })
        }
        return result
    }

    static func node(_ p: YMap) -> ProxyNode? {
        guard let type = p.str("type")?.lowercased() else { return nil }
        let name = p.str("name"), server = p.str("server"), port = p.int("port")
        var f: [String: JSON] = [:]

        func tls(always: Bool = false) -> TLSSpec? {
            let reality = p.map("reality-opts")
            guard always || p.bool("tls") || reality != nil else { return nil }
            return TLSSpec(sni: p.first("servername", "sni"),
                           insecure: p.bool("skip-cert-verify"),
                           alpn: p.list("alpn"),
                           fingerprint: p.str("client-fingerprint"),
                           realityKey: reality?.str("public-key"),
                           realityShortID: reality?.str("short-id"))
        }

        switch type {
        case "ss":
            guard let cipher = p.str("cipher"), let password = p.str("password") else { return nil }
            f["method"] = .string(cipher)
            f["password"] = .string(password)
            if let plugin = p.str("plugin") {
                let opts = pluginOptions(plugin, p.map("plugin-opts"))
                guard LinkParser.applyPlugin(plugin, opts: opts, to: &f) else { return nil }
            }
            if p.bool("udp-over-tcp") { f["udp_over_tcp"] = true }
            return NodeBuilder.make("shadowsocks", name: name, server: server, port: port, fields: f)

        case "vmess":
            guard let uuid = p.str("uuid") else { return nil }
            let t = transport(p)
            guard t.ok else { return nil }
            f["uuid"] = .string(uuid)
            f["alter_id"] = .int(p.int("alterId") ?? 0)
            f["security"] = .string(p.str("cipher") ?? "auto")
            return NodeBuilder.make("vmess", name: name, server: server, port: port, fields: f,
                                    tls: tls(), transport: t.spec)

        case "vless":
            guard let uuid = p.str("uuid") else { return nil }
            let t = transport(p)
            guard t.ok else { return nil }
            f["uuid"] = .string(uuid)
            if let flow = p.str("flow") { f["flow"] = .string(flow) }
            f["packet_encoding"] = .string(p.str("packet-encoding") ?? "xudp")
            return NodeBuilder.make("vless", name: name, server: server, port: port, fields: f,
                                    tls: tls(), transport: t.spec)

        case "trojan":
            guard let password = p.str("password") else { return nil }
            let t = transport(p)
            guard t.ok else { return nil }
            f["password"] = .string(password)
            return NodeBuilder.make("trojan", name: name, server: server, port: port, fields: f,
                                    tls: tls(always: true), transport: t.spec)

        case "hysteria2", "hy2":
            f["password"] = .string(p.first("password", "auth") ?? "")
            if let ports = p.str("ports") {
                f["server_ports"] = .array(ports.split(separator: ",").map {
                    JSON.string($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":"))
                })
            }
            if let obfs = p.str("obfs") {
                f["obfs"] = ["type": .string(obfs), "password": .string(p.str("obfs-password") ?? "")]
            }
            if let up = mbps(p.str("up")) { f["up_mbps"] = .int(up) }
            if let down = mbps(p.str("down")) { f["down_mbps"] = .int(down) }
            return NodeBuilder.make("hysteria2", name: name, server: server, port: port, fields: f, tls: tls(always: true))

        case "hysteria":
            f["up_mbps"] = .int(mbps(p.str("up")) ?? 10)
            f["down_mbps"] = .int(mbps(p.str("down")) ?? 50)
            if let auth = p.first("auth-str", "auth_str", "auth") { f["auth_str"] = .string(auth) }
            if let obfs = p.str("obfs") { f["obfs"] = .string(obfs) }
            return NodeBuilder.make("hysteria", name: name, server: server, port: port, fields: f, tls: tls(always: true))

        case "tuic":
            guard let uuid = p.str("uuid") else { return nil }
            f["uuid"] = .string(uuid)
            f["password"] = .string(p.str("password") ?? "")
            if let cc = p.str("congestion-controller") { f["congestion_control"] = .string(cc) }
            if let mode = p.str("udp-relay-mode") { f["udp_relay_mode"] = .string(mode) }
            if p.bool("reduce-rtt") { f["zero_rtt_handshake"] = true }
            return NodeBuilder.make("tuic", name: name, server: server, port: port, fields: f, tls: tls(always: true))

        case "socks5":
            f["version"] = "5"
            if let u = p.str("username") { f["username"] = .string(u) }
            if let pw = p.str("password") { f["password"] = .string(pw) }
            return NodeBuilder.make("socks", name: name, server: server, port: port, fields: f, tls: tls())

        case "http":
            if let u = p.str("username") { f["username"] = .string(u) }
            if let pw = p.str("password") { f["password"] = .string(pw) }
            return NodeBuilder.make("http", name: name, server: server, port: port, fields: f, tls: tls())

        case "anytls":
            guard let password = p.str("password") else { return nil }
            f["password"] = .string(password)
            return NodeBuilder.make("anytls", name: name, server: server, port: port, fields: f, tls: tls(always: true))

        default:
            // ssr、snell、wireguard 等 sing-box 不支持或需要 endpoint 的协议
            return nil
        }
    }

    /// Clash 的 plugin-opts 转成 SIP003 选项串
    static func pluginOptions(_ plugin: String, _ o: YMap?) -> String? {
        guard let o else { return nil }
        var parts: [String] = []
        if ["obfs", "simple-obfs", "obfs-local"].contains(plugin) {
            if let mode = o.str("mode") { parts.append("obfs=\(mode)") }
            if let host = o.str("host") { parts.append("obfs-host=\(host)") }
        } else {
            if let mode = o.str("mode") { parts.append("mode=\(mode)") }
            if o.bool("tls") { parts.append("tls") }
            if let host = o.str("host") { parts.append("host=\(host)") }
            if let path = o.str("path") { parts.append("path=\(path)") }
        }
        return parts.joined(separator: ";")
    }

    /// ok 为 false 表示 network 不受 sing-box 支持, 节点应跳过
    static func transport(_ p: YMap) -> (spec: TransportSpec?, ok: Bool) {
        switch p.str("network")?.lowercased() ?? "tcp" {
        case "tcp":
            return (nil, true)
        case "ws":
            let o = p.map("ws-opts")
            // mihomo 用 ws-opts.v2ray-http-upgrade 表示 HTTPUpgrade
            let upgrade = o?.bool("v2ray-http-upgrade") ?? false
            var spec = TransportSpec(type: upgrade ? "httpupgrade" : "ws", path: o?.str("path"),
                                     host: o?.map("headers")?.str("Host"))
            spec.maxEarlyData = o?.int("max-early-data")
            spec.earlyDataHeader = o?.str("early-data-header-name")
            return (spec, true)
        case "grpc":
            return (TransportSpec(type: "grpc", serviceName: p.map("grpc-opts")?.str("grpc-service-name")), true)
        case "h2":
            let o = p.map("h2-opts")
            return (TransportSpec(type: "http", path: o?.str("path"), host: o?.list("host").joined(separator: ",")), true)
        case "http":
            let o = p.map("http-opts")
            return (TransportSpec(type: "http", path: o?.list("path").first,
                                  host: o?.map("headers")?.list("Host").first), true)
        default:
            return (nil, false)
        }
    }

    /// "100 Mbps" / "1 Gbps" / "100" → Mbps
    static func mbps(_ s: String?) -> Int? {
        guard let s = s?.lowercased() else { return nil }
        guard let v = Double(s.prefix { $0.isNumber || $0 == "." }) else { return nil }
        if s.contains("g") { return Int(v * 1000) }
        if s.contains("k") { return max(Int(v / 1000), 1) }
        return Int(v)
    }
}
