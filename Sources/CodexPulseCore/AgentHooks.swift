import Foundation

/// Surgically owns only handlers whose command invokes our dedicated event mode.
/// All other settings and hooks survive install/update/remove, with a backup per write.
public enum AgentHooks {
    public static let marker = "--ai-pulse-event"
    public static func settingsURL(agent: MonitoredAgent, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(agent == .claude ? ".claude/settings.json" : ".grok/hooks/ai-pulse.json")
    }
    public static func events(_ agent: MonitoredAgent) -> [String] {
        let common = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PostToolUseFailure", "Notification", "Stop", "StopFailure", "PreCompact", "PostCompact"]
        return common + (agent == .grok ? ["StopCancelled", "PermissionDenied"] : ["PermissionRequest"])
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func command(agent: MonitoredAgent, executable: URL) -> String {
        shellQuote(executable.path) + " " + marker + " " + agent.rawValue
    }
    private static func owns(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return false }
        return command.contains(" " + marker + " ")
    }
    public static func merged(_ source: [String: Any], agent: MonitoredAgent, executable: URL, enabled: Bool) throws -> [String: Any] {
        var result = source
        guard source["hooks"] == nil || source["hooks"] is [String: Any] else {
            throw LocalReadError.unavailable("现有 hooks 格式不兼容，未修改配置。")
        }
        var hooks = source["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else {
                throw LocalReadError.unavailable("现有 hooks 格式不兼容，未修改配置。")
            }
            var retained: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw LocalReadError.unavailable("现有 hooks 格式不兼容，未修改配置。")
                }
                let rest = handlers.filter { !owns($0) }
                if rest.count == handlers.count { retained.append(group) }
                else if !rest.isEmpty { group["hooks"] = rest; retained.append(group) }
            }
            if retained.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = retained }
        }
        if enabled {
            for event in events(agent) {
                var groups = hooks[event] as? [[String: Any]] ?? []
                // Always return success with no stdout; never decide approvals or block turns.
                groups.append(["hooks": [["type": "command", "command": command(agent: agent, executable: executable), "timeout": 2]]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }
    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw LocalReadError.unavailable("无法识别现有配置，未修改文件。")
        }
        return root
    }
    public static func installed(agent: MonitoredAgent, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let root = try? load(settingsURL(agent: agent, home: home)), let hooks = root["hooks"] as? [String: Any] else { return false }
        let expected = command(agent: agent, executable: executable)
        return events(agent).allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == expected }
            }
        }
    }
    @discardableResult public static func configure(agent: MonitoredAgent, executable: URL, enabled: Bool,
                                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        let url = settingsURL(agent: agent, home: home)
        let source = try load(url)
        let result = try merged(source, agent: agent, executable: executable, enabled: enabled)
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: result, options: options)
        let before = try JSONSerialization.data(withJSONObject: source, options: options)
        guard data != before else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("ai-pulse-backup-" + UUID().uuidString)
            try fm.copyItem(at: url, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
