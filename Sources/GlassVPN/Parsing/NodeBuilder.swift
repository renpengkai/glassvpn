//
// NodeBuilder.swift
// GlassVPN
// 各格式解析器先整理出 TLS / 传输层的中间描述, 再统一生成 sing-box outbound。
//

import Foundation

struct TLSSpec {
    var sni: String?
    var insecure = false
    var alpn: [String] = []
    var fingerprint: String?
    var realityKey: String?
    var realityShortID: String?

    var json: JSON {
        var t: [String: JSON] = ["enabled": true]
        if let sni, !sni.isEmpty { t["server_name"] = .string(sni) }
        if insecure { t["insecure"] = true }
        if !alpn.isEmpty { t["alpn"] = .array(alpn.map(JSON.string)) }
        let hasReality = !(realityKey ?? "").isEmpty
        // sing-box 的 reality 必须配合 uTLS, 链接未给指纹时用 chrome
        let fp = fingerprint ?? (hasReality ? "chrome" : nil)
        if let fp, !fp.isEmpty, fp != "none" {
            t["utls"] = ["enabled": true, "fingerprint": .string(fp)]
        }
        if hasReality, let key = realityKey {
            t["reality"] = ["enabled": true, "public_key": .string(key), "short_id": .string(realityShortID ?? "")]
        }
        return .object(t)
    }
}

struct TransportSpec {
    /// sing-box transport 类型: ws / grpc / http / httpupgrade / quic
    var type: String
    var path: String?
    var host: String?
    var serviceName: String?
    var maxEarlyData: Int?
    var earlyDataHeader: String?

    /// 把各客户端的 network 名称映射到 sing-box transport 类型。
    /// 返回空串表示原始 TCP (无 transport), 返回 nil 表示 sing-box 不支持 (如 xhttp、kcp), 节点应跳过。
    static func kind(_ network: String?, headerType: String? = nil) -> String? {
        switch (network ?? "tcp").lowercased() {
        case "", "tcp", "raw": return headerType?.lowercased() == "http" ? "http" : ""
        case "ws", "websocket": return "ws"
        case "grpc", "gun": return "grpc"
        case "h2", "http": return "http"
        case "httpupgrade": return "httpupgrade"
        case "quic": return "quic"
        default: return nil
        }
    }

    static func make(_ kind: String, path: String?, host: String?, serviceName: String? = nil) -> TransportSpec? {
        kind.isEmpty ? nil : TransportSpec(type: kind, path: path, host: host, serviceName: serviceName)
    }

    var json: JSON {
        var t: [String: JSON] = ["type": .string(type)]
        switch type {
        case "ws":
            var p = path ?? "/"
            var ed = maxEarlyData
            // v2rayN 风格的 "/path?ed=2048" 转成 sing-box 的 early data 字段, 否则服务端会收到错误路径
            if let r = p.range(of: "?ed=") {
                ed = Int(p[r.upperBound...].prefix(while: \.isNumber)) ?? ed
                p = String(p[..<r.lowerBound])
            }
            t["path"] = .string(p.isEmpty ? "/" : p)
            if let host, !host.isEmpty { t["headers"] = ["Host": .string(host)] }
            if let ed, ed > 0 {
                t["max_early_data"] = .int(ed)
                t["early_data_header_name"] = .string(earlyDataHeader ?? "Sec-WebSocket-Protocol")
            }
        case "grpc":
            t["service_name"] = .string(serviceName ?? "")
        case "http":
            if let host, !host.isEmpty {
                t["host"] = .array(host.split(separator: ",").map { JSON.string(String($0)) })
            }
            if let path, !path.isEmpty { t["path"] = .string(path) }
        case "httpupgrade":
            if let host, !host.isEmpty { t["host"] = .string(host) }
            t["path"] = .string(path ?? "/")
        default:
            break
        }
        return .object(t)
    }
}

enum NodeBuilder {

    static func make(_ type: String, name: String?, server: String?, port: Int?, fields: [String: JSON],
                     tls: TLSSpec? = nil, transport: TransportSpec? = nil) -> ProxyNode? {
        guard let server = server?.trimmingCharacters(in: .whitespaces), !server.isEmpty else { return nil }
        let port = port ?? 0
        // Hysteria2 端口跳跃可以只给端口范围
        guard (1...65535).contains(port) || fields["server_ports"] != nil else { return nil }
        var o = fields
        o["type"] = .string(type)
        o["server"] = .string(server)
        if port > 0 { o["server_port"] = .int(port) }
        if let tls { o["tls"] = tls.json }
        if let transport { o["transport"] = transport.json }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProxyNode(tag: trimmed.isEmpty ? "\(server):\(port)" : trimmed, outbound: .object(o))
    }
}

struct ParseResult {
    var nodes: [ProxyNode] = []
    /// 识别出但无法转换的条目数 (协议不受支持或字段缺失)
    var skipped = 0

    mutating func add(_ node: ProxyNode?) {
        if let node { nodes.append(node) } else { skipped += 1 }
    }

    mutating func merge(_ other: ParseResult) {
        nodes += other.nodes
        skipped += other.skipped
    }

    /// sing-box 要求 tag 唯一, 且不能与配置里固定的 proxy / auto / direct 重名
    func uniqued() -> ParseResult {
        var used: Set<String> = ["proxy", "auto", "direct", "block", "dns-out"]
        var out = self
        out.nodes = nodes.map { node in
            var n = node
            var tag = node.tag
            var k = 2
            while used.contains(tag) {
                tag = "\(node.tag) \(k)"
                k += 1
            }
            used.insert(tag)
            n.tag = tag
            return n
        }
        return out
    }
}
