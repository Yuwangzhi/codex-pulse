import Foundation
import CodexPulseCore

/// Reads the DeepSeek balance endpoint with the account's own credential.
///
/// The credential is resolved in memory for each request: a key you stored in the keychain wins,
/// otherwise the account's `config.toml` provider entry (or its `env_key`) is used. Nothing is
/// written to disk and the token never reaches the UI, logs or diagnostics.
struct DeepSeekClient {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Result {
        var balance: DeepSeekBalance
        var source: ProviderConfig.ResolvedCredential.Source
        var provider: String
    }

    static func fetchBalance(account: AccountConfig, storedKey: String?,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Result {
        let home = account.expandedHome
        let configURL = home.appendingPathComponent("config.toml")
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let scan = ProviderConfig.scan(text)
        guard let credential = ProviderConfig.resolveCredential(scan: scan, hint: account.providerHint,
                                                               baseURL: account.effectiveBaseURL,
                                                               storedKey: storedKey, environment: environment) else {
            throw Failure(message: "没有找到 DeepSeek 凭据：可在设置中填写 API Key，或在 \(configURL.path) 中配置 provider 的 bearer token / env_key。")
        }
        guard let url = BalanceEndpoint.url(base: account.effectiveBaseURL, path: account.effectiveBalancePath) else {
            throw Failure(message: "余额接口地址无效，请检查 Base URL。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure(message: "余额请求失败：\(describe(error))") }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 401, 403: throw Failure(message: "余额接口返回 \(http.statusCode)：当前凭据无效或无权限。")
            case 404: throw Failure(message: "余额接口返回 404：请检查 Base URL 与路径 \(account.effectiveBalancePath)。")
            case 429: throw Failure(message: "余额接口返回 429：请求过于频繁，稍后自动重试。")
            default: throw Failure(message: "余额接口返回 \(http.statusCode)。")
            }
        }
        do {
            let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: data)
            guard !balance.balanceInfos.isEmpty else { throw Failure(message: "余额接口未返回余额条目。") }
            return Result(balance: balance, source: credential.source, provider: credential.provider)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "余额返回格式无法识别。")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet: return "网络不可用"
        case .timedOut: return "请求超时"
        case .cannotFindHost, .cannotConnectToHost: return "无法连接服务端"
        case .appTransportSecurityRequiresSecureConnection: return "系统安全策略拒绝了该地址"
        default: return urlError.localizedDescription
        }
    }
}

/// Keys the user typed into Pulse are kept in the macOS keychain, never in UserDefaults.
enum KeychainStore {
    private static let service = "com.yuwangzhi.codex-pulse"

    static func key(for account: UUID) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account.uuidString,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        query[kSecUseDataProtectionKeychain as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    @discardableResult
    static func setKey(_ value: String?, for account: UUID) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account.uuidString]
        var deleteQuery = base
        deleteQuery[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        var addQuery = base
        addQuery[kSecUseDataProtectionKeychain as String] = true
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}
