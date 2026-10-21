import Foundation
import Testing
import CSQLite
@testable import CodexPulseCore

private func request(output: Int64 = 100, latency: Double = 5000, first: Double? = 1000,
                     duration: Double? = nil, status: Int = 200, streaming: Bool = true) -> RelayRequest {
    RelayRequest(id: UUID().uuidString, providerID: "a", model: "model", input: 10, output: output,
                 cacheRead: 20, cacheWrite: 30, cost: 0.25, latencyMS: latency, firstTokenMS: first,
                 durationMS: duration, status: status, streaming: streaming, date: Date())
}

@Test func relayTimingRejectsMissingAndDegenerateIntervals() {
    let row = request()
    #expect(row.throughput == 20)
    #expect(row.generationSpeed == 25)
    #expect(request(duration: 5000).generationSpeed == 25)
    #expect(request(first: 5000, duration: 5000).generationSpeed == nil)
    #expect(request(first: 6000, duration: 5000).generationSpeed == nil)
    #expect(request(duration: 5000, streaming: false).generationSpeed == nil)
    #expect(request(latency: 0).throughput == nil)
    #expect(request(first: nil).generationSpeed == nil)
    #expect(request(first: 4999).generationSpeed == nil)
    #expect(request(status: 500).throughput == nil)
}

@Test func relayAggregateWeightsByTimeAndExcludesFailedTiming() {
    let totals = RelayTotals([request(output: 100, latency: 1000), request(output: 100, latency: 9000), request(status: 429)])
    #expect(totals.requests == 3)
    #expect(totals.successes == 2)
    #expect(totals.throughput == 20) // Not the unweighted average of 100 and 11.11.
    #expect(totals.cost == 0.75)
    #expect(totals.tokens == 480)
    #expect(totals.generationSpeed == 12.5)
    #expect(RelayTotals().throughput == nil)
    #expect(RelayTotals().firstTokenMS == nil)
}

@Test func claudeCacheIsIncludedExactlyOnceForLegacyAndFreshRows() {
    var row = request()
    for semantics in [0, 1, 2] {
        row.inputSemantics = semantics
        #expect(row.tokens == 160)
    }
}

@Test func unlimitedRelayKeyDoesNotBecomeNegativeBalanceOrUnlimitedAccount() throws {
    let data = Data(#"{"code":true,"data":{"object":"token_usage","unlimited_quota":true,"total_available":-500,"total_used":500,"expires_at":0,"user_quota":{"total_available":900}}}"#.utf8)
    let quota = try RelayQuota(data: data)
    #expect(quota.unlimited)
    #expect(quota.remaining == nil)
    #expect(quota.accountRemaining == 900)
    #expect(quota.used == 500)
    #expect(quota.expires == nil)
}

@Test func relayQuotaKeepsUnknownsAndExpiry() throws {
    let data = Data(#"{"data":{"object":"token_usage","unlimited_quota":false,"total_available":"42","expires_at":1900000000}}"#.utf8)
    let quota = try RelayQuota(data: data)
    #expect(quota.remaining == 42)
    #expect(quota.accountRemaining == nil)
    #expect(quota.used == nil)
    #expect(quota.expires?.timeIntervalSince1970 == 1900000000)
    #expect(throws: (any Error).self) { try RelayQuota(data: Data(#"{"success":false,"message":"no"}"#.utf8)) }
}

@Test func relayReaderIsReadOnlyAndSeparatesSourceAppAndWindow() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-relay-\(UUID()).db")
    defer { try? FileManager.default.removeItem(at: url) }
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let schema = """
    CREATE TABLE providers(id TEXT,app_type TEXT,name TEXT,settings_config TEXT,is_current INT,sort_index INT);
    INSERT INTO providers VALUES('a','claude','relay','{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid","ANTHROPIC_AUTH_TOKEN":"synthetic-only"}}',1,0);
    INSERT INTO providers VALUES('b','codex','other','{}',1,1);
    CREATE TABLE proxy_request_logs(request_id TEXT,provider_id TEXT,app_type TEXT,model TEXT,input_tokens INT,
      output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,total_cost_usd TEXT,latency_ms INT,
      first_token_ms INT,duration_ms INT,status_code INT,is_streaming INT,created_at INT,input_token_semantics INT,data_source TEXT);
    INSERT INTO proxy_request_logs VALUES('proxy','a','claude','m',10,100,20,30,'0.25',5000,1000,NULL,200,1,2000,2,'proxy');
    INSERT INTO proxy_request_logs VALUES('import','a','claude','m',10,100,20,30,'0.25',5000,NULL,NULL,200,1,2000,2,'session_log');
    INSERT INTO proxy_request_logs VALUES('codex','b','codex','m',10,100,20,30,'0.25',5000,1000,NULL,200,1,2000,1,'proxy');
    INSERT INTO proxy_request_logs VALUES('desktop','a','claude-desktop','m',10,100,20,30,'0.25',5000,1000,NULL,200,1,2000,2,'proxy');
    INSERT INTO proxy_request_logs VALUES('old','a','claude','m',10,100,20,30,'0.25',5000,1000,NULL,200,1,1000,2,'proxy');
    """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: url)
    let snapshot = try RelayDatabase.read(url: url, since: Date(timeIntervalSince1970: 1500))
    #expect(snapshot.providers.count == 1)
    #expect(snapshot.providers.first?.baseURL == "https://example.invalid")
    #expect(snapshot.requests.map(\.id) == ["proxy"])
    #expect(snapshot.importedRequests == 1)
    #expect(snapshot.totals.tokens == 160)
    #expect(snapshot.totals.generationSpeed == 25)
    let credential = try RelayDatabase.credential(providerID: "a", url: url)
    #expect(credential?.token == "synthetic-only")
    #expect(try RelayDatabase.credential(providerID: "a' OR 1=1 --", url: url) == nil)
    #expect(try Data(contentsOf: url) == before)
}
