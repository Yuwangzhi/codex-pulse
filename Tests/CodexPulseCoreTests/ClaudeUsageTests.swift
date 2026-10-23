import Foundation
import Testing
@testable import CodexPulseCore

private let claudeNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func officialClaudeShowsRemainingFromUtilization() throws {
    let usage = try ClaudeOfficialUsage.decode(Data(#"{"five_hour":{"utilization":2,"resets_at":"2030-01-01T00:00:00.123Z"},"seven_day":{"utilization":0,"resets_at":null}}"#.utf8), now: claudeNow)
    let layout = QuotaStatusLayout(gpt: "96%", grok: "66%", claude: usage, now: claudeNow)
    #expect(layout.text == "GPT 96%\t98%\nGrok 66%\t100%")
    #expect(layout.right == ["98%", "100%"])
    #expect(usage.fiveHour?.resetsAt != nil)
    #expect(!usage.isStale(now: claudeNow))
    #expect(usage.isStale(now: claudeNow.addingTimeInterval(121)))
}

@Test func missingOfficialClaudeLeavesEmptyCellsAndNeverFallsBackToRelay() throws {
    let absent = QuotaStatusLayout(gpt: "96%", grok: "66%", claude: nil, now: claudeNow)
    #expect(absent.text == "GPT 96%\nGrok 66%")
    #expect(absent.right == ["", ""])
    #expect(!absent.hasRightColumn)
    let weeklyOnly = try ClaudeOfficialUsage.decode(Data(#"{"five_hour":null,"seven_day":{"utilization":63}}"#.utf8), now: claudeNow)
    let partial = QuotaStatusLayout(gpt: "—", grok: "—", claude: weeklyOnly, now: claudeNow)
    #expect(partial.right == ["", "37%"])
    #expect(partial.text == "GPT —\nGrok —\t37%")
}

@Test func missingMalformedAndExpiredClaudeWindowsDoNotBecomeZero() throws {
    for raw in [#"{}"#, #"{"five_hour":{"utilization":null}}"#, #"{"five_hour":{"utilization":true}}"#,
                #"{"seven_day":{"utilization":-1}}"#, #"{"five_hour":{"utilization":20,"resets_at":"bad"}}"#] {
        #expect(throws: ClaudeUsageError.invalidResponse) { try ClaudeOfficialUsage.decode(Data(raw.utf8), now: claudeNow) }
    }
    let expired = ClaudeUsageWindow(usedPercent: 40, resetsAt: claudeNow)
    #expect(expired.text(now: claudeNow).isEmpty)
    // Display is remaining percent; usage beyond the limit bottoms out at 0% instead of going negative.
    #expect(ClaudeUsageWindow(usedPercent: 24).text(now: claudeNow) == "76%")
    #expect(ClaudeUsageWindow(usedPercent: 105).text(now: claudeNow) == "0%")
}

@Test func relayAndAPIConfigurationsCannotExposeASavedOfficialLogin() {
    #expect(ClaudeOfficialConfiguration.isOfficial(settings: nil, environment: [:]))
    #expect(ClaudeOfficialConfiguration.isOfficial(settings: Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}"#.utf8), environment: [:]))
    for env in [["ANTHROPIC_BASE_URL":"https://relay.example"], ["ANTHROPIC_AUTH_TOKEN":"synthetic"],
                ["ANTHROPIC_API_KEY":"synthetic"], ["CLAUDE_CODE_OAUTH_TOKEN":"synthetic"],
                ["CLAUDE_CODE_USE_BEDROCK":"1"], ["CLAUDE_CODE_USE_VERTEX":"true"],
                ["ANTHROPIC_BASE_URL":"https://api.anthropic.com.evil.example"]] {
        #expect(!ClaudeOfficialConfiguration.isOfficial(settings: nil, environment: env))
        let data = try! JSONSerialization.data(withJSONObject: ["env": env])
        #expect(!ClaudeOfficialConfiguration.isOfficial(settings: data, environment: [:]))
    }
    #expect(!ClaudeOfficialConfiguration.isOfficial(settings: Data("bad".utf8), environment: [:]))
    #expect(!ClaudeOfficialConfiguration.isOfficial(settings: Data(#"{"apiKeyHelper":"helper"}"#.utf8), environment: [:]))
}

private func syntheticClaudeCredential(_ token: String = "synthetic-access", scopes: [String] = ["user:profile"], expiry: Date = claudeNow.addingTimeInterval(3600)) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token, "refreshToken": "never-use-this", "scopes": scopes, "expiresAt": expiry.timeIntervalSince1970 * 1000]])
}

@Test func claudeCredentialsRequireUsageScopeAndKeepRequestsOnOfficialHost() throws {
    let credentials = try ClaudeUsageCredentials(data: syntheticClaudeCredential(), now: claudeNow)
    let request = credentials.request()
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.httpBody == nil)
    #expect(!credentials.fingerprint.contains("synthetic-access"))
    let rotated = try ClaudeUsageCredentials(data: syntheticClaudeCredential("rotated"), now: claudeNow)
    #expect(rotated.fingerprint != credentials.fingerprint)
    #expect(throws: ClaudeUsageError.missingScope) { try ClaudeUsageCredentials(data: syntheticClaudeCredential(scopes: ["user:inference"]), now: claudeNow) }
    #expect(throws: ClaudeUsageError.expired) { try ClaudeUsageCredentials(data: syntheticClaudeCredential(expiry: claudeNow), now: claudeNow) }
    #expect(throws: ClaudeUsageError.signedOut) { try ClaudeUsageCredentials(data: Data(#"{"mcpOAuth":{}}"#.utf8), now: claudeNow) }
}

@Test func officialProfileReadIsReadOnlyAndRelaySwitchRejectsItsCachedCredential() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialFile = directory.appendingPathComponent(".credentials.json")
    let settingsFile = directory.appendingPathComponent("settings.json")
    let bytes = try syntheticClaudeCredential()
    try bytes.write(to: credentialFile)
    let environment = ["CLAUDE_CONFIG_DIR": directory.path]
    let loaded = try ClaudeUsageCredentials.load(now: claudeNow, environment: environment)
    #expect(!loaded.fingerprint.isEmpty)
    #expect(try Data(contentsOf: credentialFile) == bytes)
    try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://relay.example","ANTHROPIC_AUTH_TOKEN":"synthetic"}}"#.utf8).write(to: settingsFile)
    #expect(throws: ClaudeUsageError.notOfficial) { try ClaudeUsageCredentials.load(now: claudeNow, environment: environment) }
    #expect(try Data(contentsOf: credentialFile) == bytes)
    try FileManager.default.removeItem(at: settingsFile)
    try FileManager.default.removeItem(at: credentialFile)
    // The custom profile must not borrow a real user's global Keychain login.
    #expect(throws: ClaudeUsageError.signedOut) { try ClaudeUsageCredentials.load(now: claudeNow, environment: environment) }
}
