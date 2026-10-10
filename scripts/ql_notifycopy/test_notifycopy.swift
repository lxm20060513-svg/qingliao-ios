import Foundation

// 轻聊通知文案规范化 · **行为**真值表（v4.0.91）
// ============================================================
// 与生产代码**一起编译**（见 check_swift.sh）：这里调的就是 QingliaoNotifyCopy 的真身，
// 不是抄一份逻辑 —— 抄一份的话两边会各改各的，最后测的不是发版的那份。
//
// 为什么值得钉：这一层是「iOS 快捷指令按通知标题筛类别」的**契约**。
// 前缀改一个字（比如「轻聊·提醒」写成「轻聊 · 提醒」），用户在自动化里写的
// 「标题包含『轻聊·提醒』」就静默失效 —— 界面上看不出任何异常，只有用户发现"自动化不灵了"。
// 所以前缀、副标题上限、空值语义、回复预览截断全部钉死。

var pass = 0
var fail = 0

// ⚠️ Swift 6 模式下顶层代码是 @MainActor 隔离的，而顶层全局变量也是 → 非隔离的 ck() 改不了它
// （"main actor-isolated var 'pass' can not be mutated from a nonisolated context"，
//   本地实测踩到）。所以断言函数显式标 @MainActor —— 别改回非隔离再加 nonisolated(unsafe)。
@MainActor
func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

@MainActor
func ckEq(_ name: String, _ got: String, _ want: String) {
    ck(name, got == want, "实得「\(got)」期望「\(want)」")
}

// MARK: - 1. 前缀契约（改这里 = 改用户自动化的条件）

ckEq("reminder 前缀", QingliaoNotifyKind.reminder.title, "【轻聊·提醒】")
ckEq("reply 前缀", QingliaoNotifyKind.reply.title, "【轻聊·回复】")
ckEq("proactive 前缀", QingliaoNotifyKind.proactive.title, "【轻聊·主动】")
ckEq("confirm 前缀", QingliaoNotifyKind.confirm.title, "【轻聊·待确认】")
ckEq("inbox 前缀", QingliaoNotifyKind.inbox.title, "【轻聊·投递】")
ckEq("alert 前缀", QingliaoNotifyKind.alert.title, "【轻聊·告警】")

let allPrefixes = QingliaoNotifyKind.allCases.map { $0.prefix }
ck("前缀互不重复", Set(allPrefixes).count == QingliaoNotifyKind.allCases.count,
   "有重复：\(allPrefixes)")
ck("前缀都带「轻聊·」标识", allPrefixes.allSatisfy { $0.hasPrefix("轻聊·") })
ck("标题都是全角方括号包起来的", QingliaoNotifyKind.allCases.allSatisfy {
    $0.title.hasPrefix("【") && $0.title.hasSuffix("】") })
// 前缀里不许有空格：用户在「包含」条件里手打时最容易漏空格 → 干脆不出现空格
ck("前缀不含空格", allPrefixes.allSatisfy { !$0.contains(" ") && !$0.contains("\u{3000}") })
// 旧写法（"轻聊 · 推送" 这种带空格中点的）必须彻底消失，否则自动化条件两套写法并存
ck("前缀没有「·」两侧空格的老写法", allPrefixes.allSatisfy { !$0.contains(" · ") })

// MARK: - 2. 后端 task_type → 类别（唯一映射点）

ckEq("task_type reply", QingliaoNotifyKind.fromTaskType("reply").prefix, "轻聊·回复")
ckEq("task_type agent", QingliaoNotifyKind.fromTaskType("agent").prefix, "轻聊·主动")
ckEq("task_type question", QingliaoNotifyKind.fromTaskType("question").prefix, "轻聊·待确认")
ckEq("task_type cron", QingliaoNotifyKind.fromTaskType("cron").prefix, "轻聊·投递")
ckEq("task_type system", QingliaoNotifyKind.fromTaskType("system").prefix, "轻聊·告警")
// progress 不弹通知，但要落一个类别（新增类型时别崩）
ckEq("task_type progress 兜底", QingliaoNotifyKind.fromTaskType("progress").prefix, "轻聊·回复")
ckEq("空 task_type（老后端）兜底", QingliaoNotifyKind.fromTaskType("").prefix, "轻聊·回复")
ckEq("未知 task_type 兜底", QingliaoNotifyKind.fromTaskType("brand_new_thing").prefix, "轻聊·回复")

// MARK: - 3. 副标题：关键值，空则 nil（不能塞空串）

