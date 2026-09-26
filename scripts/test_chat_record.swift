// 一句话记账（聊天页入口 · 口径 1a）真值表 —— Linux 本地预检用，纯 Foundation，无 UI 依赖
//
// 编译运行（在仓库根目录，工具链路径见 check_swift.sh）：
//   ./scripts/check_chat_record.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_chat_record /tmp/ql_chat_record_main/main.swift \
//       qingliao/Core/ChatRecordKit.swift qingliao/Core/IntentPipeline.swift \
//       qingliao/Core/QuickReminder.swift qingliao/Core/RecordKit.swift \
//       qingliao/Core/AgentCardParser.swift
//
// 口径（本文件钉死的东西）：
//   · **反例占三分之一以上**：本入口是「点即写」（写错就进用户账本），
//     所以「不该认的必须不认」比「该认的能认」更重要 —— 反例条数不足直接判红，防后人只加正例。
//   · 两段识别：① 带单位/前缀 → 复用 IntentPipeline；② 裸数字 → 本仓新增的窄门。
//   · 分类只做词表命中 + 兜底「其它」；分类必须落进 note（RecordItem 没有 category 字段）。
//   · 卡片走既有 ```ql-card 协议：**必须能被真的 AgentCardParser 解出来**（不是手写字符串自证）。
//   · 卡片**不带动作段**：AgentCard 协议今天没有可交互动作位（撤销按钮因此在宿主动作条上，
//     见 ChatRecordBar 头注释）。谁要往卡里加按钮，先改 AgentCardParser/AgentResultCard。

import Foundation

// MARK: - 断言工具

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

/// 固定时区日历：卡片上的时间文案必须与跑测试的机器时区无关（check_swift.sh 已钉 TZ，双保险）
func fixedCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
    return c
}

/// 固定时刻：2026-09-26 14:03:00 +08:00（epoch 1790402580，`date -d '2026-09-26 14:03:00' +%s` 校过）
func fixedNow() -> Date {
    Date(timeIntervalSince1970: 1_790_402_580)
}

/// 正例：必须认出来，并断言金额/事项/分类
func expectDraft(_ name: String, _ text: String, amount: Double?, item: String?, category: String?) {
    positives += 1
    guard let d = ChatRecordKit.draft(from: text, now: fixedNow()) else {
        check("\(name)（「\(text)」应认成一笔）", false)
        return
    }
    if let amount { check("\(name)（金额 = \(amount)）", d.amount == amount) }
    if let item { check("\(name)（事项 = \(item)）", d.item == item) }
    if let category { check("\(name)（分类 = \(category)）", d.category == category) }
    check("\(name)（单位恒为元）", d.unit == "元")
    check("\(name)（原话保留）", d.raw == text)
}

/// 反例：必须**不认**（宁可漏，不可错账）
func expectNil(_ name: String, _ text: String) {
    negatives += 1
    check("\(name)（「\(text)」不应认成一笔）", ChatRecordKit.draft(from: text, now: fixedNow()) == nil)
}

@main
enum ChatRecordTruthTable {

    static func runAllTests() {
        sectionOne_裸数字正例()
        sectionTwo_带单位复用既有管道()
        sectionThree_反例()
        sectionFour_分类与备注()
        sectionFive_卡片()
        sectionSix_签名与时间文案()
        sectionSeven_反例占比哨兵()
    }

    // MARK: - 1. 裸数字正例（② 本仓补的那条窄门）

    static func sectionOne_裸数字正例() {
        print("\n=== 1. 裸数字正例（用户口径原句：聊天框说「买菜 86」）===")
        expectDraft("买菜 86", "买菜 86", amount: 86, item: "买菜", category: "餐饮")
        expectDraft("买菜 86.5", "买菜 86.5", amount: 86.5, item: "买菜", category: "餐饮")
        expectDraft("打车 32.5", "打车 32.5", amount: 32.5, item: "打车", category: "交通")
        expectDraft("午饭 25", "午饭 25", amount: 25, item: "午饭", category: "餐饮")
        expectDraft("电费 120", "电费 120", amount: 120, item: "电费", category: "居家")
        expectDraft("买药 30", "买药 30", amount: 30, item: "买药", category: "医疗")
        // 金额在前、话头在后：事项取金额**后面**那段（否则标题会洗成「花了 买菜」）
        expectDraft("花了 15 买菜", "花了 15 买菜", amount: 15, item: "买菜", category: "餐饮")
        // 「记账」前缀不是事项
        expectDraft("记账 买菜 86", "记账 买菜 86", amount: 86, item: "买菜", category: "餐饮")
        expectDraft("帮我记 奶茶 18", "帮我记 奶茶 18", amount: 18, item: "奶茶", category: "餐饮")
        // 千分位
        expectDraft("交房租 2,000", "交房租 2,000", amount: 2000, item: "交房租", category: "居家")
        // 金额前只有动词：退回动词本身当事项（宁可记一笔，不要静默不记）
        expectDraft("打车 32.5", "打车 32.5", amount: 32.5, item: "打车", category: "交通")
        expectDraft("花了 15", "花了 15", amount: 15, item: "花了", category: "其它")
        // 话头（我 / 今天）不是事项的一部分
        expectDraft("我今天 买菜 86", "我今天 买菜 86", amount: 86, item: "买菜", category: "餐饮")
    }

