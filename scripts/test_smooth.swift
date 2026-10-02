// 流式打字机「平滑释放」推进真值表（v4.0.23）
//
// 事故背景：v3.4.20 引入平滑层时推进写成「在 smoothedContent 自己的副本上切片」，
//   空串起步时 index(_:offsetBy:limitedBy:) 恒返回 nil → 落到 `?? s.endIndex` → 每 tick 都切出空串。
//   后果：smoothedContent 永远停在 ""，流式期间 displayContent 恒空（聊天页那口气泡从「思考三点」
//   被换成 streamingBubble 后**什么都没有** = 空气泡），只有收尾 stopSmooth 才一次性补齐全文。
//   2026-10-02 真机反馈：「工具调用一出来，思考气泡动画就会消失」——Agent 先有中间文本、
//   气泡早早切成空气泡，而工具阶段长达几十秒，空气泡特别显眼。
//
// 本表两条腿：
//   A. 算法行为（编译真源 Core/SmoothRelease.swift）：空起步必须前进 / 分级步长 / 单调收敛 / 不越界
//   B. 源码接线（读 StreamClient.swift）：推进必须走 SmoothRelease，且旧的自切片写法不得复活

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

@main
struct SmoothReleaseTruthTable {
    static func main() {
        runAll()
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }

    static func runAll() {
        // MARK: A. 算法行为

        // A1 核心回归：旧实现空起步恒 0（永远吐不出第一个字）→ 这里必须 >= 1
        check("A1 空起步第一 tick 必须吐字（旧实现恒 0 → 空气泡）",
              SmoothRelease.nextLength(smoothedCount: 0, contentCount: 51) >= 1)
        check("A2 只有 1 个字时一 tick 追平", SmoothRelease.nextLength(smoothedCount: 0, contentCount: 1) == 1)

        // A3-A5 分级步长（积压越大释放越快，追赶下游轮询增量）
        check("A3 积压 ≤20 → 1 字/tick",
              SmoothRelease.step(backlog: 1) == 1 && SmoothRelease.step(backlog: 20) == 1)
        check("A4 积压 21–60 → 2 字/tick",
              SmoothRelease.step(backlog: 21) == 2 && SmoothRelease.step(backlog: 60) == 2)
        check("A5 积压 >60 → 4 字/tick",
              SmoothRelease.step(backlog: 61) == 4 && SmoothRelease.step(backlog: 500) == 4)

        // A6-A7 整条流模拟：严格单调、不卡死、能在合理 tick 数内追平
        var n = 0, ticks = 0, monotonic = true, stuck = false
        while n < 51 && ticks < 500 {
            let next = SmoothRelease.nextLength(smoothedCount: n, contentCount: 51)
            if next < n { monotonic = false }
            if next == n { stuck = true; break }   // 原地不动 = 旧 bug 的形态
            n = next
            ticks += 1
        }
        check("A6 逐 tick 严格单调推进、无卡死（stuck = 旧 bug 形态）", monotonic && !stuck)
        check("A7 51 字 ≤60 tick 追平（48ms×60≈2.9s）", n == 51 && ticks <= 60)

        // A8-A10 边界
        check("A8 已追平时原样返回（不越界）", SmoothRelease.nextLength(smoothedCount: 51, contentCount: 51) == 51)
        check("A9 内容为空时返回 0", SmoothRelease.nextLength(smoothedCount: 0, contentCount: 0) == 0)
        check("A10 入参已超过内容长度时不倒退", SmoothRelease.nextLength(smoothedCount: 60, contentCount: 51) == 60)

        // MARK: B. 源码接线护栏（防回退）

        let path = "qingliao/Core/StreamClient.swift"
        let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check("B1 StreamClient.swift 可读（cwd 必须是仓根）", !src.isEmpty)
        check("B2 startSmooth 推进走 SmoothRelease.nextLength", src.contains("SmoothRelease.nextLength("))
        check("B3 旧写法「let s = self.smoothedContent」已清除", !src.contains("let s = self.smoothedContent"))
        check("B4 旧的自我切片 String(s[..<idx]) 已清除", !src.contains("String(s[..<idx])"))
    }
}
