// MARK: - v3.9.61 输入栏两层化 · 真值表（源护栏 + 几何纯计算镜像）
//
// 用户原话：「输入框在键盘弹出状态做两层处理，第一层作为消息输入层，无文字输入时显示输入消息，
// 光标也走这一层；第二层走工具，附件、相机图标自己模型选择放第二层」。
//
// 护栏三件事（ql_ui 技能口径）：
//   1. 两层恒定结构在位（messageRow / toolRow），且**不用 if focused 之类的条件切结构**
//      —— 那会让 TextField 换父级/换兄弟集合 → 重建 → 键盘弹一下又收回（v3.9.53 同款坑）；
//   2. 归属正确：textArea 与占位符在第一层；附件/相机/模型快选在第二层；
//   3. 旧单行形态清零（单行 HStack 里同时挂 attachButtons + textArea 的写法不复存在）。
// 纯计算：两层高度算式镜像（42 / 42 / 8 → 92）本机可算，改常量时表同步红。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) else { return "" }
    return s
}

let inputBarSrc = src("Features/Chat/ChatInputBar.swift")

// ── 源护栏：非空 ─────────────────────────────────────────────
check("ChatInputBar.swift 源可读", !inputBarSrc.isEmpty)

// ── 0. 两层结构在位 ─────────────────────────────────────────
check("容器是两层 VStack（单行 HStack 已退场）",
      inputBarSrc.contains("VStack(spacing: toolLayerExpanded ? ChatInputBarLayout.rowGap : 0) {"))
check("第一层 messageRow 在容器里", inputBarSrc.contains("            messageRow\n"))
check("第二层 toolRow 在容器里", inputBarSrc.contains("            toolRow\n"))
check("messageRow 是独立计算属性", inputBarSrc.contains("private var messageRow: some View"))
check("toolRow 是独立计算属性", inputBarSrc.contains("private var toolRow: some View"))
check("两层间距恒引用 Layout 常量（展开态 rowGap；收起态 0 是同一三元的另一支，不算魔法数）",
      inputBarSrc.contains("ChatInputBarLayout.rowGap"))

// ── 1. 归属正确（用户点名的两层各放什么） ────────────────────
// 第一层 = 消息输入层：输入框（含占位符「输入消息…」与光标）+ 停止/发送
// messageRow 段只取到函数体闭合（`}` 单独一行）为止，**不圈它后面的文档注释**——
// 否则 toolRow 的注释里提到的 modelButton/attachButtons 会被算进第一层 → 假红。
let messageRowSlice: String = {
    guard let a = inputBarSrc.range(of: "private var messageRow: some View") else { return "" }
    let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
    // 函数体闭合 = 首个「4 空格缩进的 }」
    guard let end = body.range(of: "\n    }\n") else { return "" }
    return String(body[body.startIndex..<end.upperBound])
}()
check("messageRow 段可切出（切片空了本条就是空真）", !messageRowSlice.isEmpty)
check("第一层含 textArea（输入框/光标/占位符都走它）", messageRowSlice.contains("textArea"))
check("第一层含 trailingButtons（停止/发送与输入同行，未搬去第二层）",
      messageRowSlice.contains("trailingButtons"))
check("占位符文案留在第一层（textArea 内）",
      inputBarSrc.contains("Text(\"输入消息...\")"))

// 第二层 = 工具层：附件 + 相机 + 模型快选
// toolRow 段同样只取函数体（不圈 attachButtons 的文档注释）
let toolRowSlice: String = {
    guard let a = inputBarSrc.range(of: "private var toolRow: some View") else { return "" }
    let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
    guard let end = body.range(of: "\n    }\n") else { return "" }
    return String(body[body.startIndex..<end.upperBound])
}()
check("toolRow 段可切出（切片空了本条就是空真）", !toolRowSlice.isEmpty)
check("第二层含 attachButtons（附件 + 相机）", toolRowSlice.contains("attachButtons"))
check("第二层含 modelButton（模型快选）", toolRowSlice.contains("modelButton"))
check("第二层模型名靠右（Spacer 推到尾部）", toolRowSlice.contains("Spacer(minLength: 0)"))
check("工具不留在第一层（附件/相机/模型都不在 messageRow 段里）",
      !messageRowSlice.contains("attachButtons") && !messageRowSlice.contains("modelButton"))

