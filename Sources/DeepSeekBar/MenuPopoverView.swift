import DeepSeekBarCore
import Charts
import SwiftUI

/// 菜单栏下拉弹窗主体
struct MenuPopoverView: View {
    var refreshOnAppear = true
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var hoveredTodayUsageSample: TodayUsageSample?
    @State private var hoveredDailyUsage: DailyUsage?
    @State private var accountContentHeight: CGFloat = 400

    private var maximumContentHeight: CGFloat {
        max(246, min(686, (NSScreen.main?.visibleFrame.height ?? 860) - 174))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                accountContent
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: AccountContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            // MenuBarExtra 以固有尺寸创建窗口；仅设 maxHeight 会让滚动区折叠为零。
            .frame(height: min(accountContentHeight, maximumContentHeight))
            .scrollIndicators(.visible)
            .onPreferenceChange(AccountContentHeightKey.self) { height in
                if height > 0, height.isFinite { accountContentHeight = height }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            if refreshOnAppear { state.refreshForPresentation() }
        }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            balanceSection
            Divider()
            usageSection
            Divider()
            statusSection
        }
    }

    // MARK: - 余额

    @ViewBuilder
    private var balanceSection: some View {
        sectionTitle("账户余额")
        if let b = state.balance {
            HStack(alignment: .firstTextBaseline) {
                Text("\(b.symbol)\(b.total, specifier: "%.2f")")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Spacer()
                availabilityBadge(b.isAvailable)
            }
            HStack {
                Text("充值 \(b.symbol)\(b.toppedUp, specifier: "%.2f")")
                Text("·")
                Text("赠送 \(b.symbol)\(b.granted, specifier: "%.2f")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let err = state.balanceError {
            errorRow(err, fixHint: state.hasAPIKey ? nil : "在设置中填入 API Key")
        } else {
            Text("加载中…").foregroundStyle(.secondary)
        }
    }

    private func availabilityBadge(_ available: Bool) -> some View {
        Text(available ? "可用" : "不可用")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(available ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
            .foregroundStyle(available ? Color.green : Color.red)
            .clipShape(Capsule())
    }

    // MARK: - 消费/用量

    @ViewBuilder
    private var usageSection: some View {
        sectionTitle("消费与用量")
        switch state.usageState {
        case .idle:
            VStack(alignment: .leading, spacing: 6) {
                Text("查看消费明细需要平台登录凭证")
                    .font(.caption).foregroundStyle(.secondary)
                Button("登录 DeepSeek 平台获取") {
                    openWindow(id: "login")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        case .loading where state.usage == nil:
            Text("加载中…").foregroundStyle(.secondary)
        case .tokenExpired:
            VStack(alignment: .leading, spacing: 6) {
                errorRow("平台登录已过期", fixHint: nil)
                Button("重新登录") {
                    openWindow(id: "login")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        case .unavailable(let msg) where state.usage == nil:
            errorRow(msg, fixHint: nil)
        default:
            if let u = state.usage { usageContent(u) }
        }
    }

    private func usageContent(_ u: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("今日消费").foregroundStyle(.secondary)
                    Text("\(u.symbol)\(u.todayCost, specifier: "%.4f") · \(AppState.formatTokens(u.todayTokens)) tokens")
                        .gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("今日 Flash").foregroundStyle(.secondary)
                    modelUsageText(u.todayFlashUsage, symbol: u.symbol)
                }
                GridRow {
                    Text("今日 Pro").foregroundStyle(.secondary)
                    modelUsageText(u.todayProUsage, symbol: u.symbol)
                }
                GridRow {
                    Text("本月消费").foregroundStyle(.secondary)
                    Text("\(u.symbol)\(u.monthCost, specifier: "%.4f") · \(AppState.formatTokens(u.monthTokens)) tokens")
                }
                GridRow {
                    Text("模型请求").foregroundStyle(.secondary)
                    Text("\(u.monthRequests) 次")
                        .help("本月模型请求数；Search / Fetch 调用次数单独列在下方")
                }
                if let rate = u.cacheHitRate {
                    GridRow {
                        Text("缓存命中率").foregroundStyle(.secondary)
                        Text("\(rate * 100, specifier: "%.1f")%")
                    }
                }
                if let model = u.topModel {
                    GridRow {
                        Text("主力模型").foregroundStyle(.secondary)
                        Text(model).lineLimit(1)
                    }
                }
            }
            .font(.callout)

            ToolUsageView(symbol: u.symbol, usage: u.toolUsage)

            todayUsageChart

            if !u.daily.isEmpty {
                chartView(u.last7CalendarDays())
            }
        }
    }

    /// DeepSeek 只返回当日累计值；此图按 App 每次成功刷新的时间采样。
    private var todayUsageChart: some View {
        let samples = state.todayUsageSamples
        let hoveredSample = hoveredTodayUsageSample.flatMap { selected in
            samples.first { $0.id == selected.id }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日累计 Token")
                Spacer(minLength: 8)
                if let hoveredSample {
                    Text("\(timeLabel(hoveredSample.timestamp)) · \(exactTokenLabel(hoveredSample.tokens))")
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("按刷新时间采样")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if samples.isEmpty {
                Text("成功刷新后开始记录今日趋势")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                todayUsageLineChart(samples)
            }
        }
    }

    private func todayUsageLineChart(_ samples: [TodayUsageSample]) -> some View {
        let maxTokens = samples.map(\.tokens).max() ?? 0
        let yMax = max(Double(maxTokens) * 1.08, 1)
        let hoveredSample = hoveredTodayUsageSample.flatMap { selected in
            samples.first { $0.id == selected.id }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let latestTime = samples.last?.timestamp ?? Date()
        let startOfDay = calendar.startOfDay(for: latestTime)
        let domainEnd = max(latestTime, startOfDay.addingTimeInterval(60 * 60))

        return Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("时间", sample.timestamp),
                    yStart: .value("基线", 0),
                    yEnd: .value("Token", Double(sample.tokens)))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.accentColor.opacity(0.10))

                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Token", Double(sample.tokens)))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
            }

            if let latest = samples.last {
                PointMark(
                    x: .value("时间", latest.timestamp),
                    y: .value("Token", Double(latest.tokens)))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(22)
            }

            if let hoveredSample {
                RuleMark(x: .value("悬停时间", hoveredSample.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("悬停时间", hoveredSample.timestamp),
                    y: .value("悬停 Token", Double(hoveredSample.tokens)))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(42)
            }
        }
        .chartXScale(domain: startOfDay...domainEnd)
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(AppState.formatTokens(Int(tokens)))
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartOverlay { chartProxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrameAnchor = chartProxy.plotFrame else {
                                if hoveredTodayUsageSample != nil {
                                    hoveredTodayUsageSample = nil
                                }
                                return
                            }
                            let plotFrame = geometry[plotFrameAnchor]
                            guard plotFrame.contains(location),
                                  let timestamp: Date = chartProxy.value(
                                    atX: location.x - plotFrame.minX
                                  ) else {
                                if hoveredTodayUsageSample != nil {
                                    hoveredTodayUsageSample = nil
                                }
                                return
                            }
                            let nearest = nearestSample(
                                to: timestamp,
                                in: samples
                            )
                            if hoveredTodayUsageSample?.id != nearest?.id {
                                hoveredTodayUsageSample = nearest
                            }
                        case .ended:
                            if hoveredTodayUsageSample != nil {
                                hoveredTodayUsageSample = nil
                            }
                        }
                    }
            }
        }
        .frame(height: 92)
        .accessibilityLabel("今日累计 Token 趋势")
        .accessibilityValue(
            hoveredSample.map {
                "\(timeLabel($0.timestamp))，\(exactTokenLabel($0.tokens))"
            } ?? "最新 \(exactTokenLabel(samples.last?.tokens ?? 0))"
        )
    }

    /// 近 7 日 tokens 迷你柱状图
    private func chartView(_ days: [DailyUsage]) -> some View {
        let maxTokens = max(days.map(\.tokens).max() ?? 1, 1)
        let hoveredDay = hoveredDailyUsage.flatMap { selected in
            days.first { $0.id == selected.id }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 7 日用量")
                Spacer(minLength: 8)
                if let hoveredDay {
                    Text("\(dayLabel(hoveredDay.date)) · \(exactTokenLabel(hoveredDay.tokens))")
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("悬停查看详情")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    let isHovered = hoveredDailyUsage?.id == day.id
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(isHovered ? 1 : 0.72))
                            .frame(height: max(2, 44 * CGFloat(day.tokens) / CGFloat(maxTokens)))
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(
                                        Color.primary.opacity(isHovered ? 0.28 : 0),
                                        lineWidth: 1
                                    )
                            }
                        Text(dayLabel(day.date))
                            .font(.system(size: 8))
                            .foregroundStyle(isHovered ? .primary : .tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        if isInside {
                            hoveredDailyUsage = day
                        } else if hoveredDailyUsage?.id == day.id {
                            hoveredDailyUsage = nil
                        }
                    }
                    .help("\(dayLabel(day.date)) · \(exactTokenLabel(day.tokens))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date)
                    .accessibilityValue(exactTokenLabel(day.tokens))
                }
            }
            .frame(height: 60)
            .animation(.easeOut(duration: 0.12), value: hoveredDailyUsage?.id)
        }
    }

    private func dayLabel(_ date: String) -> String {
        String(date.suffix(5)).replacingOccurrences(of: "-", with: "/")
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func exactTokenLabel(_ tokens: Int) -> String {
        "\(tokens.formatted(.number.grouping(.automatic))) tokens"
    }

    private func modelUsageText(_ usage: TodayModelUsage, symbol: String) -> Text {
        Text("\(symbol)\(usage.cost, specifier: "%.4f") · \(AppState.formatTokens(usage.tokens)) tokens")
    }

    private func nearestSample(
        to timestamp: Date,
        in samples: [TodayUsageSample]
    ) -> TodayUsageSample? {
        samples.min {
            abs($0.timestamp.timeIntervalSince(timestamp))
                < abs($1.timestamp.timeIntervalSince(timestamp))
        }
    }

    // MARK: - 服务状态

    @ViewBuilder
    private var statusSection: some View {
        sectionTitle("服务状态")
        HStack {
            statusDot(level: state.probe.level)
            Text("API 探测").foregroundStyle(.secondary)
            Spacer()
            Text(state.probe.label)
        }
        .font(.callout)
        HStack {
            statusDot(level: statusPageLevel)
            Text("官方状态页").foregroundStyle(.secondary)
            Spacer()
            Text(state.statusPage.label).lineLimit(1)
            Link("打开", destination: URL(string: "https://status.deepseek.com/")!)
        }
        .font(.callout)
    }

    private var statusPageLevel: Int {
        switch state.statusPage {
        case .unknown, .undetermined: return 0
        case .noIncident: return 1
        case .unreachable: return 2
        case .incident: return 3
        }
    }

    private func statusDot(level: Int) -> some View {
        let color: Color = switch level {
        case 1: .green
        case 2: .orange
        case 3: .red
        default: .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - 底部操作栏

    private var footer: some View {
        HStack(spacing: 12) {
            if let t = state.lastUpdated {
                Text("更新于 \(t, style: .time)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await state.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
            .help("设置")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
    }

    // MARK: - 通用小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func errorRow(_ message: String, fixHint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message).font(.callout).foregroundStyle(.red)
            if let fixHint {
                Text(fixHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}

private struct AccountContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
