//
// SubscriptionFetcher.swift
// GlassVPN
// 拉取订阅: 普通 HTTP(S) 订阅与 GitHub 订阅 (文件页 / raw / Gist, 私有仓库 token, 公开仓库加速镜像)。
//

import Foundation

enum SubscriptionFetcher {

    struct Result {
        var text: String
        var usage: Usage?
        /// 服务端建议的配置名 (profile-title 或 content-disposition)
        var title: String?
    }

    static func isGitHub(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "gist.github.com" || h.hasSuffix("githubusercontent.com")
    }

    /// github.com 的 blob/raw 页面、gist 页面换成原始文件地址
    static func rawURL(_ string: String) -> String {
        guard let u = URL(string: string), let host = u.host?.lowercased() else { return string }
        let parts = u.path.split(separator: "/").map(String.init)
        if host == "github.com", parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
            return "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/" + parts[3...].joined(separator: "/")
        }
        if host == "gist.github.com", parts.count >= 2 {
            return "https://gist.githubusercontent.com/\(parts[0])/\(parts[1])/raw"
        }
        return string
    }

    /// 前缀式镜像, 如 "https://ghfast.top/" + 原地址
    static func withMirror(_ url: String, mirror: String) -> String {
        let m = mirror.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return url }
        return m.hasSuffix("/") ? m + url : m + "/" + url
    }

    static func fetch(url raw: String, userAgent: String, token: String, mirror: String) async throws -> Result {
        let direct = rawURL(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let original = URL(string: direct), let scheme = original.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AppError("订阅地址无效")
        }
        let github = isGitHub(original.host)
        // 带 token 的私有仓库不走第三方镜像, 避免 token 泄露给镜像站
        let final = github && token.isEmpty ? withMirror(direct, mirror: mirror) : direct
        guard let url = URL(string: final) else { throw AppError("订阅地址无效") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        // 多数机场按 UA 决定下发格式, clash.meta 能拿到协议最全的 Clash.Meta 配置
        req.setValue(userAgent.isEmpty ? "clash.meta" : userAgent, forHTTPHeaderField: "User-Agent")
        if github && !token.isEmpty {
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AppError("无效的响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError(http.statusCode == 404 && github ? "HTTP 404：文件不存在，或私有仓库缺少令牌" : "服务器返回 HTTP \(http.statusCode)")
        }
        return Result(text: String(decoding: data, as: UTF8.self),
                      usage: usage(http.value(forHTTPHeaderField: "subscription-userinfo")),
                      title: title(http))
    }

    /// "upload=1; download=2; total=3; expire=4"
    static func usage(_ header: String?) -> Usage? {
        guard let header else { return nil }
        var v: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let text = kv[1].trimmingCharacters(in: .whitespaces)
            // 个别面板会输出科学计数法
            if let n = Int64(text) ?? Double(text).map({ Int64($0) }) {
                v[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = n
            }
        }
        guard !v.isEmpty else { return nil }
        let expire = v["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return Usage(upload: v["upload"] ?? 0, download: v["download"] ?? 0, total: v["total"] ?? 0, expire: expire)
    }

    static func title(_ http: HTTPURLResponse) -> String? {
        if var t = http.value(forHTTPHeaderField: "profile-title"), !t.isEmpty {
            if t.hasPrefix("base64:") { t = Base64.decode(String(t.dropFirst(7))) ?? t }
            return t
        }
        guard let cd = http.value(forHTTPHeaderField: "content-disposition") else { return nil }
        var name: String?
        if let r = cd.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            name = String(cd[r.upperBound...]).components(separatedBy: ";")[0].removingPercentEncoding
        } else if let r = cd.range(of: "filename=", options: .caseInsensitive) {
            name = String(cd[r.upperBound...]).components(separatedBy: ";")[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        guard let name, !name.isEmpty else { return nil }
        return (name as NSString).deletingPathExtension
    }
}
