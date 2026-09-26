import Foundation

// MARK: - v4.0.x 一句话记账 · 聊天页入口（口径 1a）
//
// 目标：用户在聊天框里说一句「买菜 86」→ ①记一笔账 ②会话里出一张记账卡 ③AI 照常回一句。
//
// 为什么单开一个文件，而不是塞进 IntentPipeline.swift / RecordKit.swift：
//   · IntentPipeline 是**三个入口共用**的识别口径（输入栏粘贴识别 / 大爆炸 / 「+ → 拍照 → 识别」），
//     它的形态是「认出来 → 用户点『记一笔』→ 才写」。聊天框这句要的是**点即写**，
//     两者共享的是同一个写入落点（RecordStore.addDetailed）与单位归一（RecordKit.normalizeUnit），
//     **不是**共享「猜数字」的规则 —— 把裸数字规则塞进 IntentPipeline，剪贴板/图片入口也会开始认裸数字，
//     那两处的动作条是「一键写库」，假阳性会直接变成用户账本里的错账。
//   · 本文件**纯 Foundation、零 SwiftUI**：本机没有 Xcode，规则层的口径与假阳性只能用可执行真值表钉住
//     （scripts/test_chat_record.swift），视图与状态读写分别在 ChatView / RecordStore 里，不混进来。
//
// 识别两段（**先复用、后补缺**，不新造第二套口径）：
//   ① 带单位/前缀的写法（「买菜 86 元」「¥86 买菜」「86 块钱」）→ 交给既有 IntentPipeline.classify，
//      直接吃它的 value/unit（连「>100 万不认」这种上限校验都还是同一份代码）。
//   ② 裸数字写法（「买菜 86」）→ IntentPipeline 的 matchAmount 三条正则
//      （amountPrefixed / amountYuan / amountEnergy）都要求 ¥/元/块/度/kWh，裸数字必然落空，
//      所以这里补一条**门更严**的规则。
//
// 裸数字为什么必须更严（本仓既有口径：假阳性比漏识别更伤）：
//   「买菜 86」和「股票 3000」「体重 65」「步数 8000」「验证码 1234」在字符层面是同构的，
//   只看「有汉字 + 有数字」会把这些全记成支出。所以裸数字要**同时**过四道门：
//     ① 汉字必须存在，数字**恰好一个**且独立成词（不与字母/其它数字/小数点粘连 → 订单号天然排除）
//     ② 数字后面不能紧跟非金额单位（斤/公里/点/岁/人/年/日/号…），整数位 ≤ 5
//     ③ 全文与事项不得含「非消费语义」词（收入语义 / 证件号 / 计量指标 …）
//     ④ 数字必须出现在汉字**之后**（「事项 金额」语序）——「86 买菜」这种倒装不认
//   刻意**没有**「四位数字一律当成年份」这道门：房租 2000、手机 2026 都是常见金额，
//   一律拒会被用户当成「说了没反应」；日期形态由 ②（跟 年/月/日/号）与 ④（倒装）挡。
//   过不了门就不写：宁可漏（用户还能在生活页手记，或换个说法带上「元」），不可错账。

/// 一句话记账解析出的草稿（纯值类型：落库前不碰任何状态，便于真值表直接断言）
struct ChatExpenseDraft: Equatable, Sendable {
    /// 事项（记什么）——如「买菜」
    let item: String
    let amount: Double
    /// 单位：本入口**只产出「元」**（非「元」的数值是表读数，不是账，归既有「读数」形态）
    let unit: String
    /// 分类（餐饮 / 交通 / …，词表兜底「其它」）
    let category: String
    /// 原话（永远留着，事后可追溯「这句到底怎么被认成账的」）
    let raw: String
    /// 记账时间（= 解析时刻；作为参数传入而不是内部取 Date()，真值表才能固定）
    let at: Date

    /// 落库备注：分类 + 原话。
    /// 为什么塞 note：RecordItem **没有** category 字段（RecordKit 头注释「第一版刻意不做类别字段」），
    /// 而生活页只显示 title / 金额 / 时间 —— 分类不落进 note 就只活在卡片上、库里丢干净，
    /// 将来要做「分类统计」时无从回溯。
    var storeNote: String { "分类：\(category)｜原话：\(raw)" }
}

/// 会话里刚记下的一笔（驱动输入栏上方的「已记账 + 撤销」动作条；撤销要能一并收回卡片）
struct ChatRecordEntry: Equatable {
    let item: RecordItem
    let category: String
    /// 会话里那张记账卡的消息 id（撤销时一并从会话里收回）
    let cardMessageID: String
    /// 去重签名（撤销后要放回，否则「撤销完再说一遍同一句」会被自己挡掉）
    let signature: String
}

