import AppKit
import CodexPulseCore
import Combine
import ServiceManagement
import SwiftUI

/// Coordinates the monitored accounts and exposes the selected account's state to the UI.
///
/// Each account keeps its own `AccountRuntime` (its own connection, logs and snapshots). Only the
/// selected account is polled at full cadence. The GPT quota account keeps a lightweight
/// app-server connection even while another account is selected. DeepSeek
/// balances of background accounts are still refreshed on a slow timer because that is one cheap
/// HTTPS request; other background Codex accounts retain their cached snapshot.
@MainActor
final class MonitorStore: ObservableObject {
    // MARK: - Panel state

    @Published var selectedTab = 0
    @Published var taskFilter = "全部"
    @Published var showExtraQuotas = false
    @Published var searchText = ""
    @Published var sessionSort: SessionSort = .activity
    @Published var expandedSessionID: String?
    @Published var theme = UserDefaults.standard.string(forKey: "theme") ?? "跟随系统" {
        didSet { if !isDemo { UserDefaults.standard.set(theme, forKey: "theme") } }
    }
    @Published var compactStatus = UserDefaults.standard.bool(forKey: "compactStatus") {
        didSet { if !isDemo { UserDefaults.standard.set(compactStatus, forKey: "compactStatus") } }
    }
    @Published var floatingEnabled = UserDefaults.standard.object(forKey: "floatingEnabled") as? Bool ?? false {
        didSet { if !isDemo { UserDefaults.standard.set(floatingEnabled, forKey: "floatingEnabled") } }
    }
    var isPresentingDialog = false
    var dismissPanel: (() -> Void)?
    var revealDashboard: (() -> Void)?
    @Published var projectDirectories = UserDefaults.standard.dictionary(forKey: "projectDirectories") as? [String: String] ?? [:]
    @Published var openingProject = false
    var projectOpenRequest: UUID?
    @Published var now = Date()
    @Published var settingsError: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled

    // MARK: - Accounts

    @Published private(set) var accounts: [AccountConfig] = []
    @Published private(set) var selectedID: UUID?
    @Published var showAccountEditor = false
    @Published private(set) var editingID: UUID?
    @Published var draftName = ""
    @Published var draftKind: AccountKind = .codex {
        didSet { if draftKind != oldValue { refreshDraftNote() } }
    }
    @Published var draftHome = ""
    @Published var draftCLI = ""
    @Published var draftBaseURL = ""
    @Published var draftBalancePath = ""
    @Published var draftKey = ""
    @Published var draftHasStoredKey = false
    @Published var draftNote: String?
    @Published var accountStatus: String?

    let relay: RelayMonitor
    let agents: AgentMonitor
    let isDemo: Bool

    // MARK: - Live state

    private var runtimes: [UUID: AccountRuntime] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var timer: Timer?
    private var relaySubscription: AnyCancellable?
    private var agentSubscription: AnyCancellable?
    private var stopping = false

    var selectedRuntime: AccountRuntime? { selectedID.flatMap { runtimes[$0] } }
    var selectedAccount: AccountConfig? { accounts.first { $0.id == selectedID } }

    var sessions: [SessionInfo] { selectedRuntime?.sessions ?? [] }
    var quota: QuotaResponse? { selectedRuntime?.quota }
    var resetCreditSnapshot: ResetCreditSnapshot? { selectedRuntime?.resetCreditSnapshot }
    var usage: AccountUsage? { selectedRuntime?.accountUsage }
    var localUsage: UsageSnapshot? { selectedRuntime?.usage }
    var balance: DeepSeekBalance? { selectedRuntime?.balance }
    var connected: Bool { selectedRuntime?.connected ?? false }
    var connectionMessage: String { selectedRuntime?.connectionMessage ?? "尚未连接" }
    var localError: String? { selectedRuntime?.localError }
    var quotaError: String? { selectedRuntime?.quotaError }
    var usageError: String? { selectedRuntime?.usageError }
    var balanceError: String? { selectedRuntime?.balanceError }
    var localUpdated: Date? { selectedRuntime?.localUpdated }
    var quotaUpdated: Date? { selectedRuntime?.quotaUpdated }
    var usageUpdated: Date? { selectedRuntime?.usageUpdated }
    var balanceUpdated: Date? { selectedRuntime?.balanceUpdated }
    var credentialNotice: String? { selectedRuntime?.credentialNotice }
    var observedSpend: Double? { selectedRuntime?.observedSpend }
    var isDeepSeek: Bool { selectedAccount?.kind == .deepseek }
    var isCodex: Bool { (selectedAccount?.kind ?? .codex) == .codex }

