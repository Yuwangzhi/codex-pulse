import Foundation
import CryptoKit

public enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case notOfficial, signedOut, authorization, expired, missingScope, invalidResponse, unavailable
    case rateLimited(Date)

    public var errorDescription: String? {
        switch self {
        case .notOfficial: return "未找到 Claude 官方订阅来源。"
        case .signedOut: return "未登录 Claude 官方订阅；登录后自动读取额度。"
        case .authorization: return "Claude 官方登录凭据暂不可读，请授权后刷新。"
        case .expired: return "Claude 临时凭据待更新，正在自动重试；若持续失败，请在 Claude Code 中更新登录。"
        case .missingScope: return "Claude 登录未提供用量读取权限，请使用官方订阅登录。"
        case .invalidResponse: return "Claude 官方接口暂未返回可用的额度窗口。"
        case .unavailable: return "Claude 官方用量暂时无法刷新。"
        case .rateLimited: return "Claude 官方用量查询限流，稍后自动重试。"
        }
    }
}

public struct ClaudeUsageWindow: Sendable, Equatable, Codable {
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

public struct ClaudeOfficialUsage: Sendable, Equatable, Codable {
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

public struct ClaudeUsageCredentials: Sendable {
    private let accessToken: String
    public let fingerprint: String
    public let expiresAt: Date
    public var directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    public init(data: Data, now: Date, allowExpired: Bool = false) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw ClaudeUsageError.signedOut }
        guard let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile") else {
            throw ClaudeUsageError.missingScope
        }
        guard let expiry = oauth["expiresAt"] as? NSNumber, expiry.doubleValue.isFinite else { throw ClaudeUsageError.expired }
        expiresAt = Date(timeIntervalSince1970: expiry.doubleValue / 1000)
        guard allowExpired || expiresAt > now else { throw ClaudeUsageError.expired }
        accessToken = token
        fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(allowInteraction: Bool = false, now: Date = Date(), allowExpired: Bool = false,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultDir
        // Monitor this profile's saved official subscription independently of its inference route.
        // Relay/API keys are never used for quota requests or substituted for the OAuth login.
        func decode(_ data: Data) throws -> Self {
            var value = try Self(data: data, now: now, allowExpired: allowExpired)
            value.directory = directory
            return value
        }
        let file = directory.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), data.count < 1024 * 1024 else { throw ClaudeUsageError.signedOut }
            return try decode(data)
        }
        // A custom profile must never fall back to the global user's Keychain login.
        guard directory.standardizedFileURL == defaultDir.standardizedFileURL else { throw ClaudeUsageError.signedOut }
        let data: Data
        do { data = try KeychainCredentialReader.read(service: "Claude Code-credentials",
                                                      account: NSUserName(), allowInteraction: allowInteraction) }
        catch KeychainCredentialReadError.notFound { throw ClaudeUsageError.signedOut }
        catch { throw ClaudeUsageError.authorization }
        return try decode(data)
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

/// The Claude column keeps its place through sign-out, resets and transient refresh failures.
public struct QuotaStatusLayout: Sendable, Equatable {
    public let left: [String]
    public let right: [String]
    public var hasRightColumn: Bool { right.contains { !$0.isEmpty } }
    public var text: String {
        zip(left, right).map { $1.isEmpty ? $0 : $0 + "\t" + $1 }.joined(separator: "\n")
    }
    public init(gpt: String, grok: String, claude: ClaudeOfficialUsage?, now: Date, stale: Bool = false) {
        left = ["GPT " + gpt, "Grok " + grok]
        let old = stale || (claude?.isStale(now: now) ?? false)
        right = [claude?.fiveHour, claude?.sevenDay].map { window in
            let value = window?.text(now: now) ?? ""
            return value.isEmpty ? "—" : value + (old ? "*" : "")
        }
    }
}
