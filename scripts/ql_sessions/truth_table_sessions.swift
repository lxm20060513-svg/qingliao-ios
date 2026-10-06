// MARK: - 会话列表「进行中」标识 · 真值表（v4.0.x · 2026-09-27 用户拍板）
//
// 口径（用户从编号选项里拍板）：
//   位置 = **替换右列 chevron**；形态 = **呼吸脉冲小圆点**（开了「减弱动态效果」即静止常亮）；
//   判定 = **本机这条流没结束就算**（切到别的会话看别的行、App 切后台都照显）。
//
// 为什么值得钉（三处都会**静默**错，不报错、只让用户觉得「这功能没用/列表发烫」）：
//   ① 真源是「流归属会话」`auth.currentStreamSessionId` —— StreamClient 启动时写入，**结束后不清空**
//      （全仓只有三处赋值、没有复位），只看它不配 isStreaming/isDone 就会把上一次跑过的会话永久标成进行中；
//   ② 多选编辑态必须优先：标识把勾选圈顶掉 = 编辑模式下点不中要删的会话；
//   ③ 会话列表在流式期间会重新求值 —— 行内**只许读 isStreaming/isDone**（布尔），
//      一旦读到 `stream.content`（每 token 都变），列表就每个 token 重算一次。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 去掉 `//` 与 `/* */` 注释，只留代码文本（注释里常留着旧口径说明，先剥再判）
func stripComments(_ s: String) -> String {
    var out = ""
    var inLine = false, inBlock = false
    var prev: Character = " "
    for ch in s {
        if inLine {
            if ch == "\n" { inLine = false; out.append(ch) }
            continue
        }
        if inBlock {
            if ch == "*" && prev == "/" { inBlock = false }
            prev = ch == "*" ? "*" : " "
            continue
        }
        if ch == "/" && prev == "/" { inLine = true; prev = " "; continue }
        if ch == "/", let n = out.last, n == "*" { inBlock = true; prev = " "; continue }
        out.append(ch)
        prev = ch
    }
    return out.replacingOccurrences(of: "*/", with: " ")
}

/// 取 a 之后、b 之前的一段源码（先断言切片非空，否则下面的断言等于空真）
func slice(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}

let viewSrc = src("qingliao/Features/Sessions/SessionsView.swift")
let viewCode = stripComments(viewSrc)

// ── 1. 源可读（空了下面全是空真） ─────────────────────────────
check("SessionsView.swift 源可读", !viewCode.isEmpty)

// ── 2. 会话列表页真的拿到了流对象（缺它读不到 isStreaming → 标识永远不出现） ──
check("SessionsView 注入了 StreamClient（@Environment(StreamClient.self) private var stream）",
      viewCode.contains("@Environment(StreamClient.self) private var stream"))

// ── 3. 「算不算进行中」的判定（本表最重要的三条） ──────────────
// 2026-09-30：判定从 `private var runningSessionID: String?` 改成按会话判定的方法
// （原属性引用了 sessionCell 的形参 s → 编译不过，swiftc -parse 查不出、CI Archive 才炸；
//  发布前审查拦下）。断言语义一条未减，只同步锚点，并补一条多会话并行口径。
let judge = slice(viewCode, "private func isRunning(_ s: ChatSession) -> Bool", "private func sessionCell(_ s: ChatSession)")
check("isRunning 切片非空（护栏不许空真）", !judge.isEmpty)
check("必须取**流归属**会话 auth.currentStreamSessionId（不是当前打开的会话）",
      judge.contains("auth.currentStreamSessionId"))
check("必须同时判 stream.isStreaming（光看归属 id 会把上次跑过的会话永久标成进行中）",
      judge.contains("stream.isStreaming"))
check("必须同时判 !stream.isDone（流收尾后 isStreaming/isDone 才是真状态）",
      judge.contains("!stream.isDone"))
check("空 id 不得误标（归属比较 == s.id，空串永不相等）",
      judge.contains("auth.currentStreamSessionId == s.id"))
