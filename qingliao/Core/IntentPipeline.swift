import Foundation

// MARK: - v3.9.71 意图管道（输入收口）
//
// 定位：把"随手拿到的一段内容"（复制的文字 / 拍的照片 OCR 出的字 / 分享进来的文本）
//      判成一个**结构化意图**，并给出**可执行动作**。UI 只负责把 actions 画成动作条。
//
// 分层（刻意的，改这块前必读）：
//   · 本文件 = 契约 + 规则抽取 + 动作表，**纯 Foundation、零 UI 依赖** →
//     scripts/test_intent_pipeline.swift 能在没有 iOS SDK 的本机逐条断言。
//     判断逻辑一旦误判，用户看到的是「把一串普通数字当快递单号」「句子里抄个日期就弹加提醒」，
//     **假阳性比漏识别更伤**，所以判断全在这层、全可本机回归。
//   · OCR（Vision）/ 端侧语义（Foundation Models）/ 云端兜底 都在别的文件里，
//     它们只产出**文本或结构化结果**，最终仍回到 classify() 这条判断链（端侧语义除外，它是直出结构）。
//   · 动作条与执行（写库/撤销）在 Features/Chat/IntentActionBar.swift —— 本文件不认识任何一个 Store。
//
// 优先级（强格式优先，避免"里面夹了个数字就被判成金额"）：
//   express > amount > datetime > link > contact > address > text
//
// 置信度口径：强格式（含 ≥3 个地址关键词）≥0.9 / 地址弱命中 0.75 / 兜底 text 0.3、空串 0。
//   **低于 0.5 只给 askAI + copy，绝不猜**（动作条据此不给写入类动作）。

/// 内容类型
enum IntentKind: String, Sendable {
    case express, address, contact, link, text, amount, datetime
}

/// 判定来源（哪一层认出来的）
enum IntentProvenance: String, Sendable {
    case rule       // 本文件的正则
    case ocr        // 端侧 OCR 出字后再走规则
    case onDevice   // Foundation Models 直出
    case cloud      // 后端兜底
}

/// 可执行动作。**UI 不做判断**，一律由 actions(for:) 按 kind + fields 生成
enum IntentAction: String, Sendable, Hashable {
    case storeRecord, addTodo, addReminder, saveMemo, saveToKB, openMap, call, mailto, copy, askAI
}

/// 识别结果
struct RecognizedIntent: Equatable, Sendable {
    var kind: IntentKind
    /// 一行摘要（动作条标题 / 记录列表显示）
    var title: String
    /// 按 kind 约定的字段（见各 extractor 内注释）
    var fields: [String: String]
    /// 原文，**永远保留**（可追溯）
    var raw: String
    var confidence: Double
    var provenance: IntentProvenance
    var actions: [IntentAction]
}

enum IntentPipeline {

    /// 兜底（没识别出任何强格式）的置信度：低到足以让动作条只给"问 AI / 复制"
    static let fallbackConfidence = 0.3

    // MARK: 对外入口

