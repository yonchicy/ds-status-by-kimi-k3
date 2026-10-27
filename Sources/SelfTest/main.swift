import DeepSeekBarCore
import Foundation

// 极简断言测试器（CLT 环境无 XCTest，用退出码表示成败）
final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

let failures = FailureCounter()
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name) \(detail)")
        failures.increment()
    }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

actor RequestRecorder {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

print("▶ 余额响应解析")
let balanceJSON = """
{
  "is_available": true,
  "balance_infos": [
    {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"},
    {"currency": "USD", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
  ]
}
"""
do {
    let decoded = try JSONDecoder().decode(BalanceResponse.self, from: Data(balanceJSON.utf8))
    check(decoded.isAvailable, "is_available")
    check(decoded.balanceInfos.count == 2, "balance_infos 数量")
    check(decoded.balanceInfos[0].currency == "CNY", "币种")
    check(decoded.balanceInfos[0].totalBalance == "110.00", "总余额字符串")
} catch {
    check(false, "余额解码", error.localizedDescription)
}

print("▶ 用量/消费聚合")
let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"
let today = formatter.string(from: Date())

let amountJSON = """
{
  "code": 0, "msg": "ok",
  "data": {
    "biz_code": 0, "biz_msg": "",
    "biz_data": {
      "total": [
        {"model": "deepseek-chat", "usage": [
          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "800"},
          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "200"},
          {"type": "RESPONSE_TOKEN", "amount": "500"},
          {"type": "REQUEST", "amount": "7"}
        ]},
        {"model": "deepseek-reasoner", "usage": [
          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "100"},
          {"type": "RESPONSE_TOKEN", "amount": "300"},
          {"type": "REQUEST", "amount": "3"}
        ]}
      ],
      "days": [
        {"date": "\(today)", "data": [
          {"model": " DeepSeek-V4-Flash ", "usage": [
            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "50"},
            {"type": "RESPONSE_TOKEN", "amount": "30"},
            {"type": "REQUEST", "amount": "1"}
          ]},
          {"model": "deepseek-reasoner", "usage": [
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "20"}
          ]},
          {"model": "deepseek-v4-pro[1m]", "usage": [
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "15"},
            {"type": "RESPONSE_TOKEN", "amount": "25"},
            {"type": "REQUEST", "amount": "1"}
          ]},
          {"model": "future-model", "usage": [
            {"type": "RESPONSE_TOKEN", "amount": "10"}
          ]}
        ]}
      ]
    }
  }
}
"""

let costJSON = """
{
  "code": 0, "msg": "ok",
  "data": {
    "biz_code": 0, "biz_msg": "",
    "biz_data": [
      {
        "currency": "CNY",
        "total": [
          {"model": "deepseek-chat", "usage": [
            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.0100"},
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.0040"},
            {"type": "RESPONSE_TOKEN", "amount": "0.0200"}
          ]}
        ],
        "days": [
          {"date": "\(today)", "data": [
            {"model": "deepseek-v4-pro[1m]", "usage": [
              {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.0003"},
              {"type": "RESPONSE_TOKEN", "amount": "0.0005"}
            ]},
            {"model": "DEEPSEEK-V4-FLASH", "usage": [
              {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.0010"},
              {"type": "RESPONSE_TOKEN", "amount": "0.0005"}
            ]},
            {"model": "deepseek-chat", "usage": [
              {"type": "RESPONSE_TOKEN", "amount": "0.0005"}
            ]},
            {"model": "future-model", "usage": [
              {"type": "RESPONSE_TOKEN", "amount": "0.0002"}
            ]}
          ]}
        ]
      }
    ]
  }
}
"""

do {
    let amountEnv = try JSONDecoder().decode(AmountEnvelope.self, from: Data(amountJSON.utf8))
    let costEnv = try JSONDecoder().decode(CostEnvelope.self, from: Data(costJSON.utf8))
    guard let amountBiz = amountEnv.data?.biz_data, let costBiz = costEnv.data?.biz_data?.first else {
        check(false, "信封解包"); throw DeepSeekError.parseFailed("selftest")
    }
    let s = DeepSeekClient.aggregate(amount: amountBiz, cost: costBiz, now: Date())
    check(s.currency == "CNY", "币种")
    check(s.todayTokens == 150, "今日 tokens", "实际 \(s.todayTokens)")
    check(approx(s.todayCost, 0.003), "今日消费", "实际 \(s.todayCost)")
    check(s.todayFlashUsage.tokens == 100, "今日 Flash tokens", "实际 \(s.todayFlashUsage.tokens)")
    check(approx(s.todayFlashUsage.cost, 0.002), "今日 Flash 消费", "实际 \(s.todayFlashUsage.cost)")
    check(s.todayProUsage.tokens == 40, "今日 Pro tokens", "实际 \(s.todayProUsage.tokens)")
    check(approx(s.todayProUsage.cost, 0.0008), "今日 Pro 消费", "实际 \(s.todayProUsage.cost)")
    check(
        s.todayFlashUsage.tokens + s.todayProUsage.tokens < s.todayTokens,
        "未知模型只计入今日总量")
    check(
        s.todayFlashUsage.cost + s.todayProUsage.cost < s.todayCost,
        "未知模型消费只计入今日总额")
    check(s.monthTokens == 2000, "本月 tokens", "实际 \(s.monthTokens)")          // 800+200+500+100+100+300
    check(s.monthRequests == 10, "本月请求数", "实际 \(s.monthRequests)")         // 7+3
    check(approx(s.monthCost, 0.034), "本月消费", "实际 \(s.monthCost)")
    check(s.topModel == "deepseek-chat", "主力模型", "实际 \(s.topModel ?? "nil")")
    check(approx(s.cacheHitRate ?? 0, 900.0 / 1200.0), "缓存命中率")
    check(s.daily.count == 1, "逐日明细天数", "实际 \(s.daily.count)")
    check(s.daily.first?.requests == 2, "当日请求数")
} catch {
    check(false, "聚合测试异常", error.localizedDescription)
}

print("▶ 近 7 日跨月数据范围")
var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
let monthBoundaryNow = gregorian.date(from: DateComponents(
    timeZone: gregorian.timeZone,
    year: 2026,
    month: 8,
    day: 3,
    hour: 12))!
let requestedMonths = DeepSeekClient.usageMonthsCoveringLast7Days(
    endingOn: monthBoundaryNow,
    timeZone: gregorian.timeZone)
let requestedMonthKeys = Set(requestedMonths.map { "\($0.year)-\($0.month)" })
let last7MonthKeys = Set((0...6).compactMap { daysBack -> String? in
    guard let date = gregorian.date(byAdding: .day, value: -daysBack, to: monthBoundaryNow) else {
        return nil
    }
    let parts = gregorian.dateComponents([.year, .month], from: date)
    guard let year = parts.year, let month = parts.month else { return nil }
    return "\(year)-\(month)"
})
check(
    requestedMonthKeys.isSuperset(of: last7MonthKeys),
    "月初也会请求覆盖近 7 日的所有月份",
    "请求 \(requestedMonthKeys.sorted())，需要 \(last7MonthKeys.sorted())")
check(
    requestedMonths.map { "\($0.year)-\($0.month)" } == ["2026-7", "2026-8"],
    "跨月请求顺序",
    "实际 \(requestedMonths)")

let julyAmountJSON = """
{
  "code": 0, "data": {"biz_code": 0, "biz_data": {
    "total": [{"model": "old-month-model", "usage": [
      {"type": "RESPONSE_TOKEN", "amount": "999999"}
    ]}],
    "days": [
      {"date": "2026-07-28", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "28"}
      ]}]},
      {"date": "2026-07-29", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "29"}
      ]}]},
      {"date": "2026-07-30", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "30"}
      ]}]},
      {"date": "2026-07-31", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "31"}
      ]}]}
    ]
  }}
}
"""
let augustAmountJSON = """
{
  "code": 0, "data": {"biz_code": 0, "biz_data": {
    "total": [{"model": "current-month-model", "usage": [
      {"type": "RESPONSE_TOKEN", "amount": "600"}
    ]}],
    "days": [
      {"date": "2026-08-01", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "101"}
      ]}]},
      {"date": "2026-08-03", "data": [{"model": "deepseek-chat", "usage": [
        {"type": "RESPONSE_TOKEN", "amount": "103"}
      ]}]}
    ]
  }}
}
"""
let augustCostJSON = """
{
  "code": 0, "data": {"biz_code": 0, "biz_data": [{
    "currency": "CNY",
    "total": [{"model": "current-month-model", "usage": [
      {"type": "RESPONSE_TOKEN", "amount": "0.06"}
    ]}],
    "days": []
  }]}
}
"""
do {
    let july = try JSONDecoder().decode(AmountEnvelope.self, from: Data(julyAmountJSON.utf8))
    let august = try JSONDecoder().decode(AmountEnvelope.self, from: Data(augustAmountJSON.utf8))
    let cost = try JSONDecoder().decode(CostEnvelope.self, from: Data(augustCostJSON.utf8))
    guard let julyBiz = july.data?.biz_data,
          let augustBiz = august.data?.biz_data,
          let costBiz = cost.data?.biz_data?.first else {
        check(false, "跨月 fixture 解包")
        throw DeepSeekError.parseFailed("cross-month selftest")
    }

    let summary = DeepSeekClient.aggregate(
        amount: augustBiz,
        cost: costBiz,
        historicalAmounts: [julyBiz],
        now: monthBoundaryNow)
    let chartDays = summary.last7CalendarDays(
        endingOn: monthBoundaryNow,
        timeZone: gregorian.timeZone)
    check(
        chartDays.map(\.date) == [
            "2026-07-28", "2026-07-29", "2026-07-30", "2026-07-31",
            "2026-08-01", "2026-08-02", "2026-08-03",
        ],
        "跨月图表日期完整且有序",
        "实际 \(chartDays.map(\.date))")
    check(
        chartDays.map(\.tokens) == [28, 29, 30, 31, 101, 0, 103],
        "跨月图表 token 正确，缺失日补零",
        "实际 \(chartDays.map(\.tokens))")
    check(summary.monthTokens == 600, "上月 total 不计入本月 tokens", "实际 \(summary.monthTokens)")
    check(summary.topModel == "current-month-model", "上月模型不影响本月主力模型")
} catch {
    check(false, "跨月图表测试异常", error.localizedDescription)
}

print("▶ 今日累计 token 采样")
let samplingStart = gregorian.date(from: DateComponents(
    timeZone: gregorian.timeZone,
    year: 2026,
    month: 8,
    day: 13,
    hour: 9,
    minute: 30))!
var todaySeries = TodayUsageSeries()
todaySeries.record(tokens: 100, at: samplingStart, timeZone: gregorian.timeZone)
todaySeries.record(
    tokens: 120,
    at: samplingStart.addingTimeInterval(30),
    timeZone: gregorian.timeZone)
check(
    todaySeries.samples.map(\.tokens) == [120],
    "同一分钟刷新覆盖末点",
    "实际 \(todaySeries.samples.map(\.tokens))")

todaySeries.record(
    tokens: 120,
    at: samplingStart.addingTimeInterval(120),
    timeZone: gregorian.timeZone)
todaySeries.record(
    tokens: 110,
    at: samplingStart.addingTimeInterval(240),
    timeZone: gregorian.timeZone)
check(
    todaySeries.samples.map(\.tokens) == [120, 120, 110],
    "跨分钟保留平段与服务端修正值",
    "实际 \(todaySeries.samples.map(\.tokens))")

do {
    let encoded = try JSONEncoder().encode(todaySeries)
    let decoded = try JSONDecoder().decode(TodayUsageSeries.self, from: encoded)
    check(decoded == todaySeries, "采样序列持久化往返")
} catch {
    check(false, "采样序列编解码", error.localizedDescription)
}

todaySeries.record(
    tokens: 130,
    at: samplingStart.addingTimeInterval(360),
    timeZone: gregorian.timeZone,
    maxSamples: 3)
check(todaySeries.samples.count == 3, "采样数量上限", "实际 \(todaySeries.samples.count)")

let nextDay = gregorian.date(byAdding: .day, value: 1, to: samplingStart)!
check(todaySeries.retainDay(containing: nextDay, timeZone: gregorian.timeZone), "跨日检测到变化")
check(todaySeries.samples.isEmpty, "跨日清空旧采样")

let shanghai = TimeZone(identifier: "Asia/Shanghai")!
let utcLateAfternoon = gregorian.date(from: DateComponents(
    timeZone: gregorian.timeZone,
    year: 2026,
    month: 8,
    day: 13,
    hour: 16,
    minute: 30))!
todaySeries.record(tokens: 9, at: utcLateAfternoon, timeZone: shanghai)
check(todaySeries.dayKey == "2026-08-14", "采样日期遵循指定时区", "实际 \(todaySeries.dayKey ?? "nil")")

print("▶ 近 7 日新版请求编排")
let requestRecorder = RequestRecorder()
let orchestrationTimeZone = gregorian.timeZone
let orchestrationClient = DeepSeekClient { request in
    guard let url = request.url else { throw DeepSeekError.parseFailed("selftest request") }
    await requestRecorder.append(url.path)
    var buckets: [[String: Any]] = []
    for (date, count) in [("2026-07-28", 28), ("2026-07-29", 29), ("2026-07-30", 30),
                          ("2026-07-31", 31), ("2026-08-01", 101), ("2026-08-03", 103)] {
        let timestamp = ISO8601DateFormatter().date(from: date + "T00:00:00Z")!.timeIntervalSince1970
        buckets.append(["time": timestamp, "usage": ["RESPONSE_TOKEN": count]])
    }
    let payload: [String: Any]
    switch url.path {
    case "/api/v0/usage/by_api_key/amount":
        payload = ["series": [["model": "deepseek-flash", "buckets": buckets]], "function_series": []]
    case "/api/v0/usage/by_api_key/cost":
        payload = ["data": [["currency": "CNY", "series": [], "function_series": []]]]
    default:
        throw DeepSeekError.apiError("unexpected request path")
    }
    let body = try JSONSerialization.data(withJSONObject: [
        "code": 0, "data": ["biz_code": 0, "biz_data": payload]
    ])
    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
let orchestrationSemaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let summary = try await orchestrationClient.fetchUsageSummary(
            platformToken: "selftest-token", now: monthBoundaryNow, timeZone: orchestrationTimeZone)
        let chartDays = summary.last7CalendarDays(endingOn: monthBoundaryNow, timeZone: orchestrationTimeZone)
        let requests = await requestRecorder.snapshot()
        let expectedRequests: Set<String> = [
            "/api/v0/usage/by_api_key/amount", "/api/v0/usage/by_api_key/cost"
        ]
        check(requests.count == 2 && Set(requests) == expectedRequests,
              "跨月仍只请求一次用量和一次消费")
        check(chartDays.map(\.tokens) == [28, 29, 30, 31, 101, 0, 103],
              "新版响应覆盖完整近 7 日，缺失日期补零")
        check(summary.todayTokens == 103 && summary.monthTokens == 204,
              "上月图表数据不污染今日与本月摘要")
    } catch {
        check(false, "请求编排测试异常", error.localizedDescription)
    }
    orchestrationSemaphore.signal()
}
orchestrationSemaphore.wait()

