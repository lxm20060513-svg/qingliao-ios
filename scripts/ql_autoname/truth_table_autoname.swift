// MARK: - v3.9.90 会话自动命名 · 真值表（单文件：源护栏 + 逻辑镜像逐字校验）
//
// 产品口径（用户拍板 3a）：
//   ① 会话自动命名 = **首条消息后起一次名**；
//   ② **用户手动改过名字的会话，之后不再自动改名**。
//
// 跑法（单文件、**不 import 项目代码**，与 scripts/ql_orb 等表同口径；本机没有 Xcode 也能跑）：
//   cd /opt/data/qingliao_ios && /opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc \
//     -o /tmp/test_autoname scripts/ql_autoname/truth_table_autoname.swift && /tmp/test_autoname
//   必须在仓根跑：读源用相对路径 qingliao/…，读不到会先报「源可读」红，不会静默假绿。
//   接进 check_swift.sh 只需要加一行（该文件不归本任务改）：
//     run_unit /tmp/test_autoname scripts/ql_autoname/truth_table_autoname.swift
//
// 三层防护（少一层就是本仓最恨的「假绿」）：
//   ① **生产形态护栏**：ChatStore 侧接线（触发点=落库口 / 结果走既有落库链 / 失败静默 /
//      幂等 / 「人改过」与投递壳两道闸门）+ SessionAutoName 的判断句形态（改口径必红）。
//   ② **镜像逐字校验**：本文件的 AutoNameMirror 必须与 qingliao/Core/SessionAutoName.swift 的
//      同名函数体/常量逐字一致（去注释去空白后比较）。生产改了公式而这里没跟 → 必红。
//      有这条，下面「跑镜像」= 跑生产，不必把项目源码拉进来编（那要改别人的 check_swift.sh）。
//   ③ **口径真值表**：产品两条口径 + 清洗/截断/闸门的全组合，逐条钉死。

import Foundation

// ── ② 镜像：必须与 qingliao/Core/SessionAutoName.swift 逐字一致（改动那边就得改这里，第 6 组会红）

enum AutoNameMirror {

    static let fallbackLength = 30
    static let maxTitleLength = 12
    static let inputLimit = 400

    static let systemPrompt = """
    你是会话命名助手。根据用户的第一条消息，给这次对话起一个简短标题。
    要求：用用户所用的语言，不超过 12 个字；只输出标题本身，不要引号、不要书名号、不要句号、不要换行、不要解释。
    """

    static func prompt(firstMessage: String) -> String {
        let t = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = t.count > inputLimit ? String(t.prefix(inputLimit)) + "…" : t
        return "用户的第一条消息：\n\(clipped)"
    }

    static func fallbackTitle(_ content: String) -> String {
        String(content.prefix(fallbackLength))
    }

    static func isNameable(_ content: String) -> Bool {
        var t = content
        for ph in placeholders { t = t.replacingOccurrences(of: ph, with: " ") }
        return t.filter { $0.isLetter || $0.isNumber }.count >= 2
    }

    private static let placeholders = ["[图片]", "![图片]", "[语音]", "[文件]", "[视频]"]

    static func sanitize(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let titled = lines.filter { $0.count <= maxTitleLength * 2 }
        let picked = titled.last ?? lines[lines.count - 1]
        return truncate(picked, to: maxTitleLength)
    }

