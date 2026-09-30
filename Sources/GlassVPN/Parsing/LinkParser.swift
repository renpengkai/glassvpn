//
// LinkParser.swift
// GlassVPN
// 分享链接解析: ss / vmess / vless / trojan / hysteria / hysteria2(hy2) / tuic / socks / anytls。
//

import Foundation

/// 手工拆分链接。URLComponents 对未编码的密码、base64 userinfo、端口跳跃写法都不宽容。
struct LinkURL {
    /// userinfo 原文 (已百分号解码)
    var user = ""
    var host = ""
    var portText = ""
    /// 键统一小写
    var query: [String: String] = [:]
    var name = ""

    var port: Int? { Int(portText) }

    init?(_ link: String) {
        guard let r = link.range(of: "://") else { return nil }
        var rest = String(link[r.upperBound...])
        if let h = rest.firstIndex(of: "#") {
            name = LinkURL.decode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        if let q = rest.firstIndex(of: "?") {
            query = LinkURL.parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        // 先按最后一个 @ 拆 userinfo, 再去掉路径: userinfo 里可能有 base64 的 "/"
        if let at = rest.lastIndex(of: "@") {
            user = LinkURL.decode(String(rest[..<at]))
            rest = String(rest[rest.index(after: at)...])
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        guard let hp = LinkURL.splitHost(rest) else { return nil }
        host = hp.host
        portText = hp.port
    }

    static func decode(_ s: String) -> String {
        (s.removingPercentEncoding ?? s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitHost(_ s: String) -> (host: String, port: String)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            return (host, after.hasPrefix(":") ? String(after.dropFirst()) : "")
        }
        // 端口段可能是 "443,2000-3000" 这类端口跳跃写法, 所以按第一个冒号拆
        guard let c = s.firstIndex(of: ":") else { return s.isEmpty ? nil : (s, "") }
        return (String(s[..<c]), String(s[s.index(after: c)...]))
    }

    static func parseQuery(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first, !k.isEmpty else { continue }
            result[decode(String(k)).lowercased()] = kv.count > 1 ? decode(String(kv[1])) : ""
        }
        return result
    }
}

enum LinkParser {

    static func parse(_ line: String) -> ProxyNode? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "://") else { return nil }
        switch s[..<r.lowerBound].lowercased() {
        case "ss": return shadowsocks(s)
        case "vmess": return vmess(s)
        case "vless": return standard(s, type: "vless")
        case "trojan": return standard(s, type: "trojan")
        case "hysteria2", "hy2": return hysteria2(s)
        case "hysteria": return hysteria(s)
        case "tuic": return tuic(s)
        case "socks", "socks5": return socks(s)
        case "anytls": return anytls(s)
        default: return nil
        }
    }

    // MARK: - Shadowsocks

    static func shadowsocks(_ link: String) -> ProxyNode? {
        var body = String(link.dropFirst("ss://".count))
        var name = ""
        if let h = body.firstIndex(of: "#") {
            name = LinkURL.decode(String(body[body.index(after: h)...]))
            body = String(body[..<h])
        }
        var query: [String: String] = [:]
        if let q = body.firstIndex(of: "?") {
            query = LinkURL.parseQuery(String(body[body.index(after: q)...]))
            body = String(body[..<q])
        }
        while body.hasSuffix("/") { body.removeLast() }
        // 旧格式整体 base64: method:password@host:port
        if !body.contains("@"), let decoded = Base64.decode(body) { body = decoded }
        guard let at = body.lastIndex(of: "@") else { return nil }
        var info = String(body[..<at])
        // SIP002: userinfo 为 base64(method:password), 2022 系列允许明文百分号编码
        info = info.contains(":") ? LinkURL.decode(info) : (Base64.decode(info) ?? LinkURL.decode(info))
        guard let c = info.firstIndex(of: ":"),
              let hp = LinkURL.splitHost(String(body[body.index(after: at)...])) else { return nil }
        var fields: [String: JSON] = [
            "method": .string(String(info[..<c])),
            "password": .string(String(info[info.index(after: c)...])),
        ]
        if let plugin = nonEmpty(query["plugin"]) {
            guard applyPlugin(plugin, to: &fields) else { return nil }
        }
        return NodeBuilder.make("shadowsocks", name: name, server: hp.host, port: Int(hp.port), fields: fields)
    }

