import Foundation
import Testing
@testable import CodexPulseCore

private let sampleConfig = """
# Codex 配置示例
model = "deepseek-flash"
model_provider = "deepseek"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "secret-from-config"

[model_providers."local relay"]
base_url = "https://relay.example.com/v1"
env_key = "RELAY_KEY"

[projects."/Users/someone"]
trust_level = "trusted"
"""

@Test func providerScanReadsOnlyTheFieldsPulseNeeds() {
    let scan = ProviderConfig.scan(sampleConfig)
    #expect(scan.activeProvider == "deepseek")
    #expect(scan.entries.count == 2)
    let deepseek = scan.entry(named: "deepseek")
    #expect(deepseek?.baseURL == "https://api.deepseek.com/")
    #expect(deepseek?.bearerToken == "secret-from-config")
    #expect(deepseek?.wireAPI == "responses")
    #expect(deepseek?.isDeepSeek == true)
    let relay = scan.entry(named: "local relay")
    #expect(relay?.envKey == "RELAY_KEY")
    #expect(relay?.isDeepSeek == false)
}

@Test func credentialPreferenceIsExplicitKeyThenConfigThenEnvironment() {
    let scan = ProviderConfig.scan(sampleConfig)
    let stored = ProviderConfig.resolveCredential(scan: scan, hint: "", baseURL: "", storedKey: "typed-key", environment: [:])
    #expect(stored?.token == "typed-key")
    #expect(stored?.source == .storedKey)

    let fromHint = ProviderConfig.resolveCredential(scan: scan, hint: "deepseek", baseURL: "", storedKey: nil, environment: [:])
    #expect(fromHint?.token == "secret-from-config")
    #expect(fromHint?.source == .configToken)

    let fromHost = ProviderConfig.resolveCredential(scan: scan, hint: "", baseURL: "https://api.deepseek.com", storedKey: nil, environment: [:])
    #expect(fromHost?.provider == "deepseek")

    let fromEnvironment = ProviderConfig.resolveCredential(scan: scan, hint: "local relay",
                                                           baseURL: "https://relay.example.com", storedKey: nil,
                                                           environment: ["RELAY_KEY": "env-value"])
    #expect(fromEnvironment?.token == "env-value")
    #expect(fromEnvironment?.source == .environment)

    let missing = ProviderConfig.resolveCredential(scan: ProviderConfig.scan("model = \"gpt-5\""), hint: "",
                                                   baseURL: "", storedKey: nil, environment: [:])
    #expect(missing == nil)
}

@Test func detectionSeparatesDeepSeekHomesFromCodexHomes() {
    let deepSeek = ProviderConfig.scan(sampleConfig)
    #expect(deepSeek.activeEntry?.isDeepSeek == true)
    let openai = ProviderConfig.scan("""
    model_provider = "openai"
    [model_providers.openai]
    base_url = "https://api.openai.com/v1"
    experimental_bearer_token = "openai-token"
    """)
    #expect(openai.activeEntry?.isDeepSeek == false)
}

@Test func localUsagePartitionFollowsProviderAndModel() {
    #expect(AccountKind.deepseek.matchesLocalUsage(modelProvider: "deepseek", model: "deepseek-flash"))
    #expect(AccountKind.deepseek.matchesLocalUsage(modelProvider: "custom", model: "deepseek-v4-pro"))
    #expect(AccountKind.deepseek.matchesLocalUsage(modelProvider: "", model: "DeepSeek-Chat"))
    #expect(!AccountKind.codex.matchesLocalUsage(modelProvider: "deepseek", model: "deepseek-flash"))
    #expect(AccountKind.codex.matchesLocalUsage(modelProvider: "openai", model: "gpt-5.6-sol"))
    #expect(AccountKind.codex.matchesLocalUsage(modelProvider: "", model: "gpt-6-astra"))
}