    static func truncate(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n))
        guard cut.count == n else { return cut }
        var out = cut
        if let sp = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: sp) >= n - 2 {
            out = String(cut[cut.startIndex..<sp])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { return "" }
        while let f = t.first, "#>*-·•+=~".contains(f) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        if let r = numberedPrefixEnd(t) { t = String(t.dropFirst(r)).trimmingCharacters(in: .whitespaces) }
        for label in labels where t.hasPrefix(label) {
            t = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        while let f = t.first, wrappers.contains(f) { t.removeFirst() }
        while let l = t.last, wrappers.contains(l) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        while let l = t.last, tailPunctuation.contains(l) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        if hardReject.contains(where: { t.contains($0) }) { return "" }
        if t.count > maxTitleLength, softReject.contains(where: { t.contains($0) }) { return "" }
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return t
    }

    private static func numberedPrefixEnd(_ s: String) -> Int? {
        var digits = 0
        for ch in s {
            if ch.isNumber { digits += 1; continue }
            if digits > 0, ".、)）:：".contains(ch) { return digits + 1 }
            return nil
        }
        return nil
    }

    private static let labels = ["会话标题：", "会话标题:", "会话命名：", "标题：", "标题:", "名字：", "名字:", "名称：", "名称:", "Title:", "title:"]
    private static let wrappers: Set<Character> = ["\"", "“", "”", "‘", "’", "'", "`", "「", "」", "『", "』", "《", "》", "【", "】", "(", ")", "（", "）"]
    private static let tailPunctuation: Set<Character> = ["。", ".", "!", "！", "?", "？", ",", "，", ";", "；", ":", "：", "、", " ", "…"]
    private static let hardReject = ["语言模型", "作为AI", "作为一个AI", "无法命名", "无法起名", "无法为这个会话", "请提供更多", "需要更多信息"]
    private static let softReject = ["抱歉", "无法", "不能", "请提供", "需要更多", "unable", "I cannot"]

    static func shouldFire(messageCount: Int,
                           firstIsUser: Bool,
                           firstMessageNameable: Bool,
                           alreadyAutoNamed: Bool,
                           userRenamed: Bool,
                           isDeliverySession: Bool) -> Bool {
        guard messageCount == 1, firstIsUser else { return false }
        guard !isDeliverySession else { return false }
        guard !alreadyAutoNamed else { return false }
        guard !userRenamed else { return false }
        return firstMessageNameable
    }

    static func shouldApply(isSameSession: Bool,
                            currentTitle: String,
                            snapshotFallback: String,
                            currentFirstUser: String,
                            snapshotFirstUser: String,
                            userRenamed: Bool) -> Bool {
        guard isSameSession else { return false }
        guard !userRenamed else { return false }
        guard currentTitle == snapshotFallback else { return false }
        guard currentFirstUser == snapshotFirstUser else { return false }
        return true
    }

    static func isAppTitle(_ title: String, autoNamed: String?, fallback: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if let autoNamed, t == autoNamed.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        return t == fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 表体

// 计数用 nonisolated(unsafe)：本表是单线程脚本，不存在竞争。
// 这样写是为了 Swift 5 / Swift 6 两种编译模式都能过——Swift 6 里顶层 var 默认归 MainActor，
// 给 check 加 @MainActor 又会让 Swift 5 模式（check_swift.sh 的 run_unit 不带 -swift-version）编不过。
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ ok: Bool) {
    if ok { pass += 1; print("✅ \(name)") } else { fail += 1; print("❌ \(name)") }
}

let chatSrc = src("Core/ChatStore.swift")
let nameSrc = src("Core/SessionAutoName.swift")
let mirrorSrc = selfSrc()
check("ChatStore.swift 源可读", !chatSrc.isEmpty)
check("SessionAutoName.swift 源可读", !nameSrc.isEmpty)
check("本表源可读（镜像逐字校验要用；读不到 = 路径写错）", !mirrorSrc.isEmpty)

// 自动命名那一段（标记 → 下一个 MARK 之前）：段内断言只在这块切片里做，
// 避免整文件级负断言被别处同名符号绊红/绊绿。
let autoSection = slice(chatSrc, from: "MARK: - v3.9.90 会话自动命名", to: "// MARK: - v2.0.36")
check("ChatStore 里能切出自动命名段（切片失败 = 下面那些断言全是白写）", autoSection.count > 500)

// ── 1. 旧口径零改动：30 字兜底收敛成一个真源 ─────────────────────
let chatNoComments = stripComments(chatSrc)
check("兜底标题只剩 SessionAutoName.fallbackTitle 一个真源（chatStore 里 prefix(30) 清零）",
      !chatNoComments.contains("prefix(30)"))
check("append 里走 fallbackTitle（首条消息仍立刻有标题，UI 不等网络）",
      chatNoComments.contains("title = SessionAutoName.fallbackTitle(m.content)"))
check("落库 payload 的 firstUserText 也走同一个函数（两处不再各写一份）",
      chatNoComments.contains("let firstUserText = SessionAutoName.fallbackTitle("))
check("生产口径：fallbackLength == 30（升级不改老会话标题）", AutoNameMirror.fallbackLength == 30)

// ── 2. 不新造后端接口：起名复用既有 /api/stream/chat ──────────────
check("起名走既有 /api/stream/chat（非流式一问一答）", autoSection.contains("\"/api/stream/chat\""))
check("起名段里唯一的后端路径是 /api/stream/chat（不新造端点）", Set(apiPaths(in: autoSection)) == ["stream/chat"])
check("取回复体的口径复用 QingliaoAIReply.text（与 Siri/摘要同一处真相）",
      autoSection.contains("QingliaoAIReply.text(from: j)"))
check("模型/provider 只认 CloudConfig.mainModelAndProvider", autoSection.contains("CloudConfig.mainModelAndProvider"))

// ── 3. 接线：触发点在落库口 + 结果走既有落库链 ────────────────────
check("触发挂在 writeSessionSnapshot 末尾（首条消息已落库那一刻）",
      chatNoComments.contains("maybeAutoName(auth: auth, sessionId: sid, messages: msgs, title: t)"))
check("命名结果走既有 saveToServer（防抖 + FIFO 串行写）",
      chatNoComments.contains("Task { await self.saveToServer(auth: auth) }"))
check("命名结果**不**自己拼 merge（旧快照写库会盖掉期间新落的消息）",
      !autoSection.contains("/api/sessions/merge") && !autoSection.contains("messagesPayload"))
check("幂等闸门接线：alreadyAutoNamed 吃持久化标记",
      autoSection.contains("alreadyAutoNamed: autoNamedTitles[sid] != nil"))
check("投递壳闸门接线：永不自动命名（标题后端锁定）",
      autoSection.contains("isDeliverySession: sid == Self.deliverySessionId"))
check("不动对话内容：起名段里没有 messages 的增删",
      !autoSection.contains("messages.removeAll") && !autoSection.contains("messages.append("))

// ── 4. 失败静默回落（无网/超时/后端报错都不弹错、不阻塞） ─────────
check("起名失败 catch → return nil（调用方直接丢弃，留 30 字兜底）",
      autoSection.contains("print(\"[AutoName] 起名失败（静默回落 30 字兜底）") && autoSection.contains("return nil"))
check("起名段内没有任何弹错/阻塞按钮（不出现 alert/errorText）",
      !autoSection.contains("alert") && !autoSection.contains("errorText"))
check("起名带超时（15s），不会无限挂着", autoSection.contains("timeout: 15"))

// ── 5. 「用户手动改过名字」的标记：持久化 + 向后兼容 + 登出清理 ────
check("标记持久化到 UserDefaults（跨启动仍记得「人改过」）",
      autoSection.contains("\"qingliao_renamed_by_user\"")
      && autoSection.contains("UserDefaults.standard.set(Array(renamedByUser), forKey: Self.renamedByUserKey)"))
check("向后兼容老数据：读回来是空集（老数据没有这个 key → 不多改任何标题）",
      autoSection.contains("stringArray(forKey: Self.renamedByUserKey) ?? []")
      && autoSection.contains("dictionary(forKey: Self.autoNamedTitlesKey) as? [String: String]) ?? [:]"))
check("登出丢弃标记（SR10 同款：ChatStore 跨登录态存活）", chatNoComments.contains("resetTitleMarks()"))
check("反推入口存在（会话列表改名/网页端改名都没有事件可挂，只能反推）",
      chatNoComments.contains("noteExternalTitleIfNeeded(") && chatNoComments.contains("SessionAutoName.isAppTitle("))
check("反推只在「就是当前会话」时写标记（不误标别的会话）",
      autoSection.contains("if sessionId == sid { noteExternalTitleIfNeeded(sid, title: title, messages: messages) }"))
check("反推判据来自生产源码（不是表里自己编的）",
      nameSrc.contains("static func isAppTitle(")
      && nameSrc.contains("return t == fallback.trimmingCharacters(in: .whitespacesAndNewlines)"))

// ── 6. ② 镜像逐字校验：下面跑镜像 = 跑生产 ───────────────────────
let prodFns = ["prompt", "fallbackTitle", "isNameable", "sanitize", "truncate", "clean",
               "numberedPrefixEnd", "shouldFire", "shouldApply", "isAppTitle"]
for fn in prodFns {
    let p = canon(funcBody(stripComments(nameSrc), fn))
    let m = canon(funcBody(stripComments(mirrorSrc), fn))
    check("镜像逐字一致：\(fn)()（生产改了公式而这里没跟 → 这条必红）", !p.isEmpty && p == m)
}
let prodConsts = ["static let fallbackLength", "static let maxTitleLength", "static let inputLimit",
                  "static let labels", "static let wrappers", "static let tailPunctuation",
                  "static let hardReject", "static let softReject", "static let placeholders",
                  "static let systemPrompt"]
for c in prodConsts {
    let name = c.replacingOccurrences(of: "static let ", with: "")
    check("镜像逐字一致：\(name)（长度上限/词表/提示词都是产品口径）",
          !decl(nameSrc, c).isEmpty && decl(nameSrc, c) == decl(mirrorSrc, c))
}
check("生产判据句在场：只认「1 条消息」且「首条是用户」",
      nameSrc.contains("guard messageCount == 1, firstIsUser else { return false }"))
check("生产判据句在场：结果落地要求「标题仍是那次兜底」",
      nameSrc.contains("guard currentTitle == snapshotFallback else { return false }"))
check("生产判据句在场：结果落地要求「话题没换」",
      nameSrc.contains("guard currentFirstUser == snapshotFirstUser else { return false }"))
check("生产判据句在场：只有「当前会话就是发起命名的会话」才允许写",
      nameSrc.contains("guard isSameSession else { return false }"))

// ── 7. 纯逻辑：30 字兜底（与历史行为逐字一致） ───────────────────
check("兜底：短消息原样", AutoNameMirror.fallbackTitle("今天北京天气") == "今天北京天气")
check("兜底：空内容给空串（调用方另有 isEmpty 分支，不会写出空标题）", AutoNameMirror.fallbackTitle("") == "")
check("兜底：45 字 → 前 30 字",
      AutoNameMirror.fallbackTitle(String(repeating: "字", count: 45)) == String(repeating: "字", count: 30))

// ── 8. 纯逻辑：值不值得起名 ─────────────────────────────────────
let nameableCases: [(String, Bool, String)] = [
    ("帮我看看这张图\n[图片]", true, "图片带文字：文字还在 → 能起名"),
    ("[图片]", false, "纯图片占位：起不出名字"),
    ("[语音]", false, "纯语音占位：起不出名字"),
    ("", false, "空内容"),
    ("a", false, "一个字母：起名只会空转"),
    ("。。。", false, "纯标点"),
    ("你好", true, "两个汉字够起名"),
    ("12345", true, "纯数字也算内容"),
]
for (content, want, why) in nameableCases {
    check("isNameable(\(content.replacingOccurrences(of: "\n", with: "⏎").prefix(14))) == \(want)（\(why)）",
          AutoNameMirror.isNameable(content) == want)
}

// ── 9. 纯逻辑：模型输出 → 标题（正例） ───────────────────────────
let sanitizeOK: [(String, String, String)] = [
    ("今天北京天气怎么样", "今天北京天气怎么样", "单行、12 字内 → 原样"),
    ("「会议纪要整理」", "会议纪要整理", "去书名号"),
    ("\"NAS 备份失败排查\"", "NAS 备份失败排查", "去引号"),
    ("标题：部署排查", "部署排查", "去「标题：」前缀"),
    ("标题: 部署排查。", "部署排查", "半角冒号 + 结尾句号"),
    ("## 新家装修预算", "新家装修预算", "去 markdown 井号"),
    ("1. 报销单怎么填", "报销单怎么填", "去编号前缀"),
    ("好的，我来为这个会话命名\n新家装修预算", "新家装修预算", "多行取最后一个像标题的候选"),
    ("思考中……\n\n关于 IPv6 打不开的排查", "关于 IPv6 打不开的", "思考链式输出取结论行 + 超长截断"),
    ("如何用 Python 批量重命名 NAS 上的图片文件", "如何用 Python", "超长时退到空格，不留半截词"),
    ("关于 NAS 磁盘满了的排查", "关于 NAS 磁盘满了的", "中文为主：不误退到空格（12 字硬切）"),
    ("```\n北京天气\n```", "北京天气", "去代码围栏"),
]
for (raw, want, why) in sanitizeOK {
    let got = AutoNameMirror.sanitize(raw) ?? "<nil>"
    check("sanitize(\(raw.prefix(16))…) == \(want)（\(why)）", got == want)
}

// ── 10. 纯逻辑：模型输出 → 标题（负例：宁可回落也不能写脏标题） ────
let sanitizeNil: [(String, String)] = [
    ("", "空输出"),
    ("   \n  ", "只有空白"),
    ("抱歉，作为一个语言模型我无法命名", "拒答/元话：不能写进会话列表"),
    ("请提供更多信息才能命名这个会话", "反问式输出"),
    ("。。。", "纯标点"),
]
for (raw, why) in sanitizeNil {
    check("sanitize(\(raw.prefix(12))) == nil（\(why)）", AutoNameMirror.sanitize(raw) == nil)
}
check("短句里的「无法」不被误杀（「无法登录」是正经标题）", AutoNameMirror.sanitize("无法登录") == "无法登录")
check("14 字的解释句里的「抱歉」仍被拒（长句 = 解释，不是标题）",
      AutoNameMirror.sanitize("抱歉，这个会话我没法给出名字") == nil)
check("截断只在超上限时发生（12 字以内一字不改）",
      AutoNameMirror.truncate("北京今天天气", to: 12) == "北京今天天气")

// ── 11. 纯逻辑：该不该起名（产品口径 3a 全组合） ─────────────────
func fire(_ count: Int, user: Bool = true, nameable: Bool = true,
          named: Bool = false, renamed: Bool = false, delivery: Bool = false) -> Bool {
    AutoNameMirror.shouldFire(messageCount: count, firstIsUser: user,
                              firstMessageNameable: nameable, alreadyAutoNamed: named,
                              userRenamed: renamed, isDeliverySession: delivery)
}
check("首条用户消息落库 → 起名（产品口径 3a 第一条）", fire(1))
check("第 2 条消息落库 → 不起（首条消息后只起一次名）", !fire(2))
check("空快照 → 不起", !fire(0))
check("首条是 assistant（推送注入）→ 不起", !fire(1, user: false))
check("首条消息不可起名（纯图片）→ 不起", !fire(1, nameable: false))
check("已自动命名过 → 不起（幂等，跨启动也算）", !fire(1, named: true))
check("用户手动改过名 → 不起（产品口径 3a 第二条）", !fire(1, renamed: true))
check("投递壳会话 → 不起（标题后端锁定）", !fire(1, delivery: true))
check("改名 + 投递壳同时命中 → 仍不起", !fire(1, renamed: true, delivery: true))

// ── 12. 纯逻辑：结果该不该落地（四个「不」） ─────────────────────
func apply(_ same: Bool = true, title: String = "今天北京天气",
           fallback: String = "今天北京天气", first: String = "今天北京天气",
           snapshot: String = "今天北京天气", renamed: Bool = false) -> Bool {
    AutoNameMirror.shouldApply(isSameSession: same, currentTitle: title,
                               snapshotFallback: fallback, currentFirstUser: first,
                               snapshotFirstUser: snapshot, userRenamed: renamed)
}
check("四个「不」全过 → 落地", apply())
check("已切走会话 → 不落地（旧快照写库会盖掉新消息）", !apply(false))
check("用户在起名在途时改名 → 不落地（不抢用户的命名）", !apply(title: "我自己起的名字"))
check("用户改过名的会话 → 不落地", !apply(renamed: true))
check("同一 id 被清空后换了话题 → 不落地（旧名字配新消息）", !apply(first: "另一个话题了", snapshot: "今天北京天气"))
check("标题被清空（新会话路径）→ 不落地", !apply(title: ""))

// ── 13. 纯逻辑：线上标题是不是「App 自己写的」 ───────────────────
check("空标题算自己的（列表里改不出空名）", AutoNameMirror.isAppTitle("", autoNamed: nil, fallback: "兜底"))
check("等于 30 字兜底 → 自己的", AutoNameMirror.isAppTitle("兜底", autoNamed: nil, fallback: "兜底"))
check("等于自动命名结果 → 自己的", AutoNameMirror.isAppTitle("北京天气", autoNamed: "北京天气", fallback: "兜底"))
check("既不是兜底也不是命名结果 → 人改的",
      !AutoNameMirror.isAppTitle("我的私人会话", autoNamed: "北京天气", fallback: "兜底"))
check("老数据（无命名记录）但恰好等于兜底 → 自己的（升级不误判）",
      AutoNameMirror.isAppTitle("兜底", autoNamed: nil, fallback: "兜底"))
check("首尾空白差异不算人改的（后端可能顺手 trim）",
      AutoNameMirror.isAppTitle("  兜底\n", autoNamed: nil, fallback: "兜底"))
check("改了内容（加了个句号）→ 人改的",
      !AutoNameMirror.isAppTitle("兜底。", autoNamed: nil, fallback: "兜底"))

// ── 14. 提示词与送模型文本 ──────────────────────────────────────
check("标题上限 12 字（会话列表一行放得下）", AutoNameMirror.maxTitleLength == 12)
check("送模型的首条消息有上限 400 字（防把文章粘进来撑成贵请求）", AutoNameMirror.inputLimit == 400)
check("提示词要求「只输出标题本身」", AutoNameMirror.systemPrompt.contains("只输出标题本身"))
check("提示词要求长度上限与不加引号",
      AutoNameMirror.systemPrompt.contains("12 个字") && AutoNameMirror.systemPrompt.contains("不要引号"))
check("prompt() 带首条消息且超长截断",
      AutoNameMirror.prompt(firstMessage: "北京天气").contains("北京天气")
      && AutoNameMirror.prompt(firstMessage: String(repeating: "长", count: 500)).count < 500)

print("\n———————————————")
if fail == 0 {
    print("🎉 会话自动命名真值表全部通过（\(pass) 项）")
    exit(0)
} else {
    print("❌ 会话自动命名真值表：\(fail) 个失败 / \(pass) 个通过")
    exit(1)
}

// MARK: - 读源小工具（口径同 scripts/ql_entry、ql_toolsteps：必须在仓根跑）

/// 生产源码（相对仓根；读不到返回空串 → 第 0 组先报红，不会静默全绿）
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "qingliao/" + path, encoding: .utf8) else { return "" }
    return s
}

