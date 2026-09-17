import CSQLite
import Foundation
import Testing
@testable import CodexPulseCore

/// Builds a throwaway Codex home: `state_1.sqlite` plus the rollout files it points at.
private struct Fixture {
    let home: URL
    let files: [URL]

    init(threads: [(id: String, provider: String, model: String, file: String, updatedAt: Int)]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-ledger-\(UUID().uuidString)")
        home = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = threads.map { root.appendingPathComponent($0.file) }
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_1.sqlite").path, &db) == SQLITE_OK else {
            throw LocalReadError.unavailable("测试数据库创建失败")
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL)", nil, nil, nil)
        for thread in threads {
            let sql = "INSERT INTO threads (id, model_provider, model, rollout_path, updated_at) VALUES ('\(thread.id)', '\(thread.provider)', '\(thread.model)', '\(home.appendingPathComponent(thread.file).path)', \(thread.updatedAt))"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private func write(_ lines: [String], to url: URL) throws {
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func append(_ lines: [String], to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(lines.joined(separator: "\n").appending("\n").utf8))
}

private func turnContext(_ model: String, at timestamp: String) -> String {
    #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"\#(model)","turn_id":"t1"}}"#
}

/// `last_token_usage` is the per-request delta; `total_token_usage` is the thread cumulative total.
private func tokenCount(input: Int, cached: Int, output: Int, total: Int, cumulative: Int? = nil, at timestamp: String) -> String {
    let cumulativeField = cumulative.map { #","total_token_usage":{"total_tokens":\#($0)}"# } ?? ""
    return #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(total)}\#(cumulativeField)}}}"#
}

private func cumulativeOnly(_ total: Int, at timestamp: String) -> String {
    #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)}}}}"#
}

private let now = Date()
private let recent = Int(now.timeIntervalSince1970)

@Test func usageIsBucketedByEventDayAndModelWithDeltaSemantics() async throws {
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "a.jsonl", recent)])
    defer { fixture.remove() }
    try write([
        turnContext("deepseek-flash", at: "2026-09-10T00:00:00Z"),
        tokenCount(input: 100, cached: 60, output: 20, total: 120, cumulative: 120, at: "2026-09-10T00:00:01Z"),
        tokenCount(input: 10, cached: 0, output: 5, total: 15, cumulative: 135, at: "2026-09-10T00:00:05Z"),
        turnContext("deepseek-v4-pro", at: "2026-09-12T00:00:00Z"),
        tokenCount(input: 200, cached: 100, output: 30, total: 230, cumulative: 230, at: "2026-09-12T00:00:02Z")
    ], to: fixture.files[0])

    let ledger = UsageLedger(home: fixture.home, kind: .deepseek)
    let snapshot = try await ledger.snapshot()
    let dayOne = DayKey.day(fromTimestamp: "2026-09-10T00:00:01Z")!
    let dayTwo = DayKey.day(fromTimestamp: "2026-09-12T00:00:02Z")!
    #expect(snapshot.days.map(\.date) == [dayOne, dayTwo].sorted())
    #expect(snapshot.days.first?.totalTokens == 135)
    #expect(snapshot.days.first?.inputTokens == 110)
    #expect(snapshot.days.first?.cachedInputTokens == 60)
    #expect(snapshot.days.first?.outputTokens == 25)
    #expect(snapshot.days.last?.totalTokens == 230)
    #expect(snapshot.totalTokens == 365)
    #expect(snapshot.filesRead == 1)
    #expect(snapshot.truncatedFiles == 0)
    #expect(snapshot.models.map(\.model) == ["deepseek-v4-pro", "deepseek-flash"])
    #expect(snapshot.models.first?.tokens == 230)
}

@Test func ledgerFiltersByAccountKind() async throws {
    let fixture = try Fixture(threads: [
        ("t1", "deepseek", "deepseek-flash", "ds.jsonl", recent),
        ("t2", "openai", "gpt-5.6-sol", "oa.jsonl", recent)
    ])
    defer { fixture.remove() }
    try write([tokenCount(input: 10, cached: 0, output: 5, total: 15, at: "2026-09-16T00:00:01Z")], to: fixture.files[0])
    try write([tokenCount(input: 1000, cached: 0, output: 500, total: 1500, at: "2026-09-16T00:00:01Z")], to: fixture.files[1])

    let deepSeek = try await UsageLedger(home: fixture.home, kind: .deepseek).snapshot()
    #expect(deepSeek.totalTokens == 15)
    #expect(deepSeek.filesRead == 1)
    let codex = try await UsageLedger(home: fixture.home, kind: .codex).snapshot()
    #expect(codex.totalTokens == 1500)
    #expect(codex.models.map(\.model) == ["gpt-5.6-sol"])
}

