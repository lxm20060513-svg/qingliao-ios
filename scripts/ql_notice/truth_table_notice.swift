import Foundation

// 轻聊「阶段总结」标记 · 源码契约真值表（v4.0.112）
//
// 口径：Hermes 打满迭代上限时会额外请模型写一版**收尾总结**再交差，但这条总结在 wire 上
// 就是一段普通 assistant 文本 —— App 分不出它和「正常答完」，用户会把「我没跑完，先给你这些」
// 当成最终答案。故全链带一个标记，气泡上出「阶段总结」角标。
//
// 全链（缺任何一环都静默退化）：
//   Hermes `/v1/responses` 的 `hermes.budget_exhausted` 加法字段
//        （gateway/platforms/api_server_openai_routes.py 的 `_budget_handoff_note`）
//   → 后端 stream_api.py `st["notice"] = "budget"`（只记标记、不碰 content）
//   → 轮询体多一个 `notice` 键 → App 落库 / 读回 → 气泡出角标
//
// 为什么必须钉（都是**编译过、预检绿、只有真机能看出来**的退化）：
//   ① messagesPayload 漏写 notice → 落库没这个字段，杀 App 重进 / 切会话后这条没跑完的
//      总结又冒充「正常答完」（标记只在内存里活着；教训同 withdrawn / edited）。
//   ② 新一轮不清 notice → 上一轮打满上限的标记粘到下一轮的正常回答上（假警报）。
//   ③ 后台跑流器（App 不在前台时跑完的那条）漏带 → 后台回的消息永远没有标记。
//   ④ 角标视图写了但没挂进 normalBubbleBody → 编译过、预检绿、用户永远看不到。
//   ⑤ 气泡里硬编码 "budget" 字面量 → 取值真源分叉两份，后端换值只改一处。
//   ⑥ 注释版本号漂移（本批曾把 v4.0.112 写成 v4.0.121）→ 接手人按注释对版本，对不上。
//
// ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
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
/// 只留代码行（注释里提到 `notice` / `budget` 是说明，不该被计数）
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

