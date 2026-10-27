import Foundation

enum UsageDate {
    static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func key(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar(timeZone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - 领域模型

/// 应用成功刷新时记录的“今日累计 token”快照。
public struct TodayUsageSample: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { timestamp }
    public var timestamp: Date
    public var tokens: Int

    public init(timestamp: Date, tokens: Int) {
        self.timestamp = timestamp
        self.tokens = tokens
    }
}

/// 仅保留当前自然日的累计 token 刷新采样，可直接序列化到 UserDefaults。
public struct TodayUsageSeries: Codable, Equatable, Sendable {
    public private(set) var dayKey: String?
    public private(set) var samples: [TodayUsageSample]

    public init(dayKey: String? = nil, samples: [TodayUsageSample] = []) {
        self.dayKey = dayKey
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
    }

    public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        UsageDate.key(for: date, timeZone: timeZone)
    }

    /// 丢弃其他日期的采样。返回 true 表示序列发生了变化。
    @discardableResult
    public mutating func retainDay(containing date: Date,
                                   timeZone: TimeZone = .current) -> Bool {
        let expectedKey = Self.dayKey(for: date, timeZone: timeZone)
        let retained: [TodayUsageSample]
        if dayKey == expectedKey {
            retained = samples.filter {
                Self.dayKey(for: $0.timestamp, timeZone: timeZone) == expectedKey
            }
        } else {
            retained = []
        }

        let changed = dayKey != expectedKey || retained != samples
        dayKey = expectedKey
        samples = retained
        return changed
    }

    /// 同一分钟内只保留最后一次刷新；跨分钟则追加，以便折线显示平台段。
    public mutating func record(tokens: Int,
                                at timestamp: Date,
                                timeZone: TimeZone = .current,
                                maxSamples: Int = 1_500) {
        retainDay(containing: timestamp, timeZone: timeZone)
        let calendar = UsageDate.calendar(timeZone: timeZone)
        let sample = TodayUsageSample(timestamp: timestamp, tokens: max(tokens, 0))

        if let index = samples.lastIndex(where: {
            calendar.isDate($0.timestamp, equalTo: timestamp, toGranularity: .minute)
        }) {
            samples[index] = sample
        } else {
            samples.append(sample)
        }
        samples.sort { $0.timestamp < $1.timestamp }

        let limit = max(maxSamples, 1)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }

    public mutating func clear(at date: Date = Date(),
                               timeZone: TimeZone = .current) {
        dayKey = Self.dayKey(for: date, timeZone: timeZone)
        samples.removeAll(keepingCapacity: false)
    }
}

public struct BalanceSnapshot: Equatable {
    public var currency: String
    public var total: Double
    public var granted: Double     // 赠送余额
    public var toppedUp: Double    // 充值余额
    public var isAvailable: Bool
    public var updatedAt: Date

    public var symbol: String { currency == "CNY" ? "¥" : "$" }
}

public struct DailyUsage: Equatable, Identifiable {
    public var id: String { date }
    public var date: String        // YYYY-MM-DD
    public var tokens: Int
    public var cost: Double
    public var requests: Int
}

public struct TodayModelUsage: Equatable, Sendable {
    public var tokens: Int
    public var cost: Double

    public init(tokens: Int = 0, cost: Double = 0) {
        self.tokens = tokens
        self.cost = cost
    }
}

/// Search / Fetch 按次计量；消费金额取平台账单，不用请求数乘本地单价估算。
public struct ToolUsage: Equatable, Sendable {
    public var requests: Int
    public var cost: Double

    public init(requests: Int = 0, cost: Double = 0) {
        self.requests = requests
        self.cost = cost
    }
}

public struct ToolUsageSummary: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var today: ToolUsage
    public var month: ToolUsage

    public init(name: String, today: ToolUsage = .init(), month: ToolUsage = .init()) {
        self.name = name
        self.today = today
        self.month = month
    }
}

public struct UsageSummary: Equatable {
    public var currency: String
    public var todayTokens: Int
    public var todayCost: Double
    public var todayFlashUsage: TodayModelUsage
    public var todayProUsage: TodayModelUsage
    public var toolUsage: [ToolUsageSummary] = []
    public var monthTokens: Int
    public var monthCost: Double
    public var monthRequests: Int    // 模型请求；Search / Fetch 单独计数
    public var topModel: String?
    public var cacheHitRate: Double?   // 本月缓存命中率 0...1
    public var daily: [DailyUsage]

    public var symbol: String { currency == "CNY" ? "¥" : "$" }
}

