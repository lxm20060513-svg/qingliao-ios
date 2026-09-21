// v3.9.56 TypeSafe 智能路由（设置页开关）真值表
// 被测逻辑：qingliao/Core/TypesafeRouting.swift（生产代码，非镜像副本）
//
// 为什么必须逐条断言：这块 UI 上显示/回写的全是**后端状态**，算错一格就是「开关显示已开启、
// 后端其实没判定」或者「熔断倒计时差一分钟」——用户在真机上看到的就是假状态。而本机没有 iOS SDK，
// 真机验证一轮很贵（打包 + 侧载 + 装机）。所以模型层刻意写成纯 Foundation 纯函数，在这里钉死。
//
// 编译运行（在仓库根目录，工具链见 check_swift.sh 第 10 步）：
//   rm -rf /tmp/ql_ts_main && mkdir -p /tmp/ql_ts_main
//   cp scripts/test_typesafe_routing.swift /tmp/ql_ts_main/main.swift
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_typesafe_routing \
//       /tmp/ql_ts_main/main.swift qingliao/Core/TypesafeRouting.swift
//   /tmp/test_typesafe_routing
//
// ⚠️ 本表只证「解析 + 文案」；网络读写（GET/POST 是否真落到后端）只能靠真机/接口实测，
//    按钮是否真能点也只能靠真机。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if ok {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

/// 后端 GET /api/agent/typesafe/routing 的真实响应形状
let routingJSON: [String: Any] = [
    "enabled": true, "mode": "smart", "threshold": 0.6, "timeout_ms": 1200,
    "max_chars": 120, "breaker_fails": 3, "breaker_cooldown_s": 300,
]
let breakerJSON: [String: Any] = [
    "open": false, "remain_s": 0, "fails": 0, "trips": 0, "since_s": 0, "last_error": "",
]
let breakerOpenJSON: [String: Any] = [
    "open": true, "remain_s": 272, "fails": 3, "trips": 1, "since_s": 28,
    "last_error": "HTTPError 401",
]

// MARK: - 1. 解析

print("— 解析 —")
let r = TypesafeRouting(json: routingJSON)
check("完整 JSON 解析成功", r != nil)
check("字段全对（enabled/mode/threshold/timeout/max_chars/熔断参数）",
      r == TypesafeRouting(enabled: true, mode: "smart", threshold: 0.6, timeoutMs: 1200,
                           maxChars: 120, breakerFails: 3, breakerCooldownS: 300))
check("与 fallback 同参（后端默认段 == App 兜底段）", r == TypesafeRouting.fallback)

check("enabled 缺失 → 解析失败（不拿兜底冒充后端现状）",
      TypesafeRouting(json: ["mode": "smart"]) == nil)
check("enabled 是字符串 \"true\" → 解析失败（后端协议里它是 bool）",
      TypesafeRouting(json: ["enabled": "true"]) == nil)
check("非 JSON 对象键值（空字典）→ 解析失败", TypesafeRouting(json: [:]) == nil)

let rStr = TypesafeRouting(json: ["enabled": true, "threshold": "0.75", "timeout_ms": "1500",
                                  "max_chars": "80", "breaker_fails": "5", "breaker_cooldown_s": "600"])
check("数字以字符串下发也能读（0.75/1500/80/5/600）",
      rStr?.threshold == 0.75 && rStr?.timeoutMs == 1500 && rStr?.maxChars == 80
        && rStr?.breakerFails == 5 && rStr?.breakerCooldownS == 600)

check("mode 缺失 → 兜底 smart", TypesafeRouting(json: ["enabled": true])?.mode == "smart")
check("threshold 越界 1.5 → 收敛到 1.0",
      TypesafeRouting(json: ["enabled": true, "threshold": 1.5])?.threshold == 1.0)
check("threshold 越界 -0.2 → 收敛到 0.0",
      TypesafeRouting(json: ["enabled": true, "threshold": -0.2])?.threshold == 0.0)
check("整数型 threshold 1 → 1.0（Double/Int 都能吃）",
      TypesafeRouting(json: ["enabled": true, "threshold": 1])?.threshold == 1.0)

// MARK: - 2. 开关行文案

print("— 开关行文案 —")
check("开启 → 「判定是否要干活 · 已开启」", TypesafeRouting.fallback.subtitleText == "判定是否要干活 · 已开启")
check("关闭 → 「已关闭 · 全走原关键词规则」",
      TypesafeRouting(json: ["enabled": false])!.subtitleText == "已关闭 · 全走原关键词规则")
check("关闭时 mode 仍是 smart 也不显示 mode（副标题只说开关状态）",
      TypesafeRouting(json: ["enabled": false, "mode": "smart"])!.subtitleText == "已关闭 · 全走原关键词规则")

