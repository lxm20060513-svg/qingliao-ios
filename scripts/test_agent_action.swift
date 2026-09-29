// AgentActionParser 单元测试（Linux 本地预检用，纯 Foundation，无 UI 依赖）
//
// 编译运行（在仓库根目录，cq 工具链见 check_swift.sh）：
//   $SWIFT/swiftc -o /tmp/t qingliao/Core/AgentAction.swift qingliao/Core/AppPermissionKit.swift scripts/test_agent_action.swift
//   /tmp/t
//
// 覆盖：零回归（无标记/非法 JSON/未知动作）· 流式安全（未闭合不出卡）·
//       参数读取 · 动作→能力/影响分级 · ISO8601 容错
//
// ⚠️ AppPermissionKit 依赖 EventKit/Photos/UIKit，Linux 上编不过。
//    所以本测试只**复制** AppCapability / AgentAction 的判定表做等价断言；
//    真值来源仍是 AppPermissionKit.swift，改那边必须同步改这里的 assertTable（check_swift.sh 会提醒）。

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

/// 零回归核心：必须退化成单文本段且逐字相同
func expectPlain(_ name: String, _ input: String) {
    let segs = AgentActionParser.parse(input)
    guard segs.count == 1, case .text(let t) = segs[0] else {
        check(name + "（应为单个文本段）", false)
        return
    }
    check(name + "（文本逐字保留）", t == input)
}

func actionOf(_ segs: [AgentActionParser.Segment], _ idx: Int) -> AgentAction? {
    guard segs.indices.contains(idx), case .action(let a) = segs[idx] else { return nil }
    return a
}

// MARK: - 零回归（口径 ①）

