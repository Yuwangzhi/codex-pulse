import Foundation
import CryptoKit
import Darwin

public enum MonitoredAgent: String, Codable, CaseIterable, Sendable {
    case claude, grok
    public var label: String { self == .claude ? "Claude Code" : "Grok CLI" }
}

public enum AgentPhase: String, Codable, Sendable {
    case running, attention, completed, interrupted, idle, unknown, ended
    public var label: String {
        switch self {
        case .running: return "执行中"
        case .attention: return "等你回应"
        case .completed: return "本轮已回复"
        case .interrupted: return "已中断"
        case .idle: return "就绪"
        case .unknown: return "待确认"
        case .ended: return "会话已关闭"
        }
    }
    public var priority: Int {
        switch self {
        case .attention: return 0
        case .running: return 1
        case .unknown: return 2
        case .interrupted: return 3
        case .completed: return 4
        case .idle: return 5
        case .ended: return 6
        }
    }
}

/// Allowlisted hook metadata. Prompt text, tool input/output, responses and error bodies
/// are deliberately absent from this model and never written to the state directory.
public struct AgentSession: Codable, Identifiable, Sendable {
    public var agent: MonitoredAgent
    public var sessionID: String
    public var cwd: String
    public var phase: AgentPhase
    public var updatedAt: Date
    public var lastEvent: String
    public var tool: String?
    public var promptID: String?
    public var ownerPID: Int32?
    public var id: String { agent.rawValue + ":" + sessionID }
    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public init(agent: MonitoredAgent, sessionID: String, cwd: String, phase: AgentPhase,
                updatedAt: Date, lastEvent: String = "", tool: String? = nil,
                promptID: String? = nil, ownerPID: Int32? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.cwd = cwd; self.phase = phase
        self.updatedAt = updatedAt; self.lastEvent = lastEvent; self.tool = tool
        self.promptID = promptID; self.ownerPID = ownerPID
    }

    public func observedPhase(now: Date, ownerAlive: Bool? = nil) -> AgentPhase {
        if ownerAlive == false { return .ended }
        // Silence never means completion. Long tools and disconnected hooks look alike.
        if phase == .running && now.timeIntervalSince(updatedAt) > 120 { return .unknown }
        if ownerPID == nil && now.timeIntervalSince(updatedAt) > 1800 { return .unknown }
        return phase
    }
}

public struct AgentHookEvent: Sendable {
    public var agent: MonitoredAgent
    public var sessionID: String
    public var name: String
    public var cwd: String
    public var tool: String?
    public var promptID: String?
    public var notification: String?
    public var reason: String?
    public var receivedAt: Date