public extension UsageSummary {
    /// 近 7 个自然日（含今天）的逐日用量。
    /// API 只返回有用量的日期，缺失的日期补零，保证图表永远是整齐的 7 根柱子。
    func last7CalendarDays(endingOn now: Date = Date(),
                           timeZone: TimeZone = .current) -> [DailyUsage] {
        let cal = UsageDate.calendar(timeZone: timeZone)
        let map = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        return stride(from: 6, through: 0, by: -1).compactMap { back in
            guard let date = cal.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = UsageDate.key(for: date, timeZone: timeZone)
            return map[key] ?? DailyUsage(date: key, tokens: 0, cost: 0, requests: 0)
        }
    }
}

public enum UsageState: Equatable {
    case idle           // 尚未请求（未配置 platform token）
    case loading
    case available
    case tokenExpired   // 40002/40003，需要重新登录
    case unavailable(String)
}

public enum ProbeStatus: Equatable {
    case unknown
    case ok(latencyMs: Int)
    case slow(latencyMs: Int)
    case down(String)

    public var label: String {
        switch self {
        case .unknown: return "未知"
        case .ok(let ms): return "正常 · \(ms)ms"
        case .slow(let ms): return "缓慢 · \(ms)ms"
        case .down(let why): return "异常 · \(why)"
        }
    }

    public var level: Int { // 0 未知 1 正常 2 缓慢 3 异常
        switch self {
        case .unknown: return 0
        case .ok: return 1
        case .slow: return 2
        case .down: return 3
        }
    }
}

public enum StatusPageResult: Equatable {
    case unknown
    case unreachable
    case noIncident       // 总体状态徽章为绿（一切运行正常）
    case incident(String) // 总体状态徽章非绿，附带状态文字
    case undetermined     // 页面可达但结构无法识别（FlashCat 改版时兜底）

    public var label: String {
        switch self {
        case .unknown: return "未检查"
        case .unreachable: return "无法访问"
        case .noIncident: return "一切运行正常"
        case .incident(let s): return s.isEmpty ? "存在故障/降级" : s
        case .undetermined: return "可访问（未能判定，点击查看）"
        }
    }
}

// MARK: - 错误

public enum DeepSeekError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidPlatformToken
    case httpError(Int)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidPlatformToken: return "平台登录已过期，请重新登录"
        case .httpError(let code): return "HTTP \(code)"
        case .apiError(let msg): return msg
        case .parseFailed(let msg): return "解析失败: \(msg)"
        }
    }

    public static func isAuthCode(_ code: Int) -> Bool { code == 40002 || code == 40003 }
}

// MARK: - 官方余额接口响应（api.deepseek.com/user/balance）

public struct BalanceResponse: Decodable {
    public let isAvailable: Bool
    public let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

public struct BalanceInfo: Decodable {
    public let currency: String
    public let totalBalance: String
    public let grantedBalance: String
    public let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

// MARK: - 平台内部接口响应（platform.deepseek.com，防御式解析，全部字段可选）
// 信封结构：{code, msg, data: {biz_code, biz_msg, biz_data}}
// HTTP 状态恒为 200，成败看 code / biz_code；40002/40003 表示 token 缺失或失效。

public struct AmountEnvelope: Decodable {
    public struct Inner: Decodable {
        public struct BizData: Decodable {
            public struct ModelUsage: Decodable {
                public let model: String?
                public let usage: [Item]?
                public struct Item: Decodable {
                    public let type: String?
                    public let amount: String?
                }
            }
            public struct DayUsage: Decodable {
                public let date: String?
                public let data: [ModelUsage]?
            }
            public let total: [ModelUsage]?
            public let days: [DayUsage]?
        }
        public let biz_code: Int?
        public let biz_msg: String?
        public let biz_data: BizData?
    }
    public let code: Int?
    public let msg: String?
    public let data: Inner?
}

public struct CostEnvelope: Decodable {
    public struct Inner: Decodable {
        public struct BizDataItem: Decodable {
            public struct ModelUsage: Decodable {
                public let model: String?
                public let usage: [Item]?
                public struct Item: Decodable {
                    public let type: String?
                    public let amount: String?
                }
            }
            public struct DayUsage: Decodable {
                public let date: String?
                public let data: [ModelUsage]?
            }
            public let total: [ModelUsage]?
            public let days: [DayUsage]?
            public let currency: String?
        }
        public let biz_code: Int?
        public let biz_msg: String?
        public let biz_data: [BizDataItem]?
    }
    public let code: Int?
    public let msg: String?
    public let data: Inner?
}