@Test func balanceDecodesStringsNumbersAndMissingFields() throws {
    let payload = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"3.50"},{"currency":"CNY","total_balance":"16.07","granted_balance":"0.00","topped_up_balance":16.07}]}"#
    let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: Data(payload.utf8))
    #expect(balance.isAvailable == true)
    #expect(balance.balanceInfos.count == 2)
    // CNY wins even though it is not the first entry.
    #expect(balance.primary?.currency == "CNY")
    #expect(balance.primary?.totalBalance == "16.07")
    #expect(balance.primary?.toppedUpBalance == "16.07")
    #expect(balance.display == "¥16.07")

    let minimal = try JSONDecoder().decode(DeepSeekBalance.self, from: Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"1.2"}]}"#.utf8))
    #expect(minimal.isAvailable == nil)
    #expect(minimal.primary?.grantedBalance == nil)
    #expect(minimal.display == "¥1.20")
}

@Test func balanceEndpointJoinsBaseAndPathSafely() {
    #expect(BalanceEndpoint.url(base: "https://api.deepseek.com", path: "/user/balance")?.absoluteString == "https://api.deepseek.com/user/balance")
    #expect(BalanceEndpoint.url(base: "https://api.deepseek.com/", path: "user/balance")?.absoluteString == "https://api.deepseek.com/user/balance")
    #expect(BalanceEndpoint.url(base: "https://relay.example.com/v1", path: "")?.absoluteString == "https://relay.example.com/v1/user/balance")
    #expect(BalanceEndpoint.url(base: "not a url", path: "/user/balance") == nil)
    #expect(BalanceEndpoint.url(base: "ftp://api.deepseek.com", path: "/user/balance") == nil)
}

@Test func balanceHistoryTracksObservedSpendAndKeepsRecentDays() {
    var history: [String: BalanceSample] = [:]
    history = BalanceHistory.record(history, day: "2026-09-17", value: 16.07)
    #expect(BalanceHistory.observedSpend(history, day: "2026-09-17") == nil)
    history = BalanceHistory.record(history, day: "2026-09-17", value: 15.95)
    let spend = BalanceHistory.observedSpend(history, day: "2026-09-17")
    #expect(spend != nil)
    #expect(abs((spend ?? 0) - 0.12) < 0.0001)
    #expect(history["2026-09-17"]?.samples == 2)

    for day in 1...30 { history = BalanceHistory.record(history, day: "2026-07-\(String(format: "%02d", day))", value: 10) }
    let trimmed = BalanceHistory.trimmed(history, keepDays: 10, day: "2026-09-17")
    #expect(trimmed.count == 10)
    #expect(trimmed["2026-09-17"] != nil)
    #expect(trimmed["2026-07-30"] != nil)
    #expect(trimmed["2026-07-01"] == nil)
}

@Test func accountConfigFallsBackToDeepSeekDefaults() {
    let account = AccountConfig(name: "", kind: .deepseek, home: "~/.codex")
    #expect(account.displayName == "DeepSeek")
    #expect(account.effectiveBaseURL == "https://api.deepseek.com")
    #expect(account.effectiveBalancePath == "/user/balance")
    #expect(account.expandedHome.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
}

@Test func registryMigratesALegacySingleAccountInstallation() throws {
    let suite = UserDefaults(suiteName: "pulse-migration-\(UUID().uuidString)")!
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try """
    model_provider = "deepseek"
    [model_providers.deepseek]
    base_url = "https://api.deepseek.com/"
    """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    suite.set(home.path, forKey: AccountRegistry.legacyHomeKey)
    suite.set("/opt/codex", forKey: AccountRegistry.legacyExecutableKey)
    let loaded = AccountRegistry.load(defaults: suite, environment: [:])
    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.kind == .deepseek)
    #expect(loaded.accounts.first?.cliPath == "/opt/codex")
    #expect(loaded.selected == loaded.accounts.first?.id)

    // A saved registry wins over legacy keys on the next launch.
    let replacement = AccountConfig(name: "工作账号", kind: .codex, home: home.path)
    AccountRegistry.save([replacement], selected: replacement.id, defaults: suite)
    let reloaded = AccountRegistry.load(defaults: suite, environment: [:])
    #expect(reloaded.accounts == [replacement])
    #expect(reloaded.selected == replacement.id)
    suite.removePersistentDomain(forName: suite.description)
}
