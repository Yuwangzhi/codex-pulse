import Foundation

/// Ask the installed official CLI to initialize and check usage. It owns token rotation and locking.
/// There is no user message, model request, tool, hook, MCP server or conversation to resume.
enum ClaudeLoginRenewal {
    static let requestID = "ai-pulse-auth-init"
    static let usageID = "ai-pulse-auth-usage"
    static let input = Data(("{\"type\":\"control_request\",\"request_id\":\"" + requestID
        + "\",\"request\":{\"subtype\":\"initialize\"}}\n"
        + "{\"type\":\"control_request\",\"request_id\":\"" + usageID
        + "\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n").utf8)
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--no-session-persistence", "--safe-mode", "--setting-sources", "",
        "--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config", "--mcp-config",
        "{\"mcpServers\":{}}", "--tools", "", "--no-chrome", "--disable-slash-commands"]

    static func environment(directory: URL, inherited: [String: String]) -> [String: String] {
        let names = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL",
                     "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
        var env = inherited.filter { names.contains($0.key) }
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            env["CLAUDE_CONFIG_DIR"] = directory.path
        }
        // Keep the CLI's auth/usage networking enabled; its nonessential-traffic switch also
        // disables the usage check which recovers a server-side 401.
        return env
    }

    static func validate(_ data: Data) throws {
        var initialized = false, checkedUsage = false
        for line in data.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = row["type"] as? String else { throw ClaudeUsageError.unavailable }
            // Only protocol/control/system events are expected; never interpret model output as success.
            guard ["control_response", "system", "auth_status"].contains(type) else { throw ClaudeUsageError.unavailable }
            if type == "control_response", let response = row["response"] as? [String: Any] {
                if response["request_id"] as? String == requestID {
                    guard response["subtype"] as? String == "success" else { throw ClaudeUsageError.expired }
                    initialized = true
                }
                if response["request_id"] as? String == usageID {
                    guard response["subtype"] as? String == "success" else { throw ClaudeUsageError.expired }
                    checkedUsage = true
                }
            }
        }
        // A usage check lets the CLI also recover a server-side 401 before local expiry.
        guard initialized && checkedUsage else { throw ClaudeUsageError.unavailable }
    }

    static func renew(directory: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClaudeUsageError.expired
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ai-pulse-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = try KeychainCredentialReader.run(executable: URL(fileURLWithPath: path), arguments: arguments,
            timeout: 40, outputLimit: 1024 * 1024, input: input,
            environment: environment(directory: directory, inherited: ProcessInfo.processInfo.environment), directory: scratch)
        try validate(output)
    }
}

/// Quotas and a one-way credential fingerprint only. No login token, account name or credential file.
public struct ClaudeUsageCache: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let snapshot: ClaudeOfficialUsage
    public init(fingerprint: String, snapshot: ClaudeOfficialUsage) {
        self.fingerprint = fingerprint; self.snapshot = snapshot
    }
}
