import DeepSeekBarWidgetShared
import SwiftUI
import WidgetKit

struct OverviewWidgetView: View {
    let snapshot: WidgetSnapshot?
    let date: Date
    let family: WidgetFamily
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.blue)
                Text("DeepSeek").fontWeight(.semibold)
                Spacer(minLength: 0)
                if let snapshot {
                    Circle().fill(statusColor(snapshot.isStale(at: date) ? 0 : snapshot.probeLevel))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(snapshot.isStale(at: date) ? "状态待更新" : snapshot.probeLabel)
                }
            }
            .font(.caption)

            if let snapshot {
                HStack(alignment: .top, spacing: 16) {
                    account(snapshot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if family == .systemMedium {
                        Divider()
                        details(snapshot)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                footer(snapshot)
            } else {
                Spacer(minLength: 0)
                Text("账户概览").font(.title3.weight(.semibold))
                Text(message ?? "点击打开 DeepSeekBar")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func account(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("账户余额").font(.caption2).foregroundStyle(.secondary)
            Text(snapshot.balance?.amount ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let usage = snapshot.currentUsage(at: date) {
                Text("今日 \(WidgetSnapshot.money(usage.todayCost, currency: usage.currency))")
                    .font(.caption).monospacedDigit()
                Text("\(WidgetSnapshot.tokens(usage.todayTokens)) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(usageHint(snapshot)).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func details(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("本月消费").font(.caption2).foregroundStyle(.secondary)
            Text(snapshot.currentUsage(at: date).map {
                WidgetSnapshot.money($0.monthCost, currency: $0.currency)
            } ?? "—")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            statusRow("API", label: snapshot.probeLabel, level: snapshot.probeLevel,
                      stale: snapshot.isStale(at: date))
            statusRow("官方", label: snapshot.officialLabel, level: snapshot.officialLevel,
                      stale: snapshot.isStale(at: date))
        }
    }

    private func statusRow(_ title: String, label: String, level: Int, stale: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor(stale ? 0 : level)).frame(width: 5, height: 5)
            Text("\(title) · \(stale ? "待更新" : label)")
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        let hint = warning(snapshot)
        return HStack(spacing: 4) {
            Image(systemName: hint == nil ? "clock" : "exclamationmark.circle")
            if let hint {
                Text(hint)
            } else {
                Text("同步于")
                Text(snapshot.generatedAt, style: .time)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(hint == nil ? Color.secondary : Color.orange)
        .lineLimit(1).minimumScaleFactor(0.75)
    }

    private func warning(_ snapshot: WidgetSnapshot) -> String? {
        if snapshot.isStale(at: date) { return "数据已过期 · 点击刷新" }
        if snapshot.usageState == .expired { return "登录已过期 · 点击登录" }
        if snapshot.balanceState == .unavailable { return "余额更新失败 · 点击重试" }
        if snapshot.usageState == .unavailable { return "用量更新失败 · 点击重试" }
        if snapshot.balance?.isAvailable == false { return "账户不可用 · 点击查看" }
        if snapshot.balanceState == .needsSetup { return "点击配置 API Key" }
        if snapshot.usageState == .needsSetup { return "点击登录查看用量" }
        if snapshot.currentUsage(at: date) == nil { return "今日用量待更新" }
        return nil
    }

    private func usageHint(_ snapshot: WidgetSnapshot) -> String {
        switch snapshot.usageState {
        case .needsSetup: return "登录后查看今日用量"
        case .expired: return "平台登录已过期"
        case .unavailable: return "用量暂不可用"
        case .available: return "今日用量待更新"
        }
    }

    private func statusColor(_ level: Int) -> Color {
        switch level {
        case 1: return .green
        case 2: return .orange
        case 3: return .red
        default: return .gray
        }
    }
}
