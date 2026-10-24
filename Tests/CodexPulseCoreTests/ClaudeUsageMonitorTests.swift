import Foundation
import Testing
@testable import CodexPulseCore

private let monitorNow = Date(timeIntervalSince1970: 1_800_000_000)
private func credential(_ token: String = "fixture-old", expiry: Date = monitorNow.addingTimeInterval(3600)) throws -> ClaudeUsageCredentials {
    let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": token, "refreshToken": "never-copy-or-use", "scopes": ["user:profile"],
        "expiresAt": expiry.timeIntervalSince1970 * 1000]])
    return try ClaudeUsageCredentials(data: data, now: monitorNow, allowExpired: true)
}
private func reading(_ used: Double = 10) -> ClaudeOfficialUsage {
    .init(fiveHour: .init(usedPercent: used, resetsAt: monitorNow.addingTimeInterval(3600)),
          sevenDay: .init(usedPercent: 20), readAt: monitorNow)
}

// All detached credential/service calls and test changes serialize through this fixture.
private final class MonitorFixture: @unchecked Sendable {
    struct State {
        var now = monitorNow
        var login: Result<ClaudeUsageCredentials, Error> = .success(try! credential())
        var result: Result<ClaudeOfficialUsage, Error> = .success(reading())
        var nextLogin: ClaudeUsageCredentials?
        var switchDuringFetch: ClaudeUsageCredentials?
        var signOutDuringFetch = false
        var cache: ClaudeUsageCache?
        var fetches = 0
        var renewals = 0
    }
    private let lock = NSLock()
    private var state = State()
    func access<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&state)
    }
    var dependencies: ClaudeUsageDependencies {
        .init(now: { self.access { $0.now } },
            load: { _ in try self.access { try $0.login.get() } },
            fetch: { _ in try self.access { s in
                s.fetches += 1
                if let next = s.switchDuringFetch { s.login = .success(next); s.switchDuringFetch = nil }
                if s.signOutDuringFetch { s.login = .failure(ClaudeUsageError.signedOut) }
                return try s.result.get()
            } },
            renew: { _ in self.access { s in
                s.renewals += 1
                if let next = s.nextLogin { s.login = .success(next) }
            } },
            readCache: { self.access { $0.cache } },
            writeCache: { cache in self.access { $0.cache = cache } })
    }
}

@MainActor @Test func expiredAccessTokenIsRenewedByCLIThenQuotaIsFetched() async throws {
    let f = MonitorFixture()
    try f.access { s in
        s.login = .success(try credential(expiry: monitorNow.addingTimeInterval(-1)))
        s.nextLogin = try credential("fixture-renewed")
    }
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(monitor.snapshot == reading())
    #expect(monitor.error == nil)
    #expect(f.access { $0.renewals == 1 && $0.fetches == 1 })
}

@MainActor @Test func nearExpiryRenewsBeforeItBlanksTheQuota() async throws {
    let f = MonitorFixture()
    try f.access { $0.login = .success(try credential(expiry: monitorNow.addingTimeInterval(45))) }
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(f.access { $0.renewals == 1 })
    #expect(monitor.snapshot == reading()) // Even a failed pre-emptive renewal can use the valid token.
}

@MainActor @Test func failedRenewalPreservesCacheAndManualRefreshRespectsBackoff() async throws {
    let f = MonitorFixture(), expired = try credential(expiry: monitorNow.addingTimeInterval(-1))
    f.access { $0.login = .success(expired); $0.cache = .init(fingerprint: expired.fingerprint, snapshot: reading()) }
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    for _ in 0..<3 { monitor.refresh(force: true); await monitor.waitForRefresh() }
    #expect(monitor.snapshot == reading())
    #expect(monitor.error == .expired)
    #expect(monitor.isStale(now: monitorNow))
    #expect(f.access { $0.renewals == 1 && $0.fetches == 0 })
    try f.access { $0.now = monitorNow.addingTimeInterval(301); $0.nextLogin = try credential("renewed") }
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(f.access { $0.renewals == 2 && $0.fetches == 1 })
    #expect(monitor.error == nil)
}

@MainActor @Test func networkFailureAndRestartKeepTimestampUntilSuccessfulRecovery() async throws {
    let f = MonitorFixture()
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    f.access { $0.result = .failure(ClaudeUsageError.unavailable); $0.now = monitorNow.addingTimeInterval(180) }
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(monitor.snapshot?.readAt == monitorNow)
    #expect(monitor.isStale(now: monitorNow.addingTimeInterval(180)))
    monitor.stop()
    let reopened = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    #expect(reopened.snapshot == nil) // Cache has not yet been matched to a credential.
    reopened.refresh(); await reopened.waitForRefresh()
    #expect(reopened.snapshot == reading())
    f.access { $0.result = .success(reading(25)) }
    reopened.refresh(force: true); await reopened.waitForRefresh()
    #expect(reopened.snapshot == reading(25))
    #expect(reopened.error == nil)
}

@MainActor @Test func switchingAccountDoesNotReusePersistedQuotaOrInFlightResponse() async throws {
    let f = MonitorFixture()
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    try f.access { $0.switchDuringFetch = try credential("different-account") }
    monitor.refresh(force: true); await monitor.waitForRefresh()
    #expect(monitor.snapshot == nil)
    #expect(f.access { $0.cache == nil })
    f.access { $0.result = .success(reading(75)) }
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(monitor.snapshot == reading(75))
}