check("多会话并行：后台跑流集合命中也算「进行中」（BackgroundStreamRunner 口径）",
      judge.contains("backgroundRunningIDs.contains(s.id)"))

// ── 4. 性能口径：行内不许读每 token 都会变的内容 ────────────────
check("行内不得读 stream.content（每 token 变化 → 会话列表每 token 重算）",
      !viewCode.contains("stream.content"))

// ── 5. SessionRow：参数 + 分支顺序（多选编辑态优先） ────────────
let row = slice(viewCode, "struct SessionRow: View", "private struct RunningDot")
check("SessionRow 切片非空", !row.isEmpty)
check("SessionRow 有 running 参数（默认 false = 老调用点不受影响）", row.contains("var running = false"))
check("右列存在 running 分支（} else if running {）", row.contains("} else if running {"))
check("RunningDot() 在 running 分支里被用上", row.contains("RunningDot()"))

let checkIdx = row.range(of: "checkmark.circle.fill")?.lowerBound
let runningIdx = row.range(of: "} else if running {")?.lowerBound
// ⚠️ 不能用裸 "chevron.right" 当锚：头像图标表里那串 "chevron.left.forwardslash.chevron.right"
//    本身就含这个子串（会命中最前面那个假锚）。必须锚到真正的右列箭头。
let chevronIdx = row.range(of: "Image(systemName: \"chevron.right\")")?.lowerBound
check("多选勾选圈分支仍在（编辑模式不许被标识顶掉）", checkIdx != nil)
check("running 分支排在多选勾选**之后**（编辑态优先）",
      (checkIdx != nil && runningIdx != nil) && checkIdx! < runningIdx!)
check("chevron 只出现在 running 分支**之后**的兜底里（= 箭头被标识替换，不是并存）",
      (chevronIdx != nil && runningIdx != nil) && runningIdx! < chevronIdx!)

// ── 6. RunningDot：无障碍 + 动效口径 + 不引入实色底 ─────────────
let dot = slice(viewCode, "private struct RunningDot", "private struct SessionTagCapsules")
check("RunningDot 切片非空（元素真的在源码里）", !dot.isEmpty)
check("RunningDot 尊重「减弱动态效果」（accessibilityReduceMotion）", dot.contains("accessibilityReduceMotion"))
check("减速动效是**门控**而非仅声明（reduceMotion ? nil : …）", dot.contains("reduceMotion ? nil :"))
check("呼吸用 repeatForever(autoreverses:) 循环（与 SkeletonBlock 同口径）",
      dot.contains("repeatForever(autoreverses: true)"))
check("减速时静止常亮（opacity 取 1，不是 0）", dot.contains("reduceMotion ? 1 :"))
check("有无障碍标签（纯图形标识，VoiceOver 读不到就没有语义）", dot.contains("accessibilityLabel"))
check("RunningDot 不自行挂实色底（会话卡 F2 口径：卡上不得再压实色底）", !dot.contains(".background("))

// ══════════════════════════════════════════════════════════════════
// v4.1.x「一键清空会话内容」（会话列表长按菜单 → 清消息、留会话与标题）
//
// 为什么值得钉（三处都会**静默**错，用户只看到「点了没反应」或「删完又回来」）：
//   ① 它走的是 merge 的 **sessions 键 + 空 messages 数组**，不是 deleted 键 ——
//      钉 deleted 为空数组（真源 = 切片里 "deleted": []），否则日后有人改成删除就等于
//      把「保留会话与标题」这条产品口径悄悄换掉（那不是清空，是删除）。
//   ② 固定会话（投递壳 / 轻聊主动）不许清空：主动会话内容**以 NAS 为准**，
//      App 写空数组会被后端 _CLIENT_WINS_IDS 之外那条路忽略 → 用户看到「清空没反应」。
//      与「不可删 / 不可改名」同一类保护，故菜单里**直接不给入口**（不给会报错的按钮）。
//   ③ 正在看的会话必须在**可见的聊天页**上清数据：隐藏 TabView 页直接清 messages 是本仓
//      实测的 SIGTRAP 组合（v2.0.44/2.0.54/2.0.56），故钉「先切 tab + 延迟一帧再清」。
//   ④ 反过来钉一条**否定**纪律：这里**不能**照抄 rename() 的 sessionsFromNetwork 闸门。
//      那个闸门防的是「拿 50 条缓存快照去写 → 整会话覆盖 → 永久截断历史」，
//      而清空发的是空数组、后端直接采用 incoming，压根没有截断风险；
//      照抄只会让冷启动缓存的用户点了没反应。否定式纪律最容易被「顺手补齐」违反，故钉死。
// ══════════════════════════════════════════════════════════════════

