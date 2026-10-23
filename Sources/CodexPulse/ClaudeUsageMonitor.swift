import Foundation
import Combine
import CodexPulseCore

/// Official subscription only. Credentials are read in memory; no refresh/login writes or relay fallback.
@MainActor
final class ClaudeUsageMonitor: ObservableObject {
    @Published private(set) var snapshot: ClaudeOfficialUsage?
    @Published private(set) var error: ClaudeUsageError?
    @Published private(set) var busy = false
    private let demo: Bool
    private var stopped = false
    private var fingerprint: String?
    private var lastCheck = Date.distantPast
    private var lastFetch = Date.distantPast
    private var retryAt = Date.distantPast
    private var task: Task<Void, Never>?

    init(demo: Bool, demoSignedIn: Bool = true) {
        self.demo = demo
        if demo && demoSignedIn {
            snapshot = ClaudeOfficialUsage(
                fiveHour: ClaudeUsageWindow(usedPercent: 24, resetsAt: Date().addingTimeInterval(7200)),
                sevenDay: ClaudeUsageWindow(usedPercent: 63, resetsAt: Date().addingTimeInterval(86400 * 4)), readAt: Date())
        } else if demo { error = .signedOut }
    }
    func stop() { stopped = true; task?.cancel(); task = nil }
    func refresh(force: Bool = false, allowInteraction: Bool = false) {
        guard !demo, !stopped, !busy, force || Date().timeIntervalSince(lastCheck) >= 10 else { return }
        busy = true; lastCheck = Date()
        task = Task {
            defer { busy = false; task = nil }
            let loaded = await Task.detached(priority: .utility) {
                Result { try ClaudeUsageCredentials.load(allowInteraction: allowInteraction) }
            }.value
            guard !stopped, !Task.isCancelled else { return }
            let credentials: ClaudeUsageCredentials
            switch loaded {
            case .success(let value): credentials = value
            case .failure(let failure):
                snapshot = nil; fingerprint = nil
                error = failure as? ClaudeUsageError ?? .unavailable
                return
            }
            if fingerprint != credentials.fingerprint {
                snapshot = nil; error = nil; lastFetch = .distantPast; retryAt = .distantPast
                fingerprint = credentials.fingerprint
            }
            guard Date() >= retryAt, force || Date().timeIntervalSince(lastFetch) >= 60 else { return }
            lastFetch = Date()
            let result = await Task.detached(priority: .utility) {
                await Result<ClaudeOfficialUsage, Error>(catchingAsync: { try await ClaudeUsageService.fetch(credentials) })
            }.value
            // A sign-out/provider/account change while HTTPS was in flight must never publish the old account.
            let current = await Task.detached(priority: .utility) { Result { try ClaudeUsageCredentials.load() } }.value
            guard !stopped, !Task.isCancelled else { return }
            guard case .success(let latest) = current, latest.fingerprint == credentials.fingerprint else {
                snapshot = nil; fingerprint = nil
                if case .failure(let failure) = current { error = failure as? ClaudeUsageError ?? .unavailable }
                lastCheck = .distantPast
                return
            }
            switch result {
            case .success(let value): snapshot = value; error = nil
            case .failure(let failure):
                let failure = failure as? ClaudeUsageError ?? .unavailable
                error = failure
                switch failure {
                case .expired, .missingScope, .signedOut, .notOfficial, .authorization: snapshot = nil
                case .rateLimited(let date): retryAt = date
                default: break // Retain a same-credential snapshot with its original timestamp.
                }
            }
        }
    }
    var detail: String {
        if let error { return error.localizedDescription }
        return snapshot == nil ? "正在读取 Claude 官方订阅用量…" : "Claude 官方订阅 · 剩余比例 · 每 60 秒查询"
    }
    func isStale(now: Date) -> Bool { snapshot.map { $0.isStale(now: now) || error != nil } ?? false }
}

private extension Result where Failure == Error {
    init(catchingAsync body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