    var runningCount: Int { sessions.filter { $0.state == .running }.count }
    var trafficSessions: [TrafficSession] {
        // A directory may be registered for more than one provider; deduplicate by session ID.
        var codex: [String: SessionInfo] = [:]
        let sources = isDemo ? (selectedRuntime.map { [$0] } ?? []) : Array(runtimes.values)
        for runtime in sources {
            for session in runtime.sessions {
                let updated = session.lastEventAt ?? session.updatedAt
                if let old = codex[session.id], (old.lastEventAt ?? old.updatedAt) >= updated { continue }
                codex[session.id] = session
            }
        }
        let rows = codex.values.compactMap { session -> TrafficSession? in
            let updated = session.lastEventAt ?? session.updatedAt
            guard now.timeIntervalSince(updated) < 3600 else { return nil }
            let phase: AgentPhase
            switch session.state {
            case .running: phase = now.timeIntervalSince(updated) > 120 ? .unknown : .running
            case .quiet, .unknown: phase = .unknown
            case .completed: phase = .completed
            case .interrupted: phase = .interrupted
            }
            return TrafficSession(id: "codex:" + session.id, agent: "Codex", project: session.project,
                                  cwd: session.cwd, phase: phase, detail: session.activity, updatedAt: updated)
        }
        var desktop: [TrafficSession] = []
        if agents.grokBotRunning {
            desktop = [TrafficSession(id: "grokbot:desktop", agent: "Grok Bot", project: "桌面客户端", cwd: "",
                                       phase: .unknown, detail: "客户端在线 · 任务状态未提供", updatedAt: now)]
        }
        return TrafficSession.sorted(rows + agents.traffic(now: now) + desktop)
    }
    func revealTrafficSession(_ session: TrafficSession? = nil) {
        selectedTab = 1
        if let session, session.agent == "Codex" {
            let id = String(session.id.dropFirst("codex:".count))
            if let account = accounts.first(where: { runtimes[$0.id]?.sessions.contains { $0.id == id } == true }) {
                selectAccount(account.id)
            }
            taskFilter = "全部"; searchText = ""; expandedSessionID = id
        }
        revealDashboard?()
    }
    var quietCount: Int { sessions.filter { $0.state == .quiet }.count }
    var completedCount: Int { sessions.filter { $0.state == .completed }.count }
    var colorScheme: ColorScheme? { theme == "深色" ? .dark : (theme == "浅色" ? .light : nil) }
    var refreshing: Bool {
        guard let runtime = selectedRuntime else { return false }
        return runtime.quotaBusy || runtime.usageBusy || runtime.balanceBusy
    }
    var filteredSessions: [SessionInfo] {
        let state: TaskState? = [.running, .quiet, .completed, .interrupted, .unknown].first { $0.label == taskFilter }
        return SessionQuery.results(sessions, search: searchText, state: state, sort: sessionSort)
    }
    func showTasks(_ filter: String) { taskFilter = filter; searchText = ""; selectedTab = 1 }

    var quotaStale: Bool { quotaUpdated.map { now.timeIntervalSince($0) > 120 } ?? true }
    var resetCreditSnapshotCurrent: Bool {
        guard let snapshot = resetCreditSnapshot, let quotaUpdated else { return false }
        let listedCreditExpired = snapshot.value.availableDetails.contains { $0.expirationDate.map { $0 <= now } ?? false }
        return snapshot.recordedAt == quotaUpdated && !quotaStale && quotaError == nil && connected && !listedCreditExpired
    }
    var balanceStale: Bool { balanceUpdated.map { now.timeIntervalSince($0) > 180 } ?? true }

