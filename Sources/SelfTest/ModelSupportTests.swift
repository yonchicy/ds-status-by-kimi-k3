import DeepSeekBarCore
import Foundation

private typealias ModelSupportRow = (model: String?, tokens: Int, cost: Double)

/// 使用平台的嵌套响应结构走解码与聚合，避免依赖分类器的私有接口。
private func modelSupportSummary(today: [ModelSupportRow], earlier: [ModelSupportRow] = []) throws -> UsageSummary {
    func records(_ rows: [ModelSupportRow], cost: Bool) -> [[String: Any]] {
        rows.map { row in
            var record: [String: Any] = ["usage": [
                ["type": "RESPONSE_TOKEN", "amount": cost ? String(row.cost) : String(row.tokens)],
                ["type": "REQUEST", "amount": cost ? "90" : "1"]
            ]]
            if let model = row.model { record["model"] = model }
            return record
        }
    }
    func businessData(cost: Bool) -> [String: Any] {
        ["currency": "CNY", "total": records(earlier + today, cost: cost), "days": [
            ["date": "2026-09-22", "data": records(earlier, cost: cost)],
            ["date": "2026-09-23", "data": records(today, cost: cost)]
        ]]
    }
    func envelope(_ payload: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "code": 0, "msg": "ok",
            "data": ["biz_code": 0, "biz_msg": "", "biz_data": payload]
        ])
    }

    let amount = try JSONDecoder().decode(AmountEnvelope.self, from: envelope(businessData(cost: false)))
    let cost = try JSONDecoder().decode(CostEnvelope.self, from: envelope([businessData(cost: true)]))
    guard let amountData = amount.data?.biz_data, let costData = cost.data?.biz_data?.first else {
        throw DeepSeekError.parseFailed("model support fixture")
    }
    let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
    return DeepSeekClient.aggregate(amount: amountData, cost: costData, now: now,
                                    timeZone: TimeZone(secondsFromGMT: 0)!)
}

func runModelSupportTests() {
    print("▶ 官方模型 ID 与平台别名的离线聚合回归")
    do {
        // 每个明确 ID 都单独贡献数据，防止新 ID 漏算被其他模型的总量掩盖。
        let supported = [
            ("deepseek-flash", false),
            ("deepseek-v4-flash-vision-exp", false),
            ("deepseek-v4-flash", false),
            ("deepseek-chat", false),
            ("deepseek-reasoner", false),
            ("deepseek-v4-pro", true)
        ]
        for (model, isPro) in supported {
            for raw in [model, " \n\(model.uppercased())\t ", " \(model.uppercased())[1m] \n"] {
                let summary = try modelSupportSummary(today: [(raw, 120, 0.006)])
                let expected = isPro ? summary.todayProUsage : summary.todayFlashUsage
                let other = isPro ? summary.todayFlashUsage : summary.todayProUsage
                check(expected.tokens == 120 && approx(expected.cost, 0.006)
                      && other.tokens == 0 && approx(other.cost, 0),
                      "模型归属与消费：\(raw.debugDescription)")
                check(summary.todayTokens == 120 && summary.monthTokens == 120
                      && approx(summary.todayCost, 0.006) && approx(summary.monthCost, 0.006)
                      && summary.topModel == raw,
                      "总量与原始模型名：\(raw.debugDescription)")
            }
        }

        let unknown: [String?] = [
            "deepseek-flash-preview", "deepseek-v4-flash-vision-exp-next",
            "deepseek-v4-flash-next", "deepseek-v4-pro-next",
            "deepseek-v4-flash-next[1m]", "deepseek-v4-pro-next[1m]",
            "DeepSeek-V4.1-Flash", "", " \n\t ", nil
        ]
        for raw in unknown {
            let summary = try modelSupportSummary(today: [(raw, 17, 0.002)])
            check(summary.todayFlashUsage.tokens == 0 && approx(summary.todayFlashUsage.cost, 0)
                  && summary.todayProUsage.tokens == 0 && approx(summary.todayProUsage.cost, 0)
                  && summary.todayTokens == 17 && summary.monthTokens == 17
                  && approx(summary.todayCost, 0.002) && approx(summary.monthCost, 0.002),
                  "未知模型保留总量且不误归类：\(String(describing: raw))")
        }

        let topModel = " DeepSeek-V4-Flash-Vision-Exp[1m] "
        let mixed = try modelSupportSummary(today: [
            ("deepseek-flash", 10, 0.001), (topModel, 100, 0.01),
            ("deepseek-v4-flash", 20, 0.002), ("deepseek-chat", 30, 0.003),
            ("deepseek-reasoner", 40, 0.004), ("deepseek-v4-pro[1m]", 50, 0.005),
            ("future-model", 60, 0.006), (nil, 70, 0.007)
        ], earlier: [(topModel, 200, 0.02), ("deepseek-v4-pro", 80, 0.008)])
        check(mixed.todayFlashUsage.tokens == 200 && approx(mixed.todayFlashUsage.cost, 0.02)
              && mixed.todayProUsage.tokens == 50 && approx(mixed.todayProUsage.cost, 0.005),
              "混合模型按今日范围累计 Flash 与 Pro")
        check(mixed.todayTokens == 380 && approx(mixed.todayCost, 0.038)
              && mixed.monthTokens == 660 && approx(mixed.monthCost, 0.066)
              && mixed.monthRequests == 10 && mixed.topModel == topModel,
              "混合日月总量包含未知模型，主力模型保留平台原始名称")
        let days = Dictionary(uniqueKeysWithValues: mixed.daily.map { ($0.date, $0) })
        check(days["2026-09-22"]?.tokens == 280 && days["2026-09-22"]?.requests == 2
              && approx(days["2026-09-22"]?.cost ?? -1, 0.028)
              && days["2026-09-23"]?.tokens == 380 && days["2026-09-23"]?.requests == 8
              && approx(days["2026-09-23"]?.cost ?? -1, 0.038),
              "逐日图表保留新旧模型、未知模型的 tokens、请求和消费")
    } catch {
        check(false, "模型支持信封解码与聚合", error.localizedDescription)
    }
}
