// MARK: - v4.0.x 流式轮次代次（开跑 startSeq / 收尾 finishSeq）· 真值表（源护栏）
//
// 病根：`isStreaming` 的 false→true 边沿**会被同帧变化吞掉**——finish() 里 isStreaming=false 后
// 同步回调 onFinished，排队续发（sendQueued → start()）在同一帧把它设回 true →
// SwiftUI 的 onChange 看到 old/new 都是 true，整轮边沿被静默跳过。
//
// 症状两处（都是既存缺陷，v4.0.x 一并清掉；仓内 finishSeq 的注释早就写了这个机理，
// 但同一文件下面的观察点没照它改）：
//   ① DockTabView：上一轮失败 + 排队自动续发 → 球的失败态清不掉，在整轮新回答期间一直压暗；
//   ② ChatView：上一轮手动展开的工具卡被带进新一轮。
//
// 定案：仿已有的 `finishSeq`（v3.9.33 就是这么修的）加对称的只增 `startSeq`；
//      三个开跑入口（start / restoreIfNeeded / adoptRemote）都要自增，漏一处就漏一条边沿。
//
// 用法：./check_swift.sh 第 47 步

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
/// 去注释行：源码注释里提到历史形态（「原来观察 isStreaming」）不算违规
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}

let streamSrc   = src("Core/StreamClient.swift")
let dockSrc     = src("Features/DockTabView.swift")
let chatViewSrc = src("Features/Chat/ChatView.swift")

// ── ① 源护栏：非空（路径别改，改了下面全是假绿）──────────────────────
check("v4.0.x·能读到 StreamClient.swift 源码", !streamSrc.isEmpty)
check("v4.0.x·能读到 DockTabView.swift 源码", !dockSrc.isEmpty)
check("v4.0.x·能读到 ChatView.swift 源码", !chatViewSrc.isEmpty)

let streamCode = stripComments(streamSrc)
let dockCode   = stripComments(dockSrc)
let chatCode   = stripComments(chatViewSrc)

/// 取 `marker` 到**下一个** `.onChange(` 之间的切片——窄窗口够用且不会被后面新加的同名观察点污染
func sliceToNextOnChange(_ s: String, from marker: String) -> String {
    guard let a = s.range(of: marker) else { return "" }
    let tail = s[a.upperBound...]
    if let b = tail.range(of: ".onChange(of:") { return String(tail[..<b.lowerBound]) }
    return String(tail.prefix(800))
}

// ── ② 代次字段本身：只增、外部不许写、两半都在 ──────────────────────
check("v4.0.x·startSeq 是只增的 private(set)（外部不许写，否则 UI 端可被绕开）",
      streamCode.contains("private(set) var startSeq = 0"))
check("v4.0.x·收尾侧 finishSeq 仍在（这套机制的两半，只留一半等于没修）",
      streamCode.contains("private(set) var finishSeq = 0")
      && streamCode.contains("finishSeq += 1"))

// ── ③ 三个开跑入口都要自增（漏一处就漏一条边沿）────────────────────
let incCount = streamCode.components(separatedBy: "startSeq += 1").count - 1
check("v4.0.x·开跑自增至少 3 处（start / restoreIfNeeded / adoptRemote）——实得 \(incCount)",
      incCount >= 3)
check("v4.0.x·isStreaming 收口 private(set)（开写权限 = 跨文件新增开跑点能绕过本表，编译期查不出）",
      streamCode.contains("private(set) var isStreaming = false"))
var nearCount = 0
var rest = streamCode[...]
while let r = rest.range(of: "isStreaming = true") {
    if rest[r.upperBound...].prefix(120).contains("startSeq += 1") { nearCount += 1 }
    rest = rest[r.upperBound...]
}
check("v4.0.x·开跑自增数与 isStreaming = true 处数一致（实得 \(nearCount)/\(incCount)；有一处漏配就说明边沿会被漏掉）",
      nearCount == incCount)

// ── ④ 观察端：两处 UI 都改看序号 ────────────────────────────────────
check("v4.0.x·DockTabView 球失败态观察 startSeq（观察 isStreaming 会被同帧续发吞边沿 → 球整轮压暗）",
      dockCode.contains(".onChange(of: stream.startSeq)")
      && dockCode.contains("orbFailed = false"))
check("v4.0.x·ChatView 工具卡收起观察 startSeq（否则上一轮展开态带进新一轮）",
      chatCode.contains(".onChange(of: stream.startSeq)")
      && chatCode.contains("toolStepsExpanded = false"))
check("v4.0.x·两处都不再观察 isStreaming（反向断言：回退即红）",
      !dockCode.contains(".onChange(of: stream.isStreaming)")
      && !chatCode.contains(".onChange(of: stream.isStreaming)"))

// ── ⑤ 原有交互口径没被顺手改坏 ──────────────────────────────────────
check("v4.0.x·工具卡收起仍带会话归属判定（A 起流不该收 B 里手动展开的卡）",
      chatCode.contains("if thisSessionStreaming { toolStepsExpanded = false }"))
let orbStartWin = dockCode.range(of: ".onChange(of: stream.startSeq)")
    .map { String(dockCode[$0.upperBound...].prefix(160)) } ?? ""
check("v4.0.x·球失败态观察闭包只清 orbFailed，不动 orbUnseen（「未查看」要保留：排队续发不该吞掉它）",
      orbStartWin.contains("orbFailed = false") && !orbStartWin.contains("orbUnseen = false"))

// ── ⑥ 两条同帧顺序依赖（v4.0.x 只读审查回流，必修）──────────────────
// 坑：`finishSeq` 与 `startSeq` 可能落在同一次视图更新里（开跑即失败 / 失败后同帧续发），
//     两个闭包都跑，最终 orbFailed 取决于派发顺序 → 判据必须看 isStreaming 的**最终值**。
let finishWin = sliceToNextOnChange(dockCode, from: ".onChange(of: stream.finishSeq)")
check("v4.0.x·收尾观察端判据顺序无关（`lastFinishFailed, !stream.isStreaming`；只看 lastFinishFailed 会随派发顺序飘）",
      finishWin.contains("stream.lastFinishFailed, !stream.isStreaming"))
// 坑：`suppressAutoReadOnce` 复位是**开跑语义**，挂在 aiBusy 闭包里会被同帧续发吞掉
//     （v3.9.9 想修的病换了条路径复现）。
let busyWin = sliceToNextOnChange(chatCode, from: ".onChange(of: aiBusy")
check("v4.0.x·suppressAutoReadOnce 复位已离开 aiBusy 闭包（那条边沿会被同帧续发吞掉）",
      !busyWin.isEmpty && !busyWin.contains("suppressAutoReadOnce = false"))
let chatSeqWin = sliceToNextOnChange(chatCode, from: ".onChange(of: stream.startSeq)")
check("v4.0.x·抑制标记复位与工具卡收起合并在同一处 startSeq 观察（同一闭包窗口内，只增一个修饰符就超类型检查阈值）",
      chatSeqWin.contains("suppressAutoReadOnce = false") && chatSeqWin.contains("toolStepsExpanded = false"))
check("v4.0.x·ChatView 的 startSeq 观察恰 1 处——这条 body 链贴着类型检查阈值，多挂一个带闭包的成员 Archive 即挂（CI #608 实测）",
      chatCode.components(separatedBy: ".onChange(of: stream.startSeq)").count - 1 == 1)

print("流式轮次代次真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
