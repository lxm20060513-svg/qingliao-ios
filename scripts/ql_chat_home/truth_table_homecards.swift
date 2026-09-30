import Foundation

// MARK: - v4.0.10 聊天首页「方块卡片」真值表
//
// 被测真源 = `qingliao/Core/HomeCardOrder.swift`（纯 Foundation，无 SwiftUI）。
// 本表**直接编译那份源码**（不是镜像），所以没有「表与实现漂移」这个洞：
//   swiftc -swift-version 6 scripts/ql_chat_home/main.swift qingliao/Core/HomeCardOrder.swift
//
// 本表钉九件事（都是「本机一眼能查、真机上才看得出来」的形态）：
//   ① **相对位移拖拽口径**（HomeCardOrder.dragTarget）：手指微抖不许把卡甩到 0 号槽
//      —— 绝对格算法在本表里是被钉死的反面（旧写法真机手感崩）；
//   ② **写回保位**（mergeVisible）：关掉的卡留在原槽，重开精确回原位，
//      不是「追加到末尾」（那样用户会觉得排序被重置）；
//   ③ **至少留一张真卡**：全关会让首页只剩「空槽位」，用户当 App 坏了 → 最后一张拒关；
//   ④ 顺序串容错：未知 kind 丢弃、重复去重、缺失按 catalog 补齐（升级加卡不重置用户排序）；
//   ⑤ 2 列分行：落单补 nil 占位、元素守恒、columns <= 0 返回空；
//   ⑥ 单一真源：UserDefaults 键字面量全仓只有 HomeCardOrder.swift 一处；
//   ⑦ UI 不自算几何：拖拽走 HomeCardOrder.dragTarget、写回走 HomeCardOrder.mergeVisible；
//   ⑧ 接入形态：ChatView 的 welcomeView 里挂 homeCardsGrid（键盘弹起同档收起）；
//   ⑨ 胶囊口径：首页「自定义」胶囊走**栏目头档** sectionHeaderPill()（v4.0.10 起，比聊天页顶栏那档
//      矮 4pt），不许再手写 ultraThinMaterial 胶囊；聊天页顶栏那档 chatHeaderPill() 不许跟着变矮；
//   ⑩ v4.0.9（用户拍板）：**空槽位可关**（旧实现无条件补回 = 关不掉的真根因）、页脚那条
//      「继续上次」长条卡**已删除**（resumeRow 零残留，用途由首页「继续上次会话」方块卡承担）；
//   ⑪ v4.0.10 真机两条坏形（用户配图 + 手报）：**卡高恒定**（agentTip 副标题折两行 → 内容 ~94pt
//      顶在 84pt 槽位、ZStack 居中溢出 → 真机「这张卡大小不一样」；像素量 283px vs 同排 254px）
//      ＋ **长按拖动真能成立**（卡片是 Button，内置手势拦住挂父级的长按 → 拖不动；
//      改 simultaneousGesture，并用 suppressTapUntil 挡掉松手后的误触轻点）
//      ＋ **慢点击不许被吞**（二修：门闩只在**真位移 ≥ 6pt** 时上 —— 按住不动再松手 = 轻点照常执行；
//      长按门槛 0.28 → 0.40s）
//      ＋ **栏目头「自定义」胶囊变矮**（原先借聊天页顶栏档 27pt，在 11pt 栏目头旁又高又重 →
//      新档 15 + 2×Spacing.xs = 23pt；只压高度，字号/横内距/描边不动）。
//   ⑫ v4.0.10（用户要求「在设置里增加可以关掉首页快捷卡片功能」）：总开关 `HomeCardStore.enabledKey`
//      —— **键缺失 = 开**（老用户行为不变，别用 bool(forKey:)）、默认值走 `enabledDefault` 单一真源、
//      关掉 = **整块不渲染且不留空占位**（留占位等于关不掉）、设置页那一行必须恒在
//      （首页关了就没别的入口可点了，否则只能删 App 重装才能开回来）。

// Swift 6 严格并发：main.swift 顶层代码是 @MainActor 隔离的，而顶层变量不能挂 global actor
// → 计数器用 nonisolated(unsafe)（单线程顺序跑，无并发访问），这样 check 从顶层调用得通
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它（注释里讲清「不许出现什么」时，否则会被自己染红）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
/// 去掉全部空白 —— 顺序/相邻类断言不受缩进漂移影响
func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }
/// 取 `func xxx` 到函数体收尾（4 空格缩进的 `}`）之间的源码。
/// 用途：口径类断言必须**只看这个函数体**——「同名 token 在文件别处出现过就算过」是假绿。
func fnBody(_ sig: String, _ s: String) -> String {
    guard let r = s.range(of: sig) else { return "" }
    let rest = s[r.lowerBound...]
    guard let e = rest.range(of: "\n    }") else { return String(rest) }
    return String(rest[rest.startIndex..<e.lowerBound])
}