    // MARK: - 2. 带单位/前缀：必须走既有 IntentPipeline，别另立一套

    static func sectionTwo_带单位复用既有管道() {
        print("\n=== 2. 带单位/前缀（① 复用 IntentPipeline.classify）===")
        expectDraft("买菜 86 元", "买菜 86 元", amount: 86, item: "买菜", category: "餐饮")
        expectDraft("¥86 买菜", "¥86 买菜", amount: 86, item: "买菜", category: "餐饮")
        expectDraft("打车 32 块钱", "打车 32 块钱", amount: 32, item: "打车", category: "交通")
        // 「人民币」不在 IntentPipeline 的单位白名单里 → 走 ② 裸数字，事项尾巴上的单位词要剥干净
        expectDraft("买菜 100 人民币", "买菜 100 人民币", amount: 100, item: "买菜", category: "餐饮")

        // 读数（度 / kWh）不是账：单位不是「元」→ 不记
        negatives += 1
        check("电表 86 度不记成钱（表读数是另一形态）",
              ChatRecordKit.draft(from: "电表 86 度", now: fixedNow()) == nil)
        negatives += 1
        check("86 kWh 不记成钱", ChatRecordKit.draft(from: "抄表 86 kWh", now: fixedNow()) == nil)

        // 金额上限与 IntentPipeline 同口径（>100 万）
        expectNil("天价（200 万）不认", "买菜 2000000 元")
    }

    // MARK: - 3. 反例（本入口最要紧的一节）

    static func sectionThree_反例() {
        print("\n=== 3. 反例：不该认的必须不认 ===")
        expectNil("纯数字", "86")
        expectNil("无数字", "买菜")
        expectNil("订单号（字母+长数字粘连）", "SF1234567890")
        expectNil("快递单号", "快递 12345678")
        expectNil("验证码", "验证码 1234")
        expectNil("股票", "股票 3000")
        expectNil("余额", "余额 500")
        expectNil("步数", "步数 8000")
        expectNil("体重", "体重 65")
        expectNil("血压", "血压 120")
        expectNil("内存", "内存 16")
        expectNil("多个数字（两个数不猜）", "买菜 86 和 12")
        // 四位数字**不是**年份一律拒：2026 元很常见（房租 2000 / 手机 2026），拒了像「说了没反应」。
        // 真正要挡的日期/编号形态由「后面跟 年/月/日/号」+「数字必须在汉字之后」两道门挡，见下面两条。
        expectDraft("四位金额（2026 元）要认", "手机 2026", amount: 2026, item: "手机", category: "购物")
        expectNil("日期在前（倒装）", "2026 年 买菜")
        expectNil("年份带「年」", "生日 1998 年")
        expectNil("日期收尾（日）", "买菜 3 日")
        expectNil("编号收尾（号）", "快递 888 号")
        expectNil("带非金额单位（斤）", "买菜 3 斤")
        expectNil("带非金额单位（公里）", "开车 20 公里")
        expectNil("带非金额单位（岁）", "妈妈 60 岁")
        expectNil("带非金额单位（%）", "涨了 8 %")
        expectNil("序数", "第 3 章")
        expectNil("超长（>24 字）", "昨天买了菜，路上堵了 20 分钟，回来又看了一会儿书")
        expectNil("收入语义（工资）", "收了 500 工资")
        expectNil("收入语义（退款）", "退款 88 到账")
        expectNil("超过裸数字上限", "买菜 123456")
        expectNil("小数点后三位", "买菜 17.999")
        expectNil("只有单位词没有事项", "人民币 100")
        expectNil("空串", "")
    }

    // MARK: - 4. 分类与备注

