import Foundation
import CSQLite

public struct TokenDelta: Equatable, Sendable {
    public var inputTokens: Int64 = 0
    public var cachedInputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var totalTokens: Int64 = 0
    public init(inputTokens: Int64 = 0, cachedInputTokens: Int64 = 0, outputTokens: Int64 = 0, totalTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct UsageDay: Codable, Equatable, Identifiable, Sendable {
    public var date: String
    public var totalTokens: Int64 = 0
    public var inputTokens: Int64 = 0
    public var cachedInputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var id: String { date }

    public init(date: String) { self.date = date }

    public mutating func add(_ delta: TokenDelta) {
        totalTokens += delta.totalTokens
        inputTokens += delta.inputTokens
        cachedInputTokens += delta.cachedInputTokens
        outputTokens += delta.outputTokens
    }
}

public struct UsageModelShare: Identifiable, Equatable, Sendable {
    public var model: String
    public var tokens: Int64
    public var id: String { model }
    public init(model: String, tokens: Int64) { self.model = model; self.tokens = tokens }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var days: [UsageDay] = []
    public var models: [UsageModelShare] = []
    public var windowDays: Int = 30
    public var filesRead: Int = 0
    public var truncatedFiles: Int = 0
    public var unreadableFiles: Int = 0
    public var generatedAt: Date = Date()
    public var todayKey: String = ""

    public init() {}

    public var today: UsageDay? { days.first { $0.date == todayKey } }
    public var totalTokens: Int64 { days.reduce(0) { $0 + $1.totalTokens } }
    /// Days with any recorded usage, most recent last. Used by the bar chart.
    public var recentDays: [UsageDay] { Array(days.suffix(7)) }

    public var hasData: Bool { !days.isEmpty }
}

/// Builds token usage from the account's own Codex logs.
///
/// Sources, in the order they are trusted per thread:
/// - `event_msg` / `token_count` → `info.last_token_usage` is the per-request delta.
///   (`token_usage_record.turn_token_usage` is the *cumulative* turn total and must not be summed.)
/// - when only a cumulative `total_token_usage` is present, the difference from the previous
///   cumulative value is used.
///
/// Each delta is attributed to the local calendar day of the event timestamp. Files are read
/// incrementally: the first pass keeps the tail (bounded by `maxInitialBytes`) and later passes
/// only read appended bytes, so a 2-second refresh stays cheap.
public actor UsageLedger {
    public struct Options: Sendable {
        public var windowDays: Int = 30
        /// First pass keeps the tail of a log. Long sessions can reach hundreds of megabytes, and
        /// the scan is cheap because only usage lines are parsed, so this is generous on purpose.
        public var maxInitialBytes: UInt64 = 256 * 1024 * 1024
        public var maxFiles: Int = 400
        public var maxRowsScanned: Int = 5000
        public var chunkBytes: Int = 256 * 1024
        public init() {}
    }

    private struct FileState {
        var identity: UInt64?
        var offset: UInt64 = 0
        var modified: Date?
        var pending = Data()
        var discardFirst = false
        var truncated = false
        var unreadable = false
        /// A head-truncated file cannot attribute its first partial turn; counting starts at the
        /// first `turn_context` that was actually read.
        var sawTurnContext = false
        var provider: String = ""
        var model: String = ""
        var currentModel: String = ""
        var lastCumulative: Int64?
        var days: [String: UsageDay] = [:]
        /// day → model → tokens, so model shares follow the same window as the daily buckets.
        var modelDays: [String: [String: Int64]] = [:]
    }

    private struct ThreadRow {
        var provider: String
        var model: String
        var rolloutPath: String
    }

    private let home: URL
    private let kind: AccountKind
    private let options: Options
    private var cache: [String: FileState] = [:]

    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let tokenCountMarker = Data(#""token_count""#.utf8)

    public init(home: URL, kind: AccountKind, options: Options = Options()) {
        self.home = home; self.kind = kind; self.options = options
    }

    public func reset() { cache.removeAll() }

    public func snapshot(now: Date = Date()) throws -> UsageSnapshot {
        let today = DayKey.format(now)
        let cutoff = now.addingTimeInterval(-Double(options.windowDays) * 86400)
        let cutoffDay = DayKey.format(cutoff)
        let rows = try readThreads(since: cutoff)

        var seen = Set<String>()
        var snapshot = UsageSnapshot()
        snapshot.windowDays = options.windowDays
        snapshot.generatedAt = now
        snapshot.todayKey = today

        var matched = 0
        for row in rows {
            guard matched < options.maxFiles else { break }
            guard !row.rolloutPath.isEmpty, kind.matchesLocalUsage(modelProvider: row.provider, model: row.model) else { continue }
            matched += 1
            seen.insert(row.rolloutPath)
            var state = cache[row.rolloutPath] ?? FileState(model: row.model)
            state.provider = row.provider
            state.model = row.model
            if state.currentModel.isEmpty { state.currentModel = row.model }
            read(url: URL(fileURLWithPath: row.rolloutPath), into: &state)
            cache[row.rolloutPath] = state
        }
        cache = cache.filter { seen.contains($0.key) }
        snapshot.filesRead = matched

        var days: [String: UsageDay] = [:]
        var models: [String: Int64] = [:]
        for state in cache.values {
            if state.truncated { snapshot.truncatedFiles += 1 }
            if state.unreadable { snapshot.unreadableFiles += 1 }
            for (key, day) in state.days where key >= cutoffDay && key <= today {
                days[key, default: UsageDay(date: key)].add(TokenDelta(inputTokens: day.inputTokens,
                                                                      cachedInputTokens: day.cachedInputTokens,
                                                                      outputTokens: day.outputTokens,
                                                                      totalTokens: day.totalTokens))
            }
            for (key, shares) in state.modelDays where key >= cutoffDay && key <= today {
                for (model, tokens) in shares {
                    models[model.isEmpty ? "未记录模型" : model, default: 0] += tokens
                }
            }
        }
        snapshot.days = days.values.sorted { $0.date < $1.date }
        snapshot.models = models.map { UsageModelShare(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
        return snapshot
    }

    // MARK: - Rolling file reads

    private func read(url: URL, into state: inout FileState) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            state.unreadable = true
            return
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modified = attributes[.modificationDate] as? Date

        if state.identity != inode || size < state.offset || (size == state.offset && state.modified != nil && state.modified != modified) {
            // File replaced or rolled back: the cached projection no longer belongs to it.
            let model = state.model, current = state.currentModel
            state = FileState(model: model, currentModel: current.isEmpty ? model : current)
        }
        state.identity = inode
        state.modified = modified
        guard size > state.offset else { state.unreadable = false; return }

        if state.offset == 0 && size > options.maxInitialBytes {
            state.offset = size - options.maxInitialBytes
            state.truncated = true
            state.discardFirst = true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { state.unreadable = true; return }
        defer { try? handle.close() }
        // A tail seek usually starts mid-line, and only then must the first line be discarded.
        // Dropping a complete line would silently lose one request's usage.
        if state.discardFirst, state.offset > 0 {
            if (try? handle.seek(toOffset: state.offset - 1)) != nil,
               (try? handle.read(upToCount: 1))?.first == 10 {
                state.discardFirst = false
            }
        }
        do { try handle.seek(toOffset: state.offset) } catch { state.unreadable = true; return }

        while state.offset < size {
            let remaining = size - state.offset
            let chunk: Data
            do { chunk = try handle.read(upToCount: Int(min(UInt64(options.chunkBytes), remaining))) ?? Data() }
            catch { state.unreadable = true; return }
            if chunk.isEmpty { break }
            state.offset += UInt64(chunk.count)
            state.pending.append(chunk)
            while let newline = state.pending.firstIndex(of: 10) {
                let line = Data(state.pending[..<newline])
                state.pending.removeSubrange(...newline)
                if state.discardFirst { state.discardFirst = false; continue }
                consume(line, into: &state)
            }
        }
        state.unreadable = false
    }

    private func consume(_ line: Data, into state: inout FileState) {
        // Rollouts are large; most lines (assistant output, tool results) carry no usage. A byte
        // search keeps the per-refresh cost low enough to re-read a long session's tail.
        let turnContextLine = line.range(of: Self.turnContextMarker) != nil
        let tokenCountLine = !turnContextLine && line.range(of: Self.tokenCountMarker) != nil
        guard turnContextLine || tokenCountLine else { return }
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "turn_context":
            if let payload = event["payload"] as? [String: Any], let model = payload["model"] as? String, !model.isEmpty {
                state.currentModel = model
                state.sawTurnContext = true
            }
        case "event_msg":
            guard let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { return }
            // The skipped head may hold a different model; wait until the tail proves the model.
            guard state.sawTurnContext || !state.truncated else { return }
            let delta = delta(from: info, state: &state)
            guard delta.totalTokens != 0 || delta.inputTokens != 0 || delta.outputTokens != 0 else { return }
            // Attribution follows the model of this turn. A session can be continued after the
            // provider is switched, so the thread row alone would move another provider's tokens
            // into this account.
            let model = (state.currentModel.isEmpty ? state.model : state.currentModel)
            guard model.isEmpty || kind.matchesLocalUsage(modelProvider: state.provider, model: model) else { return }
            let key = DayKey.day(fromTimestamp: event["timestamp"] as? String) ?? DayKey.format(Date())
            state.days[key, default: UsageDay(date: key)].add(delta)
            state.modelDays[key, default: [:]][model, default: 0] += delta.totalTokens
        default:
            break
        }
    }

    private func delta(from info: [String: Any], state: inout FileState) -> TokenDelta {
        func value(_ dictionary: [String: Any]?, _ key: String) -> Int64 {
            ((dictionary?[key] as? NSNumber)?.int64Value) ?? 0
        }
        var delta = TokenDelta()
        if let last = info["last_token_usage"] as? [String: Any] {
            delta.inputTokens = value(last, "input_tokens")
            delta.cachedInputTokens = value(last, "cached_input_tokens")
            delta.outputTokens = value(last, "output_tokens")
            delta.totalTokens = value(last, "total_tokens")
        } else if let total = info["total_token_usage"] as? [String: Any] {
            let cumulative = value(total, "total_tokens")
            let previous = state.lastCumulative ?? 0
            if cumulative > previous {
                delta.inputTokens = value(total, "input_tokens")
                delta.outputTokens = value(total, "output_tokens")
                delta.totalTokens = cumulative - previous
            }
            state.lastCumulative = cumulative
            return delta
        }
        if let total = info["total_token_usage"] as? [String: Any] { state.lastCumulative = value(total, "total_tokens") }
        if delta.totalTokens == 0 {
            delta.totalTokens = delta.inputTokens + delta.outputTokens
        }
        return delta
    }

    // MARK: - Local thread index

    private func readThreads(since: Date) throws -> [ThreadRow] {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let databases = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let database = databases.first else {
            throw LocalReadError.unavailable("未找到本机会话数据库，请先使用 Codex 创建任务。")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw LocalReadError.unavailable("无法读取 Codex 会话数据库。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        // Metadata only: provider, model and log path. Never prompt bodies.
        let sql = "SELECT model_provider, model, rollout_path FROM threads WHERE updated_at >= ? ORDER BY updated_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LocalReadError.unavailable("Codex 数据库结构暂不兼容，请更新 Codex Pulse。")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int(statement, 2, Int32(options.maxRowsScanned))
        func string(_ index: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: bytes)
        }
        var rows: [ThreadRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            rows.append(ThreadRow(provider: string(0), model: string(1), rolloutPath: string(2)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw LocalReadError.unavailable("会话数据库暂时忙碌，请稍后刷新。") }
        return rows
    }
}

/// Local calendar day keys. Usage is bucketed in the machine's timezone, matching the clock the
/// user reads on screen; server-side buckets may use a different timezone.
public enum DayKey {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    public static func format(_ date: Date) -> String { dayFormatter.string(from: date) }
    public static func date(_ key: String) -> Date? { dayFormatter.date(from: key) }

    public static func day(fromTimestamp timestamp: String?) -> String? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        guard let date = fractional.date(from: timestamp) ?? iso.date(from: timestamp) else { return nil }
        return format(date)
    }
}