let coreSrc = src("qingliao/Core/HomeCardOrder.swift")
let cards = src("qingliao/Features/HomeCards.swift")
let chat = src("qingliao/Features/Chat/ChatView.swift")
let gate = src("check_swift.sh")
let pill = src("qingliao/Theme/Pill.swift")
let settings = src("qingliao/Features/Settings/SettingsCore.swift")

check("HomeCardOrder.swift 源可读", !coreSrc.isEmpty)
check("HomeCards.swift 源可读", !cards.isEmpty)
check("ChatView.swift 源可读", !chat.isEmpty)
check("check_swift.sh 源可读", !gate.isEmpty)
check("Pill.swift 源可读（栏目头/聊天页头两档口径都在它里面）", !pill.isEmpty)

// ── ① 目录与默认档 ─────────────────────────────────────────────
check("卡片种类 7 类（mail/resume/todo/weather/expense/agentTip/custom）",
      HomeCardKind.allCases.count == 7)
check("catalogOrder == allCases（默认顺序 = 目录顺序，不另写一份数组）",
      HomeCardKind.catalogOrder == HomeCardKind.allCases)
check("可拖拽 6 张、空槽位不进拖拽流",
      HomeCardKind.draggable.count == 6 && !HomeCardKind.draggable.contains(.custom))
check("默认关掉的三张 = [todo, weather, expense]",
      HomeCardStore.defaultOff == [.todo, .weather, .expense])
check("默认档下首屏 4 张 = [mail, resume, agentTip, custom]",
      HomeCardOrder.resolve(order: "", off: HomeCardOrder.encode(HomeCardStore.defaultOff))
        == [.mail, .resume, .agentTip, .custom])

// ── ② 顺序串容错（parse / encode / resolve） ────────────────────
check("parse 空串 → 空列表", HomeCardOrder.parse("").isEmpty)
check("parse 容忍空格：\" mail , resume \" → [mail, resume]",
      HomeCardOrder.parse(" mail , resume ") == [.mail, .resume])
check("parse 丢弃未知 kind（老版本删卡/改名不让老用户首页崩）",
      HomeCardOrder.parse("mail,zzz_resume,resume") == [.mail, .resume])
check("encode 往返：encode → parse 恒等",
      HomeCardOrder.parse(HomeCardOrder.encode([.todo, .mail, .custom])) == [.todo, .mail, .custom])
check("encode 空列表写空串（「顺序」没有全关语义，不写哨兵）",
      HomeCardOrder.encode([]) == "")
check("resolve 去重：重复 kind 只留一次",
      HomeCardOrder.resolve(order: "mail,mail,mail", off: "").count == 7)
check("resolve 补齐新卡：顺序串只有 resume → 首项 resume + 其余按 catalog 排尾",
      HomeCardOrder.resolve(order: "resume", off: "") == [.resume] + HomeCardKind.catalogOrder.filter { $0 != .resume })
check("resolve 未知项不影响补全：\"zzz,mail\" → 7 项且首项 mail",
      HomeCardOrder.resolve(order: "zzz,mail", off: "").first == .mail
        && HomeCardOrder.resolve(order: "zzz,mail", off: "").count == 7)
check("resolve 过滤被关的卡", !HomeCardOrder.resolve(order: "", off: "todo,weather").contains(.todo))
check("resolve 只在「列表为空」时兜底；全关时剩下的 custom 不算数 → 开关侧必须自己拒关最后一张真卡",
      HomeCardOrder.resolve(order: "", off: HomeCardOrder.encode(HomeCardKind.draggable)) == [.custom])
check("atLeastOne([]) == [resume]；非空原样返回",
      HomeCardOrder.atLeastOne([]) == [.resume]
        && HomeCardOrder.atLeastOne([.mail, .todo]) == [.mail, .todo])

// ── ③ 开关：至少留一张真卡（空槽位不算卡） ──────────────────────
check("🚨 开关方向不许反：打开 → 从 off 移除（不给加上）；关闭 → 加进 off",
      HomeCardOrder.setEnabled([], .todo, on: true) == []
        && HomeCardOrder.setEnabled([], .todo, on: false) == [.todo])
