import Foundation
import CSQLite

public struct RelayProvider: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var current: Bool
    public init(id: String, name: String, baseURL: String = "", current: Bool = false) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.current = current
    }
}

public struct RelayRequest: Identifiable, Sendable {
    public var id: String
    public var providerID: String
    public var model: String
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var cost: Double
    public var latencyMS: Double
    public var firstTokenMS: Double?
    public var durationMS: Double?
    public var status: Int
    public var streaming: Bool
    public var date: Date
    /// CC Switch: 1 = total-inclusive, 2 = fresh input, 0 = legacy. Claude legacy rows are fresh.
    public var inputSemantics: Int = 2
    public init(id: String, providerID: String, model: String, input: Int64, output: Int64,
                cacheRead: Int64, cacheWrite: Int64, cost: Double, latencyMS: Double,
                firstTokenMS: Double?, durationMS: Double?, status: Int, streaming: Bool, date: Date,
                inputSemantics: Int = 2) {
        self.id = id; self.providerID = providerID; self.model = model; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.cost = cost; self.latencyMS = latencyMS
        self.firstTokenMS = firstTokenMS; self.durationMS = durationMS; self.status = status
        self.streaming = streaming; self.date = date; self.inputSemantics = inputSemantics
    }
    public var tokens: Int64 {
        // This reader is scoped to app_type=claude, whose inputs are fresh
        // even for legacy rows. Match CC Switch real_total_tokens_sql.
        input + output + cacheRead + cacheWrite
    }
    public var successful: Bool { (200..<300).contains(status) }
    /// Includes queueing, prefill, reasoning, and network time. Never call this decode speed.
    public var throughput: Double? {
        guard successful, output > 0, latencyMS > 0 else { return nil }
        return Double(output) * 1000 / latencyMS
    }
    /// CC Switch records latency_ms after stream completion. A separate duration overrides it.
    /// Intervals below 250ms are too sensitive to rounding / upstream buffering to report.
    /// This is observed post-first-byte throughput, not the server's pure decode speed.
    public var outputIntervalMS: Double? {
        guard successful, streaming, output > 0, let firstTokenMS, firstTokenMS > 0 else { return nil }
        let interval = (durationMS ?? latencyMS) - firstTokenMS
        return interval >= 250 ? interval : nil
    }
    public var generationSpeed: Double? {
        outputIntervalMS.map { Double(output) * 1000 / $0 }
    }
}

public struct RelayTotals: Sendable {
    public var requests = 0
    public var successes = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var tokens: Int64 = 0
    public var cost = 0.0
    public var throughput: Double?
    public var firstTokenMS: Double?
    public var generationSpeed: Double?
    public init(_ rows: [RelayRequest] = []) {
        requests = rows.count; successes = rows.filter(\.successful).count
        input = rows.reduce(0) { $0 + $1.input }; output = rows.reduce(0) { $0 + $1.output }
        cacheRead = rows.reduce(0) { $0 + $1.cacheRead }; cacheWrite = rows.reduce(0) { $0 + $1.cacheWrite }
        tokens = rows.reduce(0) { $0 + $1.tokens }; cost = rows.reduce(0) { $0 + $1.cost }
        let timed = rows.filter { $0.throughput != nil }
        let elapsed = timed.reduce(0) { $0 + $1.latencyMS }
        if elapsed > 0 { throughput = Double(timed.reduce(Int64(0)) { $0 + $1.output }) * 1000 / elapsed }
        let ttft = rows.filter { $0.successful && ($0.firstTokenMS ?? 0) > 0 }.compactMap(\.firstTokenMS)
        if !ttft.isEmpty { firstTokenMS = ttft.reduce(0, +) / Double(ttft.count) }
        let generated = rows.filter { $0.generationSpeed != nil }
        let generationMS = generated.reduce(0) { $0 + $1.outputIntervalMS! }
        if generationMS > 0 { generationSpeed = Double(generated.reduce(Int64(0)) { $0 + $1.output }) * 1000 / generationMS }
    }
}

public struct RelaySnapshot: Sendable {
    public var providers: [RelayProvider] = []
    public var requests: [RelayRequest] = []
    /// Imported session rows are intentionally separate: they can overlap proxy observations.
    public var importedRequests = 0
    public var generatedAt = Date()
    public var since = Date()
    public var totals: RelayTotals { RelayTotals(requests) }
    public init() {}
}

