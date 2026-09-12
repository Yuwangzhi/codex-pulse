import Foundation
import Testing
@testable import CodexPulseCore

private func event(_ type: String, at seconds: Int, extra: [String: Any] = [:], kind: String = "event_msg") -> Data {
    var payload = extra; payload["type"] = type
    return try! JSONSerialization.data(withJSONObject: ["type": kind, "timestamp": "2026-09-12T12:00:\(String(format: "%02d", seconds))Z", "payload": payload])
}
private let base = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!

@Test func lifecycleAndSilence() {
    var p = RolloutProjection()
    p.consume(event("task_started", at: 0, extra: ["turn_id": "a"]))
    #expect(p.state(now: base.addingTimeInterval(10)) == .running)
    #expect(p.state(now: base.addingTimeInterval(121)) == .quiet)
    p.consume(event("task_complete", at: 20, extra: ["turn_id": "a"]))
    #expect(p.state(now: base.addingTimeInterval(1000)) == .completed)
}

@Test func unrelatedTurnCannotCompleteCurrentTask() {
    var p = RolloutProjection()
    p.consume(event("task_started", at: 0, extra: ["turn_id": "new"]))
    p.consume(event("task_complete", at: 1, extra: ["turn_id": "old"]))
    #expect(p.state(now: base.addingTimeInterval(2)) == .running)
    p.consume(event("turn_aborted", at: 3, extra: ["turn_id": "new"]))
    #expect(p.state(now: base.addingTimeInterval(4)) == .interrupted)
}

@Test func completeIsNotOverwrittenByUsage() {
    var p = RolloutProjection()
    p.consume(event("task_complete", at: 0))
    p.consume(event("token_count", at: 1, extra: ["info": ["total_token_usage": ["total_tokens": 120]]]))
    #expect(p.state(now: base.addingTimeInterval(2)) == .completed)
    #expect(p.totalTokens == 120)
}

@Test func cumulativeTokensAreNotSummed() {
    var p = RolloutProjection()
    for n in [100, 150, 150] {
        p.consume(event("token_count", at: 1, extra: ["info": ["total_token_usage": ["total_tokens": n]]]))
    }
    #expect(p.totalTokens == 150)
}

@Test func contextUsesInputAndMalformedRecordsAreIgnored() {
    var p = RolloutProjection()
    p.consume(Data("broken json".utf8))
    p.consume(event("token_count", at: 1, extra: ["info": ["last_token_usage": ["input_tokens": 50, "output_tokens": 25], "model_context_window": 200]]))
    #expect(p.contextPercent == 25)
    #expect(p.state(now: base) == .unknown)
}

@Test func incrementalReaderWaitsForCompleteLineAndHandlesTruncation() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = RolloutReader()
    let start = event("task_started", at: 0)
    try start.prefix(start.count / 2).write(to: url)
    #expect(try reader.read(url: url).state(now: base) == .unknown)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd(); try handle.write(contentsOf: start.suffix(start.count - start.count / 2) + Data([10]))
    try handle.close()
    #expect(try reader.read(url: url).state(now: base) == .running)
    try (event("task_complete", at: 2) + Data([10])).write(to: url, options: .atomic)
    #expect(try reader.read(url: url).state(now: base) == .completed)
}

@Test func tailOfLargeRolloutFindsLastLifecycle() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var bytes = Data(repeating: 32, count: 5 * 1024 * 1024)
    bytes.append(10); bytes.append(event("task_complete", at: 1)); bytes.append(10)
    try bytes.write(to: url)
    #expect(try RolloutReader().read(url: url).state(now: base) == .completed)
}

@Test func quotaWindowsUseReportedDurations() throws {
    let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1}}}"#.utf8)
    let quota = try JSONDecoder().decode(QuotaResponse.self, from: data)
    #expect(quota.rateLimits.primary?.label == "每周额度")
    #expect(quota.rateLimits.primary?.remaining == 98)
    #expect(quota.rateLimits.secondary == nil)
    #expect(quota.ordinaryUsageAllowed == nil)
    // A passed reset timestamp never synthesizes a replenished balance.
    #expect(quota.rateLimits.primary?.remaining == 98)
}

@Test func bucketsDeduplicateAndMissingBalancesStayUnknown() throws {
    let data = Data(#"{"rateLimits":{"limitId":"codex","credits":{"hasCredits":false,"unlimited":false,"balance":null}},"rateLimitsByLimitId":{"codex":{"limitId":"codex"},"spark":{"limitName":"Spark"}}}"#.utf8)
    let quota = try JSONDecoder().decode(QuotaResponse.self, from: data)
    #expect(quota.buckets.count == 2)
    #expect(quota.buckets.first?.id == "codex")
    #expect(quota.buckets.last?.id == "spark")
    #expect(quota.rateLimits.credits?.display == "未提供")
}

@Test func usageUsesLatestRecordedDateAndPreservesUnknown() throws {
    let data = Data(#"{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":[{"startDate":"2026-09-10","tokens":12},{"startDate":"2026-09-01","tokens":3}]}"#.utf8)
    let usage = try JSONDecoder().decode(AccountUsage.self, from: data)
    #expect(usage.recentDays.last?.startDate == "2026-09-10")
    #expect(usage.summary.lifetimeTokens == nil)
    #expect(DisplayFormat.tokens(nil) == "—")
}