// ── 2. 附件/相机两个入口本体仍在（没被两层化顺手删掉） ──────
check("附件按钮（paperclip）仍在", inputBarSrc.contains("Image(systemName: \"paperclip\")"))
check("相机按钮仍在", inputBarSrc.contains("Image(systemName: \"camera\")"))
check("发送按钮仍在", inputBarSrc.contains("Image(systemName: \"arrow.up\")"))

// ── 2b. 收起态只显第一层（v3.9.66，用户做上一轮评估里的方案 1）────────────────────
// 用户原话（评估后拍板）：「做 1，另外输入框圆角加到 20」——「做 1」=「未弹出键盘时候输入框
// 只显示第一层的输入信息这一层，在点击输入框弹出键盘后输入框的第一第二层都显示」。
// 实现纪律（v3.9.53 键盘弹一下又收回的坑）：
//   · 两层**恒渲染** —— 不许 `if kbEnv.isVisible { toolRow }` / `if toolLayerExpanded { toolRow }`；
//   · 只改不改变类型的量：toolRow 的 frame(height) 0↔toolRowMinHeight、opacity 0↔1、
//     allowsHitTesting 同步切；VStack spacing 展开 rowGap / 收起 0；
//   · 判据 = `focused || kbEnv.isVisible`（iPad 蓝牙键盘软键盘不弹，只判键盘高度会永远收起）；
//   · 三处（spacing / height / opacity）必须同读一个判定属性，否则高度动画与淡入不同步。
// 反向自证：把 toolRow 的 frame 改回常量高度 → 收起态三条护栏立刻全红。
check("收起态判据在位：toolLayerExpanded = focused || kbEnv.isVisible",
      inputBarSrc.contains("private var toolLayerExpanded: Bool {")
      && inputBarSrc.contains("focused || kbEnv.isVisible"))
check("第二层高度随判据收放：展开 toolRowMinHeight / 收起 0（不写 nil，nil 会回退固有高度 34）",
      inputBarSrc.contains(".frame(minHeight: toolLayerExpanded ? ChatInputBarLayout.toolRowMinHeight : 0)"))
check("第二层透明度随判据收放（收起 0 / 展开 1）",
      inputBarSrc.contains(".opacity(toolLayerExpanded ? 1 : 0)"))
check("第二层命中区随判据同步关（收起态空白不吞输入框点击）",
      inputBarSrc.contains(".allowsHitTesting(toolLayerExpanded)"))
check("容器间距随判据收放（展开 rowGap / 收起 0，防层高已 0 仍留 8pt 缝）",
      inputBarSrc.contains("VStack(spacing: toolLayerExpanded ? ChatInputBarLayout.rowGap : 0)"))
check("高度/淡入动画与聚焦蓝边同一条 Motion.snap",
      inputBarSrc.contains(".animation(Motion.snap, value: toolLayerExpanded)"))
check("恒两层铁律：不得用 if 包裹 toolRow（VStack 子节点集合恒为两个）",
      !inputBarSrc.contains("if toolLayerExpanded {\n            toolRow")
      && !inputBarSrc.contains("if focused {\n            toolRow")
      && !inputBarSrc.contains("if kbEnv.isVisible {\n            toolRow")
      && !inputBarSrc.contains("if !toolLayerExpanded {\n            toolRow"))
