import Foundation
import CSQLite

public enum LocalReadError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let detail): return detail }
    }
}

public actor LocalSessions {
    public let home: URL
    private var readers: [String: RolloutReader] = [:]
    public init(home: URL) { self.home = home }

    public func read(now: Date = Date()) throws -> [SessionInfo] {
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
        // Metadata only: never select prompt bodies or credentials. Limit is visible in the UI.
        let sql = "SELECT id,title,cwd,model,rollout_path,updated_at,tokens_used FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 60"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LocalReadError.unavailable("Codex 数据库结构暂不兼容，请更新 Codex Pulse。")
        }
        defer { sqlite3_finalize(statement) }
        func string(_ index: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: bytes)
        }
        var sessions: [SessionInfo] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let title = string(1)
            var session = SessionInfo(id: string(0), title: title.isEmpty ? "未命名任务" : title,
                                      cwd: string(2), model: string(3), rolloutPath: string(4),
                                      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                                      totalTokens: sqlite3_column_int64(statement, 6))
            let reader = readers[session.rolloutPath] ?? RolloutReader()
            readers[session.rolloutPath] = reader
            do { session = try reader.read(url: URL(fileURLWithPath: session.rolloutPath)).applying(to: session, now: now) }
            catch { session.activity = "任务记录暂不可读" }
            sessions.append(session)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw LocalReadError.unavailable("会话数据库暂时忙碌，请稍后刷新。") }
        let retained = Set(sessions.map(\.rolloutPath))
        readers = readers.filter { retained.contains($0.key) }
        return sessions.sorted {
            let a = $0.state == .running ? 0 : ($0.state == .quiet ? 1 : 2)
            let b = $1.state == .running ? 0 : ($1.state == .quiet ? 1 : 2)
            if a != b { return a < b }
            return ($0.lastEventAt ?? $0.updatedAt) > ($1.lastEventAt ?? $1.updatedAt)
        }
    }
}
