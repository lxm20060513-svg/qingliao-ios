// 进度推送「按时间前后推」真值表（v3.9.76）
// 被测逻辑：qingliao/Core/InboxProgressOrder.swift（**生产代码**，非镜像）
// 事故背景：用户 2026-09-25 定规则——「这类进度回复（AI 正在回复（已生成 152 字，第 17 步 运行代码））
//           要按时间前后推，不要 20 步推在 17 步前」。
//           乱序唯一来源是投递层**僵尸重投**（后端 pop_pending 把 sending 超时的消息重置回 pending），
//           旧快照会落在更新的快照之后被注入。
// 用法：./check_swift.sh 第 18 步

import Foundation

var failures = 0
var total = 0

func check(_ name: String, _ expect: Bool, _ actual: Bool) {
    total += 1
    if expect == actual {
        print("✅ \(name)")
    } else {
        print("❌ \(name) — 期望 \(expect)，实际 \(actual)")
        failures += 1
    }
}

/// 去注释行（源码级断言的常规做法：注释里提到历史形态不算违规）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}

let s17 = InboxProgressOrder.Snapshot(step: 17, chars: 152)
let s20 = InboxProgressOrder.Snapshot(step: 20, chars: 300)
let s0 = InboxProgressOrder.Snapshot(step: 0, chars: 88)

// ── ① 解析：只认真正的进度文案，别的推送一律放过（不许误伤）──
check("标准文案 → (步数 17, 字数 152)",
      true,
      InboxProgressOrder.snapshot(from: "⏳ AI 正在回复（已生成 152 字，第 17 步 运行代码）\n\n…尾巴") == s17)
check("没有步数（工具还没跑过）→ step = 0",
      true,
      InboxProgressOrder.snapshot(from: "⏳ AI 正在回复（已生成 88 字）\n\n…x") == s0)
check("普通推送（每日早报）→ nil：本机制不许误伤别的推送",
      true,
      InboxProgressOrder.snapshot(from: "📋 每日早报：今天…") == nil)
check("像进度但没字数 → nil（格式变了宁可放过，不可误丢）",
      true,
      InboxProgressOrder.snapshot(from: "⏳ AI 正在回复") == nil)

// ── ② 单调判据：用户那条规则的正面 ──
check("第一条（没有基准）→ 接受", true,
      InboxProgressOrder.shouldAccept(s17, after: nil))
check("17 步 → 20 步：正常前进 → 接受", true,
      InboxProgressOrder.shouldAccept(s20, after: s17))
check("🚨 20 步 → 17 步：**丢弃**（用户报的原话场景）", true,
      !InboxProgressOrder.shouldAccept(s17, after: s20))
check("同步数、字数更多 → 接受（还在吐字）", true,
      InboxProgressOrder.shouldAccept(.init(step: 17, chars: 400), after: s17))
check("同步数、字数相同 → 丢弃（重复快照没意义）", true,
      !InboxProgressOrder.shouldAccept(s17, after: s17))
check("同步数、字数更少 → 丢弃（回退）", true,
      !InboxProgressOrder.shouldAccept(.init(step: 17, chars: 100), after: s17))
check("无步数快照晚到（0 步、字数很多）→ 丢弃（步数为主判据）", true,
      !InboxProgressOrder.shouldAccept(.init(step: 0, chars: 9999), after: .init(step: 3, chars: 100)))
check("无步数 → 无步数且字数更多 → 接受", true,
      InboxProgressOrder.shouldAccept(.init(step: 0, chars: 90), after: s0))

// ── ③ 基准新鲜度（App 重启后内存分组表为空，只能拿会话里最后一条进度气泡兜底）──
let nowMs: TimeInterval = 1_800_000_000_000
check("基准在窗口内（1 分钟前）→ 新鲜", true,
      InboxProgressOrder.isFresh(baselineMs: nowMs - 60_000, nowMs: nowMs))
check("基准超出窗口（16 分钟前）→ 不新鲜：上一条任务留下的旧气泡不能当基准", true,
      !InboxProgressOrder.isFresh(baselineMs: nowMs - 16 * 60 * 1000, nowMs: nowMs))
check("没有基准 → 不新鲜", true,
      !InboxProgressOrder.isFresh(baselineMs: nil, nowMs: nowMs))
check("基准在未来（时钟回拨）→ 不新鲜", true,
      !InboxProgressOrder.isFresh(baselineMs: nowMs + 60_000, nowMs: nowMs))

// ── ④ 接线护栏：闸门必须真的挂在注入之前，且丢弃也要 markDone ──
let inboxCode = stripCommentLines((try? String(contentsOfFile: "qingliao/Core/InboxStore.swift", encoding: .utf8)) ?? "")
check("v3.9.76·能读到 InboxStore 源码（路径别改）", true, !inboxCode.isEmpty)
check("v3.9.76·进度注入前必须过单调闸门", true,
      inboxCode.contains("InboxProgressOrder.shouldAccept(snap, after: baseline)"))
// ⚠️ 原来钉的是 `sourceTaskId ?? "unknown"` —— 那是**错的形态**（nil 时所有任务共用一个桶，
//   A 的 20 步之后 B 的第一条会被判迟到丢弃 + markDone，进度永久丢失）。现在钉「拿不到就不进桶」。
check("v3.9.76·分组键必须是 source_task_id，拿不到就整段放行（不落共用桶）", true,
      inboxCode.contains("sourceTaskId.flatMap { progressSnapshots[$0] }")
      && inboxCode.contains("if let key = sourceTaskId {")
      && !inboxCode.contains("sourceTaskId ?? \"unknown\""))
let discardBlock: String = {
    guard let s = inboxCode.range(of: "if !InboxProgressOrder.shouldAccept") else { return "" }
    let tail = String(inboxCode[s.lowerBound...])
    guard let e = tail.range(of: "return") else { return "" }
    return String(tail[..<e.upperBound])
}()
check("v3.9.76·能切到丢弃分支（切片失败 = 下一条断言白写）", true, !discardBlock.isEmpty)
check("v3.9.76·丢弃旧快照前必须 markDone（否则后端一直重投这条旧快照）", true,
      discardBlock.contains("markDone"))

print(failures == 0 ? "🎉 进度顺序真值表全部通过（\(total) 条）" : "❌ 进度顺序真值表失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
