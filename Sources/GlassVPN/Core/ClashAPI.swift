//
// ClashAPI.swift
// GlassVPN
// sing-box 内置 Clash API 客户端: 存活检查、切换节点/模式、延迟测试、实时流量。
//

import Foundation

struct ClashAPI {
    let port: Int
    let secret: String

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // 本地控制接口不能走系统代理 (系统代理正指向内核自身)
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    func isAlive() async -> Bool {
        (try? await send(request("/version", timeout: 1))) != nil
    }

    func select(_ tag: String, in group: String = "proxy") async throws {
        try await send(request("/proxies/\(Self.escape(group))", method: "PUT", body: ["name": tag]))
    }

    func setMode(_ mode: String) async throws {
        try await send(request("/configs", method: "PATCH", body: ["mode": mode]))
    }

    /// 分组当前实际使用的出站
    func now(_ group: String) async -> String? {
        guard let data = try? await send(request("/proxies/\(Self.escape(group))")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["now"] as? String
    }

    /// 通过节点真实请求测试地址, 返回毫秒; 失败返回 nil
    func delay(_ tag: String, url: String, timeout: Int = 5000) async -> Int? {
        let req = request("/proxies/\(Self.escape(tag))/delay",
                          query: [("url", url), ("timeout", "\(timeout)")],
                          timeout: TimeInterval(timeout) / 1000 + 2)
        guard let data = try? await send(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = obj["delay"] as? Int, ms > 0 else { return nil }
        return ms
    }

    /// 每秒一条的上下行速率 (字节/秒)
    func traffic() -> AsyncThrowingStream<(up: Int, down: Int), Error> {
        let req = request("/traffic", timeout: 10)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await Self.session.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        continuation.yield((up: obj["up"] as? Int ?? 0, down: obj["down"] as? Int ?? 0))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func request(_ path: String, method: String = "GET", query: [(String, String)] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 5) -> URLRequest {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = port
        c.percentEncodedPath = path
        // queryItems 不会编码值里的 & 与 =, 测试地址可能带参数, 手工编码
        if !query.isEmpty {
            c.percentEncodedQuery = query.map { "\($0.0)=\(Self.escape($0.1))" }.joined(separator: "&")
        }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AppError("控制接口返回 HTTP \(code)") }
        return data
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}
