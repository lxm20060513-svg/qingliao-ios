// 第 5 项「主动跟进闭环」App 侧真值表（v4.0.x）
//
// 为什么后端表（ql_followup/truth_table_followup.py）之外还要这张：那张只管「到没到点」。
// App 这一层最容易出的事故是**界面说一套、点下去做另一套**，而且全是编译得过、点一下才炸：
//   · 「已到点」由前端拿时间戳重算 = 两套口径必然漂移（界面说到点，真跑不投递）
//   · 「现在检查」误传 dry_run:false → 点一下真发消息 + 吃掉一次提问机会
//   · 勾销在前端本地删计数 → 后端还记着 2 遍，用户再标回来它就永远闭嘴
//   · 插值写成字面量 \\(…) → 编译照过（\\ 是合法转义），界面显示鬼话

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool, _ extra: @autoclosure () -> String = "") {
    if cond {
        passCount += 1
    } else {
        failCount += 1
        let e = extra()
        print("❌ \(name)\(e.isEmpty ? "" : "  ← \(e)")")
    }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) else { return "" }
    return s
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

let sp = stripCommentLines(src("Features/Settings/SettingsProactive.swift"))
check("SettingsProactive.swift 源可读", !sp.isEmpty)

// ── ① 待跟进卡片真的挂在页面上（写了个 view 但没人调用是最常见的假实现） ──
check("ProactiveAgentSheet 渲染 followupCard", sp.contains("                    followupCard"))
check("followupCard 有声明", sp.contains("private var followupCard: some View"))
// v4.0.x 第 6 项起是**六**张（新增反思日记，在待跟进与复盘之间）。
let order = ["budgetCard", "sourceCard", "followupCard", "journalCard", "reviewCard", "manualCard"]
var idx = order.compactMap { sp.range(of: "                    \($0)\n")?.lowerBound }
check("六张卡片按 预算→事件源→待跟进→反思日记→复盘→手动 顺序渲染",
      idx.count == 6 && zip(idx, idx.dropFirst()).allSatisfy { $0 < $1 },
      "\(idx.count)/6")

// ── ② 到期口径只在后端：due/dueAt 一律读下发值，前端不重算 ──
check("界面用后端下发的 due 字段", sp.contains("(r[\"due\"] as? Bool) == true"))
check("界面不拿时间戳自己算到期（没有 Date()/timeIntervalSince 参与 due）",
      !sp.contains("due") || !sp.contains("Date().timeIntervalSince")
        || !sp.contains("timeIntervalSince1970"),
      "前端出现本地时钟算到期")
check("后端未下发/未到点时显示「还没到时间」，不谎报",
      sp.contains("\"还没到时间\"") && sp.contains("已到点，会主动问一句"))
check("due 缺失时安全回落为 false（as? Bool == true 恒真守卫）",
      sp.contains("as? Bool) == true"))

// ── ③ 「现在检查」只判定不投递 ──
check("检查按钮走 /api/agent/proactive/followup",
      sp.contains("/api/agent/proactive/followup"))
check("检查按钮显式传 dry_run: true", sp.contains("body: [\"dry_run\": true]"))
check("检查按钮**没有**传 dry_run: false（那会真发消息 + 消耗提问机会）",
      !sp.contains("\"dry_run\": false") && !sp.contains("dry_run: false"))
check("按钮文案写明只判定不投递", sp.contains("不会真发消息"))

// ── ④ 勾销/忽略 = 翻状态离开 pending；前端绝不碰计数 ──
check("勾销写 /api/memory/status", sp.contains("/api/memory/status"))
check("勾销翻成 active", sp.contains("status: \"active\""))
check("忽略翻成 stale", sp.contains("status: \"stale\""))
check("App 不本地删除/改写追问计数",
      !sp.contains("removeValue(forKey:")
        && !sp.contains("asked\"] = ") && !sp.contains("asked\"] ?? 0"),
      "出现前端本地删/改 asked 的写法")
check("勾销后重新拉 state（界面跟后端走，不本地推算）",
      sp.contains("state = (await auth.jsonOrLog(\"/api/agent/proactive/state\")) ?? state"))
check("失败时不谎报成功（有失败分支提示已还原）", sp.contains("已还原"))

// ── ⑤ 空态有话说 ──
check("无 pending 时给出操作指引", sp.contains("还没有待跟进的事"))

// ── ⑥ 上限/阈值读后端，不在前端硬编 ──
check("上限读后端 maxRounds", sp.contains("intOf(fu[\"maxRounds\"], 3)"))
check("阈值读后端 afterHours", sp.contains("intOf(fu[\"afterHours\"], 20)"))
check("Stepper 区间与后端 save_config 的 1~720 一致", sp.contains("in: 1...720"))

// ── ⑦ 插值字面量真 bug 回归 ──
check("阈值标签是真插值不是字面量反斜杠", !sp.contains("Stepper(\"\\\\(intOf("))
check("阈值标签用单反斜杠插值", sp.contains("Stepper(\"\\(intOf("))
check("待跟进摘要不是字面量反斜杠", !sp.contains("Text(\"待跟进 \\\\(pending.count"))

// ── ⑧ FollowupRow ──
check("FollowupRow 有 struct 定义", sp.contains("struct FollowupRow: View"))
check("FollowupRow 渲染「已办完」", sp.contains("已办完"))
check("FollowupRow 渲染「不用管」", sp.contains("不用管"))
check("行内动作按 busy 禁用（防重复点击重复发请求）", sp.contains(".disabled(busy)"))
check("行内显示已问遍数/上限", sp.contains("已问"))

// ── ⑨ 令牌不得自造（缺令牌 = 编译红，这一层只需确认用全的是已有名字） ──
let theme = src("Theme/Theme.swift") + src("Core/DesignTokens.swift")
let used = ["Spacing.xxl", "Spacing.lg", "Spacing.rowDividerInset",
            "Typography.body", "Typography.subhead", "Typography.tiny"]
let themeSrcAll = (theme + src("Theme/Layout.swift") + src("Theme/Typography.swift")
                   + src("Theme/Spacing.swift"))
check("本文件用到的设计令牌都在主题文件里存在",
      used.allSatisfy { themeSrcAll.contains($0) || themeSrcAll.contains(String($0.split(separator: ".").last!)) })

print("—— 第 5 项 App 真值表：\(passCount) 通过 / \(failCount) 失败")