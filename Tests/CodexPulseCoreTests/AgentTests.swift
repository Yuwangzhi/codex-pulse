import Foundation
import Testing
@testable import CodexPulseCore

private let agentEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private func hook(_ fields: [String: Any], agent: MonitoredAgent = .grok,
                  at offset: TimeInterval = 0, environment: [String: String] = [:]) throws -> AgentHookEvent? {
    AgentHookEvent(data: try JSONSerialization.data(withJSONObject: fields), agent: agent,
                   environment: environment, now: agentEpoch.addingTimeInterval(offset))
}
private func agentTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-agents-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func grokAliasesAndPrivacyAllowlist() throws {
    let event = try #require(try hook([
        "sessionId": "session-a", "hookEventName": "pre_tool_use", "workspaceRoot": "/repo/main",
        "toolName": "run_terminal_command", "toolInput": ["command": "PRIVATE_COMMAND"],
        "prompt": "PRIVATE_PROMPT", "lastAssistantMessage": "PRIVATE_RESPONSE"
    ]))
    let row = try #require(event.applying(to: nil))
    #expect(row.phase == .running)
    #expect(row.tool == "run_terminal_command")
    #expect(row.cwd == "/repo/main")
    let saved = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
    #expect(!saved.contains("PRIVATE_"))
    #expect(!saved.contains("toolInput"))
}

@Test func inheritedClaudeHooksAndSubagentsDoNotDuplicateGrok() throws {
    let fields: [String: Any] = ["session_id": "s", "hook_event_name": "Stop"]
    #expect(try hook(fields, agent: .claude, environment: ["GROK_SESSION_ID": "s"]) == nil)
    #expect(try hook(fields.merging(["subagentType": "explore"]) { _, b in b }) == nil)
    #expect(try hook(fields.merging(["agent_id": "nested"]) { _, b in b }, agent: .claude) == nil)
    #expect(try hook(fields, agent: .claude) != nil)
}

@Test func lateGrokTurnReportsCannotSettleANewerPrompt() throws {
    let first = try #require(try hook(["sessionId": "s", "hook_event_name": "UserPromptSubmit", "promptId": "a"]))
    let second = try #require(try hook(["sessionId": "s", "hook_event_name": "UserPromptSubmit", "promptId": "b"], at: 1))
    let previous = second.applying(to: first.applying(to: nil))
    for name in ["Stop", "StopFailure", "StopCancelled"] {
        let late = try #require(try hook(["sessionId": "s", "hook_event_name": name, "promptId": "a"], at: 2))
        #expect(late.applying(to: previous)?.phase == .running)
        #expect(late.applying(to: previous)?.promptID == "b")
    }
    let backstop = try #require(try hook(["sessionId": "s", "hook_event_name": "Notification", "notificationType": "idle_prompt"], at: 3))
    #expect(backstop.applying(to: previous)?.phase == .idle)
}

@Test func permissionNotificationsDifferFromIdleAndUnrelatedNotifications() throws {
    let start = try #require(try hook(["session_id": "s", "hook_event_name": "UserPromptSubmit"]))
    let row = start.applying(to: nil)
    let permission = try #require(try hook(["session_id": "s", "hook_event_name": "Notification", "notification_type": "permission_prompt"], at: 1))
    #expect(permission.applying(to: row)?.phase == .attention)
    let info = try #require(try hook(["session_id": "s", "hook_event_name": "Notification", "notification_type": "auth_success"], at: 2))
    #expect(info.applying(to: row)?.phase == .running)
    let stop = try #require(try hook(["session_id": "s", "hook_event_name": "StopCancelled"], at: 3))
    #expect(stop.applying(to: row)?.phase == .interrupted)
}

@Test func staleOrDeadSessionsNeverBecomeCompleted() {
    let row = AgentSession(agent: .grok, sessionID: "s", cwd: "/repo", phase: .running, updatedAt: agentEpoch)
    #expect(row.observedPhase(now: agentEpoch.addingTimeInterval(121)) == .unknown)
    #expect(row.observedPhase(now: agentEpoch, ownerAlive: false) == .ended)
    #expect(row.observedPhase(now: agentEpoch, ownerAlive: true) == .running)
}

@Test func sessionFilesSeparateAgentsHashUnsafeIDsAndKeepNewestEvent() throws {
    let directory = try agentTemp(); defer { try? FileManager.default.removeItem(at: directory) }
    let unsafeID = "../../same-id"
    let newer = try #require(try hook(["session_id": unsafeID, "hook_event_name": "UserPromptSubmit"], at: 2))
    let older = try #require(try hook(["session_id": unsafeID, "hook_event_name": "Stop"], at: 1))
    let claude = try #require(try hook(["session_id": unsafeID, "hook_event_name": "Stop"], agent: .claude, at: 2))
    try AgentSessionFiles.record(newer, directory: directory)
    try AgentSessionFiles.record(older, directory: directory)
    try AgentSessionFiles.record(claude, directory: directory)
    let rows = try AgentSessionFiles.read(directory: directory, now: agentEpoch.addingTimeInterval(3))
    #expect(rows.count == 2)
    #expect(rows.first { $0.agent == .grok }?.phase == .running)
    #expect(rows.first { $0.agent == .claude }?.phase == .completed)
    #expect(!AgentSessionFiles.key(agent: .grok, sessionID: unsafeID).contains("/"))
}

