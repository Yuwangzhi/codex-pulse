import Foundation
import Testing
@testable import CodexPulseCore

private let quotaNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func gptMenuUsesTightestWindowAndFlagsAnOfflineSnapshot() throws {
    let data = Data(#"{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":80,"windowDurationMins":10080}}"#.utf8)
    let bucket = try JSONDecoder().decode(QuotaBucket.self, from: data)
    let current = QuotaMenuValue.gpt(bucket: bucket, updatedAt: quotaNow, connected: true,
                                    hasError: false, accountName: "Test GPT", now: quotaNow)
    #expect(current.value == "20%")
    #expect(current.detail.contains("每周额度"))
    #expect(!current.stale)
    let offline = QuotaMenuValue.gpt(bucket: bucket, updatedAt: quotaNow, connected: false,
                                    hasError: false, accountName: "Test GPT", now: quotaNow)
    #expect(offline.menuText == "GPT 20%*")
}

@Test func claudeMenuNeverSubstitutesUsedOrUnlimitedForMissingBalance() throws {
    let noBalance = try RelayQuota(data: Data(#"{"data":{"object":"token_usage","unlimited_quota":true,"total_used":5000000}}"#.utf8))
    let provider = RelayProvider(id: "current", name: "Current provider", current: true)
    let result = QuotaMenuValue.claude(provider: provider, quota: noBalance, unitsPerDollar: 500000,
                                      currency: "USD", updatedAt: quotaNow, hasError: false, now: quotaNow)
    #expect(result.value == "—")
    #expect(result.detail.contains("未返回账户余额"))
    let accountBalance = try RelayQuota(data: Data(#"{"data":{"object":"token_usage","unlimited_quota":true,"user_quota":{"total_available":3500000}}}"#.utf8))
    let known = QuotaMenuValue.claude(provider: provider, quota: accountBalance, unitsPerDollar: 500000,
                                     currency: "USD", updatedAt: quotaNow, hasError: false, now: quotaNow)
    #expect(known.value == "$7.00")
    #expect(!known.value.contains("Key"))
}

@Test func claudeKeyQuotaRetainsItsScopeAndUnknownCurrencyUnit() throws {
    let quota = try RelayQuota(data: Data(#"{"data":{"object":"token_usage","unlimited_quota":false,"total_available":1250000}}"#.utf8))
    let result = QuotaMenuValue.claude(provider: RelayProvider(id: "a", name: "Key provider"), quota: quota,
                                      unitsPerDollar: nil, currency: nil, updatedAt: quotaNow,
                                      hasError: false, now: quotaNow)
    #expect(result.value == "Key 1250000单位")
    #expect(result.detail.contains("Key 剩余额度"))
    #expect(!result.value.contains("$"))
}

@Test func grokMenuFlagsOldCacheAndDoesNotExposeASignedOutAccount() {
    var snapshot = GrokBotSnapshot(pid: 1, appVersion: "test", signedIn: true,
                                   quota: GrokBotQuota(usedPercent: 14, readAt: quotaNow.addingTimeInterval(-301)))
    #expect(QuotaMenuValue.grok(snapshot: snapshot, now: quotaNow).menuText == "Grok 86%*")
    snapshot.signedIn = false
    #expect(QuotaMenuValue.grok(snapshot: snapshot, now: quotaNow).value == "—")
}
