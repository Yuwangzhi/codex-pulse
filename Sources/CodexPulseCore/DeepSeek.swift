import Foundation

/// `GET {base}/user/balance` response. Amounts are strings on the wire, so decoding accepts
/// both string and number forms and never rounds them into a float before display.
public struct DeepSeekBalanceInfo: Codable, Equatable, Sendable {
    public var currency: String
    public var totalBalance: String
    public var grantedBalance: String?
    public var toppedUpBalance: String?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    public init(currency: String, totalBalance: String, grantedBalance: String? = nil, toppedUpBalance: String? = nil) {
        self.currency = currency; self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance; self.toppedUpBalance = toppedUpBalance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = (try? container.decode(String.self, forKey: .currency)) ?? ""
        totalBalance = Self.amount(container, .totalBalance) ?? ""
        grantedBalance = Self.amount(container, .grantedBalance)
        toppedUpBalance = Self.amount(container, .toppedUpBalance)
    }

    private static func amount(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return String(number) }
        return nil
    }

    public var amount: Double? { Double(totalBalance) }

    public var display: String { DisplayFormat.money(amount, currency: currency) }
}

public struct DeepSeekBalance: Codable, Equatable, Sendable {
    public var isAvailable: Bool?
    public var balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    public init(isAvailable: Bool?, balanceInfos: [DeepSeekBalanceInfo]) {
        self.isAvailable = isAvailable; self.balanceInfos = balanceInfos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try? container.decodeIfPresent(Bool.self, forKey: .isAvailable)
        balanceInfos = (try? container.decodeIfPresent([DeepSeekBalanceInfo].self, forKey: .balanceInfos)) ?? []
    }

    /// CNY is the account's own billing currency when present; otherwise the first entry wins.
    public var primary: DeepSeekBalanceInfo? {
        balanceInfos.first { $0.currency.uppercased() == "CNY" } ?? balanceInfos.first
    }

    public var display: String { primary?.display ?? "—" }
    public var amount: Double? { primary?.amount }
}

public enum BalanceEndpoint {
    /// Joins a base URL and a balance path without producing `//` or dropping a base path.
    public static func url(base: String, path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        var tail = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { tail = ProviderConfig.defaultBalancePath }
        if !tail.hasPrefix("/") { tail = "/" + tail }
        guard let url = URL(string: root + tail), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// One calendar day of observed balance samples. Pulse stores what it saw, not what it inferred.
public struct BalanceSample: Codable, Equatable, Sendable {
    public var first: Double
    public var last: Double
    public var samples: Int

    public init(first: Double, last: Double, samples: Int) {
        self.first = first; self.last = last; self.samples = samples
    }
}

public enum BalanceHistory {
    public static func record(_ history: [String: BalanceSample], day: String, value: Double) -> [String: BalanceSample] {
        var result = history
        if let existing = result[day] {
            result[day] = BalanceSample(first: existing.first, last: value, samples: existing.samples + 1)
        } else {
            result[day] = BalanceSample(first: value, last: value, samples: 1)
        }
        return result
    }

    /// Observed change within the day: positive means the balance dropped by that amount.
    /// A single sample cannot show a change, and a top-up reports a negative value.
    public static func observedSpend(_ history: [String: BalanceSample], day: String) -> Double? {
        guard let sample = history[day], sample.samples >= 2 else { return nil }
        return sample.first - sample.last
    }

    public static func trimmed(_ history: [String: BalanceSample], keepDays: Int, day: String) -> [String: BalanceSample] {
        let sorted = history.keys.sorted()
        guard sorted.count > keepDays else { return history }
        let keep = Set(sorted.suffix(keepDays) + [day])
        return history.filter { keep.contains($0.key) }
    }
}