@main
struct TestMain {
    static func main() {
expectPlain("无标记 → 原文",
    "帮我把明天下午的会议加到日历。")
expectPlain("非法 JSON → 原文", """
```ql-action
{action: calendar.create, params:}
```
""")
expectPlain("未知动作 → 原文", """
```ql-action
{"action": "launch.missiles", "params": {}}
```
""")
expectPlain("空围栏 → 原文", """
```ql-action
```
""")

// MARK: - 流式安全（口径 ②：未闭合不出卡）

let unclosed = """
```ql-action
{"action": "calendar.create", "params": {"title": "半截"}}
"""
let unclosedSegs = AgentActionParser.parse(unclosed)
check("未闭合围栏不出卡（流式安全）",
      unclosedSegs.count == 1 && {
          if case .action = unclosedSegs[0] { return false }
          return true
      }())
expectPlain("未闭合围栏 → 原文逐字保留", unclosed)

// MARK: - 正常解析

let full = """
好的，已帮你安排。

```ql-action
{"action": "calendar.create", "params": {"title": "季度评审", "start": "2026-09-28T15:00:00+08:00", "end": "2026-09-28T16:00:00+08:00", "location": "3 号会议室"}, "summary": "新建「季度评审」"}
```

明天上午你有空吗？
"""
let segs = AgentActionParser.parse(full)
check("多段拆分正确（文本/动作/文本）", segs.count == 3)
if case .text(let t) = segs[0] { check("首段文本保留", t.contains("已帮你安排")) }
if case .text(let t) = segs[2] { check("尾段文本保留", t.contains("明天上午")) }

let a = actionOf(segs, 1)
check("动作解析出 calendar.create", a?.kind == .calendarCreate)
check("summary 可读", a?.summary == "新建「季度评审」")
check("参数可读", a?.param("title") == "季度评审")
check("参数 location 可读", a?.param("location") == "3 号会议室")
check("空值参数返回 nil", a?.param("missing") == nil)
check("空白参数返回 nil", a?.param("   ") == nil)

// MARK: - 分级表（口径 ②：读/写/删）

let table: [(AgentAction.Kind, AgentAction.Kind.Impact, String)] = [
    // v4.0.7 后共 22 个动作。这张表是**分级真值**：读=免确认自动跑、写=点一下、删=红色确认。
    // 漏一行不会编译失败（表是数据），所以 scripts/check_action_capabilities.py 会反查
    // 「所有 rawValue 都必须在这张表里」——加动作忘了加分级 = 静默按错的分级执行。
    (.calendarCreate, .write,  "calendar"),
    (.calendarUpdate, .write,  "calendar"),
    (.calendarDelete, .delete, "calendar"),
    (.calendarFree,   .read,   "calendar"),
    (.calendarToday,  .read,   "calendar"),
    (.reminderCreate, .write,  "reminders"),
    (.reminderList,   .read,   "reminders"),
    (.reminderDelete, .delete, "reminders"),
    (.photoSave,      .write,  "photos"),
    (.photoDelete,    .delete, "photos"),
    (.contactsSearch, .read,   "contacts"),
    (.contactsCreate, .write,  "contacts"),
    (.locationCurrent, .read,  "location"),
    (.clipboardRead,  .read,   "clipboard"),
    (.clipboardWrite, .write,  "clipboard"),
    (.fileList,       .read,   "files"),
    (.fileRead,       .read,   "files"),
    (.fileWrite,      .write,  "files"),
    (.notify,         .write,  "notifications"),
    (.mailSend,       .write,  "mail"),
    (.goalCreate,     .write,  "reminders"),
    (.goalStepDone,   .write,  "reminders"),
]
for (kind, impact, cap) in table {
    check("\(kind.rawValue) 影响分级 = \(impact.rawValue)", kind.impact == impact)
    check("\(kind.rawValue) 归属能力 = \(cap)", kind.capability.rawValue == cap)
}

// MARK: - v4.0.x 扩容动作的协议解析

let rem = AgentAction.parse(json: """
{"action":"reminder.create","params":{"title":"交水费","due":"2026-09-28T09:00:00+08:00","notes":"户号 12345"},"summary":"新建提醒：交水费"}
""")
check("动作解析出 reminder.create", rem?.kind == .reminderCreate)
check("提醒标题可读", rem?.param("title") == "交水费")
check("提醒到点时间是 ISO8601", AgentAction.isoDate(rem?.param("due") ?? "") != nil)
check("提醒 notes 可读", rem?.param("notes") == "户号 12345")

let clip = AgentAction.parse(json: """
{"action":"clipboard.write","params":{"text":"hello 轻聊"},"summary":"复制到剪贴板"}
""")
check("动作解析出 clipboard.write", clip?.kind == .clipboardWrite)
check("剪贴板内容可读", clip?.param("text") == "hello 轻聊")

let file = AgentAction.parse(json: """
{"action":"file.write","params":{"path":"notes/todo.txt","content":"买牛奶\\n交房租"},"summary":"写入文件"}
""")
check("动作解析出 file.write", file?.kind == .fileWrite)
check("文件名可读", file?.param("path") == "notes/todo.txt")
check("文件内容多行保留", file?.param("content") == "买牛奶\n交房租")


// MARK: - 邮件代发（v4.0.x）的协议解析

// ⚠️ 正文是多行：JSON 里的换行必须写成 \\n（Swift 多行字符串会把 \n 先变成真实换行 → JSON 直接非法，解析整段退化成原文）。
let mailJSON = """
{"action":"mail.send","params":{"to":"someone@example.com","subject":"本周进展","body":"1. 联调完成\\n2. 改图纸","account":"acc-eeb8da14"},"summary":"发本周进展给自己"}
"""
let mail = AgentAction.parse(json: mailJSON)
check("动作解析出 mail.send", mail?.kind == .mailSend)
check("收件人可读", mail?.param("to") == "someone@example.com")
check("主题可读", mail?.param("subject") == "本周进展")
check("正文多行保留", mail?.param("body") == "1. 联调完成\n2. 改图纸")
check("account 可读（多账号时指定用哪个发）", mail?.param("account") == "acc-eeb8da14")
check("mail.send 是写动作（必须点胶囊确认，不能自动发）", AgentAction.Kind.mailSend.impact == .write)
check("mail.send 归属邮件能力", AgentAction.Kind.mailSend.capability.rawValue == "mail")
check("mail.send 的标签给用户看得懂", AgentAction.Kind.mailSend.capabilityLabel == "发送邮件")

// 只读动作必须落在 .read（卡片据此免确认自动跑；判错 = 该跑的跑不起来 / 该确认的不确认）
check("reminder.list 是只读", AgentAction.Kind.reminderList.impact == .read)
check("location.current 是只读", AgentAction.Kind.locationCurrent.impact == .read)
check("clipboard.read 是只读", AgentAction.Kind.clipboardRead.impact == .read)
check("file.read 是只读", AgentAction.Kind.fileRead.impact == .read)
check("contacts.search 是只读", AgentAction.Kind.contactsSearch.impact == .read)

// 动作名唯一：同名 = 后端发下来会被解析成先注册的那个，静默走错分支
// v3.9.110 审查修：改用 allCases，别再手写列表——扩容时手写那份必然漏（本轮就漏了 mailSend，
// 「动作名互不重复」这条负断言的覆盖面比真值表少一项，是典型的假绿夹具）。
let allKinds: [AgentAction.Kind] = AgentAction.Kind.allCases
check("动作总数 22（v4.0.7 加 goal.create/goal.step_done）", allKinds.count == 22)
// MARK: - v4.0.7 长期目标动作
let goalActions: [AgentAction.Kind] = [.goalCreate, .goalStepDone]
check("goal 动作数 2", goalActions.count == 2)
for k in goalActions {
    check("\(k.rawValue) 归类为写操作", k.impact == .write)
    check("\(k.rawValue) 归 reminders 能力", k.capability == .reminders)
    check("\(k.rawValue) 标签非空", !k.capabilityLabel.isEmpty)
}
check("goal.create 是写（必须点确认）", AgentAction.Kind.goalCreate.impact == .write)
check("goal.step_done 是写", AgentAction.Kind.goalStepDone.impact == .write)
if let a = AgentAction.parse(json: #"{"action":"goal.create","params":{"title":"秋季新品","steps":"[\"定产品线\",\"备货5000\"]"},"summary":"建长期目标"}"#) {
    check("解析 goal.create", a.kind == .goalCreate)
    check("解析出标题", a.param("title") == "秋季新品")
    check("解析出步骤 JSON", a.param("steps")?.contains("备货5000") == true)
} else { check("解析 goal.create", false) }
check("未知 goal.x 动作退化为 nil（不猜不执行）",
      AgentAction.parse(json: #"{"action":"goal.explode"}"#) == nil)

check("动作名互不重复", Set(allKinds.map(\.rawValue)).count == allKinds.count)

// MARK: - 参数类型容错（后端可能传数字/布尔）

let mixed = AgentAction.parse(json: """
{"action":"notify","params":{"delay": 5, "urgent": true, "body":"记得吃药", "skip":"x"}}
""")
check("数字参数转字符串", mixed?.param("delay") == "5")
check("布尔参数转字符串", mixed?.param("urgent") == "true")
check("字符串参数正常", mixed?.param("body") == "记得吃药")
// 4 个标量全收下：delay(数字)/urgent(布尔)/body(字符串)/skip(字符串)。
// ⚠️ 别在这里写"应忽略未知键" —— 协议刻意宽松（后端加字段不必改 App），键多于预期是正常的。
check("四个标量参数全部保留", mixed?.params.count == 4)

// MARK: - ISO8601 容错

check("带时区 ISO8601 可解析",
      AgentAction.isoDate("2026-09-28T15:00:00+08:00") != nil)
check("带小数秒 ISO8601 可解析",
      AgentAction.isoDate("2026-09-28T15:00:00.123Z") != nil)
check("非 ISO 串返回 nil", AgentAction.isoDate("明天下午三点") == nil)
check("空串返回 nil", AgentAction.isoDate("") == nil)

// MARK: - 门控

check("含 ql-action 标记被识别", AgentActionParser.containsActionMarker("a ```ql-action b"))
check("无标记不被误判", !AgentActionParser.containsActionMarker("普通文字"))
check("ql_action 宽容写法被识别", AgentActionParser.isActionFence("ql_action"))
check("ql-card 不被误认为动作", !AgentActionParser.isActionFence("ql-card"))

// MARK: - 结果

if failures == 0 {
    print("\n全部通过 ✅")
} else {
    print("\n失败 \(failures) 条 ❌")
    exit(1)
}
    }
}
