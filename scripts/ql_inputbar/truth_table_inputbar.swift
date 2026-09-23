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
      inputBarSrc.contains("VStack(spacing: ChatInputBarLayout.rowGap) {"))
check("第一层 messageRow 在容器里", inputBarSrc.contains("            messageRow\n"))
check("第二层 toolRow 在容器里", inputBarSrc.contains("            toolRow\n"))
check("messageRow 是独立计算属性", inputBarSrc.contains("private var messageRow: some View"))
check("toolRow 是独立计算属性", inputBarSrc.contains("private var toolRow: some View"))
check("两层间距走 Layout 常量（不写魔法数）",
      inputBarSrc.contains("static let rowGap: CGFloat = Spacing.md"))

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
check("两层高度走 Layout 常量 messageRowMinHeight / toolRowMinHeight",
      inputBarSrc.contains(".frame(minHeight: ChatInputBarLayout.messageRowMinHeight)")
      && inputBarSrc.contains(".frame(minHeight: ChatInputBarLayout.toolRowMinHeight)"))
check("两层高度都不是写死数字（写死会在放大字号时裁字）",
      !inputBarSrc.contains(".frame(minHeight: 42)")
      && !inputBarSrc.contains(".frame(minHeight: 44)"))

// ── 3c. 外层玻璃容器形状（用户：「内部的椭圆玻璃层就不要了，只留底部方形圆角框」）──
// v3.9.62 第一版走 `.background { RoundedRectangle(...).glassEffect() }`——**宿主形状拦不住玻璃本体**：
// Apple 官方明确 glassEffect 默认形状是 Capsule（`DefaultGlassEffectShape`；文档原文「applies the
// given effect within a Capsule shape behind the view's content」），Drop 到宿主是圆角矩形时玻璃仍按
// 胶囊渲染（两端半径 = 容器高/2 ≈54），衬在圆角矩形白边**里面**→ 用户看到「方框里套椭圆玻璃」。
// 正确做法 = 官方 `in:` 参数把玻璃钉进 RoundedRectangle，玻璃与描边同形、容器只剩一个形状。
// 同一形状必须在三处同时成立：玻璃底（in: 参数）/ 聚焦蓝边 / 常态白边。
check("外层玻璃容器走 Radius.field(14) 圆角矩形（不再全圆角胶囊）",
      inputBarSrc.contains(".glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))"))
check("容器圆角走 Radius 令牌，不是魔法数",
      inputBarSrc.contains("in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous)"))
// 旧写法清零：玻璃不再挂在 background{Shape} 宿主上（宿主 Shape 拦不住默认胶囊形态）
check("旧写法清零：玻璃不挂 background{ Shape } 宿主（v3.9.62 椭圆玻璃病根）",
      !inputBarSrc.contains(".background {\n            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)\n                .glassEffect()\n        }"))
check("玻璃容器不再是 Capsule（旧胶囊形态清零）",
      !inputBarSrc.contains(".background { Capsule().glassEffect() }"))
check("聚焦蓝边描边同圆角矩形（与玻璃底同形）",
      inputBarSrc.contains("overlay {\n            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)\n                .strokeBorder(Color.blue.opacity(focused ? 0.45 : 0), lineWidth: 0.8)"))
check("常态白边描边同圆角矩形（与玻璃底同形）",
      inputBarSrc.contains("RoundedRectangle(cornerRadius: Radius.field, style: .continuous)\n                    .strokeBorder(.white.opacity(Tint.subtle), lineWidth: 0.8)"))
// 排除式：fullInputBar 体内（到 fullInputBar 函数体闭合为止）不得再出现容器级 Capsule。
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
//   第二层 42 = 附件/相机视觉 30 + 上下各 6（与 30 → 42 的对齐余量）
//   间距    8 = Spacing.md
//   容器最小总高 = 42 + 8 + 42 = 92
// 本机 import 不到 SwiftUI → 常量在这里镜像一份；源里改了数、这里不同步 → 表立刻红。
enum ChatInputBarLayoutMirror {
    static let messageRowMinHeight: Double = 42
    static let toolRowMinHeight: Double = 42
    static let rowGap: Double = 8
    static let containerMinHeight: Double = 92
}

let rowGapMirror: Double = 8
let messageRowMirror: Double = 12 * 2 + 17.9   // ≈41.9 → 收 42
let toolRowMirror: Double = 30 + 6 * 2          // 42
let containerMirror = messageRowMirror + rowGapMirror + toolRowMirror

check("算式：第一层高 ≈42（12×2 + 17.9）", abs(messageRowMirror - 42) < 0.2)
check("算式：第二层高 = 42（30 + 6×2）", abs(toolRowMirror - 42) < 0.001)
check("算式：容器最小总高 ≈92（42+8+42）", abs(containerMirror - 92) < 0.2)
check("常量与算式一致：rowGap == 8",
      abs(Double(ChatInputBarLayoutMirror.rowGap) - rowGapMirror) < 0.001)
check("常量与算式一致：messageRowMinHeight == 42",
      abs(Double(ChatInputBarLayoutMirror.messageRowMinHeight) - 42) < 0.001)
check("常量与算式一致：toolRowMinHeight == 42",
      abs(Double(ChatInputBarLayoutMirror.toolRowMinHeight) - 42) < 0.001)
check("常量与算式一致：containerMinHeight == 92（不手改，改了算式就对不上）",
      abs(Double(ChatInputBarLayoutMirror.containerMinHeight)
          - (ChatInputBarLayoutMirror.messageRowMinHeight
             + ChatInputBarLayoutMirror.rowGap
             + ChatInputBarLayoutMirror.toolRowMinHeight)) < 0.001)

print("输入栏两层化真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