let clearFn = slice(viewCode, "private func clearContent(_ s: ChatSession)", "private func delete(_ s: ChatSession)")
check("clearContent 切片非空（护栏不许空真）", !clearFn.isEmpty)

// —— 入口：长按菜单里真有一项，且固定会话不给入口（不是给一个点了报错的按钮） ——
let menu = slice(viewCode, "Menu(\"标签\")", "func rank(")
check("长按菜单切片非空", !menu.isEmpty)
check("长按菜单有「清空会话内容」入口（清消息、留会话与标题）",
      menu.contains("Label(\"清空会话内容\""))
check("入口由「打开确认弹窗」驱动，不在 contextMenu 关闭瞬间改数据（同 delete 的 v2.0.57 口径）",
      menu.contains("confirmClear = s"))
check("清空入口是 destructive（与删除同级，不可误触）",
      menu.contains("Button(role: .destructive) {\n            confirmClear = s"))
let clearIdx = menu.range(of: "清空会话内容")?.lowerBound
let deleteIdx = menu.range(of: "Label(\"删除会话\"")?.lowerBound
check("「清空会话内容」排在「删除会话」**之前**（风险递增，两项都是 destructive）",
      (clearIdx != nil && deleteIdx != nil) && clearIdx! < deleteIdx!)
// v4.0.18 反转：固定会话（投递壳 / 轻聊主动）**也给清空入口**（用户拍板：这两个会话也要能清；
// 删除仍不给入口）。清空入口不得再按固定会话排除。
check("清空入口对固定会话可见（清空按钮前无固定会话排除判断）",
      menu.contains("Button(role: .destructive) {\n            confirmClear = s") &&
      !menu.contains("if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId {\n            Button(role: .destructive) {\n                confirmClear = s"))
// v4.0.68：固定会话改成顶部**并排卡**后，卡片成了唯一入口 —— 卡片不挂菜单 = 清空入口随改版消失
//（审查实锤过一次）。另外：菜单必须仍是**单一真源**，卡片不许另抄一份。
check("v4.0.68：并排卡挂同一份 sessionRowMenu（清空入口不在改版里丢）",
      viewCode.components(separatedBy: ".contextMenu { sessionRowMenu(s) }").count - 1 == 2)
check("v4.0.68：长按菜单是单一真源（confirmClear 赋值点唯一）",
      viewCode.components(separatedBy: "confirmClear = s").count - 1 == 1)

// —— 确认弹窗：独立文案，明说「会话与标题保留」（不是复用删除弹窗） ——
check("清空有独立的确认弹窗（不与删除共用一个 alert）",
      viewCode.contains(".alert(\"清空会话内容\""))
check("确认弹窗文案写明「会话与标题保留」（用户点之前就知道删的是什么）",
      viewCode.contains("会话与标题保留"))
check("清空有独立的失败提示（errorText 只在列表为空时渲染，失败会静默）",
      viewCode.contains(".alert(\"清空失败\"") && viewCode.contains("clearError"))

