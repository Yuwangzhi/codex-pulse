import CodexPulseCore
import Combine
import Foundation

/// Live state for one monitored account.
///
/// Codex accounts talk to `codex app-server` (quotas + account usage) and to the local session
/// database. DeepSeek accounts talk to the DeepSeek balance endpoint and to the same local logs,
/// which are the only source of token usage for a DeepSeek-backed home. A DeepSeek account never
/// starts an app-server process, because that endpoint requires a Codex login it does not have.
@MainActor
final class AccountRuntime: ObservableObject, Identifiable {
    enum Role { case selected, background }

    let id: UUID
    private(set) var config: AccountConfig

    @Published var sessions: [SessionInfo] = []
    @Published var quota: QuotaResponse?
    @Published var accountUsage: AccountUsage?
    @Published var balance: DeepSeekBalance?
    @Published var usage: UsageSnapshot?

    @Published var connected = false
    @Published var connectionMessage = "尚未连接"
    @Published var localError: String?
    @Published var quotaError: String?
    @Published var usageError: String?
    @Published var balanceError: String?

    @Published var localUpdated: Date?
    @Published var quotaUpdated: Date?
    @Published var usageUpdated: Date?
    @Published var balanceUpdated: Date?

    @Published var credentialNotice: String?
    @Published var observedSpend: Double?
    @Published var isLive = false

    @Published private(set) var quotaBusy = false
    @Published private(set) var usageBusy = false
    @Published private(set) var balanceBusy = false

    private let rpc = RPCClient()
    private var local: LocalSessions
    private var ledger: UsageLedger
    private var localBusy = false
    private var ledgerBusy = false
    private var tickCount = 0
    private var balanceHistory: [String: BalanceSample] = [:]
    private var lastBalanceAttempt: Date?
    private var turnCompletionPending = false
    private var localGeneration = UUID()

    static let balanceRefreshTicks = 15      // 30 秒（选中账户）
    static let backgroundBalanceTicks = 300  // 10 分钟（后台账户）
    static let quotaRefreshTicks = 30        // 60 秒
    static let serverUsageRefreshTicks = 150 // 5 分钟

    init(config: AccountConfig) {
        self.id = config.id
        self.config = config
        self.local = LocalSessions(home: config.expandedHome)
        self.ledger = UsageLedger(home: config.expandedHome, kind: config.kind)
        self.balanceHistory = Self.loadBalanceHistory(id: config.id)
        self.observedSpend = BalanceHistory.observedSpend(balanceHistory, day: DayKey.format(Date()))
        self.connectionMessage = config.kind == .deepseek ? "正在读取 DeepSeek 余额…" : "正在连接 Codex…"
        rpc.onReady = { [weak self] in
            guard let self else { return }
            self.connected = true
            self.connectionMessage = "已连接 Codex"
            self.refreshQuota(); self.refreshServerUsage()
        }
        rpc.onDisconnect = { [weak self] message in
            guard let self, self.isLive else { return }
            self.connected = false
            self.connectionMessage = message
        }
        rpc.onNotification = { [weak self] method, _ in
            guard let self else { return }
            if method == "account/rateLimits/updated" { self.refreshQuota() }
            if method == "account/updated" {
                // Never leave another account's balances on screen after a login switch.
                self.quota = nil; self.accountUsage = nil
                self.quotaUpdated = nil; self.usageUpdated = nil
                self.refreshQuota(); self.refreshServerUsage()
            }
        }
    }

    // MARK: - Lifecycle

    func startLive() {
        isLive = true
        tickCount = 0
        if config.kind == .codex {
            rpc.start(home: config.expandedHome, cliPath: config.cliPath)
        } else {
            connected = true
            connectionMessage = "DeepSeek · 余额接口"
            refreshBalance(force: true)
        }
        refreshLocal()
        refreshLedger()
    }

    func stopLive() {
        isLive = false
        rpc.stop()
        if config.kind == .deepseek { connected = false }
    }

