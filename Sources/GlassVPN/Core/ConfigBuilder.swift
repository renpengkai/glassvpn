//
// ConfigBuilder.swift
// GlassVPN
// 由节点列表生成 sing-box 配置 (1.12+ 格式: 新版 DNS 服务器写法、rule action)。
//

import Foundation

enum ConfigBuilder {

    static let defaultTestURL = "https://www.gstatic.com/generate_204"

    /// jsDelivr 镜像在国内可直连, 规则集下载不依赖尚未就绪的代理
    static let ruleSets: [(tag: String, url: String)] = [
        ("geosite-cn", "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs"),
        ("geoip-cn", "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs"),
    ]

    struct Options {
        var mode: ProxyMode
        var tun: Bool
        var mixedPort: Int
        var apiPort: Int
        var secret: String
        var allowLAN: Bool
        var logLevel: String
        var testURL: String
    }

    static func build(nodes: [ProxyNode], selected: String?, options o: Options) throws -> Data {
        guard !nodes.isEmpty else { throw AppError("没有可用节点") }
        let tags = nodes.map(\.tag)

        var outbounds: [JSON] = nodes.map { node in
            var ob = node.outbound
            ob["tag"] = .string(node.tag)
            return ob
        }
        let initial = selected.flatMap { tags.contains($0) ? $0 : nil } ?? "auto"
        let urltest: JSON = [
            "type": "urltest", "tag": "auto",
            "outbounds": .array(tags.map(JSON.string)),
            "url": .string(o.testURL), "interval": "10m", "tolerance": 50,
        ]
        let selector: JSON = [
            "type": "selector", "tag": "proxy",
            "outbounds": .array([JSON.string("auto")] + tags.map(JSON.string)),
            "default": .string(initial),
            "interrupt_exist_connections": true,
        ]
        let direct: JSON = ["type": "direct", "tag": "direct"]
        outbounds += [urltest, selector, direct]

        var inbounds: [JSON] = [[
            "type": "mixed", "tag": "mixed-in",
            "listen": .string(o.allowLAN ? "0.0.0.0" : "127.0.0.1"),
            "listen_port": .int(o.mixedPort),
        ]]
        if o.tun {
            let tun: JSON = [
                "type": "tun", "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 9000, "auto_route": true, "strict_route": true, "stack": "mixed",
            ]
            inbounds.append(tun)
        }

        let dnsServers: JSON = [
            ["type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"],
            ["type": "udp", "tag": "local", "server": "223.5.5.5"],
        ]
        let dnsRules: JSON = [
            ["clash_mode": "direct", "server": "local"],
            ["clash_mode": "global", "server": "remote"],
            ["rule_set": "geosite-cn", "server": "local"],
        ]
        let dns: JSON = ["servers": dnsServers, "rules": dnsRules, "final": "remote", "strategy": "prefer_ipv4"]

        // clash_mode 规则让 Clash API 的 PATCH /configs 能在运行中切换 规则/全局/直连
        let routeRules: JSON = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["clash_mode": "direct", "outbound": "direct"],
            ["clash_mode": "global", "outbound": "proxy"],
            ["ip_is_private": true, "outbound": "direct"],
            ["rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"],
        ]
        let ruleSetList: [JSON] = ruleSets.map { rs -> JSON in
            ["type": "remote", "tag": .string(rs.tag), "format": "binary", "url": .string(rs.url), "download_detour": "direct"]
        }
        let route: JSON = [
            "rules": routeRules,
            "rule_set": .array(ruleSetList),
            "final": "proxy",
            "auto_detect_interface": true,
            "default_domain_resolver": "local",
        ]

        let clashAPI: JSON = [
            "external_controller": .string("127.0.0.1:\(o.apiPort)"),
            "secret": .string(o.secret),
            "default_mode": .string(o.mode.rawValue),
        ]
        let experimental: JSON = ["cache_file": ["enabled": true], "clash_api": clashAPI]
        let log: JSON = ["level": .string(o.logLevel), "timestamp": true]

        let config: JSON = [
            "log": log,
            "dns": dns,
            "inbounds": .array(inbounds),
            "outbounds": .array(outbounds),
            "route": route,
            "experimental": experimental,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }
}
