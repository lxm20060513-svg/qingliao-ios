// MARK: - v3.9.76 入口行为真值表（会话点击 / 相机呈现）
//
// 事故背景（2026-09-25 用户真机逐条反馈——两条都是 v3.9.75 改动的**反向**）：
//   ①「从轻聊投递会话点进去应该跳到会话内容看到投递信息详情，而不是跳到任务中心」
//      v3.9.75 按标题把 qingliao_delivery 特判成开任务中心，用户实测直接否掉。
//   ②「系统相机顶部有黑边」
//      v3.9.75 只把 .sheet 换成 .fullScreenCover —— 不够。fullScreenCover 的内容视图默认
//      被约束在安全区内，UIImagePickerController 的取景层只铺满那个内缩矩形，
//      顶部状态栏高度（≈59pt）露出的仍是宿主黑底；相机 App 本身是全屏取景，要对齐它。
//
// 定稿口径（本表逐条钉死）：
//   ① 会话列表 open(_:) 是**唯一**进会话入口，不许按标题/内容做特殊分流；
//      任务中心有它自己的常驻入口（聊天页 header 的 showTaskCenter），不在会话列表。
//   ② CameraPicker 以 fullScreenCover 呈现时内容必须 .ignoresSafeArea()（全屏取景）。
//
// 用法（必须在仓库根跑，表内用相对路径读源）：./check_swift.sh 第 17 步，
// 或 python3 /opt/data/scripts/ql.py test（cwd 已钉死到 iOS 仓）。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1; print("✅ " + name) } else { failCount += 1; print("❌ " + name) }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { return "" }
    return s
}

/// 取 a、b 之间的片段 —— 排除式断言一律在切片内做，避免整文件级假红/假绿
/// （注释里提到旧符号名是常态，整文件 `!contains("旧名")` 必被自己的版本叙述绊红）。
/// 排除式断言先去注释：本仓已两次被「注释里写着旧写法」绊成假绿/假红（与 ql_orbmenu 表同口径）。
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a) else { return "" }
    guard let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.lowerBound..<r2.lowerBound])
}

/// 双引号字符（避免在断言的字符串字面量里写转义 —— patch 类编辑工具会弄坏反斜杠转义）
let Q = String(UnicodeScalar(34))

let sess = src("Features/Sessions/SessionsView.swift")
let chat = src("Features/Chat/ChatView.swift")
let chatStore = src("Core/ChatStore.swift")
let inbox = src("Core/InboxStore.swift")

// —— 哨兵：源读不到 → 整表假绿，必须先报红 ——
check("源文件可读（SessionsView / ChatView / ChatStore / InboxStore）",
      !sess.isEmpty && !chat.isEmpty && !chatStore.isEmpty && !inbox.isEmpty)

// —— ① 会话列表：不许按标题特判「投递」，也不许在这里开任务中心 ——
// 断言用「声明/调用形态」串，不用裸符号名（注释里叙述旧名不算回退）。
// ⚠️ 改成**裸标识串 + 剥注释**：原来钉 `private var showTaskCenter` 这种「声明形态串」，
//    改个名（showTaskCenterSheet）或把调用塞进别的分支就能让分流回归而表保持全绿。
let sessClean = stripCommentLines(sess)
check("SessionsView 无投递会话特判（isDeliverySession 已清零）",
      !sessClean.contains("isDeliverySession"))
check("SessionsView 无任务中心 state（showTaskCenter 已清零）",
      !sessClean.contains("showTaskCenter"))
check("SessionsView 不再 present 任务中心（TaskCenterView 已清零）",
      !sessClean.contains("TaskCenterView"))

let openBody = between(sess, "private func open(_ s: ChatSession) {", "@ViewBuilder")
check("open(_:) 函数体切片取到（锚点没改名）", !openBody.isEmpty)
check("open(_:) 三步齐：markRead → load → 切 tab（投递会话也走这一条）",
      openBody.contains("chat.markRead(s.id)")
      && openBody.contains("chat.load(s)")
      && openBody.contains("onOpenSession?()"))
check("open(_:) 里没有任何提前 return 的特殊分流",
      !openBody.contains("showTaskCenter = true") && !openBody.contains("TaskCenterView()"))

// —— ② 相机：fullScreenCover 的内容必须忽略安全区 ——
let camSlice = between(chat, ".fullScreenCover(isPresented: $showCameraPicker)", "// v2.0.43")
check("ChatView 相机呈现切片取到", !camSlice.isEmpty)
check("相机仍以 fullScreenCover 呈现（没退回 .sheet）",
      chat.contains(".fullScreenCover(isPresented: $showCameraPicker)"))