/// a 在 b 之前（同为 -1 时判 false）
func orderedPair(_ src: String, _ a: String, _ b: String) -> Bool {
    guard let ra = src.range(of: a), let rb = src.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// ── 读取面 ──────────────────────────────────────────────────────
let noticeRaw = read("qingliao/Core/MessageNotice.swift")
let noticeSrc = codeOnly(noticeRaw)
let modelsRaw = read("qingliao/Core/Models.swift")
let modelsSrc = codeOnly(modelsRaw)
let storeSrc = codeOnly(read("qingliao/Core/ChatStore.swift"))
let authSrc = codeOnly(read("qingliao/Core/AuthStore.swift"))
let streamSrc = codeOnly(read("qingliao/Core/StreamClient.swift"))
let bgSrc = codeOnly(read("qingliao/Core/BackgroundStreamRunner.swift"))
let bubbleSrc = codeOnly(read("qingliao/Features/Chat/ChatMessageBubble.swift"))
let checkSrc = read("check_swift.sh")
let projSrc = read("project.yml")

// ── A. 源可读 + 切片哨兵 ────────────────────────────────────────
ck("MessageNotice.swift 源可读", !noticeSrc.isEmpty)
ck("Models.swift 源可读", !modelsSrc.isEmpty)
ck("ChatStore.swift 源可读", !storeSrc.isEmpty)
ck("AuthStore.swift 源可读", !authSrc.isEmpty)
ck("StreamClient.swift 源可读", !streamSrc.isEmpty)
ck("BackgroundStreamRunner.swift 源可读", !bgSrc.isEmpty)
ck("ChatMessageBubble.swift 源可读", !bubbleSrc.isEmpty)
let styleBody = closureBody(noticeSrc, "static func style(for notice: String?)")
ck("MessageNotice.style 切片取到（空了下面三条等于空真）", !styleBody.isEmpty && styleBody.count < 400)
let idBody = closureBody(modelsSrc, "var id: String")
ck("ChatMessage.id 切片取到", !idBody.isEmpty && idBody.count < 400)
let payloadBody = closureBody(storeSrc, "static func messagesPayload(")
ck("messagesPayload 切片取到", !payloadBody.isEmpty && payloadBody.count > 800)
let asPayloadBody = closureBody(modelsSrc, "func asPayload(")
ck("asPayload 切片取到", !asPayloadBody.isEmpty && asPayloadBody.count > 400)
let bubbleBody = closureBody(bubbleSrc, "private var normalBubbleBody")
ck("normalBubbleBody 切片取到", !bubbleBody.isEmpty && bubbleBody.count > 400)

// ── B. 纯逻辑真跑（把生产源编进来，不是 grep）────────────────────
ck("MessageNotice.budget 常量 = \"budget\"（与后端 st[\"notice\"] 取值域一致）", MessageNotice.budget == "budget")
ck("budget → 文案「阶段总结」", MessageNotice.style(for: "budget")?.label == "阶段总结",
   "实际 \(String(describing: MessageNotice.style(for: "budget")?.label))")
ck("budget → 色键 orange", MessageNotice.style(for: "budget")?.colorKey == "orange")
ck("nil → 不出角标（老后端零行为变化）", MessageNotice.style(for: nil) == nil)
ck("空串 → 不出角标（后端 st.get 兜底空串）", MessageNotice.style(for: "") == nil)
ck("未知取值 → 不出角标（将来后端加值只是暂时不显示，不会显示成错的）",
   MessageNotice.style(for: "some_future_value") == nil)

// ── C. 单一真源 + 模式匹配陷阱 ──────────────────────────────────
ck("MessageNotice 是纯逻辑（不 import SwiftUI，桌面端真值表可编）", !noticeSrc.contains("import SwiftUI"))
ck("取值比较用 if n == budget（switch 里 case 后裸标识符会被解析成值绑定模式 → 恒真）",
   styleBody.contains("if n == budget") && !styleBody.contains("switch "))
ck("气泡文件里不出现裸 \"budget\" 字面量（唯一真源在 MessageNotice）",
   hits(bubbleSrc, "\"budget\"") == 0, "命中 \(hits(bubbleSrc, "\"budget\"")) 次")

