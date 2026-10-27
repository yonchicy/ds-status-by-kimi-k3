import DeepSeekBarCore
import Foundation

// Fixtures follow the public platform frontend's by_api_key series contract.
// No live credentials or paid Search/Fetch requests are used by these tests.
private func billingEnvelope(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "code": 0, "data": ["biz_code": 0, "biz_data": value]
    ])
}

private func billingTime(_ iso: String) -> Int {
    Int(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970)
}

private func billingAmountSeries(_ name: String, _ time: Int,
                                 _ usage: [String: Any], key: String = "test-key") -> [String: Any] {
    ["model": name, "api_key": ["tracking_id": key],
     "buckets": [["time": time, "usage": usage]]]
}

private func billingCostSeries(_ name: String, _ time: Int,
                               _ cost: Any, key: String = "test-key") -> [String: Any] {
    ["model": name, "api_key": ["tracking_id": key],
     "buckets": [["time": time, "cost": cost]]]
}

private func billingClient(amount: Data, cost: Data,
                           recorder: RequestRecorder? = nil) -> DeepSeekClient {
    DeepSeekClient { request in
        guard let url = request.url,
              url.host == "platform.deepseek.com",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer billing-fixture-token" else {
            throw DeepSeekError.apiError("unexpected billing request or authentication")
        }
        await recorder?.append(url.absoluteString)
        let data: Data
        switch url.path {
        case "/api/v0/usage/by_api_key/amount": data = amount
        case "/api/v0/usage/by_api_key/cost": data = cost
        default: throw DeepSeekError.apiError("unexpected legacy billing endpoint")
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func billingSummary(amountSeries: [[String: Any]] = [],
                            amountFunctions: [[String: Any]] = [],
                            costSeries: [[String: Any]] = [],
                            costFunctions: [[String: Any]] = [],
                            currency: String = "CNY",
                            now: Date, zone: TimeZone) async throws -> UsageSummary {
    let amount = try billingEnvelope(["series": amountSeries, "function_series": amountFunctions])
    let cost = try billingEnvelope(["data": [[
        "currency": currency, "series": costSeries, "function_series": costFunctions
    ]]])
    return try await billingClient(amount: amount, cost: cost).fetchUsageSummary(
        platformToken: "billing-fixture-token", now: now, timeZone: zone)
}

func runSearchBillingTests() {
    print("▶ Search / Fetch 新版账单请求、解码与聚合回归")
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T04:00:00Z")!
        let today = billingTime("2026-10-31T16:00:00Z")
        let previous = billingTime("2026-10-30T16:00:00Z")
        do {
            let recorder = RequestRecorder()
            let amount = try billingEnvelope([
                "series": [
                    billingAmountSeries("deepseek-flash", today, [
                        "PROMPT_CACHE_HIT_TOKEN": 100, "PROMPT_CACHE_MISS_TOKEN": 50,
                        "RESPONSE_TOKEN": 25, "REQUEST": 2], key: "first"),
                    billingAmountSeries("deepseek-flash", today, [
                        "PROMPT_CACHE_HIT_TOKEN": 40, "PROMPT_CACHE_MISS_TOKEN": 10,
                        "RESPONSE_TOKEN": 30, "REQUEST": 1], key: "second"),
                    billingAmountSeries("deepseek-v4-pro", today, [
                        "PROMPT_CACHE_MISS_TOKEN": 60, "RESPONSE_TOKEN": 20, "REQUEST": 1]),
                    billingAmountSeries("deepseek-flash", previous, [
                        "PROMPT_CACHE_HIT_TOKEN": 900, "RESPONSE_TOKEN": 200, "REQUEST": 9])
                ],
                "function_series": [
                    billingAmountSeries("Search", today, ["FUNCTION_CALL": 5], key: "first"),
                    billingAmountSeries("Search", today, ["FUNCTION_CALL": 2], key: "second"),
                    billingAmountSeries("Fetch", today, ["FUNCTION_CALL": 3]),
                    billingAmountSeries("Search", previous, ["FUNCTION_CALL": 30])
                ]
            ])
            let cost = try billingEnvelope(["data": [
                ["currency": "CNY", "series": [
                    billingCostSeries("deepseek-flash", today, "0.12", key: "first"),
                    billingCostSeries("deepseek-flash", today, 0.03, key: "second"),
                    billingCostSeries("deepseek-v4-pro", today, "0.20"),
                    billingCostSeries("deepseek-flash", previous, "10.00")
                ], "function_series": [
                    billingCostSeries("Search", today, "0.025", key: "first"),
                    billingCostSeries("Search", today, "0.010", key: "second"),
                    billingCostSeries("Fetch", today, 0.015),
                    billingCostSeries("Search", previous, "0.15")
                ]],
                ["currency": "USD", "series": [], "function_series": [
                    billingCostSeries("Search", today, "999.00")
                ]]
            ]])
            let summary = try await billingClient(amount: amount, cost: cost, recorder: recorder)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: now, timeZone: zone)
            let requests = await recorder.snapshot()
            let components = requests.compactMap { URLComponents(string: $0) }
            let parameters = components.map { Dictionary(uniqueKeysWithValues:
                ($0.queryItems ?? []).map { ($0.name, $0.value ?? "") }) }
            check(components.count == 2 && Set(components.map(\.path)) == [
                "/api/v0/usage/by_api_key/amount", "/api/v0/usage/by_api_key/cost"
            ], "新版账单只请求两次，全账户模型与工具一起读取")
            check(parameters.allSatisfy {
                $0["start"] == String(billingTime("2026-10-25T16:00:00Z"))
                    && $0["end"] == String(billingTime("2026-11-01T16:00:00Z"))
                    && $0["tz"] == "28800" && $0["api_key_tracking_id"] == nil
            }, "月初范围覆盖近七日，使用北京时间且结束时间排他")
            check(summary.currency == "CNY" && approx(summary.todayCost, 0.40)
                  && approx(summary.monthCost, 0.40), "模型与工具费用合计，不混加其他币种和上月账单")
            check(summary.todayTokens == 335 && summary.monthTokens == 335
                  && summary.monthRequests == 4, "工具调用次数不污染模型 tokens 或模型请求数")
            check(summary.todayFlashUsage.tokens == 255 && approx(summary.todayFlashUsage.cost, 0.15)
                  && summary.todayProUsage.tokens == 80 && approx(summary.todayProUsage.cost, 0.20),
                  "不同 API Key 的 Flash / Pro 数据正确合并")
            check(summary.topModel == "deepseek-flash" && approx(summary.cacheHitRate ?? -1, 140.0 / 260.0),
                  "主力模型与缓存命中率仅使用当月模型数据")
            let search = summary.toolUsage.first { $0.name == "Search" }
            let fetch = summary.toolUsage.first { $0.name == "Fetch" }
            check(search?.today.requests == 7 && search?.month.requests == 7
                  && approx(search?.today.cost ?? -1, 0.035)
                  && approx(search?.month.cost ?? -1, 0.035)
                  && fetch?.today.requests == 3 && approx(fetch?.today.cost ?? -1, 0.015),
                  "Search / Fetch 分项按平台名称和实际账单金额累计")
            let days = Dictionary(uniqueKeysWithValues: summary.daily.map { ($0.date, $0) })
            check(days["2026-11-01"]?.requests == 14 && approx(days["2026-11-01"]?.cost ?? -1, 0.40)
                  && days["2026-10-31"]?.tokens == 1100 && days["2026-10-31"]?.requests == 39
                  && approx(days["2026-10-31"]?.cost ?? -1, 10.15),
                  "逐日记录保留跨月工具消费与次数，月份汇总互不混入")

            let usdPreferred = try await billingClient(amount: amount, cost: cost)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: now,
                                   timeZone: zone, preferredCurrency: "USD")
            check(usdPreferred.currency == "USD" && approx(usdPreferred.todayCost, 999)
                  && approx(usdPreferred.monthCost, 999)
                  && approx(usdPreferred.toolUsage.first { $0.name == "Search" }?.today.cost ?? -1, 999)
                  && approx(usdPreferred.todayFlashUsage.cost, 0),
                  "显式美元偏好选择 USD 账单，人民币分项不混入")

            let free = try await billingSummary(
                amountFunctions: [billingAmountSeries("Search", today, ["FUNCTION_CALL": 500])],
                costFunctions: [billingCostSeries("Search", today, "0")], now: now, zone: zone)
            check(free.toolUsage.first?.today.requests == 500 && approx(free.todayCost, 0)
                  && approx(free.toolUsage.first?.month.cost ?? -1, 0),
                  "免费或未扣费调用保留次数，不能按本地单价自动计费")
            check(free.topModel == nil && free.cacheHitRate == nil && free.monthTokens == 0
                  && free.monthRequests == 0, "纯工具账户不产生伪模型或 token 数据")

            let costOnly = try await billingSummary(
                costFunctions: [billingCostSeries("Future tool v2", today, "0.00075")],
                currency: "USD", now: now, zone: zone)
            check(costOnly.currency == "USD" && costOnly.symbol == "$"
                  && approx(costOnly.todayCost, 0.00075) && approx(costOnly.monthCost, 0.00075)
                  && costOnly.toolUsage.first?.name == "Future tool v2"
                  && costOnly.toolUsage.first?.today.requests == 0,
                  "只有扣费明细的新工具仍展示，保留美元小额精度")

            let amountOnly = try await billingSummary(
                amountFunctions: [billingAmountSeries("Fetch", today, ["FUNCTION_CALL": 8])],
                now: now, zone: zone)
            check(amountOnly.toolUsage.first?.today.requests == 8
                  && approx(amountOnly.toolUsage.first?.today.cost ?? -1, 0),
                  "工具用量先于费用到达时保留调用次数")

            let later = ISO8601DateFormatter().date(from: "2026-11-03T04:00:00Z")!
            let laterDay = billingTime("2026-11-02T16:00:00Z")
            let monthToDate = try await billingSummary(
                amountFunctions: [
                    billingAmountSeries("Search", today, ["FUNCTION_CALL": 4]),
                    billingAmountSeries("Search", laterDay, ["FUNCTION_CALL": 2])
                ], costFunctions: [
                    billingCostSeries("Search", today, "0.02"),
                    billingCostSeries("Search", laterDay, "0.01")
                ], now: later, zone: zone)
            check(monthToDate.toolUsage.first?.today.requests == 2
                  && monthToDate.toolUsage.first?.month.requests == 6
                  && approx(monthToDate.todayCost, 0.01) && approx(monthToDate.monthCost, 0.03),
                  "今日与本月工具分项独立累计，按本地日期拆分时间桶")

            let empty = try await billingSummary(now: now, zone: zone)
            check(empty.toolUsage.isEmpty && empty.daily.isEmpty && empty.topModel == nil
                  && empty.todayTokens == 0 && approx(empty.monthCost, 0), "空账单正确返回空状态")

            let emptyAmount = try billingEnvelope(["series": [], "function_series": []])
            let emptyCost = try billingEnvelope(["data": [[
                "currency": "CNY", "series": [], "function_series": []
            ]]])
            let noCurrencyCost = try billingEnvelope(["data": []])
            let toolAmount = try billingEnvelope([
                "series": [], "function_series": [
                    billingAmountSeries("Search", today, ["FUNCTION_CALL": 12])
                ]
            ])
            let noCharge = try await billingClient(amount: toolAmount, cost: noCurrencyCost)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: now, timeZone: zone)
            check(noCharge.currency == "CNY" && approx(noCharge.todayCost, 0)
                  && approx(noCharge.monthCost, 0) && noCharge.toolUsage.first?.today.requests == 12
                  && noCharge.toolUsage.first?.month.requests == 12,
                  "费用 data 空数组是有效零账单，工具调用次数仍保留")
            let noUSDCharge = try await billingClient(amount: toolAmount, cost: noCurrencyCost)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: now,
                                   timeZone: zone, preferredCurrency: "USD")
            check(noUSDCharge.currency == "USD" && noUSDCharge.symbol == "$"
                  && approx(noUSDCharge.monthCost, 0) && noUSDCharge.toolUsage.first?.today.requests == 12,
                  "费用币种数组为空时保留美元偏好及工具用量")

            let dstZone = TimeZone(identifier: "America/New_York")!
            let dstNow = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
            let fixedMonthStart = billingTime("2026-03-01T04:00:00Z")
            let dstRecorder = RequestRecorder()
            let dstAmount = try billingEnvelope([
                "series": [], "function_series": [
                    billingAmountSeries("Search", fixedMonthStart, ["FUNCTION_CALL": 2])
                ]
            ])
            let dstCost = try billingEnvelope(["data": [[
                "currency": "CNY", "series": [], "function_series": [
                    billingCostSeries("Search", fixedMonthStart, "0.01")
                ]
            ]]])
            let dstSummary = try await billingClient(amount: dstAmount, cost: dstCost, recorder: dstRecorder)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: dstNow, timeZone: dstZone)
            let dstRequests = await dstRecorder.snapshot()
            let dstParameters = dstRequests.compactMap { URLComponents(string: $0) }.map {
                Dictionary(uniqueKeysWithValues: ($0.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            }
            check(dstParameters.count == 2 && dstParameters.allSatisfy {
                $0["tz"] == "-14400" && $0["start"] == String(fixedMonthStart)
                    && $0["end"] == String(billingTime("2026-03-11T04:00:00Z"))
            }, "跨夏令时月份整段使用当前 UTC-4 偏移计算查询边界")
            check(dstSummary.daily.first?.date == "2026-03-01"
                  && dstSummary.daily.first?.requests == 2
                  && approx(dstSummary.daily.first?.cost ?? -1, 0.01)
                  && dstSummary.toolUsage.first?.month.requests == 2
                  && approx(dstSummary.monthCost, 0.01),
                  "夏令时月初时间桶按查询偏移保留为三月一日，不错分到上月")

            let nepalRecorder = RequestRecorder()
            _ = try await billingClient(amount: emptyAmount, cost: emptyCost, recorder: nepalRecorder)
                .fetchUsageSummary(platformToken: "billing-fixture-token", now: now,
                                   timeZone: TimeZone(identifier: "Asia/Kathmandu")!)
            let nepalRequests = await nepalRecorder.snapshot()
            let nepalParameters = nepalRequests.compactMap { URLComponents(string: $0) }.map {
                Dictionary(uniqueKeysWithValues: ($0.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            }
            check(nepalParameters.count == 2 && nepalParameters.allSatisfy {
                $0["tz"] == "18000"
                    && $0["start"] == String(billingTime("2026-10-25T18:15:00Z") + 2700)
                    && $0["end"] == String(billingTime("2026-11-01T18:15:00Z") + 2700)
            }, "加德满都按官方前端使用整小时 tz，起止边界补偿 2700 秒")

            for (label, brokenAmount, brokenCost) in [
                ("缺少模型序列", try billingEnvelope(["function_series": []]), emptyCost),
                ("缺少工具序列", try billingEnvelope(["series": []]), emptyCost),
                ("费用结构漂移", emptyAmount, try billingEnvelope(["currency": "CNY"])),
                ("非 JSON 响应", Data("upstream failure".utf8), emptyCost)
            ] {
                do {
                    _ = try await billingClient(amount: brokenAmount, cost: brokenCost)
                        .fetchUsageSummary(platformToken: "billing-fixture-token", now: now, timeZone: zone)
                    check(false, "\(label)应报错，不能伪装为零消费")
                } catch { check(true, "\(label)应报错，不能伪装为零消费") }
            }

            for code in [40002, 40003] {
                let expired = try JSONSerialization.data(withJSONObject: [
                    "code": 0, "data": ["biz_code": code, "biz_msg": "expired"]
                ])
                do {
                    _ = try await billingClient(amount: emptyAmount, cost: expired)
                        .fetchUsageSummary(platformToken: "billing-fixture-token", now: now, timeZone: zone)
                    check(false, "工具账单登录失效 \(code) 必须透传")
                } catch {
                    check((error as? DeepSeekError) == .invalidPlatformToken,
                          "工具账单登录失效 \(code) 必须透传")
                }
            }
            let malformedAuthBodies: [[String: Any]] = [
                ["code": 0, "data": ["biz_code": 40003, "biz_data": [String: Any]()]],
                ["code": 40003, "data": "not a success envelope"]
            ]
            for (index, body) in malformedAuthBodies.enumerated() {
                let expired = try JSONSerialization.data(withJSONObject: body)
                do {
                    _ = try await billingClient(amount: emptyAmount, cost: expired)
                        .fetchUsageSummary(platformToken: "billing-fixture-token", now: now, timeZone: zone)
                    check(false, "登录失效优先于成功数据解析（结构 \(index + 1)）")
                } catch {
                    check((error as? DeepSeekError) == .invalidPlatformToken,
                          "登录失效优先于成功数据解析（结构 \(index + 1)）")
                }
            }
            for status in [401, 500] {
                let client = DeepSeekClient { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
                }
                do {
                    _ = try await client.fetchUsageSummary(
                        platformToken: "billing-fixture-token", now: now, timeZone: zone)
                    check(false, "HTTP \(status) 不能回退成不含工具的消费摘要")
                } catch {
                    let expected: DeepSeekError = status == 401 ? .invalidPlatformToken : .httpError(status)
                    check((error as? DeepSeekError) == expected,
                          "HTTP \(status) 不能回退成不含工具的消费摘要")
                }
            }
        } catch {
            check(false, "Search / Fetch 请求与账单回归", error.localizedDescription)
        }
    }
    semaphore.wait()
}
