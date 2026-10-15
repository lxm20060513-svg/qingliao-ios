// v4.1.x 插话（暂停-恢复）真值表 —— Linux 本地预检用，纯 Foundation，无 UI 依赖
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 第 104 段）：
//   ./check_swift.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_interject \
//       scripts/ql_interject/truth_table_interject.swift qingliao/Core/InterjectPolicy.swift
//
// 本表钉死的口径（都是「漏一条就静默坏掉」的地方）：
//   ① 只能插**本会话**那条流（插别的会话 = 掐掉别人正在等的回答）；无主流（taskId 空）不许插；
//   ② 插话起流失败 → **退排队**（消息一条都不能丢）；已起来后中途失败 → 不许退排队（否则同一句发两遍）；
//   ③ 状态行只写本机确知的事（父流 id 是 App 自己写的），普通流不许冒出插话状态行，
//      「已完成 0 步」不许显示假进度；
//   ④ ⚡键无文字不许可点；
//   ⑤ 接线形态：ChatInputBar 声明序 == ChatView 实参序（实参序错在本地查不出、CI 才炸）；
//   ⑥ 轮询元组**三处元数必须一致**（AuthStore 返回 / StreamClient 解包 / 后台跑流器解包）——
//      这次从 13 元长到 17 元，漏改任何一处都是编译错或静默串位；
//   ⑦ 老路径零改动：不点 ⚡ 的排队链路与 PendingSend 持久化形态逐字不变。
//   反例占本表约三分之一。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

/// 剥注释后的源码（断言钉的是**代码**不是注释；与其余真值表同口径）。
/// 逐字符扫描，而不是逐行替换：注释里出现 `/api/auth/*` 这种串时，天真实现会把 `/*`
/// 当成块注释开始，把后面几百行代码**整段吃掉**（本仓可真踩过：断言全红，看着像代码没了）。
/// 字符串字面量内不认注释（否则 "http://..." 会被 `//` 截断）。
func src(_ path: String) -> String {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
    let cs = Array(raw)
    var out = ""
    var i = 0
    var inBlock = false, inLine = false, inStr = false, escaped = false
    while i < cs.count {
        let c = cs[i]
        let n: Character? = i + 1 < cs.count ? cs[i + 1] : nil
        if inLine { if c == "\n" { inLine = false; out.append(c) }; i += 1; continue }
        if inBlock { if c == "*", n == "/" { inBlock = false; i += 2; continue }; i += 1; continue }
        if inStr {
            out.append(c)
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inStr = false }
            i += 1; continue
        }
        if c == "\"" { inStr = true; out.append(c); i += 1; continue }
        if c == "/", n == "/" { inLine = true; i += 2; continue }
        if c == "/", n == "*" { inBlock = true; i += 2; continue }
        out.append(c); i += 1
    }
    return out
}

/// 取 a…b 之间的第一段（找不到返回 nil）
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let ra = s.range(of: a) else { return nil }
    let rest = s[ra.upperBound...]
    guard let rb = rest.range(of: b) else { return nil }
    return String(rest[rest.startIndex..<rb.lowerBound])
}

/// 元组元素个数（按顶层逗号切；元素里没有嵌套括号/逗号）
func tupleArity(_ inner: String) -> Int {
    let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return 0 }
    return t.components(separatedBy: ",").count
}

/// 「续接段」元素数：从某个前导元素之后接下去的部分（首段常为空，不计）
func tailArity(_ inner: String) -> Int {
    inner.components(separatedBy: ",")
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .count
}

// ⚠️ 不要用 `@main`：本文件被 check_swift.sh 复制成 /tmp/ql_ij_main/main.swift 编译，
// 而 main.swift 里**本来就有顶层代码**（全局计数器 + 末尾调用）——`@main` 与顶层代码不能共存
// （Swift 6 实测：'main' attribute cannot be used in a module that contains top-level code）。
// 顶层直接调用即可，两种编法（单文件 / main.swift + InterjectPolicy）都成立。
struct InterjectTruthTable {

