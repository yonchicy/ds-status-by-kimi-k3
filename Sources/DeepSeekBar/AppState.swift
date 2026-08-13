import DeepSeekBarCore
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // 数据
    @Published private(set) var balance: BalanceSnapshot?
    @Published private(set) var usage: UsageSummary?
    @Published private(set) var usageState: UsageState = .idle
    @Published private(set) var probe: ProbeStatus = .unknown
    @Published private(set) var statusPage: StatusPageResult = .unknown
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    // 设置
    @Published var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes")
            restartTimer()
        }
    }

    private let client = DeepSeekClient.shared
    private var timer: Timer?

    var apiKey: String? { KeychainStore.read(.apiKey) }
    var platformToken: String? { KeychainStore.read(.platformToken) }
    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }
    var hasPlatformToken: Bool { !(platformToken ?? "").isEmpty }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = saved > 0 ? saved : 5
        restartTimer()
        Task { await refresh() }
    }

    // MARK: - 定时刷新

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalMinutes * 60),
                                     repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    // MARK: - 刷新主流程（四类请求并发，互不影响）

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastUpdated = Date()
        }

        async let balanceTask: () = refreshBalance()
        async let usageTask: () = refreshUsage()
        async let probeTask: () = refreshProbe()
        async let statusTask: () = refreshStatusPage()
        _ = await (balanceTask, usageTask, probeTask, statusTask)
    }

    private func refreshBalance() async {
        guard let key = apiKey, !key.isEmpty else {
            balance = nil
            balanceError = DeepSeekError.missingAPIKey.localizedDescription
            return
        }
        do {
            balance = try await client.fetchBalance(apiKey: key)
            balanceError = nil
        } catch {
            balanceError = error.localizedDescription
        }
    }

    private func refreshUsage() async {
        guard let token = platformToken, !token.isEmpty else {
            usage = nil
            usageState = .idle
            return
        }
        usageState = .loading
        do {
            usage = try await client.fetchUsageSummary(platformToken: token)
            usageState = .available
        } catch DeepSeekError.invalidPlatformToken {
            usage = nil
            usageState = .tokenExpired
        } catch {
            usageState = .unavailable(error.localizedDescription)
        }
    }

    private func refreshProbe() async {
        probe = await client.probeService(apiKey: apiKey)
    }

    private func refreshStatusPage() async {
        statusPage = await client.fetchStatusPage()
    }

    // MARK: - 凭据操作

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainStore.delete(.apiKey) } else { KeychainStore.save(trimmed, for: .apiKey) }
        Task { await refresh() }
    }

    func savePlatformToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainStore.delete(.platformToken) } else { KeychainStore.save(trimmed, for: .platformToken) }
        Task { await refresh() }
    }

    func clearCredentials() {
        KeychainStore.delete(.apiKey)
        KeychainStore.delete(.platformToken)
        balance = nil
        usage = nil
        usageState = .idle
        balanceError = nil
    }

    // MARK: - 菜单栏标题

    /// 优先显示「今日消费 · 今日 tokens」；未配置/未取到平台用量时回退到总余额；再不行显示占位
    var menuLabel: String {
        if let u = usage, usageState == .available {
            return "\(u.symbol)\(Self.formatCost(u.todayCost)) · \(Self.formatTokens(u.todayTokens))"
        }
        if let b = balance {
            let warn = b.isAvailable ? "" : " ⚠"
            return "\(b.symbol)\(String(format: "%.2f", b.total))\(warn)"
        }
        if balanceError != nil { return "DS !" }
        return "DS …"
    }

    /// 金额自适应格式：≥0.01 两位小数；极小金额四位，避免轻量用户整天显示 0.00
    static func formatCost(_ cost: Double) -> String {
        if cost >= 0.01 || cost == 0 {
            return String(format: "%.2f", cost)
        }
        return String(format: "%.4f", cost)
    }

    /// token 数缩写：123.4K / 5.67M
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
