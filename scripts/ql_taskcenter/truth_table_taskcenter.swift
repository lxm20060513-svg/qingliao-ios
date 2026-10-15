// v4.0.114 任务中心真值表 —— Linux 本地预检用（纯 Foundation，只读源码）
//
// 由来：全仓破坏性动作的既定口径是**一律二次确认**（清空会话、删文件、删产物、停任务……），
// 而任务中心的「清理已完成」是唯一**直接删**的入口 —— 点一下，已完成任务全部消失、无法恢复。
// 本批给它补上确认，并且必须是仓内统一形态。
//
// ⚠️ 形态不是随便挑的：v4.0.102 起全仓统一「二次确认走**锚定浮层** AnchorMenuOverlay，
//    **不用** confirmationDialog」——后者在 iPhone 上固定从屏幕底部升起、锚不到触发按钮，
//    仓内已逐个搬走（先例：ClipboardHistorySheet、SettingsData 的 HistorySheet「全部清除」）。
//    另外锚定浮层必须挂 **NavigationStack 之外**（整页最外层），轻纱才盖得住导航栏。
//
// 全是**编译不报、手点才现**的坏法：漏确认 = 误删；挂错层 = 轻纱盖不住导航栏；
// 用 confirmationDialog = 与全仓观感不一致、锚不到按钮；不采锚点 = 弹在屏幕左上角。
//
// ⚠️ 全部断言走**剥注释**后的代码文本：本仓老坑「注释里写了就假绿」。

import Foundation

var passCount = 0
var failCount = 0

@MainActor
func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if cond { passCount += 1 } else { failCount += 1 }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 去掉行注释与块注释（本仓同类表的既有一口径）
func stripComments(_ s: String) -> String {
    var out = ""
    var inBlock = false
    for raw in s.components(separatedBy: "\n") {
        var line = raw
        if inBlock {
            guard let end = line.range(of: "*/") else { continue }
            line = String(line[end.upperBound...])
            inBlock = false
        }
        while let start = line.range(of: "/*") {
            if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                line = String(line[line.startIndex..<start.lowerBound]) + String(line[end.upperBound...])
            } else {
                line = String(line[line.startIndex..<start.lowerBound])
                inBlock = true
                break
            }
        }
        if let r = line.range(of: "//") {
            line = String(line[line.startIndex..<r.lowerBound])
        }
        out += line + "\n"
    }
    return out
}

let path = "qingliao/Features/TaskCenterView.swift"
let code = stripComments(src(path))
let raw = src(path)

// ── ① 「清理已完成」是破坏性操作，必须有二次确认（原先直接 store.clearCompleted()）──
check("① 「清理已完成」不再直删（按钮只置位确认态）",
      code.contains("Button(\"清理已完成\") { confirmClearCompleted = true }")
        && !code.contains("Button(\"清理已完成\") { store.clearCompleted() }"))
check("① 确认态存在且默认关闭（@State 初值 false，冷启动不弹）",
      code.contains("@State private var confirmClearCompleted = false"))
check("① 确认里有 destructive 选项 + 取消选项",
      code.contains("AnchorMenuItem(id: \"clear\", title: \"清理\", icon: \"trash\", color: .red, destructive: true)")
        && code.contains("AnchorMenuItem(id: \"cancel\", title: \"取消\", icon: \"xmark\", color: .gray)"))
check("① 明示后果（不可恢复）—— 原 confirmationDialog 的 message 承载，改浮层后同样必须在场",
      code.contains("message: \"已完成的任务会从列表移除，无法恢复。\""))
check("① 真删动作挂在这个确认之下（onPick 里判 id 才调 store.clearCompleted）",
      code.contains("if m.id == \"clear\" {")
        && code.contains("store.clearCompleted()"))

// ── ② 形态：锚定浮层，不是 confirmationDialog（v4.0.102 全仓口径）──
check("② 走 AnchorMenuOverlay 锚定浮层",
      code.contains("AnchorMenuOverlay(anchorFrame: clearAnchor == .zero ? fallback : clearAnchor"))
check("②🚫 不用 confirmationDialog（iPhone 上固定从底部升起、锚不到触发按钮，仓内已废弃）",
      !code.contains("confirmationDialog"))
check("② 锚点由触发按钮自己采集（onGeometryChange 取 .global frame）",
      code.contains(".onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { clearAnchor = $0 }"))
check("② @State clearAnchor 存在且初值为 .zero",
      code.contains("@State private var clearAnchor: CGRect = .zero"))
check("② 锚点未量到时有兜底（不弹屏幕左上角）",
      code.contains("let fallback = CGRect(")
        && code.contains("clearAnchor == .zero ? fallback : clearAnchor"))

// ── ③ 挂载层：必须在 NavigationStack **之外**（整页最外层），轻纱才盖得住导航栏（v4.0.77 口径）──
check("③ 确认浮层挂在最外层（与 taskActionMenuLayer 同层，都在 NavigationStack 之外）",
      code.contains(".overlay { taskActionMenuLayer }")
        && code.contains(".overlay { clearCompletedMenuLayer }"))
check("③ 浮层是独立 @ViewBuilder 计算属性（不是塞在 NavigationStack 里的 .overlay）",
      code.contains("@ViewBuilder\n    private var clearCompletedMenuLayer: some View {"))
check("③ onClose / onPick 都会复位确认态（不留悬挂态）",
      code.contains("onClose: { confirmClearCompleted = false })")
        && code.contains("confirmClearCompleted = false\n") 
        && code.contains("if m.id == \"clear\" {"))

// ── ④ 实参序红线：实参序 = 声明序（本仓 CI 才查得出来）──
// 声明：AnchorMenuOverlay(anchorFrame:items:title:message:onPick:onClose:)
check("④ 实参序 = 声明序（anchorFrame → items → title → message → onPick → onClose）",
      code.contains("anchorFrame: clearAnchor == .zero ? fallback : clearAnchor,\n"
                    + "                              items: [")
        && code.contains("title: \"清理已完成的任务？\",\n"
                         + "                              message: \"已完成的任务会从列表移除，无法恢复。\",\n"
                         + "                              onPick: { m in"))

// ── ⑤ 反向：不许把确认退回「无确认」或「系统动作表」──
check("⑤🚫 不许无确认直删",
      !code.contains("store.clearCompleted()\n                    }")
        || code.contains("if m.id == \"clear\" {"))
check("⑤🚫 不许在注释外留下 confirmationDialog（剥注释后一处都不许有）",
      !code.contains("confirmationDialog"))

print("任务中心真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