    /// Rebuilds the runtime against an edited account. Any stale snapshot is dropped so the UI
    /// never shows one account's numbers under another account's name.
    func update(config: AccountConfig) {
        let homeChanged = config.expandedHome != self.config.expandedHome
        let kindChanged = config.kind != self.config.kind
        self.config = config
        guard homeChanged || kindChanged else { return }
        stopLive()
        // Readers are bound to a directory and a provider split; an edited account gets new ones.
        local = LocalSessions(home: config.expandedHome)
        ledger = UsageLedger(home: config.expandedHome, kind: config.kind)
        localGeneration = UUID(); localBusy = false; ledgerBusy = false
        sessions = []; quota = nil; accountUsage = nil; balance = nil; usage = nil
        localUpdated = nil; quotaUpdated = nil; usageUpdated = nil; balanceUpdated = nil
        localError = nil; quotaError = nil; usageError = nil; balanceError = nil
    }

    func tick(role: Role) {
        tickCount += 1
        let selected = role == .selected
        if selected {
            refreshLocal()
            refreshLedger()
            if turnCompletionPending {
                turnCompletionPending = false
                if config.kind == .deepseek { refreshBalance(force: true) }
            }
        }
        switch config.kind {
        case .codex:
            guard selected else { return }
            if tickCount % Self.quotaRefreshTicks == 0 { refreshQuota() }
            if tickCount % Self.serverUsageRefreshTicks == 0 { refreshServerUsage() }
            if !connected, tickCount % 20 == 0 { rpc.start(home: config.expandedHome, cliPath: config.cliPath) }
        case .deepseek:
            let interval = selected ? Self.balanceRefreshTicks : Self.backgroundBalanceTicks
            if tickCount % interval == 0 { refreshBalance() }
        }
    }

    /// Manual refresh (⌘R): everything this account can read, regardless of cadence.
    func refreshAll(role: Role) {
        if role == .selected { refreshLocal(); refreshLedger() }
        switch config.kind {
        case .codex:
            if role == .selected {
                if !connected { rpc.start(home: config.expandedHome, cliPath: config.cliPath) }
                else { refreshQuota(); refreshServerUsage() }
            }
        case .deepseek:
            refreshBalance(force: true)
        }
    }

    // MARK: - Local sessions

    private func refreshLocal() {
        guard isLive, !localBusy else { return }
        localBusy = true
        let reader = local
        let generation = localGeneration
        Task { [weak self] in
            let result: Result<[SessionInfo], Error>
            do { result = .success(try await reader.read()) } catch { result = .failure(error) }
            guard let self, self.localGeneration == generation else { return }
            self.localBusy = false
            switch result {
            case .success(let sessions):
                self.apply(sessions: sessions)
            case .failure(let error):
                self.localError = error.localizedDescription
                self.sessions = self.sessions.map { var item = $0; item.state = .unknown; return item }
            }
        }
    }

    private func apply(sessions updated: [SessionInfo]) {
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        let finished = updated.contains { session in
            session.state == .completed && previous[session.id] != nil && previous[session.id] != .completed
        }
        if finished { turnCompletionPending = true }
        sessions = updated
        localError = nil
        localUpdated = Date()
    }

    private func refreshLedger() {
        guard isLive, !ledgerBusy else { return }
        ledgerBusy = true
        let ledger = self.ledger
        Task { [weak self] in
            let result: Result<UsageSnapshot, Error>
            do { result = .success(try await ledger.snapshot()) } catch { result = .failure(error) }
            guard let self else { return }
            self.ledgerBusy = false
            switch result {
            case .success(let snapshot): self.usage = snapshot
            case .failure(let error): self.usage = nil; self.localError = self.localError ?? error.localizedDescription
            }
        }
    }

    // MARK: - Codex account side

