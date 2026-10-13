// #3 轻聊斜杠命令层 —— 行为测试（真跑生产源码 qingliao/Core/SlashCommands.swift）
//
// 为什么编生产源码而不是镜像：镜像实现会与生产代码各改各的（本仓 5b 的教训），
// 解析口径改坏也全绿。这里编的就是 Core/SlashCommands.swift，纯 Foundation、Linux 可编可跑。
//
// 钉住的是「静默退化」面：
//   · 注册表少一条 / 多一条（面板与帮助卡都靠 allCases 迭代，少一条用户就永远看不到那条命令）；
//   · parse 对**未知命令**返回 nil → send() 会把它当普通消息发给模型（污染上下文 / 复读源）；
//   · 前导/尾部空白、参数内空格、中文命令名切分（`/记一笔 35 咖啡`）的容错一旦丢，用户输入「看着对但不生效」；
//   · 面板前缀过滤与「点选填入」口径漂移（`/h` 点完填的不是 `/help`）。
//
// ⚠️ 入口文件名必须叫 main.swift（多文件一起编译时只有 main.swift 允许顶层代码）→ 由 check_swift.sh 复制。

import Foundation

// main.swift 里的顶层代码本身就是 MainActor 隔离的（且顶层变量不许标全局 actor），
// 所以这两个计数器只能是裸 var；下面的 check/section 都标 @MainActor 以便被顶层直接调用。
var passCount = 0
var failCount = 0

@MainActor
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

@MainActor
func eqParse(_ s: String, _ cmd: SlashCommand?, _ arg: String) -> Bool {
    guard let r = SlashParser.parse(s) else { return false }
    return r.cmd == cmd && r.arg == arg
}

// MARK: - A. 命令注册表（v1 六条，标题/说明/是否带参）

@MainActor
func sectionA_注册表() {
    let all = SlashCommand.allCases
    check("v1 恰好 6 条命令（多一条少一条都要显式改表）", all.count == 6)
    check("顺序稳定 = 定义序", all == [.new, .model, .stop, .usage, .expense, .help])
    check("显示名带前导 /（面板与帮助卡直接用）",
          all.map { $0.title } == ["/new", "/model", "/stop", "/usage", "/记一笔", "/help"])
    check("中文命令名保留（不是拼音/英文别名）", SlashCommand.expense.rawValue == "记一笔")
    check("每条都有非空说明", all.allSatisfy { !$0.hint.isEmpty })
    check("说明不相同（面板两行文字才有信息量）", Set(all.map { $0.hint }).count == all.count)
    check("只有 /记一笔 要参数", all.filter { $0.takesArgument } == [.expense])
    check("无参命令的填入模板 = 命令名本身", SlashCommand.new.fillTemplate == "/new")
    check("带参命令的填入模板留尾空格（点选后能接着打字）", SlashCommand.expense.fillTemplate == "/记一笔 ")
}

// MARK: - B. parse：容错与三个返回约定

@MainActor
func sectionB_解析() {
    // 非命令 → nil（照常走 sendCore）
    check("普通文本不是命令 → nil", SlashParser.parse("你好") == nil)
    check("空串不是命令 → nil", SlashParser.parse("") == nil)
    check("纯空白不是命令 → nil", SlashParser.parse("   ") == nil)
    check("不以 / 开头就不是命令 → nil", SlashParser.parse(" new") == nil)
    check("URL 文本不误判（http://…）", SlashParser.parse("http://x.com/a") == nil)

    // 六条命令都能认出（空参）
    check("/new 空参", eqParse("/new", .new, ""))
    check("/model 空参", eqParse("/model", .model, ""))
    check("/stop 空参", eqParse("/stop", .stop, ""))
    check("/usage 空参", eqParse("/usage", .usage, ""))
    check("/help 空参", eqParse("/help", .help, ""))
    check("/记一笔 空参（带参命令允许不写参数）", eqParse("/记一笔", .expense, ""))

    // 容错
    check("前导/尾部空白容错", eqParse("  /new  ", .new, ""))
    check("大小写不敏感（/NEW）", eqParse("/NEW", .new, ""))
    check("参数内允许空格：/记一笔 35 咖啡", eqParse("/记一笔 35 咖啡", .expense, "35 咖啡"))
    check("参数首尾空白裁掉", eqParse("/记一笔   35 咖啡  ", .expense, "35 咖啡"))
    check("无参命令后面也能跟东西（参数不丢）", eqParse("/new hello", .new, "hello"))
    check("命令名大小写混写也能匹配", eqParse("/Help", .help, ""))

    // ⚠️ 两条关键约定（独立审查抓过一次误伤后定稿）：
    //   ① **只有**「/ + 单个不含斜杠的 token」才算命令形态；单独 `/`、`/usr/bin 是什么` 这类
    //      路径问句（token 里还有斜杠）一律 nil（直通给 AI）—— 否则用户原话被吞 + 草稿被清。
    //   ② 未知命令（/foobar）仍**必须返回非 nil**（cmd == nil），由调用方插提示卡、不发模型。
    check("单独一个 / → 不是命令（直通，不吞不消草稿）", SlashParser.parse("/") == nil)
    check("单独一个 / 带空白 → 不是命令", SlashParser.parse("/ ") == nil)
    check("路径问句 `/usr/bin 是什么` → 不是命令（直通给 AI）",
          SlashParser.parse("/usr/bin 是什么") == nil)
    check("路径问句 `/etc/hosts 怎么改` → 不是命令（直通给 AI）",
          SlashParser.parse("/etc/hosts 怎么改") == nil)
    check("无空格路径 `/usr/bin` → 不是命令（直通给 AI）", SlashParser.parse("/usr/bin") == nil)
    let unknown = SlashParser.parse("/foobar")
    check("未知命令返回非 nil（不是「非命令」）", unknown != nil)
    check("未知命令的 cmd 为 nil（由调用方分辨）", unknown?.cmd == nil)
    check("未知命令的原文不进 arg", unknown?.arg == "")
    check("未知命令带参数也照样返回非 nil", SlashParser.parse("/zzz 1 2")?.cmd == nil)
}

