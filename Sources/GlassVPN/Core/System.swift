//
// System.swift
// GlassVPN
// 路径常量、子进程执行、日志读取、进程路径查询。
//

import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("GlassVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 用户态内核 (首次启动下载)
    static var core: URL { support.appendingPathComponent("core/sing-box") }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var state: URL { support.appendingPathComponent("profiles.json") }
    static var userLog: URL { support.appendingPathComponent("core.log") }

    /// 以下与 gvpnhelper 内的常量保持一致
    static let helper = "/Library/PrivilegedHelperTools/io.github.renpengkai.glassvpn.helper"
    static let rootCore = "/Library/PrivilegedHelperTools/io.github.renpengkai.glassvpn.core"
    static let rootLog = URL(fileURLWithPath: "/Library/Logs/GlassVPN/core.log")
}

enum Shell {
    /// 输出写临时文件而不是管道: 特权组件会拉起常驻的内核进程, 若内核继承了管道写端, 这里将永远读不到 EOF
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("glassvpn-\(UUID().uuidString).out")
        fm.createFile(atPath: out.path, contents: nil)
        defer { try? fm.removeItem(at: out) }
        guard let handle = try? FileHandle(forWritingTo: out) else { return (-1, "无法创建临时文件") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            try? handle.close()
            return (-1, error.localizedDescription)
        }
        p.waitUntilExit()
        try? handle.close()
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum LogReader {
    static func tail(_ url: URL, maxBytes: Int = 64 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // 从中间截断时丢掉不完整的首行
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func lastLines(_ url: URL, _ n: Int) -> String {
        lastLines(of: tail(url, maxBytes: 8192), n)
    }

    static func lastLines(of text: String, _ n: Int) -> String {
        text.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}

enum Proc {
    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
