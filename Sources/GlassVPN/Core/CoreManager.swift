//
// CoreManager.swift
// GlassVPN
// sing-box 内核管理: 应用包内自带一份 (Contents/MacOS/sing-box), 启动时安装到数据目录;
// 也可从 GitHub Releases 更新或导入本地文件。
//

import Foundation

@MainActor
final class CoreManager: ObservableObject {

    @Published private(set) var version: String?
    /// TUN 特权组件里那份 root 内核的版本
    @Published private(set) var rootVersion: String?
    @Published private(set) var busy = false
    @Published var message: String?

    /// 生成的配置使用 1.12 引入的 DNS 服务器新格式
    static let minimumVersion = [1, 12, 0]

    init() {
        // 同步执行: 启动流程紧接着用 isInstalled 判断是否弹出引导窗口
        Self.installBundledIfNeeded()
        refresh()
    }

    /// 打包脚本写入 Info.plist 的内置内核版本; BUNDLE_CORE=0 打包时为空
    nonisolated static var bundledVersion: String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "GVPNCoreVersion") as? String, !v.isEmpty else {
            return nil
        }
        return v
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.core.path) }

    var isOutdated: Bool {
        guard let version else { return false }
        return !Self.atLeast(version, Self.minimumVersion)
    }

    func refresh() {
        Task {
            let result = await Task.detached {
                (CoreManager.readVersion(Paths.core.path), CoreManager.readVersion(Paths.rootCore))
            }.value
            version = result.0
            rootVersion = result.1
        }
    }

    func download(mirror: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            message = "正在查询最新版本…"
            let asset = try await Self.latestAsset()
            message = "正在下载 sing-box \(asset.tag)…"
            guard let url = URL(string: SubscriptionFetcher.withMirror(asset.url, mirror: mirror)) else {
                throw AppError("下载地址无效")
            }
            let (file, response) = try await URLSession.shared.download(from: url)
            // async 版 download 不会自动删除临时文件
            defer { try? FileManager.default.removeItem(at: file) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw AppError("下载失败，HTTP \(code)") }
            try await Task.detached { try CoreManager.installArchive(file) }.value
            message = "已安装 sing-box \(asset.tag)"
            refresh()
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }

    /// 支持直接选择 sing-box 可执行文件或官方 .tar.gz 包
    func importLocal(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            try await Task.detached {
                if url.lastPathComponent.hasSuffix(".tar.gz") || url.pathExtension == "tgz" {
                    try CoreManager.installArchive(url)
                } else {
                    try CoreManager.placeBinary(url)
                }
            }.value
            message = "已导入本地内核"
            refresh()
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 后台执行

    nonisolated static func readVersion(_ path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let r = Shell.run(path, ["version"])
        // 首行形如 "sing-box version 1.12.4"
        guard r.status == 0, let line = r.output.split(separator: "\n").first else { return nil }
        return line.split(separator: " ").last.map(String.init)
    }

    /// 数据目录里没有内核, 或已装版本比内置的旧时, 用内置内核覆盖。
    /// 用户手动更新到更高版本后不会被降级回去。
    nonisolated static func installBundledIfNeeded() {
        guard let bundledVersion,
              let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("sing-box"),
              FileManager.default.isExecutableFile(atPath: bundled.path) else { return }
        if let installed = readVersion(Paths.core.path), atLeast(installed, numbers(bundledVersion)) { return }
        // 失败时保持现状, 用户仍可在设置中下载或导入
        try? placeBinary(bundled)
    }

    nonisolated static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    nonisolated static func atLeast(_ version: String, _ minimum: [Int]) -> Bool {
        let parts = numbers(version)
        // 1.12.0-beta.1 之类的预发布后缀会拆出多余数字, 只比较前三段
        for (a, b) in zip(parts.prefix(3) + [0, 0, 0], minimum.prefix(3)) where a != b {
            return a > b
        }
        return true
    }

    nonisolated static func latestAsset() async throws -> (tag: String, url: String) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases/latest")!,
                             timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            throw AppError("无法解析 GitHub 发布信息（可能触发了访问频率限制，可稍后重试或导入本地文件）")
        }
        #if arch(arm64)
        let suffix = "-darwin-arm64.tar.gz"
        #else
        let suffix = "-darwin-amd64.tar.gz"
        #endif
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(suffix) == true }),
              let url = asset["browser_download_url"] as? String else {
            throw AppError("发布 \(tag) 中没有适用于本机的文件")
        }
        return (tag, url)
    }

    nonisolated static func installArchive(_ archive: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("glassvpn-core-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let r = Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
        guard r.status == 0 else { throw AppError("解压失败：\(r.output)") }
        // 官方包内目录名形如 sing-box-1.12.4-darwin-arm64/sing-box
        let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "sing-box" }
        guard let found else { throw AppError("压缩包中没有 sing-box 可执行文件") }
        try placeBinary(found)
    }

    nonisolated static func placeBinary(_ src: URL) throws {
        let fm = FileManager.default
        let dst = Paths.core
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dst.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: src, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        // 浏览器下载的文件带隔离属性, 直接执行会被 Gatekeeper 拦截
        Shell.run("/usr/bin/xattr", ["-c", staging.path])
        guard readVersion(staging.path) != nil else {
            try? fm.removeItem(at: staging)
            throw AppError("不是有效的 sing-box 可执行文件（请确认架构匹配本机）")
        }
        // 先校验再替换, 运行中的旧内核不受影响
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: staging, to: dst)
    }
}