    /// SIP003 插件, 形如 "obfs-local;obfs=http;obfs-host=x"。sing-box 只内置 obfs-local 与 v2ray-plugin,
    /// 其他插件返回 false, 由调用方跳过该节点。
    static func applyPlugin(_ spec: String, opts: String? = nil, to fields: inout [String: JSON]) -> Bool {
        let parts = spec.split(separator: ";", maxSplits: 1).map(String.init)
        var name = parts.first ?? ""
        let options = opts ?? (parts.count > 1 ? parts[1] : "")
        if name == "simple-obfs" || name == "obfs" { name = "obfs-local" }
        guard name == "obfs-local" || name == "v2ray-plugin" else { return false }
        fields["plugin"] = .string(name)
        if !options.isEmpty { fields["plugin_opts"] = .string(options) }
        return true
    }

    // MARK: - VMess

    static func vmess(_ link: String) -> ProxyNode? {
        let body = String(link.dropFirst("vmess://".count)).components(separatedBy: "#")[0]
        guard let text = Base64.decode(body), let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 部分客户端导出的是与 vless 相同结构的标准 URL
            return standard(link, type: "vmess")
        }
        let j = YMap(obj)
        guard let uuid = j.str("id"), let kind = TransportSpec.kind(j.str("net"), headerType: j.str("type")) else {
            return nil
        }
        let fields: [String: JSON] = [
            "uuid": .string(uuid),
            "security": .string(j.str("scy") ?? "auto"),
            "alter_id": .int(j.int("aid") ?? 0),
        ]
        var tls: TLSSpec?
        let security = j.str("tls")?.lowercased() ?? ""
        if security == "tls" || security == "reality" {
            tls = TLSSpec(sni: j.first("sni", "host"),
                          insecure: j.bool("allowInsecure") || j.bool("skip-cert-verify"),
                          alpn: j.list("alpn"),
                          fingerprint: j.str("fp"),
                          realityKey: j.str("pbk"),
                          realityShortID: j.str("sid"))
        }
        // grpc 的 serviceName 在 vmess JSON 里放在 path 字段
        let transport = TransportSpec.make(kind, path: j.str("path"), host: j.str("host"), serviceName: j.str("path"))
        return NodeBuilder.make("vmess", name: j.str("ps"), server: j.str("add"), port: j.int("port"),
                                fields: fields, tls: tls, transport: transport)
    }

    // MARK: - VLESS / Trojan / 标准 VMess URL

    static func standard(_ link: String, type: String) -> ProxyNode? {
        guard let u = LinkURL(link), !u.user.isEmpty else { return nil }
        let q = u.query
        var fields: [String: JSON] = [:]
        switch type {
        case "trojan":
            fields["password"] = .string(u.user)
        case "vless":
            fields["uuid"] = .string(u.user)
            if let flow = nonEmpty(q["flow"]) { fields["flow"] = .string(flow) }
            fields["packet_encoding"] = "xudp"
        default:
            fields["uuid"] = .string(u.user)
            fields["security"] = .string(nonEmpty(q["encryption"]) ?? "auto")
            fields["alter_id"] = 0
        }
        guard let kind = TransportSpec.kind(q["type"], headerType: q["headertype"]) else { return nil }
        let security = (q["security"] ?? (type == "trojan" ? "tls" : "")).lowercased()
        var tls: TLSSpec?
        // trojan 协议本身要求 TLS, 除非明确写了 security=none
        if ["tls", "reality", "xtls"].contains(security) || (type == "trojan" && security != "none") {
            tls = TLSSpec(sni: nonEmpty(q["sni"]) ?? nonEmpty(q["peer"]),
                          insecure: flag(q["allowinsecure"]) || flag(q["insecure"]),
                          alpn: list(q["alpn"]),
                          fingerprint: nonEmpty(q["fp"]),
                          realityKey: nonEmpty(q["pbk"]),
                          realityShortID: q["sid"])
        }
        let transport = TransportSpec.make(kind, path: q["path"], host: q["host"], serviceName: q["servicename"])
        return NodeBuilder.make(type, name: u.name, server: u.host, port: u.port,
                                fields: fields, tls: tls, transport: transport)
    }

    // MARK: - Hysteria / Hysteria2 / TUIC

    static func hysteria2(_ link: String) -> ProxyNode? {
        guard let u = LinkURL(link) else { return nil }
        let q = u.query
        var fields: [String: JSON] = ["password": .string(u.user)]
        var port: Int?
        var ranges: [JSON] = []
        // 端口跳跃: "443,20000-30000" 或 mport 参数; sing-box 的范围写法是 "20000:30000"
        let spec = u.portText + (nonEmpty(q["mport"]).map { "," + $0 } ?? "")
        for part in spec.split(separator: ",") {
            if part.contains("-") {
                ranges.append(.string(part.replacingOccurrences(of: "-", with: ":")))
            } else if let p = Int(part) {
                if port == nil { port = p } else { ranges.append(.string("\(p):\(p)")) }
            }
        }
        if !ranges.isEmpty { fields["server_ports"] = .array(ranges) }
        if let obfs = nonEmpty(q["obfs"]), obfs != "none" {
            fields["obfs"] = ["type": .string(obfs), "password": .string(q["obfs-password"] ?? "")]
        }
        if let up = q["upmbps"].flatMap({ Int($0) }) { fields["up_mbps"] = .int(up) }
        if let down = q["downmbps"].flatMap({ Int($0) }) { fields["down_mbps"] = .int(down) }
        let tls = TLSSpec(sni: nonEmpty(q["sni"]), insecure: flag(q["insecure"]), alpn: list(q["alpn"]))
        return NodeBuilder.make("hysteria2", name: u.name, server: u.host, port: port, fields: fields, tls: tls)
    }

    static func hysteria(_ link: String) -> ProxyNode? {
        guard let u = LinkURL(link) else { return nil }
        let q = u.query
        // sing-box 要求显式给出带宽, 链接缺省时取保守值
        var fields: [String: JSON] = [
            "up_mbps": .int(Int(q["upmbps"] ?? "") ?? 10),
            "down_mbps": .int(Int(q["downmbps"] ?? "") ?? 50),
        ]
        if let auth = nonEmpty(q["auth"]) { fields["auth_str"] = .string(auth) }
        if let obfs = nonEmpty(q["obfsparam"]) { fields["obfs"] = .string(obfs) }
        let tls = TLSSpec(sni: nonEmpty(q["peer"]) ?? nonEmpty(q["sni"]), insecure: flag(q["insecure"]), alpn: list(q["alpn"]))
        return NodeBuilder.make("hysteria", name: u.name, server: u.host, port: u.port, fields: fields, tls: tls)
    }

    static func tuic(_ link: String) -> ProxyNode? {
        guard let u = LinkURL(link), let c = u.user.firstIndex(of: ":") else { return nil }
        let q = u.query
        var fields: [String: JSON] = [
            "uuid": .string(String(u.user[..<c])),
            "password": .string(String(u.user[u.user.index(after: c)...])),
        ]
        if let cc = nonEmpty(q["congestion_control"]) { fields["congestion_control"] = .string(cc) }
        if let mode = nonEmpty(q["udp_relay_mode"]) { fields["udp_relay_mode"] = .string(mode) }
        let tls = TLSSpec(sni: nonEmpty(q["sni"]), insecure: flag(q["allow_insecure"]) || flag(q["insecure"]),
                          alpn: list(q["alpn"]))
        return NodeBuilder.make("tuic", name: u.name, server: u.host, port: u.port, fields: fields, tls: tls)
    }

    // MARK: - SOCKS / AnyTLS

    static func socks(_ link: String) -> ProxyNode? {
        guard let u = LinkURL(link) else { return nil }
        var fields: [String: JSON] = ["version": "5"]
        var info = u.user
        if !info.isEmpty, !info.contains(":"), let decoded = Base64.decode(info) { info = decoded }
        if let c = info.firstIndex(of: ":") {
            fields["username"] = .string(String(info[..<c]))
            fields["password"] = .string(String(info[info.index(after: c)...]))
        }
        return NodeBuilder.make("socks", name: u.name, server: u.host, port: u.port, fields: fields)
    }

    static func anytls(_ link: String) -> ProxyNode? {
        guard let u = LinkURL(link), !u.user.isEmpty else { return nil }
        let q = u.query
        let tls = TLSSpec(sni: nonEmpty(q["sni"]), insecure: flag(q["insecure"]) || flag(q["allowinsecure"]),
                          fingerprint: nonEmpty(q["fp"]))
        return NodeBuilder.make("anytls", name: u.name, server: u.host, port: u.port,
                                fields: ["password": .string(u.user)], tls: tls)
    }

    // MARK: - 工具

    private static func flag(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }

    private static func list(_ v: String?) -> [String] {
        v?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }

    private static func nonEmpty(_ v: String?) -> String? {
        guard let v, !v.isEmpty else { return nil }
        return v
    }
}
