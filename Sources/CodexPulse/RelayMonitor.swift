import Foundation
import Combine
import CodexPulseCore

private final class NoRelayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RelayBalanceState {
    var quota: RelayQuota?
    var unitsPerDollar: Double?
    var currency: String?
    var exchangeRate: Double = 1
    var updated: Date?
    var error: String?
    func amount(_ raw: Double?) -> String {
        guard let raw else { return "—" }
        guard let unitsPerDollar, unitsPerDollar > 0, let currency else {
            return String(format: "%.0f 额度单位", raw)
        }
        return DisplayFormat.money(raw / unitsPerDollar * exchangeRate, currency: currency)
    }
}

/// Independent of the selected Codex account. No model calls, no hooks, no proxy changes.
@MainActor
final class RelayMonitor: ObservableObject {
    @Published private(set) var snapshot: RelaySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var balances: [String: RelayBalanceState] = [:]
    @Published var days = 1 { didSet { if days != oldValue { snapshot = nil; error = nil; refresh() } } }
    @Published var providerID = ""
    @Published var balanceEnabled = UserDefaults.standard.object(forKey: "relayBalanceEnabled") as? Bool ?? true {
        didSet {
            guard !demo else { return }
            UserDefaults.standard.set(balanceEnabled, forKey: "relayBalanceEnabled")
            if balanceEnabled { refreshBalances(force: true) }
            else { balanceTask?.cancel(); balanceTask = nil; balances = [:] }
        }
    }
    private let demo: Bool
    private var busy = false
    private var balancesBusy = false
    private var balanceTask: Task<Void, Never>?
    private var lastBalanceAttempt: Date?
    private var tickNumber = 0
    private var stopped = false
    private var generation = 0