check("收起态不喂 if 切结构：toolRow 声明仍是 HStack 起始（无 if 前缀成员）",
      {
          guard let a = inputBarSrc.range(of: "private var toolRow: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "HStack(spacing: 8) {") else { return false }
          let head = String(body[body.startIndex..<end.lowerBound])
          // 声明行与文档注释之间不得插入条件分支
          return !head.contains("\n        if ")
      }())
check("常量未被顺手改：toolRowMinHeight 仍 34、messageRowMinHeight 仍 42、rowGap 仍 Spacing.md（本轮只加收放不改量）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 34")
      && inputBarSrc.contains("static let messageRowMinHeight: CGFloat = 42")
      && inputBarSrc.contains("static let rowGap: CGFloat = Spacing.md"))
// 收起态高度算式：padding(.vertical) Spacing.md 12×2 + 第一层 42 = 58（原两层态 84）。
// ⚠️ v3.9.67 修正：此处「58/26」与源注释里的「66」两版文案都拿错了 padding——v3.9.66 当轮
//   真实值是 12×2+42 = 66；v3.9.67 用户「收起态高度改为 50」后垂直 padding 降为 Spacing.xs(4)，
//   真实值是 4×2+42 = 50。算式断言统一在第 5 节执行（镜像常量在那里声明），
//   顶层代码顺序执行，这里直接引用会「use of local variable before its declaration」。
// 第一层控件仍在第一层（收起态可发消息/可停止，不会因第二层消失而丢功能入口）
check("发送键仍在第一层 trailingButtons（收起态无第二层也能发）",
      messageRowSlice.contains("trailingButtons"))

// ── 2c. 容器圆角 18 → 20（v3.9.66，用户：「另外输入框圆角加到 20」）──────────────
// 明确数值规格，不新开 Radius 令牌档（Radius 6 档 8/10/12/14/16/22，20 落在 card 与 hero 之间，
// 为它新开中间档会破坏语义层级）——仍走 ChatInputBarLayout.containerCornerRadius 单一真源。
// 圆角变大后平坦段同步收窄：收起态 58 − 20×2 = 18pt / 展开态 84 − 20×2 = 44pt。
check("圆角常量 18 → 20（明确数值规格，不套令牌档）",
      inputBarSrc.contains("static let containerCornerRadius: CGFloat = 20"))
check("四处同形仍全部引用 containerCornerRadius（玻璃/蓝边/白边/流光）",
      inputBarSrc.components(separatedBy: "cornerRadius: ChatInputBarLayout.containerCornerRadius").count - 1 == 4)
// 平坦段断言与算式镜像统一放在第 5 节（flatTopCollapsedMirror / flatTopMirror）——
// 顶层代码顺序执行，此处引用后面的 let 会「cannot find ... in scope」。

// ── 2d. 收起态高度 66 → 50（v3.9.67，用户：「收起态高度改为 50」）────────────────
// 只动容器**垂直 padding** 一个数：Spacing.md(12) → Spacing.xs(4)。
// 算式：收起态容器高 = 第一层 42 + padding 4×2 = **50**；
//       展开态容器高 = 内容 84 + 4×2 = **92**；
//       平坦段 = 收起 50 − 20×2 = 10pt / 展开 92 − 20×2 = 52pt（均 > 0，弧顶不咬文字）。
// 水平 padding（Spacing.lg 18×2）**不动**——用户原话只说高度，横向宽度与输入框可用宽
// （≈297pt 的口径）都不属于这次改动面。
check("垂直 padding 走 Spacing.xs(4)（收起态高 50 的唯一来源，不打魔法数）",
      inputBarSrc.contains(".padding(.vertical, Spacing.xs)"))
check("旧垂直 padding 清零：不再有 .padding(.vertical, Spacing.md)（66 的来源）",
      !inputBarSrc.contains(".padding(.vertical, Spacing.md)"))
check("水平 padding 未动：仍是 Spacing.lg(18)（本轮只调高度，宽度口径不变）",
      inputBarSrc.contains(".padding(.horizontal, Spacing.lg)"))
check("容器级垂直 padding 只出现一次（第一层内两处 Spacing.xl 属内容侧，不混算）",
      {
          let containerLevel = inputBarSrc.components(separatedBy: ".padding(.vertical, Spacing.xs)").count - 1
          let contentLevel = inputBarSrc.components(separatedBy: ".padding(.vertical, Spacing.xl)").count - 1
          return containerLevel == 1 && contentLevel == 2
      }())
check("第二层行高常量未动（toolRowMinHeight 仍 34，本轮只收容器 padding）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 34"))
check("containerMinHeight 仍 84（语义=内容最小总高，容器高度由 padding 另行给）",
      inputBarSrc.contains("static let containerMinHeight: CGFloat = 84"))

