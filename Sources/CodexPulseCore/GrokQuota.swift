import Foundation
import CommonCrypto
import CryptoKit

public enum GrokQuotaError: Error, LocalizedError, Equatable {
    case authorization, signedOut, accountChanged, credentials, unavailable, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .authorization: return "需要批准读取 Grok Bot 登录。请点「授权并刷新」，并在 macOS 钥匙串提示中允许。"
        case .signedOut: return "请先在 Grok Bot 中登录。"
        case .accountChanged: return "Grok Bot 账户正在切换，稍后重试。"
        case .credentials: return "Grok Bot 登录暂不可用，请打开客户端确认登录状态。"
        case .unavailable: return "Grok 额度查询失败，保留上次记录。"
        case .invalidResponse: return "Grok 接口未返回可用的个人额度。"
        }
    }
}

/// Reads only the selected account's access token. No refresh-token rotation or writes to
/// Grok Bot's storage, and no credentials in diagnostics, preferences or error messages.
public struct GrokQuotaCredentials: Sendable {
    let accessToken: String
    let accountSlot: String
    let teamID: Int?
    public let selectionID: String

    public static func scope(for accountSlot: String) -> String {
        SHA256.hash(data: Data(accountSlot.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func store(directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("sand-secrets.json")
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, (attributes.fileSize ?? 0) < 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              (value["version"] as? Int ?? 1) == 1 else { throw GrokQuotaError.credentials }
        return value
    }

    public static func currentScope(directory: URL = GrokBotReader.directory) throws -> String? {
        let value = try store(directory: directory)
        guard let text = value["cursor-accounts"] as? String,
              let accounts = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return accounts["active"] as? String
    }

    public static func currentSelectionID(directory: URL = GrokBotReader.directory) throws -> String? {
        let value = try store(directory: directory)
        guard let text = value["cursor-accounts"] as? String,
              let accounts = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let active = accounts["active"] as? String,
              let records = accounts["accounts"] as? [String: [String: String]],
              let record = records[active] else { return nil }
        return selectionID(active: active, record: record)
    }

    private static func selectionID(active: String, record: [String: String]) -> String {
        scope(for: active + ":" + (record["cursor-selected-team-id"] ?? ""))
    }

    public static func load(accountSlot: String, allowInteraction: Bool = false,
                            directory: URL = GrokBotReader.directory) throws -> Self {
        let value: [String: Any]
        do { value = try store(directory: directory) } catch { throw GrokQuotaError.credentials }
        var password: Data?
        return try decode(store: value, accountSlot: accountSlot) { encoded in
            if password == nil { password = try storagePassword(allowInteraction: allowInteraction) }
            guard let password else { throw GrokQuotaError.authorization }
            return try decrypt(encoded, password: password)
        }
    }

    /// Decryption is injectable so fixtures never access the real Keychain.
    static func decode(store: [String: Any], accountSlot: String,
                       decrypt: (String) throws -> String) throws -> Self {
        guard let text = store["cursor-accounts"] as? String,
              let accounts = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let active = accounts["active"] as? String else { throw GrokQuotaError.signedOut }
        guard active == scope(for: accountSlot) else { throw GrokQuotaError.accountChanged }
        guard let records = accounts["accounts"] as? [String: [String: String]],
              let record = records[active], let encoded = record["cursor-access-token"] else {
            throw GrokQuotaError.credentials
        }
        func read(_ value: String) throws -> String {
            if value.hasPrefix("plaintext:v1:") {
                guard let data = Data(base64Encoded: String(value.dropFirst("plaintext:v1:".count))),
                      let text = String(data: data, encoding: .utf8) else { throw GrokQuotaError.credentials }
                return text
            }
            if value.hasPrefix("scoped:v1:") {
                let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, parts[2] == active else { throw GrokQuotaError.accountChanged }
                return try decrypt(String(parts[3]))
            }
            return try decrypt(value)
        }
        let token = try read(encoded)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw GrokQuotaError.credentials }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              claims["sub"] as? String == accountSlot else { throw GrokQuotaError.accountChanged }
        let team: Int?
        if let encoded = record["cursor-selected-team-id"] {
            guard let id = Int(try read(encoded)), id > 0 else { throw GrokQuotaError.credentials }
            team = id
        } else { team = nil }
        return Self(accessToken: token, accountSlot: accountSlot, teamID: team,
                    selectionID: selectionID(active: active, record: record))
    }

    private static func storagePassword(allowInteraction: Bool) throws -> Data {
        do { return try KeychainCredentialReader.read(service: "Grok Bot Safe Storage", allowInteraction: allowInteraction) }
        catch { throw GrokQuotaError.authorization }
    }

    /// Electron/macOS v10 safeStorage (AES-128-CBC, PBKDF2-HMAC-SHA1).
    static func decrypt(_ encoded: String, password: Data) throws -> String {
        guard let bytes = Data(base64Encoded: encoded), bytes.starts(with: Data("v10".utf8)),
              bytes.count > 3 else { throw GrokQuotaError.credentials }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derivation = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003, &key, key.count)
            }
        }
        guard derivation == kCCSuccess else { throw GrokQuotaError.credentials }
        let ciphertext = Data(bytes.dropFirst(3)), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let result = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, ciphertext.count, &output, output.count, &count)
        }
        guard result == kCCSuccess, let text = String(bytes: output.prefix(count), encoding: .utf8) else {
            throw GrokQuotaError.credentials
        }
        return text
    }
}

public enum GrokQuotaAPI {
    public static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    static func request(credentials: GrokQuotaCredentials) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        if let team = credentials.teamID { request.setValue(String(team), forHTTPHeaderField: "x-cursor-team-id") }
        return request
    }

    public static func fetch(credentials: GrokQuotaCredentials) async throws -> GrokBotQuota {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoGrokRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request(credentials: credentials))
            guard let http = response as? HTTPURLResponse else { throw GrokQuotaError.unavailable }
            if http.statusCode == 401 || http.statusCode == 403 { throw GrokQuotaError.credentials }
            guard http.statusCode == 200, data.count < 128 * 1024 else { throw GrokQuotaError.unavailable }
            return try decode(data, now: Date())
        } catch let error as GrokQuotaError { throw error }
        catch { throw GrokQuotaError.unavailable }
    }

    public static func decode(_ data: Data, now: Date) throws -> GrokBotQuota {
        struct Response: Decodable {
            var usagePercent: Double?
            var nextResetTimestampUtc: String?
            var usesPooledEnterpriseAllowance: Bool?
            var grokPlanLabel: String?
        }
        guard let value = try? JSONDecoder().decode(Response.self, from: data),
              value.usesPooledEnterpriseAllowance != true,
              let used = value.usagePercent, used.isFinite, used >= 0 else { throw GrokQuotaError.invalidResponse }
        var reset: Date?
        if let text = value.nextResetTimestampUtc {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = format.date(from: text)
            if reset == nil { format.formatOptions = [.withInternetDateTime]; reset = format.date(from: text) }
            guard reset != nil else { throw GrokQuotaError.invalidResponse }
        }
        return GrokBotQuota(usedPercent: used, resetAt: reset, readAt: now, plan: value.grokPlanLabel, source: .server)
    }
}

private final class NoGrokRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