let januaryBoundary = gregorian.date(from: DateComponents(
    timeZone: gregorian.timeZone,
    year: 2026,
    month: 1,
    day: 2,
    hour: 12))!
let yearBoundaryMonths = DeepSeekClient.usageMonthsCoveringLast7Days(
    endingOn: januaryBoundary,
    timeZone: gregorian.timeZone)
check(
    yearBoundaryMonths.map { "\($0.year)-\($0.month)" } == ["2025-12", "2026-1"],
    "跨年月份范围",
    "实际 \(yearBoundaryMonths)")

print("▶ 认证失败信封（40003）")
let authErrJSON = #"{"code": 40003, "msg": "Authorization Failed (invalid token)", "data": null}"#
do {
    let env = try JSONDecoder().decode(AmountEnvelope.self, from: Data(authErrJSON.utf8))
    check(env.code == 40003, "code 解析")
    check(DeepSeekError.isAuthCode(env.code ?? 0), "识别为 token 失效")
} catch {
    check(false, "错误信封解码", error.localizedDescription)
}

print("▶ 防御式解析（字段缺失不崩溃）")
let sparseJSON = #"{"code": 0, "data": {"biz_code": 0, "biz_data": {"total": null, "days": []}}}"#
do {
    let env = try JSONDecoder().decode(AmountEnvelope.self, from: Data(sparseJSON.utf8))
    check(env.code == 0, "code")
    check(env.data?.biz_data?.days?.count == 0, "空 days")
} catch {
    check(false, "稀疏字段解码", error.localizedDescription)
}