    public init?(data: Data, agent: MonitoredAgent, environment: [String: String] = [:], now: Date = Date()) {
        // Grok scans Claude settings by default. Do not report those inherited hooks as CC.
        if agent == .claude && (environment["GROK_SESSION_ID"] != nil || environment["GROK_HOOK_EVENT"] != nil) { return nil }
        guard data.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ keys: String...) -> String? {
            keys.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        }
        // A nested agent's Stop/teardown must not settle the parent session.
        if text("subagentType", "subagent_type", "agent_id") != nil { return nil }
        guard let session = text("session_id", "sessionId") ?? environment["GROK_SESSION_ID"],
              session.utf8.count <= 256,
              let event = text("hook_event_name", "hookEventName") ?? environment["GROK_HOOK_EVENT"] else { return nil }
        let key = event.replacingOccurrences(of: "_", with: "").lowercased()
        let names = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                     "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Notification",
                     "Stop", "StopFailure", "StopCancelled", "PreCompact", "PostCompact"]
        guard let name = names.first(where: { $0.lowercased() == key }) else { return nil }
        self.agent = agent; sessionID = session; self.name = name
        cwd = String((text("workspaceRoot", "cwd") ?? "").prefix(4096))
        tool = text("tool_name", "toolName").map { String($0.prefix(160)) }
        promptID = text("promptId", "prompt_id").map { String($0.prefix(256)) }
        notification = text("notification_type", "notificationType")
        reason = text("reason")
        receivedAt = now
    }

    public func applying(to previous: AgentSession?, ownerPID: Int32? = nil) -> AgentSession? {
        let previous = previous?.agent == agent && previous?.sessionID == sessionID ? previous : nil
        if let previous, previous.updatedAt > receivedAt { return previous }
        let endEvents = ["Stop", "StopFailure", "StopCancelled"]
        if endEvents.contains(name), let current = previous?.promptID, let reported = promptID, current != reported {
            return previous // A cancelled Grok turn may report after the next prompt started.
        }
        var result = previous ?? AgentSession(agent: agent, sessionID: sessionID, cwd: cwd,
                                              phase: .unknown, updatedAt: receivedAt)
        var phase: AgentPhase
        switch name {
        case "SessionStart": phase = .idle
        case "SessionEnd": phase = .ended
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PreCompact", "PostCompact": phase = .running
        case "PreToolUse":
            let userTools = ["askuserquestion", "ask_user_question", "exitplanmode", "exit_plan_mode"]
            phase = userTools.contains(tool?.lowercased() ?? "") ? .attention : .running
        case "PermissionRequest", "PermissionDenied": phase = .attention
        case "Stop":
            phase = ["channel_closed", "shutdown"].contains(reason ?? "") ? .ended : .completed
        case "StopCancelled", "StopFailure": phase = .interrupted
        case "Notification":
            switch notification {
            case "permission_prompt", "worker_permission_prompt", "agent_needs_input", "elicitation_dialog": phase = .attention
            case "idle_prompt": phase = .idle
            default: return previous // An arbitrary notification is not a request for approval.
            }
        default: return previous
        }
        result.phase = phase; result.updatedAt = receivedAt; result.lastEvent = name
        if !cwd.isEmpty { result.cwd = cwd }
        if name == "UserPromptSubmit" { result.promptID = promptID }
        result.tool = name == "PreToolUse" ? tool : nil
        result.ownerPID = ownerPID ?? result.ownerPID
        return result
    }
}

public enum AgentSessionFiles {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/ai-pulse/agent-sessions")
    }
    public static func key(agent: MonitoredAgent, sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return agent.rawValue + "-" + digest
    }
    public static func record(_ event: AgentHookEvent, directory: URL = directory, ownerPID: Int32? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = key(agent: event.agent, sessionID: event.sessionID)
        let lock = Darwin.open(directory.appendingPathComponent(base + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw LocalReadError.unavailable("无法锁定会话状态。") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw LocalReadError.unavailable("会话状态正忙。") }
        defer { flock(lock, LOCK_UN) }
        let url = directory.appendingPathComponent(base + ".json")
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AgentSession.self, from: $0) }
        guard let next = event.applying(to: previous, ownerPID: ownerPID) else { return }
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(directory: URL = directory, now: Date = Date()) throws -> [AgentSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        var sessions: [AgentSession] = []
        for url in urls where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 32 * 1024,
                  let data = try? Data(contentsOf: url), let session = try? JSONDecoder().decode(AgentSession.self, from: data),
                  now.timeIntervalSince(session.updatedAt) < 86400 else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Shared display model for existing Codex observations and the independent CC/Grok hooks.
public struct TrafficSession: Identifiable, Sendable {
    public var id: String
    public var agent: String
    public var project: String
    public var cwd: String
    public var phase: AgentPhase
    public var detail: String
    public var updatedAt: Date
    public init(id: String, agent: String, project: String, cwd: String, phase: AgentPhase, detail: String, updatedAt: Date) {
        self.id = id; self.agent = agent; self.project = project; self.cwd = cwd
        self.phase = phase; self.detail = detail; self.updatedAt = updatedAt
    }
    public static func sorted(_ rows: [TrafficSession]) -> [TrafficSession] {
        rows.sorted {
            if $0.phase.priority != $1.phase.priority { return $0.phase.priority < $1.phase.priority }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}