check("重复关幂等",
      HomeCardOrder.setEnabled([.mail], .mail, on: false) == [.mail])
check("重新打开：从 off 移除（回原位由完整顺序串保证）",
      HomeCardOrder.setEnabled([.mail, .todo], .mail, on: true) == [.todo])
check("面板绑定方向与实现自洽（get = !off.contains(k)，set 传 newVal）",
      flat(stripCommentLines(cards)).contains("get:{!off.contains(k)}")
        && flat(stripCommentLines(cards)).contains("off=HomeCardOrder.setEnabled(off,k,on:newVal)"))
check("打开已打开的卡幂等（off 里没有它 → 不变）",
      HomeCardOrder.setEnabled([.todo], .mail, on: true) == [.todo])
check("🚨 拒关最后一张真卡：只剩 resume 时再关它 → 原样返回（首页不能只剩空槽位）",
      HomeCardOrder.setEnabled(HomeCardKind.draggable.filter { $0 != .resume }, .resume, on: false)
        == HomeCardKind.draggable.filter { $0 != .resume })
check("对照：还剩别的真卡时允许关（不是把整排开关禁掉）",
      HomeCardOrder.setEnabled([.mail, .todo, .weather, .expense], .resume, on: false)
        == [.mail, .todo, .weather, .expense, .resume])
check("v4.0.9 空槽位可关（旧口径「UI 禁用 + 逻辑再守一道」已按用户要求撤销）",
      HomeCardOrder.setEnabled([.mail], .custom, on: false) == [.mail, .custom])
check("真卡全关时再关空槽位 → 仍拒关（首页不会一张卡都不剩）",
      HomeCardOrder.setEnabled(HomeCardKind.draggable, .custom, on: false) == HomeCardKind.draggable)

// ── ④ 拖拽落位几何（相对位移，不是绝对格） ──────────────────────
let cellW = 170.0, rowH = 93.0, n = 6
check("微抖不换位：from 3、位移 (1,1) → 仍是 3（绝对格算法会甩到 0，真机手感崩）",
      HomeCardOrder.dragTarget(from: 3, dx: 1, dy: 1, cellWidth: cellW, rowHeight: rowH, count: n) == 3)
check("横向：dx 满一格宽 → 右移一列（from+1）",
      HomeCardOrder.dragTarget(from: 2, dx: cellW, dy: 0, cellWidth: cellW, rowHeight: rowH, count: n) == 3)
check("纵向：dy 满一行高 → 下移一行 = 跨 2 个槽（from+2）",
      HomeCardOrder.dragTarget(from: 2, dx: 0, dy: rowH, cellWidth: cellW, rowHeight: rowH, count: n) == 4)
check("左下：dy 一行高 + dx 负一格宽 → from+1",
      HomeCardOrder.dragTarget(from: 2, dx: -cellW, dy: rowH, cellWidth: cellW, rowHeight: rowH, count: n) == 3)
check("半格阈值即生效：dy == rowHeight/2 → 下移一行",
      HomeCardOrder.dragTarget(from: 0, dx: 0, dy: rowH / 2, cellWidth: cellW, rowHeight: rowH, count: n) == 2)
check("下界夹紧：0 号卡往左上拖 → 仍 0",
      HomeCardOrder.dragTarget(from: 0, dx: -cellW, dy: -rowH, cellWidth: cellW, rowHeight: rowH, count: n) == 0)
check("上界夹紧：末号卡往右下拖 → 仍 count-1",
      HomeCardOrder.dragTarget(from: n - 1, dx: cellW, dy: rowH, cellWidth: cellW, rowHeight: rowH, count: n) == n - 1)
check("异常入参一律返回 from（count 0 / 尺寸 0 / from 越界）",
      HomeCardOrder.dragTarget(from: 0, dx: 99, dy: 99, cellWidth: cellW, rowHeight: rowH, count: 0) == 0
        && HomeCardOrder.dragTarget(from: 1, dx: 99, dy: 99, cellWidth: 0, rowHeight: rowH, count: n) == 1
        && HomeCardOrder.dragTarget(from: 9, dx: 99, dy: 99, cellWidth: cellW, rowHeight: rowH, count: n) == 9)

// ── ⑤ 换位 / 2 列分行 ──────────────────────────────────────────
check("move 正常换位",
      HomeCardOrder.move([.mail, .resume, .todo], kind: .resume, to: 2) == [.mail, .todo, .resume])
