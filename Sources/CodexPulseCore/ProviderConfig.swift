import Foundation

/// One `[model_providers.<name>]` block of a Codex `config.toml`.
public struct ProviderEntry: Equatable, Sendable {
    public var name: String
    public var baseURL: String = ""
    public var bearerToken: String = ""
    public var envKey: String = ""
    public var wireAPI: String = ""

    public var isDeepSeek: Bool { ProviderConfig.isDeepSeek(provider: name, baseURL: baseURL) }
}

/// Reads only the fields Pulse needs from `config.toml`.
///
/// This is a deliberately small scanner rather than a full TOML implementation: it tracks
/// section headers, collects the handful of provider keys Pulse understands, and ignores
/// everything else without interpreting it.
public enum ProviderConfig {
    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultBalancePath = "/user/balance"

    public struct Scan: Equatable, Sendable {
        public var activeProvider: String = ""
        public var entries: [ProviderEntry] = []

        public func entry(named name: String) -> ProviderEntry? {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        public var activeEntry: ProviderEntry? { entry(named: activeProvider) }
    }

    public struct Detection: Equatable, Sendable {
        public var kind: AccountKind
        public var providerName: String?
        public var baseURL: String?
    }

    public static func isDeepSeek(provider: String, baseURL: String) -> Bool {
        let name = provider.lowercased()
        let host = URL(string: baseURL)?.host?.lowercased() ?? baseURL.lowercased()
        return name.contains("deepseek") || host.contains("deepseek")
    }

    public static func scan(_ text: String) -> Scan {
        var result = Scan()
        var current: ProviderEntry?

        func flush() {
            guard let entry = current else { return }
            if !entry.baseURL.isEmpty || !entry.bearerToken.isEmpty || !entry.envKey.isEmpty || !entry.wireAPI.isEmpty {
                if let index = result.entries.firstIndex(where: { $0.name == entry.name }) {
                    result.entries[index] = entry
                } else {
                    result.entries.append(entry)
                }
            }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                flush()
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                let parts = splitPath(name)
                if parts.count >= 2, parts[0] == "model_providers" {
                    current = ProviderEntry(name: unquote(parts[1]))
                }
                continue
            }
            guard let separator = firstUnquotedIndex(of: "=", in: line) else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            if var entry = current {
                switch key {
                case "base_url": entry.baseURL = value
                case "experimental_bearer_token": entry.bearerToken = value
                case "env_key": entry.envKey = value
                case "wire_api": entry.wireAPI = value
                case "name": if entry.name.isEmpty { entry.name = value }
                default: break
                }
                current = entry
            } else if key == "model_provider" {
                result.activeProvider = value
            }
        }
        flush()
        return result
    }

    public static func detect(home: URL) -> Detection {
        let url = home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Detection(kind: .codex, providerName: nil, baseURL: nil)
        }
        let scan = scan(text)
        let active = scan.activeEntry
        let deepSeek = active.map(\.isDeepSeek) ?? false
        if deepSeek {
            return Detection(kind: .deepseek, providerName: active?.name, baseURL: active?.baseURL)
        }
        if let entry = scan.entries.first(where: \.isDeepSeek) {
            return Detection(kind: .deepseek, providerName: entry.name, baseURL: entry.baseURL)
        }
        return Detection(kind: .codex, providerName: active?.name, baseURL: active?.baseURL)
    }

    // MARK: - Credentials

    public struct ResolvedCredential: Equatable, Sendable {
        public enum Source: String, Sendable {
            case storedKey = "钥匙串"
            case configToken = "config.toml"
            case environment = "环境变量"
        }
        public var token: String
        public var source: Source
        public var provider: String
    }

    /// Finds a bearer token for a DeepSeek account without ever writing it anywhere.
    /// Order: stored keychain value, the account's own `config.toml`, then the environment.
    public static func resolveCredential(scan: Scan, hint: String, baseURL: String,
                                         storedKey: String?, environment: [String: String]) -> ResolvedCredential? {
        if let storedKey, !storedKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return ResolvedCredential(token: storedKey, source: .storedKey, provider: hint.isEmpty ? "stored" : hint)
        }
        func token(from entry: ProviderEntry, source: ResolvedCredential.Source) -> ResolvedCredential? {
            if !entry.bearerToken.isEmpty {
                return ResolvedCredential(token: entry.bearerToken, source: source, provider: entry.name)
            }
            if !entry.envKey.isEmpty, let value = environment[entry.envKey], !value.isEmpty {
                return ResolvedCredential(token: value, source: .environment, provider: entry.name)
            }
            return nil
        }
        if !hint.isEmpty, let entry = scan.entry(named: hint), let found = token(from: entry, source: .configToken) {
            return found
        }
        let targetHost = URL(string: baseURL.isEmpty ? defaultBaseURL : baseURL)?.host?.lowercased()
        if let targetHost {
            for entry in scan.entries where URL(string: entry.baseURL)?.host?.lowercased() == targetHost {
                if let found = token(from: entry, source: .configToken) { return found }
            }
        }
        for entry in scan.entries where entry.isDeepSeek {
            if let found = token(from: entry, source: .configToken) { return found }
        }
        for entry in scan.entries {
            if let found = token(from: entry, source: .configToken) { return found }
        }
        for key in ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY", "DS_API_KEY"] {
            if let value = environment[key], !value.isEmpty {
                return ResolvedCredential(token: value, source: .environment, provider: key)
            }
        }
        return nil
    }

    // MARK: - Small helpers

    private static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        var result = ""
        for character in line {
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "#" && !inSingle && !inDouble { break }
            result.append(character)
        }
        return result
    }

    private static func firstUnquotedIndex(of target: Character, in line: String) -> String.Index? {
        var inSingle = false, inDouble = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == target && !inSingle && !inDouble { return index }
            index = line.index(after: index)
        }
        return nil
    }

    /// Splits `model_providers."my provider"` while keeping quoted segments intact.
    private static func splitPath(_ text: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var inSingle = false, inDouble = false
        for character in text {
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "." && !inSingle && !inDouble { parts.append(buffer); buffer = ""; continue }
            buffer.append(character)
        }
        parts.append(buffer)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return value.replacingOccurrences(of: "\\\"", with: "\"")
    }
}