// ── 3. 恒定结构铁律：不得用条件切换结构 ──────────────────────
// 反例（都不允许出现在容器/两层声明上）：
//   · if focused / if kbEnv.isVisible 包住某一层 → 层时隐时现
//   · textArea 被包在 if 分支里 → 它是第一层的恒生成成员
check("容器两层无条件包裹（不用 if focused 切结构）",
      !inputBarSrc.contains("if focused {\n            messageRow")
      && !inputBarSrc.contains("if focused {\n            toolRow"))
check("textArea 不在任何 if 分支里（恒渲染，重建即掉键盘）",
      !inputBarSrc.contains("if !text.isEmpty {\n            textArea")
      && !inputBarSrc.contains("if text.isEmpty {\n            textArea"))

// ── 3b. 靠左口径（用户：「第一层的输入消息有没有靠左？我想，按照靠左而不是居中」）──
// 同层三处必须同侧 leading：TextField 的 multilineTextAlignment、占位符 overlay、
// 录音态上屏文本。只钉 TextField 会漏掉后两者——占位符与输入文字换行后错位最扎眼。
check("第一层消息文本显式靠左（TextField multilineTextAlignment .leading）",
      inputBarSrc.contains(".multilineTextAlignment(.leading)"))
check("占位符 overlay 靠左（frame(maxWidth: .infinity, alignment: .leading)）",
      inputBarSrc.contains("Text(\"输入消息...\")\n                                .font(.system(size: Typography.body))\n                                .foregroundStyle(.secondary)\n                                .frame(maxWidth: .infinity, alignment: .leading)"))
check("录音态上屏文本也靠左（与输入态同侧，切换不错位）",
      inputBarSrc.contains(".foregroundStyle(recordingText.isEmpty ? Color.secondary : Color.primary)\n                        // v3.9.62：与 TextField 的 `.multilineTextAlignment(.leading)` 同侧\n                        .multilineTextAlignment(.leading)"))
