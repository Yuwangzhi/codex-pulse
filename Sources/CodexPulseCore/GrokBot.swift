import Foundation

public enum GrokQuotaSource: Sendable { case clientCache, server }

public struct GrokBotQuota: Sendable {
    public var usedPercent: Double
    public var resetAt: Date?
    public var readAt: Date
    public var expiresAt: Date?
    public var plan: String?
    public var source: GrokQuotaSource
    public var refreshFailed = false
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public init(usedPercent: Double, resetAt: Date? = nil, readAt: Date, expiresAt: Date? = nil, plan: String? = nil,
                source: GrokQuotaSource = .clientCache) {
        self.usedPercent = usedPercent; self.resetAt = resetAt; self.readAt = readAt; self.expiresAt = expiresAt; self.plan = plan
        self.source = source
    }
    public func isStale(now: Date) -> Bool {
        refreshFailed || now.timeIntervalSince(readAt) > (source == .server ? 120 : 300) || (expiresAt.map { $0 <= now } ?? false)
    }
}

public struct GrokBotSnapshot: Sendable {
    public var pid: Int32
    public var appVersion: String
    public var signedIn: Bool
    public var quota: GrokBotQuota?
    public var accountSlot: String?
    public init(pid: Int32, appVersion: String, signedIn: Bool, quota: GrokBotQuota? = nil, accountSlot: String? = nil) {
        self.pid = pid; self.appVersion = appVersion; self.signedIn = signedIn; self.quota = quota
        self.accountSlot = accountSlot
    }
}

/// Grok Bot 0.71.x exposes a desktop presence marker and an account-scoped usage cache.
/// This reader deliberately does not open secrets, transcripts, drafts or browser storage.
/// The cache does NOT supply authoritative task-running state.
public enum GrokBotReader {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Grok Bot")
    }
    private struct Presence: Decodable {
        var version: Int
        var pid: Int32
        var appVersion: String
        var signedIn: Bool
    }
    private struct Envelope<T: Decodable>: Decodable { var schemaVersion: Int; var value: T }
    private struct Cache: Decodable {
        struct Reading: Decodable {
            struct Usage: Decodable {
                var percentUsed: Double
                var nextResetMs: Double?
                var grokPlanLabel: String?
            }
            var usage: Usage
            var readAtMs: Double
        }
        var kind: String
        var reading: Reading?
        var expiresAtMs: Double?
    }
    /// Persistence file names are base32-encoded storage keys, not authentication material.
    public static func decodeKey(_ name: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt32 = 0, bits = 0
        var bytes: [UInt8] = []
        for byte in name.uppercased().utf8 {
            if byte == 61 { break }
            guard let value = alphabet.firstIndex(of: byte) else { return nil }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
            buffer &= bits == 0 ? 0 : (1 << bits) - 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }
    private static func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) < 128 * 1024 else {
            throw LocalReadError.unavailable("Grok Bot 缓存格式不兼容。")
        }
        return try Data(contentsOf: url)
    }
    public static func read(directory: URL = directory) throws -> GrokBotSnapshot? {
        let fm = FileManager.default
        let status = directory.appendingPathComponent("desktop-status.json")
        guard fm.fileExists(atPath: status.path) else { return nil }
        let decoder = JSONDecoder()
        let presence = try decoder.decode(Presence.self, from: boundedData(status))
        guard presence.version == 1, presence.pid > 0 else { return nil }
        var snapshot = GrokBotSnapshot(pid: presence.pid, appVersion: presence.appVersion, signedIn: presence.signedIn)
        guard presence.signedIn else { return snapshot }
        let cacheDirectory = directory.appendingPathComponent("sand-client-persistence")
        guard let urls = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return snapshot }
        let keys = urls.filter { $0.pathExtension == "blob" }.compactMap { url -> (String, URL)? in
            decodeKey(url.deletingPathExtension().lastPathComponent).map { ($0, url) }
        }
        guard let slotURL = keys.first(where: { $0.0 == "sand.client.slice.client-meta.account-slot" })?.1,
              let slot = try? decoder.decode(Envelope<String>.self, from: boundedData(slotURL)), slot.schemaVersion == 1 else { return snapshot }
        snapshot.accountSlot = slot.value
        // Match JS encodeURIComponent, and only the currently selected account.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        guard let scope = slot.value.addingPercentEncoding(withAllowedCharacters: allowed),
              let quotaURL = keys.first(where: { $0.0 == "sand.client.slice.account.\(scope).weekly-usage.cache" })?.1,
              let cache = try? decoder.decode(Envelope<Cache>.self, from: boundedData(quotaURL)),
              cache.schemaVersion == 2, cache.value.kind == "present", let reading = cache.value.reading,
              reading.usage.percentUsed.isFinite, (0...100).contains(reading.usage.percentUsed),
              reading.readAtMs.isFinite, reading.readAtMs > 0 else { return snapshot }
        func date(_ ms: Double?) -> Date? { ms.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil } }
        snapshot.quota = GrokBotQuota(usedPercent: reading.usage.percentUsed, resetAt: date(reading.usage.nextResetMs),
                                     readAt: Date(timeIntervalSince1970: reading.readAtMs / 1000),
                                     expiresAt: date(cache.value.expiresAtMs), plan: reading.usage.grokPlanLabel)
        return snapshot
    }
}
