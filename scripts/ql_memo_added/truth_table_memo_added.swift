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

// ─────── ④ 源级接线断言（模型全绿但源码没接 = 功能 100% 不 work）───────
// 镜像模型证明不了「ChatView 真的挂了这条 bar」「撤销真的调了 delete」。
// 2026-10-04 取证发现：本项功能早在 v4.0.120 就落地了，但护栏只覆盖镜像模型 ——
// 源码里删掉挂载点/换成别的端点，表照样全绿。下列断言把接线钉死。
print("── ④ 源级接线（读 App 源码）")

let repoRoot = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath
func src(_ rel: String) -> String {
    let p = rel.hasPrefix("/") ? rel : "\(repoRoot)/\(rel)"
    return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
}
func sc(_ name: String, _ cond: Bool, _ detail: String = "") {
    check(name, cond, detail)
}
func slice(_ s: String, _ from: String, _ to: String) -> String {
    guard let a = s.range(of: from)?.lowerBound else { return "" }
    guard let b = s.range(of: to, range: a..<s.endIndex)?.lowerBound else { return String(s[a...]) }
    return String(s[a..<b])
}
// 写成字面量相对路径（不拼变量）：check_guard_coverage.py 的 SRC_RE 靠这个形态
// 校验「引用的源文件真的存在」，拼变量的写法会被它当成没读源码而漏掉断链检查。
let chatView = src("qingliao/Features/Chat/ChatView.swift")
let streamClient = src("qingliao/Core/StreamClient.swift")
let authStore = src("qingliao/Core/AuthStore.swift")
let memoBar = src("qingliao/Features/Chat/ChatMemoBar.swift")
sc("C0 五个源文件都读到（路径没断）",
   !chatView.isEmpty && !streamClient.isEmpty && !authStore.isEmpty && !memoBar.isEmpty)

// C1 提示条真的挂在输入栏上方那个槽位里
sc("C1 bar 挂在 chatRecordBarSlot", chatView.contains("} else if !stream.memoAdded.isEmpty {"))
sc("C1 bar 用 ChatMemoBar 渲染", chatView.contains("ChatMemoBar(texts: stream.memoAdded"))
sc("C1 ChatMemoBar.swift 存在", !memoBar.isEmpty)

// C2 判据只读 stream.memoAdded（不另挂 .onChange —— 那条链贴着类型检查阈值）
let slot = slice(chatView, "private var chatRecordBarSlot", "// MARK: - v3.7.0")
sc("C2 判据读 stream.memoAdded", slot.contains("stream.memoAdded.isEmpty"))

// C3 撤销 = 真删 /api/memory/delete（不是本地隐藏）
let undoBody = slice(chatView, "private func undoMemo", "private func flashRecordDedup")
sc("C3 撤销调 memory/delete", undoBody.contains("/api/memory/delete"))
sc("C3 撤销逐条删", undoBody.contains("for t in texts"))
// v3.9.41 同款教训：try? 吞错 → 记忆「看着删了」重开又回来
sc("C3 撤销判 ok 字段", undoBody.contains("(j[\"ok\"] as? Bool) == true"))
sc("C3 删除失败震动可见（不假装成功）", undoBody.contains("Haptics.error()"))
// 部分失败时已删的那几条必须先摘掉，否则再点撤销永远停在同一条失败
sc("C3 部分失败先摘已删条目", undoBody.contains("stream.forgetMemo(deleted)"))

// C4 撤销成功后从本流摘掉（防「删了又弹」）
sc("C4 撤销成功调 forgetMemo", undoBody.contains("stream.forgetMemo(texts)"))
sc("C4 关闭钮也走 forgetMemo", slot.contains("stream.forgetMemo(stream.memoAdded)"))
sc("C4 forgetMemo 是唯一写入口", streamClient.contains("func forgetMemo(_ texts: [String])"))

// C5 两道闸门都在源码里（差集 + 撤销屏蔽集）
sc("C5 差集闸门", streamClient.contains("!memoAdded.contains($0)"))
sc("C5 撤销屏蔽集闸门", streamClient.contains("!memoDismissed.contains($0)"))

// C6 复位与工具进度同生命周期（切会话/新流后同一条是新事件）
let resetBody = slice(streamClient, "func resetToolProgress()", "/// v3.9.58：工具步骤耗时")
sc("C6 resetToolProgress 清 memoAdded", resetBody.contains("memoAdded = []"))
sc("C6 resetToolProgress 清 memoDismissed", resetBody.contains("memoDismissed = []"))

// C7 后端键解包（老后端无此键 = 空数组 → 不弹）
sc("C7 AuthStore 解 memoAdded", authStore.contains("j[\"memoAdded\"] as? [String]"))
sc("C7 回落空数组", authStore.contains("as? [String] ?? []"))

// C8 12 秒自动收尾挂在 bar 自己的 .task 里（不占宿主修饰符链）
sc("C8 bar 自带 task 定时收尾", memoBar.contains(".task(id: texts)"))
sc("C8 定时 12 秒", memoBar.contains("12_000_000_000"))

// C9 与长期目标卡不重叠：同一槽位是 if/else if 互斥（一次只弹一条）
sc("C9 槽位互斥（记账条/去重条/记忆条 三选一）",
   chatView.contains("} else if recordDedupNotice {") && slot.contains("} else if !stream.memoAdded.isEmpty {"))

// C10 胶囊/卡片走统一 token（不自造）
sc("C10 撤销胶囊走 topBar 口径", memoBar.contains("Text(\"撤销\").pill(.topBar, tone: .danger)"))
sc("C10 卡片走 dashboardCard", memoBar.contains(".dashboardCard()"))

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
