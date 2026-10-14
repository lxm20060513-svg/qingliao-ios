// MARK: - v4.0.109 工作区「待你处理」真值表
//
// 被测对象：`qingliao/Core/WorkspacePendingKit.swift`（纯逻辑，只 import Foundation）。
// 背景（用户 2026-10-14「『待你处理』聚合」）：工作区要列出**跨会话**的未答问题卡。
// 为什么要这张表：
//   ① 这块的正确性全押在 JSON 解析上，而**字段名一旦与 `Core/Models.swift`（ChatMessage.parse）
//      分叉，页面会静默变空** —— 不报错、不红字，最难查的一类回归；
//   ② 解析/清洗/排序这些最容易手滑的地方，本机没有 Xcode SDK，只有这张表能在推 CI 前跑真逻辑。
//
// 用法：见 `check_swift.sh`「工作区待你处理真值表」那段（run_unit6 编真源 + 跑）。

import Foundation

var passCount = 0
var failCount = 0
/// ⚠️ Swift 6 模式下 main.swift 的顶层代码在 @MainActor 上跑，而本函数是 nonisolated
/// → 不加 @MainActor 会直接编不过（「main actor-isolated var can not be mutated」）。
@MainActor func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

// ── 1. 源可读 + 纯 Foundation（拖进 SwiftUI 这张表就编不过，也是「真值表可编」这条契约本身） ──
let kitSrc = src("qingliao/Core/WorkspacePendingKit.swift")
let modelsSrc = src("qingliao/Core/Models.swift")
check("WorkspacePendingKit.swift 源可读", !kitSrc.isEmpty)
check("Models.swift 源可读（下面拿它比对字段名）", !modelsSrc.isEmpty)
check("待你处理逻辑层只 import Foundation",
      kitSrc.contains("import Foundation") && !kitSrc.contains("import SwiftUI"))

// ── 2. 字段名与 Models.swift 同源（分叉 = 页面静默变空） ──
check("会话字段名同源：id / title / messages",
      kitSrc.contains("\"id\"") && kitSrc.contains("\"title\"") && kitSrc.contains("\"messages\"")
      && modelsSrc.contains("d[\"title\"]") && modelsSrc.contains("d[\"messages\"]"))
check("消息字段名同源：timestamp / content / questionId / questionAnswer",
      kitSrc.contains("\"timestamp\"") && kitSrc.contains("\"content\"")
      && kitSrc.contains("\"questionId\"") && kitSrc.contains("\"questionAnswer\"")
      && modelsSrc.contains("d[\"timestamp\"]") && modelsSrc.contains("d[\"content\"]")
      && modelsSrc.contains("d[\"questionId\"]") && modelsSrc.contains("d[\"questionAnswer\"]"))
check("未答判据 = questionAnswer 为空",
      kitSrc.contains("guard text(m[\"questionAnswer\"]) == nil else { continue }"))

// ── 3. 真逻辑：抽卡 / 过滤 / 去重 / 排序 ──
func msg(_ content: String, questionId: String? = nil, answer: String? = nil, ts: Double) -> [String: Any] {
    var d: [String: Any] = ["content": content, "timestamp": ts]
    if let q = questionId { d["questionId"] = q }
    if let a = answer { d["questionAnswer"] = a }
    return d
}
func sess(_ id: String, _ title: String, _ msgs: [[String: Any]]) -> [String: Any] {
    ["id": id, "title": title, "messages": msgs]
}