// —— 载荷：走 sessions 键（会话与标题保留），绝不走 deleted ——
check("清空写请求走 merge 的 sessions 键（会话本身保留）",
      clearFn.contains("\"sessions\": [[\"id\": sid, \"title\": ttl, \"messages\": [Any]()]"))
check("deleted 必须为空数组（走 deleted 就等于删会话，不是清空内容）",
      clearFn.contains("\"deleted\": [] as [Any]"))
check("标题沿用当前值（不清空标题 = 产品口径）",
      clearFn.contains("let ttl = s.title") && clearFn.contains("\"title\": ttl"))
check("messages 传空数组（真清空内容）",
      clearFn.contains("\"messages\": [Any]()"))

// —— 固定会话闸门（v4.0.18 反转：固定会话允许清空，clearContent 不再拦） ——
check("clearContent 不再拦固定会话（后端已支持两固定会话清空落库）",
      !clearFn.contains("s.id == ChatStore.deliverySessionId || s.id == ChatStore.proactiveSessionId"))

// —— 不设「冷启动缓存不许清空」这道闸：它对清空是**错的**（rename ③ 的坑不适用）——
//    rename 要把完整消息集写回去，50 条快照会截断历史；清空发的是空数组，
//    后端 merge 对同 id 直接采用 incoming（sessions_api：incoming 带 messages 含空数组 → 采用），
//    空数组落到线上恒为「无消息」，**无截断风险**。照抄 rename 的闸门只会让
//    冷启动缓存的用户点了没反应。护栏钉死这个「不许被加回来」的判断。
check("不得搬用 rename 的 sessionsFromNetwork 闸门（清空发空数组，无截断风险）",
      !clearFn.contains("sessionsFromNetwork"))
check("也就不再需要为清空去取完整消息集（不该出现 usingLiveChat/msgs 分支）",
      !clearFn.contains("usingLiveChat") && !clearFn.contains("let msgs ="))

// —— 当前会话：切 tab + 延迟一帧再清（隐藏页清数据 = 本仓实测 SIGTRAP） ——
check("当前会话清空前必须先切到聊天页（onOpenSession）",
      clearFn.contains("onOpenSession?()"))
check("清数据必须延迟一帧（0.08s）执行，不能与切 tab 同帧（v2.0.44/2.0.54/2.0.56 教训）",
      clearFn.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.08)"))

// —— 失败必须提示 + 成功才动内存 ——
check("服务器未确认成功就不许动本地内存（清完又被下次 saveToServer 写回去 = 白做）",
      clearFn.contains("guard synced else { await load(); return }"))
check("失败文案有网络异常与服务器异常两态",
      clearFn.contains("清空未同步到服务器：") && clearFn.contains("清空未同步到服务器（服务器返回异常）"))
check("该会话有后台流在跑时先撤（否则答案把刚清空的会话又写满）",
      clearFn.contains("BackgroundStreamRunner.shared.cancelForDeletedSession(sessionId: s.id, auth: auth)"))
check("成功后整体刷新列表（不就地改 sessions，与 delete 同口径）",
      clearFn.contains("await load()"))
// —— v4.0.15：清空前必须排空写链，否则在途旧快照把刚清掉的内容整会话盖回来 ——
// 事故机制：clearContent 自己直发 merge（不进 saveWriteChain），而 ChatView 的防抖写
// 可能已带着清空前的旧快照排在链里/在途 → 空写落地后旧快照后到 → 「清空了又全回来」。
check("清空前必须先排空写链（flushPendingWrites）", clearFn.contains("await chat.flushPendingWrites()"))
let nsPos: (String, String) -> Int = { hay, needle in
    (hay as NSString).range(of: needle).location == NSNotFound
        ? Int.max : (hay as NSString).range(of: needle).location
}
check("排空必须排在发空写之前（不是写完之后才排）",
      nsPos(clearFn, "flushPendingWrites") < nsPos(clearFn, "/api/sessions/merge"))