// ── D. Models：字段 / 读回 / 不进消息身份 / 不进模型上下文 ────────
ck("ChatMessage 声明 notice 字段", modelsSrc.contains("var notice: String?"))
ck("parse 读回 notice（重启后仍带标记）", modelsSrc.contains(#"msg.notice = d["notice"] as? String"#))
ck("notice 不进 id 计算（标记不是消息身份，进 id 会让翻转时重播插入动画）", !idBody.contains("notice"))
ck("notice 不进 asPayload（发回模型上下文没有意义）", !asPayloadBody.contains("notice"))

// ── E. ChatStore：形参 / 落内存 / 落库 ──────────────────────────
ck("upsertAssistant 声明 notice 形参（默认空串）", storeSrc.contains(#"notice: String = """#))
ck("两处落内存都带上标记", hits(storeSrc, "if !notice.isEmpty { m.notice = notice }") == 2,
   "命中 \(hits(storeSrc, "if !notice.isEmpty { m.notice = notice }")) 次")
ck("messagesPayload 写库带上 notice（不落库 = 重启后标记丢失）", storeSrc.contains(#"p["notice"] = nt"#))
ck("写库位置在 return 之前（不是写在死代码里）", orderedPair(payloadBody, #"p["notice"] = nt"#, "return p"))

// ── F. AuthStore：轮询解包 ──────────────────────────────────────
ck("streamPoll 解析后端 notice 键（老后端无此键 = 空串，优雅退化）",
   authSrc.contains(#"let notice = j["notice"] as? String ?? """#))
ck("streamPoll 返回元组末位带 notice（13 元组）", authSrc.contains("reasoning, notice)"))

// ── G. StreamClient：复位 / 只在变化时写入 ──────────────────────
ck("整轮 notice 属性在场", streamSrc.contains("var notice = \"\""))
let resetHits = hits(streamSrc, "notice = \"\"") - hits(streamSrc, "var notice = \"\"")
ck("开跑 + 移交两处都复位（防上一轮标记粘到下一轮）", resetHits == 2,
   "复位命中 \(resetHits) 次（已扣掉属性声明那处）")
ck("只在变化时写入（同 isAgent 口径，避免每轮 poll 触发无谓刷新）",
   streamSrc.contains("if !noticeIn.isEmpty, noticeIn != notice { notice = noticeIn }"))

// ── H. 后台跑流器：App 不在前台时跑完的那条也要带标记 ────────────
ck("后台解包 13 元组末位 noticeIn", bgSrc.contains("noticeIn"))
ck("透传给落库函数", bgSrc.contains("notice: noticeIn"))
ck("落库函数形参声明 notice", bgSrc.contains(#"notice: String = """#))
ck("后台落库带上标记", bgSrc.contains("if !notice.isEmpty { m2.notice = notice }"))

// ── I. 气泡角标：取值走真源 + 真挂上去了 ────────────────────────
ck("bubbleNoticeTag 视图在场", bubbleSrc.contains("private var bubbleNoticeTag: some View"))
ck("角标取值走 MessageNotice.style 单一真源（不自己判字符串）",
   bubbleSrc.contains("MessageNotice.style(for: message.notice)"))
ck("角标已挂进 normalBubbleBody（写了不挂 = 用户永远看不到）", bubbleBody.contains("bubbleNoticeTag"))
let tagBody = closureBody(bubbleSrc, "private var bubbleNoticeTag")
ck("角标切片取到", !tagBody.isEmpty && tagBody.count < 900)
ck("色键映射在 UI 层唯一映射点", bubbleSrc.contains("private func noticeTint("))

// ── I2. 落库边：`stream.notice` → 消息体（v4.0.112 审查收口新增）──────────
// 原表只读到 Core 层：**唯一的落地边没有任何护栏** —— `landAwayReply` 声明漏形参
//（调用点实参多一个，CI 直接编不过）、6 处 `upsertAssistant` / 4 处 `landAwayReply`
// 漏传 notice（切走·接回·续跑路径的角标静默丢失）都能在这张表下全绿通过。
// 注：`codeOnly` 剥掉行注释，负断言不受注释里贴的「错形态」干扰。
let cvSrc = codeOnly(read("qingliao/Features/Chat/ChatView.swift"))
let cveSrc = codeOnly(read("qingliao/Features/Chat/ChatViewExport.swift"))
ck("落库边哨兵：两边源都读到（空了下面几条全在空串上判绿）",
   cvSrc.count > 20000 && cveSrc.count > 2000)
ck("landAwayReply 形参带 notice（缺 = 调用点实参多一个，CI 直接炸）",
   cvSrc.contains("sid: String, title: String, notice: String)"))
ck("landAwayReply 的 notice **不给默认值**（默认值 = 漏传静默编过）",
   !cvSrc.contains("title: String, notice: String = "))
ck("landAwayReply 把 notice 写进消息体（只收形参不落 = 白传）",
   cvSrc.contains("if !notice.isEmpty { m.notice = notice }")
   && cvSrc.contains("chat.noteAwayLandedReply(sessionId: sid, text: text, notice: notice)"))
ck("负断言：landAwayReply 调用点不得漏传 notice",
   hits(cvSrc, ", title: startTitle)\n") == 0 && hits(cveSrc, ", title: startTitle)\n") == 0)
ck("负断言：upsertAssistant 落库不得漏传 notice（空回复提示 `afterUserID: msg.id` 除外）",
   hits(cvSrc, "afterUserID: anchor)") == 0
   && hits(cvSrc, "afterUserID: anchorUserID)") == 0
   && hits(cvSrc, "afterUserID: anchorID)") == 0
   && hits(cveSrc, "afterUserID: m.id)") == 0)
ck("移交账本带 notice（服务端写失败、靠内存补回那条也不能丢标记）",
   storeSrc.contains("awayLandedNotices[sid] = notice")
   && storeSrc.contains("awayLandedNotices.removeValue(forKey: sid)")
   && storeSrc.contains("if !notice.isEmpty { back.notice = notice }"))

// ── J. 版本号一致 + 注册 ────────────────────────────────────────
// v4.0.112（审查收口）：原断言只查「不含 v4.0.121」这一个字面量 —— 写成 v4.0.999 照样绿，
// 等于没钉。改成**真比较**：从 project.yml 取当前版本、算出本批目标版本，
// 新增文件里的注释版本只允许这两者之一（发版前=目标版，发版后=当前版）。
let curVer: String = {
    guard let r = projSrc.range(of: "MARKETING_VERSION: \"") else { return "" }
    let rest = projSrc[r.upperBound...]
    return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)])
}()
let nextVer: String = {
    var parts = curVer.split(separator: ".").map(String.init)
    guard parts.count == 3, let last = Int(parts[2]) else { return "" }
    parts[2] = String(last + 1)
    return parts.joined(separator: ".")
}()
ck("哨兵：project.yml 版本可解析（防止下面两条在空串上判绿）",
   !curVer.isEmpty && !nextVer.isEmpty && curVer != nextVer)
let noticeVers = Set(noticeRaw.split(separator: "\n").compactMap { line -> String? in
    guard let r = line.range(of: "v4.0.1") else { return nil }
    return String(line[r.lowerBound...].prefix(8))
})
// v4.0.114（假红收口）：原写法白名单 = {当前版, 本批目标版}，只在「本批新增、且 project.yml 还没 bump」
// 这一种时序下成立。**上批新增的文件**（MessageNotice 自己写的是 v4.0.112）一旦 bump 就必红，
// 与它有没有写错毫无关系 —— 纯假红，且每次 bump 都会复发。
// 改成**真比较**：注释版本号必须是已发布过的真实号（≤ 当前版）；未来号（v4.0.999 / v4.0.121）照样红。
// 解析失败的串（如 v4.0.1x）由 count 相等这条挡住，不许被 compactMap 悄悄丢掉后误绿。
let noticeVerNums = Set(noticeVers.compactMap { v -> Int? in
    guard v.hasPrefix("v4.0.") else { return nil }
    return Int(v.dropFirst(5))
})
let curMinor = Int(String(curVer.split(separator: ".").last ?? "")) ?? 0
ck("MessageNotice 注释里的版本号必须是已发布过的真实号（≤ 当前版 v\(curVer)），不得写未来号"
   + "（旧断言只查「不含 v4.0.121」= 写成 v4.0.999 照样绿）",
   !noticeVers.isEmpty && noticeVerNums.count == noticeVers.count
   && noticeVerNums.allSatisfy { $0 <= curMinor })
ck("负断言：错的 v4.0.121 不得在本批源里复活",
   !noticeRaw.contains("v4.0.121") && !modelsRaw.contains("v4.0.121")
   && !streamSrc.contains("v4.0.121") && !bgSrc.contains("v4.0.121") && !storeSrc.contains("v4.0.121"))
ck("check_swift.sh 引用了 scripts/ql_notice/", checkSrc.contains("scripts/ql_notice/"))
ck("check_swift.sh 有 §103 段标题", checkSrc.contains("103.") && checkSrc.contains("阶段总结"))

print("—— 源级表：\(pass) 通过 / \(fail) 失败 ——")
if fail > 0 { exit(1) }
