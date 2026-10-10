import Foundation

// iOS 27 快捷指令联动动作 · **源码契约**真值表（v4.0.91）
// ============================================================
// 为什么这些断言只能在源码层面查：AppIntents / SwiftUI 在本机（Linux + swiftc，无 iOS SDK）
// **编不了**，本地能做的只有 `swiftc -parse`（语法）。所以把「能不能被真机认出来」的
// 硬约束逐条钉在源码文本上 —— 少一条，症状是「Archive 过了、真机 Siri 里根本看不见这个动作」，
// 而那要等 20 分钟一轮 CI + 装包才发现。
//
// 三类断言：
//   ① 实体（AppEntity）**完整性** —— 少一个 defaultQuery / 少了 EntityQuery 方法，实体会静默不可用
//   ② 三条隔离纪律 —— 查询不触网、状态访问走 MainActor.run、不占 Siri 短语名额
//   ③ 划词动作的输入形态 —— 参数必须是 String（系统「获取所选文字」只能喂文本）

var pass = 0
var fail = 0

// 注：本表由 `ql.py test` 以**单文件 / 默认语言模式**编译（顶层代码非隔离），
// 所以 ck() 不能标 @MainActor —— 标了会报「call to main actor-isolated global function
// in a synchronous nonisolated context」。要 Swift 6 严格并发口径的表走 check_swift.sh 的 run_unit6。
func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}

let ent = read("qingliao/Core/QingliaoEntities.swift")
let txt = read("qingliao/Core/QingliaoTextIntents.swift")
let intents = read("qingliao/Core/AppIntents.swift")
let proj = read("project.yml")

// MARK: - 0. 前提：文件真的读到了（否则整张表会「全绿」地假过）

ck("QingliaoEntities.swift 读到内容", ent.count > 2000, "实得 \(ent.count) 字符")
ck("QingliaoTextIntents.swift 读到内容", txt.count > 1000, "实得 \(txt.count) 字符")
ck("project.yml 读到内容", proj.contains("qingliao/Core"))

// MARK: - 1. 实体完整性（缺一个就没法在快捷指令里被选中/被模型读到）

for e in ["TodoEntity", "MemoEntity", "GoalEntity"] {
    ck("\(e) 存在且是 AppEntity", ent.contains("struct \(e): AppEntity"))
    ck("\(e) 有 typeDisplayRepresentation（Siri 里显示什么）", ent.contains("TypeDisplayRepresentation(name:"))
}
ck("三个实体各自声明 defaultQuery", ent.components(separatedBy: "static var defaultQuery = ").count - 1 == 3,
   "实得 \(ent.components(separatedBy: "static var defaultQuery = ").count - 1) 处")