let json: [String: Any] = ["sessions": [
    sess("s1", "写周报", [msg("要不要我把这周改动整理成发布说明？\n选项：要|不用", questionId: "q1", ts: 1_000),
                        msg("好的", ts: 1_100)]),
    sess("s2", "报销", [msg("发票照片收到了吗？", questionId: "q2", ts: 5_000),
                       msg("已收到", questionId: "q2b", answer: "收到", ts: 6_000)]),
    sess("s3", "闲聊", [msg("今天天气不错", ts: 9_000)]),
]]
let items = WorkspacePendingKit.parse(json)
check("抽出 2 张未答问题卡（已答的卡与无 questionId 的普通消息都不算）", items.count == 2)
check("按时间新 → 旧排序（s2 在前）", items.first?.sessionId == "s2")
check("问题正文取首行、剥掉「选项：」行", items.first?.question == "发票照片收到了吗？")
check("会话标题带出来（列表第 2 行要用）", items.first?.sessionTitle == "报销")
check("带答案的同一张卡不进列表", !items.contains { $0.sessionId == "s2" && $0.question.contains("已收到") })
check("空/坏输入 → 空数组（不崩）",
      WorkspacePendingKit.parse(nil).isEmpty
      && WorkspacePendingKit.parse([:]).isEmpty
      && WorkspacePendingKit.parse(["sessions": "坏了"]).isEmpty)
check("会话缺 id → 跳过（id 是跳转的钥匙）",
      WorkspacePendingKit.parse(["sessions": [["title": "x",
                                               "messages": [msg("hi", questionId: "q", ts: 1)]]]]).isEmpty)
check("questionId 是空串 → 不算卡",
      WorkspacePendingKit.parse(["sessions": [sess("s", "t", [msg("hi", questionId: " ", ts: 1)])]]).isEmpty)
check("同卡重复投递只留一条（同会话同 questionId）",
      WorkspacePendingKit.parse(["sessions": [sess("s9", "t", [msg("再来一次", questionId: "qz", ts: 2),
                                                                msg("再来一次", questionId: "qz", ts: 3)])]]).count == 1)
check("会话标题缺失 → 兜底「未命名会话」",
      WorkspacePendingKit.parse(["sessions": [["id": "s", "messages": [msg("问一句", questionId: "q", ts: 1)]]]])
        .first?.sessionTitle == "未命名会话")
check("时间字段吃 Int / 字符串数字（后端两种都可能给）",
      WorkspacePendingKit.parse(["sessions": [sess("s", "t", [["content": "问", "questionId": "q", "timestamp": 7]])]]).first?.time == 7
      && WorkspacePendingKit.parse(["sessions": [sess("s", "t", [["content": "问", "questionId": "q", "timestamp": "8"]])]]).first?.time == 8)
check("会话最后消息时间 = 该会话 messages 里最大 timestamp（不是问题那条的时间）",
      WorkspacePendingKit.parse(json).first(where: { $0.sessionId == "s2" })?.time == 6_000)

// ── 4. 正文清洗（questionLine） ──
check("首行是媒体占位 → 继续往下找正文",
      WorkspacePendingKit.questionLine("MEDIA:/x/y.png\n要我做表格吗？") == "要我做表格吗？")
check("空内容 / 非字符串 → nil（不崩）",
      WorkspacePendingKit.questionLine(nil) == nil
      && WorkspacePendingKit.questionLine("") == nil
      && WorkspacePendingKit.questionLine(42) == nil)
check("超长截断到 42 字 + 省略号",
      (WorkspacePendingKit.questionLine(String(repeating: "字", count: 80)) ?? "").count == 43)
check("剥掉行首 markdown 标记（# / - / >）",
      WorkspacePendingKit.questionLine("## 要不要继续？") == "要不要继续？"
      && WorkspacePendingKit.questionLine("- 帮你订票？") == "帮你订票？")
check("只有「选项：」行 → nil（没有正文就别占一行）",
      WorkspacePendingKit.questionLine("选项：要|不用") == nil)

// ── 5. 相对时间（毫秒入参） ──
let now: Double = 1_700_000_000_000
check("相对时间五档：刚刚 / 分钟 / 小时 / 天 / 更早走日期",
      WorkspacePendingKit.relative(now - 30_000, now: now) == "刚刚"
      && WorkspacePendingKit.relative(now - 5 * 60_000, now: now) == "5 分钟前"
      && WorkspacePendingKit.relative(now - 3 * 3_600_000, now: now) == "3 小时前"
      && WorkspacePendingKit.relative(now - 2 * 86_400_000, now: now) == "2 天前"
      && WorkspacePendingKit.relative(now - 30 * 86_400_000, now: now).contains("月"))

print("工作区「待你处理」真值表：#18 \(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