check("move 原位不动（from == dest 原样返回）",
      HomeCardOrder.move([.mail, .resume], kind: .mail, to: 0) == [.mail, .resume])
check("move 越界夹紧：to -5 → 首位；to 99 → 末位",
      HomeCardOrder.move([.mail, .resume, .todo], kind: .todo, to: -5) == [.todo, .mail, .resume]
        && HomeCardOrder.move([.mail, .resume, .todo], kind: .mail, to: 99) == [.resume, .todo, .mail])
check("move 未知 kind → 原样（不崩）",
      HomeCardOrder.move([.mail], kind: .todo, to: 0) == [.mail])
check("rows 空列表 → 空（不能返回一行 nil 撑出空白高度）",
      HomeCardOrder.rows([]).isEmpty)
check("rows 单张落单补 nil 占位",
      HomeCardOrder.rows([.mail]) == [[.mail, nil]])
check("rows 两张正好一行",
      HomeCardOrder.rows([.mail, .resume]) == [[.mail, .resume]])
check("rows 五张 → 3 行（2+2+1），末行补 nil",
      HomeCardOrder.rows([.mail, .resume, .todo, .weather, .expense])
        == [[.mail, .resume], [.todo, .weather], [.expense, nil]])
check("rows 元素守恒：拍平非 nil 数 == 输入数",
      HomeCardOrder.rows(HomeCardKind.catalogOrder).flatMap { $0 }.compactMap { $0 }.count == 7)
check("rows columns <= 0 → 空（不许死循环）",
      HomeCardOrder.rows([.mail, .resume], columns: 0).isEmpty)

// ── ⑥ 写回保位（关掉的卡必须留在原槽） ─────────────────────────
let offDefault = HomeCardStore.defaultOff
let visibleDefault: [HomeCardKind] = [.mail, .resume, .agentTip, .custom]
check("写回：关掉的卡逐个留在原槽（默认档下结果 == catalog 原序）",
      HomeCardOrder.mergeVisible(oldFull: HomeCardKind.catalogOrder,
                                 newVisible: visibleDefault,
                                 off: offDefault) == HomeCardKind.catalogOrder)
let mergedSwapped = HomeCardOrder.mergeVisible(oldFull: HomeCardKind.catalogOrder,
                                               newVisible: [.resume, .mail, .agentTip, .custom],
                                               off: offDefault)
check("写回：可见卡换位（resume/mail 对调）后，被关的三张仍在原槽 3/4/5 位",
      mergedSwapped == [.resume, .mail, .todo, .weather, .expense, .agentTip, .custom])
check("写回后重新打开 todo → 精确回到第 3 位（不是排到末尾）",
      HomeCardOrder.resolve(order: HomeCardOrder.encode(mergedSwapped), off: "weather,expense") ==
        [.resume, .mail, .todo, .agentTip, .custom])
check("写回：oldFull 之外的新卡（升版加卡）补到末尾",
      HomeCardOrder.mergeVisible(oldFull: [.mail, .resume],
                                 newVisible: [.resume, .mail, .todo],
                                 off: []) == [.resume, .mail, .todo])
check("写回长度守恒（可见卡少于槽位的边界不崩）",
      HomeCardOrder.mergeVisible(oldFull: HomeCardKind.catalogOrder,
                                 newVisible: [.mail],
                                 off: []).count == 7)

// ── ⑦ 持久化键 / 版式常量（单一真源） ───────────────────────────
check("UserDefaults 键字面量全仓只在 HomeCardOrder.swift（grep 单一真源）",
      flat(stripCommentLines(coreSrc)).contains("\"qingliao_home_card_order\"")
        && flat(stripCommentLines(cards)).contains("qingliao_home_card_order") == false
        && flat(stripCommentLines(chat)).contains("qingliao_home_card_order") == false)
check("HomeCardStore.orderKey / offKey 与字面量一致",
      HomeCardStore.orderKey == "qingliao_home_card_order"
        && HomeCardStore.offKey == "qingliao_home_card_off")
check("卡片高度 84pt / 间距 9pt（视觉与拖拽命中区共用同一份）",
      HomeCardStore.cardHeight == 84 && HomeCardStore.gap == 9)

