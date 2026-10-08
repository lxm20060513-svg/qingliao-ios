import Foundation

/// P4 冷启动口径（工作模式 · 条目 17 / 18）——**三页空态文案的唯一真源**。
///
/// 条目 17：会话 / 生活 / 看板 每页 day-1 给「一句话 + 一个动作」（替掉空卡与 `--`）。
/// 条目 18：每页这句话要说清「**这台子围着什么事转**」，而不是「暂无数据」这种无信息量占位。
///
/// 口径（为什么这么写）：
///   · **一句话 = 这页在管什么**：会话=干活的地方 / 生活=你自己要推进的东西 / 看板=家里在跑什么。
///     用户第一次打开时唯一缺的不是功能，是「我该拿它干什么」——所以句子主语是事，不是数据。
///   · **一个动作 = 真能一键开始**：动作不是装饰按钮，落点是「把示例指令送进会话输入框」
///     （`ComposerSeedBox` 一次性投递），另外两页再顺带切到会话页。
///     刻意**不自动聚焦键盘**：键盘已开保持、未开不弹（用户口径）。
///   · **没有 `--` / 「暂无」/ 数字 0**：P1 已定的铁律，这里同样不许拿占位符充数。
///   · **生活模式零变更**：`guard active`，生活模式下这三处一个字都不多（生活页观感不动是用户红线）。
///   · 文案只此一处：视图里不许出现第二份（真值表会扫全仓字面量）。
enum OnboardPage: String, CaseIterable {
    case chat
    case life
    case board
}

/// 一页的冷启动引导：一句话 + 一个动作
struct OnboardGuide: Equatable {
    /// 这页围着什么事转（一句话）
    var title: String
    /// 一句补充：怎么开始
    var line: String
    /// 动作按钮文案
    var action: String
    /// 动作落点：送进会话输入框的示例指令（用户可改再发）
    var seed: String
    /// 这页自己是谁（引导卡据此判断「要不要顺手切到会话页」）
    var page: OnboardPage
    /// 点动作后要去的页（会话页自己不动；另两页切到会话）——恒为 `.chat`，等于「示例指令的去处」
    var target: OnboardPage
}

enum WorkbenchOnboard {

    /// 三页文案（工作模式）。顺序 = `OnboardPage.allCases`，缺一页都会被真值表抓住。
    static func guide(for page: OnboardPage, empty: Bool) -> OnboardGuide? {
        guard active else { return nil }
        guard empty else { return nil }
        return table[page]
    }

    /// 只有「这台子有内容了」才收起来 —— 判定输入由各页自己给（本文件不读任何数据）
    static var active: Bool { WorkbenchScope.launched == .work }

    /// 三张引导卡（唯一真源；视图不许再写字面量）
    static let table: [OnboardPage: OnboardGuide] = [
        .chat: OnboardGuide(
            title: "这里是干活的地方",
            line: "说一件事，我直接去做 —— 记账、盯进度、建场景都行",
            action: "先让它干一件",
            seed: "帮我把这个月的支出记一下",
            page: .chat,
            target: .chat),
        .life: OnboardGuide(
            title: "这里攒你自己的东西",
            line: "目标、习惯、待办、备忘 —— 围着「你要推进什么」转",
            action: "先建一个目标",
            seed: "帮我建一个长期目标：每周整理一次家里账单",
            page: .life,
            target: .chat),
        .board: OnboardGuide(
            title: "这里盯家里在跑什么",
            line: "场景、自动化、容器 —— 围着「家里怎么在运转」转",
            action: "先建一个场景",
            seed: "帮我建一个场景：晚上 11 点提醒我关客厅灯",
            page: .board,
            target: .chat),
    ]
}
