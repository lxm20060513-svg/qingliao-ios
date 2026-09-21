// v3.9.54 模型用量卡片文案真值表
//
// 镜像对象：qingliao/Core/Models.swift 的 ProviderUsage.balanceText / detailText
// （本机无 UIKit/SwiftUI，所以只把两条纯判断链原样抄过来，不 import 项目代码）
//
// 事故场景（本表存在的理由）：StepFun 是订阅制、官方无额度查询接口 →
// 原来主文本「控制台查看」+ 副文本「额度见控制台」两句说同一件事；
// 主文本改「订阅制」时**不能误伤**其它 unsupported provider
// （硅基流动=余额接口下线、小米/商汤/AMD=无公开接口），它们必须仍是「控制台查看」。
//
// ⚠️ 本表只证文案分支；类型/并发仍只能靠 CI Archive。

import Foundation

// MARK: - 镜像：balanceText

func mainText(provider: String, unsupported: Bool, mode: String,
              pct: [String: Double], windows: [[String: Any]],
              total: Double, currency: String) -> String {
    if unsupported { return provider == "stepfun" ? "订阅制" : "控制台查看" }
    if mode == "plan", let monthly = pct["monthly"] {
        return String(format: "月用量 %.0f%%", monthly)
    }
    if let w5 = windows.first, let remain = w5["remaining"] as? Int, let tl = w5["total"] as? Int {
        return "\(remain) / \(tl)"
    }
    if total > 0 {
        let sym = currency == "USD" ? "$" : "¥"
        return String(format: "%@%.2f", sym, total)
    }
    return "—"
}

// MARK: - 镜像：detailText

func subText(unsupported: Bool, available: Bool, error: String, mode: String,
             pct: [String: Double], windows: [[String: Any]],
             toppedUp: Double, granted: Double) -> String {
    if unsupported { return error.isEmpty ? "无公开接口" : error }
    if !available { return error.isEmpty ? "不可用" : error }
    if windows.count >= 2, let wk = windows[1] as? [String: Any],
       let usedPct = wk["used_pct"] as? Int {
        return String(format: "周窗口 余 %d%%", 100 - usedPct)
    }
    if mode == "plan" {
        var parts: [String] = []
        if let w = pct["weekly"] { parts.append(String(format: "周 %.0f%%", w)) }
        if let r = pct["rolling"] { parts.append(String(format: "滚动 %.0f%%", r)) }
        return parts.isEmpty ? "订阅中" : parts.joined(separator: " · ")
    }
    var parts: [String] = []
    if toppedUp > 0 { parts.append(String(format: "充值 %.2f", toppedUp)) }
    if granted > 0 { parts.append(String(format: "赠金 %.2f", granted)) }
    return parts.isEmpty ? "可用" : parts.joined(separator: " · ")
}

// MARK: - 用例

struct Case {
    let name: String
    let got: String
    let expect: String
}

var cases: [Case] = []
func add(_ name: String, _ got: String, _ expect: String) {
    cases.append(Case(name: name, got: got, expect: expect))
}

// ① 事故场景：StepFun 订阅制 → 主「订阅制」+ 副「Step Plan · 额度见控制台」
add("事故回归·StepFun 订阅制卡片",
    mainText(provider: "stepfun", unsupported: true, mode: "plan", pct: [:],
             windows: [], total: 0, currency: "CNY"),
    "订阅制")
add("事故回归·StepFun 副文本",
    subText(unsupported: true, available: false, error: "Step Plan · 额度见控制台",
            mode: "plan", pct: [:], windows: [], toppedUp: 0, granted: 0),
    "Step Plan · 额度见控制台")

// ② 反向误伤：其它 unsupported 一律保持「控制台查看」
add("硅基流动（余额接口下线）不被误标订阅制",
    mainText(provider: "siliconflow", unsupported: true, mode: "payg", pct: [:],
             windows: [], total: 0, currency: "CNY"),
    "控制台查看")
add("硅基流动副文本",
    subText(unsupported: true, available: false, error: "官方余额接口已下线，请控制台查看",
            mode: "payg", pct: [:], windows: [], toppedUp: 0, granted: 0),
    "官方余额接口已下线，请控制台查看")
