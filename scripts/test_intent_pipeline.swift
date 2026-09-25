// v3.9.71 意图管道真值表
// 被测逻辑：qingliao/Core/IntentPipeline.swift（生产代码，非镜像副本）
//           + qingliao/Core/QuickReminder.swift（datetime 判定复用它，不另写解析器）
//
// 为什么必须逐条断言：这块一旦误判，用户看到的是「把一串普通数字当成快递单号」、
// 「句子里抄了个日期就弹出加提醒」——假阳性比漏识别更伤（本仓口径）。
// 本机没有 iOS SDK、真机一轮很贵，所以判断逻辑刻意全写成纯 Foundation 纯函数，在这里钉死。
//
// 编译运行（仓库根目录，工具链见 check_swift.sh）：
//   rm -rf /tmp/ql_intent_main && mkdir -p /tmp/ql_intent_main
//   cp scripts/test_intent_pipeline.swift /tmp/ql_intent_main/main.swift
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_intent_pipeline \
//       /tmp/ql_intent_main/main.swift qingliao/Core/IntentPipeline.swift qingliao/Core/QuickReminder.swift
//   /tmp/test_intent_pipeline
//
// ⚠️ 本表只证「识别 + 动作映射 + 字段抽取」；OCR / 端侧语义 / 网络动作只能真机或接口实测。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if ok {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

/// 固定 now，避免「1 小时后」这类相对时间在不同时刻跑出不同结果
let NOW = ISO8601DateFormatter().date(from: "2026-09-23T20:00:00+08:00")!

func run(_ text: String) -> RecognizedIntent {
    IntentPipeline.classify(text: text, now: NOW)
}

// MARK: - 1. 类型判定：正例

let positives: [(String, IntentKind)] = [
    // express
    ("SF1234567890123", .express),
    ("顺丰快递单号 773012345678901", .express),
    ("快递取件码 YT4512345678901", .express),
    // amount
    ("共 128.50 元", .amount),
    ("发票金额 ¥1,280.00", .amount),
    ("电表读数 1234 度", .amount),
    ("本次用电 56.8 kWh", .amount),
    // datetime
    ("明晚八点提醒我开会", .datetime),
    ("5 分钟后提醒我关火", .datetime),
    ("每天早上 7 点半提醒我吃药", .datetime),
    // link
    ("https://example.com/a/b?x=1", .link),
    ("https://example.com/diag/ping", .link),   // 用例里的地址一律用 example.com：本仓是公开仓，真实内网 IP 不能入库
    ("www.baidu.com/s?wd=轻聊", .link),
    // contact
    ("13812345678", .contact),
    ("ming@example.com", .contact),
    ("+86 138 1234 5678", .contact),
    // address
    ("上海市浦东新区张江路 100 号", .address),
    ("广东省深圳市南山区科技园南区 8 栋", .address),
    ("幸福路 12 号 3 单元", .address),          // v3.9.71：门牌数字是地址的硬证据，必须仍认得出
]

print("── 1. 正例：类型判定 ──")
for (text, kind) in positives {
    let got = run(text).kind
    check("[\(kind.rawValue)] \(text) → \(got.rawValue)", got == kind)
}

// MARK: - 2. 反例（占 1/3 以上：假阳性比漏识别更伤）

let negatives: [String] = [
    "123456",                       // 纯数字，不是快递号
    "今天天气不错",                  // 普通句子，不该触发 datetime
    "3.5",                          // 光秃秃小数，不是金额
    "2026",                          // 年份，不是金额也不是快递号
    "abcdefg",                       // 无意义串
    "他说他下午可能来",              // 模糊时间，不该弹加提醒
    // v3.9.71 审查打回的两条日程假阳性（原来被判成 0.9 日程并给出「建提醒」）
    "充电要 5 小时",                 // 有数字+时钟字，但没有提醒意图 → 不该判日程
    "分了三期",                      // "分"是时钟字，但这里不是时间
    "￥",                            // 只有符号没有数字
]

print("── 2. 反例：必须落到 text，且只给 问AI/复制 ──")
for text in negatives {
    let r = run(text)
    check("反例 \(text) → text（实得 \(r.kind.rawValue)）", r.kind == .text)
    check("反例 \(text) 置信 <0.5（实得 \(r.confidence)）", r.confidence < 0.5)
    check("反例 \(text) 动作只有 askAI/copy（实得 \(r.actions))",
          Set(r.actions).isSubset(of: [.askAI, .copy]))
}