    var menuGPTAccount: AccountConfig? {
        if let selectedAccount, selectedAccount.kind == .codex { return selectedAccount }
        return accounts.first { $0.kind == .codex }
    }
    var quotaMenu: [QuotaMenuValue] {
        let gpt = menuGPTAccount.flatMap { runtimes[$0.id] }
        let currentProviders = (relay.snapshot?.providers ?? []).filter(\.current)
        let provider = currentProviders.count == 1 ? currentProviders.first : nil
        let state = provider.flatMap { relay.balances[$0.id] }
        return [
            .gpt(bucket: gpt?.quota?.rateLimits, updatedAt: gpt?.quotaUpdated,
                 connected: gpt?.connected ?? false, hasError: gpt?.quotaError != nil,
                 accountName: menuGPTAccount?.displayName ?? "Codex 账户", now: now),
            .grok(snapshot: agents.grokBot, now: now),
            .claude(provider: provider, quota: state?.quota, unitsPerDollar: state?.unitsPerDollar,
                    currency: state?.currency, exchangeRate: state?.exchangeRate ?? 1, updatedAt: state?.updated,
                    hasError: relay.error != nil || state?.error != nil, now: now)
        ]
    }
    private var statusBarQuotas: [QuotaMenuValue] {
        quotaMenu.filter { $0.id == "gpt" || $0.id == "grok" }
    }
    var statusLabel: String {
        statusBarQuotas.map { "\($0.title) \($0.value)" }
            .joined(separator: "；")
    }
    var statusTooltip: String {
        statusBarQuotas.map { item in
            item.menuText + "：" + item.detail + (item.updatedAt.map { " · \(DisplayFormat.age($0, now: now))读取" } ?? "")
        }.joined(separator: "\n") + "\n* 表示上次记录或旧缓存；点击展开详情。"
    }

    var headerStatusText: String {
        switch selectedAccount?.kind ?? .codex {
        case .codex: return "已连接 · 本机任务实时监测"
        case .deepseek: return "DeepSeek · 余额每 30 秒 · 用量每 2 秒"
        }
    }

    // MARK: - Init

    init(demo: Bool = false) {
        isDemo = demo
        relay = RelayMonitor(demo: demo)
        agents = AgentMonitor(demo: demo)
        relaySubscription = relay.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        agentSubscription = agents.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if demo {
            loadDemo()
        } else {
            // User requested a quota-first menu; the floating panel remains an optional setting.
            if !UserDefaults.standard.bool(forKey: "quotaMenuLayoutV1") {
                floatingEnabled = false
                UserDefaults.standard.set(true, forKey: "quotaMenuLayoutV1")
            }
            let stored = UserDefaults.standard.data(forKey: AccountRegistry.accountsKey)
            let loaded = AccountRegistry.load()
            accounts = loaded.accounts
            selectedID = loaded.selected
            for account in accounts { _ = runtime(for: account) }
            // Persist a migrated single-account setup so its identifier (and therefore its
            // balance history) stays stable across launches.
            if stored == nil || AccountRegistry.decode(stored).isEmpty {
                AccountRegistry.save(accounts, selected: selectedID)
            }
            Self.pruneOrphanAccountHistory(accounts)
        }
    }

