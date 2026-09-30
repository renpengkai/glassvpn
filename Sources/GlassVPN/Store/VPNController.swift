//
// VPNController.swift
// GlassVPN
// 连接生命周期: 生成配置 → 校验 → 启动内核 (用户态或经特权组件以 root 运行 TUN) → 等待 Clash API
// → 设置系统代理; 运行中监控流量与内核存活, 断开或退出时按相反顺序清理。
//

import Foundation

struct TrafficSample: Hashable {
    var up: Int
    var down: Int
}

@MainActor
final class VPNController: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case stopping
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接中…"
            case .connected: return "已连接"
            case .stopping: return "断开中…"
            case .failed: return "连接失败"
            }
        }

        var busy: Bool { self == .connecting || self == .stopping }
    }

    static let sampleCapacity = 60

    @Published private(set) var state: State = .idle
    @Published private(set) var up = 0
    @Published private(set) var down = 0
    @Published private(set) var totalUp: Int64 = 0
    @Published private(set) var totalDown: Int64 = 0
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var connectedAt: Date?
    /// 选中「自动选择」时 urltest 实际使用的节点
    @Published private(set) var autoNow: String?
    @Published private(set) var testing = false
    @Published private(set) var logURL = Paths.userLog

    let store: ProfileStore
    let core: CoreManager

    private var process: Process?
    private var api: ClashAPI?
    private var tunActive = false
    private var monitorTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?

    init(store: ProfileStore, core: CoreManager) {
        self.store = store
        self.core = core
        if UserDefaults.standard.bool(forKey: Settings.tun) { logURL = Paths.rootLog }
    }

    // MARK: - 连接

    func toggle() async {
        switch state {
        case .connected: await disconnect()
        case .idle, .failed: await connect()
        default: break
        }
    }

    func connect() async {
        switch state {
        case .idle, .failed: break
        default: return
        }
        state = .connecting
        samples = []
        totalUp = 0
        totalDown = 0
        do {
            try await start()
            connectedAt = Date()
            state = .connected
            startMonitoring()
        } catch {
            await teardown()
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        guard state == .connected || state == .connecting else {
            if case .failed = state { state = .idle }
            return
        }
        state = .stopping
        await teardown()
        state = .idle
    }

    func reconnect() async {
        guard state == .connected else { return }
        await disconnect()
        await connect()
    }

    // MARK: - 运行中操作

    func select(_ tag: String) {
        store.select(node: tag)
        guard state == .connected, let api else { return }
        Task {
            try? await api.select(tag)
            await refreshInfo(api)
        }
    }

    func setMode(_ mode: ProxyMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Settings.mode)
        guard state == .connected, let api else { return }
        Task { try? await api.setMode(mode.rawValue) }
    }

    func switchProfile(_ id: UUID) {
        guard store.current?.id != id else { return }
        store.select(profile: id)
        Task { await reconnect() }
    }

    /// 已连接时用 Clash API 做真实 URL 测试; 未连接时退化为 TCP 握手 (跳过无法 TCP 探测的 UDP 协议)
    func testLatency() async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        let api = state == .connected ? self.api : nil
        let url = UserDefaults.standard.string(forKey: Settings.testURL) ?? ConfigBuilder.defaultTestURL
        let targets = api == nil ? store.nodes.filter { !$0.isUDP } : store.nodes
        store.latency.removeAll()
        await withTaskGroup(of: (String, Int?).self) { group in
            var next = 0
            // 限制并发, 避免几百个节点同时发起连接
            while next < min(16, targets.count) {
                let node = targets[next]
                group.addTask {
                    let ms = await VPNController.probe(node, api: api, url: url)
                    return (node.tag, ms)
                }
                next += 1
            }
            while let result = await group.next() {
                store.latency[result.0] = result.1 ?? -1
                if next < targets.count {
                    let node = targets[next]
                    group.addTask {
                        let ms = await VPNController.probe(node, api: api, url: url)
                        return (node.tag, ms)
                    }
                    next += 1
                }
            }
        }
    }

    nonisolated private static func probe(_ node: ProxyNode, api: ClashAPI?, url: String) async -> Int? {
        if let api { return await api.delay(node.tag, url: url) }
        return await TCPPing.measure(host: node.server, port: node.port)
    }

    // MARK: - 崩溃恢复与退出

    /// 上次异常退出可能遗留: 指向本应用端口的系统代理、用户态内核进程、root 内核进程
    func recover() {
        let d = UserDefaults.standard
        if d.bool(forKey: Settings.proxyApplied), Self.clearProxy() {
            d.set(false, forKey: Settings.proxyApplied)
        }
        let pid = pid_t(d.integer(forKey: Settings.corePID))
        if pid > 0, Proc.path(of: pid) == Paths.core.resolvingSymlinksInPath().path {
            kill(pid, SIGTERM)
        }
        d.removeObject(forKey: Settings.corePID)
        if PrivilegedHelper.isInstalled, PrivilegedHelper.run(["status"]).output == "running" {
            PrivilegedHelper.run(["stop"])
        }
    }

    /// applicationWillTerminate 中同步调用, 不能依赖异步任务
    func shutdownSync() {
        monitorTask?.cancel()
        infoTask?.cancel()
        let d = UserDefaults.standard
        if d.bool(forKey: Settings.proxyApplied), Self.clearProxy() {
            d.set(false, forKey: Settings.proxyApplied)
        }
        if let p = process {
            process = nil
            p.terminate()
            p.waitUntilExit()
            d.removeObject(forKey: Settings.corePID)
        }
        if tunActive {
            PrivilegedHelper.run(["stop"])
            tunActive = false
        }
    }

    // MARK: - 内部

    private func start() async throws {
        guard core.isInstalled else { throw AppError("尚未安装 sing-box 内核，请在「设置」中下载") }
        if core.isOutdated { throw AppError("sing-box 内核版本过旧（需要 1.12 及以上），请在「设置」中更新") }
        guard let profile = store.current, !profile.nodes.isEmpty else { throw AppError("没有可用节点，请先添加订阅") }

        let d = UserDefaults.standard
        let tun = d.bool(forKey: Settings.tun)
        let options = ConfigBuilder.Options(
            mode: ProxyMode(stored: d.string(forKey: Settings.mode)),
            tun: tun,
            mixedPort: d.integer(forKey: Settings.mixedPort),
            apiPort: d.integer(forKey: Settings.apiPort),
            // 每次连接随机生成, 本机其他进程无法直接操控内核
            secret: UUID().uuidString,
            allowLAN: d.bool(forKey: Settings.allowLAN),
            logLevel: d.string(forKey: Settings.logLevel) ?? "info",
            testURL: d.string(forKey: Settings.testURL) ?? ConfigBuilder.defaultTestURL,
            // TUN 模式实际运行的是特权组件里那份 root 内核, 版本可能与用户态内核不同
            coreVersion: tun ? (core.rootVersion ?? core.version) : core.version)
        let data = try ConfigBuilder.build(nodes: profile.nodes, selected: store.selectedTag, options: options)
        try data.write(to: Paths.config, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)

        let corePath = Paths.core.path, configPath = Paths.config.path
        let check = await Task.detached { Shell.run(corePath, ["check", "-c", configPath]) }.value
        guard check.status == 0 else {
            throw AppError("配置校验失败：" + LogReader.lastLines(of: check.output, 4))
        }

        logURL = tun ? Paths.rootLog : Paths.userLog
        if tun {
            guard await Task.detached(operation: { PrivilegedHelper.isReady }).value else {
                throw AppError("TUN 模式需要先在「设置」中安装特权组件")
            }
            let r = await Task.detached { PrivilegedHelper.run(["start", configPath]) }.value
            guard r.ok else { throw AppError(r.output.isEmpty ? "TUN 模式启动失败" : r.output) }
            tunActive = true
        } else {
            try launchProcess()
        }

        let api = ClashAPI(port: options.apiPort, secret: options.secret)
        self.api = api
        try await waitUntilReady(api)
        // cache_file 会记住上次的选择与模式, 以当前界面状态为准覆盖
        try? await api.select(store.selectedTag ?? "auto")
        try? await api.setMode(options.mode.rawValue)

        // TUN 已接管全部流量, 不再需要系统代理
        if !tun && d.bool(forKey: Settings.systemProxy) {
            try await setSystemProxy(port: options.mixedPort)
        }
    }

    private func launchProcess() throws {
        FileManager.default.createFile(atPath: Paths.userLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: Paths.userLog)
        let p = Process()
        p.executableURL = Paths.core
        p.arguments = ["run", "-c", Paths.config.path, "-D", Paths.support.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.processExited(proc) }
        }
        try p.run()
        process = p
        UserDefaults.standard.set(Int(p.processIdentifier), forKey: Settings.corePID)
    }

    private func processExited(_ p: Process) {
        // 主动断开时 process 已置空, 这里只处理意外退出
        guard p === process else { return }
        process = nil
        UserDefaults.standard.removeObject(forKey: Settings.corePID)
        guard state == .connected else { return }
        let reason = LogReader.lastLines(Paths.userLog, 3)
        Task {
            await teardown()
            state = .failed("内核意外退出" + (reason.isEmpty ? "" : "：\(reason)"))
        }
    }

    private func waitUntilReady(_ api: ClashAPI) async throws {
        // 首次启动需要下载规则集, 可能要十几秒
        let deadline = Date().addingTimeInterval(30)
        var round = 0
        while Date() < deadline {
            if await api.isAlive() { return }
            if !tunActive, process?.isRunning != true {
                throw AppError("内核启动失败：" + LogReader.lastLines(Paths.userLog, 4))
            }
            round += 1
            if tunActive, round % 10 == 0 {
                let status = await Task.detached { PrivilegedHelper.run(["status"]).output }.value
                if status != "running" { throw AppError("内核启动失败：" + LogReader.lastLines(Paths.rootLog, 4)) }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw AppError("等待内核启动超时，请查看日志")
    }

    private func setSystemProxy(port: Int) async throws {
        // 先记标记: 即使只设置成功一部分服务, 断开或下次启动也会清理
        UserDefaults.standard.set(true, forKey: Settings.proxyApplied)
        let ok = await Task.detached { () -> Bool in
            if SystemProxy.apply(port: port) { return true }
            return PrivilegedHelper.isReady && PrivilegedHelper.run(["proxy", "on", "\(port)"]).ok
        }.value
        guard ok else {
            throw AppError("无法设置系统代理：请在「设置」中安装特权组件，或关闭「系统代理」后手动使用 127.0.0.1:\(port)")
        }
    }

    nonisolated private static func clearProxy() -> Bool {
        if SystemProxy.apply(port: nil) { return true }
        return PrivilegedHelper.isReady && PrivilegedHelper.run(["proxy", "off"]).ok
    }

    private func teardown() async {
        monitorTask?.cancel()
        monitorTask = nil
        infoTask?.cancel()
        infoTask = nil
        api = nil

        // 顺序: 先撤系统代理再停内核, 避免中间出现代理指向已关闭端口导致断网
        if UserDefaults.standard.bool(forKey: Settings.proxyApplied) {
            if await Task.detached(operation: { VPNController.clearProxy() }).value {
                UserDefaults.standard.set(false, forKey: Settings.proxyApplied)
            }
        }
        if let p = process {
            process = nil
            p.terminate()
            // 等内核释放端口, 否则紧接着的重连会遇到端口占用
            for _ in 0..<20 where p.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            UserDefaults.standard.removeObject(forKey: Settings.corePID)
        }
        if tunActive {
            tunActive = false
            _ = await Task.detached { PrivilegedHelper.run(["stop"]) }.value
        }
        up = 0
        down = 0
        connectedAt = nil
        autoNow = nil
    }

    private func startMonitoring() {
        guard let api else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await s in api.traffic() {
                        self?.record(up: s.up, down: s.down)
                    }
                } catch {}
                if Task.isCancelled { return }
                // 流中断: 内核仍存活则重新订阅, 否则判定为连接断开
                if await api.isAlive() {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                guard let self, self.state == .connected else { return }
                await self.teardown()
                self.state = .failed("与内核的连接已断开，请查看日志")
                return
            }
        }
        infoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInfo(api)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func refreshInfo(_ api: ClashAPI) async {
        let selected = await api.now("proxy")
        if selected == nil || selected == "auto" {
            autoNow = await api.now("auto")
        } else {
            autoNow = nil
        }
    }

    private func record(up: Int, down: Int) {
        self.up = up
        self.down = down
        totalUp += Int64(up)
        totalDown += Int64(down)
        samples.append(TrafficSample(up: up, down: down))
        if samples.count > Self.sampleCapacity {
            samples.removeFirst(samples.count - Self.sampleCapacity)
        }
    }
}
