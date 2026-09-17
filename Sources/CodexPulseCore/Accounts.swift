import Foundation

/// A monitored account. Every account is bound to one Codex data directory (`CODEX_HOME`),
/// because that directory carries the login state, the local session database and the
/// provider configuration that Pulse reads.
public enum AccountKind: String, Codable, CaseIterable, Sendable {
    /// ChatGPT / Codex login: quotas and account usage come from the Codex app server.
    case codex
    /// DeepSeek API key: balance comes from the DeepSeek balance endpoint, token usage from local Codex logs.
    case deepseek

    public var label: String { self == .codex ? "Codex" : "DeepSeek" }
    public var shortLabel: String { self == .codex ? "Codex" : "DS" }

    public var detail: String {
        switch self {
        case .codex: return "读取 codex app-server 的额度与账号用量"
        case .deepseek: return "读取 DeepSeek 余额接口与本机 Token 用量"
        }
    }

    public var symbol: String { self == .codex ? "person.crop.circle" : "bolt.horizontal.circle" }

    /// Splits local threads into the DeepSeek side and the Codex/OpenAI side.
    /// A thread counts as DeepSeek when its provider or model name says so.
    public static func isDeepSeekUsage(modelProvider: String, model: String) -> Bool {
        let provider = modelProvider.lowercased()
        let slug = model.lowercased()
        return provider.contains("deepseek") || slug.hasPrefix("deepseek") || slug.contains("deepseek")
    }

    public func matchesLocalUsage(modelProvider: String, model: String) -> Bool {
        let deepSeek = Self.isDeepSeekUsage(modelProvider: modelProvider, model: model)
        return self == .deepseek ? deepSeek : !deepSeek
    }
}

public struct AccountConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AccountKind
    /// Path to this account's Codex data directory.
    public var home: String
    /// Optional CLI override; empty means auto-detect a shared Codex CLI.
    public var cliPath: String
    /// DeepSeek only: API base URL, for example `https://api.deepseek.com`.
    public var baseURL: String
    /// DeepSeek only: balance endpoint path, for example `/user/balance`.
    public var balancePath: String
    /// Optional `model_providers.<name>` hint used to pick a credential from `config.toml`.
    public var providerHint: String
    /// True when the user stored a key for this account in the macOS keychain.
    public var hasStoredKey: Bool

    public init(id: UUID = UUID(), name: String, kind: AccountKind, home: String, cliPath: String = "",
                baseURL: String = "", balancePath: String = "", providerHint: String = "", hasStoredKey: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.home = home; self.cliPath = cliPath
        self.baseURL = baseURL; self.balancePath = balancePath; self.providerHint = providerHint
        self.hasStoredKey = hasStoredKey
    }

    public var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.label : name }
    public var expandedHome: URL { URL(fileURLWithPath: (home as NSString).expandingTildeInPath) }

    public var effectiveBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ProviderConfig.defaultBaseURL : trimmed
    }

    public var effectiveBalancePath: String {
        let trimmed = balancePath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ProviderConfig.defaultBalancePath : trimmed
    }

    public static func defaultAccount(home: URL) -> AccountConfig {
        let detected = ProviderConfig.detect(home: home)
        return AccountConfig(name: detected.kind.label, kind: detected.kind, home: home.path,
                             baseURL: detected.baseURL ?? "", providerHint: detected.providerName ?? "")
    }
}

public enum AccountRegistry {
    public static let accountsKey = "accounts"
    public static let selectedKey = "selectedAccountID"
    /// Legacy keys kept for a one-time migration of installations that predate multiple accounts.
    public static let legacyHomeKey = "codexHome"
    public static let legacyExecutableKey = "codexExecutable"

    public static func decode(_ data: Data?) -> [AccountConfig] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([AccountConfig].self, from: data)) ?? []
    }

    public static func encode(_ accounts: [AccountConfig]) -> Data? {
        try? JSONEncoder().encode(accounts)
    }

    /// Loads accounts, migrating a pre-0.3 installation or falling back to the default Codex home.
    public static func load(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment,
                            fileManager: FileManager = .default) -> (accounts: [AccountConfig], selected: UUID?) {
        let stored = decode(defaults.data(forKey: accountsKey))
        if !stored.isEmpty {
            let selected = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
            let valid = selected.flatMap { id in stored.contains { $0.id == id } ? id : nil }
            return (stored, valid ?? stored.first?.id)
        }
        let configured = defaults.string(forKey: legacyHomeKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["CODEX_HOME"]
        let home = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        var account = AccountConfig.defaultAccount(home: home)
        if let legacyExecutable = defaults.string(forKey: legacyExecutableKey), !legacyExecutable.isEmpty {
            account.cliPath = legacyExecutable
        }
        return ([account], account.id)
    }

    public static func save(_ accounts: [AccountConfig], selected: UUID?, defaults: UserDefaults = .standard) {
        defaults.set(encode(accounts), forKey: accountsKey)
        defaults.set(selected?.uuidString, forKey: selectedKey)
    }
}
