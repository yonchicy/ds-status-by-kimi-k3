import Foundation

// Compiled into the test-only Core module so production initializers need not be widened.
public extension BalanceSnapshot {
    static func popoverFixture(at now: Date) -> Self {
        .init(currency: "CNY", total: 128.60, granted: 8.60, toppedUp: 120,
              isAvailable: true, updatedAt: now)
    }
}

public extension UsageSummary {
    static func popoverFixture(at now: Date, toolCount: Int = 2) -> Self {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return .init(
            currency: "CNY", todayTokens: 152_400, todayCost: 0.895,
            todayFlashUsage: .init(tokens: 140_000, cost: 0.15),
            todayProUsage: .init(tokens: 12_400, cost: 0.05),
            toolUsage: (0..<toolCount).map { index in
                .init(name: "tool-\(index)", today: .init(requests: 123, cost: 0.615),
                      month: .init(requests: 2468, cost: 12.34))
            },
            monthTokens: 3_452_000, monthCost: 24.945, monthRequests: 309,
            topModel: "deepseek-flash", cacheHitRate: 0.825,
            daily: (0..<7).map { offset in
                let date = calendar.date(byAdding: .day, value: offset - 6, to: now)!
                return .init(date: formatter.string(from: date), tokens: 40_000 + offset * 18_000,
                             cost: 0.1, requests: 12)
            })
    }
}
