import Foundation

// MARK: - v3.9.86 长回复阅读（功能 4 · B 方案）真值表（本机可跑）
//
// 用户 2026-09-26 拍板：「B 半屏 sheet 放大（沿用现有 detent）——最省：无新增宿主、
// sheet 互斥枚举照旧；代价是长文只有屏高」。本表钉死这条口径，防止以后被改成"新增全屏宿主"或
// "另起一套 markdown 渲染"：
//   ① 入口：长按文字菜单「全屏阅读」有且只有一条链路（SelectableTextLabel → MessageBlockView →
//      MessageBubble → ChatView 的 longReplyPayload），四条都传了 onRead；
//   ② 档位沿用全站 .medium/.large，且**不许**出现 .large-only / .height(N) / fullScreenCover 宿主；
//   ③ 复用而非重造：正文走 SelectableTextLabel（与气泡同一条渲染路径），章节切分走
//      MarkdownRenderer.extractHeaders（与「章节列表」同真源）——不许在阅读 sheet 里自己写
//      markdown 解析或另建标题正则；
//   ④ 背景不覆盖系统材质（根容器不许刷 systemBackground）；大纲层走材质不是实底；
//   ⑤ 同宿主互斥：分享不许再挂第二个 .sheet（改为先 dismiss 再 present）；
//   ⑥ 大纲不新增 sheet/全屏页（是本 sheet 内部一层）；
//   ⑦ 参数声明序 = 调用序（onRead 插在 onWithdraw 之后、onPin 之前，两处调用点同序）；
//   ⑧ 胶囊不许被压没（.fixedSize()）——v3.9.72 踩过的空胶囊坑。

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }

let sheet = src("qingliao/Features/Chat/LongReplySheet.swift")
let chatView = src("qingliao/Features/Chat/ChatView.swift")
let sel = src("qingliao/Features/Chat/SelectableTextLabel.swift")
let comps = src("qingliao/Features/Chat/ChatComponents.swift")
let bubble = src("qingliao/Features/Chat/ChatMessageBubble.swift")
let sheetCode = stripCommentLines(sheet)

// MARK: 0. 文件到位
check("① Features/Chat/LongReplySheet.swift 存在且非空", sheet.count > 2000)
check("① 定义了 LongReplySheet 视图", sheet.contains("struct LongReplySheet: View"))
check("① 载荷 Identifiable（.sheet(item:) 需要）", sheet.contains("struct LongReplyPayload: Identifiable"))

// MARK: 1. 入口链路唯一且四段都传了 onRead
check("① 长按菜单有「全屏阅读」项", sel.contains("全屏阅读") && comps.contains("全屏阅读"))
check("① SelectableTextLabel 声明 onRead", sel.contains("var onRead: ((String) -> Void)? = nil"))
check("① MessageBlockView 声明 onRead", comps.contains("var onRead: ((String) -> Void)? = nil"))
check("① MessageBubble 声明 onRead", bubble.contains("var onRead: ((String) -> Void)? = nil"))
check("① ChatView 有 onRead 接线闭包", chatView.contains("} onRead: {"))
check("① ChatView 状态 longReplyPayload 存在", chatView.contains("var longReplyPayload: LongReplyPayload?"))
// 代码块/表格走 SwiftUI 菜单、markdown 走 UITextView 菜单，两条渲染路径都得能触发阅读
check("① 两条渲染路径都传了 onRead（MessageBlockView 调用点 ≥2）",
      bubble.components(separatedBy: "onRead: onRead").count - 1 >= 2)
check("① 气泡级 contextMenu 没被挂上（会抢 UITextView 长按，v2.0.122 旧坑）",
      !bubble.contains(".contextMenu { bubbleMenu }") || !comps.contains("onRead: onRead,"))

// MARK: 2. 档位沿用 + 不新增宿主
check("② 宿主挂 .sheet(item: $longReplyPayload)", chatView.contains(".sheet(item: $longReplyPayload)"))
check("② 档位 .presentationDetents([.medium, .large])（与全站输入弹窗同档）",
      flat(chatView).contains("LongReplySheet(payload:payload).presentationDetents([.medium,.large])"))
check("② 阅读 sheet 自身不写 detents（档位只在宿主一处，勿两处各写一份）",
      !sheetCode.contains("presentationDetents"))
check("② 不写死高度 .height(N)（用户要求沿用系统档位）",
      !sheetCode.contains(".height("))
check("② 阅读不是全屏呈现：宿主用 .sheet(item:)，长回复未新增 fullScreenCover 宿主",
      chatView.contains(".sheet(item: $longReplyPayload)")
      && !sheetCode.contains("fullScreenCover")
      && !flat(chatView).contains("fullScreenCover(item:$longReplyPayload)"))
// 基线：ChatView 既有 4 个 fullScreenCover（相机/任务中心/大爆炸/大图），阅读不得再加。
// 计数必须先去注释行——注释里提到 fullScreenCover 的地方有好几处。
let chatCode = stripCommentLines(chatView)
check("② fullScreenCover 宿主数量仍为基线 4（相机/任务中心/大爆炸/大图）",
      flat(chatCode).components(separatedBy: ".fullScreenCover").count - 1 == 4)