/// 本文件自己的源：镜像逐字校验要拿它做对照（路径写错 → 源可读那条先红）
func selfSrc() -> String {
    guard let s = try? String(contentsOfFile: "scripts/ql_autoname/truth_table_autoname.swift", encoding: .utf8) else { return "" }
    return s
}

/// 取 a、b 之间的片段（负断言只在这块切片里做，避免整文件级假红/假绿）
func slice(_ s: String, from: String, to: String) -> String {
    guard let r = s.range(of: from) else { return "" }
    let tail = s[r.lowerBound...]
    guard let r2 = tail.range(of: to) else { return String(tail) }
    return String(tail[..<r2.lowerBound])
}

/// 去注释（行首与行尾）：负断言必须走它（「讲清旧写法」的注释会把断言染红，本仓已踩过）；
/// 镜像比较也走它（注释不参与比较，代码逐字就够）。
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            if let r = line.range(of: "//") { return line[..<r.lowerBound] }
            return line
        }
        .joined(separator: "\n")
}

/// 源里的后端路径（`"/api/xxx"` → `xxx`）：给「只允许既有端点」这类负断言用
func apiPaths(in s: String) -> [String] {
    s.components(separatedBy: "\"/api/").dropFirst()
        .map { String($0.prefix(while: { $0 != "\"" })) }
}

