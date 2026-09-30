//
// SystemProxy.swift
// GlassVPN
// 系统代理 (networksetup)、TUN 特权组件 (setuid helper) 与 TCP 握手测速。
//

import AppKit
import Network

enum SystemProxy {
    static let tool = "/usr/sbin/networksetup"
    static let bypass = ["127.0.0.1", "localhost", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12",
                         "192.168.0.0/16", "::1"]

    /// 已启用的网络服务; 输出首行是说明文字, 以 * 开头的是已停用服务
    static func services() -> [String] {
        Shell.run(tool, ["-listallnetworkservices"]).output
            .split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// 直接调用 networksetup, 管理员账户通常无需授权; 返回是否生效, 失败时由调用方改用特权组件
    static func apply(port: Int?) -> Bool {
        let list = services()
        for s in list {
            if let port {
                Shell.run(tool, ["-setwebproxy", s, "127.0.0.1", "\(port)"])
                Shell.run(tool, ["-setsecurewebproxy", s, "127.0.0.1", "\(port)"])
                Shell.run(tool, ["-setsocksfirewallproxy", s, "127.0.0.1", "\(port)"])
                Shell.run(tool, ["-setproxybypassdomains", s] + bypass)
            } else {
                Shell.run(tool, ["-setwebproxystate", s, "off"])
                Shell.run(tool, ["-setsecurewebproxystate", s, "off"])
                Shell.run(tool, ["-setsocksfirewallproxystate", s, "off"])
            }
        }
        // networksetup 权限不足时退出码并不可靠, 以回读结果为准
        guard let first = list.first else { return true }
        let out = Shell.run(tool, ["-getwebproxy", first]).output
        let enabled = out.contains("Enabled: Yes")
        if let port { return enabled && out.contains("Port: \(port)") }
        return !enabled
    }
}

enum PrivilegedHelper {
    /// 与 gvpnhelper 内的 helperVersion 一致; 改动 helper 行为时同步递增, 旧版本会提示重新安装
    static let version = "1"

    private static var bundled: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("gvpnhelper").path
    }

    /// 已安装、属主 root、带 setuid 位、版本匹配且 root 内核存在
    static var isReady: Bool {
        var st = stat()
        guard stat(Paths.helper, &st) == 0, st.st_uid == 0, st.st_mode & 0o4000 != 0,
              FileManager.default.isExecutableFile(atPath: Paths.rootCore) else { return false }
        let r = run(["version"])
        return r.ok && r.output == version
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: Paths.helper) }

    @discardableResult
    static func run(_ args: [String]) -> (ok: Bool, output: String) {
        let r = Shell.run(Paths.helper, args)
        return (r.status == 0, r.output)
    }

    /// 通过管理员授权对话框安装 helper 与一份 root 所有的内核副本。
    /// 内核复制到 root 目录是为了防止普通进程替换可执行文件后借 helper 以 root 运行任意程序。
    static func install(core: String) -> String? {
        guard let src = bundled, FileManager.default.isExecutableFile(atPath: src) else { return "应用包内缺少 gvpnhelper" }
        guard FileManager.default.isExecutableFile(atPath: core) else { return "请先下载 sing-box 内核" }
        let helper = quote(Paths.helper), rootCore = quote(Paths.rootCore)
        let script = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "(\(helper) stop >/dev/null 2>&1 || true)",
            "cp -f \(quote(src)) \(helper)",
            "cp -f \(quote(core)) \(rootCore)",
            "(xattr -c \(helper) \(rootCore) || true)",
            "chown root:wheel \(helper) \(rootCore)",
            "chmod 4755 \(helper)",
            "chmod 755 \(rootCore)",
        ].joined(separator: " && ")
        return runPrivileged(script)
    }

    static func uninstall() -> String? {
        let script = [
            "(\(quote(Paths.helper)) stop >/dev/null 2>&1 || true)",
            "rm -f \(quote(Paths.helper)) \(quote(Paths.rootCore))",
            "rm -rf '/Library/Application Support/GlassVPN' /Library/Logs/GlassVPN",
        ].joined(separator: " && ")
        return runPrivileged(script)
    }

    /// 成功返回 nil, 否则返回错误描述
    private static func runPrivileged(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: 用户在授权对话框点了取消
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "已取消" }
        return error[NSAppleScript.errorMessage] as? String ?? "授权失败"
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum TCPPing {
    /// 未连接时的近似延迟: 到节点端口的 TCP 握手耗时
    static func measure(host: String, port: Int, timeout: Double = 3) async -> Int? {
        guard port > 0, port <= 65535, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let queue = DispatchQueue(label: "glassvpn.ping")
            let once = Once()
            let start = DispatchTime.now().uptimeNanoseconds
            let finish: (Int?) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
                case .failed, .waiting, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// 保证 continuation 只 resume 一次
    private final class Once {
        private var done = false
        private let lock = NSLock()

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
