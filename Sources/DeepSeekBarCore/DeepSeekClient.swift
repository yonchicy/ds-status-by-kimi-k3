import Foundation

/// DeepSeek API 客户端。
/// - 余额：官方公开接口，用 API Key 鉴权
/// - 用量/消费：平台网页端内部接口，用平台登录 Token 鉴权（HTTP 恒 200，成败看 body 里的 code/biz_code）
public struct DeepSeekClient: Sendable {
    public static let shared = DeepSeekClient()

    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private let modelsURL = URL(string: "https://api.deepseek.com/models")!
    private let amountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private let costURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private let statusPageURL = URL(string: "https://status.deepseek.com/")!

    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private let loadData: DataLoader

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        loadData = { request in try await session.data(for: request) }
    }

    /// 注入网络加载器，用于离线验证完整的请求与聚合链路。
    public init(dataLoader: @escaping DataLoader) {
        loadData = dataLoader
    }

    // MARK: - 余额（官方接口，API Key）

    public func fetchBalance(apiKey: String) async throws -> BalanceSnapshot {
        var req = URLRequest(url: balanceURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await loadData(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            if code == 401 { throw DeepSeekError.apiError("API Key 无效或已过期") }
            if code == 429 { throw DeepSeekError.apiError("请求过于频繁，稍后再试") }
            throw DeepSeekError.httpError(code)
        }

        let decoded: BalanceResponse
        do {
            decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw DeepSeekError.parseFailed("balance: \(error.localizedDescription)")
        }

        // 多币种时优先选有余额的
        let infos = decoded.balanceInfos
        let picked = infos.first { $0.currency == "USD" && (Double($0.totalBalance) ?? 0) > 0 }
            ?? infos.first { (Double($0.totalBalance) ?? 0) > 0 }
            ?? infos.first { $0.currency == "CNY" }
            ?? infos.first

        guard let info = picked else {
            return BalanceSnapshot(currency: "CNY", total: 0, granted: 0, toppedUp: 0,
                                   isAvailable: decoded.isAvailable, updatedAt: Date())
        }
        return BalanceSnapshot(
            currency: info.currency,
            total: Double(info.totalBalance) ?? 0,
            granted: Double(info.grantedBalance) ?? 0,
            toppedUp: Double(info.toppedUpBalance) ?? 0,
            isAvailable: decoded.isAvailable,
            updatedAt: Date())
    }

    // MARK: - 用量/消费（平台内部接口，平台 Token）

    /// 校验平台 Token 是否有效（成功返回 true；40002/40003 返回 false）
    public func validatePlatformToken(_ token: String) async throws -> Bool {
        let (month, year) = Self.currentMonthYear()
        do {
            _ = try await fetchAmount(token: token, month: month, year: year)
            return true
        } catch DeepSeekError.invalidPlatformToken {
            return false
        }
    }

    /// 拉取本月用量 + 消费并聚合；月初额外拉取上月，以覆盖完整的近 7 个自然日。
    public func fetchUsageSummary(platformToken token: String,
                                  now: Date = Date(),
                                  timeZone: TimeZone = .current) async throws -> UsageSummary {
        let current = Self.currentMonthYear(now, timeZone: timeZone)
        async let amountReq = fetchAmount(token: token, month: current.month, year: current.year)
        async let costReq = fetchCost(token: token, month: current.month, year: current.year)

        let periods = Self.usageMonthsCoveringLast7Days(endingOn: now, timeZone: timeZone)
        guard let history = periods.first(where: {
            $0.month != current.month || $0.year != current.year
        }) else {
            let (amount, cost) = try await (amountReq, costReq)
            return Self.aggregate(amount: amount, cost: cost, now: now, timeZone: timeZone)
        }

        async let historyAmountReq = fetchAmount(token: token, month: history.month, year: history.year)
        let (amount, cost) = try await (amountReq, costReq)
        do {
            let historyAmount = try await historyAmountReq
            return Self.aggregate(
                amount: amount,
                cost: cost,
                historicalAmounts: [historyAmount],
                now: now,
                timeZone: timeZone)
        } catch DeepSeekError.invalidPlatformToken {
            throw DeepSeekError.invalidPlatformToken
        } catch {
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
            // 历史月份失败时仍保留当月摘要，图表中缺失日期会按既有逻辑补零。
            return Self.aggregate(amount: amount, cost: cost, now: now, timeZone: timeZone)
        }
    }

    public static func currentMonthYear(_ now: Date = Date(),
                                        timeZone: TimeZone = .current) -> (month: Int, year: Int) {
        let calendar = UsageDate.calendar(timeZone: timeZone)
        let c = calendar.dateComponents([.month, .year], from: now)
        return (c.month ?? 1, c.year ?? 1970)
    }

    /// 查询近 7 个自然日所跨越的月份，按时间从早到晚排列。
    /// 7 日窗口最多跨两个月；显式按 Gregorian 计算，避免用户日历设置改变 API 参数。
    public static func usageMonthsCoveringLast7Days(
        endingOn now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [(month: Int, year: Int)] {
        let calendar = UsageDate.calendar(timeZone: timeZone)
        var seen = Set<Int>()
        var result: [(month: Int, year: Int)] = []

        for daysBack in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let c = calendar.dateComponents([.month, .year], from: date)
            guard let month = c.month, let year = c.year else { continue }
            let key = year * 100 + month
            if seen.insert(key).inserted {
                result.append((month: month, year: year))
            }
        }
        return result
    }

    private func platformRequest(url: URL, token: String, month: Int, year: Int) -> URLRequest {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "month", value: String(month)),
                            URLQueryItem(name: "year", value: String(year))]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        return req
    }

    private func checkEnvelope(code: Int?, bizCode: Int?, bizMsg: String?, api: String) throws {
        if let code = code, code != 0 {
            if DeepSeekError.isAuthCode(code) { throw DeepSeekError.invalidPlatformToken }
            throw DeepSeekError.apiError("\(api) code \(code)")
        }
        if let bizCode = bizCode, bizCode != 0 {
            if DeepSeekError.isAuthCode(bizCode) { throw DeepSeekError.invalidPlatformToken }
            throw DeepSeekError.apiError(bizMsg ?? "\(api) biz_code \(bizCode)")
        }
    }

    private func fetchAmount(token: String, month: Int, year: Int) async throws -> AmountEnvelope.Inner.BizData {
        let req = platformRequest(url: amountURL, token: token, month: month, year: year)
        let (data, resp) = try await loadData(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            if status == 401 || status == 403 { throw DeepSeekError.invalidPlatformToken }
            throw DeepSeekError.httpError(status)
        }
        let env: AmountEnvelope
        do { env = try JSONDecoder().decode(AmountEnvelope.self, from: data) }
        catch { throw DeepSeekError.parseFailed("amount: \(error.localizedDescription)") }
        try checkEnvelope(code: env.code, bizCode: env.data?.biz_code, bizMsg: env.data?.biz_msg, api: "amount")
        guard let biz = env.data?.biz_data else { throw DeepSeekError.parseFailed("amount: 缺少 biz_data") }
        return biz
    }

    private func fetchCost(token: String, month: Int, year: Int) async throws -> CostEnvelope.Inner.BizDataItem {
        let req = platformRequest(url: costURL, token: token, month: month, year: year)
        let (data, resp) = try await loadData(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            if status == 401 || status == 403 { throw DeepSeekError.invalidPlatformToken }
            throw DeepSeekError.httpError(status)
        }
        let env: CostEnvelope
        do { env = try JSONDecoder().decode(CostEnvelope.self, from: data) }
        catch { throw DeepSeekError.parseFailed("cost: \(error.localizedDescription)") }
        try checkEnvelope(code: env.code, bizCode: env.data?.biz_code, bizMsg: env.data?.biz_msg, api: "cost")
        guard let item = env.data?.biz_data?.first else {
            throw DeepSeekError.parseFailed("cost: 缺少 biz_data")
        }
        return item
    }

    // MARK: - 聚合

    /// token 类指标计入 tokens；REQUEST 计入请求次数；其余未知类型忽略，避免重复计数
    private static func isTokenType(_ type: String?) -> Bool {
        switch type?.uppercased() ?? "" {
        case "PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN":
            return true
        default:
            return false
        }
    }

    private static func isRequestType(_ type: String?) -> Bool {
        type?.uppercased() == "REQUEST"
    }

    private enum UsageModelFamily {
        case flash
        case pro
        case other
    }

    /// 平台用量接口没有公开模型字段契约，因此仅识别官方模型 ID 及明确的兼容别名。
    /// 未知值仍计入总量，但不会被误归到 Flash 或 Pro。
    private static func usageModelFamily(_ rawModel: String?) -> UsageModelFamily {
        guard let model = rawModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !model.isEmpty else {
            return .other
        }

        if model == "deepseek-v4-pro" || model.hasPrefix("deepseek-v4-pro[") {
            return .pro
        }
        if model == "deepseek-v4-flash"
            || model.hasPrefix("deepseek-v4-flash[")
            || model == "deepseek-chat"
            || model == "deepseek-reasoner" {
            return .flash
        }
        return .other
    }

    public static func aggregate(amount: AmountEnvelope.Inner.BizData,
                                 cost: CostEnvelope.Inner.BizDataItem,
                                 historicalAmounts: [AmountEnvelope.Inner.BizData] = [],
                                 now: Date,
                                 timeZone: TimeZone = .current) -> UsageSummary {
        let currency = cost.currency ?? "CNY"
        let todayString = UsageDate.key(for: now, timeZone: timeZone)

        // 今日
        var todayTokens = 0, todayRequests = 0, todayCost = 0.0
        var todayFlashUsage = TodayModelUsage()
        var todayProUsage = TodayModelUsage()
        for day in amount.days ?? [] where day.date == todayString {
            for m in day.data ?? [] {
                var modelTokens = 0
                for u in m.usage ?? [] {
                    if Self.isTokenType(u.type) {
                        let tokens = Int(u.amount ?? "") ?? 0
                        todayTokens += tokens
                        modelTokens += tokens
                    }
                    if Self.isRequestType(u.type) { todayRequests += Int(u.amount ?? "") ?? 0 }
                }
                switch Self.usageModelFamily(m.model) {
                case .flash: todayFlashUsage.tokens += modelTokens
                case .pro: todayProUsage.tokens += modelTokens
                case .other: break
                }
            }
        }
        for day in cost.days ?? [] where day.date == todayString {
            for m in day.data ?? [] {
                var modelCost = 0.0
                for u in m.usage ?? [] where Self.isTokenType(u.type) {
                    let itemCost = Double(u.amount ?? "") ?? 0
                    todayCost += itemCost
                    modelCost += itemCost
                }
                switch Self.usageModelFamily(m.model) {
                case .flash: todayFlashUsage.cost += modelCost
                case .pro: todayProUsage.cost += modelCost
                case .other: break
                }
            }
        }

        // 本月（total 汇总 + 逐日明细画图）
        var monthTokens = 0, monthRequests = 0, monthCost = 0.0
        var hit = 0, miss = 0
        var modelTokens: [String: Int] = [:]
        for m in amount.total ?? [] {
            var sum = 0
            for u in m.usage ?? [] {
                let v = Int(u.amount ?? "") ?? 0
                if Self.isTokenType(u.type) {
                    sum += v
                    switch u.type?.uppercased() {
                    case "PROMPT_CACHE_HIT_TOKEN": hit += v
                    case "PROMPT_CACHE_MISS_TOKEN": miss += v
                    default: break
                    }
                }
                if Self.isRequestType(u.type) { monthRequests += v }
            }
            if let model = m.model { modelTokens[model, default: 0] += sum }
            monthTokens += sum
        }
        for m in cost.total ?? [] {
            for u in m.usage ?? [] where Self.isTokenType(u.type) {
                monthCost += Double(u.amount ?? "") ?? 0
            }
        }
        let topModel = modelTokens.max { $0.value < $1.value }?.key
        let cacheHitRate: Double? = (hit + miss) > 0 ? Double(hit) / Double(hit + miss) : nil

        // 逐日（amount 与 cost 按日期合并）
        var daily: [String: DailyUsage] = [:]
        for source in historicalAmounts + [amount] {
            for d in source.days ?? [] {
                guard let date = d.date else { continue }
                var tokens = 0, requests = 0
                for m in d.data ?? [] {
                    for u in m.usage ?? [] {
                        if Self.isTokenType(u.type) { tokens += Int(u.amount ?? "") ?? 0 }
                        if Self.isRequestType(u.type) { requests += Int(u.amount ?? "") ?? 0 }
                    }
                }
                daily[date] = DailyUsage(date: date, tokens: tokens, cost: 0, requests: requests)
            }
        }
        for d in cost.days ?? [] {
            guard let date = d.date else { continue }
            var c = 0.0
            for m in d.data ?? [] {
                for u in m.usage ?? [] where Self.isTokenType(u.type) {
                    c += Double(u.amount ?? "") ?? 0
                }
            }
            if var existing = daily[date] {
                existing.cost = c
                daily[date] = existing
            } else {
                daily[date] = DailyUsage(date: date, tokens: 0, cost: c, requests: 0)
            }
        }
        let dailySorted = daily.values.sorted { $0.date < $1.date }

        return UsageSummary(
            currency: currency,
            todayTokens: todayTokens,
            todayCost: todayCost,
            todayFlashUsage: todayFlashUsage,
            todayProUsage: todayProUsage,
            monthTokens: monthTokens,
            monthCost: monthCost,
            monthRequests: monthRequests,
            topModel: topModel,
            cacheHitRate: cacheHitRate,
            daily: dailySorted)
    }

    // MARK: - 服务状态探测

    /// 探测 api.deepseek.com：有 API Key 时做认证探测，否则做匿名探测（401 也算服务可达）
    public func probeService(apiKey: String?) async -> ProbeStatus {
        var req = URLRequest(url: modelsURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        do {
            let (_, resp) = try await loadData(req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200:
                return ms < 2000 ? .ok(latencyMs: ms) : .slow(latencyMs: ms)
            case 401, 403:
                // 服务可达，只是未认证/Key 无效
                return apiKey == nil ? .ok(latencyMs: ms) : .down("认证失败(\(status))")
            case 429:
                return .slow(latencyMs: ms)
            default:
                return .down("HTTP \(status)")
            }
        } catch {
            return .down("网络不可达")
        }
    }

    // MARK: - 官方状态页

    /// 抓 status.deepseek.com（FlashCat 托管的 Next.js 页面）。
    /// 判定依据：服务端渲染的总体状态徽章 <h2> 的颜色与文字（绿色对勾=一切正常）。
    /// 注意不能用全页关键词匹配——页面内嵌的 i18n 字典和历史事件包含"故障"等字样，会误报。
    public func fetchStatusPage() async -> StatusPageResult {
        var req = URLRequest(url: statusPageURL)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await loadData(req)
            guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? -1) else {
                return .unreachable
            }
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                return .undetermined
            }
            return Self.parseStatusPage(html: html)
        } catch {
            return .unreachable
        }
    }

    /// 从 HTML 中提取带状态徽章的 <h2> 并分类（独立出来便于测试）
    public static func parseStatusPage(html: String) -> StatusPageResult {
        // 枚举所有 <h2>...</h2> 块
        guard let h2Regex = try? NSRegularExpression(pattern: #"<h2[^>]*>.*?</h2>"#, options: [.dotMatchesLineSeparators]),
              let colorRegex = try? NSRegularExpression(pattern: #"bg-(green|red|orange|yellow)-\d+"#)
        else { return .undetermined }

        let ns = html as NSString
        let h2Matches = h2Regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        // 总体状态块是第一个内含 bg-* 徽章的 h2
        for m in h2Matches {
            let block = ns.substring(with: m.range)
            guard let colorMatch = colorRegex.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
                  let color = (block as NSString).substring(with: colorMatch.range(at: 1)) as String?
            else { continue }

            let text = block.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch color {
            case "green":
                return .noIncident
            case "red", "orange", "yellow":
                return .incident(text)
            default:
                return .undetermined
            }
        }
        return .undetermined
    }
}
