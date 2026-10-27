import DeepSeekBarWidgetShared
import Foundation

func runWidgetTests() {
    print("▶ 桌面小组件：自然日、过期与共享快照")
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23, minute: 55))!
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    var snapshot = WidgetSnapshot.preview(at: date)
    snapshot.usage?.timeZoneIdentifier = zone.identifier

    check(snapshot.currentUsage(at: date, timeZone: zone)?.todayTokens == 152_400,
          "同一天展示实际用量")
    check(snapshot.currentUsage(at: midnight, timeZone: zone) == nil,
          "跨日跨月不把昨天的累计用量显示为今日")
    check(snapshot.currentUsage(at: date, timeZone: TimeZone(secondsFromGMT: 0)!) == nil,
          "时区变化后隐藏旧时区用量")
    check(!snapshot.isStale(at: date.addingTimeInterval(899))
          && snapshot.isStale(at: date.addingTimeInterval(900)), "默认十五分钟后标记快照过期")
    check(snapshot.timelineDates(from: date, timeZone: zone)
          == [date, midnight, date.addingTimeInterval(900)],
          "即使主应用退出，时间线仍含午夜清空与过期节点")
    check(snapshot.timelineDates(from: date.addingTimeInterval(1800), timeZone: zone).allSatisfy {
        $0 >= date.addingTimeInterval(1800)
    }, "读取旧快照不会排入过去的时间线节点")

    snapshot.refreshIntervalMinutes = 60
    check(snapshot.expiresAt == date.addingTimeInterval(7200), "慢刷新设置允许两个刷新周期")
    snapshot.usageState = .expired
    check(snapshot.currentUsage(at: date, timeZone: zone) == nil, "登录过期不显示旧账户用量")
    snapshot.usageState = .needsSetup
    check(snapshot.currentUsage(at: date, timeZone: zone) == nil, "未登录不显示缓存用量")
    snapshot.usageState = .unavailable
    check(snapshot.currentUsage(at: date, timeZone: zone) != nil, "临时失败可保留同日数据并显示失败状态")
    check(WidgetSnapshot.money(0.0003, currency: "CNY") == "¥0.0003", "小组件保留极小消费金额")
    check(WidgetSnapshot.money(0, currency: "USD") == "$0.00", "零消费与美元格式")
    check(WidgetSnapshot.tokens(152_400) == "152.4K", "小组件 token 缩写")

    do {
        let data = try JSONEncoder().encode(snapshot)
        check(try WidgetBridge.decode(data) == snapshot, "主应用快照可以通过本机协议往返")
        var cleared = WidgetSnapshot(generatedAt: date)
        let reloaded = try WidgetBridge.decode(JSONEncoder().encode(cleared))
        check(reloaded.balance == nil && reloaded.usage == nil && reloaded.usageState == .needsSetup,
              "清除凭据后的快照替换掉旧余额与用量")
        cleared.version = 99
        do {
            _ = try WidgetBridge.decode(JSONEncoder().encode(cleared))
            check(false, "不兼容版本必须拒绝")
        } catch WidgetBridge.BridgeError.invalidResponse {
            check(true, "不兼容版本显示失败状态")
        }
        do {
            _ = try WidgetBridge.decode(Data("broken JSON".utf8))
            check(false, "损坏快照必须拒绝")
        } catch is DecodingError {
            check(true, "损坏快照不会被误当作零余额或演示数据")
        }
        do {
            _ = try WidgetBridge.decode(Data(repeating: 0, count: WidgetBridge.maximumResponseBytes + 1))
            check(false, "过大响应必须拒绝")
        } catch WidgetBridge.BridgeError.invalidResponse {
            check(true, "拒绝过大响应")
        }
        do {
            let future = WidgetSnapshot(generatedAt: Date().addingTimeInterval(3600))
            _ = try WidgetBridge.decode(JSONEncoder().encode(future))
            check(false, "未来时间戳必须拒绝")
        } catch WidgetBridge.BridgeError.invalidResponse {
            check(true, "拒绝未来时间戳")
        }
    } catch {
        check(false, "小组件快照协议", error.localizedDescription)
    }

    let valid = "GET /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1:47924\r\nX-DeepSeekBar-Widget: 1\r\n\r\n"
    check(WidgetBridge.accepts(valid), "接受原生小组件的本机请求")
    let rejected = [
        valid.replacingOccurrences(of: "GET ", with: "POST "),
        valid.replacingOccurrences(of: "/v1/snapshot", with: "/credentials"),
        valid.replacingOccurrences(of: "127.0.0.1:47924", with: "evil.example:47924"),
        valid.replacingOccurrences(of: "X-DeepSeekBar-Widget: 1\r\n", with: ""),
        valid.replacingOccurrences(of: "X-DeepSeekBar-Widget: 1", with: "X-DeepSeekBar-Widget: 1\r\nOrigin: https://evil.example"),
        valid.replacingOccurrences(of: "X-DeepSeekBar-Widget: 1", with: "X-DeepSeekBar-Widget: 1\r\nHost: localhost:47924"),
        valid.replacingOccurrences(of: "X-DeepSeekBar-Widget: 1", with: "X-DeepSeekBar-Widget: 1\r\nTransfer-Encoding: chunked"),
        valid + valid,
    ]
    for (index, request) in rejected.enumerated() {
        check(!WidgetBridge.accepts(request), "拒绝非法或浏览器请求 \(index + 1)")
    }
}