for q in ["TodoEntityQuery", "MemoEntityQuery", "GoalEntityQuery"] {
    ck("\(q) 存在", ent.contains("struct \(q): EntityQuery"))
    ck("\(q) 支持按名搜索（EntityStringQuery）", ent.contains("struct \(q): EntityQuery, EntityStringQuery, EnumerableEntityQuery"))
    ck("\(q) 实现 entities(for:)（实体回填，缺了 Siri 拿不到具体对象）",
       ent.contains("func entities(for identifiers: [String])"))
    ck("\(q) 实现 allEntities()（快捷指令能生成「查找」动作）",
       ent.contains("func allEntities() async throws ->"))
}
// @Property 是「端侧模型能读到字段」的唯一途径 —— 这次改动的全部价值就在这几个注解上
ck("@Property 数量 ≥ 12（三个实体加起来，模型可读字段）",
   ent.components(separatedBy: "@Property(").count - 1 >= 12,
   "实得 \(ent.components(separatedBy: "@Property(").count - 1)")
for field in ["内容", "已完成", "来源", "步骤", "已完成步数", "最近一次推进"] {
    ck("实体字段「\(field)」暴露给模型", ent.contains("@Property(title: \"\(field)\")"))
}

// MARK: - 2. 三条隔离纪律

// ②-1 查询不触网：无界面进程里 fetch 会把 Siri 卡到超时（120s）
//     ⚠️ 只约束**查询结构体**内部：动作（perform）里挂 auth 是本地读配置，不算触网。
//     （第一版把整文件一刀切，被 `store.attach(auth:)` 误报 —— 断言要打到该管的范围上。）
func slice(_ src: String, from: String, to: String) -> String {
    guard let a = src.range(of: from) else { return "" }
    let rest = src[a.lowerBound...]
    guard let b = rest.range(of: to) else { return String(rest) }
    return String(rest[..<b.lowerBound])
}
for q in ["TodoEntityQuery", "MemoEntityQuery", "GoalEntityQuery"] {
    let body = slice(ent, from: "struct \(q): EntityQuery", to: "\n// MARK")
    ck("\(q) 结构体确实切出来了（空切片会让下面几条假绿）", body.count > 200, "实得 \(body.count) 字符")
    for bad in ["URLSession", "URLRequest", "QingliaoIntentClient", "oneShot(", "inboxTexts()"] {
        ck("\(q) 不触网（无 \(bad)）", !body.contains(bad))
    }
}
ck("实体文件整体没有 URLSession（查询层不许联网）", !ent.contains("URLSession"))
// ②-2 store 是 @MainActor，查询不是 → 必须 await MainActor.run 取副本
let runs = ent.components(separatedBy: "await MainActor.run").count - 1
ck("查询走 await MainActor.run（store 是 @MainActor，查询不是）", runs >= 3, "实得 \(runs) 处")
ck("查询方法没有直接标 @MainActor（会与协议的非隔离要求打架）",
   !ent.contains("@MainActor\n    func entities") && !ent.contains("@MainActor func entities"))
ck("没有把 store 实例带出 MainActor 闭包（只取值副本）",
   !ent.contains("-> TodoStore") && !ent.contains("-> MemoStore") && !ent.contains("-> GoalStore"))

// ②-3 不占 Siri 短语名额：本 App 已用 9/10
let phrases = intents.components(separatedBy: "AppShortcut(").count - 1
ck("App Shortcuts 仍是 9 条（上限 10，加实体不需要动它）", phrases == 9, "实得 \(phrases)")
for added in ["AskAboutTextIntent", "ListTodosIntent", "ToggleTodoIntent", "SearchMemosIntent", "ListGoalsIntent"] {
    ck("新动作 \(added) 没占用 Siri 短语（出现在 AppShortcut 里就是越界）",
       !intents.contains("AppShortcut(\(added)"))
}

// MARK: - 3. 动作本身（标题/描述/参数）

for a in ["ListTodosIntent", "ToggleTodoIntent", "SearchMemosIntent", "ListGoalsIntent"] {
    ck("动作 \(a) 存在", ent.contains("struct \(a): AppIntent"))
    ck("动作 \(a) 有中文标题", ent.contains("struct \(a): AppIntent"))
}
ck("看待办返回结构化实体（ReturnsValue<[TodoEntity]>）", ent.contains("ReturnsValue<[TodoEntity]>"))
ck("搜备忘返回结构化实体（ReturnsValue<[MemoEntity]>）", ent.contains("ReturnsValue<[MemoEntity]>"))
ck("看目标返回结构化实体（ReturnsValue<[GoalEntity]>）", ent.contains("ReturnsValue<[GoalEntity]>"))
ck("勾选待办是唯一写动作（其余只读）",
   ent.components(separatedBy: "store.toggleDone(item)").count - 1 == 1)
// 写 NAS 前挂最新 auth（与 AddMemoIntent 同规矩；没挂的话只落本地，用户以为记上了）
ck("勾选待办前挂最新 auth", ent.contains("store.attach(auth: auth)"))
// 覆盖检查：intent 的 title 与 description 都要有（Siri/快捷指令里就是靠它们认）
ck("每个新动作都有 description", ent.components(separatedBy: "IntentDescription(").count - 1 >= 4)

// MARK: - 4. 划词动作（特性 5）

ck("AskAboutTextIntent 存在", txt.contains("struct AskAboutTextIntent: AppIntent"))
ck("文字参数是 String（只能文本——「获取所选文字」喂不了别的类型）",
   txt.contains("@Parameter(title: \"文字\"") && txt.contains("var text: String"))
ck("问题参数可选（留空按「这段文字是什么意思」）", txt.contains("var question: String?"))
ck("返回值是回答正文（供下一步接「显示结果/记到备忘」）", txt.contains("ReturnsValue<String>"))
ck("提示词带「文字」与「问题」两段（缺上下文模型会答飞）",
   txt.contains("【文字】") && txt.contains("【我的问题】"))
ck("划词文本有长度上限（防把主模型上下文挤爆）", txt.contains("static let textLimit = 4000")
   && txt.contains(".prefix(textLimit)"))
ck("空文本会抛错并给出可操作的提示（不是静默返回空）",
   txt.contains("throw QingliaoIntentError(message:") && txt.contains("获取所选文字"))
ck("提示词组装是纯函数（prompt 标注 static，可被真值表直接调）",
   txt.contains("static func prompt(text: String, question: String, style: AskStyle) -> String"))
// 复用已有风格枚举，别另起一套（两套「一句话/详细」会漂移）
ck("回答风格复用现有 AskStyle", txt.contains("var style: AskStyle?") && !txt.contains("enum AskStyle"))
// 来源参数接进备忘
ck("AddMemoIntent 新增「来源」参数（划词带出处）", intents.contains("@Parameter(title: \"来源\"")
   && intents.contains("var source: String?"))
ck("来源拼进正文而不是塞 MemoItem.source（sourceLabel 认不出的值会渲染成「手记」）",
   intents.contains("raw + \"\\n\\n—— 来自 \\(src)\""))
ck("来源为空时正文不变（不留一行空「—— 来自」）",
   intents.contains("let src = (source ?? \"\").trimmingCharacters(in: .whitespacesAndNewlines)"))

// MARK: - 5. 跨文件复用（别各自抄一份对话框构造）

ck("qlDialog 已放开到模块内（两个新文件都要用）", intents.contains("\nfunc qlDialog(_ text: String)")
   && !intents.contains("private func qlDialog"))
ck("新文件不再自行构造 IntentDialog（复用 qlDialog）",
   !txt.contains("IntentDialog(") && !ent.contains("IntentDialog("))

// MARK: - 6. 新文件会被编进主 App（否则一切白搭）

ck("project.yml 主 target 以目录为源（qingliao/ 下的新文件自动进编译）", proj.contains("- qingliao\n"))

print("")
if fail == 0 { print("通过 \(pass) 项 / 失败 0 项") }
else { print("通过 \(pass) 项，失败 \(fail) 项") }
exit(fail == 0 ? 0 : 1)