// —— 确认弹窗不许显示条数（列表可能来自 50 条冷启动缓存，条数会与真实不符）——
check("确认弹窗不显示消息条数（冷启动缓存条数会骗人）",
      !viewCode.contains("confirmClear?.messages.count"))

// —— 与既有删除路径互不串味（两处都还在，各司其职） ——
check("删除会话路径仍在（deleted 键 + confirmDelete）",
      viewCode.contains("confirmDelete = s") && viewCode.contains("Label(\"删除会话\""))
let delFn = slice(viewCode, "private func delete(_ s: ChatSession)", "}\n\n")
check("delete 切片非空", !delFn.isEmpty)
check("清空逻辑没有混进 delete 函数体（两条路径必须各自独立可读）",
      !delFn.contains("清空未同步到服务器"))

// ══════════════════════════════════════════════════════════════════
// v4.1.x「单条会话左滑删除」（TrailingDeleteSwipe 条件修饰器，滑到底即触发）
//
// 为什么值得钉（四处都会**静默**错，编译器不报、真值表不写就没人拦）：
//   ① 左滑动作只许「置确认状态」—— 一旦直连 delete(s) 或自己发 merge，
//      既有「删除会话」二次确认就被绕过（用户点一下滑走就没了）；
//   ② 必须复用既有删链 delete(_:)（内含 flushPendingWrites 写链闸门 + merge deleted 键），
//      另写一套存储写逻辑 = 又造一个「删了又活着回来 / 清空了又全回来」的入口；
//   ③ 固定会话（投递壳 / 轻聊主动）必须**不给入口**（与长按菜单、批量删同一口径），
//      后端 _PROTECTED_IDS 拒删，给了就是「点了会报错的按钮」；
//   ④ 滑到底要能触发 → 不得写 allowsFullSwipe: false（写了就只能滑完再点那颗按钮）。
// v4.0.35：swipe 从内联挂载改为 TrailingDeleteSwipe 条件修饰器（固定会话整行不挂，
// 消死空白 swipe 区），形态断言同步搬家——钉修饰器本体 + sessionCell 的接线。
// ══════════════════════════════════════════════════════════════════

let cell = slice(viewCode, "private func sessionCell(_ s: ChatSession)", "private func rank(_ id: String)")
check("sessionCell 切片非空（护栏不许空真）", !cell.isEmpty)

// —— 修饰器本体（真值所在）——
let modDef = slice(viewCode, "private struct TrailingDeleteSwipe", "private extension View")
check("TrailingDeleteSwipe 修饰器定义存在（v4.0.35 条件挂载形态）", !modDef.isEmpty)
check("左滑删除仍挂在 trailing 边（.swipeActions(edge: .trailing)）",
      modDef.contains(".swipeActions(edge: .trailing"))
check("左滑动作是 destructive 红色「删除」（Button(role: .destructive) + trash 图标）",
      modDef.contains("Button(role: .destructive)") && modDef.contains("Label(\"删除\", systemImage: \"trash\")"))
check("滑到底即触发（allowsFullSwipe: true）",
      modDef.contains("allowsFullSwipe: true") && !modDef.contains("allowsFullSwipe: false"))
check("动作只置确认回调，不自行删数据（onTrigger 闭包，不得直连 delete/merge）",
      modDef.contains("onTrigger()")
      && !modDef.contains("delete(")
      && !modDef.contains("/api/sessions")
      && !modDef.contains("auth.json"))

// —— sessionCell 接线（消费侧）——
check("sessionCell 接线走 TrailingDeleteSwipe（不再内联挂 trailing swipe）",
      cell.contains(".modifier(TrailingDeleteSwipe("))
check("接线传 isActive: !isFixedSession（固定会话整行不挂，消死空白区）",
      cell.contains("isActive: !isFixedSession(s.id)"))
check("接线回调只置确认状态（confirmDelete = s），不自行删数据",
      cell.contains("{ confirmDelete = s }") && !cell.contains("delete(s)"))

