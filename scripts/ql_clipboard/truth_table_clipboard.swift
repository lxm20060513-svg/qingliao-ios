import Foundation

// 轻聊剪贴板历史 · 源码契约真值表（v4.0.104 待做池 #11）
// 与 scripts/ql_clipboard/test_clipboard.swift 分工：那边真跑 ClipboardHistoryStore 的行为
// （空串/trim/去重/上限/超长/清空/删单条/开关/坏条容错/重载），这边钉**接线形态**——
// 键单一真源 + 唯一写入口 + 只在用户动作时读剪贴板 + 入待办走 RecordStore + 设置页入口/挂 sheet + 上限常量。
//
// 为什么必须钉（全是静默退化）：
//   ① 渲染期读剪贴板 → 每次开首页弹一次系统「允许粘贴」提示（用户会疯）；而把某处读挪进 body 编译照过。
//   ② 视图自己拼键名 / 自己写 UserDefaults → 绕过唯一写入口，两处真源必然漂移。
//   ③ 入待办自己拼 UserDefaults（不走 RecordStore）→ 与账本/生活页口径分叉，同一件事四处实现。
//   ④ 上限常量改名/改值 → 容量兜底失效却无人察觉。
//   ⑤ 设置页入口或 .sheet 被删 → 功能静默消失（编译过、点不开）。
//
// 片段连续性写法：closureBody / onlyWhitespaceBetween / orderedPair；每个切片都先断言**非空哨兵**，
// 防「锚点变了 → 读空串 → 下面断言在空真上全绿」。
// ⚠️ 本表编译成独立可执行文件（非 main.swift）→ 顶层非 main actor，用 nonisolated(unsafe) 兜全局计数。
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 只留代码行（注释里提到 `UIPasteboard` 是说明，不该被计数）
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.hasPrefix("//") && !t.hasPrefix("*") }
        .joined(separator: "\n")
}
func hits(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }

/// 取某声明后的 `{ … }` 花括号体（跳过注释/字符串里的花括号）。取不到返回 ""（调用方必须用非空哨兵兜）。
func closureBody(_ src: String, _ decl: String) -> String {
    guard let r = src.range(of: decl) else { return "" }
    let after = src[r.upperBound...]
    guard let open = after.firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    var inStr = false
    var esc = false
    var out = ""
    while i < src.endIndex {
        let ch = src[i]
        if inStr {
            if esc { esc = false }
            else if ch == "\\" { esc = true }
            else if ch == "\"" { inStr = false }
            out.append(ch)
        } else if ch == "\"" {
            inStr = true; out.append(ch)
        } else if ch == "/" , src.index(after: i) < src.endIndex, src[src.index(after: i)] == "/" {
            // 行注释：跳到行尾
            while i < src.endIndex, src[i] != "\n" { i = src.index(after: i) }
            continue
        } else if ch == "{" {
            depth += 1; if depth == 1 { i = src.index(after: i); continue }
            out.append(ch)
        } else if ch == "}" {
            depth -= 1
            if depth == 0 { return out }
            out.append(ch)
        } else {
            out.append(ch)
        }
        i = src.index(after: i)
    }
    return out
}

/// a 与 b 之间只有空白/逗号/换行（片段连续性：两处确实紧邻，不是隔了半个文件）
func onlyWhitespaceBetween(_ src: String, _ a: String, _ b: String) -> Bool {
    guard let ra = src.range(of: a), let rb = src.range(of: b, range: ra.upperBound..<src.endIndex) else { return false }
    let between = src[ra.upperBound..<rb.lowerBound]
    return between.allSatisfy { $0.isWhitespace || $0 == "," || $0 == "\n" }
}

