// MARK: - v4.0.x AI 思考/回复中不出现上拉指示器 · 真值表（源护栏）
//
// 用户实测（2026-09-28 截图）：「AI思考回復過程中這個指示不要出現」——AI 正在回复
// （截图里是「21 步工具调用」正下方），底部仍浮着「上拉拉取推送」胶囊。
//
// 病根两处（都在 Features/Chat/InboxPullRefresh.swift）：
//   ① 挡板口径太窄：v3.9.41 只拦 `thisSessionStreaming`（本会话本地流），而**思考阶段**
//      （`remoteBusy` 服务器兜底探测已为真、本地流还没起来）不在这条判定里 → 照样能拉出胶囊；
//   ② 残留清不掉：胶囊由进度驱动（`progress >= 0.04` 就显示）。「先上拉出胶囊、AI 才开始回答」
//      的场景下，AI 忙时列表自动滚底、滚动投影恒为 0，`onScrollGeometryChange` 一次都不回调 →
//      **任何写在滚动回调里的清理都执行不到**，胶囊一直挂着。
//
// 定案：挡板换成 `aiBusy`（= thisSessionStreaming || remoteBusy，与「AI 正在输入」同一真值源，
//      也避免两处各写一份组合式日后漂移）；残留由 `.onChange(of: aiBusy)` 驱动的
//      `inboxPullReset()` 清。本表钉住这套结构，防「下次重构删了照样全绿」。
//
// 用法：./check_swift.sh 第 46 步

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) else { return "" }
    return s
}
/// 去注释行：源码里提到历史形态（本例不可避免要写「原来只认 thisSessionStreaming」）不算违规
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
/// 取 from..to 之间源码（切片失败返回空串，由「能切到」断言抓出，不让后续断言白写）
func slice(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from),
          let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.lowerBound..<b.lowerBound])
}

let pullSrc = src("Features/Chat/InboxPullRefresh.swift")
let chatViewSrc = src("Features/Chat/ChatView.swift")

// ── ① 源护栏：非空（路径别改，改了下面全是假绿）──────────────────────
check("v4.0.x·能读到 InboxPullRefresh.swift 源码", !pullSrc.isEmpty)
check("v4.0.x·能读到 ChatView.swift 源码", !chatViewSrc.isEmpty)

// ── ② 切片（注释里也有这些字样 → 断言一律用剥注释后的切片）────────────
let handleCode = stripComments(slice(pullSrc, from: "func inboxPullHandleScroll", to: "/// 上拉满格后松手"))
let resetCode  = stripComments(slice(pullSrc, from: "func inboxPullReset", to: "/// ScrollView.onScrollGeometryChange"))
let aiBusyCode = stripComments(slice(chatViewSrc, from: "var aiBusy: Bool {", to: "}"))
let chatCode   = stripComments(chatViewSrc)
// 「复位调用挂在哪一层」必须切片看：早先只断言全仓出现过 `.onChange(of: aiBusy)` + `inboxPullReset()`，
// 而 2519 行那个既有的 aiBusy 观察者就能满足前半条 —— 把复位整段删掉护栏仍然全绿（审查指出的假绿）。
let busyWindow = chatCode.range(of: ".onChange(of: aiBusy, initial: true)")
    .map { String(chatCode[$0.lowerBound...].prefix(600)) } ?? ""
let aiBusyObserverCount = chatCode.components(separatedBy: ".onChange(of: aiBusy").count - 1
let triggerCode = stripComments(slice(pullSrc, from: "private func triggerInboxPull", to: "inbox.pollOnce()"))

check("v4.0.x·能切到 inboxPullHandleScroll 函数体（切不到下面几条就是白写）", !handleCode.isEmpty)
check("v4.0.x·能切到 inboxPullReset 函数体（切不到下面几条就是白写）", !resetCode.isEmpty)
check("v4.0.x·能切到 aiBusy 定义体（切不到下面几条就是白写）", !aiBusyCode.isEmpty)