ckEq("副标题去空白", QingliaoNotifyCopy.subtitle("  每天 07:30 ") ?? "nil", "每天 07:30")
ck("nil → nil", QingliaoNotifyCopy.subtitle(nil) == nil)
ck("纯空白 → nil", QingliaoNotifyCopy.subtitle("   \n  ") == nil)
ck("全角空格 → nil", QingliaoNotifyCopy.subtitle("\u{3000}\u{3000}") == nil)

let longDetail = String(repeating: "字", count: 40)
let clampedDetail = QingliaoNotifyCopy.subtitle(longDetail) ?? ""
ckEq("副标题截断到 24 字 + 省略号", "\(clampedDetail.count)", "25")
ck("副标题截断尾部是省略号", clampedDetail.hasSuffix("…"))
ckEq("副标题恰好 24 字不截", QingliaoNotifyCopy.subtitle(String(repeating: "字", count: 24))?.count.description ?? "nil", "24")
ck("副标题换行被拍平", QingliaoNotifyCopy.subtitle("第一行\n第二行") == "第一行 第二行")

// MARK: - 4. 正文：只 trim，**不**折叠换行、**不**截断（多行投递靠 iOS 自己排版）

ckEq("正文 trim 两端空白", QingliaoNotifyCopy.body("  \n 内容 \n "), "内容")
ckEq("正文保留内部换行（多行投递不塌成一行）", QingliaoNotifyCopy.body("第一行\n第二行"), "第一行\n第二行")
ckEq("正文不截断（长文照给，iOS 自己折行）",
     "\(QingliaoNotifyCopy.body(String(repeating: "字", count: 500)).count)", "500")
ckEq("正文空 → 兜底文案", QingliaoNotifyCopy.body("   "), "点击查看详情")
ckEq("正文空 + 自定义兜底", QingliaoNotifyCopy.body("", fallback: "看看轻聊"), "看看轻聊")

// MARK: - 5. AI 回复预览（原 NotificationHelper.notifyReply 的首句逻辑）

ckEq("预览取第一非空行", QingliaoNotifyCopy.replyPreview("\n\n  第一句要不要再说  \n第二句"), "第一句要不要再说")
ckEq("预览剥 markdown 记号", QingliaoNotifyCopy.replyPreview("### 结论：可以\n详情…"), "结论：可以")
ckEq("预览剥代码围栏与星号", QingliaoNotifyCopy.replyPreview("```\n**重点**在这\n```"), "重点在这")
ckEq("预览空回复 → 空串", QingliaoNotifyCopy.replyPreview("   \n  "), "")
ckEq("预览截断到 50 字 + 省略号", "\(QingliaoNotifyCopy.replyPreview(String(repeating: "字", count: 80)).count)", "51")
ckEq("预览 50 字不截", "\(QingliaoNotifyCopy.replyPreview(String(repeating: "字", count: 50)).count)", "50")
// 纯函数语义：预览是单行展示，换行必须被压掉（否则通知里出现半行）
ck("预览单行（无换行）", !QingliaoNotifyCopy.replyPreview("甲\n乙").contains("\n"))

// MARK: - 6. compose 三件套：调用点只接一个元组，标题不许被别的内容污染

let trio = QingliaoNotifyCopy.compose(.reminder, detail: "每天 07:30", body: "该吃药了")
ckEq("compose 标题", trio.title, "【轻聊·提醒】")
ckEq("compose 副标题", trio.subtitle ?? "nil", "每天 07:30")
ckEq("compose 正文", trio.body, "该吃药了")
ck("compose 标题不含副标题内容（自动化按前缀判类别才稳）", !trio.title.contains("07:30"))
let trioNoDetail = QingliaoNotifyCopy.compose(.inbox, body: "周报出来了")
ck("compose 无副标题 → nil（不设空的 subtitle）", trioNoDetail.subtitle == nil)

// MARK: - 7. clamp 边界（UTF-16 与字符数不一致的坑：emoji/中文混排）

ckEq("clamp 不超长原样返回", QingliaoNotifyCopy.clamp("abc", 5), "abc")
ckEq("clamp 截断补省略号", QingliaoNotifyCopy.clamp("abcdef", 4), "abcd…")
ckEq("clamp 0 → 空", QingliaoNotifyCopy.clamp("abc", 0), "")
ckEq("clamp 按字符数不是字节数（emoji 算一个）", "\(QingliaoNotifyCopy.clamp("😀😀😀😀😀", 3).count)", "4")

print("")
if fail == 0 { print("通过 \(pass) 项 / 失败 0 项") }
else { print("通过 \(pass) 项，失败 \(fail) 项") }
exit(fail == 0 ? 0 : 1)
