import AppKit
import CodexPulseCore
import Combine
import ServiceManagement

@MainActor
final class MonitorStore: ObservableObject {
    @Published var selectedTab = 0
    @Published var taskFilter = "全部"
    @Published var showExtraQuotas = false
    @Published var sessions: [SessionInfo] = []
    @Published var quota: QuotaResponse?
    @Published var usage: AccountUsage?
    @Published var connected = false
    @Published var connectionMessage = "正在连接 Codex…"
    @Published var localError: String?
    @Published var quotaError: String?
    @Published var usageError: String?
    @Published var quotaUpdated: Date?
    @Published var usageUpdated: Date?
    @Published var localUpdated: Date?
    @Published var now = Date()
    @Published var settingsError: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var homePath: String
    @Published var executablePath: String
    let isDemo: Bool
    private let rpc = RPCClient()
    private var local: LocalSessions
    private var localBusy = false
    private var quotaBusy = false
    private var usageBusy = false
    private var timer: Timer?
    private var tick = 0
    private var stopping = false
    private var localGeneration = UUID()

    var runningCount: Int { sessions.filter { $0.state == .running }.count }
    var quietCount: Int { sessions.filter { $0.state == .quiet }.count }
    var quotaStale: Bool { quotaUpdated.map { now.timeIntervalSince($0) > 120 } ?? true }
    var statusLabel: String {
        let active = localError == nil ? "\(runningCount)" : "?"
        guard let remaining = quota?.rateLimits.primary?.remaining, !quotaStale, quotaError == nil, connected else { return "\(active) · —" }
        return "\(active) · \(Int(remaining))%"
    }

    init(demo: Bool = false) {
        isDemo = demo
        let home = Self.configuredHome()
        homePath = home.path
        executablePath = RPCClient.locateCLI()?.path ?? ""
        local = LocalSessions(home: home)
        if demo { loadDemo(); return }
        rpc.onReady = { [weak self] in
            guard let self else { return }
            self.connected = true; self.connectionMessage = "已连接 Codex"
            self.refreshQuota(); self.refreshUsage()
        }
        rpc.onDisconnect = { [weak self] message in
            guard let self, !self.stopping else { return }
            self.connected = false; self.connectionMessage = message
        }
        rpc.onNotification = { [weak self] method, _ in
            if method == "account/rateLimits/updated" { self?.refreshQuota() }
            if method == "account/updated" {
                // Do not leave another account's balances on screen after a login switch.
                self?.quota = nil; self?.usage = nil
                self?.quotaUpdated = nil; self?.usageUpdated = nil
                self?.refreshQuota(); self?.refreshUsage()
            }
        }
    }