// ── ⑦' 读取路径与开关路径同一口径（这批坑只有「接进 UI 真点一遍」才露） ──
// 会临时写 UserDefaults，跑完还原（键原来不存在就删回不存在）。
let ud = UserDefaults.standard
let keepOrder = ud.string(forKey: HomeCardStore.orderKey)
let keepOff = ud.string(forKey: HomeCardStore.offKey)

ud.removeObject(forKey: HomeCardStore.orderKey)
ud.removeObject(forKey: HomeCardStore.offKey)
check("首次使用（键都不存在）：off == 默认档三张 —— 否则面板显示「三张默认关掉的卡是开的」，与首页对不上",
      HomeCardStore.off == HomeCardStore.defaultOff)
check("首次使用：渲染 4 张 = [mail, resume, agentTip, custom]",
      HomeCardStore.kinds == [.mail, .resume, .agentTip, .custom])
check("完整顺序恒为 catalog 全量 7 张（拖拽写回拿它当 oldFull，关掉的卡才留得住）",
      HomeCardStore.fullOrder.count == 7 && Set(HomeCardStore.fullOrder) == Set(HomeCardKind.allCases))

ud.set("todo,weather,expense,custom,zzz_kind", forKey: HomeCardStore.offKey)
check("脏 off 串：未知项丢弃 + 空槽位照用户意思保留在 off（v4.0.9 起它可关）",
      HomeCardStore.off == [.todo, .weather, .expense, .custom])
ud.set(HomeCardOrder.encode(HomeCardKind.draggable), forKey: HomeCardStore.offKey)
check("脏数据把 6 张真卡全关 → 兜底放回 resume（与 setEnabled 拒关同一口径）",
      HomeCardStore.off == HomeCardKind.draggable.filter { $0 != .resume })

ud.set("", forKey: HomeCardStore.offKey)
check("动过开关（键存在空串）→ 完全听用户的，不回灌默认档",
      HomeCardStore.off.isEmpty && HomeCardStore.kinds.count == 7)

ud.set(HomeCardOrder.encode(HomeCardStore.defaultOff), forKey: HomeCardStore.offKey)
ud.set(HomeCardOrder.encode(HomeCardOrder.setEnabled(HomeCardStore.off, .todo, on: true)),
       forKey: HomeCardStore.offKey)
check("模拟开一张默认关掉的卡：它真的出现在渲染列表里（fullOrder 是全量才不会「开了看不见」）",
      HomeCardStore.kinds.contains(.todo))
check("开卡不把它挪到末尾（顺序串保留原槽位）",
      HomeCardStore.kinds == [.mail, .resume, .todo, .agentTip, .custom])

ud.set(HomeCardOrder.encode([.custom]), forKey: HomeCardStore.offKey)
check("🚨 空槽位关掉 → 不再被无条件补回（旧实现 `kinds` 末尾恒补 custom = 关不掉的真根因）",
      HomeCardStore.off == [.custom]
        && HomeCardStore.kinds == HomeCardKind.catalogOrder.filter { $0 != .custom })
check("空槽位关掉后仍有「添加卡片」入口：页头「自定义」胶囊恒在（不失联）",
      flat(stripCommentLines(cards)).contains(".sectionHeaderPill()")
        && flat(stripCommentLines(cards)).contains("HomeCardEditorSheet(off:$off)"))

if let keepOrder { ud.set(keepOrder, forKey: HomeCardStore.orderKey) }
else { ud.removeObject(forKey: HomeCardStore.orderKey) }
if let keepOff { ud.set(keepOff, forKey: HomeCardStore.offKey) }
else { ud.removeObject(forKey: HomeCardStore.offKey) }
ud.synchronize()
check("跑完还原用户键（本表不污染真机设置）",
      ud.string(forKey: HomeCardStore.orderKey) == keepOrder
        && ud.string(forKey: HomeCardStore.offKey) == keepOff)

// ── ⑧ UI 形态护栏（HomeCards.swift / ChatView.swift） ──────────
check("拖拽落位不自算：HomeCards 调 HomeCardOrder.dragTarget",
      flat(stripCommentLines(cards)).contains("HomeCardOrder.dragTarget("))
check("写回不自拼：HomeCards 走 HomeCardOrder.mergeVisible(oldFull:newVisible:off:)",
      flat(stripCommentLines(cards)).contains("HomeCardOrder.mergeVisible(oldFull:full,newVisible:movedVisible,off:off)"))
check("换位后落盘：applyMove 里 persist(order: full, off: off)",
      flat(stripCommentLines(cards)).contains("HomeCardStore.persist(order:full,off:off)"))