enum ChatRecordKit {

    // MARK: - 门槛常量

    /// 只认**短句**：长文本里出现数字的概率与语义噪声都高得多
    /// （「昨天买了菜，路上堵了 20 分钟」——真放进去就是假阳性），长句交给 AI 兜底。
    static let maxTextLength = 24
    /// 单笔上限：与 IntentPipeline.matchAmount 同口径（>100 万的数字多半是订单号 / 时间戳）
    static let maxAmount: Double = 1_000_000
    /// 裸数字形态的上限：比带单位的更保守 —— 裸数字没有单位兜底，6 位以上极易是编号
    static let maxBareAmount: Double = 99_999
    /// 事项上限：超过就不是「一件事」了，是被切错的句子
    static let maxItemLength = 14
    /// 同会话同文本的记账去重窗口（秒）。
    /// 为什么是 10 分钟而不是 Store 的 2 秒连点护栏：**「重试」入口（retryMessage）会清掉 sendCore 的
    /// 60s 同内容幂等签名并原样重发同一条文本** —— 只靠 2 秒挡不住「失败 → 一分钟后点重试」，
    /// 会凭空多记一笔。用户真隔十分钟又买了一次同样的菜是正常业务，允许再记（与 Store
    /// 「同额两笔正常」的口径一致）。
    static let repeatWindow: TimeInterval = 600

    // MARK: - 入口