// MARK: - 3. 动作表映射

print("── 3. 动作表 ──")
func actionsOf(_ text: String) -> Set<IntentAction> { Set(run(text).actions) }

check("快递号 → 含 addTodo", actionsOf("SF1234567890123").contains(.addTodo))
check("快递号 → 不含 storeRecord", !actionsOf("SF1234567890123").contains(.storeRecord))
check("金额 → 含 storeRecord", actionsOf("共 128.50 元").contains(.storeRecord))
check("金额 → 不含 addReminder", !actionsOf("共 128.50 元").contains(.addReminder))
check("日期 → 含 addReminder", actionsOf("明晚八点提醒我开会").contains(.addReminder))
check("日期 → 不含 storeRecord", !actionsOf("明晚八点提醒我开会").contains(.storeRecord))
check("链接 → 含 saveToKB", actionsOf("https://example.com/a/b").contains(.saveToKB))
check("电话 → 含 call", actionsOf("13812345678").contains(.call))
check("邮箱 → 含 mailto", actionsOf("ming@example.com").contains(.mailto))
check("地址 → 含 openMap", actionsOf("上海市浦东新区张江路 100 号").contains(.openMap))
check("每种类型都给 askAI", positives.allSatisfy { actionsOf($0.0).contains(.askAI) })
check("每种类型都给 copy", positives.allSatisfy { actionsOf($0.0).contains(.copy) })

// MARK: - 4. 字段抽取

print("── 4. 字段 ──")
let amt = run("共 128.50 元")
check("金额数值 = 128.5（实得 \(amt.fields["value"] ?? "nil")）",
      Double(amt.fields["value"] ?? "") == 128.5)
check("金额单位 = 元", amt.fields["unit"] == "元")

let ex = run("顺丰快递单号 773012345678901")
check("快递单号抽出来（实得 \(ex.fields["no"] ?? "nil")）",
      ex.fields["no"] == "773012345678901")

let lk = run("https://example.com/a/b?x=1")
check("链接 host = example.com（实得 \(lk.fields["host"] ?? "nil")）",
      lk.fields["host"] == "example.com")

let ct = run("+86 138 1234 5678")
check("手机号归一化（实得 \(ct.fields["value"] ?? "nil")）",
      ct.fields["value"] == "13812345678")

