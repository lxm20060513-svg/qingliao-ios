// MARK: - 会话列表「进行中」标识 · 真值表（v4.0.x · 2026-09-27 用户拍板）
//
// 口径（用户从编号选项里拍板）：
//   位置 = **替换右列 chevron**；形态 = **呼吸脉冲小圆点**（开了「减弱动态效果」即静止常亮）；
//   判定 = **本机这条流没结束就算**（切到别的会话看别的行、App 切后台都照显）。
//
// 为什么值得钉（三处都会**静默**错，不报错、只让用户觉得「这功能没用/列表发烫」）：
//   ① 真源是「流归属会话」`auth.currentStreamSessionId` —— StreamClient 启动时写入，**结束后不清空**
//      （全仓只有三处赋值、没有复位），只看它不配 isStreaming/isDone 就会把上一次跑过的会话永久标成进行中；
//   ② 多选编辑态必须优先：标识把勾选圈顶掉 = 编辑模式下点不中要删的会话；
//   ③ 会话列表在流式期间会重新求值 —— 行内**只许读 isStreaming/isDone**（布尔），
//      一旦读到 `stream.content`（每 token 都变），列表就每个 token 重算一次。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 去掉 `//` 与 `/* */` 注释，只留代码文本（注释里常留着旧口径说明，先剥再判）
func stripComments(_ s: String) -> String {
    var out = ""
    var inLine = false, inBlock = false
    var prev: Character = " "
    for ch in s {
        if inLine {
            if ch == "\n" { inLine = false; out.append(ch) }
            continue
        }
        if inBlock {
            if ch == "*" && prev == "/" { inBlock = false }
            prev = ch == "*" ? "*" : " "
            continue
        }
        if ch == "/" && prev == "/" { inLine = true; prev = " "; continue }
        if ch == "/", let n = out.last, n == "*" { inBlock = true; prev = " "; continue }
        out.append(ch)
        prev = ch
    }
    return out.replacingOccurrences(of: "*/", with: " ")
}

/// 取 a 之后、b 之前的一段源码（先断言切片非空，否则下面的断言等于空真）
func slice(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}

let viewSrc = src("qingliao/Features/Sessions/SessionsView.swift")
let viewCode = stripComments(viewSrc)

// ── 1. 源可读（空了下面全是空真） ─────────────────────────────
check("SessionsView.swift 源可读", !viewCode.isEmpty)

// ── 2. 会话列表页真的拿到了流对象（缺它读不到 isStreaming → 标识永远不出现） ──
check("SessionsView 注入了 StreamClient（@Environment(StreamClient.self) private var stream）",
      viewCode.contains("@Environment(StreamClient.self) private var stream"))

// ── 3. 「算不算进行中」的判定（本表最重要的三条） ──────────────
let judge = slice(viewCode, "private var runningSessionID: String?", "private func sessionCell(_ s: ChatSession)")
check("runningSessionID 切片非空（护栏不许空真）", !judge.isEmpty)
check("必须取**流归属**会话 auth.currentStreamSessionId（不是当前打开的会话）",
      judge.contains("auth.currentStreamSessionId"))
check("必须同时判 stream.isStreaming（光看归属 id 会把上次跑过的会话永久标成进行中）",
      judge.contains("stream.isStreaming"))
check("必须同时判 !stream.isDone（流收尾后 isStreaming/isDone 才是真状态）",
      judge.contains("!stream.isDone"))
check("空 id 不得误标（sid.isEmpty → nil）", judge.contains("sid.isEmpty"))

// ── 4. 性能口径：行内不许读每 token 都会变的内容 ────────────────
check("行内不得读 stream.content（每 token 变化 → 会话列表每 token 重算）",
      !viewCode.contains("stream.content"))

// ── 5. SessionRow：参数 + 分支顺序（多选编辑态优先） ────────────
let row = slice(viewCode, "struct SessionRow: View", "private struct RunningDot")
check("SessionRow 切片非空", !row.isEmpty)
check("SessionRow 有 running 参数（默认 false = 老调用点不受影响）", row.contains("var running = false"))
check("右列存在 running 分支（} else if running {）", row.contains("} else if running {"))
check("RunningDot() 在 running 分支里被用上", row.contains("RunningDot()"))

let checkIdx = row.range(of: "checkmark.circle.fill")?.lowerBound
let runningIdx = row.range(of: "} else if running {")?.lowerBound
// ⚠️ 不能用裸 "chevron.right" 当锚：头像图标表里那串 "chevron.left.forwardslash.chevron.right"
//    本身就含这个子串（会命中最前面那个假锚）。必须锚到真正的右列箭头。
let chevronIdx = row.range(of: "Image(systemName: \"chevron.right\")")?.lowerBound
check("多选勾选圈分支仍在（编辑模式不许被标识顶掉）", checkIdx != nil)
check("running 分支排在多选勾选**之后**（编辑态优先）",
      (checkIdx != nil && runningIdx != nil) && checkIdx! < runningIdx!)
check("chevron 只出现在 running 分支**之后**的兜底里（= 箭头被标识替换，不是并存）",
      (chevronIdx != nil && runningIdx != nil) && runningIdx! < chevronIdx!)

// ── 6. RunningDot：无障碍 + 动效口径 + 不引入实色底 ─────────────
let dot = slice(viewCode, "private struct RunningDot", "private struct SessionTagCapsules")
check("RunningDot 切片非空（元素真的在源码里）", !dot.isEmpty)
check("RunningDot 尊重「减弱动态效果」（accessibilityReduceMotion）", dot.contains("accessibilityReduceMotion"))
check("减速动效是**门控**而非仅声明（reduceMotion ? nil : …）", dot.contains("reduceMotion ? nil :"))
check("呼吸用 repeatForever(autoreverses:) 循环（与 SkeletonBlock 同口径）",
      dot.contains("repeatForever(autoreverses: true)"))
check("减速时静止常亮（opacity 取 1，不是 0）", dot.contains("reduceMotion ? 1 :"))
check("有无障碍标签（纯图形标识，VoiceOver 读不到就没有语义）", dot.contains("accessibilityLabel"))
check("RunningDot 不自行挂实色底（会话卡 F2 口径：卡上不得再压实色底）", !dot.contains(".background("))

// ── 7. 结果 ──────────────────────────────────────────────────
print("会话列表「进行中」标识真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