    static func runAllTests() {
        // ── 1. 能不能插（InterjectPolicy.canInterject，真跑） ──
        positives += 1
        check("正常：本会话在跑 + 有 taskId → 可插",
              InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                           streamSessionId: "sA", currentSessionId: "sA", pausePending: false))
        negatives += 1
        check("反例：没在跑流 → 不可插（没父流可暂停，走普通发送）",
              !InterjectPolicy.canInterject(isStreaming: false, taskId: "t123",
                                            streamSessionId: "sA", currentSessionId: "sA", pausePending: false))
        negatives += 1
        check("反例：在跑但 taskId 空（无主流）→ 不可插（硬发只会换 400）",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "",
                                            streamSessionId: "sA", currentSessionId: "sA", pausePending: false))
        negatives += 1
        check("反例：跑的是**别的会话**的流 → 不可插（插它 = 掐掉别人正在等的回答）",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                            streamSessionId: "sB", currentSessionId: "sA", pausePending: false))
        negatives += 1
        check("反例：拿不到流归属会话（空串）→ 不可插",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                            streamSessionId: "", currentSessionId: "sA", pausePending: false))
        negatives += 1
        check("反例：当前会话未就绪（空串）→ 不可插",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                            streamSessionId: "sA", currentSessionId: "", pausePending: false))
        negatives += 1
        check("反例：两边都空不许当「相等」放行",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t",
                                            streamSessionId: "", currentSessionId: "", pausePending: false))
        // ── 1′. v4.0.115 审查 P1：后端暂停栈只有 1 层，二次插话必须拦住 ──
        negatives += 1
        check("反例：已有一条父流在等服务端接回（pausePending）→ 不可插",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                            streamSessionId: "sA", currentSessionId: "sA",
                                            pausePending: true))
        negatives += 1
        check("反例：pausePending 优先级最高 —— 连「本来完全可插」的组合也要挡住",
              !InterjectPolicy.canInterject(isStreaming: true, taskId: "t", streamSessionId: "s",
                                            currentSessionId: "s", pausePending: true))
        positives += 1
        check("正例：本会话在跑 + 有 taskId + 没有待接回的父流 → 可插（本 rc 的常规路径）",
              InterjectPolicy.canInterject(isStreaming: true, taskId: "t123",
                                           streamSessionId: "sA", currentSessionId: "sA",
                                           pausePending: false))

        // ── 2. 起流失败要不要退排队（消息一条都不许丢） ──
        positives += 1
        check("插话没起来（无 taskId）→ 退排队",
              InterjectPolicy.shouldFallbackToQueue(isInterject: true, started: false))
        negatives += 1
        check("反例：插话**已起来**后中途失败 → 不退排队（否则同一句被再排一遍 = 重发）",
              !InterjectPolicy.shouldFallbackToQueue(isInterject: true, started: true))
        negatives += 1
        check("反例：普通发送起流失败 → 不走插话退排队（老路径照旧落错误/重试）",
              !InterjectPolicy.shouldFallbackToQueue(isInterject: false, started: false))

        // ── 3. 状态行文案（不许报不实状态 / 不许显示假进度） ──
        positives += 1
        check("插话中：带步数",
              InterjectPolicy.note(streaming: true, pausedParentTaskId: "p1", pausedParentStep: 3)
                == "原回答已暂停（已完成 3 步）· 插话中")
        positives += 1
        check("插话中：步数 0 → 不写「已完成 0 步」（宁可不写也不报假进度）",
              InterjectPolicy.note(streaming: true, pausedParentTaskId: "p1", pausedParentStep: 0)
                == "原回答已暂停 · 插话中")
        negatives += 1
        check("反例：普通流（没有父流 id）→ 不出插话状态行",
              InterjectPolicy.note(streaming: true, pausedParentTaskId: "", pausedParentStep: 2).isEmpty)
        negatives += 1
        check("反例：插话流已收尾（没在跑）→ 状态行消失",
              InterjectPolicy.note(streaming: false, pausedParentTaskId: "p1", pausedParentStep: 3).isEmpty)
        negatives += 1
        check("反例：没在跑也没父流 → 空串（常态输入栏零变化）",
              InterjectPolicy.note(streaming: false, pausedParentTaskId: "", pausedParentStep: 0).isEmpty)

        // ── 4. ⚡键可点判据 ──
        positives += 1
        check("有文字 → 可点", InterjectPolicy.canTapBolt(text: "先回答我这个"))
        negatives += 1
        check("反例：纯空格 → 不可点", !InterjectPolicy.canTapBolt(text: "   "))
        negatives += 1
        check("反例：空串 → 不可点", !InterjectPolicy.canTapBolt(text: ""))
        negatives += 1
        check("反例：换行/制表（trim 后为空）→ 不可点", !InterjectPolicy.canTapBolt(text: "\n\t "))

        // ── 5. 接线形态（源级断言，剥注释） ──
        let bar = src("qingliao/Features/Chat/ChatInputBar.swift")
        let chat = src("qingliao/Features/Chat/ChatView.swift")
        let client = src("qingliao/Core/StreamClient.swift")
        let auth = src("qingliao/Core/AuthStore.swift")
        let runner = src("qingliao/Core/BackgroundStreamRunner.swift")

        positives += 1
        check("前置哨兵：五个源文件都读到了（cwd 必须 = 仓库根）",
              !bar.isEmpty && !chat.isEmpty && !client.isEmpty && !auth.isEmpty && !runner.isEmpty)

        // 5.1 声明序 == 实参序（swiftui-param-order：本地查不出，CI 才炸）
        if let dSend = bar.range(of: "var onSend: () -> Void"),
           let dStop = bar.range(of: "var onStop: () -> Void"),
           let dIj = bar.range(of: "var onInterject: (() -> Void)?"),
           let dNote = bar.range(of: "var interjectNote: String"),
           let dPick = bar.range(of: "var onPickAttachment: () -> Void") {
            positives += 1
            check("声明序：onSend < onStop < onInterject < interjectNote < onPickAttachment",
                  dSend.lowerBound < dStop.lowerBound && dStop.lowerBound < dIj.lowerBound
                  && dIj.lowerBound < dNote.lowerBound && dNote.lowerBound < dPick.lowerBound)
        } else {
            check("声明序：五个声明都在（缺一个 = 调用点必然对不上）", false)
        }
        if let aSend = chat.range(of: "onSend: { send() }"),
           let aStop = chat.range(of: "onStop: {"),
           // v4.0.115：⚡键的注入点从裸闭包改成 canInterjectNow（= InterjectPolicy）门控后的三元表达式
           let aIj = chat.range(of: "onInterject: canInterjectNow ? { send(interject: true) } : nil"),
           let aNote = chat.range(of: "interjectNote: interjectNote,"),
           let aPick = chat.range(of: "onPickAttachment: {") {
            positives += 1
            check("实参序：onSend < onStop < onInterject < interjectNote < onPickAttachment（与声明同序）",
                  aSend.lowerBound < aStop.lowerBound && aStop.lowerBound < aIj.lowerBound
                  && aIj.lowerBound < aNote.lowerBound && aNote.lowerBound < aPick.lowerBound)
        } else {
            check("实参序：五个实参都在（缺/改名 = CI 编译期才报）", false)
        }

        // 5.2 传输层：真命中新端点（两个路径都钉）
        positives += 1
        check("AuthStore：Wi-Fi 直连打 /api/stream/interject", auth.contains("\"/api/stream/interject\""))
        positives += 1
        check("AuthStore：蜂窝 relay 打 /r/stream/interject/{uid}（与后端 _RELAY_OPS 对齐）",
              auth.contains("\"/r/stream/interject/\\(uid)\""))
        positives += 1
        check("AuthStore：带 pausedTaskId（不带它 = 后端起一条普通流，父流根本没暂停）",
              auth.contains("\"pausedTaskId\": pausedTaskId"))
        positives += 1
        check("AuthStore：401 仍走统一收敛点（token 过期不能被当普通失败退避）",
              auth.contains("markSessionExpired()") && auth.contains("throw APIError.unauthorized"))
        positives += 1
        check("StreamClient：插话走「接管已起好的流」（HTTP 不在这里发）",
              client.contains("struct InterjectHandoff")
              && client.contains("interject: InterjectHandoff? = nil")
              && client.contains("tid = ij.childTaskId"))
        positives += 1
        check("ChatView：**先 HTTP 起流、成功了才动单例**（失败路径不碰父流的轮询与正文）",
              chat.contains("var handoff: StreamClient.InterjectHandoff? = nil")
              && chat.contains("try await auth.streamInterject(pausedTaskId: parent")
              && chat.contains("interject: handoff"))
        positives += 1
        check("ChatView：插话起流失败 → 释放发送锁 + 退排队（不落错误气泡）",
              chat.contains("if InterjectPolicy.shouldFallbackToQueue(isInterject: true, started: false) {")
              && chat.contains("sendingLock = false"))
        positives += 1
        check("ChatView：父流 id 一路传下去（⚡ → 发送 → 起流；断一处 = 起条普通流，父流根本没暂停）",
              chat.contains("private func interjectSendCore(")
              && chat.contains("startStream(for: msg, interjectPausedTaskId: parent)")
              && chat.contains("func startStream(for msg: ChatMessage, interjectPausedTaskId: String? = nil)")
              && chat.contains("if let parent = interjectPausedTaskId {"))
        positives += 1
        check("StreamClient：start 复位时清空 taskId（「起来没起来」的判据真源）",
              client.contains("taskId = \"\""))
        positives += 1
        check("StreamClient：start 返回是否接管（@discardableResult，老调用点不受影响）",
              client.contains("@discardableResult") && client.contains("async -> Bool {"))
        positives += 1
        check("StreamClient：解析 paused / pausedBy / pausedResumeOf / resumedChild 四键",
              client.contains("if pausedIn != isPausedStream { isPausedStream = pausedIn }")
              && client.contains("if resumedChildIn != resumedChild { resumedChild = resumedChildIn }"))
        positives += 1
        check("AuthStore：轮询体解出四个新键（老后端无键 → 默认值 = 与改动前同行为）",
              auth.contains("j[\"paused\"] as? Bool ?? false")
              && auth.contains("j[\"resumedChild\"] as? String ?? \"\""))

        // 5.3 轮询元组三处元数一致（13 → 17 这次改动最容易漏的地方）
        // 前导 7 元 / 6 元被锚点吃掉，故用 tailArity 只数续接段
        if let ret = between(auth, "func streamPoll(taskId: String, offset: Int) async throws -> (", ") {"),
           let once = between(client, "let (c, done, st, err, agent, piggyback, toolsIn", ") = try await auth.streamPoll("),
           let run = between(runner, "let (c, done, st, err, agent, piggyback,", ") =\n") {
            let a = tupleArity(ret), b = 7 + tailArity(once), c = 6 + tailArity(run)
            positives += 1
            check("元组元数三处一致：AuthStore=\(a) / StreamClient 解包=\(b) / 后台跑流器解包=\(c)", a == b && b == c)
            positives += 1
            check("元组元数 = 17（13 旧键 + 4 插话键）", a == 17)
        } else {
            check("元组元数：三处都取到了", false)
        }

        // 5.4 老路径零改动
        positives += 1
        check("排队老路仍在：sendCore 里排队分支逐字未动",
              chat.contains("pendingQueue.append(PendingSend(text: text, imageData: imageData, sessionId: chat.sessionId))"))
        positives += 1
        check("记账闸不破：用户亲手发送的两条 sendCore 行仍是原文（allowExpense: true，含第 31 段那条）",
              chat.contains("sendCore(text: text, imageData: nil, quotedText: quotedText, allowExpense: true)"))
        positives += 1
        check("PendingSend 未加字段（插话不进队列 → 零 Codable 迁移风险）",
              src("qingliao/Features/Chat/ChatPendingSend.swift").contains("case text, imageData, sessionId"))
        positives += 1
        check("插话起不来时不落错误气泡：走 interjectFallbackToQueue（补排队标记 + 落盘）",
              chat.contains("private func interjectFallbackToQueue(")
              && chat.contains("chat.messages[idx].queued = true")
              && chat.contains("persistPendingQueue()"))
        negatives += 1
        check("反例：⚡键不许出现在「不在跑流」的时候（按钮判据绑 streaming）",
              bar.contains("if streaming, let onInterject {"))

        // ── 7. v4.0.115（发包前审查闭环）：三条会把用户蒙在鼓里的静默路径 ──
        positives += 1
        check("单一真源收口：⚡键的出现条件 = 发送判据同源（canInterjectNow 走 InterjectPolicy；不满足传 nil → `if streaming, let onInterject` 不渲染）",
              chat.contains("private var canInterjectNow: Bool")
              && chat.contains("InterjectPolicy.canInterject(isStreaming: thisSessionStreaming,")
              && chat.contains("onInterject: canInterjectNow ? { send(interject: true) } : nil"))
        positives += 1
        check("插话起流失败 → 把父流的落库锚点还回去（不许拿没起流的消息顶掉 pendingUserMsgId）",
              chat.contains("let prevPendingUserMsgId = stream.pendingUserMsgId")
              && chat.contains("stream.pendingUserMsgId = prevPendingUserMsgId"))
        positives += 1
        let fbTail = chat.components(separatedBy: "private func interjectFallbackToQueue(").last ?? ""
        check("插话退排队后补一次泵（HTTP 超时 25~30s 窗口里父流收尾 → 否则这条永久「排队中」）",
              fbTail.prefix(1200).contains("pumpPendingQueue()"))
        positives += 1
        check("单一真源收口：canInterject 声明里有 pausePending 判据（后端暂停栈只有 1 层）",
              src("qingliao/Core/InterjectPolicy.swift").contains("guard !pausePending else { return false }"))

        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 三分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 3.0)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }

}

InterjectTruthTable.runAllTests()