    static func sectionFour_分类与备注() {
        print("\n=== 4. 分类（词表 + 兜底）与 note（分类不落库就丢在卡片外）===")
        check("买菜 → 餐饮（不能被「买」抢去购物）", ChatRecordKit.category(for: "买菜") == "餐饮")
        check("打车 → 交通", ChatRecordKit.category(for: "打车") == "交通")
        check("买书 → 学习", ChatRecordKit.category(for: "买书") == "学习")
        check("话费 → 居家", ChatRecordKit.category(for: "话费") == "居家")
        check("电影 → 娱乐", ChatRecordKit.category(for: "电影") == "娱乐")
        check("陌生事项 → 其它（不猜）", ChatRecordKit.category(for: "玩具") == "其它")

        guard let d = ChatRecordKit.draft(from: "买菜 86", now: fixedNow()) else {
            check("note 断言前置（应认出「买菜 86」）", false)
            return
        }
        check("note 含分类", d.storeNote.contains("分类：餐饮"))
        check("note 含原话（事后可追溯）", d.storeNote.contains("原话：买菜 86"))
    }

    // MARK: - 5. 卡片（必须能被真的 AgentCardParser 解出来）

    static func sectionFive_卡片() {
        print("\n=== 5. 记账卡（既有 ```ql-card 协议 → 真解析器）===")
        let text = ChatRecordKit.cardText(title: "买菜", amount: 86, unit: "元", category: "餐饮",
                                          raw: "买菜 86", at: fixedNow(), calendar: fixedCalendar())
        check("是卡片标记行开头", text.hasPrefix("```ql-card\n"))
        check("围栏闭合", text.hasSuffix("\n```"))
        check("卡片 JSON 单行（围栏按行切，正文不能有换行）", !text.dropFirst(11).dropLast(4).contains("\n"))
        check("卡片不带动作段（协议暂无动作位：加按钮要先改 AgentCardParser/AgentResultCard）",
              !text.contains("\"actions\""))

        let segs = AgentCardParser.parse(text)
        check("解析出恰好一段", segs.count == 1)
        guard segs.count == 1, case .card(let card) = segs[0] else {
            check("解析结果应为卡片段（不是纯文本）", false)
            return
        }
        check("卡片非空", !card.isEmpty)
        check("kind = metrics（头部图标用走势款）", card.kind == .metrics)
        check("标题带事项", (card.title ?? "").contains("买菜"))
        check("状态 = 已记账", card.status?.text == "已记账")
        check("状态语义 = ok（绿）", card.status?.tone == .ok)
        check("金额 = 86.00", card.metrics.first?.value == "86.00")
        check("金额单位 = 元", card.metrics.first?.unit == "元")
        check("字段含分类", card.fields.contains { $0.key == "分类" && $0.value == "餐饮" })
        check("字段含时间", card.fields.contains { $0.key == "时间" && $0.value == "09-26 14:03" })
        check("字段含原话", card.fields.contains { $0.key == "原话" && $0.value == "买菜 86" })
        check("footer 指向宿主上的撤销按钮（指路，不是假按钮）",
              (card.footer ?? "").contains("撤销"))
        check("降级纯文本里没有人看的 JSON 花括号", !card.plainText.contains("{"))

        // 小数金额也要有分
        let t2 = ChatRecordKit.cardText(title: "打车", amount: 32.5, unit: "元", category: "交通",
                                        raw: "打车 32.5", at: fixedNow(), calendar: fixedCalendar())
        let segs2 = AgentCardParser.parse(t2)
        if segs2.count == 1, case .card(let c2) = segs2[0] {
            check("小数金额两位小数（32.50）", c2.metrics.first?.value == "32.50")
        } else {
            check("小数金额卡片可解析", false)
        }
    }

    // MARK: - 6. 去重签名与时间文案

    static func sectionSix_签名与时间文案() {
        print("\n=== 6. 去重签名 / 时间文案 ===")
        let a = ChatRecordKit.signature(sessionId: "s1", text: "买菜 86")
        let b = ChatRecordKit.signature(sessionId: "s1", text: "买菜 86")
        let c = ChatRecordKit.signature(sessionId: "s2", text: "买菜 86")
        let d = ChatRecordKit.signature(sessionId: "s1", text: " 买菜 86 ")
        check("同会话同文本 → 同签名（重试不会多记一笔）", a == b)
        check("跨会话不同签名（别的会话同句话照样记）", a != c)
        check("首尾空白归一（同签名）", a == d)
        check("去重窗口 = 10 分钟（> Store 的 2 秒连点护栏）", ChatRecordKit.repeatWindow == 600)
        check("时间文案固定时区可复现",
              ChatRecordKit.timeText(fixedNow(), calendar: fixedCalendar()) == "09-26 14:03")
        check("动作条摘要含金额与分类",
              ChatRecordKit.barSummary(amount: 86, unit: "元", category: "餐饮") == "86.00 元 · 餐饮")
    }

    // MARK: - 7. 反例占比哨兵

    static func sectionSeven_反例占比哨兵() {
        print("\n=== 7. 反例占比哨兵 ===")
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 三分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 3.0)
    }

    static func main() {
        runAllTests()
        print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