check("旧形态清零：相机不再挂 .sheet(isPresented: $showCameraPicker)",
      !chat.contains(".sheet(isPresented: $showCameraPicker)"))
check("相机内容带 .ignoresSafeArea()（顶部黑边根因——缺它就露状态栏高度黑底）",
      camSlice.contains(".ignoresSafeArea()"))

// —— ③ 投递壳不混普通 AI 推送（v3.9.76 第三条用户反馈） ——
// 后端 `inbox_api.push` 只把 cron/system 写进固定会话（刻意排除 reply/progress）；
// 混入源在 App：consumeOne 把 progress/reply 无条件注入「当前会话」，而当时开着的正是投递壳。
check("投递会话判据是 ChatStore 的 id 常量（与后端 DELIVERY_SESSION_ID 同源）",
      chatStore.contains("static let deliverySessionId = " + Q + "qingliao_delivery" + Q))
check("投递会话判据用 id 比较，不用标题匹配",
      chatStore.contains("var isDeliverySession: Bool { sessionId == Self.deliverySessionId }"))

let consume = between(inbox, "private func consumeOne(", "/// v3.0.88 fix")
check("consumeOne 切片取到（锚点没改名）", !consume.isEmpty)
check("闸门存在：当前会话是投递壳时先分流，不注入推送气泡",
      consume.contains("if chat.isDeliverySession, taskType == " + Q + "reply" + Q + " || taskType == " + Q + "progress" + Q))
check("闸门只拦 reply/progress —— cron/system 仍走任务中心分支（别把投递详情也拦掉）",
      consume.contains("taskType == " + Q + "reply" + Q + " || taskType == " + Q + "progress" + Q)
      && consume.contains("TaskCenterStore.shared.add("))
// 顺序断言：闸门必须排在 progress 注入分支**之前**，否则残片照旧落进投递壳
check("闸门排在 progress 注入分支之前",
      { () -> Bool in
          guard let g = consume.range(of: "if chat.isDeliverySession"),
                let p = consume.range(of: "if taskType == " + Q + "progress" + Q) else { return false }
          return g.lowerBound < p.lowerBound
      }())
check("InboxStore 不用标题判投递（旧形态清零）", !inbox.contains("title.contains"))

// —— ④ 智慧球长按菜单：胶囊点一次就中（v3.9.76 第四条用户反馈） ——
// 用户原话：「长按智慧球触发的胶囊，点击胶囊有时候要点击好几次才跳转功能」。
// 根因：onTapGesture 原来挂在**与位移动画同一个视图**上 —— 入场弹簧错峰后约 0.6s 才落定，
//      期间 SwiftUI 的命中测试跟着布局动画走（点到的是"途中的位置"）→ 前几次点击必然落空；
//      且 `.glassEffect(.regular.interactive())` 自带交互识别器挂在同一视图，也可能吃掉第一次点击。
// 口径：**视觉层一律不吃事件 + 命中层位置固定在终态、不参与任何位移动画** + 首次点击即锁定防连点。
let menu = src("Features/OrbQuickMenu.swift")
check("OrbQuickMenu 源可读（路径别改）", !menu.isEmpty)
let orbVisual = between(menu, "private func pillVisual(", "private func pillHitArea(")
let orbHit = between(menu, "private func pillHitArea(", "private func dismissAnimated")
check("视觉层 / 命中层两段切片都取到（锚点没改名）", !orbVisual.isEmpty && !orbHit.isEmpty)
check("视觉层不许吃事件（allowsHitTesting(false)）", orbVisual.contains(".allowsHitTesting(false)"))
check("视觉层不许再挂点击手势（旧形态清零）", !orbVisual.contains(".onTapGesture"))
check("命中层位置固定：position(p)，不得跟着 shown 漂移",
      orbHit.contains(".position(p)") && !orbHit.contains("shown"))
check("命中层挂点击手势", orbHit.contains(".onTapGesture"))
check("命中层有防连点锁（第一次点击后锁定，动作只执行一次）",
      orbHit.contains("guard !activated else { return }") && orbHit.contains("activated = true"))

// —— 任务中心的常驻入口仍要在聊天页（别顺手删干净） ——
check("聊天页仍保留任务中心入口（header 常驻 showTaskCenter → TaskCenterView）",
      chat.contains("showTaskCenter = true") && chat.contains("TaskCenterView()"))

print("入口行为真值表：" + String(passCount) + " 通过 / " + String(failCount) + " 失败")
if failCount > 0 { exit(1) }