    /// Balance samples belong to an account identifier. Deleting an account, or a build that
    /// generated a fresh identifier, would otherwise leave unreadable entries behind forever.
    private static func pruneOrphanAccountHistory(_ accounts: [AccountConfig]) {
        let valid = Set(accounts.flatMap { ["balanceHistory." + $0.id.uuidString, "resetCredits." + $0.id.uuidString] })
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where (key.hasPrefix("balanceHistory.") || key.hasPrefix("resetCredits.")) && !valid.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
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
        selectedRuntime?.startLive()
        syncQuotaRuntime()
        relay.start()
        agents.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.now = Date()
                self.relay.tick()
                self.agents.refresh()
                for (id, runtime) in self.runtimes {
                    runtime.tick(role: self.role(for: id))
                }
            }
        }
    }

    func stop() {
        stopping = true
        relay.stop()
        agents.stop()
        timer?.invalidate()
        for runtime in runtimes.values { runtime.stopLive() }
    }

    func refresh() {
        guard !isDemo else { return }
        now = Date()
        relay.refresh()
        agents.refresh()
        relay.refreshBalances(force: true)
        for (id, runtime) in runtimes {
            runtime.refreshAll(role: role(for: id))
        }
    }

    func refreshAllAccounts() {
        guard !isDemo else { return }
        refresh()
        accountStatus = "已请求刷新：GPT 额度持续读取，选中账户读取用量，Grok 读取客户端缓存，Claude 查询当前中转额度。"
    }

    // MARK: - Runtime plumbing

    private func role(for id: UUID) -> AccountRuntime.Role {
        if id == selectedID { return .selected }
        if id == menuGPTAccount?.id { return .quotaOnly }
        return .background
    }
    private func syncQuotaRuntime() {
        guard !isDemo else { return }
        for runtime in runtimes.values where runtime.config.kind == .codex && role(for: runtime.id) == .background {
            if runtime.isLive { runtime.stopLive() }
        }
        if let account = menuGPTAccount { runtime(for: account).startLive(includeLocal: account.id == selectedID) }
    }

    @discardableResult
    private func runtime(for account: AccountConfig) -> AccountRuntime {
        if let existing = runtimes[account.id] { return existing }
        let runtime = AccountRuntime(config: account)
        // Forward nested changes so SwiftUI and the status item keep redrawing.
        subscriptions[account.id] = runtime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        runtimes[account.id] = runtime
        return runtime
    }

    func selectAccount(_ id: UUID) {
        guard selectedID != id, let account = accounts.first(where: { $0.id == id }) else { return }
        if isDemo {
            // The demo already holds a populated runtime per account; switching is display only.
            selectedID = id
            searchText = ""; expandedSessionID = nil; now = Date()
            return
        }
        let previous = selectedID
        selectedID = id
        if let previous, previous != menuGPTAccount?.id { runtimes[previous]?.stopLive() }
        AccountRegistry.save(accounts, selected: id)
        searchText = ""; expandedSessionID = nil
        runtime(for: account).startLive()
        syncQuotaRuntime()
        now = Date()
    }

    /// One line per account for the settings list: live value when available, otherwise the reason.
    func accountSummary(_ account: AccountConfig) -> String {
        guard let runtime = runtimes[account.id] else { return "尚未启用" }
        switch account.kind {
        case .codex:
            if let remaining = runtime.quota?.rateLimits.primary?.remaining {
                return "额度剩余 \(Int(remaining))% · \(DisplayFormat.age(runtime.quotaUpdated, now: now))同步"
            }
            if runtime.quotaError != nil { return "额度接口不可用（该目录需要 Codex 登录）" }
            return runtime.connectionMessage
        case .deepseek:
            if let balance = runtime.balance {
                return "余额 \(balance.display) · \(DisplayFormat.age(runtime.balanceUpdated, now: now))同步"
            }
            if let error = runtime.balanceError { return error }
            return runtime.isLive ? "正在读取余额…" : "切换到该账户后开始刷新"
        }
    }

    // MARK: - Account editing

    func beginAddAccount() {
        editingID = nil
        draftName = ""; draftKind = .codex; draftCLI = ""; draftKey = ""; draftHasStoredKey = false
        draftHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        draftBaseURL = ""; draftBalancePath = ""
        draftNote = nil
        showAccountEditor = true
        refreshDraftNote()
    }

    func beginEditAccount(_ account: AccountConfig) {
        editingID = account.id
        draftName = account.name; draftKind = account.kind; draftHome = account.home
        draftCLI = account.cliPath; draftBaseURL = account.baseURL; draftBalancePath = account.balancePath
        draftKey = ""; draftHasStoredKey = account.hasStoredKey
        showAccountEditor = true
        refreshDraftNote()
    }

    func cancelAccountEditor() {
        showAccountEditor = false
        draftKey = ""
        draftNote = nil
    }

    /// Reads the account's own `config.toml` for display: which provider was found and whether a
    /// credential is available there. The token value itself is never read into the UI.
    func refreshDraftNote() {
        let home = URL(fileURLWithPath: (draftHome as NSString).expandingTildeInPath)
        let configURL = home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            draftNote = "未找到 \(configURL.path)"
            return
        }
        let scan = ProviderConfig.scan(text)
        let active = scan.activeProvider.isEmpty ? "未设置" : scan.activeProvider
        if let entry = scan.activeEntry ?? scan.entries.first(where: \.isDeepSeek) {
            let token = entry.bearerToken.isEmpty ? "未配置 bearer token" : "已有 bearer token"
            let envKey = entry.envKey.isEmpty ? "" : " · env_key \(entry.envKey)"
            draftNote = "model_provider · \(active) · provider「\(entry.name)」\(token)\(envKey)"
        } else {
            draftNote = "model_provider · \(active) · 未在 config.toml 中找到 provider 凭据"
        }
    }

    func saveDraftAccount() {
        let home = (draftHome as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        var directory: ObjCBool = false
        guard !home.isEmpty, FileManager.default.fileExists(atPath: home, isDirectory: &directory), directory.boolValue else {
            settingsError = "请选择存在的 Codex 数据目录。"; return
        }
        let cli = (draftCLI as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        guard cli.isEmpty || FileManager.default.isExecutableFile(atPath: cli) else {
            settingsError = "Codex CLI 路径不是可执行文件。"; return
        }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        var account: AccountConfig
        if let editingID, let index = accounts.firstIndex(where: { $0.id == editingID }) {
            account = accounts[index]
            account.name = name.isEmpty ? draftKind.label : name
            account.kind = draftKind
            account.home = home
            account.cliPath = cli
            account.baseURL = draftBaseURL.trimmingCharacters(in: .whitespaces)
            account.balancePath = draftBalancePath.trimmingCharacters(in: .whitespaces)
            accounts[index] = account
        } else if let duplicate = accounts.first(where: { $0.expandedHome.path == home && $0.kind == draftKind }) {
            settingsError = "「\(duplicate.displayName)」已经使用这个目录与类型，本次未新增账户。"
            showAccountEditor = false
            return
        } else {
            account = AccountConfig(name: name.isEmpty ? draftKind.label : name, kind: draftKind, home: home, cliPath: cli,
                                    baseURL: draftBaseURL.trimmingCharacters(in: .whitespaces),
                                    balancePath: draftBalancePath.trimmingCharacters(in: .whitespaces))
            accounts.append(account)
            _ = runtime(for: account)
        }
        if account.kind == .deepseek {
            if !draftKey.trimmingCharacters(in: .whitespaces).isEmpty {
                let stored = KeychainStore.setKey(draftKey, for: account.id)
                account.hasStoredKey = stored
                if !stored { settingsError = "API Key 未能写入钥匙串，将尝试使用 config.toml 中的凭据。" }
            } else if draftHasStoredKey {
                account.hasStoredKey = KeychainStore.key(for: account.id) != nil
            }
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        }
        draftKey = ""
        runtimes[account.id]?.update(config: account)
        if selectedID == nil {
            selectedID = account.id
            accountStatus = "已选择「\(account.displayName)」作为当前账户。"
        }
        AccountRegistry.save(accounts, selected: selectedID)
        if selectedID == account.id, runtimes[account.id]?.isLive != true { runtimes[account.id]?.startLive() }
        syncQuotaRuntime()
        showAccountEditor = false
        if settingsError == nil { accountStatus = "已保存「\(account.displayName)」。" }
    }

    func deleteAccount(_ id: UUID) {
        guard !isDemo, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts.count > 1 else {
            settingsError = "至少保留一个账户。"
            return
        }
        runtimes[id]?.stopLive()
        runtimes[id] = nil
        subscriptions[id] = nil
        KeychainStore.setKey(nil, for: id)
        UserDefaults.standard.removeObject(forKey: "balanceHistory." + id.uuidString)
        UserDefaults.standard.removeObject(forKey: "resetCredits." + id.uuidString)
        accounts.remove(at: index)
        if selectedID == id {
            selectedID = accounts.first?.id
            if let next = selectedID, let account = accounts.first(where: { $0.id == next }) {
                runtime(for: account).startLive()
            }
        }
        AccountRegistry.save(accounts, selected: selectedID)
        syncQuotaRuntime()
        accountStatus = "已删除账户。"
    }

    func clearStoredKey(for id: UUID) {
        KeychainStore.setKey(nil, for: id)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].hasStoredKey = false
            runtimes[id]?.update(config: accounts[index])
        }
        draftHasStoredKey = false
        AccountRegistry.save(accounts, selected: selectedID)
        accountStatus = "已清除该账户在本机保存的 API Key。"
    }

    func chooseCLI() {
        isPresentingDialog = true
        defer { isPresentingDialog = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 Codex CLI 可执行文件"
        if panel.runModal() == .OK, let url = panel.url { draftCLI = url.path }
    }

    func chooseAccountHome() {
        isPresentingDialog = true
        defer { isPresentingDialog = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择该账户的 Codex 数据目录（通常包含 config.toml 与 state_*.sqlite）"
        let start = URL(fileURLWithPath: (draftHome as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: start.path) { panel.directoryURL = start }
        if panel.runModal() == .OK, let url = panel.url {
            draftHome = url.path
            refreshDraftNote()
        }
    }

    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                settingsError = "请在系统设置 → 通用 → 登录项中允许 AI Pulse。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { settingsError = "登录项设置失败。请从 Applications 中运行应用后重试。" }
    }

    // MARK: - Demo data

    /// Machine-readable summary for `--diagnose` / `--usage-check`.
    /// Credentials are never included: only their source label, values and error text.
    func diagnostics(detailed: Bool) -> [String: Any] {
        var summary: [String: Any] = [
            "demo": isDemo,
            "accountCount": accounts.count,
            "selected": selectedAccount?.displayName ?? "",
            "statusBar": statusLabel
        ]
        summary["relay"] = relay.diagnostics()
        summary["agentMonitor"] = [
            "claudeHooks": agents.hookStatus[.claude] ?? false,
            "grokHooks": agents.hookStatus[.grok] ?? false,
            "claudeSessions": agents.records.filter { $0.agent == .claude }.count,
            "grokSessions": agents.records.filter { $0.agent == .grok }.count,
            "floatingEnabled": floatingEnabled,
            "readOK": agents.error == nil
        ]
        summary["grokBot"] = ["running": agents.grokBotRunning, "signedIn": agents.grokBot?.signedIn ?? false,
                              "quotaCacheAvailable": agents.grokBot?.quota != nil,
                              "quotaCacheStale": agents.grokBot?.quota?.isStale(now: now) ?? true,
                              "taskStateAvailable": false]
        summary["accounts"] = accounts.map { account -> [String: Any] in
            var item: [String: Any] = [
                "name": account.displayName,
                "kind": account.kind.rawValue,
                "home": account.expandedHome.lastPathComponent,
                "directory": account.expandedHome.path,
                "selected": account.id == selectedID
            ]
            guard let runtime = runtimes[account.id] else { return item }
            item["live"] = runtime.isLive
            item["connected"] = runtime.connected
            item["sessions"] = runtime.sessions.count
            item["runningSessions"] = runtime.sessions.filter { $0.state == .running }.count
            item["localReadOK"] = runtime.localUpdated != nil
            item["quotaAvailable"] = runtime.quota != nil
            item["quotaBuckets"] = runtime.quota?.buckets.count ?? 0
            if let snapshot = runtime.resetCreditSnapshot {
                item["resetAvailableCountAtLastRead"] = snapshot.value.availableCount
                item["resetRecordedAt"] = snapshot.recordedAt.timeIntervalSince1970
                item["resetExpiresAt"] = snapshot.value.availableDetails.compactMap(\.expiresAt)
            }
            if let quota = runtime.quota, detailed {
                item["quotaPercent"] = quota.buckets.compactMap { $0.primary?.remaining }
            }
            if let error = runtime.quotaError { item["quotaError"] = error }
            item["balanceAvailable"] = runtime.balance != nil
            if let display = runtime.balance?.display { item["balance"] = display }
            if let currency = runtime.balance?.primary?.currency { item["balanceCurrency"] = currency }
            if let error = runtime.balanceError { item["balanceError"] = error }
            if let spend = runtime.observedSpend { item["observedSpendToday"] = (spend * 10_000).rounded() / 10_000 }
            if let usage = runtime.usage {
                item["usageFilesRead"] = usage.filesRead
                item["usageDays"] = usage.days.count
                item["usageWindowTokens"] = usage.totalTokens
                item["usageTodayTokens"] = usage.today?.totalTokens ?? 0
                item["usageTruncatedFiles"] = usage.truncatedFiles
                item["usageUnreadableFiles"] = usage.unreadableFiles
                item["usageModels"] = usage.models.prefix(4).map { "\($0.model):\($0.tokens)" }
                if detailed { item["usageRecentDays"] = usage.days.suffix(7).map { "\($0.date):\($0.totalTokens)" } }
            }
            if detailed { item["credential"] = runtime.credentialNotice ?? "未使用凭据" }
            return item
        }
        return summary
    }

    private func loadDemo() {
        let codex = AccountConfig(name: "Codex Pro", kind: .codex, home: "/Demo/codex", providerHint: "openai")
        let deepseek = AccountConfig(name: "DeepSeek", kind: .deepseek, home: "/Demo/codex",
                                     baseURL: ProviderConfig.defaultBaseURL, providerHint: "deepseek")
        accounts = [codex, deepseek]
        let arguments = CommandLine.arguments
        let wantCodex = arguments.contains("--kind") && arguments.contains("codex")
        selectedID = wantCodex ? codex.id : deepseek.id
        for account in accounts { runtime(for: account).loadDemoData() }
        now = Date()
    }
}