    /// 判断一段文本。纯函数（`now` 显式传入 → 真值表可固定时间）。
    static func classify(text raw: String, now: Date = Date()) -> RecognizedIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return RecognizedIntent(kind: .text, title: "", fields: [:], raw: raw,
                                    confidence: 0, provenance: .rule, actions: [.askAI, .copy])
        }
        // 强格式优先，命中即停
        let hit = matchExpress(text)
            ?? matchAmount(text)
            ?? matchDatetime(text, now: now)
            ?? matchLink(text)
            ?? matchContact(text)
            ?? matchAddress(text)

        if var i = hit {
            i.raw = text            // 原文永远保留（可追溯）；build() 里不传，避免各处重复
            i.actions = actions(for: i)
            return i
        }

        // 兜底：只给问 AI / 复制，绝不猜
        let i = RecognizedIntent(kind: .text, title: prefix(text), fields: [:], raw: text,
                                 confidence: fallbackConfidence, provenance: .rule,
                                 actions: [.askAI, .copy])
        return i
    }

    /// 动作表：kind + fields → 可执行动作。
    /// 加一类内容只需要改这里 + 一个 matchXxx，UI 不用动。
    static func actions(for i: RecognizedIntent) -> [IntentAction] {
        switch i.kind {
        case .express:  return [.addTodo, .saveMemo, .copy, .askAI]
        case .address:  return [.openMap, .saveMemo, .copy, .askAI]
        case .link:     return [.saveToKB, .saveMemo, .copy, .askAI]
        case .amount:   return [.storeRecord, .saveMemo, .copy, .askAI]
        case .datetime: return [.addReminder, .addTodo, .copy, .askAI]
        case .contact:
            // 手机号给拨号、邮箱给写邮件；判定看 fields["type"]
            return i.fields["type"] == "email"
                ? [.mailto, .saveMemo, .copy, .askAI]
                : [.call, .saveMemo, .copy, .askAI]
        case .text:     return [.askAI, .copy]
        }
    }

    // MARK: - 各类型抽取（每个都要有前缀/长度/上下文校验，防假阳性）

    /// 满足则返回 title/fields，不满足返回 nil（不要在这里塞 actions）
    private typealias Hit = (title: String, fields: [String: String], confidence: Double)

    // 快递：① 公司前缀 + 10~20 位数字 ② 上下文词（快递/取件/单号/运单/签收）附近的首个 10~20 位数字
    private static let expressPrefixed = try! NSRegularExpression(
        pattern: #"\b(SF|YT|ZTO|STO|YD|JD|EMS|JT|DBL|CNSD)\s?([0-9]{10,20})"#,
        options: [.caseInsensitive])
    private static let digitRun = try! NSRegularExpression(pattern: #"[0-9]{10,20}"#)

    private static func matchExpress(_ text: String) -> RecognizedIntent? {
        var no: String?
        var company: String?
        if let m = firstMatch(expressPrefixed, text), m.numberOfRanges >= 3 {
            company = ns(text, m.range(at: 1)).uppercased()
            no = ns(text, m.range(at: 2))
        } else if ["快递", "取件", "单号", "运单", "签收"].contains(where: { text.contains($0) }),
                  let m = firstMatch(digitRun, text) {
            no = ns(text, m.range)
        }
        guard let no else { return nil }
        var f = ["no": no]
        if let company { f["company"] = company }
        return build(.express, "快递单号 \(no)", f, 0.92)
    }

    // 金额/读数：¥ ￥ 前缀、元/块 后缀、度/kWh 后缀三种形态
    private static let amountPrefixed = try! NSRegularExpression(
        pattern: #"[¥￥]\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#)
    private static let amountYuan = try! NSRegularExpression(
        pattern: #"([0-9][0-9,]*(?:\.[0-9]+)?)\s*(元|块钱|块)"#)
    private static let amountEnergy = try! NSRegularExpression(
        pattern: #"([0-9][0-9,]*(?:\.[0-9]+)?)\s*(kWh|KWH|kwh|千瓦时|度电|度)"#)

    private static func matchAmount(_ text: String) -> RecognizedIntent? {
        var value: Double?
        var unit = "元"
        if let m = firstMatch(amountPrefixed, text), m.numberOfRanges >= 2 {
            value = number(ns(text, m.range(at: 1)))
        } else if let m = firstMatch(amountYuan, text), m.numberOfRanges >= 2 {
            value = number(ns(text, m.range(at: 1)))
        } else if let m = firstMatch(amountEnergy, text), m.numberOfRanges >= 3 {
            value = number(ns(text, m.range(at: 1)))
            let u = ns(text, m.range(at: 2))
            unit = (u == "度" || u == "度电") ? "度" : "kWh"
        }
        // 上限校验：超过 100 万的多半是别的数字（订单号/时间戳），不认
        guard let v = value, v > 0, v < 1_000_000 else { return nil }
        let shown = String(format: "%.2f", v)
        return build(.amount, "金额 \(shown) \(unit)", ["value": "\(v)", "unit": unit], 0.9)
    }

    // 日期时间：**复用 QuickReminderParser**（不另写解析器）。
    // 两道门先过，才敢调解析器——否则"今天天气不错"这种句子会被误判成日程：
    //   ① 必须含时间语义词  ② 必须含具体时刻线索（数字/中文数字/点·时·分·半）
    private static let dateGateWords = ["提醒", "记得", "别忘", "点", "时", "分", "小时",
                                        "明天", "后天", "明晚", "今晚", "下周", "周", "星期",
                                        "早上", "上午", "中午", "下午", "晚上", "每天"]
    private static let clockWords = ["点", "时", "分", "半"]
    private static let numeralChars = CharacterSet(charactersIn: "0123456789一二三四五六七八九十半")

    /// 第三道门（v3.9.71 审查收紧）：必须有**提醒意图**或**明确日期词**。
    /// 不加这道门，「充电要 5 小时」「分了三期」这类普通陈述会走到解析器并被判成日程 0.9，
    /// 动作条直接给「建提醒」（写入类）——同样是"猜"，用户会莫名其妙多出一条提醒。
    private static let remindWords = ["提醒", "记得", "别忘", "叫我", "闹钟", "定个", "安排", "开会", "会议"]
    private static let absoluteDateWords = ["明天", "后天", "明晚", "今晚", "下周", "下个月", "周", "星期",
                                            "早上", "上午", "中午", "下午", "晚上", "每天", "今晚", "号"]

    private static func matchDatetime(_ text: String, now: Date) -> RecognizedIntent? {
        guard dateGateWords.contains(where: { text.contains($0) }) else { return nil }
        let hasNumber = text.rangeOfCharacter(from: numeralChars) != nil
        let hasClock = clockWords.contains(where: { text.contains($0) })
        guard hasNumber || hasClock else { return nil }
        let wantsReminder = remindWords.contains { text.contains($0) }
        let hasAbsolute = absoluteDateWords.contains { text.contains($0) }
        guard wantsReminder || hasAbsolute else { return nil }
        guard case .success(let p) = QuickReminderParser.parseDetailed(text, now: now) else { return nil }
        let iso = ISO8601DateFormatter().string(from: p.fireDate)
        var f = ["iso": iso, "summary": p.summary]
        let sub = p.subjectHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty { f["subject"] = sub }
        return build(.datetime, p.summary, f, 0.9)
    }

    // 链接
    private static let urlRE = try! NSRegularExpression(
        pattern: #"(https?://[^\s，。；、）)】」"]+|www\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s，。；、）)】」"]*)?)"#)

    private static func matchLink(_ text: String) -> RecognizedIntent? {
        guard let m = firstMatch(urlRE, text) else { return nil }
        let url = ns(text, m.range)
        let parseTarget = url.hasPrefix("www.") ? "https://" + url : url
        guard let host = URLComponents(string: parseTarget)?.host, !host.isEmpty else { return nil }
        return build(.link, host, ["url": url, "host": host], 0.93)
    }

    // 电话 / 邮箱
    private static let phoneRE = try! NSRegularExpression(pattern: #"^(\+?86)?(1[3-9][0-9]{9})$"#)
    private static let emailRE = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    private static func matchContact(_ text: String) -> RecognizedIntent? {
        // 手机号：先剥空格/横线/括号再整体匹配（"138 1234 5678" 这种写法很常见）
        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if let m = firstMatch(phoneRE, compact), m.numberOfRanges >= 3 {
            let v = ns(compact, m.range(at: 2))
            return build(.contact, v, ["type": "phone", "value": v], 0.92)
        }
        if let m = firstMatch(emailRE, text) {
            let v = ns(text, m.range)
            return build(.contact, v, ["type": "email", "value": v], 0.92)
        }
        return nil
    }

    // 地址：**结构化组合**才算认出来（v3.9.71 审查收紧）
    //
    // 原来的写法是"关键词不同字 ≥3 个就给 0.9"（省市区县路街号镇村栋弄巷）。问题是这些字在日常
    // 说话里到处都是：「今天市区路况一般」「小区路口有家便利店」都命中 3 个字 → 判成地址 0.9 →
    // 动作条直接给出「打开地图 + 存备忘录」。这就是管道注释里最想避免的"猜"。
    //
    // 现在分两档：
    //   · 强命中 0.9：出现行政区划/门牌的**成对结构**（省+市 / 市+区 / 区+路 / 路+号 / 栋+室…），
    //     或者"数字 + 路/街 + 号/栋/室/单元"这种门牌组合
    //   · 弱命中 0.4：只有单字凑数 —— **低于 0.5 的动作门槛**，动作条只给「问 AI / 复制」，不给写入类动作
    private static let addressKeywords = Array("省市区县路街号镇村栋弄巷")
    /// 门牌：数字 + 号/栋/室/单元/楼/层 —— 这是**地址的硬证据**（口语里几乎不会出现）
    private static let doorRE = try! NSRegularExpression(
        pattern: #"\d{1,5}\s*(号|栋|幢|室|单元|号楼|楼|层)"#)
    private static let adminWords = ["省", "市", "区", "县", "镇", "乡", "街道"]

    private static func matchAddress(_ text: String) -> RecognizedIntent? {
        guard text.count >= 6 else { return nil }
        let distinct = Set(addressKeywords.filter { text.contains($0) }).count
        guard distinct >= 2 else { return nil }
        let hasDoor = firstMatch(doorRE, text) != nil
        let hasRoad = text.contains("路") || text.contains("街") || text.contains("巷") || text.contains("弄")
        let adminHits = adminWords.filter { text.contains($0) }.count
        // 强命中只看硬证据：① 有门牌数字 ② 或者"行政区划 ≥2 级 + 路/街"且文本够长
        // （"今天市区路况一般" 有 市/区/路 但没有门牌、长度只有 8 → 停在弱命中）
        let strong = hasDoor || (adminHits >= 2 && hasRoad && text.count >= 10)
        return build(.address, prefix(text), ["text": text], strong ? 0.9 : 0.4)
    }

    // MARK: - 工具

    private static func build(_ kind: IntentKind, _ title: String,
                             _ fields: [String: String], _ confidence: Double) -> RecognizedIntent {
        RecognizedIntent(kind: kind, title: title, fields: fields, raw: "",
                         confidence: confidence, provenance: .rule, actions: [])
    }

    private static func prefix(_ s: String) -> String {
        String(s.prefix(20))
    }

    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s))
    }

    private static func ns(_ s: String, _ r: NSRange) -> String {
        guard let range = Range(r, in: s) else { return "" }
        return String(s[range])
    }

    /// "1,280.00" → 1280.0
    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ""))
    }
}