/// Reads metadata only. Never select prompts, response bodies, headers, or error text.
public enum RelayDatabase {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db")
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LocalReadError.unavailable("无法读取 CC Switch 数据库，请确认已安装并启用请求记录。")
        }
        sqlite3_busy_timeout(db, 1000)
        return db
    }

    private static func query(_ db: OpaquePointer, _ sql: String, since: Date? = nil,
                              row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalReadError.unavailable("CC Switch 数据结构不兼容，请更新 AI Pulse。")
        }
        defer { sqlite3_finalize(statement) }
        if let since { sqlite3_bind_double(statement, 1, since.timeIntervalSince1970) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { row(statement); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw LocalReadError.unavailable("CC Switch 数据库忙碌，稍后自动重试。") }
    }
    private static func string(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }
    private static func optionalDouble(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    public static func read(url: URL = defaultURL, since: Date, now: Date = Date()) throws -> RelaySnapshot {
        let db = try open(url); defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw LocalReadError.unavailable("无法开始 CC Switch 只读快照。")
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var snapshot = RelaySnapshot(); snapshot.since = since; snapshot.generatedAt = now
        // SQLite extracts the non-secret base URL. settings_config is not loaded into the UI.
        try query(db, "SELECT id,name,COALESCE(json_extract(settings_config,'$.env.ANTHROPIC_BASE_URL'),''),is_current FROM providers WHERE app_type='claude' ORDER BY sort_index,name") { s in
            snapshot.providers.append(RelayProvider(id: string(s, 0), name: string(s, 1), baseURL: string(s, 2), current: sqlite3_column_int(s, 3) != 0))
        }
        try query(db, "SELECT request_id,provider_id,model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,is_streaming,created_at,input_token_semantics FROM proxy_request_logs WHERE app_type='claude' AND data_source='proxy' AND created_at>=? ORDER BY created_at DESC", since: since) { s in
            snapshot.requests.append(RelayRequest(id: string(s, 0), providerID: string(s, 1), model: string(s, 2),
                input: sqlite3_column_int64(s, 3), output: sqlite3_column_int64(s, 4), cacheRead: sqlite3_column_int64(s, 5),
                cacheWrite: sqlite3_column_int64(s, 6), cost: Double(string(s, 7)) ?? 0, latencyMS: sqlite3_column_double(s, 8),
                firstTokenMS: optionalDouble(s, 9), durationMS: optionalDouble(s, 10), status: Int(sqlite3_column_int(s, 11)),
                streaming: sqlite3_column_int(s, 12) != 0, date: Date(timeIntervalSince1970: sqlite3_column_double(s, 13)),
                inputSemantics: Int(sqlite3_column_int(s, 14))))
        }
        try query(db, "SELECT COUNT(*) FROM proxy_request_logs WHERE app_type='claude' AND data_source<>'proxy' AND created_at>=?", since: since) { s in
            snapshot.importedRequests = Int(sqlite3_column_int(s, 0))
        }
        return snapshot
    }

    /// The caller uses this only immediately before a balance GET. No credential persistence.
    public static func credential(providerID: String, url: URL = defaultURL) throws -> (baseURL: URL, token: String)? {
        let db = try open(url); defer { sqlite3_close(db) }
        var s: OpaquePointer?
        let sql = "SELECT json_extract(settings_config,'$.env.ANTHROPIC_BASE_URL'),COALESCE(NULLIF(json_extract(settings_config,'$.env.ANTHROPIC_AUTH_TOKEN'),''),json_extract(settings_config,'$.env.ANTHROPIC_API_KEY')) FROM providers WHERE app_type='claude' AND id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { return nil }
        defer { sqlite3_finalize(s) }
        _ = providerID.withCString { sqlite3_bind_text(s, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(s) == SQLITE_ROW, let base = URL(string: string(s, 0)), base.scheme == "https" else { return nil }
        let token = string(s, 1)
        guard !token.isEmpty, base.user == nil, base.password == nil, base.query == nil else { return nil }
        return (base, token)
    }
}

public struct RelayQuota: Sendable {
    public var unlimited: Bool
    public var remaining: Double?
    public var used: Double?
    public var accountRemaining: Double?
    public var expires: Date?
    /// Raw service quota units; never assume these are tokens or dollars.
    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], payload["object"] as? String == "token_usage" else {
            throw LocalReadError.unavailable("中转未返回可识别的额度数据。")
        }
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        unlimited = payload["unlimited_quota"] as? Bool ?? false
        remaining = unlimited ? nil : number(payload["total_available"])
        used = number(payload["total_used"])
        accountRemaining = number((payload["user_quota"] as? [String: Any])?["total_available"])
        expires = number(payload["expires_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
}