// —— 复用链：左滑 → confirmDelete → 既有「删除会话」alert → delete(_:)，删前必须排空写链 ——
check("二次确认沿用既有「删除会话」alert（confirmDelete 绑定，未为左滑另写一套弹窗）",
      viewCode.contains(".alert(\"删除会话\"") && viewCode.contains("isPresented: Binding(get: { confirmDelete != nil }"))
check("确认弹窗的「删除」仍走既有 delete(_:)（v2.0.57 口径：弹窗关完、延迟 0.3s 再删）",
      viewCode.contains("Task { try? await Task.sleep(for: .seconds(0.3)); delete(s) }"))
check("既有删链 delete(_:) 仍在（delFn 切片非空，下面两条才有意义）", !delFn.isEmpty)
check("左滑复用的删链在发 merge 之前先排空在途写链（flushPendingWrites，防「删了又活着回来」）",
      nsPos(delFn, "flushPendingWrites") < nsPos(delFn, "/api/sessions/merge"))
check("左滑复用的删链走 merge 的 deleted 键（与批量删同一条实现路径）",
      delFn.contains("\"deleted\": [s.id]"))

// —— 反向自证：把形态逐维度改坏，同一条断言必须变红（没红过 = 没有护栏）——
let badMod = modDef.replacingOccurrences(of: "onTrigger()", with: "delete(s)")
check("🚫 反向①：动作直连 delete(s)（绕过二次确认）→ 判红",
      !badMod.contains("onTrigger()") && badMod.contains("delete("))

let badWrite = modDef.replacingOccurrences(
    of: "onTrigger()",
    with: "_ = try? await auth.json(\"/api/sessions/merge\")")
check("🚫 反向②：动作里塞 merge 调用（另写一套存储写逻辑）→ 判红",
      badWrite.contains("/api/sessions"))

let badFull = modDef.replacingOccurrences(
    of: "allowsFullSwipe: true",
    with: "allowsFullSwipe: false")
check("🚫 反向③：写成 allowsFullSwipe: false（滑到底不触发）→ 判红",
      !badFull.contains("allowsFullSwipe: true") && badFull.contains("allowsFullSwipe: false"))

let badWiring = cell.replacingOccurrences(
    of: "isActive: !isFixedSession(s.id)",
    with: "isActive: true")
check("🚫 反向④：接线去掉固定会话拦截（主动会话左滑出删除区）→ 判红",
      badWiring.contains("isActive: true") && !badWiring.contains("isActive: !isFixedSession(s.id)"))

// ══════════════════════════════════════════════════════════════════
// v4.0.21「会话列表容器必须是 List」—— 单条左滑删除的真实前置条件（用户拍板「换 List」）
//
// 为什么值得钉（**编译器、swiftc -parse、编译期全都不报，只有真机手指能发现**）：
//   `.swipeActions` 的官方语义 = 「Adds swipe actions to a view that is presented in a **list**」
//   —— 行落在 ScrollView/LazyVStack 里时该修饰符**静默无效**。上面那组 v4.1.x 左滑断言
//   （只断言「.swipeActions 挂在会话行上」）因此一直在为**一个真机无效的功能**发绿灯：
//   它钉住了形态，没钉「形态生效的前提」。本条补的正是前提 —— 会话行必须**直接**落在 List 里。
//   反向：谁把 List 改回 ScrollView/LazyVStack（图省事/图复用容器），本条立刻变红。
// ══════════════════════════════════════════════════════════════════

let listBody = slice(viewCode, "private var sessionsListBody: some View", "private var sessionsEmptyState")
check("sessionsListBody 切片非空（护栏不许空真）", !listBody.isEmpty)
check("会话列表容器是 List（左滑删除生效的前提）", listBody.contains("List {"))
check("旧容器形态清零：不得再用 ScrollView 包会话列表", !listBody.contains("ScrollView"))
check("旧容器形态清零：不得再用 LazyVStack 包会话列表", !listBody.contains("LazyVStack"))
check("List 已抹平自带样式：plain + 隐藏自带底 + 行高兜底清零",
      listBody.contains(".listStyle(.plain)")
      && listBody.contains(".scrollContentBackground(.hidden)")
      && listBody.contains(".environment(\\.defaultMinListRowHeight, 0)"))