    private func refreshQuota() {
        guard config.kind == .codex, rpc.ready, !quotaBusy else { return }
        quotaBusy = true
        rpc.request("account/rateLimits/read") { [weak self] result in
            guard let self else { return }
            self.quotaBusy = false
            switch result.flatMap({ data in Result { try JSONDecoder().decode(QuotaResponse.self, from: data) } }) {
            case .success(let quota): self.quota = quota; self.quotaUpdated = Date(); self.quotaError = nil
            case .failure: self.quotaError = "额度读取失败；保留上次快照，请在 Codex 中确认登录状态。"
            }
        }
    }

    private func refreshServerUsage() {
        guard config.kind == .codex, rpc.ready, !usageBusy else { return }
        usageBusy = true
        rpc.request("account/usage/read") { [weak self] result in
            guard let self else { return }
            self.usageBusy = false
            switch result.flatMap({ data in Result { try JSONDecoder().decode(AccountUsage.self, from: data) } }) {
            case .success(let usage): self.accountUsage = usage; self.usageUpdated = Date(); self.usageError = nil
            case .failure: self.usageError = "账号用量暂不可用；此接口需要受支持的 Codex 登录方式。"
            }
        }
    }

    // MARK: - DeepSeek account side

    private func refreshBalance(force: Bool = false) {
        guard config.kind == .deepseek, !balanceBusy else { return }
        if !force, let last = lastBalanceAttempt, Date().timeIntervalSince(last) < 5 { return }
        balanceBusy = true
        lastBalanceAttempt = Date()
        let account = config
        let storedKey = KeychainStore.key(for: id)
        Task { [weak self] in
            do {
                let result = try await DeepSeekClient.fetchBalance(account: account, storedKey: storedKey)
                guard let self else { return }
                self.balanceBusy = false
                guard self.config == account else { return }
                self.apply(balance: result)
            } catch {
                guard let self else { return }
                self.balanceBusy = false
                self.balanceError = error.localizedDescription
            }
        }
    }

    private func apply(balance result: DeepSeekClient.Result, now: Date = Date()) {
        balance = result.balance
        balanceUpdated = now
        balanceError = nil
        credentialNotice = "凭据来源 · \(result.source.rawValue)（\(result.provider)），仅本机内存使用"
        guard let amount = result.balance.amount else { return }
        let day = DayKey.format(now)
        balanceHistory = BalanceHistory.trimmed(BalanceHistory.record(balanceHistory, day: day, value: amount),
                                                keepDays: 60, day: day)
        Self.saveBalanceHistory(balanceHistory, id: id)
        observedSpend = BalanceHistory.observedSpend(balanceHistory, day: day)
    }

    private static func historyKey(_ id: UUID) -> String { "balanceHistory." + id.uuidString }

    private static func loadBalanceHistory(id: UUID) -> [String: BalanceSample] {
        guard let data = UserDefaults.standard.data(forKey: historyKey(id)) else { return [:] }
        return (try? JSONDecoder().decode([String: BalanceSample].self, from: data)) ?? [:]
    }

