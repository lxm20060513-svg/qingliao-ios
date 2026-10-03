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
let chatViewSrc = src("Features/Chat/ChatView.swift")

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
check("第二层收起态是硬钳 height:0（v3.9.68 fix：minHeight:0 不压内容固有高 22，容器会变 72）",
      inputBarSrc.contains(".frame(height: toolLayerExpanded ? nil : 0)"))
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
check("常量未被顺手改：toolRowMinHeight 仍 38、messageRowMinHeight 仍 42、rowGap 仍 Spacing.md（本轮只加收放不改量）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 38")
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
check("第二层行高常量未动（toolRowMinHeight 仍 38，v3.9.67 那轮只收容器 padding；数值本身 v3.9.75 才变）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 38"))
check("containerMinHeight 仍 88（语义=内容最小总高，容器高度由 padding 另行给）",
      inputBarSrc.contains("static let containerMinHeight: CGFloat = 88"))

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

// ── 3d. 第二层附件/相机尺寸（v3.9.65 变小 → v3.9.75 按用户要求加大一点）────────────
// v3.9.65：视觉面 32×30 → 22×22，第二层 minHeight 42 → 34，容器最小总高 92 → 84。
// v3.9.75：用户「展开态的附件和相机图标加大一点」→ 视觉面 22 → 26、字形 subhead(13) → body(15)，
//          minHeight 34 → **38**，containerMinHeight 84 → **88**（仍不回 42：只大一点，不回两层同高）。
// 命中区不受影响：外扩量 11 → 9，26+9×2 = 44 仍是 HIG 最小可点尺寸。
// 第一层 42、发送键 32×32、两层间距 8 三项**未动**（用户只点了第二层）。
check("附件钮视觉面 26×26（v3.9.75：22 → 26）",
      inputBarSrc.contains("Image(systemName: \"paperclip\")\n                    .font(.system(size: Typography.body, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 26, height: 26)"))
check("相机钮视觉面 26×26（v3.9.75：22 → 26）",
      inputBarSrc.contains("Image(systemName: \"camera\")\n                    .font(.system(size: Typography.body, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 26, height: 26)"))