let dt = run("明晚八点提醒我开会")
check("日期 iso 可解析（实得 \(dt.fields["iso"] ?? "nil")）",
      dt.fields["iso"].flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
check("日期 summary 非空（实得 \(dt.fields["summary"] ?? "nil")）",
      !(dt.fields["summary"] ?? "").isEmpty)

// raw 永远保留原文（可追溯）
for (text, _) in positives {
    check("raw 保留原文：\(text)", run(text).raw == text)
}

// MARK: - 5. 置信度与来源

print("── 5. 置信度 / 来源 ──")
// 不变式的真正意义：**写入类动作只在置信 >0.5 时出现**。
// 所以这里守两条：① 强格式 ≥0.9 ② 兜底 text 必须 <0.5（第 2 节已断言）。
// v3.9.71 审查补第三条：**弱命中的地址必须低于 0.5 动作门槛**——原来弱命中给 0.75，
// 高于门槛就会在动作条上出现"存备忘录"这种写入类动作，等于拿单字凑数当地址用。
let strongKinds: Set<IntentKind> = [.express, .amount, .datetime, .link, .contact]
for (text, kind) in positives {
    let c = run(text).confidence
    let floor: Double = strongKinds.contains(kind) ? 0.9 : 0.75
    check("[\(kind.rawValue)] 置信 ≥\(floor)（实得 \(c)）：\(text)", c >= floor)
    check("[\(kind.rawValue)] 来源 = rule：\(text)", run(text).provenance == .rule)
}
check("全部正例都高于 0.5 动作门槛", positives.allSatisfy { run($0.0).confidence > 0.5 })
// 弱命中（单字凑数的地址）必须落在写入门槛之下——**门槛在动作条里（writeGate = 0.5）**，
// 所以这里按"动作条真正会显示出来的动作"断言，而不是动作表原始列表：
//   「今天市区路况一般」有 市/区/路 三个字凑数，但没有门牌 → kind 仍是 address，
//   置信 0.4 < 0.5 → 动作条只显示问 AI / 复制（不会出现"打开地图/存备忘录"）
for weak in ["今天市区路况一般", "小区路口有家便利店"] {
    let r = run(weak)
    check("弱命中「\(weak)」置信 <0.5（实得 \(r.confidence)）", r.confidence < 0.5)
    let shown = r.confidence >= 0.5 ? r.actions : r.actions.filter { $0 == .askAI || $0 == .copy }
    check("弱命中「\(weak)」动作条只显示 askAI/copy（实得 \(shown)）",
          shown.map { $0.rawValue }.sorted() == ["askAI", "copy"])
}
// 反面对照：真门牌地址必须过门槛（否则"别收过头"——把正经地址也挡在门外）
let realAddr = run("幸福路 12 号 3 单元")
check("真门牌地址置信 ≥0.9（实得 \(realAddr.confidence)）", realAddr.confidence >= 0.9)
check("真门牌地址给出打开地图", realAddr.actions.contains(.openMap))
// 单位归一（RecordKit.normalizeUnit）：不归一的话"块钱"会被当成读数，金额永远进不了本月合计
check("单位归一 块钱 → 元", RecordKit.normalizeUnit("块钱") == "元")
check("单位归一 人民币 → 元", RecordKit.normalizeUnit("人民币") == "元")
check("单位归一 ￥ → 元", RecordKit.normalizeUnit("￥") == "元")
check("单位归一 度电 → 度", RecordKit.normalizeUnit("度电") == "度")
check("单位归一 kwh → kWh", RecordKit.normalizeUnit("kwh") == "kWh")
check("单位归一 千瓦时 → kWh", RecordKit.normalizeUnit("千瓦时") == "kWh")
check("单位归一 空 → 空", RecordKit.normalizeUnit(nil) == "" && RecordKit.normalizeUnit("  ") == "")
check("title 非空", positives.allSatisfy { !run($0.0).title.isEmpty })

// MARK: - 6. 边界：空串 / 超长 / 换行

print("── 6. 边界 ──")
let empty = run("")
check("空串 → text", empty.kind == .text)
check("空串置信 0", empty.confidence == 0)
let longText = String(repeating: "这是一段很长的普通文本。", count: 200)
check("超长文本不崩且 → text", run(longText).kind == .text)
let multiline = "https://example.com/x\n13812345678"
check("多行不崩（取首个强格式即可）", [IntentKind.link, .contact].contains(run(multiline).kind))

// MARK: - 7. 记录容器纯逻辑（RecordKit，生活页「本月合计」的真相）
//
// 为什么单独有一节：合计算错/文案串单位，用户在生活页看到的就是假数字。
// 分层：模型 + 合计放 RecordKit.swift（纯 Foundation，本表可编）；状态读写放 RecordStore.swift（SwiftUI，只能真机）。

print("── 7. 记录容器 ──")
let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return c
}()
func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}
let recs: [RecordItem] = [
    RecordItem(kind: "amount", title: "超市", amount: 128.5, unit: "元", note: "", source: "intent", createdAt: day(2026, 9, 2)),
    RecordItem(kind: "amount", title: "打车", amount: 31.5, unit: "元", note: "", source: "intent", createdAt: day(2026, 9, 10)),
    RecordItem(kind: "meter", title: "电表", amount: 1234, unit: "度", note: "", source: "intent", createdAt: day(2026, 9, 23)),
    RecordItem(kind: "amount", title: "上月餐费", amount: 500, unit: "元", note: "", source: "manual", createdAt: day(2026, 8, 31)),
]
let sep = RecordKit.monthTotal(recs, now: day(2026, 9, 23), calendar: cal)
check("本月合计只算本月、只算「元」（实得 \(sep.amount) 元 / \(sep.count) 条）",
      sep.count == 2 && abs(sep.amount - 160.0) < 0.001)
let aug = RecordKit.monthTotal(recs, now: day(2026, 8, 31), calendar: cal)
check("切到上月：只有 1 条 500 元", aug.count == 1 && abs(aug.amount - 500) < 0.001)
check("读数不混进金额合计（度≠元）", sep.amount != 1234 + 160)
check("最近读数 = 电表（实得 \(RecordKit.latestMeter(recs)?.title ?? "nil")）",
      RecordKit.latestMeter(recs)?.title == "电表")

// 撤销 = 按 id 回删后合计应立刻变小（动作条"撤销"走的就是这条路径）
let afterDelete = recs.filter { $0.id != recs[0].id }
let sep2 = RecordKit.monthTotal(afterDelete, now: day(2026, 9, 23), calendar: cal)
check("删掉 128.5 那条后合计降到 31.5", sep2.count == 1 && abs(sep2.amount - 31.5) < 0.001)