check("开关改动也落盘（sheet 的 onChange 回写）",
      flat(stripCommentLines(cards)).contains("HomeCardEditorSheet(off:$off)"))
check("卡片区不自造路由：HomeCards 不出现 QingliaoRouteHandoff（通道由 ChatView 注入）",
      !flat(stripCommentLines(cards)).contains("QingliaoRouteHandoff"))
check("agent 卡空 prompt 兜底：idle 取建议池首项（点得快也不会发空消息）",
      flat(stripCommentLines(cards)).contains("prompt:pool[0].prompt"))
check("「自定义」胶囊走栏目头档 sectionHeaderPill()（不再是聊天页顶栏那一档）",
      flat(stripCommentLines(cards)).contains(".sectionHeaderPill()")
        && !flat(stripCommentLines(cards)).contains(".chatHeaderPill()"))
check("🚨 栏目头胶囊比聊天页头那档矮 4pt：vPad=Spacing.xs（15 + 2×4 = 23pt，旧档 15 + 2×6 = 27pt）",
      {
          let body = flat(stripCommentLines(fnBody("func sectionHeaderPill", pill)))
          return body.contains(".padding(.vertical,Spacing.xs)")
              && body.contains(".frame(height:15)")
              && !body.contains(".padding(.vertical,Spacing.sm)")
      }())
check("未点名项保持原值：chatHeaderPill 仍 Spacing.sm（聊天页顶栏两枚不跟着变矮）",
      {
          let body = flat(stripCommentLines(fnBody("func chatHeaderPill", pill)))
          return body.contains(".padding(.vertical,Spacing.sm)")
              && body.contains(".frame(height:15)")
      }())
check("两档只差纵向内距：sectionHeaderPill 与 chatHeaderPill 的字号/横内距/玻璃/命中区同参",
      {
          let a = flat(stripCommentLines(fnBody("func sectionHeaderPill", pill)))
          let b = flat(stripCommentLines(fnBody("func chatHeaderPill", pill)))
          let same = [".font(.system(size:Typography.caption,weight:.semibold))",
                      ".padding(.horizontal,Spacing.md)",
                      ".glassPillStroke()", ".contentShape(Capsule())"]
          return same.allSatisfy { a.contains($0) && b.contains($0) }
      }())
check("首页卡片不再手写 ultraThinMaterial 胶囊（散落材质在浅色下发灰）",
      !flat(stripCommentLines(cards)).contains(".ultraThinMaterial,in:Capsule()"))
check("视图状态与读取路径同源：full = HomeCardStore.fullOrder、off = HomeCardStore.off（不许各自 parse）",
      flat(stripCommentLines(cards)).contains("privatevarfull:[HomeCardKind]=HomeCardStore.fullOrder")
        && flat(stripCommentLines(cards)).contains("privatevaroff:[HomeCardKind]=HomeCardStore.off"))
check("行高/间距取自 HomeCardStore（不在视图里写死 84 / 9）",
      flat(stripCommentLines(cards)).contains("privateletcardHeight=HomeCardStore.cardHeight")
        && flat(stripCommentLines(cards)).contains("privateletgap=HomeCardStore.gap"))
check("空槽位可见时仍钉在末尾（kinds 末尾补 custom）",
      flat(stripCommentLines(coreSrc)).contains("returnbase.contains(.custom)?base:base+[.custom]"))
check("🚨 kinds 必须先让 off 说话：关掉的空槽位不许被补回",
      flat(stripCommentLines(coreSrc)).contains("ifoff.contains(.custom){returnbase}"))
check("setEnabled 不再给空槽位开小灶（旧守卫已删）",
      !flat(stripCommentLines(coreSrc)).contains("guardkind!=.customelse{returnoff}"))
check("面板不再禁用空槽位开关（v4.0.9：用户要求可关）",
      !flat(stripCommentLines(cards)).contains(".disabled(k==.custom)"))
check("v4.0.9：页脚「继续上次」长条卡已删除（ChatView 里 resumeRow 零残留）",
      !flat(stripCommentLines(chat)).contains("resumeRow"))
check("ChatView 定义 homeCardsGrid 并在 welcomeView 里挂上",
      flat(stripCommentLines(chat)).contains("privatevarhomeCardsGrid:someView")
        && flat(stripCommentLines(chat)).contains("if!kb.isVisible&&homeCardsOn{homeCardsGrid}"))

