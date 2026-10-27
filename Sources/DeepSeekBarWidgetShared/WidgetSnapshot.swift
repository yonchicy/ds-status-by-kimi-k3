import Foundation

/// Only display data crosses the process boundary. Credentials stay in the app's Keychain.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let kind = "DeepSeekBarOverview"
    public static let openURL = URL(string: "deepseekbar://overview")!

    public var version = currentVersion
    public var generatedAt: Date
    public var refreshIntervalMinutes = 5
    public var balance: Balance?
    public var usage: Usage?
    public var balanceState: DataState = .needsSetup
    public var usageState: DataState = .needsSetup
    public var probeLevel = 0
    public var probeLabel = "尚未探测"
    public var officialLevel = 0
    public var officialLabel = "尚未检查"

    public init(generatedAt: Date = Date()) { self.generatedAt = generatedAt }

    public enum DataState: String, Codable, Sendable {
        case needsSetup, available, unavailable, expired
    }

    public struct Balance: Codable, Equatable, Sendable {
        public var currency: String
        public var total: Double
        public var isAvailable: Bool
        public var updatedAt: Date

        public init(currency: String, total: Double, isAvailable: Bool, updatedAt: Date) {
            self.currency = currency
            self.total = total
            self.isAvailable = isAvailable
            self.updatedAt = updatedAt
        }

        public var amount: String { WidgetSnapshot.money(total, currency: currency) }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var currency: String
        public var todayCost: Double
        public var todayTokens: Int
        public var monthCost: Double
        public var updatedAt: Date
        public var timeZoneIdentifier: String

        public init(currency: String, todayCost: Double, todayTokens: Int,
                    monthCost: Double, updatedAt: Date, timeZoneIdentifier: String) {
            self.currency = currency
            self.todayCost = todayCost
            self.todayTokens = todayTokens
            self.monthCost = monthCost
            self.updatedAt = updatedAt
            self.timeZoneIdentifier = timeZoneIdentifier
        }

        public func isToday(at date: Date, timeZone: TimeZone) -> Bool {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return timeZone.identifier == timeZoneIdentifier
                && calendar.isDate(updatedAt, inSameDayAs: date)
        }
    }

    /// A stopped app must not leave a permanently green, apparently live widget.
    public var expiresAt: Date {
        generatedAt.addingTimeInterval(TimeInterval(max(15, min(refreshIntervalMinutes, 60) * 2) * 60))
    }

    public func isStale(at date: Date) -> Bool { date >= expiresAt }

    public func currentUsage(at date: Date, timeZone: TimeZone = .current) -> Usage? {
        guard usageState == .available || usageState == .unavailable,
              let usage, usage.isToday(at: date, timeZone: timeZone) else { return nil }
        return usage
    }

    /// Include expiry and midnight entries, even if the app quits and never requests another reload.
    public func timelineDates(from now: Date, timeZone: TimeZone = .current) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return Array(Set([now, expiresAt, midnight].filter { $0 >= now })).sorted()
    }

    public static func money(_ amount: Double, currency: String) -> String {
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
        return symbol + String(format: amount == 0 || abs(amount) >= 0.01 ? "%.2f" : "%.4f", amount)
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }

    /// Gallery previews only; never used as a fallback for real data.
    public static func preview(at date: Date = Date()) -> Self {
        var value = Self(generatedAt: date)
        value.balance = Balance(currency: "CNY", total: 128.60, isAvailable: true, updatedAt: date)
        value.usage = Usage(currency: "CNY", todayCost: 0.35, todayTokens: 152_400,
                            monthCost: 12.80, updatedAt: date, timeZoneIdentifier: TimeZone.current.identifier)
        value.balanceState = .available
        value.usageState = .available
        value.probeLevel = 1
        value.probeLabel = "正常 · 186ms"
        value.officialLevel = 1
        value.officialLabel = "一切运行正常"
        return value
    }
}
