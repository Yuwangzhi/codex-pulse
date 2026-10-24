import Foundation
import Combine

public struct ClaudeUsageDependencies {
    public var now: () -> Date
    public var load: @Sendable (Bool) throws -> ClaudeUsageCredentials
    public var fetch: @Sendable (ClaudeUsageCredentials) async throws -> ClaudeOfficialUsage
    public var renew: @Sendable (URL) throws -> Void
    public var readCache: () -> ClaudeUsageCache?
    public var writeCache: (ClaudeUsageCache?) -> Void

    public static var live: Self {
        let key = "claudeOfficialUsageCache.v1"
        return Self(now: Date.init,
            load: { try ClaudeUsageCredentials.load(allowInteraction: $0, allowExpired: true) },
            fetch: { try await ClaudeUsageService.fetch($0) },
            renew: { try ClaudeLoginRenewal.renew(directory: $0) },
            readCache: {
                guard let data = UserDefaults.standard.data(forKey: key), data.count < 16 * 1024 else { return nil }
                return try? JSONDecoder().decode(ClaudeUsageCache.self, from: data)
            }, writeCache: { value in
                if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            })
    }
}

@MainActor
public final class ClaudeUsageMonitor: ObservableObject {
    @Published public private(set) var snapshot: ClaudeOfficialUsage?
    @Published public private(set) var error: ClaudeUsageError?
    @Published public private(set) var busy = false
    private let demo: Bool
    private let dependencies: ClaudeUsageDependencies
    private var stopped = false
    private var fingerprint: String?
    private var lastCheck = Date.distantPast
    private var lastFetch = Date.distantPast
    private var retryAt = Date.distantPast
    private var renewalAt = Date.distantPast
    private var needsRenewal = false
    private var task: Task<Void, Never>?

    public init(demo: Bool, demoSignedIn: Bool = true, dependencies: ClaudeUsageDependencies = .live) {
        self.demo = demo; self.dependencies = dependencies
        if demo && demoSignedIn {
            snapshot = ClaudeOfficialUsage(
                fiveHour: ClaudeUsageWindow(usedPercent: 24, resetsAt: Date().addingTimeInterval(7200)),
                sevenDay: ClaudeUsageWindow(usedPercent: 63, resetsAt: Date().addingTimeInterval(86400 * 4)), readAt: Date())
        } else if demo { error = .signedOut }
    }
    public func stop() { stopped = true; task?.cancel(); task = nil }
    public func refresh(force: Bool = false, allowInteraction: Bool = false) {
        let now = dependencies.now()
        guard !demo, !stopped, !busy, force || now.timeIntervalSince(lastCheck) >= 10 else { return }
        busy = true; lastCheck = now
        task = Task {
            defer { busy = false; task = nil }
            await update(force: force, allowInteraction: allowInteraction)
        }
    }

    /// Tests can await the real refresh state machine without polling the user's UI or services.
    public func waitForRefresh() async { await task?.value }

    private func credentials(allowInteraction: Bool = false) async -> Result<ClaudeUsageCredentials, Error> {
        let load = dependencies.load
        return await Task.detached(priority: .utility) { Result { try load(allowInteraction) } }.value
    }
    private func accept(_ value: ClaudeUsageCredentials) {
        guard fingerprint != value.fingerprint else { return }
        fingerprint = value.fingerprint
        snapshot = nil; error = nil; lastFetch = .distantPast; retryAt = .distantPast; needsRenewal = false
        // Do not display any persisted quota until the current credential has been identified.
        if let cache = dependencies.readCache(), cache.fingerprint == value.fingerprint {
            snapshot = cache.snapshot
        } else { dependencies.writeCache(nil) }
    }
    private func credentialFailure(_ failure: Error) {
        let failure = failure as? ClaudeUsageError ?? .unavailable
        error = failure
        switch failure {
        case .signedOut, .missingScope, .notOfficial:
            snapshot = nil; fingerprint = nil; dependencies.writeCache(nil)
        default: break // A locked Keychain or temporary expiry does not erase the last verified reading.
        }
    }
    private func update(force: Bool, allowInteraction: Bool) async {
        let loaded = await credentials(allowInteraction: allowInteraction)
        guard !stopped, !Task.isCancelled else { return }
        var value: ClaudeUsageCredentials
        switch loaded {
        case .success(let loaded): value = loaded; accept(loaded)
        case .failure(let failure): credentialFailure(failure); return
        }
        let now = dependencies.now()
        if (needsRenewal || value.expiresAt <= now.addingTimeInterval(60)), now >= renewalAt {
            renewalAt = now.addingTimeInterval(300) // Manual clicks cannot create a renewal loop.
            let renew = dependencies.renew, directory = value.directory
            _ = await Task.detached(priority: .utility) { Result { try renew(directory) } }.value
            guard !stopped, !Task.isCancelled else { return }
            // CLI success alone is insufficient: its persisted access token must now be usable.
            let reloaded = await credentials()
            guard !stopped, !Task.isCancelled else { return }
            switch reloaded {
            case .success(let latest): value = latest; accept(latest)
            case .failure(let failure): credentialFailure(failure); return
            }
        }
        guard value.expiresAt > dependencies.now() else { error = .expired; return }
        guard dependencies.now() >= retryAt,
              force || dependencies.now().timeIntervalSince(lastFetch) >= 60 else { return }
        lastFetch = dependencies.now()
        let fetch = dependencies.fetch, currentValue = value
        let result = await Task.detached(priority: .utility) {
            await Result<ClaudeOfficialUsage, Error>(catchingAsync: { try await fetch(currentValue) })
        }.value
        // A sign-out/account rotation in flight must not publish the previous account's response.
        let current = await credentials()
        guard !stopped, !Task.isCancelled else { return }
        guard case .success(let latest) = current else {
            if case .failure(let failure) = current { credentialFailure(failure) }
            return
        }
        guard latest.fingerprint == value.fingerprint else {
            accept(latest); lastCheck = .distantPast; return
        }
        switch result {
        case .success(let usage):
            snapshot = usage; error = nil; needsRenewal = false
            dependencies.writeCache(ClaudeUsageCache(fingerprint: value.fingerprint, snapshot: usage))
        case .failure(let failure):
            let failure = failure as? ClaudeUsageError ?? .unavailable
            error = failure
            switch failure {
            case .expired: needsRenewal = true; lastFetch = .distantPast
            case .missingScope, .signedOut, .notOfficial: credentialFailure(failure)
            case .rateLimited(let date): retryAt = date
            default: break
            }
        }
    }
    public var detail: String {
        if let error { return error.localizedDescription }
        return snapshot == nil ? "正在读取 Claude 官方订阅用量…" : "Claude 官方订阅 · 剩余比例 · 每 60 秒查询 · 独立于 CC Switch 路由"
    }
    public func isStale(now: Date) -> Bool { snapshot.map { $0.isStale(now: now) || error != nil } ?? false }
}

private extension Result where Failure == Error {
    init(catchingAsync body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
