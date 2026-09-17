import Foundation

public struct QuotaWindow: Codable, Equatable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    public var resetsAt: Double?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public var label: String {
        guard let minutes = windowDurationMins else { return "额度窗口" }
        if minutes == 10080 { return "每周额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

public struct Credits: Codable, Equatable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?
    public var display: String {
        if unlimited { return "不限量" }
        guard let balance, let amount = Double(balance) else { return "未提供" }
        return amount.formatted(.number.precision(.fractionLength(2)))
    }
}

public struct QuotaBucket: Codable, Identifiable, Equatable {
    public var limitId: String?
    public var limitName: String?
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var credits: Credits?
    public var planType: String?
    public var spendControlReached: Bool?
    public var rateLimitReachedType: String?
    public var id: String { limitId ?? "codex" }
    public var name: String { limitName ?? (id == "codex" ? "Codex" : id) }
}

public struct QuotaResponse: Codable {
    public struct ResetCredits: Codable { public var availableCount: Int }
    public var rateLimits: QuotaBucket
    public var rateLimitsByLimitId: [String: QuotaBucket]?
    public var ordinaryUsageAllowed: Bool?
    public var rateLimitResetCredits: ResetCredits?
    public var buckets: [QuotaBucket] {
        var all = rateLimitsByLimitId ?? [:]
        all[rateLimits.id] = rateLimits
        return all.map { key, value in
            var bucket = value
            if bucket.limitId == nil { bucket.limitId = key }
            return bucket
        }.sorted { a, b in
            if a.id == "codex" { return b.id != "codex" }
            if b.id == "codex" { return false }
            return a.id < b.id
        }
    }
}

public struct AccountUsage: Codable {
    public struct Summary: Codable {
        public var lifetimeTokens: Int64?
        public var peakDailyTokens: Int64?
        public var currentStreakDays: Int?
        public var longestStreakDays: Int?
    }
    public struct Day: Codable, Identifiable {
        public var startDate: String
        public var tokens: Int64
        public var id: String { startDate }
    }
    public var summary: Summary
    public var dailyUsageBuckets: [Day]?
    public var recentDays: [Day] { Array((dailyUsageBuckets ?? []).sorted { $0.startDate < $1.startDate }.suffix(7)) }
}

public enum TaskState: String, Codable, Sendable {
    case running, quiet, completed, interrupted, unknown
    public var label: String {
        switch self {
        case .running: return "执行中"
        case .quiet: return "待确认"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .unknown: return "未知"
        }
    }
}

public struct SessionInfo: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String
    public var model: String
    public var rolloutPath: String
    public var updatedAt: Date
    public var totalTokens: Int64
    public var state: TaskState = .unknown
    public var activity: String = "等待任务记录"
    public var lastEventAt: Date?
    public var startedAt: Date?
    public var turnTokens: Int64?
    public var contextPercent: Double?
    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public init(id: String, title: String, cwd: String, model: String, rolloutPath: String, updatedAt: Date, totalTokens: Int64) {
        self.id = id; self.title = title; self.cwd = cwd; self.model = model
        self.rolloutPath = rolloutPath; self.updatedAt = updatedAt; self.totalTokens = totalTokens
    }
}

public enum DisplayFormat {
    public static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let n = Double(value)
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }
    public static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return code.isEmpty ? "" : code.uppercased() + " "
        }
    }
    /// Money is shown with the currency the service reported; an unknown amount stays unknown.
    public static func money(_ value: Double?, currency: String, fractionDigits: Int = 2) -> String {
        guard let value else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        return currencySymbol(currency) + number
    }
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "尚未更新" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }
}