    /// 解析一句话；认不出返回 nil（**不猜**）。
    static func draft(from raw: String, now: Date = Date()) -> ChatExpenseDraft? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxTextLength else { return nil }
        if let d = unitDraft(from: text, now: now) { return d }   // ① 带单位：既有管道
        return bareDraft(from: text, now: now)                    // ② 裸数字：本文件的门
    }

    /// 去重签名：会话 + 文本（口径与 sendCore 的 lastSentSignature 同构，只是窗口更长）
    static func signature(sessionId: String, text: String) -> String {
        sessionId + "|" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ① 带单位：复用 IntentPipeline

    private static func unitDraft(from text: String, now: Date) -> ChatExpenseDraft? {
        let intent = IntentPipeline.classify(text: text, now: now)
        guard intent.kind == .amount,
              let v = Double(intent.fields["value"] ?? ""),
              let unit = intent.fields["unit"], unit == "元",   // 度 / kWh 是表读数，不是账
              v > 0, v <= maxAmount else { return nil }
        let item = cleanItem(amountStripped(text))
        guard isUsableItem(item) else { return nil }
        return ChatExpenseDraft(item: item, amount: v, unit: "元",
                                category: category(for: item), raw: text, at: now)
    }

    // MARK: - ② 裸数字：本文件的门

    private static func bareDraft(from text: String, now: Date) -> ChatExpenseDraft? {
        guard hasHan(text) else { return nil }                        // 「86」「SF1234567890」
        guard !containsAny(text, incomeWords) else { return nil }      // 收入语义不猜（见下方词表注释）
        guard !containsAny(text, nonExpenseWords) else { return nil }  // 计量/编号/身份语境
        let tokens = numberTokens(in: text)
        guard tokens.count == 1, let tok = tokens.first else { return nil }   // 「买菜 86 和 12」= 两个数 → 不猜
        guard tok.value > 0, tok.value <= maxBareAmount else { return nil }
        // 刻意**没有**「四位数字一律当成年份」这道门：房租 2000、手机 2026 都是常见金额，
        // 一律拒会被用户当成「说了没反应」。日期形态由别的门挡：
        //   后面跟「年/月/日/号」→ startsWithNonMoneyUnit；前面是「2026 年 买菜」这种倒装 → 语序门。
        guard !startsWithNonMoneyUnit(String(text[tok.range.upperBound...])) else { return nil }
        guard !isOrdinalContext(String(text[text.startIndex ..< tok.range.lowerBound])) else { return nil }
        let pre = String(text[text.startIndex ..< tok.range.lowerBound])
        let post = String(text[tok.range.upperBound...])
        guard hasHan(pre) else { return nil }   // 语序：事项在前、金额在后（「买菜 86」，不认「86 买菜」）
        // 事项取词：金额前的汉字（「买菜 86」）优先；金额前只有「花了 / 打车」这类动词时取金额**后**那段
        // （「花了 15 买菜」→ 买菜，别洗出「花了 买菜」这种半截标题）；
        // 两段都空（「打车 32.5」「花了 15」）→ **退回动词本身当事项**：
        // 宁可记一笔「打车 / 32.50 元」，也不要因为「没写出事项名」就静默不记 —— 用户会以为功能坏了。
        var item = cleanItem(fillerOnly(pre) ? post : pre + " " + post)
        if item.isEmpty { item = cleanItem(pre) }
        guard isUsableItem(item) else { return nil }
        return ChatExpenseDraft(item: item, amount: tok.value, unit: "元",
                                category: category(for: item), raw: text, at: now)
    }

    // MARK: - 文本工具

    /// 汉字判定用码点区间而不是正则：NSRegularExpression 不认 `\u{...}` 转义（ICU 要 `\x{..}`），
    /// 而 `\p{Han}` 在 iOS 上要跑真机才能确认行为 —— 本机没有 Xcode，别引入只能上线才知道对错的写法。
    static func hasHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
    }

    /// 独立数字词（可能是金额，也可能是编号/年份/数量 —— 由调用方继续过门）
    static func numberTokens(in text: String) -> [(value: Double, range: Range<String.Index>)] {
        // 前后都不许贴字母/数字/小数点/逗号：「SF1234567890」整串不命中，且不会把尾巴「4567890」当金额；
        // 「17.999」这种超过两位小数的写法也整串不命中（宁可漏，不猜）。
        let pattern = "(?<![0-9A-Za-z.,])([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,5}(?:\\.[0-9]{1,2})?)(?![0-9A-Za-z.,])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            let raw = String(text[r]).replacingOccurrences(of: ",", with: "")
            guard let v = Double(raw) else { return nil }
            return (v, r)
        }
    }

    /// 年份形态：整数且落在 1900…2100 —— 「买菜 2026」「86 年」都不该记成 2026 元 / 86 元
    /// 数字后面紧跟非金额单位（斤/公里/点/岁/人…）→ 是数量不是钱。
    /// 注意这里**不含「元」**：带「元」的写法在 ① 就被 IntentPipeline 接走了。
    static func startsWithNonMoneyUnit(_ tail: String) -> Bool {
        let s = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        // 钱单位词优先判定：它们**不是**「非金额单位」。少了这条，「100 人民币」会被
        // nonMoneyUnits 里的「人」（人数）当头一个字误伤 → 该记的一笔被判成数量。
        for w in moneyWords where s.hasPrefix(w) { return false }
        for u in nonMoneyUnits where s.hasPrefix(u) { return true }
        return false
    }

    /// 数字紧跟在序数/分隔标记之后（「第 3 名」「- 12」「#8」）→ 编号，不是金额
    static func isOrdinalContext(_ head: String) -> Bool {
        let s = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = s.last else { return false }
        return ["第", "#", "-", "–", "—", "/", "、", "No", "NO", "no"].contains(String(last))
            || s.hasSuffix("编号") || s.hasSuffix("单号")
    }

    /// 把金额词挖掉（给 IntentPipeline 那一路用）：先删单位后缀形态再删 ¥ 前缀形态，
    /// 否则「¥86 元」会残留一个「元」进事项。
    static func amountStripped(_ text: String) -> String {
        var s = text
        for pattern in ["[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:元|块钱|块)",
                        "[¥￥]\\s*[0-9][0-9,]*(?:\\.[0-9]+)?"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s
    }

    /// 事项清洗：折叠空白 → 去首尾标点 → 剥掉「记账」前缀（前缀不是事项，留着会让标题与分类都跑偏）
    static func cleanItem(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t，,、。．.：:；;！!～~·-—"))
        // 话头/记账前缀不是事项（「记账 买菜 86」「今天 买菜 86」「我打车 32.5」）：
        // 留着会让生活页的标题和分类都跑偏（「今天 买菜」既不像事，也会被「今天」干扰）
        // 前缀会叠着（「我今天 买菜 86」「帮我记账 打车 32」）→ 循环剥，剥到没有为止
        var stripped = true
        while stripped {
            stripped = false
            for p in ["帮我记一笔", "帮我记账", "记一笔", "记账", "记一下", "帮我记",
                      "我的", "今天", "昨天", "刚才", "刚刚", "我"] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t，,、。．.：:；;！!～~"))
                stripped = true
                break
            }
        }
        if s.hasPrefix("的") { s = String(s.dropFirst()) }   // 「我的 的咖啡」类残渣
        // 首尾的单位词要剥掉：② 裸数字路径认「金额在前」时会把「块钱 / 人民币」留在事项尾巴上
        // （「买菜 100 人民币」→ 事项应为「买菜」）。**只剥首尾、不动中间** ——
        // 中间挖洞会把「人民币」之外的正常词切碎。剥空了由 isUsableItem 兜底拒绝（「人民币 100」无事项）。
        var strippedUnit = true
        while strippedUnit {
            strippedUnit = false
            for w in moneyWords where s.hasSuffix(w) {
                s = String(s.dropLast(w.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                strippedUnit = true
                break
            }
        }
        return s
    }

    /// 首尾可剥的钱单位词（长词在前：先剥「人民币」再轮到「元」）
    private static let moneyWords = ["人民币", "块钱", "元钱", "元整", "RMB", "rmb", "CNY", "cny",
                                    "元", "块", "¥", "￥"]

    /// 金额前面是不是「纯填充」（「花了」「我」「今天」…）——是的话事项取金额**后面**那段，
    /// 否则「花了 15 买菜」会洗出「花了 买菜」这种半截标题。
    static func fillerOnly(_ pre: String) -> Bool {
        var s = pre.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "，,、。．.：:；;！!～~ "))
        if fillerTokens.contains(s) { return true }
        for t in fillerTokens.sorted(by: { $0.count > $1.count }) {
            guard !t.isEmpty, s.hasPrefix(t) else { continue }
            var rest = String(s.dropFirst(t.count))
            if rest.isEmpty { return true }
            for v in spendVerbs.sorted(by: { $0.count > $1.count }) where rest.hasPrefix(v) {
                rest = String(rest.dropFirst(v.count))
                while rest.hasPrefix("了") { rest = String(rest.dropFirst()) }
                return rest.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }
        for v in spendVerbs.sorted(by: { $0.count > $1.count }) where s.hasPrefix(v) {
            var rest = String(s.dropFirst(v.count))
            while rest.hasPrefix("了") { rest = String(rest.dropFirst()) }
            return rest.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    /// 事项是否可用：非空、不太长、有汉字、不含非消费语义词
    static func isUsableItem(_ item: String) -> Bool {
        guard !item.isEmpty, item.count <= maxItemLength, hasHan(item) else { return false }
        return !containsAny(item, nonExpenseWords) && !containsAny(item, incomeWords)
    }

    static func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    // MARK: - 分类

    /// 分类表（顺序 = 优先级，越靠前的词越具体）。
    /// 只做「词表命中 + 兜底其它」，不做统计分类：本机没有模型，宁可给「其它」也不要猜错分类。
    /// 「餐饮」排在「购物」前：「买菜」同时含「买」（购物）与「菜」（餐饮），要判成餐饮。
    private static let categoryTable: [(name: String, words: [String])] = [
        ("居家", ["房租", "水电", "燃气", "物业", "宽带", "话费", "电费", "水费", "取暖", "家政"]),
        ("交通", ["打车", "打的", "滴滴", "地铁", "公交", "高铁", "火车", "机票", "车票", "加油",
                  "油费", "停车", "过路", "单车", "充电桩"]),
        ("医疗", ["医院", "药", "挂号", "体检", "看病", "牙医", "门诊", "疫苗"]),
        ("娱乐", ["电影", "游戏", "门票", "演唱会", "KTV", "ktv", "旅游", "酒店", "健身", "会员"]),
        ("学习", ["书", "课程", "培训", "学费", "文具", "考试", "网课"]),
        ("人情", ["红包", "礼物", "请客", "份子", "随礼", "送礼"]),
        ("餐饮", ["买菜", "菜", "饭", "餐", "外卖", "奶茶", "咖啡", "水果", "吃", "喝", "烧烤",
                  "火锅", "早餐", "午餐", "晚餐", "早点", "零食", "米", "油", "面", "肉", "蛋", "奶"]),
        ("日用", ["纸巾", "洗衣液", "牙膏", "洗发", "沐浴", "日用品", "清洁", "垃圾袋", "卫生纸"]),
        ("购物", ["买", "购", "衣服", "鞋", "淘宝", "京东", "拼多多", "数码", "耳机", "手机", "电脑", "平板", "相机", "家具", "电器", "包"]),
    ]

    static func category(for item: String) -> String {
        for row in categoryTable where row.words.contains(where: { item.contains($0) }) {
            return row.name
        }
        return "其它"
    }

    // MARK: - 词表

    /// 填充词（金额前面的「话头」，不是事项）
    private static let fillerTokens: [String] = [
        "", "我", "今天", "昨天", "刚才", "刚刚", "这", "那", "帮我", "记账", "记一笔",
    ]

    /// 消费动词（判断「金额前那段是不是纯话头」用）
    private static let spendVerbs: [String] = [
        "买了", "花", "付", "支付", "消费", "支出", "交", "缴", "充", "订", "购", "打车", "吃", "喝",
    ]

    /// 收入语义：**本轮只记支出**。把「收了 500 工资」记成支出 500 是错账，宁可漏，
    /// 让用户回生活页手记（或等收入口径定下来再补）。
    private static let incomeWords: [String] = [
        "收了", "收到", "收入", "退款", "退货", "报销", "返现", "到账", "提现", "工资", "薪水",
        "奖金", "中奖", "利息", "分红",
    ]

    /// 非消费语境：一眼不是「记一笔支出」的词。这里刻意收得宽一点 ——
    /// 误杀只损失一次自动记账（用户重说一句或生活页手记即可），误记会把别人的账本搞脏。
    private static let nonExpenseWords: [String] = [
        // 编号 / 身份 / 验证
        "快递", "单号", "取件", "签收", "验证码", "订单", "身份证", "卡号", "账号", "密码",
        "工号", "编号", "序号", "房间", "门牌", "座位", "楼层",
        // 计量指标
        "步数", "体重", "身高", "血压", "血糖", "心率", "卡路里", "内存", "流量", "版本", "更新",
        "评分", "排名", "得分", "分数", "字数", "页数", "积分", "里程", "油耗", "时速", "温度", "电量",
        // 其它数值语境
        "股票", "股价", "基金", "余额", "年份", "日期", "时间", "距离", "面积", "型号", "折",
    ]

    /// 非金额单位：数字紧跟其后就是数量/读数，不是钱（「元」不在此列，走 ① 那条路）
    private static let nonMoneyUnits: [String] = [
        "斤", "公斤", "克", "千克", "吨", "公里", "km", "KM", "米", "岁", "点", "时", "小时",
        "分", "秒", "天", "周", "月", "年", "次", "个", "件", "本", "页", "层", "楼", "台",
        "人", "位", "张", "只", "根", "瓶", "袋", "包", "盒", "杯", "碗", "份", "条", "双",
        "套", "度", "千瓦", "kWh", "kwh", "%", "℃", "kg", "KG", "g", "ml", "L",
        // v4.0.x：日期/编号收尾标记。「3 日」「26 号」是日期、不是 3 元/26 元
        "日", "号",
    ]

    // MARK: - 卡片文案

    /// 记账卡（复用既有 ```ql-card 协议 → AgentCardParser → AgentResultCard，**零新渲染体系**）
    ///
    /// ⚠️ 卡片里**放不了可点按钮**：`AgentCard` 只有 title/status/fields/metrics/items/table/footer，
    /// 协议里唯一的交互位是 plan 卡写死的「继续下一步」（语义是追下一步，不是删账）。
    /// 所以「撤销」由宿主（ChatView）在输入栏上方给真按钮，卡片 footer **指路**（指路 ≠ 假按钮：
    /// 卡上没有任何可点元素宣称自己能撤销）。
    static func cardText(title: String, amount: Double, unit: String, category: String,
                         raw: String, at: Date = Date(), calendar: Calendar = .current) -> String {
        let payload: [String: Any] = [
            "type": "metrics",
            "title": "记一笔 · \(title)",
            "subtitle": "一句话记账",
            "status": ["text": "已记账", "tone": "ok"],
            "metrics": [["label": "金额", "value": moneyText(amount), "unit": unit]],
            "fields": [
                ["key": "分类", "value": category],
                ["key": "时间", "value": timeText(at, calendar: calendar)],
                ["key": "原话", "value": raw],
            ],
            "footer": "撤销：点输入框上方的「撤销」",
        ]
        // sortedKeys：同一条记录每次序列化结果一致（落库/去重/导出比对才稳定）
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "```ql-card\n" + json + "\n```"
    }

    /// 卡片里的金额数值（单位另开一列，所以这里只给数字）——与 RecordKit 的「元固定两位小数」同口径
    static func moneyText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// 卡片里的时间：月-日 时:分（今年内不写年份，卡片一行放得下）
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%02d-%02d %02d:%02d",
                      c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 动作条上的一行摘要（金额 + 分类），与卡片同源，避免两处各拼一遍
    static func barSummary(amount: Double, unit: String, category: String) -> String {
        RecordKit.amountText(amount, unit: unit) + " · " + category
    }
}
