import DeepSeekBarWidgetShared
import SwiftUI
import WidgetKit

struct OverviewEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var message: String?
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        OverviewEntry(date: Date(), snapshot: .preview())
    }

    func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await readEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
        Task {
            let entry = await readEntry()
            let dates = entry.snapshot?.timelineDates(from: entry.date) ?? [entry.date]
            let entries = dates.map {
                OverviewEntry(date: $0, snapshot: entry.snapshot, message: entry.message)
            }
            // Reloads are requests; WidgetKit chooses the actual schedule. The app also reloads on sync.
            let minutes = max(1, min(entry.snapshot?.refreshIntervalMinutes ?? 5, 60))
            completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(Double(minutes * 60)))))
        }
    }

    private func readEntry() async -> OverviewEntry {
        do {
            let snapshot = try await WidgetSnapshotClient().fetch()
            return OverviewEntry(date: Date(), snapshot: snapshot,
                                 message: snapshot == nil ? "打开应用，配置账户并刷新" : nil)
        } catch {
            return OverviewEntry(date: Date(), snapshot: nil, message: "请保持 DeepSeekBar 运行，点击打开应用重试")
        }
    }
}

@main
struct DeepSeekBarWidget: Widget {
    let kind = WidgetSnapshot.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OverviewProvider()) { entry in
            OverviewWidgetContent(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color.blue.opacity(0.13), Color.cyan.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .widgetURL(WidgetSnapshot.openURL)
                .privacySensitive()
        }
        .configurationDisplayName("DeepSeek 账户概览")
        .description("在桌面查看余额、今日用量和服务状态。由菜单栏应用同步。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct OverviewWidgetContent: View {
    @Environment(\.widgetFamily) private var family
    let entry: OverviewEntry

    var body: some View {
        OverviewWidgetView(snapshot: entry.snapshot, date: entry.date,
                           family: family, message: entry.message)
    }
}
