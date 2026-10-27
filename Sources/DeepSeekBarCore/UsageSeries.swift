import Foundation

// 平台公开前端于 2026-10-27 使用的 by_api_key 账单结构。
// https://fe-static.deepseek.com/platform/static/1063.6997bc1b00.js
// 仅解析统计字段，不保留 api_key 的名称、tracking_id 等账户信息。
struct UsageEnvelope<Payload: Decodable>: Decodable {
    struct Inner: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: Payload?

        enum CodingKeys: String, CodingKey { case biz_code, biz_msg, biz_data }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            biz_code = try values.decodeIfPresent(Int.self, forKey: .biz_code)
            biz_msg = try values.decodeIfPresent(String.self, forKey: .biz_msg)
            // 失败响应的 biz_data 可能是 {}，先保留错误码，不按成功协议解码。
            biz_data = biz_code == 0 ? try values.decodeIfPresent(Payload.self, forKey: .biz_data) : nil
        }
    }
    let code: Int?
    let data: Inner?

    enum CodingKeys: String, CodingKey { case code, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decodeIfPresent(Int.self, forKey: .code)
        data = code == 0 ? try values.decodeIfPresent(Inner.self, forKey: .data) : nil
    }
}

/// 平台用量为数值，金额通常为十进制字符串；同时兼容两种 JSON 编码。
struct BillingValue: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self),
           let value = Double(string), value.isFinite {
            text = string
        } else if let integer = try? container.decode(Int.self) {
            text = String(integer)
        } else {
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid billing value")
            }
            text = String(value)
        }
    }
}

struct UsageAmountData: Decodable {
    struct Series: Decodable {
        struct Bucket: Decodable {
            let time: TimeInterval
            let usage: [String: BillingValue]
        }
        let model: String
        let buckets: [Bucket]
    }
    // 缺失集合表示协议变化，不应被当成免费或零用量。
    let series: [Series]
    let function_series: [Series]

    func normalized(now: Date, timeZone: TimeZone) -> AmountEnvelope.Inner.BizData {
        typealias Record = AmountEnvelope.Inner.BizData.ModelUsage
        let window = UsageWindow(now: now, timeZone: timeZone)
        var total: [Record] = []
        var days: [String: [Record]] = [:]
        for (records, isFunction) in [(series, false), (function_series, true)] {
            for series in records {
                for bucket in series.buckets where window.contains(bucket.time) {
                    let record = Record(model: series.model, usage: bucket.usage.compactMap { type, value in
                        // function_series 与模型统计隔离，避免工具进入 tokens / 缓存命中率。
                        guard isFunction ? type == "FUNCTION_CALL" : type != "FUNCTION_CALL" else { return nil }
                        return .init(type: type, amount: value.text)
                    })
                    days[window.dayKey(bucket.time), default: []].append(record)
                    if bucket.time >= window.monthStart.timeIntervalSince1970 { total.append(record) }
                }
            }
        }
        return .init(total: total, days: days.map { .init(date: $0.key, data: $0.value) })
    }
}

struct UsageCostData: Decodable {
    struct CurrencyData: Decodable {
        struct Series: Decodable {
            struct Bucket: Decodable {
                let time: TimeInterval
                let cost: BillingValue
            }
            let model: String
            let buckets: [Bucket]
        }
        let currency: String
        let series: [Series]
        let function_series: [Series]

        func normalized(now: Date, timeZone: TimeZone) -> CostEnvelope.Inner.BizDataItem {
            typealias Record = CostEnvelope.Inner.BizDataItem.ModelUsage
            let window = UsageWindow(now: now, timeZone: timeZone)
            var total: [Record] = []
            var days: [String: [Record]] = [:]
            for (records, isFunction) in [(series, false), (function_series, true)] {
                for series in records {
                    for bucket in series.buckets where window.contains(bucket.time) {
                        // 新账单已按模型聚合金额；不再分拆成 token 价格。
                        let record = Record(model: series.model, usage: [
                            .init(type: isFunction ? "FUNCTION_CALL" : "BILLED_MODEL_COST", amount: bucket.cost.text)
                        ])
                        days[window.dayKey(bucket.time), default: []].append(record)
                        if bucket.time >= window.monthStart.timeIntervalSince1970 { total.append(record) }
                    }
                }
            }
            return .init(total: total, days: days.map { .init(date: $0.key, data: $0.value) }, currency: currency)
        }
    }
    let data: [CurrencyData]
}

/// 一次查询覆盖本月与近七日；end 为明日零点（不含），跨月数据仅用于图表。
struct UsageWindow {
    let monthStart: Date
    let start: Date
    let end: Date
    let timeZone: TimeZone

    init(now: Date, timeZone: TimeZone) {
        // 平台查询只有一个 tz 偏移；整段查询按当前偏移计算，不能混入月内历史 DST。
        let billingTimeZone = TimeZone(secondsFromGMT: timeZone.secondsFromGMT(for: now))!
        let calendar = UsageDate.calendar(timeZone: billingTimeZone)
        let today = calendar.startOfDay(for: now)
        monthStart = calendar.dateInterval(of: .month, for: now)!.start
        start = min(monthStart, calendar.date(byAdding: .day, value: -6, to: today)!)
        end = calendar.date(byAdding: .day, value: 1, to: today)!
        self.timeZone = billingTimeZone
    }

    func contains(_ seconds: TimeInterval) -> Bool {
        seconds >= start.timeIntervalSince1970 && seconds < end.timeIntervalSince1970
    }

    func dayKey(_ seconds: TimeInterval) -> String {
        UsageDate.key(for: Date(timeIntervalSince1970: seconds), timeZone: timeZone)
    }
}