// ── ③ 挡板口径：AI 忙（含思考阶段）就不许上拉 ──────────────────────
check("v4.0.x·挡板用 aiBusy（覆盖思考阶段的 remoteBusy 探测，用户实测的漏洞就在这）",
      handleCode.contains("guard !st.refreshing, !aiBusy, !selectMode else { return }"))
check("v4.0.x·挡板不再只认 thisSessionStreaming（防回退成窄口径）",
      !handleCode.contains("thisSessionStreaming"))
check("v4.0.x·aiBusy 真值源仍是「本地流 + 服务器兜底探测」（与「AI 正在输入」同口径，不许漂移）",
      aiBusyCode.contains("thisSessionStreaming || remoteBusy"))
check("v4.0.x·aiBusy 必须 internal（带 private 则 InboxPullRefresh 读不到 → 编译挂）",
      aiBusyCode.contains("var aiBusy") && !aiBusyCode.contains("private var aiBusy"))
check("v4.0.x·aiBusy 按会话收窄（thisSessionStreaming 里带 currentStreamSessionId，不是全局流）",
      stripComments(slice(chatViewSrc, from: "var thisSessionStreaming: Bool {", to: "}"))
          .contains("auth.currentStreamSessionId == chat.sessionId"))

// ── ④ 残留清理：必须由 aiBusy 变化驱动，不能写在滚动回调里 ──────────────
check("v4.0.x·reset 清 progress（否则胶囊继续按 ≥ 0.04 显示）", resetCode.contains("st.progress = 0"))
check("v4.0.x·reset 清 armed（拉满待触发状态也得复位，不然回弹时会误触发拉取）",
      resetCode.contains("st.armed = false"))
check("v4.0.x·reset 带「同值不写」护栏（Observation 写同值也标脏 InboxPullLayer）",
      resetCode.contains("guard st.progress != 0 || st.armed else { return }"))
check("v4.0.x·清理不许写在滚动回调里（AI 忙时投影恒 0、回调不触发 → 等于没写）",
      !handleCode.contains("st.progress = 0"))
check("v4.0.x·复位调用就在视图级 aiBusy 观察者闭包内（挂内层 ScrollView 会在欢迎态/清空态卸载时漏复位，残留进度还会被跨会话带走）",
      busyWindow.contains("inboxPullReset()"))
check("v4.0.x·全仓只有一处 aiBusy 观察者（重复挂载会各清一遍，内层那处还会随 ScrollView 卸载）",
      aiBusyObserverCount == 1)

// ── ④b 拉取成功那条路自己也要收进度（用户实测最主要的来路）────────────────
// 只清 armed 的话：本帧刚写下的 progress（≈0.49）从此无人再动 —— refreshing 期间 122 行早退
// 吃掉全部回弹回调，拉取结束只淡出 toast，于是 68 行 `progress >= 0.04` 重新命中，
// 胶囊在 toast 消失后自己浮出来并常驻（两路只读审查独立指为最高优先）。
check("v4.0.x·能切到 triggerInboxPull 函数体（切不到下面两条就是白写）", !triggerCode.isEmpty)
check("v4.0.x·拉取一开始就收起进度（不只清 armed）",
      triggerCode.contains("if st.progress != 0 { st.progress = 0 }"))

// ── ⑤ 指示器本体未被误删（要的是「AI 忙时不出现」，不是砍掉这个功能）──────
check("v4.0.x·指示器渲染条件仍在（progress ≥ 0.04）", stripComments(pullSrc).contains("state.progress >= 0.04"))
check("v4.0.x·上拉阈值/触发链路仍在（拉满松手 → triggerInboxPull）",
      stripComments(pullSrc).contains("InboxPullState.threshold") && pullSrc.contains("func triggerInboxPull"))

print("上拉指示器挡板真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