@Test func hookMergePreservesSettingsAndOtherHandlersAndIsIdempotent() throws {
    let other: [String: Any] = ["type": "command", "command": "existing-monitor", "timeout": 20]
    let original: [String: Any] = ["env": ["KEEP": "value"], "permissions": ["allow": ["Read"]],
        "hooks": ["Stop": [["matcher": "", "hooks": [other]]]]]
    let executable = URL(fileURLWithPath: "/Applications/AI Pulse.app/Contents/MacOS/CodexPulse")
    let enabled = try AgentHooks.merged(original, agent: .claude, executable: executable, enabled: true)
    let again = try AgentHooks.merged(enabled, agent: .claude, executable: executable, enabled: true)
    let removed = try AgentHooks.merged(enabled, agent: .claude, executable: executable, enabled: false)
    func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }
    #expect(try canonical(enabled) == canonical(again))
    #expect(try canonical(removed) == canonical(original))
    #expect(AgentHooks.shellQuote("a'b $HOME") == "'a'\\''b $HOME'")
}

@Test func hookConfigurationBacksUpOnlyOnChangeAndRemovesOnlyItsHandlers() throws {
    let home = try agentTemp(); defer { try? FileManager.default.removeItem(at: home) }
    let path = AgentHooks.settingsURL(agent: .claude, home: home)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("{\"env\":{\"PRESERVE\":\"yes\"}}".utf8)
    try original.write(to: path)
    let executable = URL(fileURLWithPath: "/tmp/AI Pulse's.app/Contents/MacOS/CodexPulse")
    #expect(try AgentHooks.configure(agent: .claude, executable: executable, enabled: true, home: home))
    #expect(AgentHooks.installed(agent: .claude, executable: executable, home: home))
    #expect(try !AgentHooks.configure(agent: .claude, executable: executable, enabled: true, home: home))
    let files = try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    let backups = files.filter { $0.lastPathComponent.contains("ai-pulse-backup-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
    try AgentHooks.configure(agent: .claude, executable: executable, enabled: false, home: home)
    #expect(!AgentHooks.installed(agent: .claude, executable: executable, home: home))
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    #expect((root?["env"] as? [String: String])?["PRESERVE"] == "yes")
}

@Test func invalidHookConfigurationIsLeftUntouched() throws {
    let home = try agentTemp(); defer { try? FileManager.default.removeItem(at: home) }
    let path = AgentHooks.settingsURL(agent: .grok, home: home)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data("{\"hooks\":{\"Stop\":\"unsupported\"}}".utf8)
    try data.write(to: path)
    #expect(throws: (any Error).self) {
        try AgentHooks.configure(agent: .grok, executable: URL(fileURLWithPath: "/tmp/app"), enabled: true, home: home)
    }
    #expect(try Data(contentsOf: path) == data)
}

@Test func desktopGrokCacheUsesOnlyCurrentAccountAndMarksOldReadings() throws {
    let directory = try agentTemp(); defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = directory.appendingPathComponent("sand-client-persistence")
    try FileManager.default.createDirectory(at: persistence, withIntermediateDirectories: true)
    try Data("{\"version\":1,\"pid\":1234,\"appVersion\":\"0.71.2\",\"signedIn\":true}".utf8)
        .write(to: directory.appendingPathComponent("desktop-status.json"))
    let slot = "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob"
    let active = "onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufz2gk43ueu3ugyldoruxmzjoo5swk23mpewxk43bm5ss4y3bmnugk.blob"
    let other = "onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufz2gk43ueu3ug33unbsxeltxmvsww3dzfv2xgylhmuxggyldnbsq.blob"
    try Data("{\"schemaVersion\":1,\"value\":\"test|active\"}".utf8).write(to: persistence.appendingPathComponent(slot))
    func cache(_ used: Double) -> Data {
        Data("{\"schemaVersion\":2,\"value\":{\"kind\":\"present\",\"reading\":{\"usage\":{\"percentUsed\":\(used),\"nextResetMs\":1800001000000},\"readAtMs\":1800000000000},\"expiresAtMs\":1800002000000}}".utf8)
    }
    try cache(17).write(to: persistence.appendingPathComponent(active))
    try cache(99).write(to: persistence.appendingPathComponent(other))
    // These files must never be opened by the reader, even if they are invalid JSON.
    try Data("PRIVATE_SECRET".utf8).write(to: directory.appendingPathComponent("sand-secrets.json"))
    let snapshot = try #require(try GrokBotReader.read(directory: directory))
    let quota = try #require(snapshot.quota)
    #expect(quota.remainingPercent == 83)
    #expect(!quota.isStale(now: agentEpoch.addingTimeInterval(10)))
    #expect(quota.isStale(now: agentEpoch.addingTimeInterval(301)))
    #expect(GrokBotReader.decodeKey("MZXW6") == "foo")
    try FileManager.default.removeItem(at: persistence.appendingPathComponent(active))
    #expect(try GrokBotReader.read(directory: directory)?.quota == nil)
}