    static func configuredHome() -> URL {
        let configured = UserDefaults.standard.string(forKey: "codexHome")
        let path = configured.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
        return path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func start() {
        guard !isDemo else { return }
        rpc.start(home: Self.configuredHome()); refreshLocal()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date(); self.tick += 1; self.refreshLocal()
                if self.tick % 30 == 0 { self.refreshQuota() }
                if self.tick % 150 == 0 { self.refreshUsage() }
                if !self.connected && self.tick % 20 == 0 { self.rpc.start(home: Self.configuredHome()) }
            }
        }
    }

    func stop() { stopping = true; timer?.invalidate(); rpc.stop() }

    func refresh() {
        guard !isDemo else { return }
        refreshLocal()
        if !connected { rpc.start(home: Self.configuredHome()) }
        else { refreshQuota(); refreshUsage() }
    }

    private func refreshLocal() {
        guard !localBusy else { return }
        localBusy = true
        let reader = local, generation = localGeneration
        Task { [weak self] in
            let result: Result<[SessionInfo], Error>
            do { result = .success(try await reader.read()) } catch { result = .failure(error) }
            guard let self, self.localGeneration == generation else { return }
            self.localBusy = false
            switch result {
            case .success(let sessions): self.sessions = sessions; self.localError = nil; self.localUpdated = Date()
            case .failure(let error):
                self.localError = error.localizedDescription
                self.sessions = self.sessions.map { var item = $0; item.state = .unknown; return item }
            }
        }
    }

    private func refreshQuota() {
        guard rpc.ready, !quotaBusy else { return }
        quotaBusy = true
        rpc.request("account/rateLimits/read") { [weak self] result in
            guard let self else { return }; self.quotaBusy = false
            switch result.flatMap({ data in Result { try JSONDecoder().decode(QuotaResponse.self, from: data) } }) {
            case .success(let quota): self.quota = quota; self.quotaUpdated = Date(); self.quotaError = nil
            case .failure: self.quotaError = "额度读取失败；保留上次快照，请在 Codex 中确认登录状态。"
            }
        }
    }

    private func refreshUsage() {
        guard rpc.ready, !usageBusy else { return }
        usageBusy = true
        rpc.request("account/usage/read") { [weak self] result in
            guard let self else { return }; self.usageBusy = false
            switch result.flatMap({ data in Result { try JSONDecoder().decode(AccountUsage.self, from: data) } }) {
            case .success(let usage): self.usage = usage; self.usageUpdated = Date(); self.usageError = nil
            case .failure: self.usageError = "账号用量暂不可用；此接口需要受支持的 Codex 登录方式。"
            }
        }
    }

    func applySettings() {
        let home = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &directory), directory.boolValue else {
            settingsError = "请选择存在的 Codex 数据目录。"; return
        }
        guard executablePath.isEmpty || FileManager.default.isExecutableFile(atPath: executablePath) else {
            settingsError = "Codex CLI 路径不是可执行文件。"; return
        }
        UserDefaults.standard.set(home.path, forKey: "codexHome")
        UserDefaults.standard.set(executablePath, forKey: "codexExecutable")
        localGeneration = UUID(); localBusy = false
        local = LocalSessions(home: home); sessions = []; quota = nil; usage = nil
        quotaUpdated = nil; usageUpdated = nil; localUpdated = nil; settingsError = nil
        connected = false; connectionMessage = "正在重新连接…"
        rpc.start(home: home); refreshLocal()
    }

    func chooseCLI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 Codex CLI 可执行文件"
        if panel.runModal() == .OK, let url = panel.url { executablePath = url.path }
    }

    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                settingsError = "请在系统设置 → 通用 → 登录项中允许 Codex Pulse。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { settingsError = "登录项设置失败，请从 Applications 中运行应用后重试。" }
    }

    private func loadDemo() {
        quota = try? JSONDecoder().decode(QuotaResponse.self, from: Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1893456000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1893801600},"credits":{"hasCredits":true,"unlimited":false,"balance":"128.50"},"planType":"pro"},"ordinaryUsageAllowed":true,"rateLimitResetCredits":{"availableCount":1}}"#.utf8))
        usage = try? JSONDecoder().decode(AccountUsage.self, from: Data(#"{"summary":{"lifetimeTokens":124800000,"peakDailyTokens":12400000,"currentStreakDays":12},"dailyUsageBuckets":[{"startDate":"2026-09-06","tokens":3100000},{"startDate":"2026-09-07","tokens":6500000},{"startDate":"2026-09-08","tokens":4200000},{"startDate":"2026-09-09","tokens":9200000},{"startDate":"2026-09-10","tokens":7800000},{"startDate":"2026-09-11","tokens":12400000},{"startDate":"2026-09-12","tokens":8600000}]}"#.utf8))
        let titles = ["构建 macOS 菜单栏应用", "验证数据处理流水线", "整理研究笔记"]
        sessions = titles.enumerated().map { i, title in
            var item = SessionInfo(id: "demo-\(i)", title: title, cwd: "/Projects/\(["codex-pulse", "data-pipeline", "research"][i])", model: "Codex", rolloutPath: "", updatedAt: Date(), totalTokens: 126000)
            item.state = i == 2 ? .completed : .running
            item.activity = ["正在调用工具 · swift build", "正在运行验证", "本轮任务已完成"][i]
            item.lastEventAt = Date().addingTimeInterval(-Double(i * 15)); item.turnTokens = 42000
            return item
        }
        connected = true; connectionMessage = "演示数据"; quotaUpdated = Date(); usageUpdated = Date(); localUpdated = Date()
    }
}