check("monthKey 跨年不串（2025-12 / 2026-01）",
      RecordKit.monthKey(day(2025, 12, 31), calendar: cal) == "2025-12" &&
      RecordKit.monthKey(day(2026, 1, 1), calendar: cal) == "2026-01")

check("金额文案 128.5 元 → 128.50 元", RecordKit.amountText(128.5, unit: "元") == "128.50 元")
check("读数文案 1234 度 → 1234 度", RecordKit.amountText(1234, unit: "度") == "1234 度")
check("小数读数 56.8 kWh → 56.8 kWh", RecordKit.amountText(56.8, unit: "kWh") == "56.8 kWh")

check("排序最新在前（实得 \(RecordKit.sorted(recs).first?.title ?? "nil")）",
      RecordKit.sorted(recs).first?.title == "电表")

// 旧数据兼容：缺 amount/unit/note 键也必须能解（TodoStore 的坑 1，照抄）
let legacyJSON = #"[{"id":"a","kind":"note","title":"旧条目","source":"manual","createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-01T10:00:00Z"}]"#
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
let legacyDecoded = try? legacyDecoder.decode([RecordItem].self, from: legacyJSON.data(using: .utf8)!)
check("旧 JSON 缺字段不崩（decodeIfPresent）", legacyDecoded?.count == 1)
check("旧条目缺 amount 时 amountText 不崩", legacyDecoded?.first.map { $0.amountText.isEmpty == false } ?? false)

// MARK: - 8. 动作表完整性（源码级护栏：加了新动作不许漏文案 / 图标 / 执行分支）
//
// 为什么要有：动作表是"三处必须同步"的典型（IntentAction case / 动作条文案图标 / 执行器分支）。
// 漏一处不会编译失败——用户看到的是"点了一个没文字的按钮"或"点了没反应"，只能靠人肉发现。
// 本段直接读仓库源码断言，改路径这里会红（故意让它红）。

print("── 8. 动作表完整性 ──")
let allActions: [IntentAction] = [.storeRecord, .addTodo, .addReminder, .saveMemo,
                                 .saveToKB, .openMap, .call, .mailto, .copy, .askAI]
let barSrc = (try? String(contentsOfFile: "qingliao/Features/Chat/IntentActionBar.swift",
                          encoding: .utf8)) ?? ""
let runnerSrc = (try? String(contentsOfFile: "qingliao/Core/IntentActionRunner.swift",
                             encoding: .utf8)) ?? ""
check("读得到动作条源码（路径没被挪）", !barSrc.isEmpty)
check("读得到执行器源码（路径没被挪）", !runnerSrc.isEmpty)
for a in allActions {
    check("动作 \(a.rawValue)：动作条有文案+图标", barSrc.components(separatedBy: "case .\(a.rawValue): return").count >= 3)
    check("动作 \(a.rawValue)：执行器有分支", runnerSrc.contains("case .\(a.rawValue):"))
}
// 动作条不得出现二次确认（用户明确不喜欢整天审批）
check("动作条没有 alert/二次确认", !barSrc.contains(".alert(") && !barSrc.contains("confirmationDialog"))
// 失败必须出声
check("执行器失败路径要求出声（动作条有 Haptics.error）", barSrc.contains("Haptics.error()"))
// 低置信门槛必须存在（0.5）：改小了等于让兜底内容也能写入
check("写入类动作门槛 0.5 还在", barSrc.contains("writeGate = 0.5"))


// MARK: - 9. 大爆炸底部条口径护栏（v3.9.72：用户截图报「左下角胶囊没字」）
//
// 事故经过：底部条每个按钮**各写一套内边距**（图标胶囊各 `Spacing.xxl`=14、全选/清除各 18、复制写死
// `minWidth: 120`）→ 整行约 456pt，可用宽度 393pt（截图 1179px ÷ 3）→ SwiftUI 优先压缩 Text，
// 「全选」「清除」被压成 0 宽只剩内边距 = 两个没有字的灰空胶囊。修完必须锁住，否则谁再加一颗就复发。
// 🚨 v3.9.72 审查修正：断言改成**切片式**。整文件级断言双向失真——别处合理用一次 Spacing.xxl 会假红，
// 换个字面量（frame(minWidth: 140) / Spacing.section 内边距）当硬宽度又会假绿，事故边界是「底部条那一行」。

