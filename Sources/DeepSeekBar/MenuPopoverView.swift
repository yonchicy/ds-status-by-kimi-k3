import DeepSeekBarCore
import SwiftUI

/// 菜单栏下拉弹窗主体
struct MenuPopoverView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            balanceSection
            Divider()
            usageSection
            Divider()
            statusSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
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
                    Text("本月消费").foregroundStyle(.secondary)
                    Text("\(u.symbol)\(u.monthCost, specifier: "%.4f") · \(AppState.formatTokens(u.monthTokens)) tokens")
                }
                GridRow {
                    Text("本月请求").foregroundStyle(.secondary)
                    Text("\(u.monthRequests) 次")
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

            if !u.daily.isEmpty {
                chartView(u.last7CalendarDays())
            }
        }
    }

    /// 近 7 日 tokens 迷你柱状图
    private func chartView(_ days: [DailyUsage]) -> some View {
        let maxTokens = max(days.map(\.tokens).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("近 7 日用量").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(height: max(2, 44 * CGFloat(day.tokens) / CGFloat(maxTokens)))
                        Text(dayLabel(day.date))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60)
        }
    }

    private func dayLabel(_ date: String) -> String {
        String(date.suffix(5)).replacingOccurrences(of: "-", with: "/")
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