print("— 模式文案 —")
check("smart → 智能分流", TypesafeRouting.fallback.modeText == "智能分流")
check("force_agent → 强制 Agent",
      TypesafeRouting(json: ["enabled": true, "mode": "force_agent"])!.modeText == "强制 Agent")
check("off → 关闭", TypesafeRouting(json: ["enabled": true, "mode": "off"])!.modeText == "关闭")
check("未知 mode → 兜底智能分流（不露原始英文串）",
      TypesafeRouting(json: ["enabled": true, "mode": "future_mode"])!.modeText == "智能分流")

print("— 数值文案 —")
check("阈值 0.6 → 「0.60」", TypesafeRouting.fallback.thresholdText == "0.60")
check("阈值 0.75 → 「0.75」", rStr?.thresholdText == "0.75")
check("阈值 0.7（浮点误差）→ 「0.70」",
      TypesafeRouting(json: ["enabled": true, "threshold": 0.7])!.thresholdText == "0.70")
check("超时 1200 → 「1200 ms」", TypesafeRouting.fallback.timeoutText == "1200 ms")

// MARK: - 3. 熔断状态

print("— 熔断解析 —")
check("常规态（未熔断）解析成功", TypesafeBreaker(json: breakerJSON)?.open == false)
check("熔断态解析成功（remain 272 / fails 3）",
      TypesafeBreaker(json: breakerOpenJSON) == TypesafeBreaker(open: true, remainS: 272, fails: 3,
                                                                trips: 1, lastError: "HTTPError 401"))
check("open 缺失 → 解析失败（不拿兜底装正常）", TypesafeBreaker(json: ["remain_s": 10]) == nil)
check("remain_s 缺失 → 0（不崩、不显示垃圾）",
      TypesafeBreaker(json: ["open": true])?.remainS == 0)
check("last_error 缺失 → 空串", TypesafeBreaker(json: ["open": false])?.lastError == "")

print("— 熔断倒计时格式 —")
check("272 秒 → 「04:32」", TypesafeBreaker.clock(272) == "04:32")
check("0 秒 → 「00:00」", TypesafeBreaker.clock(0) == "00:00")
check("59 秒 → 「00:59」", TypesafeBreaker.clock(59) == "00:59")
check("60 秒 → 「01:00」", TypesafeBreaker.clock(60) == "01:00")
check("3600 秒 → 「60:00」（不截断成 00:00）", TypesafeBreaker.clock(3600) == "60:00")
check("负数（到点漂移）→ 「00:00」", TypesafeBreaker.clock(-5) == "00:00")

print("— 冷却时长文案 —")
check("300 秒 → 5 分钟", TypesafeBreaker.cooldownText(300) == "5 分钟")
check("90 秒 → 90 秒（不是「1.5 分钟」）", TypesafeBreaker.cooldownText(90) == "90 秒")
check("0 秒 → 关闭", TypesafeBreaker.cooldownText(0) == "关闭")

print("— 状态行文案 —")
check("熔断中 → 「熔断中 · 剩 04:32 · 连续失败 3 次」",
      TypesafeBreaker(json: breakerOpenJSON)!.statusText(TypesafeRouting.fallback)
        == "熔断中 · 剩 04:32 · 连续失败 3 次")
check("正常态 → 带上熔断门槛（3 次 / 5 分钟）",
      TypesafeBreaker(json: breakerJSON)!.statusText(TypesafeRouting.fallback)
        == "正常 · 连续失败 0 次（连续 3 次失败自动暂停 5 分钟）")
check("熔断已关（breaker_fails=0）→ 不写门槛，写「未启用自动熔断」",
      TypesafeBreaker(json: breakerJSON)!.statusText(TypesafeRouting(json: ["enabled": true, "breaker_fails": 0])!)
        == "正常 · 连续失败 0 次（未启用自动熔断）")
check("失败计数非 0 但未熔断 → 如实显示次数（用户能看到「刚失败过一次」）",
      TypesafeBreaker(json: ["open": false, "fails": 1])!.statusText(TypesafeRouting.fallback)
        == "正常 · 连续失败 1 次（连续 3 次失败自动暂停 5 分钟）")

// MARK: - 4. 文案常量（写进 UI，改了要同步这里）

print("— 常量 —")
check("底部说明：任何异常都回退现状（不能让用户以为会影响回复）",
      TypesafeRouting.footerText == "判定失败/超时一律回退现状，不影响正常回复；改动免重启即时生效")
check("mode=off 提示文案", TypesafeRouting.modeOffHint == "后端 mode=off：判定已关闭，点上面任一模式可恢复")

// MARK: - 汇总

print("")
if failures == 0 {
    print("✅ 全部 \(total) 条断言通过")
    exit(0)
} else {
    print("❌ \(failures)/\(total) 条断言失败")
    exit(1)
}