@MainActor @Test func signOutInFlightClearsSavedQuota() async {
    let f = MonitorFixture()
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    f.access { $0.signOutDuringFetch = true }
    monitor.refresh(force: true); await monitor.waitForRefresh()
    #expect(monitor.snapshot == nil)
    #expect(monitor.error == .signedOut)
    #expect(f.access { $0.cache == nil })
}

@MainActor @Test func keychainLockRetainsExistingReadingAndUnlockRecoversAutomatically() async throws {
    let f = MonitorFixture()
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    f.access { $0.login = .failure(ClaudeUsageError.authorization) }
    monitor.refresh(force: true); await monitor.waitForRefresh()
    #expect(monitor.snapshot == reading())
    #expect(monitor.error == .authorization)
    try f.access { $0.login = .success(try credential()) }
    monitor.refresh(force: true); await monitor.waitForRefresh()
    #expect(monitor.error == nil)
}

@MainActor @Test func usage401SchedulesOneRenewalAnd429RespectsServerRetryTime() async throws {
    let f = MonitorFixture()
    f.access { $0.result = .failure(ClaudeUsageError.expired) }
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    monitor.refresh(); await monitor.waitForRefresh()
    try f.access {
        $0.now = monitorNow.addingTimeInterval(11); $0.nextLogin = try credential("rotated")
        $0.result = .failure(ClaudeUsageError.rateLimited(monitorNow.addingTimeInterval(600)))
    }
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(f.access { $0.renewals == 1 && $0.fetches == 2 })
    monitor.refresh(force: true); await monitor.waitForRefresh()
    #expect(f.access { $0.fetches == 2 })
    f.access { $0.now = monitorNow.addingTimeInterval(601); $0.result = .success(reading()) }
    monitor.refresh(); await monitor.waitForRefresh()
    #expect(monitor.error == nil)
}

@MainActor @Test func refreshesCoalesceAndStoppedMonitorDoesNotStartWork() async {
    let f = MonitorFixture()
    let monitor = ClaudeUsageMonitor(demo: false, dependencies: f.dependencies)
    for _ in 0..<10 { monitor.refresh(force: true) }
    await monitor.waitForRefresh()
    #expect(f.access { $0.fetches == 1 })
    monitor.stop(); monitor.refresh(force: true)
    #expect(f.access { $0.fetches == 1 })
}

@Test func quotaCacheContainsNoCredentialOrIdentity() throws {
    let login = try credential()
    let cache = ClaudeUsageCache(fingerprint: login.fingerprint, snapshot: reading())
    let data = try JSONEncoder().encode(cache)
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in ["fixture-old", "accessToken", "refreshToken", "never-copy-or-use", "account"] {
        #expect(!text.contains(forbidden))
    }
    #expect(try JSONDecoder().decode(ClaudeUsageCache.self, from: data) == cache)
}

@Test func renewalProtocolHasNoPromptAndExcludesRelayEnvironment() throws {
    let rows = try ClaudeLoginRenewal.input.split(separator: 0x0A).map {
        try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0["type"] as? String == "control_request" && $0["message"] == nil })
    #expect((rows[0]["request"] as? [String: Any])?["subtype"] as? String == "initialize")
    #expect((rows[1]["request"] as? [String: Any])?["subtype"] as? String == "get_usage")
    #expect((rows[1]["request"] as? [String: Any])?["skip_behaviors"] as? Bool == true)
    let directory = URL(fileURLWithPath: "/tmp/synthetic-claude-profile")
    let env = ClaudeLoginRenewal.environment(directory: directory, inherited: [
        "HOME": "/tmp/synthetic-home", "ANTHROPIC_BASE_URL": "https://relay.example",
        "ANTHROPIC_AUTH_TOKEN": "relay-secret", "CLAUDE_CODE_OAUTH_TOKEN": "other-secret",
        "CLAUDE_CODE_USE_BEDROCK": "1", "NODE_OPTIONS": "unwanted-preload"])
    #expect(env["CLAUDE_CONFIG_DIR"] == directory.path)
    #expect(env["HOME"] == "/tmp/synthetic-home")
    #expect(env.count == 2)
    #expect(ClaudeLoginRenewal.arguments.contains("--safe-mode"))
    #expect(ClaudeLoginRenewal.arguments.contains("--no-session-persistence"))
}

@Test func renewalRequiresMatchingSuccessfulControlResponse() throws {
    let good = Data((#"{"type":"control_response","response":{"request_id":"ai-pulse-auth-init","subtype":"success"}}"# + "\n"
        + #"{"type":"control_response","response":{"request_id":"ai-pulse-auth-usage","subtype":"success"}}"#).utf8)
    try ClaudeLoginRenewal.validate(good)
    for raw in ["{}", "", #"{"type":"assistant"}"#,
                #"{"type":"control_response","response":{"request_id":"other","subtype":"success"}}"#,
                #"{"type":"control_response","response":{"request_id":"ai-pulse-auth-init","subtype":"error"}}"#] {
        #expect(throws: (any Error).self) { try ClaudeLoginRenewal.validate(Data(raw.utf8)) }
    }
}

@Test func cliControlInputIsDeliveredAndClosedWithoutShellExpansion() throws {
    let output = try KeychainCredentialReader.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
        timeout: 2, input: ClaudeLoginRenewal.input, environment: ["PATH": "/usr/bin:/bin"],
        directory: FileManager.default.temporaryDirectory)
    #expect(output == ClaudeLoginRenewal.input.dropLast())
}