/// a 在 b 之前（同为 -1 时判 false）
func orderedPair(_ src: String, _ a: String, _ b: String) -> Bool {
    guard let ra = src.range(of: a), let rb = src.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// ── 读取面 ──────────────────────────────────────────────────────
let storeSrc = codeOnly(read("qingliao/Core/ClipboardHistoryStore.swift"))
let modelsSrc = read("qingliao/Core/Models.swift")
let sheetSrc = codeOnly(read("qingliao/Features/Settings/ClipboardHistorySheet.swift"))
/// 原文（含字符串字面量）：下面的「文案不得谎称」断言要看真字面量，故不能走 codeOnly。
let sheetRaw = read("qingliao/Features/Settings/ClipboardHistorySheet.swift")
let homeSrc = codeOnly(read("qingliao/Features/HomeCards.swift"))
let coreSrc = codeOnly(read("qingliao/Features/Settings/SettingsCore.swift"))
let recordKitSrc = codeOnly(read("qingliao/Core/RecordKit.swift"))
let testSrc = read("scripts/ql_clipboard/test_clipboard.swift")

// ── A. 源可读 + 切片哨兵 ────────────────────────────────────────
ck("ClipboardHistoryStore.swift 源可读", !storeSrc.isEmpty)
ck("ClipboardHistorySheet.swift 源可读", !sheetSrc.isEmpty)
ck("HomeCards.swift 源可读", !homeSrc.isEmpty)
ck("SettingsCore.swift 源可读", !coreSrc.isEmpty)
let tapBody = closureBody(homeSrc, "private func tapClipboard()")
ck("HomeCards tapClipboard 切片取到（空了下面两条等于空真）", !tapBody.isEmpty && tapBody.count < 800)
let readBody = closureBody(sheetSrc, "private func readClipboard()")
ck("Sheet readClipboard 切片取到", !readBody.isEmpty && readBody.count < 1200)
let sheetFormBody = closureBody(sheetSrc, "var body: some View")
ck("Sheet body 切片取到", !sheetFormBody.isEmpty && sheetFormBody.count > 400)

// ── B. 键单一真源 ───────────────────────────────────────────────
let keyLine = #"static let clipboardHistory = "qingliao_clipboard_history""#
let keyEnabledLine = #"static let clipboardHistoryEnabled = "qingliao_clipboard_history_enabled""#
ck("Models.swift 声明唯一历史键 UserDefaultsKey.clipboardHistory", modelsSrc.contains(keyLine))
ck("Models.swift 声明开关键 UserDefaultsKey.clipboardHistoryEnabled", modelsSrc.contains(keyEnabledLine))
ck("测试替身与真值同字面量（防两处漂移）", testSrc.contains(keyLine) && testSrc.contains(keyEnabledLine))

var appFiles: [String] = []
if let en = FileManager.default.enumerator(atPath: repo + "/qingliao") {
    while let f = en.nextObject() as? String { if f.hasSuffix(".swift") { appFiles.append(f) } }
}
appFiles.sort()
let histLitUsers = appFiles.filter { read("qingliao/" + $0).contains(#""qingliao_clipboard_history""#) }
let enLitUsers = appFiles.filter { read("qingliao/" + $0).contains(#""qingliao_clipboard_history_enabled""#) }
ck("历史键字面量在 App 源里恰好 1 处（实得 \(histLitUsers)）", histLitUsers == ["Core/Models.swift"])
ck("开关键字面量在 App 源里恰好 1 处（实得 \(enLitUsers)）", enLitUsers == ["Core/Models.swift"])
// 注意：钉的是**键符号** `UserDefaultsKey.clipboardHistory`，不是标识符 `clipboardHistory` ——
// 后者是合法公共词（设置页 flag `showClipboardHistory`、搜索路由 route "clipboardHistory" 都得用它），
// 之前按窄词匹配会把「加了个设置入口」误判成「键被外泄」（v4.0.104 实测踩到）。
let symbolUsers = appFiles.filter { read("qingliao/" + $0).contains("UserDefaultsKey.clipboardHistory") }
ck("历史键符号只在 Store 里被读写（实得 \(symbolUsers)）",
   symbolUsers == ["Core/ClipboardHistoryStore.swift"])

// ── C. 唯一写入口 + 持久化格式（数组+下标，不是嵌套字典）──────────
ck("唯一表写盘点：Store 里 defaults.set(entries.map… 恰好 1 处（写历史表只此一入口）",
   hits(storeSrc, "defaults.set(entries.map") == 1)
ck("唯一读盘点：defaults.array(forKey: UserDefaultsKey.clipboardHistory) 恰好 1 处",
   hits(storeSrc, "defaults.array(forKey: UserDefaultsKey.clipboardHistory)") == 1)
ck("开关写的是**另一个**键（clipboardHistoryEnabled），不与历史表混用",
   hits(storeSrc, "defaults.set(newValue, forKey: UserDefaultsKey.clipboardHistoryEnabled)") == 1)
ck("持久化 payload 构造只此一处（[$0.text, $0.at, $0.source, $0.id]）",
   hits(storeSrc, "[$0.text, $0.at, $0.source, $0.id]") == 1)
ck("🚨 持久化必须用数组+下标，不得用嵌套字典（Linux swift-corelibs-foundation 读回是 [AnyHashable: Any]）",
   !storeSrc.contains("as? [String: Any]") && !storeSrc.contains("dictionary(forKey:"))
ck("单条结构 = [正文, 时间戳, 来源, id]（4 项数组）",
   storeSrc.contains("entries.map { [$0.text, $0.at, $0.source, $0.id] }") && storeSrc.contains("arr.count == 4"))
ck("坏条只跳过不整表丢弃守卫在场", storeSrc.contains("else { continue }"))
ck("Store 是纯 Foundation：不 import UIKit、不碰 UIPasteboard（读剪贴板只归调用方的用户动作）",
   !storeSrc.contains("import UIKit") && !storeSrc.contains("UIPasteboard"))
ck("容量上限常量逐字 = 100", storeSrc.contains("static let maxEntries = 100"))
ck("视图层不许直接引用历史键（UserDefaultsKey.clipboardHistory）", !sheetSrc.contains("UserDefaultsKey.clipboardHistory"))
ck("视图层不许出现历史键字面量", !sheetSrc.contains(#""qingliao_clipboard_history""#))
ck("Sheet 不自己写 UserDefaults（落库只走 Store / RecordStore）", !sheetSrc.contains("UserDefaults"))

// ── D. 读剪贴板只在「用户动作函数体内」，绝不在 body/渲染期 ──────────
ck("首页卡：读 UIPasteboard 只在 tapClipboard 函数体内",
   tapBody.contains("UIPasteboard.general.string") && hits(homeSrc, "UIPasteboard.general.string") == 1)
ck("🚨 首页卡反向：tapClipboard 的读不在任何 body 里（HomeCards body 不读剪贴板）",
   !closureBody(homeSrc, "var body: some View").contains("UIPasteboard.general.string"))
ck("设置页：读 UIPasteboard 只在 readClipboard 函数体内（用户点「读取当前剪贴板」那一刻）",
   readBody.contains("UIPasteboard.general.string?") && hits(sheetSrc, "UIPasteboard.general.string?") == 1)
ck("🚨 设置页反向：Sheet 的 body/渲染期不得读剪贴板（否则每次进页面弹系统「粘贴」提示）",
   !sheetFormBody.contains("UIPasteboard.general.string"))
ck("读剪贴板处不在 onAppear/onChange 等自动触发点（必须由用户点击触发）",
   !readBody.contains("onAppear") && !sheetFormBody.contains("UIPasteboard"))
ck("读按钮接线：Button 里调 readClipboard()", sheetSrc.contains("readClipboard()"))

// ── E. 首页卡顺手入库（零额外系统提示那条路径）──────────────────
ck("首页卡 tapClipboard 调 Store.record（用户主动点那一刻）",
   tapBody.contains("ClipboardHistoryStore.shared.record(text, source: \"首页卡\")"))
ck("首页卡：先 record 再 onAsk（入库与发给 AI 同一段文本，顺序无关正确性但钉住意图）",
   orderedPair(tapBody, "ClipboardHistoryStore.shared.record(text, source: \"首页卡\")", "onAsk("))
ck("首页卡：record 不新增第二次读取（tapClipboard 里 UIPasteboard 读只 1 次）",
   hits(tapBody, "UIPasteboard.general.string") == 1)

// ── F. 入待办走 RecordStore 公开入口 ───────────────────────────
ck("Sheet「入待办」走 RecordStore.shared.add(（不自己拼 UserDefaults）",
   sheetSrc.contains("RecordStore.shared.add("))
ck("入待办 kind = \"todo\"（RecordKit 无 todoKind 常量，现有 kind 只有 amount/meter/note/income）",
   sheetSrc.contains("kind: \"todo\""))
ck("入待办 source = \"clipboard\"", sheetSrc.contains("source: \"clipboard\""))
ck("RecordKit.sourceLabel 登记了 clipboard → 剪贴板",
   recordKitSrc.contains("case \"clipboard\": return \"剪贴板\""))

// ── G. 清空二次确认沿用既有口径（锚定浮层，不用 confirmationDialog）──
ck("清空走 AnchorMenuOverlay 锚定浮层（v4.0.102 全仓口径）", sheetSrc.contains("AnchorMenuOverlay("))
ck("🚨 清空不用 confirmationDialog（iPhone 上固定从底部升起，锚不到触发按钮）",
   !sheetSrc.contains("confirmationDialog"))

// ── H. 设置页入口 + sheet 已挂 ─────────────────────────────────
// v4.0.x（2026-10-14 用户口径「设置里面的剪切板历史可以删掉了」）：设置页那行**整体撤下**，
// 断言反向钉死——防有人「顺手」把入口加回设置页（功能本体仍在聊天页附件面板，见下一条）。
ck("🚨 设置页不得再有剪贴板历史入口（用户已撤，别加回来）",
   !coreSrc.contains("showClipboardHistory") && !coreSrc.contains("剪贴板历史"))
ck("🚨 设置页搜索路由也不得再留 clipboardHistory（留了 = 搜出来点了没反应）",
   !coreSrc.contains("case \"clipboardHistory\""))
// 功能本体（唯一视图）：聊天页附件面板第五格仍复用同一个 sheet
let chatSrc = read("qingliao/Features/Chat/ChatView.swift")
ck("🚨 功能本体还在：聊天页仍挂 ClipboardHistorySheet()（设置页撤了≠功能删了）",
   chatSrc.contains("ClipboardHistorySheet()"))

// ── I. 行为表在场（与本节互补自证）──────────────────────────────
// ── 文案诚实性（v4.0.104 审查抓到：「入待办」会经账本同步到 NAS，原文案却写「不上传」）──
ck("sheet 说明文案不得谎称「不上传」（入待办的内容会随待办账本同步到 NAS）",
   sheetRaw.contains("只留在这台手机上") && sheetRaw.contains("与你的 NAS 同步") && !sheetRaw.contains("不上传"))

ck("行为表 test_clipboard.swift 在场且真跑生产源码（注入 suite）",
   testSrc.contains("ClipboardHistoryStore(defaults:") && !testSrc.isEmpty)
ck("行为表覆盖上限 100 淘汰最旧", testSrc.contains("上限收敛") )
ck("行为表覆盖关掉开关后 record 不动库", testSrc.contains("关掉后 record 一律 nil 且不入库"))

print(fail == 0 ? "✅ ALL PASS（\(pass) 项）" : "❌ \(fail) 项失败")
exit(fail == 0 ? 0 : 1)