/// 取 `static func NAME(` 起、到花括号配平的整段（含签名）。找不到返回空串 → 断言随之红。
func funcBody(_ s: String, _ name: String) -> String {
    guard let r = s.range(of: "static func \(name)(") else { return "" }
    let tail = s[r.lowerBound...]
    var depth = 0
    var started = false
    var out = ""
    for ch in tail {
        out.append(ch)
        if ch == "{" { depth += 1; started = true }
        else if ch == "}" { depth -= 1; if started && depth == 0 { break } }
    }
    return out
}

/// 取一条 `static let NAME = …` 声明（开引号在同一行的多行字符串取到收尾的 `"""`）。
func decl(_ s: String, _ prefix: String) -> String {
    guard let r = s.range(of: prefix) else { return "" }
    let tail = s[r.lowerBound...]
    let lineEnd = tail.firstIndex(of: "\n") ?? tail.endIndex
    let firstLine = String(tail[..<lineEnd])
    // 只有「声明行自己就带开引号」的多行字符串才走块取法 ——
    // 否则会把后面别处的 `"""` 当成自己的结尾，切片一路吃到下一个常量（本表踩过：三条数值常量假红）
    if firstLine.contains("\"\"\""),
       let open = tail.range(of: "\"\"\""),
       let close = tail.range(of: "\"\"\"", range: open.upperBound..<tail.endIndex) {
        return String(tail[..<close.upperBound])
    }
    return firstLine
}

/// 归一化：只留非空白字符（比较用；注释已在调用处去掉）
func canon(_ s: String) -> String {
    String(s.filter { !$0.isWhitespace })
}