// ── ⑫ 总开关（v4.0.10 用户要求：设置里能关掉首页快捷卡片） ─────────────
check("总开关键与默认值的单一真源（字面量只在 Core，默认值只有一个常量）",
      HomeCardStore.enabledKey == "qingliao_home_card_enabled"
        && HomeCardStore.enabledDefault == true)
check("键字面量不外泄：HomeCards / ChatView / 设置页里不出现该字面量（都走 enabledKey）",
      !flat(stripCommentLines(cards)).contains("qingliao_home_card_enabled")
        && !flat(stripCommentLines(chat)).contains("qingliao_home_card_enabled")
        && !flat(stripCommentLines(settings)).contains("qingliao_home_card_enabled"))
check("设置页源可读（不然下面两条是假绿）", !flat(stripCommentLines(settings)).isEmpty)
check("设置页有恒在的开关行（标题「首页快捷卡片」+ toggle 绑定）",
      flat(stripCommentLines(settings)).contains("SettingRow(icon:\"rectangle.grid.2x2.fill\"")
        && flat(stripCommentLines(settings)).contains("title:\"首页快捷卡片\",toggle:$homeCardsOn)"))
check("设置页与聊天页绑同一个键、默认值都取 enabledDefault（不许各自写 true）",
      flat(stripCommentLines(settings)).contains("@AppStorage(HomeCardStore.enabledKey)privatevarhomeCardsOn=HomeCardStore.enabledDefault")
        && flat(stripCommentLines(chat)).contains("@AppStorage(HomeCardStore.enabledKey)privatevarhomeCardsOn=HomeCardStore.enabledDefault"))
check("🚨 关掉 = 整块不渲染且不留空占位（homeCardsGrid 全仓只有「定义 + 那一处挂载」两处引用）",
      flat(stripCommentLines(chat)).components(separatedBy: "homeCardsGrid").count - 1 == 2)
check("执行通道注入齐全（resume/ask/life/weather 四条，组件不自造路由）",
      flat(stripCommentLines(chat)).contains("onResume:") && flat(stripCommentLines(chat)).contains("onAsk:")
        && flat(stripCommentLines(chat)).contains("onOpenLife:") && flat(stripCommentLines(chat)).contains("onOpenWeather:"))
check("本表已挂进 check_swift.sh（护栏不自嗨）",
      flat(gate).contains("scripts/ql_chat_home/truth_table_homecards.swift"))

// ── ⑪ v4.0.10 真机坏形：卡高恒定 + 长按拖动真成立 ────────────────
// 用户配图报「第 4 张卡（agent 主动推荐）大小明显跟其他 3 张不一样」：
// 记忆里第一条是 20+ 字的「AI 行为规则」→ 副标题折两行 → 内容 ~94pt 顶在 84pt 槽位里，
// ZStack 居中溢出（像素量：该卡 283px vs 同排 254px @3x）。截断/筛选口径收进 HomeCardTipKit。
check("记忆语境：规则型长条目（20+ 字）被拒 → nil（退回池内短句，不再折两行）",
      HomeCardTipKit.memoryLine(entries: ["AI生成输出回复时不要回复已经回复过的内容"]) == nil)
check("记忆语境：含换行的条目被拒（换行 = 折行 = 撑破卡高）",
      HomeCardTipKit.memoryLine(entries: ["第一行\n第二行"]) == nil)
check("记忆语境：空 / 纯空白条目跳过，取后面那条合规的",
      HomeCardTipKit.memoryLine(entries: ["", "   ", "用户常用简称"]) == "用户常用简称")
check("记忆语境：超 8 字截断加省略号（连同前缀仍是一行）",
      HomeCardTipKit.memoryLine(entries: ["偏好简短回复不要客套"]) == "偏好简短回复不要…")
check("记忆语境：整条 ≤ 8 字原样用",
      HomeCardTipKit.memoryLine(entries: ["用户常住深圳"]) == "用户常住深圳")
check("记忆语境：无合规条目 → nil（退回池内短句）；有 → 「记得：xxx」",
      HomeCardTipKit.memoryLine(entries: []) == nil
        && HomeCardTipKit.subtitle(memory: nil, pool: "看看钱花在哪") == "看看钱花在哪"
        && HomeCardTipKit.subtitle(memory: "用户常住深圳", pool: "看看钱花在哪") == "记得：用户常住深圳")