add("小米 MiMo（无公开接口）仍是控制台查看",
    mainText(provider: "xiaomi", unsupported: true, mode: "plan", pct: [:],
             windows: [], total: 0, currency: "CNY"),
    "控制台查看")
add("自定义 provider（空 id）仍是控制台查看",
    mainText(provider: "", unsupported: true, mode: "plan", pct: [:],
             windows: [], total: 0, currency: "CNY"),
    "控制台查看")
add("unsupported 且 error 为空 → 副文本兜底「无公开接口」",
    subText(unsupported: true, available: false, error: "", mode: "plan", pct: [:],
            windows: [], toppedUp: 0, granted: 0),
    "无公开接口")

// ③ payg 余额形态（DeepSeek）
add("payg 有余额 → ¥ 金额",
    mainText(provider: "deepseek", unsupported: false, mode: "payg", pct: [:],
             windows: [], total: 42.5, currency: "CNY"),
    "¥42.50")
add("payg 余额为 0 → —",
    mainText(provider: "deepseek", unsupported: false, mode: "payg", pct: [:],
             windows: [], total: 0, currency: "CNY"),
    "—")
add("payg 美元符号",
    mainText(provider: "deepseek", unsupported: false, mode: "payg", pct: [:],
             windows: [], total: 12.0, currency: "USD"),
    "$12.00")
add("payg 副文本 充值/赠金",
    subText(unsupported: false, available: true, error: "", mode: "payg", pct: [:],
            windows: [], toppedUp: 10.0, granted: 3.5),
    "充值 10.00 · 赠金 3.50")
add("payg 副文本无明细 → 可用",
    subText(unsupported: false, available: true, error: "", mode: "payg", pct: [:],
            windows: [], toppedUp: 0, granted: 0),
    "可用")
add("available=false 非 unsupported → 错误文本当副文本",
    subText(unsupported: false, available: false, error: "连接超时", mode: "payg", pct: [:],
            windows: [], toppedUp: 0, granted: 0),
    "连接超时")
add("available=false 且无错误文本 → 不可用",
    subText(unsupported: false, available: false, error: "", mode: "payg", pct: [:],
            windows: [], toppedUp: 0, granted: 0),
    "不可用")

// ④ plan 百分比形态（OpenCode）
add("plan 月用量百分比",
    mainText(provider: "opencode", unsupported: false, mode: "plan", pct: ["monthly": 33.0],
             windows: [], total: 0, currency: "CNY"),
    "月用量 33%")
add("plan 副文本 周/滚动",
    subText(unsupported: false, available: true, error: "", mode: "plan",
            pct: ["weekly": 12.0, "rolling": 5.0], windows: [], toppedUp: 0, granted: 0),
    "周 12% · 滚动 5%")
add("plan 无百分比明细 → 订阅中",
    subText(unsupported: false, available: true, error: "", mode: "plan",
            pct: [:], windows: [], toppedUp: 0, granted: 0),
    "订阅中")

// ⑤ 智谱双窗口形态
let windows: [[String: Any]] = [["used_pct": 40, "remaining": 60, "total": 100],
                                ["used_pct": 25, "remaining": 75, "total": 100]]
add("双窗口主文本 = 5 小时窗口余量",
    mainText(provider: "zai-coding", unsupported: false, mode: "plan", pct: [:],
             windows: windows, total: 0, currency: "CNY"),
    "60 / 100")
add("双窗口副文本 = 周窗口剩余百分比",
    subText(unsupported: false, available: true, error: "", mode: "plan", pct: [:],
            windows: windows, toppedUp: 0, granted: 0),
    "周窗口 余 75%")

// MARK: - 跑

var failed = 0
for c in cases {
    if c.got == c.expect {
        print("✅ \(c.name) → \(c.got)")
    } else {
        failed += 1
        print("❌ \(c.name) → 得到「\(c.got)」期望「\(c.expect)」")
    }
}
print(failed == 0 ? "🎉 全部通过（\(cases.count) 项）" : "❌ 失败 \(failed)/\(cases.count) 项")
exit(failed == 0 ? 0 : 1)