print("▶ 状态页 HTML 解析")
let greenHTML = #"""
<html><body>
<h2 class="font-medium flex items-center gap-2"><div class="flex items-center justify-center rounded-full shrink-0 bg-green-500 h-4 w-4 " aria-hidden="true"><svg><path d="M20 6 9 17l-5-5"></path></svg></div>一切运行正常</h2>
<h2 class="font-medium">系统状态</h2>
<script>"incidentCount":"{count} 个故障","maintenanceCount":"{count} 个维护"</script>
</body></html>
"""#
check(DeepSeekClient.parseStatusPage(html: greenHTML) == .noIncident, "绿色徽章 → 一切正常（i18n 字典不误报）")

let redHTML = #"""
<html><body>
<h2 class="font-medium flex items-center gap-2"><div class="flex items-center justify-center rounded-full shrink-0 bg-orange-500 h-4 w-4 "></div>我们目前遇到了一些问题</h2>
</body></html>
"""#
if case .incident(let text) = DeepSeekClient.parseStatusPage(html: redHTML) {
    check(text.contains("一些问题"), "橙色徽章 → 故障并带文字", text)
} else {
    check(false, "橙色徽章 → 应判定为故障")
}

let sparseHTML = "<html><body><h2 class=\"font-medium\">系统状态</h2></body></html>"
check(DeepSeekClient.parseStatusPage(html: sparseHTML) == .undetermined, "无徽章 → 未能判定")

if CommandLine.arguments.contains("--network") {
    print("▶ 网络端到端（真实请求）")
    let client = DeepSeekClient.shared
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        // 1. 匿名探测（无 key，401 也算服务可达）
        let probeAnon = await client.probeService(apiKey: nil)
        check(probeAnon.level == 1 || probeAnon.level == 2, "匿名探测服务可达", probeAnon.label)

        // 2. 假 key 探测（应为 down/认证失败）
        let probeBad = await client.probeService(apiKey: "sk-bogus")
        check(probeBad.level == 3, "假 Key 探测识别认证失败", probeBad.label)

        // 3. 假 key 查余额（应抛 401 友好错误）
        do {
            _ = try await client.fetchBalance(apiKey: "sk-bogus")
            check(false, "假 Key 余额应报错")
        } catch let e as DeepSeekError {
            check(e == .apiError("API Key 无效或已过期"), "余额 401 映射", e.localizedDescription)
        } catch {
            check(false, "余额错误类型", error.localizedDescription)
        }

        // 4. 假平台 token 校验（应返回 false 而不是崩溃）
        do {
            let ok = try await client.validatePlatformToken("bogus-token")
            check(!ok, "假平台 Token 校验为 false")
        } catch {
            check(false, "平台 Token 校验异常", error.localizedDescription)
        }

        // 5. 官方状态页（任何结果都允许，只要不崩溃；不可达时降级为 unreachable）
        let sp = await client.fetchStatusPage()
        print("  ℹ️ 状态页结果：\(sp.label)")

        semaphore.signal()
    }
    semaphore.wait()
}

runModelSupportTests()
runSearchBillingTests()
runWidgetTests()
if CommandLine.arguments.contains("--widget-bridge") { runWidgetBridgeTests() }

print(failures.value == 0 ? "\n全部通过 ✅" : "\n\(failures.value) 项失败 ❌")
exit(failures.value == 0 ? 0 : 1)
