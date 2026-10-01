// 第 6 项「反思日记（每日一问 + 周回顾）」App 侧真值表（v4.0.x）
//
// 后端表（ql_journal/truth_table_journal.py）只管「什么时候问、问什么」。
// 这张管 App 这一层的特有事故 —— 全是编译照过、点一下才炸：
//   · 界面自己写一句问句 → 显示一句、真投递另一句（同第 5 项 due 口径漂移）
//   · 「看看今天到点没」误传 dry_run:false → 点一下真发消息 + 算今天已问
//   · 答问走后端却在 UI 上谎报「已存进记忆」（后端 saved=false）
//   · journalHour 的 Stepper 区间与后端 save_config 的 0~23 脱钩
//   · 三张真值表的「卡片顺序」断言随新增卡片失同步

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
/// 切出某个声明的函数/属性体（首个 4 空格闭合花括号收口），排除式断言用
func slice(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to, range: a.upperBound..<s.endIndex) else {
        return ""
    }
    return String(s[a.lowerBound..<b.lowerBound])
}

let spRaw = src("Features/Settings/SettingsProactive.swift")
let sp = stripCommentLines(spRaw)
check("SettingsProactive.swift 源可读", !sp.isEmpty)

// ── ① 卡片真的挂上去了（写了个 view 但没人调用 = 假实现）──
check("ProactiveAgentSheet 渲染 journalCard", sp.contains("                    journalCard"))
check("journalCard 有声明", sp.contains("private var journalCard: some View"))
let ord = ["budgetCard", "sourceCard", "followupCard", "journalCard", "reviewCard", "manualCard"]
    .compactMap { sp.range(of: "                    \($0)\n")?.lowerBound }
check("六张卡片按 预算→事件源→待跟进→反思日记→复盘→手动 顺序渲染",
      ord.count == 6 && zip(ord, ord.dropFirst()).allSatisfy { $0 < $1 },
      "\(ord.count)/6")

// ── ② 问句口径只在后端：界面读下发值，绝不自造 ──
check("问句读后端下发的 question 字段",
      sp.contains("(j[\"question\"] as? String) ?? \"—\""))
check("界面没有第二份问句文案池（自造问句 = 显示与投递漂移）",
      !sp.contains("今天有什么值得记下来的")
        && !sp.contains("JOURNAL_DAILY_QS")
        && !sp.contains("WEEKLY_REVIEW_TEXT"))
check("问句缺失时显示破折号而不是空字符串", sp.contains("?? \"—\""))
check("问句允许两行（fixedSize 撑开，不被压成一行截断）",
      sp.contains("Text((j[\"question\"] as? String) ?? \"—\")")
        && sp.contains(".fixedSize(horizontal: false, vertical: true)"))

// ── ③ 「看看今天到点没」只判定不投递 ──
check("预览走 /api/agent/proactive/journal",
      sp.contains("/api/agent/proactive/journal\", method: \"POST\""))
check("预览显式传 dry_run: true", sp.contains("body: [\"dry_run\": true]"))
check("预览**没有**传 dry_run: false（那会真发消息 + 算今天已问）",
      !sp.contains("\"dry_run\": false"))
check("预览按钮文案写明只判定不投递", sp.contains("不会真发消息"))
check("预览读后端回包 produced 决定文案", sp.contains("intOf(d[\"produced\"], 0)"))

// ── ④ 答问：只发内容给后端，不自己写记忆接口 ──
check("答问走 /api/agent/proactive/journal/answer",
      sp.contains("/api/agent/proactive/journal/answer"))
check("答问正文取自输入框（先 trim 空白）",
      sp.contains("journalDraft.trimmingCharacters(in: .whitespacesAndNewlines)"))
check("空内容不让发（按钮 disabled 守卫）",
      sp.contains(".disabled(journalBusy || journalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"))
check("App 不自己 POST 记忆写入口（记忆写入只有 memory_store 一条真路）",
      !slice(sp, from: "private func submitJournal(", to: "private func previewJournal(")
        .contains("/api/memory"))
check("后端说没存进记忆时 UI 如实告知，不谎报成功",
      sp.contains("(d[\"saved\"] as? Bool) == true ? \"已存进记忆\"")
        && sp.contains("记忆写入失败"))

// ── ⑤ 状态读数一律用「== true」守卫（字段缺失时安全落 false）──
check("asked/answered/weekAsked 都用 as? Bool == true 判",
      sp.contains("(j[\"asked\"] as? Bool) == true")
        && sp.contains("(j[\"answered\"] as? Bool) == true")
        && sp.contains("(j[\"weekAsked\"] as? Bool) == true"))

// ── ⑥ 与后端配置项口径对齐 ──
check("总开关读写 journalEnable", sp.contains("cfg[\"journalEnable\"] as? Bool ?? true")
        && sp.contains("patch([\"journalEnable\": $0])"))
check("小时阈值读写 journalHour（默认值 22 与后端 DEFAULT_CFG 一致）",
      sp.contains("intOf(cfg[\"journalHour\"], 22)") && sp.contains("patch([\"journalHour\": $0])"))
check("Stepper 区间与后端 save_config 的 0~23 一致", sp.contains("in: 0...23"))
check("默认值不写字面量 true 冒充常量",
      !sp.contains("cfg[\"journalEnable\"] as? Bool ?? 22"))

// ── ⑦ 「已答过」回显只读后端留痕，不本地存 ──
check("回显答案读后端 answer 字段", sp.contains("j[\"answer\"] as? String"))
check("回显有行数上限（长答案不撑爆卡片）",
      sp.contains(".lineLimit(3)"))
check("输入框与回显都要能承载长文本（lineLimit 非单行）",
      sp.contains(".lineLimit(1...3)"))
check("答问成功后清空输入（防重复提交同一句）",
      slice(sp, from: "private func submitJournal(", to: "private func previewJournal(")
        .contains("journalDraft = \"\""))

// ── ⑧ 忙态三件套：两个按钮各自独立忙态 + 禁用，防双击重复请求 ──
check("存回答有独立忙态 journalBusy", sp.contains("@State private var journalBusy = false"))
check("预览有独立忙态 juBusy", sp.contains("@State private var juBusy = false"))
check("两个忙态都在 defer 里复位", sp.contains("defer { journalBusy = false }")
        && sp.contains("defer { juBusy = false }"))

// ── ⑨ 后端真值表在本仓预检里挂着（防新增代码无人跑）──
let cs = src("../check_swift.sh")
check("check_swift.sh 引用了 ql_journal 真值表",
      cs.contains("ql_journal") && cs.contains("truth_table_journal.py"))

// ── ⑩ 令牌不得自造 ──
let themeSrcAll = src("Theme/Theme.swift") + src("Theme/Layout.swift")
    + src("Theme/Typography.swift") + src("Theme/Spacing.swift")
    + src("Core/DesignTokens.swift")
let used = ["Spacing.xxl", "Spacing.lg", "Spacing.rowDividerInset",
            "Typography.body", "Typography.subhead", "Typography.tiny"]
check("本卡用到的设计令牌都在主题文件里存在",
      used.allSatisfy { themeSrcAll.contains($0) || themeSrcAll.contains(String($0.split(separator: ".").last!)) })

print("—— 第 6 项 App 真值表：\(passCount) 通过 / \(failCount) 失败")