    init(demo: Bool) { self.demo = demo; if demo { loadDemo() } }
    var requests: [RelayRequest] {
        (snapshot?.requests ?? []).filter { providerID.isEmpty || $0.providerID == providerID }
    }
    var totals: RelayTotals { RelayTotals(requests) }
    var todayTotals: RelayTotals {
        RelayTotals((snapshot?.requests ?? []).filter { Calendar.current.isDateInToday($0.date) })
    }
    var providers: [RelayProvider] {
        guard let snapshot else { return [] }
        // Include providers removed from CC Switch so their historical spend stays visible.
        let known = Set(snapshot.providers.map(\.id))
        let missing = Set(snapshot.requests.map(\.providerID)).subtracting(known).sorted()
        return snapshot.providers + missing.map { RelayProvider(id: $0, name: "历史 / 未归属提供商") }
    }
    func name(_ id: String) -> String { providers.first { $0.id == id }?.name ?? "历史 / 未归属提供商" }
    func start() { guard !demo else { return }; stopped = false; refresh() }
    func stop() { stopped = true; balanceTask?.cancel() }
    func tick() {
        guard !demo, !stopped else { return }
        tickNumber += 1
        if tickNumber % 3 == 0 { refresh() }
        if tickNumber % 30 == 0 { refreshBalances(force: false) }
    }
    func refresh() {
        guard !demo, !stopped else { return }
        generation += 1
        let requestGeneration = generation
        // A changed range queues a fresh read even if the prior one is in flight.
        guard !busy else { return }
        busy = true
        let start = Calendar.current.startOfDay(for: Date())
        let since = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: start) ?? start
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try RelayDatabase.read(since: since) } }.value
            guard let self else { return }
            self.busy = false
            guard !self.stopped else { return }
            if requestGeneration != self.generation { self.refresh(); return }
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot; self.error = nil
                if !self.providerID.isEmpty, !self.providers.contains(where: { $0.id == self.providerID }) { self.providerID = "" }
                self.refreshBalances(force: false)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func refreshBalances(force: Bool) {
        guard !demo, !stopped, balanceEnabled, !balancesBusy, let snapshot else { return }
        if !force, let lastBalanceAttempt, Date().timeIntervalSince(lastBalanceAttempt) < 60 { return }
        self.lastBalanceAttempt = Date(); balancesBusy = true
        let providers = snapshot.providers
        balanceTask = Task { [weak self] in
            defer { self?.balancesBusy = false }
            // A credential/config fingerprint is intentionally not persisted. Re-read on each poll.
            var next: [String: RelayBalanceState] = [:]
            var fetched: [String: RelayBalanceState] = [:]
            for provider in providers {
                guard !Task.isCancelled else { return }
                // Only query the two New API deployments verified on this machine.
                guard let host = URL(string: provider.baseURL)?.host,
                      ["4router.net", "api.zzshu.cc"].contains(host) else {
                    next[provider.id] = RelayBalanceState(error: "未接入该提供商额度接口")
                    continue
                }
                do {
                    guard let credential = try await Task.detached(priority: .utility, operation: {
                        try RelayDatabase.credential(providerID: provider.id)
                    }).value else {
                        next[provider.id] = RelayBalanceState(error: "未找到该提供商的查询凭据")
                        continue
                    }
                    guard credential.baseURL.host == host else {
                        next[provider.id] = RelayBalanceState(error: "提供商配置已变更，等待重新同步")
                        continue
                    }
                    // Only deduplicate identical credentials within this refresh, in memory.
                    let identity = credential.baseURL.absoluteString + "\n" + credential.token
                    if let cached = fetched[identity] { next[provider.id] = cached; continue }
                    let state = try await Self.fetchBalance(baseURL: credential.baseURL, token: credential.token)
                    next[provider.id] = state; fetched[identity] = state
                } catch {
                    guard !Task.isCancelled else { return }
                    // Do not forward raw URLs, headers, or remote error bodies to UI/diagnostics.
                    let message: String
                    if let error = error as? URLError {
                        message = "额度网络查询失败（\(error.code.rawValue)），稍后重试"
                    } else if let failure = error as? RelayFetchFailure {
                        message = "额度接口返回 HTTP \(failure.status)"
                    } else { message = "中转额度返回格式暂不兼容" }
                    next[provider.id] = RelayBalanceState(error: message)
                }
            }
            guard let self, !self.stopped, self.balanceEnabled, !Task.isCancelled else { return }
            self.balances = next
        }
    }

    private struct RelayFetchFailure: Error { var status: Int }

    private static func fetchBalance(baseURL: URL, token: String) async throws -> RelayBalanceState {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 18
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRelayRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = baseURL.appendingPathComponent("api/usage/token", isDirectory: true)
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RelayFetchFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var state = RelayBalanceState(quota: try RelayQuota(data: data), updated: Date())
        // Public site metadata defines units and currency. Missing metadata means raw units.
        if let (data, response) = try? await session.data(from: baseURL.appendingPathComponent("api/status")),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let metadata = root["data"] as? [String: Any],
           let units = (metadata["quota_per_unit"] as? NSNumber)?.doubleValue, units > 0,
           let currency = metadata["quota_display_type"] as? String, ["USD", "CNY"].contains(currency) {
            if currency == "USD" { state.unitsPerDollar = units; state.currency = currency }
            else if let exchange = (metadata["usd_exchange_rate"] as? NSNumber)?.doubleValue, exchange > 0 {
                state.unitsPerDollar = units; state.currency = currency; state.exchangeRate = exchange
            }
        }
        return state
    }

    func diagnostics() -> [String: Any] {
        ["readOK": error == nil && snapshot != nil, "providers": providers.count,
         "requests": snapshot?.requests.count ?? 0, "importedRowsExcluded": snapshot?.importedRequests ?? 0,
         "todayTokens": todayTotals.tokens, "todayEstimatedUSD": todayTotals.cost,
         "balancesAvailable": balances.values.filter { $0.quota != nil }.count,
         "balanceErrors": balances.values.compactMap(\.error),
         "timedGenerationRequests": requests.filter { $0.generationSpeed != nil }.count,
         "throughputAvailable": totals.throughput != nil]
    }

    private func loadDemo() {
        var snapshot = RelaySnapshot()
        snapshot.providers = [RelayProvider(id: "a", name: "示例中转 · Claude", baseURL: "https://example.invalid", current: true)]
        snapshot.requests = (0..<12).map { i in
            RelayRequest(id: "demo-\(i)", providerID: "a", model: "claude-opus-demo", input: 1000, output: 600,
                         cacheRead: 2400, cacheWrite: 200, cost: 0.018, latencyMS: 18000, firstTokenMS: 3000,
                         durationMS: nil, status: i == 3 ? 429 : 200, streaming: true,
                         date: Date().addingTimeInterval(-Double(i) * 60))
        }
        snapshot.importedRequests = 5
        self.snapshot = snapshot
        let data = Data(#"{"data":{"object":"token_usage","unlimited_quota":true,"total_used":1250000,"user_quota":{"total_available":8750000}}}"#.utf8)
        balances["a"] = RelayBalanceState(quota: try? RelayQuota(data: data), unitsPerDollar: 500000, currency: "USD", updated: Date())
    }
}
