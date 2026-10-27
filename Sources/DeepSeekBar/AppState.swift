import Combine
import DeepSeekBarCore
import DeepSeekBarWidgetBridge
import DeepSeekBarWidgetShared
import Foundation
import SwiftUI
import WidgetKit

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
    @Published private(set) var todayUsageSamples: [TodayUsageSample] = []
    @Published private(set) var widgetSyncError: String?
    @Published private(set) var widgetLastSynced: Date?
    @Published private(set) var isWidgetBridgeReady = false

    var supportsDesktopWidgets: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("DeepSeekBarWidget.appex").path)
    }

    // 设置
    @Published var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes")
            restartTimer()
        }
    }

    @Published var appearancePreference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(
                appearancePreference.rawValue,
                forKey: AppearancePreference.storageKey)
        }
    }

    private let client = DeepSeekClient.shared
    private let widgetServer = WidgetSnapshotServer()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var refreshGeneration = 0
    private var refreshPending = false
    private var usageSnapshotDayKey: String?
    private var usageSnapshotTimeZoneIdentifier: String?
    private var usageUpdatedAt: Date?
    private var todayUsageSeries = TodayUsageSeries()
    private static let todayUsageSeriesKey = "todayUsageSeries.v1"

    var apiKey: String? { KeychainStore.read(.apiKey) }
    var platformToken: String? { KeychainStore.read(.platformToken) }
    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }
    var hasPlatformToken: Bool { !(platformToken ?? "").isEmpty }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = saved > 0 ? saved : 5
        appearancePreference = AppearancePreference.load()
        appearancePreference.applyToApp()
        loadTodayUsageSeries()
        observeCalendarChanges()
        startWidgetBridge()
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
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastUpdated = Date()
            synchronizeWidget()
        }

        repeat {
            refreshPending = false
            let generation = refreshGeneration
            async let balanceTask: () = refreshBalance(generation: generation)
            async let usageTask: () = refreshUsage(generation: generation)
            async let probeTask: () = refreshProbe(generation: generation)
            async let statusTask: () = refreshStatusPage(generation: generation)
            _ = await (balanceTask, usageTask, probeTask, statusTask)

            // 凭据/自然日可能在请求挂起期间改变；旧响应被丢弃后立即补跑一次。
            if generation != refreshGeneration { refreshPending = true }
        } while refreshPending
    }

    private func refreshBalance(generation: Int) async {
        guard generation == refreshGeneration else { return }
        guard let key = apiKey, !key.isEmpty else {
            balance = nil
            balanceError = DeepSeekError.missingAPIKey.localizedDescription
            return
        }
        do {
            let fetched = try await client.fetchBalance(apiKey: key)
            guard generation == refreshGeneration else { return }
            balance = fetched
            balanceError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            balanceError = error.localizedDescription
        }
    }

    private func refreshUsage(generation: Int) async {
        guard generation == refreshGeneration else { return }
        guard let token = platformToken, !token.isEmpty else {
            usage = nil
            usageSnapshotDayKey = nil
            usageSnapshotTimeZoneIdentifier = nil
            usageState = .idle
            clearTodayUsageHistory()
            return
        }
        usageState = .loading
        let requestedAt = Date()
        let timeZone = TimeZone.current
        do {
            let fetched = try await client.fetchUsageSummary(
                platformToken: token,
                now: requestedAt,
                timeZone: timeZone,
                preferredCurrency: balance?.currency ?? "CNY")
            guard generation == refreshGeneration else { return }

            let completedAt = Date()
            let requestedDay = TodayUsageSeries.dayKey(for: requestedAt, timeZone: timeZone)
            let completedDay = TodayUsageSeries.dayKey(for: completedAt, timeZone: timeZone)
            guard requestedDay == completedDay else {
                usage = nil
                usageSnapshotDayKey = nil
                usageSnapshotTimeZoneIdentifier = nil
                usageState = .loading
                refreshTodayUsageDay(now: completedAt)
                refreshPending = true
                return
            }

            usage = fetched
            usageSnapshotDayKey = completedDay
            usageSnapshotTimeZoneIdentifier = timeZone.identifier
            usageUpdatedAt = completedAt
            usageState = .available
            todayUsageSeries.record(
                tokens: fetched.todayTokens,
                at: completedAt,
                timeZone: timeZone)
            publishTodayUsageSeries()
        } catch DeepSeekError.invalidPlatformToken {
            guard generation == refreshGeneration else { return }
            usage = nil
            usageSnapshotDayKey = nil
            usageSnapshotTimeZoneIdentifier = nil
            usageState = .tokenExpired
        } catch {
            guard generation == refreshGeneration else { return }
            usageState = .unavailable(error.localizedDescription)
        }
    }

    private func refreshProbe(generation: Int) async {
        guard generation == refreshGeneration else { return }
        let fetched = await client.probeService(apiKey: apiKey)
        guard generation == refreshGeneration else { return }
        probe = fetched
    }

    private func refreshStatusPage(generation: Int) async {
        guard generation == refreshGeneration else { return }
        let fetched = await client.fetchStatusPage()
        guard generation == refreshGeneration else { return }
        statusPage = fetched
    }

    // MARK: - 凭据操作

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (apiKey ?? "") {
            balance = nil
            balanceError = nil
            probe = .unknown
        }
        if trimmed.isEmpty { KeychainStore.delete(.apiKey) } else { KeychainStore.save(trimmed, for: .apiKey) }
        synchronizeWidget()
        invalidateAndRefresh()
    }

    func savePlatformToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = (platformToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if previous != trimmed {
            usage = nil
            usageSnapshotDayKey = nil
            usageSnapshotTimeZoneIdentifier = nil
            usageState = trimmed.isEmpty ? .idle : .loading
            clearTodayUsageHistory()
        }
        if trimmed.isEmpty { KeychainStore.delete(.platformToken) } else { KeychainStore.save(trimmed, for: .platformToken) }
        synchronizeWidget()
        invalidateAndRefresh()
    }

    func clearCredentials() {
        KeychainStore.delete(.apiKey)
        KeychainStore.delete(.platformToken)
        balance = nil
        usage = nil
        usageSnapshotDayKey = nil
        usageSnapshotTimeZoneIdentifier = nil
        usageState = .idle
        balanceError = nil
        probe = .unknown
        statusPage = .unknown
        clearTodayUsageHistory()
        synchronizeWidget()
        invalidateCurrentRefresh()
    }

    // MARK: - 今日 token 折线采样

    /// 在弹窗显示、自然日变化或系统时区变化时清理过期点位。
    func refreshTodayUsageDay(now: Date = Date()) {
        if todayUsageSeries.retainDay(
            containing: now,
            timeZone: TimeZone.current) {
            publishTodayUsageSeries()
        }
    }

    /// 弹窗每次打开都会采一个新点；若睡眠跨日或时区通知遗漏，先隐藏过期的“今日”摘要。
    func refreshForPresentation(now: Date = Date()) {
        refreshTodayUsageDay(now: now)
        let timeZone = TimeZone.current
        let currentDay = TodayUsageSeries.dayKey(for: now, timeZone: timeZone)
        if usage != nil,
           (usageSnapshotDayKey != currentDay
            || usageSnapshotTimeZoneIdentifier != timeZone.identifier) {
            usage = nil
            usageSnapshotDayKey = nil
            usageSnapshotTimeZoneIdentifier = nil
            usageState = hasPlatformToken ? .loading : .idle
            invalidateCurrentRefresh()
        }
        Task { await refresh() }
    }

    private func loadTodayUsageSeries(now: Date = Date()) {
        if let data = UserDefaults.standard.data(forKey: Self.todayUsageSeriesKey),
           let decoded = try? JSONDecoder().decode(TodayUsageSeries.self, from: data) {
            todayUsageSeries = decoded
        } else {
            UserDefaults.standard.removeObject(forKey: Self.todayUsageSeriesKey)
        }
        _ = todayUsageSeries.retainDay(
            containing: now,
            timeZone: TimeZone.current)
        publishTodayUsageSeries()
    }

    private func clearTodayUsageHistory(now: Date = Date()) {
        todayUsageSeries.clear(at: now, timeZone: TimeZone.current)
        publishTodayUsageSeries()
    }

    private func publishTodayUsageSeries() {
        todayUsageSamples = todayUsageSeries.samples
        if let data = try? JSONEncoder().encode(todayUsageSeries) {
            UserDefaults.standard.set(data, forKey: Self.todayUsageSeriesKey)
        }
    }

    private func observeCalendarChanges() {
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.calendarContextDidChange()
                }
            }
            .store(in: &cancellables)
    }

    private func calendarContextDidChange(now: Date = Date()) {
        usage = nil
        usageSnapshotDayKey = nil
        usageSnapshotTimeZoneIdentifier = nil
        usageState = hasPlatformToken ? .loading : .idle
        refreshTodayUsageDay(now: now)
        synchronizeWidget()
        invalidateAndRefresh()
    }

    // MARK: - 桌面小组件（只共享展示快照，不共享凭据）

    private func startWidgetBridge() {
        guard supportsDesktopWidgets else { return }
        widgetServer.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.isWidgetBridgeReady = true
                    self.widgetSyncError = nil
                    self.synchronizeWidget()
                case .failure:
                    self.isWidgetBridgeReady = false
                    self.widgetSyncError = "小组件连接失败，请退出其他 DeepSeekBar 实例后重新启动。"
                }
            }
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.widgetServer.stop() }
            .store(in: &cancellables)
    }

    private func synchronizeWidget() {
        guard supportsDesktopWidgets else { return }
        var snapshot = WidgetSnapshot()
        snapshot.refreshIntervalMinutes = refreshIntervalMinutes
        snapshot.balanceState = !hasAPIKey ? .needsSetup
            : (balanceError == nil && balance != nil ? .available : .unavailable)
        if let balance {
            snapshot.balance = .init(currency: balance.currency, total: balance.total,
                                     isAvailable: balance.isAvailable, updatedAt: balance.updatedAt)
        }
        switch usageState {
        case .idle: snapshot.usageState = .needsSetup
        case .tokenExpired: snapshot.usageState = .expired
        case .unavailable: snapshot.usageState = .unavailable
        case .loading: snapshot.usageState = usage == nil ? .unavailable : .available
        case .available: snapshot.usageState = .available
        }
        if let usage, let usageUpdatedAt, let usageSnapshotTimeZoneIdentifier {
            snapshot.usage = .init(
                currency: usage.currency, todayCost: usage.todayCost, todayTokens: usage.todayTokens,
                monthCost: usage.monthCost, updatedAt: usageUpdatedAt,
                timeZoneIdentifier: usageSnapshotTimeZoneIdentifier)
        }
        snapshot.probeLevel = probe.level
        // Do not pass arbitrary server error bodies across the display-only bridge.
        snapshot.probeLabel = probe.level == 3 ? "探测异常" : probe.label
        switch statusPage {
        case .unknown, .undetermined:
            snapshot.officialLevel = 0
            snapshot.officialLabel = "未能判定"
        case .noIncident:
            snapshot.officialLevel = 1
            snapshot.officialLabel = "一切运行正常"
        case .unreachable:
            snapshot.officialLevel = 2
            snapshot.officialLabel = "无法访问"
        case .incident:
            snapshot.officialLevel = 3
            snapshot.officialLabel = "存在故障 / 降级"
        }
        let publishedAt = snapshot.generatedAt
        widgetServer.publish(snapshot) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isWidgetBridgeReady else { return }
                self.widgetLastSynced = publishedAt
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
            }
        }
    }

    private func invalidateCurrentRefresh() {
        refreshGeneration &+= 1
        if isRefreshing { refreshPending = true }
    }

    private func invalidateAndRefresh() {
        invalidateCurrentRefresh()
        Task { await refresh() }
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
