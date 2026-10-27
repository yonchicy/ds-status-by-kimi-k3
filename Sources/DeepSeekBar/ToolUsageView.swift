import DeepSeekBarCore
import SwiftUI

/// 按次计费的工具与模型 tokens 分开显示，金额已包含在账户消费中。
struct ToolUsageView: View {
    let symbol: String
    let usage: [ToolUsageSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("网页搜索与抓取")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Link("计费规则", destination: URL(string: "https://api-docs.deepseek.com/zh-cn/guides/search/")!)
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }

            if usage.isEmpty {
                Text("本月暂无搜索 / 抓取用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("API").gridColumnAlignment(.leading)
                        Text("今日")
                        Text("本月")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    ForEach(usage) { tool in
                        toolRow(tool.name, today: tool.today, month: tool.month)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("按平台账单统计 · 已计入总消费")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolRow(_ name: String, today: ToolUsage, month: ToolUsage) -> some View {
        GridRow {
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80, alignment: .leading)
                .help(name)
            usageCell(today)
            usageCell(month)
        }
    }

    private func usageCell(_ usage: ToolUsage) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(symbol)\(usage.cost, specifier: "%.4f")")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Text("\(usage.requests) 次")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}