check("第一层没有残留 .center 对齐（非 leading 的居中口径清零）",
      {
          guard let a = inputBarSrc.range(of: "private var messageRow: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          return !String(body[body.startIndex..<end.upperBound]).contains(".center")
      }())
// v3.9.66 起：第二层高度改为「展开常量 / 收起 0」三元，常量引用仍在（不写魔法数），
// 收起支的 0 是显式规格不是散落数字（给 nil 会回退内容固有高度 34 → 收起态残留空白）。
check("两层高度走 Layout 常量 messageRowMinHeight / toolRowMinHeight",
      inputBarSrc.contains(".frame(minHeight: ChatInputBarLayout.messageRowMinHeight)")
      && inputBarSrc.contains("ChatInputBarLayout.toolRowMinHeight"))
check("两层高度都不是写死数字（写死会在放大字号时裁字）",
      !inputBarSrc.contains(".frame(minHeight: 42)")
      && !inputBarSrc.contains(".frame(minHeight: 44)"))

// ── 3c. 外层玻璃容器形状（用户：「内部的椭圆玻璃层就不要了，只留底部方形圆角框」）──
// v3.9.62 第一版走 `.background { RoundedRectangle(...).glassEffect() }`——**宿主形状拦不住玻璃本体**：
// Apple 官方明确 glassEffect 默认形状是 Capsule（`DefaultGlassEffectShape`；文档原文「applies the
// given effect within a Capsule shape behind the view's content」），Drop 到宿主是圆角矩形时玻璃仍按
// 胶囊渲染（两端半径 = 容器高/2 ≈54），衬在圆角矩形白边**里面**→ 用户看到「方框里套椭圆玻璃」。
// 正确做法 = 官方 `in:` 参数把玻璃钉进 RoundedRectangle，玻璃与描边同形、容器只剩一个形状。
// 同一形状必须在四处同时成立：玻璃底（in: 参数）/ 聚焦蓝边 / 常态白边 / 流光层。
// v3.9.64：用户原话「外部方形框圆角稍微再加一点」——四处半径 14（Radius.field）→ **16（Radius.card）**；
//          令牌体系里 14 的下一档就是 16，步进 2pt 符合「稍微」，不新开中间档（6 档语义层级）。
// v3.9.64 同轮：用户原话「把输入框流光填满外部的方形框」——流光本体由 **Capsule 改为同形
//          RoundedRectangle(cornerRadius: Radius.card)**（Capsule 两端半径 = 容器高/2，流光被压成
//          两端大弧的条状；同形矩形后铺满四边与四角，含 16pt 圆角处）。
// v3.9.65：用户原话「输入框圆角加到 18」——**明确数值规格**。18 落在 Radius 的 card(16) 与 hero(22)
//          之间，为它新开令牌档会破坏 6 档语义层级 → 收进 `ChatInputBarLayout.containerCornerRadius`
//          单一真源常量，四处（玻璃 in: / 聚焦蓝边 / 常态白边 / 流光）全部引用它。
// v3.9.65 同轮：用户原话「第二层的附件和相机图标变小降低第二层高度」——附件/相机视觉面 32×30 → 22×22、
//          第二层行高 42 → 34、容器最小总高 92 → 84；命中区仍走 hitArea44 外扩到 44×44。
// v3.9.66：用户原话「输入框圆角加到 20」——仍是**明确数值规格**，仍不新开令牌档（20 同样落在
//          card 16 与 hero 22 之间，且比 18 更靠近 hero，为它单独开档破坏更大）；只把单一真源常量
//          从 18 改 20，四处同形引用不变。平坦段随「第二层可收起」重算成两个数：
//          收起态 58 − 20×2 = 18pt / 展开态 84 − 20×2 = 44pt（见下方 2b/2c 节算式镜像）。
// v3.9.67：用户原话「收起态高度改为 50」——容器**垂直 padding** 由 Spacing.md(12×2) 降到
//          Spacing.xs(4×2)（水平 padding Spacing.lg 18×2 不动，用户只说高度）。由此：
//          收起态容器高 = 第一层 42 + 4×2 = **50**（v3.9.66 写 66 是 42+12×2，真机观感偏高；
//          真值表旧文案「58」同样是拿错的 padding 算的，本轮按真值一并修正）；
//          展开态容器高 = 84 + 4×2 = **92**（containerMinHeight 84 语义=内容最小总高，不变）。
//          平坦段重算：收起态 **50 − 20×2 = 10pt** / 展开态 **92 − 20×2 = 52pt**。
//          仍走令牌不打魔法数（xs=4 是 8 档里最小档，「紧贴元素」语义与收起态吻合）。
let containerShape = "RoundedRectangle(cornerRadius: ChatInputBarLayout.containerCornerRadius, style: .continuous)"
check("外层玻璃容器走 containerCornerRadius(20) 圆角矩形（不再全圆角胶囊）",
      inputBarSrc.contains(".glassEffect(.regular, in: \(containerShape))"))
check("容器圆角走 Layout 单一真源常量，不是魔法数",
      inputBarSrc.contains("in: \(containerShape)"))
check("圆角常量声明在位：containerCornerRadius: CGFloat = 20（v3.9.65 的 18 → v3.9.66 的 20）",
      inputBarSrc.contains("static let containerCornerRadius: CGFloat = 20"))
// 旧写法清零：玻璃不再挂在 background{Shape} 宿主上（宿主 Shape 拦不住默认胶囊形态）
check("旧写法清零：玻璃不挂 background{ Shape } 宿主（v3.9.62 椭圆玻璃病根）",
      !inputBarSrc.contains(".background {\n            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)\n                .glassEffect()\n        }"))
check("玻璃容器不再是 Capsule（旧胶囊形态清零）",
      !inputBarSrc.contains(".background { Capsule().glassEffect() }"))
// fullInputBar 体内四处不得再引用 Radius 令牌做容器圆角（18 已改走 Layout 常量）——
// 排除范围只切 fullInputBar 函数体，注释里提到的历史档名不算回退。
check("四处同形：fullInputBar 函数体内容器圆角全部走 containerCornerRadius（不再引用 Radius 档）",
      {
          guard let a = inputBarSrc.range(of: "private var fullInputBar: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          return !String(body[body.startIndex..<end.upperBound]).contains("cornerRadius: Radius.")
      }())
check("聚焦蓝边描边同圆角矩形（与玻璃底同形）",
      inputBarSrc.contains("overlay {\n            \(containerShape)\n                .strokeBorder(Color.blue.opacity(focused ? 0.45 : 0), lineWidth: 0.8)"))
check("常态白边描边同圆角矩形（与玻璃底同形）",
      inputBarSrc.contains("\(containerShape)\n                    .strokeBorder(.white.opacity(Tint.subtle), lineWidth: 0.8)"))
// 流光层同形（v3.9.64 新增）：等回复流光必须铺满方框，不得退回 Capsule。
// 命中点 = `RoundedRectangle(cornerRadius: …).fill(`（Capsule 版无此前缀）。
check("流光层是同形圆角矩形（填满方形框，不再两端大弧的 Capsule）",
      inputBarSrc.contains("\(containerShape).fill(\n                        AngularGradient("))
// 旧形态清零：流光本体不再是 Capsule（只认带声明/调用形态的串，注释里提到 Capsule 不算）
check("流光旧形态清零：流光本体不用 Capsule().fill(",
      !inputBarSrc.contains("Capsule().fill("))
// 四处同盘互证：玻璃/聚焦蓝边/常态白边/流光使用同一个圆角常量，四处计数都 > 0
// v3.9.65：四处引用从 Radius.card 换成 containerCornerRadius，计数口径同步换串。
check("四处同形：容器圆弧全部引用 containerCornerRadius（玻璃/蓝边/白边/流光）",
      inputBarSrc.components(separatedBy: "cornerRadius: ChatInputBarLayout.containerCornerRadius").count - 1 == 4)
// 排除式：fullInputBar 体内不得再出现容器级 Capsule。
// ⚠️ 只排除「容器形态」串：发送/停止/附件钮的 `in: Capsule()` 是按钮级胶囊，属既定口径不动。
check("fullInputBar 体内没有容器级 Capsule 描边/玻璃（按钮级 in: Capsule() 不在此列）",
      {
          guard let a = inputBarSrc.range(of: "private var fullInputBar: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          let slice = String(body[body.startIndex..<end.upperBound])
          return !slice.contains("Capsule().glassEffect()")
              && !slice.contains("Capsule().strokeBorder")
      }())

// ── 3d. 第二层附件/相机变小 + 行高降低（v3.9.65，用户：「第二层的附件和相机图标变小降低第二层高度」）──
// 视觉面 32×30 → 22×22，第二层 minHeight 42 → 34，容器最小总高 92 → 84。
// 命中区不缩：hitArea44(h:11, v:11) 仍把可点区外扩到 44×44（HIG 最小可点尺寸）。
// 第一层 42、发送键 32×32、两层间距 8 三项**未动**（用户只点了第二层）。
check("附件钮视觉面 22×22（原 32×30）",
      inputBarSrc.contains("Image(systemName: \"paperclip\")\n                    .font(.system(size: Typography.subhead, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 22, height: 22)"))
check("相机钮视觉面 22×22（原 32×30）",
      inputBarSrc.contains("Image(systemName: \"camera\")\n                    .font(.system(size: Typography.subhead, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 22, height: 22)"))
check("附件/相机视觉面各只有一处 22×22（两处 = 一对按钮，防漏改/防多改）",
      inputBarSrc.components(separatedBy: ".frame(width: 22, height: 22)").count - 1 == 2)
check("旧视觉面 32×30 清零（attachButtons 里的旧尺寸不回潮）",
      !inputBarSrc.contains(".frame(width: 32, height: 30)"))
check("命中区仍 44×44：附件外扩 11（22+11×2=44，HIG 最小可点尺寸不变）",
      inputBarSrc.contains(".hitArea44(h: 11, v: 11)"))
check("附件/相机命中区外扩各一处 11（计数互证：两处按钮都扩到 44）",
      inputBarSrc.components(separatedBy: ".hitArea44(h: 11, v: 11)").count - 1 == 2)
check("附件/相机按钮级胶囊形态保留（变小不动二元控件口径 in: Capsule()）",
      inputBarSrc.contains("Image(systemName: \"paperclip\")\n                    .font(.system(size: Typography.subhead, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 22, height: 22)\n                    // v3.4.26：附件/相机纳入胶囊语义——低透明外圈（次级操作，弱于实底发送钮）\n                    .background(Color.primary.opacity(Tint.faint), in: Capsule())"))
check("第二层行高常量降到 34（toolRowMinHeight）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 34"))
check("容器最小总高常量降到 84（containerMinHeight）",
      inputBarSrc.contains("static let containerMinHeight: CGFloat = 84"))
check("第一层行高仍 42、两层间距仍走 Spacing.md（本轮未动第一层与间距）",
      inputBarSrc.contains("static let messageRowMinHeight: CGFloat = 42")
      && inputBarSrc.contains("static let rowGap: CGFloat = Spacing.md"))
check("发送键视觉面未动（32×32 仍在，未顺手改第一层控件）",
      inputBarSrc.contains(".frame(width: 32, height: 32)"))
// 排除式：第二层内不得残留旧视觉面 32×30 与旧外扩量（attachButtons 段内断言，避免误伤别处）
check("attachButtons 段内无旧尺寸/旧外扩量残留",
      {
          guard let a = inputBarSrc.range(of: "private var attachButtons: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          let slice = String(body[body.startIndex..<end.upperBound])
          return !slice.contains("width: 32, height: 30") && !slice.contains("hitArea44(h: 6, v: 7)")
      }())

// ── 4. 旧单行形态清零（带声明/调用形态的串，别写裸符号名） ──
// 旧形态 = fullInputBar 里一行 HStack 同时挂 attachButtons + textArea + trailingButtons。
check("旧单行 HStack 已清零（fullInputBar 体内不再有 attachButtons）",
      {
          guard let a = inputBarSrc.range(of: "private var fullInputBar: some View"),
                let b = inputBarSrc.range(of: "private var messageRow: some View",
                                          range: a.upperBound..<inputBarSrc.endIndex)
          else { return false }
          return !String(inputBarSrc[a.lowerBound..<b.lowerBound]).contains("attachButtons")
      }())

// ── 5. 高度算式镜像（改常量必须同步改这里） ──────────────────
// 令牌算式（Spacing/Typography 实际档位）：
//   第一层 42 = padding(.vertical, Spacing.xl) 12×2 + 正文 15pt 行高 ≈17.9
//   第二层 34 = 附件/相机视觉 22 + 上下各 6（v3.9.65 起；v3.9.61~64 是 30 + 6×2 = 42）
//   间距    8 = Spacing.md
//   容器最小总高 = 42 + 8 + 34 = 84
// 本机 import 不到 SwiftUI → 常量在这里镜像一份；源里改了数、这里不同步 → 表立刻红。
enum ChatInputBarLayoutMirror {
    static let messageRowMinHeight: Double = 42
    static let toolRowMinHeight: Double = 34
    static let rowGap: Double = 8
    static let containerMinHeight: Double = 84
    /// v3.9.65 圆角 18（用户明确数值规格）→ **v3.9.66 圆角 20**（用户「输入框圆角加到 20」）。
    /// 仍是明确数值规格、仍不套令牌档（Radius 6 档 8/10/12/14/16/22，20 落在 card 16 与
    /// hero 22 之间且比 18 更靠近 hero，为它单独开档破坏更大）——镜像钉住改档必同步。
    static let containerCornerRadius: Double = 20
    /// v3.9.67：容器垂直 padding = **4（Spacing.xs）**（v3.9.66 是 Spacing.md=12）。
    /// 用户原话「收起态高度改为 50」→ 只动这一个数（水平 padding Spacing.lg=18 不动）。
    /// 镜像存在意义：源里改档 ≠ 镜像同步 → 第 5 节算式立刻红。
    static let containerVPadding: Double = 4
}

let rowGapMirror: Double = 8
let messageRowMirror: Double = 12 * 2 + 17.9   // ≈41.9 → 收 42
let toolRowMirror: Double = 22 + 6 * 2          // 34（v3.9.65：视觉 30 → 22）
let containerMirror = messageRowMirror + rowGapMirror + toolRowMirror   // 84（展开态内容）
/// v3.9.67：容器垂直 padding = Spacing.xs(4)（v3.9.66 是 Spacing.md 12；用户「收起态高度改为 50」）
let containerVPaddingMirror: Double = 4
/// v3.9.66：展开态容器高别名（与收起态对比用，名不同值同源，避免两处手写 84 漂移）
let expandedContainerMirror = containerMirror
/// v3.9.67：收起态（键盘未弹）容器高 = 第一层 42 + 垂直 padding 4×2 = **50**
/// （v3.9.66 = 42 + 12×2 = 66，真机观感仍高 → 用户改 50；比展开态 92 矮 42pt。
///  真值表旧文案「58」与源注释旧「66」都是拿错 padding 算的，已按真值修正。）
let collapsedContainerMirror = messageRowMirror + containerVPaddingMirror * 2             // = 42 + 8 = 50
/// v3.9.67：圆角 20 下的两个平坦段 —— 收起态 50 − 20×2 = **10pt**（收窄但 > 0）；
/// 展开态 92 − 20×2 = **52pt**（原 44 是拿 84 当容器高算的，实际容器含 padding）
let flatTopMirror = containerMirror + containerVPaddingMirror * 2 - 2 * 20              // 52（展开态）
let flatTopCollapsedMirror = collapsedContainerMirror - 2 * 20                          // 10（收起态）

check("算式：第一层高 ≈42（12×2 + 17.9）", abs(messageRowMirror - 42) < 0.2)
check("算式：第二层高 = 34（22 + 6×2，v3.9.65 变小后）", abs(toolRowMirror - 34) < 0.001)
check("算式：展开态内容最小总高 ≈84（42+8+34，containerMinHeight 语义）", abs(containerMirror - 84) < 0.2)
check("算式：展开态容器高 = 92（84 内容 + 垂直 padding 4×2，v3.9.67）", abs(flatTopMirror + 2 * 20 - 92) < 0.2)
check("算式：展开态圆角 20 的上缘平坦段 = 52pt（92 − 20×2）", abs(flatTopMirror - 52) < 0.2)
check("算式：收起态容器高 = 50（42 + 4×2，v3.9.67 用户明确值）", abs(collapsedContainerMirror - 50) < 0.2)
check("算式：收起态比展开态矮 42pt（92 − 50，v3.9.66 时只矮 18）",
      abs(expandedContainerMirror + containerVPaddingMirror * 2 - collapsedContainerMirror - 42) < 0.2)
check("算式：收起态高度 > 第一层内容高（50 > 42，文字不被裁）",
      collapsedContainerMirror > messageRowMirror)
check("算式：收起态圆角 20 的上缘平坦段 = 10pt（50 − 20×2，仍 > 0 弧顶不咬文字）",
      abs(flatTopCollapsedMirror - 10) < 0.2)
check("常量与算式一致：rowGap == 8",
      abs(Double(ChatInputBarLayoutMirror.rowGap) - rowGapMirror) < 0.001)
check("常量与算式一致：messageRowMinHeight == 42",
      abs(Double(ChatInputBarLayoutMirror.messageRowMinHeight) - 42) < 0.001)
check("常量与算式一致：toolRowMinHeight == 34（v3.9.65）",
      abs(Double(ChatInputBarLayoutMirror.toolRowMinHeight) - 34) < 0.001)
check("常量与算式一致：containerMinHeight == 84（不手改，改了算式就对不上）",
      abs(Double(ChatInputBarLayoutMirror.containerMinHeight)
          - (ChatInputBarLayoutMirror.messageRowMinHeight
             + ChatInputBarLayoutMirror.rowGap
             + ChatInputBarLayoutMirror.toolRowMinHeight)) < 0.001)
check("常量与算术一致：containerCornerRadius == 20（v3.9.66，18 → 20）且两个平坦段均 > 0",
      abs(Double(ChatInputBarLayoutMirror.containerCornerRadius) - 20) < 0.001
      && flatTopCollapsedMirror > 0 && flatTopMirror > 0)
// v3.9.67：容器垂直 padding 与源串对齐的硬护栏（镜像数 4 = Spacing.xs）——
// 源里若被改成别的档（如回 Spacing.md），收起态就不是 50，本表前面几条算式全红。
check("常量与算式一致：容器垂直 padding 4（Spacing.xs，v3.9.67「收起态高度改为 50」）",
      abs(containerVPaddingMirror - Double(ChatInputBarLayoutMirror.containerVPadding)) < 0.001)

print("输入栏两层化真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
