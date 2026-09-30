//
// main.swift
// gvpnhelper
// setuid root 特权组件, 由 GlassVPN 安装到 /Library/PrivilegedHelperTools。
// 只接受固定的几个命令: 以 root 启停 TUN 模式的 sing-box, 以及在普通权限不足时设置系统代理。
//
//   gvpnhelper version
//   gvpnhelper start <config.json>
//   gvpnhelper stop
//   gvpnhelper status
//   gvpnhelper proxy on <port> | proxy off
//

import Foundation

let helperVersion = "1"
let corePath = "/Library/PrivilegedHelperTools/io.github.renpengkai.glassvpn.core"
let workDir = "/Library/Application Support/GlassVPN"
let logDir = "/Library/Logs/GlassVPN"
let logPath = logDir + "/core.log"
let pidPath = "/var/run/io.github.renpengkai.glassvpn.pid"
/// 子进程只拿到最小环境, 调用方的环境变量不会带进 root 进程
let safeEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = safeEnvironment
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - 内核进程

func runningPID() -> pid_t? {
    guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
          kill(pid, 0) == 0 else { return nil }
    // pid 可能已被系统复用, 确认可执行文件确实是内核再操作
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf) == corePath else { return nil }
    return pid
}

func stopCore() {
    defer { try? FileManager.default.removeItem(atPath: pidPath) }
    guard let pid = runningPID() else { return }
    kill(pid, SIGTERM)
    // 给内核时间清理 TUN 路由, 超时再强杀
    for _ in 0..<30 where kill(pid, 0) == 0 {
        usleep(100_000)
    }
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
}

func startCore(configPath: String) -> Never {
    stopCore()
    guard let data = FileManager.default.contents(atPath: configPath),
          var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail("无法读取配置文件")
    }
    // 内核以 root 运行: 去掉可写任意路径的字段, 日志走标准输出, 缓存固定写到 root 目录
    if var log = config["log"] as? [String: Any] {
        log.removeValue(forKey: "output")
        config["log"] = log
    }
    if var experimental = config["experimental"] as? [String: Any] {
        if var cache = experimental["cache_file"] as? [String: Any] {
            cache["path"] = workDir + "/cache.db"
            experimental["cache_file"] = cache
        }
        config["experimental"] = experimental
    }

    let fm = FileManager.default
    try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    guard let sanitized = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
        fail("配置序列化失败")
    }
    let rootConfig = workDir + "/config.json"
    // 配置含节点密码, 仅 root 可读
    guard fm.createFile(atPath: rootConfig, contents: sanitized, attributes: [.posixPermissions: 0o600]) else {
        fail("无法写入 \(rootConfig)")
    }
    // 日志需要让应用 (普通用户) 读取
    fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o644])
    guard let log = FileHandle(forWritingAtPath: logPath) else { fail("无法写入日志 \(logPath)") }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: corePath)
    p.arguments = ["run", "-c", rootConfig, "-D", workDir]
    p.environment = safeEnvironment
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = log
    p.standardError = log
    do {
        try p.run()
    } catch {
        fail("内核启动失败：\(error.localizedDescription)")
    }
    try? "\(p.processIdentifier)".write(toFile: pidPath, atomically: true, encoding: .utf8)
    // 配置错误、端口占用等会让内核立即退出, 稍等确认后再返回给应用
    usleep(600_000)
    if !p.isRunning { fail("内核启动后立即退出，请查看日志") }
    // helper 退出后内核由 launchd 收养继续运行
    exit(0)
}

// MARK: - 系统代理

func networkServices() -> [String] {
    run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        .split(separator: "\n").dropFirst()
        .map(String.init)
        .filter { !$0.hasPrefix("*") && !$0.isEmpty }
}

func setProxy(port: Int?) {
    let tool = "/usr/sbin/networksetup"
    let bypass = ["127.0.0.1", "localhost", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1"]
    for s in networkServices() {
        if let port {
            run(tool, ["-setwebproxy", s, "127.0.0.1", "\(port)"])
            run(tool, ["-setsecurewebproxy", s, "127.0.0.1", "\(port)"])
            run(tool, ["-setsocksfirewallproxy", s, "127.0.0.1", "\(port)"])
            run(tool, ["-setproxybypassdomains", s] + bypass)
        } else {
            run(tool, ["-setwebproxystate", s, "off"])
            run(tool, ["-setsecurewebproxystate", s, "off"])
            run(tool, ["-setsocksfirewallproxystate", s, "off"])
        }
    }
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: gvpnhelper version | start <config> | stop | status | proxy on <port> | proxy off")
}
if command == "version" {
    print(helperVersion)
    exit(0)
}
guard geteuid() == 0 else { fail("特权组件未以 root 身份运行，请在设置中重新安装") }
// setuid 只提升了有效 uid; 把实际 uid 也切到 root, 子进程 (内核、networksetup) 才会以 root 运行
guard setgid(0) == 0, setuid(0) == 0 else { fail("切换到 root 失败") }

switch command {
case "start":
    guard args.count == 2 else { fail("usage: gvpnhelper start <config>") }
    startCore(configPath: args[1])
case "stop":
    stopCore()
case "status":
    print(runningPID() != nil ? "running" : "stopped")
case "proxy":
    if args.count == 3, args[1] == "on", let port = Int(args[2]), (1...65535).contains(port) {
        setProxy(port: port)
    } else if args.count == 2, args[1] == "off" {
        setProxy(port: nil)
    } else {
        fail("usage: gvpnhelper proxy on <port> | proxy off")
    }
default:
    fail("未知命令：\(command)")
}