print("── 9. 大爆炸底部条口径 ──")
// 去注释后再判（注释里会提到这些字面量，不算违规）
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
let bbRaw = (try? String(contentsOfFile: "qingliao/Features/BigBang/BigBangView.swift", encoding: .utf8)) ?? ""
check("能读到 BigBangView 源码（路径别改）", !bbRaw.isEmpty)
let bbSrc = stripComments(bbRaw)
// 切片：只切底部条那个函数体（锚点都是代码行）
let barSlice: String = {
    guard let a = bbSrc.range(of: "private func bottomBar(showCopyCount:"),
          let b = bbSrc.range(of: "private func wordChip(") else { return "" }
    return String(bbSrc[a.lowerBound..<b.lowerBound])
}()
check("底部条切片可切出（空了后面全是空真）", !barSlice.isEmpty)
check("底部条胶囊走 .pill 口径（topBar ×4）", barSlice.components(separatedBy: ".pill(.topBar").count - 1 >= 4)
// 🚨 v3.9.77 **用户定稿推翻旧口径**：原 v3.9.72 让"主操作"（复制）走 `.pill(.primary)` —— 那是**另一套尺寸**，
//   同一排里它比旁边的「全选/清除/两个图标」更高更宽。用户装机后明确报「底部的胶囊需统一样式和大小」。
//   → 尺寸口径统一为 `.topBar`（全部 5 颗），主次改用 **tone(.accent)** 区分。别再按 v3.9.72 改回去。
// 本表没有 stripCommentLines helper → 就地剥整行注释（注释里叙述旧写法不该算回退）
let barCode = barSlice.split(separator: "\n")
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")
check("底部条胶囊尺寸统一（不得再混 .pill(.primary)＝另一套尺寸）", !barCode.contains(".pill(.primary)"))
// 🚨 v3.9.77 用户二次澄清：「统一样式和大小」= 样式与尺寸都要一致 → 复制胶囊不再用 accent 强调色。
check("底部条 5 颗完全一致（同尺寸 + 同色调 neutral）",
      barCode.components(separatedBy: ".pill(.topBar, tone: .neutral)").count - 1 >= 5
      && !barCode.contains(".pill(.topBar, tone: .accent)"))