let listStack = slice(viewCode, "private var sessionsListStack: some View", "private var sortedSessions")
check("会话行容器切片非空（护栏不许空真）", !listStack.isEmpty)
// v4.0.68：固定会话（轻聊投递/轻聊主动）已上移到顶部并排卡 → 这里多了 filter，
// 口径不变：会话行仍是**直接**铺进 List，且不套任何 LazyVStack。
check("会话行直接铺进 List（ForEach(sortedSessions…)，不再套 LazyVStack",
      listStack.contains("ForEach(sortedSessions.filter { !isFixedSession($0.id) })")
      && !listStack.contains("LazyVStack"))
check("v4.0.68：会话行过滤掉固定会话（顶部并排卡之后，同一会话不许在列表里再出现一次）",
      listStack.contains("filter { !isFixedSession($0.id) }"))
check("会话行带 List 行样式（.sessionListRow）", listStack.contains(".sessionListRow("))

let searchArea = slice(viewCode, "private var searchResultsArea: some View", "private var remoteNoticeText")
check("搜索区切片非空（护栏不许空真）", !searchArea.isEmpty)
check("搜索结果行也直接铺进 List（搜索态左滑同样要能用）",
      searchArea.contains("ForEach(filteredSessions)") && !searchArea.contains("LazyVStack"))
check("远端命中行也逐行铺进 List（不再套 VStack）",
      searchArea.contains("ForEach(remoteHits)") && !searchArea.contains("VStack("))

// —— 行样式抹平必须只有一处实现（新形态在 + 旧写法不得散落在各调用点）——
let chromeCount = viewCode.components(separatedBy: ".listRowSeparator(.hidden)").count - 1
check("行样式抹平实现唯一（.listRowSeparator(.hidden) 只许在 SessionListRowChrome 里出现 1 次）",
      chromeCount == 1)
check("行样式三件套齐全（行内边距 + 无分隔线 + 透明行底）",
      viewCode.contains(".listRowInsets(EdgeInsets(")
      && viewCode.contains(".listRowSeparator(.hidden)")
      && viewCode.contains(".listRowBackground(Color.clear)"))
let rowCalls = viewCode.components(separatedBy: ".sessionListRow(").count - 1
check("每类行都挂了行样式（调用点 ≥ 5：非搜索 3 类 + 会话行 + 搜索区各行）", rowCalls >= 5)

// —— 反向自证：容器改回旧形态，上面的断言必须变红（没红过 = 没有护栏）——
let badBackToScroll = viewCode.replacingOccurrences(
    of: "private var sessionsListBody: some View {\n        List {",
    with: "private var sessionsListBody: some View {\n        ScrollView {\n            LazyVStack {")
let badBodySlice = slice(badBackToScroll, "private var sessionsListBody: some View", "private var sessionsEmptyState")
check("🚫 反向①：容器改回 ScrollView+LazyVStack（左滑又静默失效）→ 判红",
      !badBodySlice.isEmpty && listBody.contains("List {") && !badBodySlice.contains("List {"))

let badStack = viewCode.replacingOccurrences(of: "ForEach(sortedSessions.filter { !isFixedSession($0.id) })",
                                             with: "LazyVStack { ForEach(sortedSessions.filter { !isFixedSession($0.id) })")
let badStackSlice = slice(badStack, "private var sessionsListStack: some View", "private var sortedSessions")
check("🚫 反向②：会话行又套回 LazyVStack → 判红",
      !badStackSlice.isEmpty && !listStack.contains("LazyVStack") && badStackSlice.contains("LazyVStack"))

// ── 7. 结果 ──────────────────────────────────────────────────
print("会话列表「进行中」标识真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
