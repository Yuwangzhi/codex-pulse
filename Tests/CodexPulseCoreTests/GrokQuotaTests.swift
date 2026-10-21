import Foundation
import Testing
@testable import CodexPulseCore

private let grokNow = Date(timeIntervalSince1970: 1_800_000_000)
private let grokSlot = "auth0|synthetic-user"
private func grokToken(subject: String = grokSlot) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["sub": subject])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "synthetic.\(payload).signature"
}
private func grokStore(active: String? = GrokQuotaCredentials.scope(for: grokSlot),
                       record: [String: String]) throws -> [String: Any] {
    let scope = GrokQuotaCredentials.scope(for: grokSlot)
    let accounts: [String: Any] = ["active": active as Any? ?? NSNull(), "accounts": [scope: record]]
    return ["cursor-accounts": String(decoding: try JSONSerialization.data(withJSONObject: accounts), as: UTF8.self)]
}

@Test func grokCredentialsReadOnlyTheActiveAccountAndVerifyTokenSubject() throws {
    let store = try grokStore(record: ["cursor-access-token": "encrypted", "cursor-refresh-token": "must-not-read"])
    var reads: [String] = []
    let credentials = try GrokQuotaCredentials.decode(store: store, accountSlot: grokSlot) {
        reads.append($0); return try grokToken()
    }
    #expect(reads == ["encrypted"])
    #expect(credentials.teamID == nil)
    #expect(throws: GrokQuotaError.accountChanged) {
        try GrokQuotaCredentials.decode(store: store, accountSlot: "auth0|other") { _ in Issue.record("Must not decrypt another account"); return "" }
    }
    #expect(throws: GrokQuotaError.accountChanged) {
        try GrokQuotaCredentials.decode(store: store, accountSlot: grokSlot) { _ in try grokToken(subject: "other") }
    }
    #expect(throws: GrokQuotaError.signedOut) {
        try GrokQuotaCredentials.decode(store: try grokStore(active: nil, record: [:]), accountSlot: grokSlot) { _ in "" }
    }
}

@Test func grokScopedSecretsAndTeamSelectionStayBoundToTheAccount() throws {
    let scope = GrokQuotaCredentials.scope(for: grokSlot)
    let credentials = try GrokQuotaCredentials.decode(store: grokStore(record: [
        "cursor-access-token": "scoped:v1:\(scope):token", "cursor-selected-team-id": "team"
    ]), accountSlot: grokSlot) { $0 == "token" ? try grokToken() : "42" }
    #expect(credentials.teamID == 42)
    let changed = try GrokQuotaCredentials.decode(store: grokStore(record: [
        "cursor-access-token": "token", "cursor-selected-team-id": "other-team"
    ]), accountSlot: grokSlot) { $0 == "token" ? try grokToken() : "43" }
    #expect(credentials.selectionID != changed.selectionID)
    #expect(throws: GrokQuotaError.accountChanged) {
        try GrokQuotaCredentials.decode(store: grokStore(record: ["cursor-access-token": "scoped:v1:other:token"]), accountSlot: grokSlot) { _ in "" }
    }
}

@Test func grokSafeStorageDecryptsAKnownSyntheticElectronFixture() throws {
    let fixture = "djEw68gFYauh0kLI91NEToTFjqr0XU1TcW06PtXpryE3heI="
    #expect(try GrokQuotaCredentials.decrypt(fixture, password: Data("synthetic-test-password".utf8)) == "synthetic-access-token")
    #expect(throws: GrokQuotaError.credentials) {
        try GrokQuotaCredentials.decrypt(fixture, password: Data("wrong-password".utf8))
    }
    #expect(throws: GrokQuotaError.credentials) {
        try GrokQuotaCredentials.decrypt(Data("v11unsupported".utf8).base64EncodedString(), password: Data())
    }
}

@Test func grokQuotaRequestUsesOnlyTheOriginalServiceAndSelectedTeam() throws {
    let credentials = try GrokQuotaCredentials.decode(store: grokStore(record: [
        "cursor-access-token": "token", "cursor-selected-team-id": "team"
    ]), accountSlot: grokSlot) { $0 == "token" ? try grokToken() : "42" }
    let request = GrokQuotaAPI.request(credentials: credentials)
    #expect(request.url?.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == Data("{}".utf8))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + credentials.accessToken)
    #expect(request.value(forHTTPHeaderField: "x-cursor-team-id") == "42")
    #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
}

@Test func grokServerQuotaKeepsUnitsTimestampsAndMarksFailedOrOldReadings() throws {
    var quota = try GrokQuotaAPI.decode(Data(#"{"usagePercent":33.25,"nextResetTimestampUtc":"2026-10-26T03:11:00.123Z","grokPlanLabel":"Pro"}"#.utf8), now: grokNow)
    #expect(quota.remainingPercent == 66.75)
    #expect(quota.source == .server)
    #expect(quota.resetAt != nil)
    #expect(!quota.isStale(now: grokNow.addingTimeInterval(120)))
    #expect(quota.isStale(now: grokNow.addingTimeInterval(121)))
    quota.refreshFailed = true
    #expect(quota.isStale(now: grokNow))
    let item = QuotaMenuValue.grok(snapshot: GrokBotSnapshot(pid: 1, appVersion: "test", signedIn: true, quota: quota), now: grokNow)
    #expect(item.detail.contains("服务端"))
    #expect(item.menuText == "Grok 66%*")
    let over = try GrokQuotaAPI.decode(Data(#"{"usagePercent":110}"#.utf8), now: grokNow)
    #expect(over.remainingPercent == 0)
}

@Test func grokMissingAndPooledQuotasRemainUnknown() {
    for text in ["{}", #"{"usagePercent":null}"#, #"{"usagePercent":-1}"#,
                 #"{"usagePercent":20,"usesPooledEnterpriseAllowance":true}"#,
                 #"{"usagePercent":20,"nextResetTimestampUtc":"bad-date"}"#] {
        #expect(throws: GrokQuotaError.invalidResponse) { try GrokQuotaAPI.decode(Data(text.utf8), now: grokNow) }
    }
}