check("底部条 5 颗胶囊全部同一尺寸口径", barSlice.components(separatedBy: ".pill(.topBar").count - 1 >= 5)
check("文字标签防压缩（fixedSize ≥3）", barSlice.components(separatedBy: ".fixedSize()").count - 1 >= 3)
check("底部条不再手写水平内边距（根因）", !barSlice.contains(".padding(.horizontal"))
check("底部条不再有硬宽度 minWidth", !barSlice.contains("minWidth"))
check("行间距收到 8", barSlice.contains("HStack(spacing: 8)"))
check("全选/清除保持文字胶囊", barSlice.contains("Text(\"全选\").pill(") && barSlice.contains("Text(\"清除\").pill("))
check("复制计数只在有选中时显示（不再恒显 复制 (0)）", barSlice.contains("showCopyCount && !selected.isEmpty"))
// 排除式：带括号的旧写法更宽（约 +8pt），别改回去（用原始字符串避免转义地狱）
check("复制标签不再写成带括号的 复制 (N)（宽度口径）", !barSlice.contains(#"复制 (\(selected.count))"#))
// 行宽兜底：ViewThatFits 两稿（完整版放不下 → 图标版），否则 fixedSize 关掉压缩兜底会整行溢出被裁
check("ViewThatFits 两稿兜底在位",
      bbSrc.contains("ViewThatFits(in: .horizontal)")
      && bbSrc.contains("bottomBar(showCopyCount: true)")
      && bbSrc.contains("bottomBar(showCopyCount: false)"))
check("行内边距收到 12", bbSrc.contains(".padding(.horizontal, 12)"))

// MARK: - 10. 空态输入框可见性护栏（v3.9.72：用户截图报「输入法会遮住输入框」）
//
// 事故：空态欢迎页是不可滚动的定高内容（留白 56 + 球 96 + 文案 + 4 芯片 + 续聊卡 ≈ 380pt），
// 九宫格键盘 + 候选栏 ≈ 340pt，可用高度只剩 ≈344pt → VStack 压不动欢迎页，就把输入栏挤到键盘后面。
// 修法=输入栏 layoutPriority(1) + 欢迎页键盘弹起时收缩。这里锁住两处，免得改 UI 时退回原样。

print("── 10. 空态输入框可见性 ──")
let cvRaw = (try? String(contentsOfFile: "qingliao/Features/Chat/ChatView.swift", encoding: .utf8)) ?? ""
check("能读到 ChatView 源码（路径别改）", !cvRaw.isEmpty)
let cvSrc = stripComments(cvRaw)
// 🚨 优先权必须挂在**输入栏那一层**（inputArea），不能挂整个 chatComposerArea：整组还含选图条 /
// 动作条 / 附件面板 / 引用条（各自定高，合计 ≈380pt），键盘与它们同开时输入栏本身仍会被顶出可见区。
let composerSlice: String = {
    guard let a = cvRaw.range(of: "private var chatComposerArea"),
          let b = cvRaw.range(of: "// MARK: - v3.7.0 剪贴板地图链接") else { return "" }
    return String(cvRaw[a.lowerBound..<b.lowerBound])
}()
check("composer 切片可切出（空了后面全是空真）", !composerSlice.isEmpty)
check("优先权落在输入栏那一层（切片里 inputArea + layoutPriority 同在）",
      composerSlice.contains("inputArea") && composerSlice.contains(".layoutPriority(1)"))
check("优先权不再挂整个 chatComposerArea", !cvSrc.contains("chatComposerArea\n                .layoutPriority(1)"))
check("输入栏优先权全文件只出现 1 次", cvSrc.components(separatedBy: ".layoutPriority(1)").count - 1 == 1)
check("欢迎页顶部留白随键盘收起", cvSrc.contains("Spacer(minLength: kb.isVisible ? 0 : 56)"))
// v3.9.78：欢迎页形象已从液态球换成卡通宠物（PetAvatar）——「身份尺寸不因布局改动而变」这条口径不变，只是主体换了
check("欢迎页形象保持既有尺寸口径（96pt，不因布局改小）", cvSrc.contains("PetAvatar(size: 96,"))
check("建议芯片随键盘收起", cvSrc.contains("if !kb.isVisible {") && cvRaw.contains("// if !kb.isVisible（建议芯片）"))
check("续聊卡随键盘收起", cvSrc.contains("!clearing, !kb.isVisible {"))

// ── 9. 意图动作卡外观口径（v3.9.78 用户定稿「方案 C」：「弹窗卡片圆角加大，背景改成模糊半透明」）──
// 旧形态 = `.regularMaterial` + `Radius.inset`(12) + `Color.primary.opacity(0.06)` 暗发丝线 ——
// 浅色底上材质偏白，看着像**实心卡**；定稿 = 浮层玻璃口径（`.ultraThinMaterial` 同族最薄 + `Radius.hero`(22)
// + 白 0.8pt 亮边），实现收在 `Theme/LiquidGlass.swift` 的 `OverlayGlassCard`（`.overlayGlassCard()`）——
// 用户随后说「同口径也推到其它弹窗」，识别浮层卡 / 速记待办输入卡共用同一处口径
// （调用点清单与单一真源断言见 智慧球菜单真值表 第 11 节）。
let barCardSlice: String = {
    guard let a = barSrc.range(of: ".frame(maxWidth: .infinity, alignment: .leading)"),
          let b = barSrc.range(of: ".padding(.horizontal, Spacing.section)") else { return "" }
    return String(barSrc[a.lowerBound..<b.lowerBound])
}()
check("意图卡外观切片可切出（空了后面全是空真）", !barCardSlice.isEmpty)
// ⚠️ 排除式断言一律先剥注释：本卡的注释里就写着旧口径（Radius.inset / .regularMaterial），
//    不剥会把「说明」当成回退 → 假红（本仓踩过多次）。
let cardClean = stripComments(barCardSlice)
check("走浮层玻璃口径 .overlayGlassCard()（口径数值不写在调用点）",
      cardClean.contains(".overlayGlassCard()"))
check("旧的实心卡口径清零（.regularMaterial / Radius.inset / 暗发丝线）",
      !cardClean.contains(".regularMaterial")
      && !cardClean.contains("Radius.inset")
      && !cardClean.contains("Color.primary.opacity(0.06)"))
check("调用点不再自己画圆角/材质（单一口径只在 OverlayGlassCard 里）",
      !cardClean.contains("RoundedRectangle(cornerRadius:"))
check("浮层投影留在调用点（0.12 / 12 / y4）",
      cardClean.contains(".shadow(color: .black.opacity(0.12), radius: 12, y: 4)"))

print("\n———————————————")
print(failures == 0 ? "✅ 全部通过 \(total)/\(total)" : "❌ 失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
