//
// Helpers.swift
// GlassVPN
// 解析通用工具: 宽松 Base64、对 YAML/JSON 字典的类型宽容访问。
//

import Foundation

enum Base64 {
    /// 兼容 URL-safe 字符集、缺失的补位与换行
    static func decode(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        t.removeAll { $0 == "\n" || $0 == "\r" || $0 == " " }
        guard !t.isEmpty else { return nil }
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 包装 YAML / JSON 解析出的字典。MiniYAML 的标量全是字符串, JSONSerialization 的是 NSNumber,
/// 这里统一按需转换, 调用方不用关心来源。
struct YMap {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(any: Any?) {
        guard let d = any as? [String: Any] else { return nil }
        raw = d
    }

    func str(_ key: String) -> String? {
        guard let v = raw[key] else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    func first(_ keys: String...) -> String? {
        for k in keys {
            if let v = str(k) { return v }
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        str(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func bool(_ key: String) -> Bool {
        guard let s = str(key)?.lowercased() else { return false }
        return ["true", "1", "yes", "on"].contains(s)
    }

    func map(_ key: String) -> YMap? { YMap(any: raw[key]) }

    func maps(_ key: String) -> [YMap] {
        (raw[key] as? [Any])?.compactMap { YMap(any: $0) } ?? []
    }

    /// 数组或逗号分隔字符串都当作列表
    func list(_ key: String) -> [String] {
        if let a = raw[key] as? [Any] {
            return a.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
        }
        guard let s = str(key) else { return [] }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