// 计数必须限定在 attachButtons 段内：别处（转写取消 xmark）本来就是 26×26 + 外扩 9，全文件计数会误报。
check("附件/相机视觉面在 attachButtons 段内各一处 26×26（两处 = 一对按钮，防漏改/防多改）",
      {
          guard let a = inputBarSrc.range(of: "private var attachButtons: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          let slice = String(body[body.startIndex..<end.upperBound])
          return slice.components(separatedBy: ".frame(width: 26, height: 26)").count - 1 == 2
      }())
check("旧视觉面 32×30 与 22×22 清零（attachButtons 里两代旧尺寸都不回潮）",
      !inputBarSrc.contains(".frame(width: 32, height: 30)")
      && {
          guard let a = inputBarSrc.range(of: "private var attachButtons: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          return !String(body[body.startIndex..<end.upperBound]).contains(".frame(width: 22, height: 22)")
      }())
check("命中区仍 44×44：附件外扩 9（26+9×2=44，HIG 最小可点尺寸不变）",
      inputBarSrc.contains(".hitArea44(h: 9, v: 9)"))
check("附件/相机按钮级胶囊形态保留（改尺寸不动二元控件口径 in: Capsule()）",
      inputBarSrc.contains("Image(systemName: \"paperclip\")\n                    .font(.system(size: Typography.body, weight: .medium))\n                    .foregroundStyle(.secondary)\n                    .frame(width: 26, height: 26)\n                    // v3.4.26：附件/相机纳入胶囊语义——低透明外圈（次级操作，弱于实底发送钮）\n                    .background(Color.primary.opacity(Tint.faint), in: Capsule())"))
check("附件/相机命中区外扩各一处 9（段内计数互证：两处按钮都扩到 44）",
      {
          guard let a = inputBarSrc.range(of: "private var attachButtons: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound..<inputBarSrc.endIndex])
          guard let end = body.range(of: "\n    }\n") else { return false }
          return String(body[body.startIndex..<end.upperBound])
              .components(separatedBy: ".hitArea44(h: 9, v: 9)").count - 1 == 2
      }())
check("第二层行高常量升到 38（toolRowMinHeight，v3.9.75）",
      inputBarSrc.contains("static let toolRowMinHeight: CGFloat = 38"))
check("容器最小总高常量升到 88（containerMinHeight，v3.9.75）",
      inputBarSrc.contains("static let containerMinHeight: CGFloat = 88"))
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
//   第二层 38 = 附件/相机视觉 26 + 上下各 6（v3.9.75 起；v3.9.65~74 是 22 → 34；v3.9.61~64 是 30 → 42）
//   间距    8 = Spacing.md
//   容器最小总高 = 42 + 8 + 38 = 88
// 本机 import 不到 SwiftUI → 常量在这里镜像一份；源里改了数、这里不同步 → 表立刻红。
enum ChatInputBarLayoutMirror {
    static let messageRowMinHeight: Double = 42
    static let toolRowMinHeight: Double = 38
    static let rowGap: Double = 8
    static let containerMinHeight: Double = 88
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
let toolRowMirror: Double = 26 + 6 * 2          // 38（v3.9.75：视觉 22 → 26）
/// v3.9.68 fix：第二层图标**视觉面** 22（不含命中区外扩——hitArea44 的净外扩为 0）。
/// 事故证据用它：旧 bug 收起态容器 = 42 + 22 + 4×2 = 72。
let toolRowVisualMirror: Double = 22
let containerMirror = messageRowMirror + rowGapMirror + toolRowMirror   // 88（展开态内容）
/// v3.9.67：容器垂直 padding = Spacing.xs(4)（v3.9.66 是 Spacing.md 12；用户「收起态高度改为 50」）
let containerVPaddingMirror: Double = 4
/// v3.9.66：展开态容器高别名（与收起态对比用，名不同值同源，避免两处手写 84 漂移）
let expandedContainerMirror = containerMirror
/// v3.9.67：收起态（键盘未弹）容器高 = 第一层 42 + 垂直 padding 4×2 = **50**
/// （v3.9.66 = 42 + 12×2 = 66，真机观感仍高 → 用户改 50；v3.9.75 后比展开态 96 矮 46pt。
///  真值表旧文案「58」与源注释旧「66」都是拿错 padding 算的，已按真值修正。）
let collapsedContainerMirror = messageRowMirror + containerVPaddingMirror * 2             // = 42 + 8 = 50
/// 🚨 v3.9.68 fix 事故证据（用户真机报「输入框怎么被你改这么大」的算式铁证）：
/// 收起态第二层只写 `.frame(minHeight: 0)` —— minHeight 是**下限**不是钳制，第二层内容
/// （附件/相机视觉 22 + hitArea44 净外扩 0）固有高 22pt 照常占位 → 收起态容器 =
/// 42 + 22 + 4×2 = **72**（比用户明确值 50 高 22pt）。opacity 归 0 只让它不可见，
/// 占位仍在 → 那 22pt 是玻璃框内的空白，视觉上「输入框变大」且发送键/占位文字偏下。
/// 修法 = 补 `.frame(height: 0)` 硬钳。本镜像断言旧形态算式 ≠ 50，作为勿回退的证据钉住。
let brokenCollapsedMirror = messageRowMirror + toolRowVisualMirror + containerVPaddingMirror * 2   // 72（旧 bug）
/// v3.9.67：圆角 20 下的两个平坦段 —— 收起态 50 − 20×2 = **10pt**（收窄但 > 0）；
/// 展开态 92 − 20×2 = **52pt**（原 44 是拿 84 当容器高算的，实际容器含 padding）
let flatTopMirror = containerMirror + containerVPaddingMirror * 2 - 2 * 20              // 52（展开态）
let flatTopCollapsedMirror = collapsedContainerMirror - 2 * 20                          // 10（收起态）

check("算式：第一层高 ≈42（12×2 + 17.9）", abs(messageRowMirror - 42) < 0.2)
check("算式：第二层高 = 38（26 + 6×2，v3.9.75 图标加大后）", abs(toolRowMirror - 38) < 0.001)
check("算式：展开态内容最小总高 ≈88（42+8+38，containerMinHeight 语义）", abs(containerMirror - 88) < 0.2)
check("算式：展开态容器高 = 96（88 内容 + 垂直 padding 4×2，v3.9.67 起 padding 不变）", abs(flatTopMirror + 2 * 20 - 96) < 0.2)
check("算式：展开态圆角 20 的上缘平坦段 = 56pt（96 − 20×2）", abs(flatTopMirror - 56) < 0.2)
check("算式：收起态容器高 = 50（42 + 4×2，v3.9.67 用户明确值）", abs(collapsedContainerMirror - 50) < 0.2)
check("事故证据：旧 minHeight:0 形态算出的收起态容器 = 72 ≠ 50（v3.9.68「输入框被改这么大」根因，勿回退）",
      abs(brokenCollapsedMirror - 72) < 0.2 && abs(brokenCollapsedMirror - 50) > 20)
check("算式：收起态比展开态矮 46pt（96 − 50）",
      abs(expandedContainerMirror + containerVPaddingMirror * 2 - collapsedContainerMirror - 46) < 0.2)
check("算式：收起态高度 > 第一层内容高（50 > 42，文字不被裁）",
      collapsedContainerMirror > messageRowMirror)
check("算式：收起态圆角 20 的上缘平坦段 = 10pt（50 − 20×2，仍 > 0 弧顶不咬文字）",
      abs(flatTopCollapsedMirror - 10) < 0.2)
check("常量与算式一致：rowGap == 8",
      abs(Double(ChatInputBarLayoutMirror.rowGap) - rowGapMirror) < 0.001)
check("常量与算式一致：messageRowMinHeight == 42",
      abs(Double(ChatInputBarLayoutMirror.messageRowMinHeight) - 42) < 0.001)
check("常量与算式一致：toolRowMinHeight == 38（v3.9.75）",
      abs(Double(ChatInputBarLayoutMirror.toolRowMinHeight) - 38) < 0.001)
check("常量与算式一致：containerMinHeight == 88（不手改，改了算式就对不上）",
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

// ── 3e. 输入区/发送键细分隔线 + 底部留隙收紧（v3.9.68）──────────────────────────
// 用户原话两条：
//   ①「想让发送键上下到输入框都等高，所以底部要再往上收一点」
//      —— 底部呼吸改在 ChatView.chatComposerArea 收（Spacing.lg 10 → Spacing.xs 4），
//         本容器垂直 padding 保持 4 不动（两处叠加才是输入栏离屏底的距离，单改本容器
//         会把发送键压到贴玻璃下缘，破坏 v3.9.67 的居中口径）。
//   ②「输入框可以优化的精致一点视觉上更美观一点」
//      —— 文字区与发送键之间补 0.8pt 淡分隔线（Tint.faint，全站描边口径），
//         把「输入区」与「操作键」分成两个视觉组；命中区零影响（spacing 不变）。
// 算式：收起态容器底到屏底 = ChatView 底部呼吸 4 + 容器自身总高 50（含自身 padding 4×2）
//        = **54**（v3.9.67 口径是 10 + 50 = 60，本轮收紧 6pt）。
let composerBottomMirror: Double = 4
check("ChatView 底部呼吸收到 Spacing.xs(4)（v3.9.68 第 1 条：底部再往上收）",
      chatViewSrc.contains(".padding(.bottom, Spacing.xs)   // v3.0.67 起留隙口径不变"))
check("ChatView 旧底部呼吸 Spacing.lg(10) 清零（只此一处，别处留隙不混算）",
      !chatViewSrc.contains(".padding(.bottom, Spacing.lg)"))
check("分隔线在位：第一层文字区与发送键之间（vh: 0.8，全站描边口径）",
      inputBarSrc.contains("            divider\n            trailingButtons"))
check("分隔线命中区让渡（allowsHitTesting(false)，不抢发送键点击）",
      inputBarSrc.contains(".frame(width: 0.8)\n            .frame(maxHeight: ChatInputBarLayout.messageRowMinHeight)\n            .allowsHitTesting(false)"))
// v3.9.70：把「maxHeight: .infinity 分隔线撑爆第一层」的事故钉死——旧形态串必须清零。
// 事故复盘（真机 v3.9.69 截图像素取证）：maxHeight 无穷让第一层成为弹性子项，
// 被根布局塞进全部富余空间 → 分隔线实测 ≈285pt、容器 ≈293pt（应 50）。
check("分隔线高度钳制在位：旧 maxHeight:.infinity 已清零（v3.9.70 事故护栏）",
      !inputBarSrc.contains(".frame(maxHeight: .infinity)"))
check("分隔线走 Tint.faint（与全站 0.8pt 描边同色，不自创色）",
      inputBarSrc.contains(".fill(Color.primary.opacity(Tint.faint))"))
check("分隔线是独立计算属性（不内联，避免 ViewBuilder 深层推断）",
      inputBarSrc.contains("private var divider: some View"))
check("第一层 HStack spacing 未动（仍 8：分隔线占 0 宽，间距口径不变）",
      messageRowSlice.contains("HStack(spacing: 8)"))
check("算式：收起态容器底到屏底 = 4 + 50 = 54pt（v3.9.67 是 10 + 50 = 60）",
      abs(composerBottomMirror + collapsedContainerMirror - 54) < 0.2)

// MARK: - v4.0.x 录音电平反应点（voice-glow 位点：把识别器已算好的实时 RMS 接进输入栏）
//
// 背景：v3.9.14 的脉动点是**固定节拍**——不管说没说话节拍都一样，答不了「麦克风到底收到我的声音没有」。
// 电平原生通路已有护栏（在 ql_orbmenu 表：nonisolated 读数 / 不走 @Published / teardown 清零），
// 但那里**只钉了语音对话框一个读端**。本轮在输入栏加第二个读端，所以必须同批把新读端也钉住：
// 读端丢一个，功能静默失效，而通路护栏照样全绿。
let levelDotSlice: String = {
    guard let a = inputBarSrc.range(of: "private struct RecordingLevelDot") else { return "" }
    return String(inputBarSrc[a.lowerBound...].prefix(2400))
}()
check("录音点接实时电平（旧固定节拍脉动点已清零）",
      inputBarSrc.contains("RecordingLevelDot(level: recordingLevel)")
      && !inputBarSrc.contains("PulsingRecordDot"))
check("电平每帧自读快照：TimelineView + 闭包调用（与语音对话框波条同一套读法）",
      inputBarSrc.contains("TimelineView(.animation(minimumInterval: 1.0 / 30.0))")
      && inputBarSrc.contains("level()"))
check("帧率有上限（流光是 15fps；圆点更小可略高，但不许裸 .animation 无限帧）",
      !inputBarSrc.contains("TimelineView(.animation) {"))
check("电平以**闭包**传入，调用点传 nonisolated 快照（按值传入 = 聊天页被 14Hz 全量重绘）",
      inputBarSrc.contains("var recordingLevel: () -> Float = { 0 }")
      && chatViewSrc.contains("recordingLevel: { liveSpeech.currentInputLevel() }"))
check("实参序：recordingLevel 追加在 onPickModel 之后（成员初始化器按声明序传参）",
      {
          guard let a = chatViewSrc.range(of: "onPickModel: { showComposerModel = true },"),
                let b = chatViewSrc.range(of: "recordingLevel: { liveSpeech.currentInputLevel() }")
          else { return false }
          return a.upperBound < b.lowerBound
      }())
check("光晕不用 shadow（v3.2.3 红线）；走 .background 半透明填充，不参与布局（文字不被推着移位）",
      levelDotSlice.contains(".fill(Color.red.opacity(")
      && levelDotSlice.contains(".background {")
      && !levelDotSlice.contains(".shadow"))
check("观感零回退：安静时保留原节拍分量（0.85→1.45 缩放 + 0.5→1.0 透明度），电平只做叠加",
      levelDotSlice.contains("0.85 + 0.60 * CGFloat(breath)")
      && levelDotSlice.contains("0.5 + 0.5 * breath"))
// 峰值口径 1.70（安静 0.85 ↔ 最大声 1.70）。原系数 0.55 会冲到 2.00：7pt 点视觉直径顶到 14pt
// （超口径 2pt）并压住右侧「正在听…」文字左沿 —— 审查实测出的口径漂移，护栏在这里钉住上限。
check("电平叠加系数 0.25（与节拍项 0.60 相加恰好到 1.70 峰值，不许再放大）",
      levelDotSlice.contains("0.85 + 0.60 * CGFloat(breath) + 0.25 * lv"))
check("光晕直径跟圆点缩放走（否则最大声时点被放大、环反而最薄：每侧 2.5pt 应为 3.5pt）",
      levelDotSlice.contains("7 * dotScale + 12 * lv"))
check("「减弱动态效果」退静态红点（与 v3.9.19 同口径，「正在听」的信息不丢）",
      levelDotSlice.contains("if reduceMotion {"))

// ── v4.0.10 发送锁 / 幂等闸门（「发出去不上屏」根因护栏） ─────────────
// 实报：v4.0.9 上「输入内容点发送没反应，消息不上屏，后端零请求」。
// 根因：发送锁只在流收尾回调里解锁；「新建会话」把在跑的流移交给 BackgroundStreamRunner 时走
// StreamClient.detachLocally()（刻意把 onFinished 置 nil，落库归 runner）→ 回调永不执行 →
// 锁永久为真 → 此后 sendCore 第一道 guard 静默 return（输入框已清空，用户看到「发出去不上屏」）。
// 护栏钉三件事：锁必须有窗口上限 + 移交路径显式解锁 + 幂等只对自动路径生效。
let sendCoreSlice: String = {
    guard let a = chatViewSrc.range(of: "func sendCore(") else { return "" }
    return String(chatViewSrc[a.lowerBound...])
}()
check("sendCore 源切片非空", sendCoreSlice.count > 100)
check("🚨 发送锁不许写成无窗口硬锁（`guard !sendingLock` 必须清零）",
      !sendCoreSlice.contains("guard !sendingLock"))
check("发送锁判定带窗口上限（sendingLockAt 差值 < 0.8）",
      sendCoreSlice.contains("if sendingLock {") && sendCoreSlice.contains("now - sendingLockAt < 0.8"))
check("锁超窗必须自动解锁（泄漏后能自愈，不许等回调）",
      sendCoreSlice.contains("发送锁超窗自动解锁"))
check("上锁时同步记置位时刻（sendingLockAt = now）", sendCoreSlice.contains("sendingLockAt = now"))
check("两条静默吞路径都留取证日志（双击拦截 / 幂等丢弃）",
      sendCoreSlice.contains("[SEND] 双击拦截") && sendCoreSlice.contains("[SEND] 幂等丢弃"))
check("🚨 幂等闸门必须放行「用户亲手发送」（条件带 !allowExpense）",
      sendCoreSlice.contains("now - last.ts < 60, !allowExpense {"))
check("移交后台跑流器后显式解锁（detachLocally 之后 sendingLock = false）",
      {
          guard let a = chatViewSrc.range(of: "stream.detachLocally()") else { return false }
          let after = String(chatViewSrc[a.upperBound...].prefix(400))
          return after.contains("sendingLock = false")
      }())
check("收尾回调里的解锁仍在（两条解锁路径并存，防误删）",
      chatViewSrc.contains("sendingLock = false   // 无论结果，先释放发送锁"))

// ── v4.1.x 多会话并行：发送路径不再「一律排队」（2026-09-30 用户实报） ─────
// 实报：「两个会话同时跑时，第二条上屏后显示排队中」——A 会话跑着，切到 B 发消息，
// 旧逻辑无条件走本地排队（消息顶着「排队中」），要等 A 整轮跑完才轮到 B。
// 口径修正：在跑的流属于**别的会话**时，把那条流移交 BackgroundStreamRunner（服务端任务不停），
// 本地单例腾出来给本条立即开跑；同会话连发仍走排队（并发会串上下文与落库）。
// 三条都会**静默**错，所以钉住：①移交必须在排队分支**之前**（否则永远走不到）；
// ②同会话不许移交（guard sid != chat.sessionId）；③排队老路不许被删（同会话唯一出路）。
let handoffSlice: String = {
    guard let a = chatViewSrc.range(of: "func handoffRunningStreamToBackground()") else { return "" }
    return String(chatViewSrc[a.lowerBound...])
}()
check("handoffRunningStreamToBackground 源切片非空（切片失败 = 下面全是空真）", handoffSlice.count > 200)
check("🚨 sendCore 在排队分支**之前**尝试移交（跨会话并行入口，写反了永远走不到）",
      {
          guard let s = sendCoreSlice.range(of: "if !handoffRunningStreamToBackground()"),
                let q = sendCoreSlice.range(of: "msg.queued = true") else { return false }
          return s.lowerBound < q.lowerBound
      }())
check("同会话连发不许移交（guard 里带 `sid != chat.sessionId`）",
      handoffSlice.contains("sid != chat.sessionId"))
check("异常态护栏齐（isStreaming / !isDone / taskId 非空缺一味就移交给错对象）",
      handoffSlice.contains("stream.isStreaming, !stream.isDone, !stream.taskId.isEmpty"))
check("移交复用既有 adopt（后台跑流器）+ detachLocally 组合",
      handoffSlice.contains("BackgroundStreamRunner.shared.adopt(")
      && handoffSlice.contains("stream.detachLocally()"))
check("移交后显式解锁（detachLocally 吞掉 onFinished → 防发送锁泄漏）",
      handoffSlice.contains("sendingLock = false"))
check("排队老路仍在（同会话连发的唯一出路，不许被这次改动删掉）",
      sendCoreSlice.contains("pendingQueue.append(PendingSend(") && sendCoreSlice.contains("persistPendingQueue()"))
check("「排队中」标记仍在（同会话排队时那条上屏角标）", sendCoreSlice.contains("msg.queued = true"))

// ── v4.0.10：思考气泡动画概率不启动（2026-09-30 用户实报） ────────────
// 循环脉冲靠 `.animation(_:value:)` 的 false→true **边沿**启动；只写「onAppear 置 true」时，
// 视图离开层级又被加回（滚动回收 / `thisSessionStreaming` 抖动 / 切会话回来）@State 仍是 true
// → 第二次 onAppear 无变化 → repeatForever 不重启 → 三点静止。四条一起钉住：
// ①onAppear 与 onDisappear **成对**（消隐复位才保证下次出现有边沿）②不许改用异步翻转
// ③不许退回「只有 onAppear 没有 onDisappear」的老写法 ④外观口径不动。
let typingSlice: String = {
    guard let a = chatViewSrc.range(of: "struct TypingIndicator: View") else { return "" }
    return String(chatViewSrc[a.lowerBound...])
}()
// 只认定位切片里的**代码行**（注释里会提到 `DispatchQueue.main.async` 这个反面例子，
// 不滤掉注释的话「不许改异步」那条会假失败）。
let typingCode = typingSlice.split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.hasPrefix("//") }
    .joined(separator: "\n")
check("TypingIndicator 源切片非空（切片失败 = 下面全是空真）", typingSlice.count > 200)
// v4.0.12 根治「圆点脉冲自己消失」（用户 2026-09-30 真机实报：onAppear/onDisappear 边沿方案
// 没根治，思考气泡在父级重建时身份抖动，边沿丢失后 @State 已是 true → 动画永不重启 ≈ 空泡）。
// 根治：TimelineView 驱动——相位由时间戳直接算出，视图怎么重建都停不下来；旧断言全部退役。
// v4.0.19（用户 2026-10-01 三报「动一段时间就会消失」）：`.animation` 调度是官方「pausable
// schedule」——没有活动动画时被系统降频/暂停，恰是本动画停摆的真根因 → 换 `.periodic`
// 墙钟调度（regular intervals 永不暂停）。护栏同步换契约：钉 periodic + 禁 .animation 调度。
check("🚨 脉冲改 TimelineView 墙钟驱动（.periodic；.animation 是 pausable schedule、会被系统停表）",
      typingCode.contains("TimelineView(.periodic(from: .now")
      && typingCode.contains("timeline.date.timeIntervalSinceReferenceDate")
      && !typingCode.contains("TimelineView(.animation("))
check("零 @State 动画位（不存在可丢失的 false→true 边沿 = 根因移除）",
      !typingCode.contains("@State") && !typingCode.contains(".repeatForever"))
check("周期与旧版一致（1.2s 全周期 = 0.6s easeInOut 往返 + 每颗错相 0.18s）",
      typingCode.contains("dividingBy: 1.2") && typingCode.contains("Double(i) * 0.18"))
check("reduceMotion：不建时钟直接渲染静止满点（强度 1.0，periodic 无 paused 参数）",
      typingCode.contains("if reduceMotion {") && typingCode.contains("dotRow(timeline: nil)")
      && typingCode.contains("?? 1.0"))
check("🚨 切断祖先动画事务继承（v4.0.14 真机再报「还是会丢失」的真根因：宿主满屏 "
    + "withAnimation / .animation(_:value:) 在更上层，逐帧 scaleEffect/opacity 被隐式动画"
    + "插值成一团均值 → 帧在走、画面看着静止）",
      typingCode.contains(".transaction { $0.animation = nil }"))
check("🚨 强度下限 ≥0.6（时钟被主线程抢占时那一帧仍看得见三点，不会退化成空泡）",
      typingCode.contains("0.62 + 0.38 * (1.0 - $0)")   // v4.0.19 起 pulse 收进 map 闭包，形参是 $0
      && !typingCode.contains("0.45 + 0.55 * (1.0 - pulse)"))
check("不许改用异步翻转（Swift 6 严格并发下闭包捕获 View 编译不过）",
      !typingCode.contains("DispatchQueue.main.async"))

// 同族第三处：header「AI 正在输入」小三点（LiquidGlass.BusyDots）——同一个「边沿」坑。
// 三处（ChatView.TypingIndicator / PetAvatar.ThinkingDots / BusyDots）修法一致：消隐复位。
let liquidSrc = src("Theme/LiquidGlass.swift")
let busyDotsSlice: String = {
    guard let a = liquidSrc.range(of: "struct BusyDots: View") else { return "" }
    return String(liquidSrc[a.lowerBound...].prefix(1200))
}()
let busyCode = busyDotsSlice.split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.hasPrefix("//") }
    .joined(separator: "\n")
check("BusyDots 切片非空（header「AI 正在输入」小三点）", busyCode.count > 100)
check("🚨 BusyDots 消隐时复位（缺它则三点概率静止不呼吸）",
      busyCode.contains(".onDisappear { on = false }"))
check("BusyDots 出现时置位", busyCode.contains(".onAppear { on = true }"))
check("BusyDots 外观口径不动（opacity 呼吸 + 分相 delay）",
      busyCode.contains(".delay(Double(i) * 0.16), value: on)"))

// ── v4.1.x：多会话并行下「整个气泡压根不出现」（2026-09-30 用户实报，与动画那条是**两条不同的链**）──
// 现象：输入栏胶囊/灵动岛按 aiBusy 显示「AI 正在输入」，聊天流里却一个思考气泡都没有。
// 根因：气泡条件只认 thisSessionStreaming，漏掉「服务器有在途任务、本地被 guard `!stream.isStreaming`
// 挡着没接回」这一态（多会话并行时几乎必现：另有会话在前台收流 → 自己不接回）。三条护栏：
let bubbleCond: String = {
    guard let a = chatViewSrc.range(of: "if thisSessionStreaming || remoteBusy {") else { return "" }
    let tail = String(chatViewSrc[a.lowerBound...])
    let window = String(tail.prefix(3000))   // 足够罩住本组两个分支（中间的说明注释也算在内）
    // 终点取窗口内**最后一次** streamingBubble：上面那段注释里会提到这个名字（首现在注释里），
    // 只有 backwards 才能切到真正的 else 体（用首现会把切片截在注释上，下面三条全假红）。
    if let b = window.range(of: "streamingBubble", options: .backwards) {
        return String(window[..<b.upperBound])
    }
    return window
}()
check("🚨 思考气泡条件与 aiBusy 对齐（含 remoteBusy，否则「气泡压根不出现」）",
      bubbleCond.contains("if thisSessionStreaming || remoteBusy {"))
check("🚨 气泡内层条件必须取反（无内容/纯 remoteBusy 走三点）",
      bubbleCond.contains("if !thisSessionStreaming || stream.content.isEmpty {"))
// 防再写反（发布前审查实抓，2026-09-30）：光断言「条件存在」是**假护栏**——条件写反过一次，
// 症状是「本地流式全程三点、整段回答到收尾才蹦出来」。这里改断言**分支体归属**：
let bubbleIfBody: String = {
    guard let a = bubbleCond.range(of: "if !thisSessionStreaming || stream.content.isEmpty {") else { return "" }
    let tail = String(bubbleCond[a.lowerBound...])
    guard let b = tail.range(of: "} else {") else { return "" }
    return String(tail[..<b.lowerBound])
}()
let bubbleElseBody: String = {
    guard let b = bubbleCond.range(of: "} else {") else { return "" }
    return String(bubbleCond[b.upperBound...].prefix(200))
}()
// v4.0.39：三点本体已从 inline 块抽成计算属性 thinkingIndicatorRow（外面套了一层浮现包装），
// 所以 if 体不再出现 TypingIndicator() 字面量。断言跟着改成**两跳**：if 体必须调 thinkingIndicatorRow，
// 且 thinkingIndicatorRow 本体（定义处）必须真的渲染 TypingIndicator() —— 语义没变，
// 仍能钉住「if 体是三点、else 体是 streamingBubble」这条发布前审查抓出来的分支归属。
let typingRowSrc: String = {
    guard let a = chatViewSrc.range(of: "private var thinkingIndicatorRow: some View") else { return "" }
    return String(chatViewSrc[a.lowerBound...].prefix(1200))
}()
check("🚨 气泡 if 体必须是三点（写反 = 有内容时只显示三点，回答最后才蹦出来）",
      bubbleIfBody.contains("thinkingIndicatorRow") && !bubbleIfBody.contains("streamingBubble")
      && typingRowSrc.contains("TypingIndicator()"))
check("🚨 气泡 else 体必须是 streamingBubble（否则首帧/纯 remoteBusy 拿残留内容渲染 = 串话）",
      bubbleElseBody.contains("streamingBubble"))
let sidChangeSlice: String = {
    guard let a = chatViewSrc.range(of: "dropPendingQueue(dropping: prior)") else { return "" }
    return String(chatViewSrc[a.lowerBound...].prefix(700))
}()
check("🚨 切会话作废上一会话的忙态结论（否则新会话假气泡 / 假「AI 正在输入」）",
      sidChangeSlice.contains("remoteBusy = false") && sidChangeSlice.contains("remoteBusyFails = 0"))

// ── v4.0.27 思考档位胶囊迁入工具层（用户：胶囊放输入框展开态拍照旁、风格对齐附件/相机） ──
// ① 输入栏侧：reasoningButton 挂 toolRow（附件/相机之后）、壳逐值对齐 attachButtons（淡底 Tint.faint
//   + 0.8pt 同色描边）、门控走 reasoningLevelTitle 空串（与 modelButton 同套）。
// ② ChatView 侧：header 不再挂（reasoningPill/localReasoningPill 清零）、调用点传展示值 + 回调，
//   实参序 = 声明序（recordingLevel 之后）。
check("思考档位胶囊挂进工具层（附件/相机之后）",
      toolRowSlice.components(separatedBy: "attachButtons").count - 1 == 1
      && toolRowSlice.contains("attachButtons\n            reasoningButton"))
check("思考档位胶囊壳对齐附件/相机（淡底 Tint.faint + 0.8pt 同色描边）",
      {
          guard let a = inputBarSrc.range(of: "private var reasoningButton: some View") else { return false }
          let body = String(inputBarSrc[a.lowerBound...].prefix(1600))
          guard let end = body.range(of: "\n    }\n") else { return false }
          let slice = String(body[body.startIndex..<end.upperBound])
          return !slice.isEmpty
              && slice.contains(".background(Color.primary.opacity(Tint.faint), in: Capsule())")
              && slice.contains("Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)")
              && slice.contains("hitArea44(h: 9, v: 9)")
      }())
check("思考档位胶囊门控 = reasoningLevelTitle 空串（别的调用方零感知）",
      inputBarSrc.contains("if !reasoningLevelTitle.isEmpty {"))
check("调用点传展示值 + 回调（实参序 = 声明序：recordingLevel 声明在最前）",
      {
          guard let a = chatViewSrc.range(of: "reasoningLevelIcon: reasoningLevel.symbol"),
                let b = chatViewSrc.range(of: "reasoningLevelTitle: reasoningLevel.title"),
                let c = chatViewSrc.range(of: "onPickReasoning: { showReasoningPicker = true }"),
                let d = chatViewSrc.range(of: "recordingLevel: { liveSpeech.currentInputLevel() }")
          else { return false }
          // ⚠️ v4.0.28 修正（存量假红）：旧断言要求 recordingLevel 排在 **最后**，与 ChatInputBar
          // 的真实声明序矛盾（声明区：recordingLevel 在 94 行，reasoningLevelIcon/Title/onPickReasoning
          // 在 99~101 行）→ 恒红。真口径 = 本仓铁律「实参序 = 声明序」：recordingLevel 必须在最前。
          return d.upperBound <= a.lowerBound
              && a.upperBound < b.lowerBound
              && b.upperBound < c.lowerBound
      }())
check("header 旧思考胶囊清零（reasoningPill / localReasoningPill 不复存在）",
      !chatViewSrc.contains("private var reasoningPill: some View")
      && !chatViewSrc.contains("localReasoningPill"))
check("档位弹窗仍由 ChatView 持有（confirmationDialog 不动）",
      chatViewSrc.contains(".confirmationDialog(\"模型思考档位\", isPresented: $showReasoningPicker"))

// ── v4.0.36 朗读胶囊迁入工具层（用户：胶囊移动到对话框展开态底部模型思考档位旁边，
//            图标风格对齐模型思考档位胶囊） ──
// ① 输入栏侧：autoReadButton 挂 toolRow（紧挨思考档位之后）、图标风格**逐值对齐** reasoningButton、
//   门控走 autoReadIcon 空串（与 reasoningButton 同套：别的调用方零感知）。
// ② ChatView 侧：旧位置清零（autoReadPill 本体 + 调用点都搬走）、状态与动作留本页（toggleAutoRead）、
//   调用点传展示值 + 回调，实参序 = 声明序（onPickReasoning 之后）。
/// 切出输入栏里某个 `private var X: some View` 的函数体（首个「4 空格缩进的 }」为止）
func barSlice(_ marker: String) -> String {
    guard let a = inputBarSrc.range(of: marker) else { return "" }
    let body = String(inputBarSrc[a.lowerBound...].prefix(1600))
    guard let end = body.range(of: "\n    }\n") else { return "" }
    return String(body[body.startIndex..<end.upperBound])
}
let autoReadSlice = barSlice("private var autoReadButton: some View")
let reasoningSliceV436 = barSlice("private var reasoningButton: some View")
check("两枚胶囊的函数体都切出来了（切片空了 → 下面两条就成了空真）",
      !autoReadSlice.isEmpty && !reasoningSliceV436.isEmpty)
check("朗读胶囊挂进工具层（思考档位之后、模型快选之前，且只挂一处）",
      {
          guard let r = toolRowSlice.range(of: "reasoningButton"),
                let a = toolRowSlice.range(of: "autoReadButton"),
                let s = toolRowSlice.range(of: "Spacer(minLength: 0)") else { return false }
          return r.upperBound < a.lowerBound && a.upperBound < s.lowerBound
              && toolRowSlice.components(separatedBy: "autoReadButton").count - 1 == 1
      }())
check("🚨 朗读胶囊图标风格逐值对齐思考档位（字号/字重 + 视觉高 + 淡底 + 0.8pt 描边 + 命中区 44）",
      ["Typography.body, weight: .medium", "height: 26",
       "Color.primary.opacity(Tint.faint), in: Capsule()",
       "strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)",
       "hitArea44(h: 9, v: 9)"].allSatisfy { autoReadSlice.contains($0) && reasoningSliceV436.contains($0) })
check("朗读胶囊 = 纯图标 26×26 视觉面 + 两态只差图标着色（accent / secondary，沿用 header 口径）",
      autoReadSlice.contains("Image(systemName: autoReadIcon)")
      && autoReadSlice.contains(".frame(width: 26, height: 26)")
      && autoReadSlice.contains("autoReadOn ? Color.accentColor : Color.secondary"))
check("朗读胶囊门控 = autoReadIcon 空串（别的调用方零感知）",
      inputBarSrc.contains("if !autoReadIcon.isEmpty {"))
check("朗读胶囊只此两处（声明 + 挂载，不许有第二个挂点）",
      inputBarSrc.components(separatedBy: "autoReadButton").count - 1 == 2)
check("调用点传展示值 + 回调（实参序 = 声明序：onPickReasoning 之后紧跟 autoReadIcon/On/onToggle）",
      {
          guard let c = chatViewSrc.range(of: "onPickReasoning: { showReasoningPicker = true }"),
                let i = chatViewSrc.range(of: "autoReadIcon: \"speaker.wave.2.fill\""),
                let o = chatViewSrc.range(of: "autoReadOn: autoReadReply"),
                let t = chatViewSrc.range(of: "onToggleAutoRead: { toggleAutoRead() }")
          else { return false }
          return c.upperBound < i.lowerBound && i.upperBound < o.lowerBound && o.upperBound < t.lowerBound
      }())
check("header 旧朗读胶囊清零（autoReadPill 不复存在：本体与调用点都搬走了）",
      !chatViewSrc.contains("autoReadPill"))
check("状态与动作仍留 ChatView（toggleAutoRead：关掉立刻闭嘴 + 触感；状态走 UserDefaults 不变）",
      chatViewSrc.contains("private func toggleAutoRead()")
      && chatViewSrc.contains("if !autoReadReply { SpeechManager.shared.stop() }")
      && chatViewSrc.contains("Haptics.tap()"))

print("输入栏两层化真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
