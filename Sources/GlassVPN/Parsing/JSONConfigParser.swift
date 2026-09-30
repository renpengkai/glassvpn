//
// JSONConfigParser.swift
// GlassVPN
// JSON 格式的配置: sing-box 完整配置/outbound 列表、V2ray/V2fly/Xray 配置 (单个或数组)、Shadowsocks SIP008。
//

import Foundation

enum JSONConfigParser {

    static let singBoxTypes: Set<String> = [
        "shadowsocks", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "socks", "http", "anytls", "ssh",
    ]
    static let v2rayProtocols: Set<String> = ["vmess", "vless", "trojan", "shadowsocks", "socks", "http"]

    static func parse(_ obj: Any) -> ParseResult? {
        if let d = obj as? [String: Any] {
            let m = YMap(d)
            let outbounds = m.maps("outbounds")
            if !outbounds.isEmpty {
                // V2ray 用 protocol 字段, sing-box 用 type 字段
                return outbounds.contains { $0.raw["protocol"] != nil }
                    ? v2ray(outbounds, remarks: m.str("remarks"))
                    : singBox(outbounds)
            }
            let servers = m.maps("servers")
            if !servers.isEmpty { return sip008(servers) }
            if d["type"] != nil { return singBox([m]) }
            if d["server_port"] != nil && d["method"] != nil { return sip008([m]) }
            return nil
        }
        if let a = obj as? [Any] {
            var r = ParseResult()
            for item in a {
                if let sub = parse(item) { r.merge(sub) } else { r.skipped += 1 }
            }
            return r
        }
        return nil
    }

    // MARK: - sing-box

    static func singBox(_ outbounds: [YMap]) -> ParseResult {
        var r = ParseResult()
        for o in outbounds {
            // selector / urltest / direct 等非代理出站直接忽略, 不计入跳过数
            guard let type = o.str("type"), singBoxTypes.contains(type) else { continue }
            guard let server = o.str("server") else {
                r.skipped += 1
                continue
            }
            var dict = o.raw
            dict.removeValue(forKey: "tag")
            // detour 引用的是原配置里的其他出站, 导入后不存在
            dict.removeValue(forKey: "detour")
            r.nodes.append(ProxyNode(tag: o.str("tag") ?? "\(server):\(o.int("server_port") ?? 0)", outbound: JSON(any: dict)))
        }
        return r
    }

    // MARK: - V2ray / Xray

    static func v2ray(_ outbounds: [YMap], remarks: String?) -> ParseResult {
        let proxies = outbounds.filter { v2rayProtocols.contains($0.str("protocol")?.lowercased() ?? "") }
        var r = ParseResult()
        for o in proxies {
            let tag = o.str("tag")
            let name = proxies.count == 1 ? (remarks ?? tag) : [remarks, tag].compactMap { $0 }.joined(separator: " ")
            r.add(v2rayNode(o, name: name))
        }
        return r
    }

    static func v2rayNode(_ o: YMap, name: String?) -> ProxyNode? {
        guard let proto = o.str("protocol")?.lowercased(), let settings = o.map("settings") else { return nil }
        var f: [String: JSON] = [:]
        let server: String?
        let port: Int?

        switch proto {
        case "vmess", "vless":
            guard let vnext = settings.maps("vnext").first, let user = vnext.maps("users").first,
                  let id = user.str("id") else { return nil }
            server = vnext.str("address")
            port = vnext.int("port")
            f["uuid"] = .string(id)
            if proto == "vmess" {
                f["security"] = .string(user.str("security") ?? "auto")
                f["alter_id"] = .int(user.int("alterId") ?? 0)
            } else {
                if let flow = user.str("flow") { f["flow"] = .string(flow) }
                f["packet_encoding"] = "xudp"
            }
        default:
            guard let s = settings.maps("servers").first else { return nil }
            server = s.str("address")
            port = s.int("port")
            switch proto {
            case "trojan":
                f["password"] = .string(s.str("password") ?? "")
            case "shadowsocks":
                f["method"] = .string(s.str("method") ?? "")
                f["password"] = .string(s.str("password") ?? "")
            default:
                if proto == "socks" { f["version"] = "5" }
                if let u = s.maps("users").first {
                    f["username"] = .string(u.str("user") ?? "")
                    f["password"] = .string(u.str("pass") ?? "")
                }
            }
        }

        let stream = o.map("streamSettings")
        let tcpHeader = stream?.map("tcpSettings")?.map("header")
        guard let kind = TransportSpec.kind(stream?.str("network"), headerType: tcpHeader?.str("type")) else { return nil }
        var transport: TransportSpec?
        switch kind {
        case "ws":
            let w = stream?.map("wsSettings")
            transport = TransportSpec(type: "ws", path: w?.str("path"), host: w?.map("headers")?.str("Host") ?? w?.str("host"))
        case "grpc":
            transport = TransportSpec(type: "grpc", serviceName: stream?.map("grpcSettings")?.str("serviceName"))
        case "http":
            if let h = stream?.map("httpSettings") {
                transport = TransportSpec(type: "http", path: h.str("path"), host: h.list("host").joined(separator: ","))
            } else {
                // TCP + HTTP 伪装头
                let req = tcpHeader?.map("request")
                transport = TransportSpec(type: "http", path: req?.list("path").first,
                                          host: req?.map("headers")?.list("Host").first)
            }
        case "httpupgrade":
            let h = stream?.map("httpupgradeSettings")
            transport = TransportSpec(type: "httpupgrade", path: h?.str("path"), host: h?.str("host"))
        case "quic":
            transport = TransportSpec(type: "quic")
        default:
            transport = nil
        }

        var tls: TLSSpec?
        switch stream?.str("security")?.lowercased() {
        case "tls":
            let t = stream?.map("tlsSettings")
            tls = TLSSpec(sni: t?.str("serverName"), insecure: t?.bool("allowInsecure") ?? false,
                          alpn: t?.list("alpn") ?? [], fingerprint: t?.str("fingerprint"))
        case "reality":
            let t = stream?.map("realitySettings")
            tls = TLSSpec(sni: t?.str("serverName"), fingerprint: t?.str("fingerprint"),
                          realityKey: t?.str("publicKey"), realityShortID: t?.str("shortId"))
        default:
            tls = nil
        }

        return NodeBuilder.make(proto, name: name, server: server, port: port, fields: f, tls: tls, transport: transport)
    }

    // MARK: - SIP008

    static func sip008(_ servers: [YMap]) -> ParseResult {
        var r = ParseResult()
        for s in servers {
            var f: [String: JSON] = [
                "method": .string(s.str("method") ?? ""),
                "password": .string(s.str("password") ?? ""),
            ]
            if let plugin = s.str("plugin"), !LinkParser.applyPlugin(plugin, opts: s.str("plugin_opts"), to: &f) {
                r.skipped += 1
                continue
            }
            r.add(NodeBuilder.make("shadowsocks", name: s.first("remarks", "name"), server: s.str("server"),
                                   port: s.int("server_port"), fields: f))
        }
        return r
    }
}
