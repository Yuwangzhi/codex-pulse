import Foundation

/// Projects lifecycle events into a local observation, never equating silence with completion.
public struct RolloutProjection {
    public private(set) var lastEventAt: Date?
    public private(set) var startedAt: Date?
    public private(set) var lifecycle: TaskState = .unknown
    public private(set) var activity = "等待任务记录"
    public private(set) var totalTokens: Int64?
    public private(set) var turnTokens: Int64?
    public private(set) var contextPercent: Double?
    private var turnID: String?
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    public init() {}

    public mutating func consume(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let kind = event["type"] as? String,
              let payload = event["payload"] as? [String: Any] else { return }
        let timestamp = event["timestamp"] as? String ?? ""
        let date = Self.fractional.date(from: timestamp) ?? Self.iso.date(from: timestamp)
        // Historical metadata rewrites are not task activity.
        guard ["event_msg", "response_item", "turn_context", "token_usage_record"].contains(kind) else { return }
        if let date { lastEventAt = max(lastEventAt ?? date, date) }
        let type = payload["type"] as? String ?? ""
        if kind == "event_msg" {
            switch type {
            case "task_started":
                turnID = payload["turn_id"] as? String
                startedAt = date; lifecycle = .running; activity = "正在处理任务"; turnTokens = nil
            case "task_complete", "turn_aborted":
                let eventTurn = payload["turn_id"] as? String
                guard turnID == nil || eventTurn == nil || eventTurn == turnID else { return }
                lifecycle = type == "task_complete" ? .completed : .interrupted
                activity = type == "task_complete" ? "本轮任务已完成" : "本轮任务已中断"
            case "token_count":
                if let info = payload["info"] as? [String: Any] {
                    if let total = info["total_token_usage"] as? [String: Any] {
                        totalTokens = (total["total_tokens"] as? NSNumber)?.int64Value
                    }
                    if let last = info["last_token_usage"] as? [String: Any],
                       let input = (last["input_tokens"] as? NSNumber)?.doubleValue,
                       let window = (info["model_context_window"] as? NSNumber)?.doubleValue, window > 0 {
                        contextPercent = min(100, max(0, input / window * 100))
                    }
                }
            default: break
            }
        } else if kind == "turn_context" {
            let nextTurn = payload["turn_id"] as? String
            if nextTurn != turnID || lifecycle == .unknown {
                turnID = nextTurn; startedAt = date; lifecycle = .running; activity = "正在处理任务"
            }
        } else if kind == "token_usage_record" {
            if let usage = payload["thread_token_usage"] as? [String: Any] {
                totalTokens = (usage["total_tokens"] as? NSNumber)?.int64Value
            }
            if let usage = payload["turn_token_usage"] as? [String: Any] {
                turnTokens = (usage["total_tokens"] as? NSNumber)?.int64Value
            }
        } else if kind == "response_item" {
            switch type {
            case "function_call", "custom_tool_call":
                markActivity("正在调用工具 · " + (payload["name"] as? String ?? "工具"))
            case "function_call_output", "custom_tool_call_output": markActivity("工具已返回，继续处理")
            case "reasoning": markActivity("正在思考")
            case "message":
                if payload["role"] as? String == "assistant" { markActivity("正在生成回复") }
            default: break
            }
        }
    }

    private mutating func markActivity(_ text: String) {
        // A bounded tail can start after task_started; activity alone remains an observation.
        if lifecycle == .unknown { lifecycle = .running }
        if lifecycle == .running { activity = text }
    }

    public func state(now: Date = Date()) -> TaskState {
        if lifecycle == .running, now.timeIntervalSince(lastEventAt ?? .distantPast) > 120 { return .quiet }
        return lifecycle
    }

    public func applying(to session: SessionInfo, now: Date = Date()) -> SessionInfo {
        var result = session
        result.state = state(now: now); result.activity = activity
        if result.state == .quiet { result.activity = "超过 2 分钟无新事件，可能仍在执行工具" }
        result.lastEventAt = lastEventAt; result.startedAt = startedAt
        result.totalTokens = totalTokens ?? session.totalTokens
        result.turnTokens = turnTokens; result.contextPercent = contextPercent
        return result
    }
}

/// Initial reads are bounded. Subsequent polls parse only appended, complete JSONL records.
public final class RolloutReader {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var identity: UInt64?
    private var modified: Date?
    private var projection = RolloutProjection()
    public init() {}

    public func read(url: URL) throws -> RolloutProjection {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let mtime = attributes[.modificationDate] as? Date
        if identity != inode || size < offset || (size == offset && modified != nil && modified != mtime) {
            offset = 0; pending.removeAll(); projection = RolloutProjection()
        }
        identity = inode; modified = mtime
        guard size > offset else { return projection }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let maxInitial: UInt64 = 4 * 1024 * 1024
        let skipPartial = offset == 0 && size > maxInitial
        if skipPartial { offset = size - maxInitial }
        try file.seek(toOffset: offset)
        // Avoid a giant allocation when resuming after sleep; discard a truncated first record.
        var discardFirst = skipPartial
        while offset < size {
            let chunk = try file.read(upToCount: Int(min(256 * 1024, size - offset))) ?? Data()
            if chunk.isEmpty { break }
            offset += UInt64(chunk.count); pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if discardFirst { discardFirst = false } else { projection.consume(line) }
            }
        }
        return projection
    }
}