    private static func saveBalanceHistory(_ history: [String: BalanceSample], id: UUID) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey(id))
    }

    // MARK: - Demo

    /// Synthetic values for `--demo`. Nothing here touches the network, the CLI or local logs.
    func loadDemoData() {
        connected = true
        isLive = false
        localUpdated = Date(); quotaUpdated = Date(); usageUpdated = Date(); balanceUpdated = Date()
        let titles = config.kind == .deepseek
            ? ["接入 DeepSeek 余额接口", "核对本机用量账本", "整理多账户切换"]
            : ["构建 macOS 菜单栏应用", "验证数据处理流水线", "整理研究笔记"]
        sessions = titles.enumerated().map { index, title in
            var item = SessionInfo(id: "demo-\(config.kind.rawValue)-\(index)", title: title,
                                   cwd: "/Projects/\(["codex-pulse", "data-pipeline", "research"][index])",
                                   model: config.kind == .deepseek ? "deepseek-flash" : "gpt-5.6-sol",
                                   rolloutPath: "", updatedAt: Date(), totalTokens: config.kind == .deepseek ? 24_800_000 : 126_000)
            item.state = index == 2 ? .completed : .running
            item.activity = ["正在调用工具 · swift build", "正在运行验证", "本轮任务已完成"][index]
            item.lastEventAt = Date().addingTimeInterval(-Double(index * 15))
            item.turnTokens = config.kind == .deepseek ? 8_400_000 : 42_000
            item.contextPercent = Double(18 + index * 9)
            return item
        }
        usage = Self.demoUsage(kind: config.kind)
        switch config.kind {
        case .codex:
            connectionMessage = "演示数据 · Codex app-server"
            quota = try? JSONDecoder().decode(QuotaResponse.self, from: Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1893456000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1893801600},"credits":{"hasCredits":true,"unlimited":false,"balance":"128.50"},"planType":"pro"},"ordinaryUsageAllowed":true,"rateLimitResetCredits":{"availableCount":1}}"#.utf8))
            quota?.rateLimits.primary?.resetsAt = Date().addingTimeInterval(7200).timeIntervalSince1970
            quota?.rateLimits.secondary?.resetsAt = Date().addingTimeInterval(3 * 86400).timeIntervalSince1970
            accountUsage = try? JSONDecoder().decode(AccountUsage.self, from: Data(#"{"summary":{"lifetimeTokens":124800000,"peakDailyTokens":12400000,"currentStreakDays":12},"dailyUsageBuckets":[{"startDate":"2026-09-06","tokens":3100000},{"startDate":"2026-09-07","tokens":6500000},{"startDate":"2026-09-08","tokens":4200000},{"startDate":"2026-09-09","tokens":9200000},{"startDate":"2026-09-10","tokens":7800000},{"startDate":"2026-09-11","tokens":12400000},{"startDate":"2026-09-12","tokens":8600000}]}"#.utf8))
        case .deepseek:
            connectionMessage = "演示数据 · DeepSeek 余额接口"
            balance = DeepSeekBalance(isAvailable: true, balanceInfos: [
                DeepSeekBalanceInfo(currency: "CNY", totalBalance: "16.07", grantedBalance: "0.00", toppedUpBalance: "16.07")
            ])
            observedSpend = 0.38
            credentialNotice = "凭据来源 · config.toml（deepseek），仅本机内存使用"
        }
    }

    private static func demoUsage(kind: AccountKind) -> UsageSnapshot {
        let day = DayKey.format(Date())
        let values: [Int64] = kind == .deepseek
            ? [1_820_000, 6_450_000, 3_120_000, 9_800_000, 5_240_000, 12_600_000, 8_400_000]
            : [3_100_000, 6_500_000, 4_200_000, 9_200_000, 7_800_000, 12_400_000, 8_600_000]
        var snapshot = UsageSnapshot()
        snapshot.windowDays = 30
        snapshot.generatedAt = Date()
        snapshot.todayKey = day
        snapshot.filesRead = 8
        snapshot.days = values.enumerated().map { offset, tokens in
            var entry = UsageDay(date: DayKey.format(Date().addingTimeInterval(-Double(6 - offset) * 86400)))
            entry.totalTokens = tokens
            entry.inputTokens = Int64(Double(tokens) * 0.82)
            entry.cachedInputTokens = Int64(Double(tokens) * 0.61)
            entry.outputTokens = tokens - entry.inputTokens
            return entry
        }
        snapshot.models = kind == .deepseek
            ? [UsageModelShare(model: "deepseek-flash", tokens: 31_200_000), UsageModelShare(model: "deepseek-v4-pro", tokens: 16_210_000)]
            : [UsageModelShare(model: "gpt-5.6-sol", tokens: 43_800_000), UsageModelShare(model: "gpt-5.5", tokens: 3_000_000)]
        return snapshot
    }
}