@Test func appendedBytesAreReadWithoutReparsingTheFile() async throws {
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "a.jsonl", recent)])
    defer { fixture.remove() }
    let file = fixture.files[0]
    try write([tokenCount(input: 10, cached: 0, output: 5, total: 15, at: "2026-09-16T00:00:01Z")], to: file)

    let ledger = UsageLedger(home: fixture.home, kind: .deepseek)
    #expect(try await ledger.snapshot().totalTokens == 15)
    try append([tokenCount(input: 20, cached: 0, output: 10, total: 30, at: "2026-09-16T00:00:09Z")], to: file)
    #expect(try await ledger.snapshot().totalTokens == 45)
    // Re-reading without changes stays stable rather than double counting.
    #expect(try await ledger.snapshot().totalTokens == 45)
}

@Test func turnLevelModelDecidesAttributionInsideAMixedThread() async throws {
    // A session can be continued after the provider is switched, so one log can hold turns from
    // two providers. Only the DeepSeek turns belong to the DeepSeek account's usage.
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "mixed.jsonl", recent)])
    defer { fixture.remove() }
    try write([
        turnContext("deepseek-flash", at: "2026-09-10T00:00:00Z"),
        tokenCount(input: 100, cached: 0, output: 0, total: 100, at: "2026-09-10T00:00:01Z"),
        turnContext("gpt-6-astra", at: "2026-09-10T00:10:00Z"),
        tokenCount(input: 900, cached: 0, output: 0, total: 900, at: "2026-09-10T00:10:01Z"),
        turnContext("deepseek-v4-pro", at: "2026-09-10T00:20:00Z"),
        tokenCount(input: 50, cached: 0, output: 0, total: 50, at: "2026-09-10T00:20:01Z")
    ], to: fixture.files[0])
    let snapshot = try await UsageLedger(home: fixture.home, kind: .deepseek).snapshot()
    #expect(snapshot.totalTokens == 150)
    #expect(snapshot.models.map(\.model).sorted() == ["deepseek-flash", "deepseek-v4-pro"])
}

@Test func partialTrailingLineIsHeldUntilComplete() async throws {
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "a.jsonl", recent)])
    defer { fixture.remove() }
    let file = fixture.files[0]
    let complete = tokenCount(input: 10, cached: 0, output: 5, total: 15, at: "2026-09-16T00:00:01Z")
    try write([complete], to: file)
    let extra = tokenCount(input: 20, cached: 0, output: 10, total: 30, at: "2026-09-16T00:00:09Z")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(extra.dropLast(6).utf8))
    try handle.close()

    let ledger = UsageLedger(home: fixture.home, kind: .deepseek)
    #expect(try await ledger.snapshot().totalTokens == 15)
    try append([String(extra.suffix(6))], to: file)
    #expect(try await ledger.snapshot().totalTokens == 45)
}

@Test func largeFilesKeepTheTailAndReportTruncation() async throws {
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "a.jsonl", recent)])
    defer { fixture.remove() }
    let file = fixture.files[0]
    let filler = #"{"type":"response_item","timestamp":"2026-09-16T00:00:00Z","payload":{"type":"reasoning","text":""# + String(repeating: "x", count: 4096) + #""}}"#
    try write([
        tokenCount(input: 999, cached: 0, output: 0, total: 999, at: "2026-09-16T00:00:00Z"),
        filler,
        turnContext("deepseek-flash", at: "2026-09-16T00:00:29Z"),
        tokenCount(input: 10, cached: 0, output: 5, total: 15, at: "2026-09-16T00:00:30Z")
    ], to: file)

    var options = UsageLedger.Options()
    options.maxInitialBytes = 1024
    let snapshot = try await UsageLedger(home: fixture.home, kind: .deepseek, options: options).snapshot()
    #expect(snapshot.totalTokens == 15)
    #expect(snapshot.truncatedFiles == 1)
}

@Test func cumulativeOnlyRecordsUseTheDeltaBetweenReadings() async throws {
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "a.jsonl", recent)])
    defer { fixture.remove() }
    try write([
        cumulativeOnly(100, at: "2026-09-16T00:00:01Z"),
        cumulativeOnly(160, at: "2026-09-16T00:00:02Z"),
        cumulativeOnly(160, at: "2026-09-16T00:00:03Z")
    ], to: fixture.files[0])
    let snapshot = try await UsageLedger(home: fixture.home, kind: .deepseek).snapshot()
    #expect(snapshot.totalTokens == 160)
    #expect(snapshot.days.count == 1)
}

@Test func threadsOutsideTheWindowAreIgnored() async throws {
    let old = Int(now.addingTimeInterval(-60 * 86400).timeIntervalSince1970)
    let fixture = try Fixture(threads: [("t1", "deepseek", "deepseek-flash", "old.jsonl", old)])
    defer { fixture.remove() }
    try write([tokenCount(input: 10, cached: 0, output: 5, total: 15, at: "2026-09-16T00:00:01Z")], to: fixture.files[0])
    let snapshot = try await UsageLedger(home: fixture.home, kind: .deepseek).snapshot()
    #expect(snapshot.filesRead == 0)
    #expect(snapshot.totalTokens == 0)
}
