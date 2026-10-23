import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case notOfficial, signedOut, authorization, expired, missingScope, invalidResponse, unavailable
    case rateLimited(Date)

    public var errorDescription: String? {
        switch self {
        case .notOfficial: return "当前未连接 Claude 官方订阅，状态栏留空。"
        case .signedOut: return "未登录 Claude 官方订阅，状态栏留空。"
        case .authorization: return "Claude 官方登录凭据暂不可读，请授权后刷新。"
        case .expired: return "Claude 官方登录已过期，请在 Claude Code 中更新登录后刷新。"
        case .missingScope: return "Claude 登录未提供用量读取权限，请使用官方订阅登录。"
        case .invalidResponse: return "Claude 官方接口暂未返回可用的额度窗口。"
        case .unavailable: return "Claude 官方用量暂时无法刷新。"
        case .rateLimited: return "Claude 官方用量查询限流，稍后自动重试。"
        }
    }
}

public struct ClaudeUsageWindow: Sendable, Equatable {
    /// Official utilization is USED percentage; it is displayed as remaining to match GPT/Grok.
    public let usedPercent: Double
    public let resetsAt: Date?
    public init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public func text(now: Date) -> String {
        guard usedPercent.isFinite, usedPercent >= 0, resetsAt.map({ $0 > now }) ?? true else { return "" }
        return String(format: "%.0f%%", remainingPercent)
    }
}

public struct ClaudeOfficialUsage: Sendable, Equatable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let readAt: Date
    public init(fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?, readAt: Date) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.readAt = readAt
    }
    public func isStale(now: Date) -> Bool { now.timeIntervalSince(readAt) > 120 }
    public static func decode(_ data: Data, now: Date) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }
        func window(_ key: String) -> ClaudeUsageWindow? {
            guard let row = root[key] as? [String: Any], let used = row["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite, used.doubleValue >= 0 else { return nil }
            var reset: Date?
            if let text = row["resets_at"] as? String {
                let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = format.date(from: text)
                if reset == nil { format.formatOptions = [.withInternetDateTime]; reset = format.date(from: text) }
                guard reset != nil else { return nil }
            }
            return ClaudeUsageWindow(usedPercent: used.doubleValue, resetsAt: reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { throw ClaudeUsageError.invalidResponse }
        return Self(fiveHour: five, sevenDay: seven, readAt: now)
    }
}

/// Read the active CLI configuration, never CC Switch's historical provider selection.
/// An API key, relay token, cloud backend or custom endpoint is not a subscription login.
public enum ClaudeOfficialConfiguration {
    public static func isOfficial(settings: Data?, environment: [String: String]) -> Bool {
        var env = environment
        if let settings {
            guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { return false }
            if let overrides = root["env"] as? [String: Any] {
                for (key, value) in overrides {
                    guard let text = value as? String else { return false }; env[key] = text
                }
            }
            if let helper = root["apiKeyHelper"] as? String, !helper.isEmpty { return false }
        }
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            if let text = env[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        }
        for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            if let text = env[key]?.lowercased(), ["1", "true"].contains(text) { return false }
        }
        if let base = env["ANTHROPIC_BASE_URL"], !base.isEmpty {
            guard let url = URLComponents(string: base), url.scheme == "https", url.host == "api.anthropic.com",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  ["", "/"].contains(url.path), url.query == nil, url.fragment == nil else { return false }
        }
        return true
    }
}

public struct ClaudeUsageCredentials: Sendable {
    private let accessToken: String
    public let fingerprint: String

    public init(data: Data, now: Date) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw ClaudeUsageError.signedOut }
        guard let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile") else {
            throw ClaudeUsageError.missingScope
        }
        guard let expiry = oauth["expiresAt"] as? NSNumber, expiry.doubleValue.isFinite,
              expiry.doubleValue / 1000 > now.timeIntervalSince1970 else { throw ClaudeUsageError.expired }
        accessToken = token
        fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(allowInteraction: Bool = false, now: Date = Date(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultDir
        let settingsURL = directory.appendingPathComponent("settings.json")
        let settings: Data?
        do { settings = FileManager.default.fileExists(atPath: settingsURL.path) ? try Data(contentsOf: settingsURL) : nil }
        catch { throw ClaudeUsageError.notOfficial }
        guard ClaudeOfficialConfiguration.isOfficial(settings: settings, environment: environment) else {
            throw ClaudeUsageError.notOfficial
        }
        let file = directory.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), data.count < 1024 * 1024 else { throw ClaudeUsageError.signedOut }
            return try Self(data: data, now: now)
        }
        // A custom profile must never fall back to the global user's Keychain login.
        guard directory.standardizedFileURL == defaultDir.standardizedFileURL else { throw ClaudeUsageError.signedOut }
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ClaudeUsageError.signedOut }
        guard status == errSecSuccess, let data = result as? Data, data.count < 1024 * 1024 else {
            throw ClaudeUsageError.authorization
        }
        return try Self(data: data, now: now)
    }

    public func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"; request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

public enum ClaudeUsageService {
    public static func fetch(_ credentials: ClaudeUsageCredentials) async throws -> ClaudeOfficialUsage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoClaudeUsageRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: credentials.request())
            guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.unavailable }
            if http.statusCode == 401 { throw ClaudeUsageError.expired }
            if http.statusCode == 403 { throw ClaudeUsageError.missingScope }
            if http.statusCode == 429 {
                let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                throw ClaudeUsageError.rateLimited(Date().addingTimeInterval(max(60, min(seconds, 86400))))
            }
            guard http.statusCode == 200, data.count < 128 * 1024 else { throw ClaudeUsageError.unavailable }
            return try ClaudeOfficialUsage.decode(data, now: Date())
        } catch let error as ClaudeUsageError { throw error }
        catch { throw ClaudeUsageError.unavailable }
    }
}

private final class NoClaudeUsageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Logical rows are shared by rendering, diagnostics and tests. Missing official values are empty cells.
public struct QuotaStatusLayout: Sendable, Equatable {
    public let left: [String]
    public let right: [String]
    public var hasRightColumn: Bool { right.contains { !$0.isEmpty } }
    public var text: String {
        zip(left, right).map { $1.isEmpty ? $0 : $0 + "\t" + $1 }.joined(separator: "\n")
    }
    public init(gpt: String, grok: String, claude: ClaudeOfficialUsage?, now: Date) {
        left = ["GPT " + gpt, "Grok " + grok]
        right = [claude?.fiveHour?.text(now: now) ?? "", claude?.sevenDay?.text(now: now) ?? ""]
    }
}