check("🚨 卡面副标题恒单行（lineLimit(1)、无 .fixedSize 竖直撑开）——双行会撑破 84pt 卡高",
      flat(stripCommentLines(cards)).contains("Text(subtitle).font(.system(size:Typography.tiny)).foregroundStyle(.secondary).lineLimit(1)")
        && !flat(stripCommentLines(cards)).contains("fixedSize(horizontal:false,vertical:true)"))
check("🚨 长按拖动不被 Button 抢：卡上挂的是 simultaneousGesture（旧 .gesture 真机拖不动）",
      flat(stripCommentLines(cards)).contains(".simultaneousGesture(dragGesture(index:index))"))
check("拖完不吃轻点：tap 首行有 suppressTapUntil 门闩；onEnded 只在真拖动后上闩",
      flat(stripCommentLines(cards)).contains("ifDate()<suppressTapUntil{return}")
        && flat(stripCommentLines(cards)).contains(
            "HomeCardDragKit.isRealDrag(dx:drag.translation.width,dy:drag.translation.height)else{return}suppressTapUntil=Date().addingTimeInterval(HomeCardDragKit.latchWindow)"))

// ── ⑫ v4.0.10 二修（真机报「agent 主动推荐卡片点了没反应」）：慢点击不许被拖动吞 ──
//    根因：轻点与长按拖动抢同一次按压；旧口径「长按一成立就上闩」→ 按住不动再松手 = 什么都不发生。
check("拖动判定收在 HomeCardDragKit（纯逻辑可测，别散在视图里靠手感）",
      HomeCardDragKit.moveThreshold == 6 && HomeCardDragKit.latchWindow == 0.8)
check("长按门槛别再退回 0.28 秒（太短：慢点击被吃进拖动会话）",
      HomeCardDragKit.longPressSeconds >= 0.35 && HomeCardDragKit.longPressSeconds <= 0.6
        && !flat(stripCommentLines(cards)).contains("LongPressGesture(minimumDuration:0.28)"))
check("长按手势取常量而不是字面量（门槛只有一处真源）",
      flat(stripCommentLines(cards)).contains("LongPressGesture(minimumDuration:HomeCardDragKit.longPressSeconds)"))
check("🚨 按住不动不算拖动：零位移/微小位移一律判 false（松手要当轻点）",
      !HomeCardDragKit.isRealDrag(dx: 0, dy: 0)
        && !HomeCardDragKit.isRealDrag(dx: 5.9, dy: 0)
        && !HomeCardDragKit.isRealDrag(dx: 4, dy: 4)
        && !HomeCardDragKit.isRealDrag(dx: -1, dy: 2))
check("真拖动仍要判 true（阈值边界 + 各方向 + 负向）",
      HomeCardDragKit.isRealDrag(dx: 6, dy: 0)
        && HomeCardDragKit.isRealDrag(dx: 0, dy: -6)
        && HomeCardDragKit.isRealDrag(dx: -12, dy: 3)
        && HomeCardDragKit.isRealDrag(dx: 0, dy: 40))
check("onChanged 上闩被真位移把住（不是「长按成立就上闩」）",
      flat(stripCommentLines(cards)).contains(
        "ifHomeCardDragKit.isRealDrag(dx:moved.width,dy:moved.height){suppressTapUntil=Date().addingTimeInterval(HomeCardDragKit.latchWindow)}"))
check("🚨 全仓每一次上闩都排在 isRealDrag 判定之后（漏一处 = 慢点击又被吞）", { () -> Bool in
    let src = flat(stripCommentLines(cards))
    var idx = src.startIndex
    var total = 0
    while let r = src.range(of: "suppressTapUntil=Date()", range: idx..<src.endIndex) {
        total += 1
        let head = src[src.startIndex..<r.lowerBound]
        let tailText = String(head.suffix(240))
        guard tailText.contains("isRealDrag") else { return false }
        idx = r.upperBound
    }
    return total >= 2   // onChanged 续窗 + onEnded 收尾，两处都必须有
}())
check("真拖动那条路没丢：换位调用排在门闩之后（先上闩再 dragTarget）", { () -> Bool in
    let src = flat(stripCommentLines(cards))
    guard let latch = src.range(of: "HomeCardDragKit.isRealDrag(dx:drag.translation.width"),
          let target = src.range(of: "lettarget=HomeCardOrder.dragTarget(") else { return false }
    return latch.lowerBound < target.lowerBound
}())

print(fail == 0 ? "✅ ql_chat_home 真值表 \(pass) 项全过" : "❌ 失败 \(fail) / 通过 \(pass)")
if fail > 0 { exit(1) }
