import DeepSeekBarCore
import Foundation

// 极简断言测试器（CLT 环境无 XCTest，用退出码表示成败）
var failures = 0
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name) \(detail)")
        failures += 1
    }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

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
          {"model": "deepseek-chat", "usage": [
            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "80"},
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "20"},
            {"type": "RESPONSE_TOKEN", "amount": "50"},
            {"type": "REQUEST", "amount": "2"}
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
            {"model": "deepseek-chat", "usage": [
              {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.0010"},
              {"type": "RESPONSE_TOKEN", "amount": "0.0020"}
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
    check(s.todayTokens == 150, "今日 tokens", "实际 \(s.todayTokens)")           // 80+20+50
    check(approx(s.todayCost, 0.003), "今日消费", "实际 \(s.todayCost)")
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
    Task {
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

print(failures == 0 ? "\n全部通过 ✅" : "\n\(failures) 项失败 ❌")
exit(failures == 0 ? 0 : 1)
