// 「AI 记住瞬间」真值表 v4.0.120（第 2 项）
//
// 重点验证三条「错了就是用户丢记忆/连环弹泡」的：
//   ① 后端累积数组 memoAdded 在 0.15s 轮询下必须**只触发一次**（差集去重）
//   ② 复位必须与工具进度同生命周期（切会话/起新流后同一条属于该弹的新事件）
//   ③ 撤销后必须从本流列表摘干净，且不被后续轮询重弹
// 编译：swiftc -O truth_table_memo_added.swift -o tt_memo_added && ./tt_memo_added
import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("  ✅ \(name)" + (detail.isEmpty ? "" : "  ← \(detail)")) }
    else { fail += 1; print("  ❌ \(name)" + (detail.isEmpty ? "" : "  ← \(detail)")) }
}

// ─────── 与 Core/StreamClient.swift 的 memoAdded 逻辑同构（去掉 SwiftUI/Observation 依赖）───────
final class MemoAddedModel {
    private(set) var memoAdded: [String] = []
    private var memoDismissed: Set<String> = []

    /// 对应 StreamClient 轮询里的差集写入（两道闸门：差集 + 撤销屏蔽集）
    func poll(_ incoming: [String]) {
        guard !incoming.isEmpty else { return }
        let fresh = incoming.filter { !memoAdded.contains($0) && !memoDismissed.contains($0) }
        if !fresh.isEmpty { memoAdded.append(contentsOf: fresh) }
    }

    /// 对应 resetToolProgress()
    func reset() { memoAdded = []; memoDismissed = [] }

    /// 对应 forgetMemo()
    func forget(_ texts: [String]) {
        memoDismissed.formUnion(texts)
        memoAdded.removeAll { memoDismissed.contains($0) }
    }
}

// ─────── ① 累积数组 + 高频轮询 = 只触发一次 ───────
print("── ① 差集去重（后端累积数组 × 40 轮轮询）")
let m = MemoAddedModel()
var eventCount = 0
for _ in 0..<40 {
    let before = m.memoAdded.count
    m.poll(["我喜欢喝美式"])          // 后端每轮都重发同一条
    if m.memoAdded.count != before { eventCount += 1 }
}
check("40 轮轮询只产生 1 次事件", eventCount == 1, "实际 \(eventCount) 次")
check("最终只有 1 条", m.memoAdded == ["我喜欢喝美式"], "\(m.memoAdded)")

// 后端一次记多条
let m2 = MemoAddedModel()
m2.poll(["喜欢喝美式", "住杭州", "周五交周报"])
check("一次多条全部收录", m2.memoAdded.count == 3, "\(m2.memoAdded)")

// 第二条消息又记住一条 → 只并入增量
m2.poll(["喜欢喝美式", "住杭州", "周五交周报", "不吃香菜"])
check("增量只追加新的", m2.memoAdded == ["喜欢喝美式", "住杭州", "周五交周报", "不吃香菜"], "\(m2.memoAdded)")

// 老后端无此键 = 空数组 → 不动（优雅退化）
let m3 = MemoAddedModel()
m3.poll([])
check("老后端空数组不写入", m3.memoAdded.isEmpty)
m3.poll(["x"])
m3.poll([])
check("出现过一次后空轮不清空", m3.memoAdded == ["x"], "\(m3.memoAdded)")

// ─────── ② 复位与工具进度同生命周期 ───────
print("── ② 复位（切会话 / 起新流）")
let m4 = MemoAddedModel()
m4.poll(["喜欢喝美式"])
m4.reset()
check("resetToolProgress 清空", m4.memoAdded.isEmpty)
m4.poll(["喜欢喝美式"])
check("新流里同一条是新的事件（会再弹）", m4.memoAdded == ["喜欢喝美式"])

// ─────── ③ 撤销 = 真删 + 摘干净不重弹 ───────
print("── ③ 一键撤销")
let m5 = MemoAddedModel()
m5.poll(["喜欢喝美式", "住杭州"])
m5.forget(["喜欢喝美式"])
check("撤销后只剩未撤销那条", m5.memoAdded == ["住杭州"], "\(m5.memoAdded)")
// 关键：撤销后后端仍在下发累积数组（后端不感知撤销），必须不被重弹
var rePopped = 0
for _ in 0..<20 {
    let before = m5.memoAdded.count
    m5.poll(["喜欢喝美式", "住杭州"])   // 后端照旧重发已删那条
    if m5.memoAdded.count != before { rePopped += 1 }
}
check("撤销后不被后续轮询重弹", rePopped == 0, "重弹 \(rePopped) 次")

// 撤销不存在的条目不应误删别的
let m6 = MemoAddedModel()
m6.poll(["A", "B"])
m6.forget(["C"])
check("撤销不存在的条目=无副作用", m6.memoAdded == ["A", "B"], "\(m6.memoAdded)")
m6.forget(["A", "B"])
check("全部撤销后清空", m6.memoAdded.isEmpty)

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