// MARK: - C. 面板前缀过滤 + 填入模板 + 触发口径

@MainActor
func sectionC_面板() {
    check("空前缀（/）→ 全部命令", SlashParser.matches(prefix: "/") == SlashCommand.allCases)
    check("空串前缀 → 全部命令（面板初值口径）", SlashParser.matches(prefix: "") == SlashCommand.allCases)
    check("/h → 只剩 /help", SlashParser.matches(prefix: "/h") == [.help])
    check("/n → 只剩 /new", SlashParser.matches(prefix: "/n") == [.new])
    check("/mo → 只剩 /model", SlashParser.matches(prefix: "/mo") == [.model])
    check("大写前缀也认（/S → /stop）", SlashParser.matches(prefix: "/S") == [.stop])
    check("中文前缀 /记 → /记一笔", SlashParser.matches(prefix: "/记") == [.expense])
    check("无匹配 → 空（面板高度 0，自然不显示）", SlashParser.matches(prefix: "/zzz").isEmpty)
    check("空前缀时面板列满 6 行（覆盖全部命令）",
          SlashParser.matches(prefix: "/").count == 6)

    // 点选填入后再解析，必须回到同一条命令（往返一致）
    for cmd in SlashCommand.allCases {
        let back = SlashParser.parse(cmd.fillTemplate)
        check("往返：\(cmd.title) 点选填入后仍解析为同一条命令", back?.cmd == cmd)
    }

    // 触发口径（单一真源）
    check("/ 触发面板", SlashParser.panelPrefix("/") == "/")
    check("/h 触发面板且前缀就是 /h", SlashParser.panelPrefix("/h") == "/h")
    check("中文命令也能触发面板", SlashParser.panelPrefix("/记一笔") == "/记一笔")
    check("前导空白裁掉后仍触发", SlashParser.panelPrefix("  /new ") == "/new")
    check("普通文本不触发面板", SlashParser.panelPrefix("你好") == nil)
    check("空串不触发面板", SlashParser.panelPrefix("") == nil)
    check("⚠️ 带空格的命令（已经在输参数）不触发面板",
          SlashParser.panelPrefix("/记一笔 35") == nil)
    check("含空格的任意输入都不触发面板", SlashParser.panelPrefix("/a b") == nil)
}

// MARK: - D. 金额抽取（/记一笔 口径）

@MainActor
func sectionD_金额() {
    check("首个数字即金额", SlashParser.leadingNumber("35 咖啡") == 35)
    check("数字在后面也认（v1 口径：不猜语序）", SlashParser.leadingNumber("咖啡35") == 35)
    check("小数金额", SlashParser.leadingNumber("12.5 打车") == 12.5)
    check("没有数字 → nil（调用方提示、不落库）", SlashParser.leadingNumber("咖啡") == nil)
    check("空串 → nil", SlashParser.leadingNumber("") == nil)

    check("切分：金额 + 用途", SlashParser.expenseParts("35 咖啡")?.amount == 35
          && SlashParser.expenseParts("35 咖啡")?.item == "咖啡")
    check("切分：数字在后，剩余仍是用途", SlashParser.expenseParts("咖啡35")?.item == "咖啡")
    check("切分：只有数字 → 用途为空（调用方兜底标题）",
          SlashParser.expenseParts("35")?.amount == 35 && SlashParser.expenseParts("35")?.item == "")
    check("切分：小数金额", SlashParser.expenseParts("12.5 打车")?.amount == 12.5)
    check("切分：没数字 → nil", SlashParser.expenseParts("咖啡") == nil)
    check("切分：数字只被吃掉一次（剩余的另一个数字留在用途里）",
          SlashParser.expenseParts("35 买了 2 杯咖啡")?.item == "买了 2 杯咖啡")
}

// MARK: - 入口

@MainActor
func main() {
    sectionA_注册表()
    sectionB_解析()
    sectionC_面板()
    sectionD_金额()
    if failCount == 0 {
        print("✅ ALL PASS（\(passCount) 项）")
        exit(0)
    }
    print("❌ 失败 \(failCount) 项 / 通过 \(passCount) 项")
    exit(1)
}

main()