check("② 没有 navigationDestination/全屏页（4 号不引入新转场）",
      !sheetCode.contains("navigationDestination"))

// MARK: 3. 复用既有渲染/章节真源
check("③ 正文走 SelectableTextLabel（与气泡同一条渲染路径）", sheet.contains("SelectableTextLabel("))
check("③ 章节切分走 MarkdownRenderer.extractHeaders（与章节列表同真源）",
      sheet.contains("MarkdownRenderer.extractHeaders"))
check("③ 正文排版走 MarkdownRenderer.renderCached（吃全局缓存，不自造解析）",
      sheet.contains("MarkdownRenderer.renderCached"))
check("③ 阅读 sheet 内不自己写 markdown 标题正则（防止两套口径漂移）",
      !sheetCode.contains("hasPrefix(\"#\")") && !sheetCode.contains("NSRegularExpression"))
check("③ 朗读复用 SpeechManager（不新建 TTS 实例）", sheet.contains("SpeechManager.shared"))
check("③ 存便签复用 MemoStore", sheet.contains("MemoStore.shared.add"))

// MARK: 4. 背景不覆盖系统材质
check("④ 根容器不刷 systemBackground（会把系统材质盖成实底）",
      !sheetCode.contains("systemBackground"))
check("④ 不加 presentationBackground（iOS 26 系统材质才是对的底）",
      !sheetCode.contains("presentationBackground"))
check("④ 大纲层走材质，不是 secondarySystemGrouped 实底",
      sheetCode.contains("ultraThinMaterial") && !sheetCode.contains("secondarySystemBackground"))

// MARK: 5. 同宿主互斥（分享）
check("⑤ 分享不再挂第二个 .sheet（会被静默吞掉）", !sheetCode.contains("ActivityShareSheet"))
check("⑤ 分享走「先 dismiss 再 present」", sheetCode.contains("dismiss()") && sheetCode.contains("UIActivityViewController"))
check("⑤ 分享前有延时等 sheet 退场（同宿主铁律的既有口径）",
      sheetCode.contains("milliseconds(450)"))

// MARK: 6. 大纲是本 sheet 内部一层
check("⑥ 大纲不新建 sheet（是覆盖层）", sheetCode.contains("tocOverlay"))
check("⑥ 大纲跳转走 ScrollViewReader 锚点", sheet.contains("ScrollViewReader") && sheet.contains("proxy.scrollTo"))
check("⑥ 无标题的长回复也能进（整条作为一章）", sheetCode.contains("\"全文\""))

// MARK: 7. 参数声明序 = 调用序（swiftui-param-order 铁律，CI 本地查不出）
func orderOK(_ s: String, _ a: String, _ b: String) -> Bool {
    guard let ia = s.range(of: a), let ib = s.range(of: b) else { return false }
    return ia.lowerBound < ib.lowerBound
}
// 各类型的声明序是历史形成的，断言按各自的真实邻位关系写死：
//   SelectableTextLabel / MessageBlockView：onWithdraw < onRead < onMultiSelect|onPin
//   MessageBubble：onPin … onRemind < onRead < onAIImageTap（onRead 插在 onRemind 之后）
for (name, text) in [("SelectableTextLabel", sel), ("MessageBlockView", comps)] {
    let decls = text.components(separatedBy: "struct \(name)").last ?? ""
    check("⑦ \(name) 声明序 onWithdraw < onRead", orderOK(decls, "var onWithdraw", "var onRead"))
    check("⑦ \(name) 声明序 onRead < onPin（若该类型有 onPin）",
          !decls.contains("var onPin") || orderOK(decls, "var onRead", "var onPin"))
}
let bubbleDecl = bubble.components(separatedBy: "struct MessageBubble").last ?? ""
check("⑦ MessageBubble 声明序 onRemind < onRead < onAIImageTap",
      orderOK(bubbleDecl, "var onRemind", "var onRead")
      && orderOK(bubbleDecl, "var onRead", "var onAIImageTap"))
let callInChat = chatView.components(separatedBy: "MessageBubble(").last ?? ""
check("⑦ MessageBubble 调用点 onRemind → onRead → onAIImageTap（与声明序一致）",
      orderOK(callInChat, "onRemind:", "onRead:")
      && orderOK(callInChat, "onRead:", "onAIImageTap:"))
let compCall = comps.components(separatedBy: "SelectableTextLabel(").last ?? ""
check("⑦ SelectableTextLabel 调用点 onWithdraw < onRead < onMultiSelect",
      orderOK(compCall, "onWithdraw:", "onRead:") && orderOK(compCall, "onRead:", "onMultiSelect:"))
let b1 = bubble.components(separatedBy: "MessageBlockView(").dropFirst().first ?? ""
check("⑦ MessageBlockView 调用点 onRead 在 onPin 之前", orderOK(b1, "onRead:", "onPin:"))

// MARK: 8. 胶囊护栏
check("⑧ 动作胶囊文字 .fixedSize()（v3.9.72 空胶囊坑）", sheetCode.contains(".fixedSize()"))

print("长回复阅读真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
