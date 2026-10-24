// v4.0.154 上下文压缩「按体量」真值表 —— Linux 本地预检用，纯 Foundation
// （编译真源 qingliao/Core/ContextBudget.swift，不是镜像 → 没有表/实现漂移的洞）
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 新增段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_contextbudget \
//       scripts/ql_contextbudget/truth_table_contextbudget.swift qingliao/Core/ContextBudget.swift
//
// 事故（2026-10-24 用户实报「手动压缩上下文失效」）：
//   旧口径写死「保留最近 20 条」→ 用户那个会话恰好 20 条、其中一条 AI 回复 13 万字，
//   ① 条数不满足 `count > keepLast + 1`，压缩静默返回 false（点了没反应）；
//   ② 即便压了，条数达标 ≠ 体量下降。条数是「消息个头均匀」时代的代理指标，必须换成字符预算。
//
// 断言分两类：
//   1）算法本体（真源编译）：预算内全保留 / 超预算从最新往回截 / 至少保 minKeep / 边界
//   2）反证：同一组入参数按「旧条数口径」算出来的保留数必须与本实现不同
//      —— 说明这条表真的钉住了新旧差异，不是恒真护栏

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool, negative: Bool = false) {
    print("\(cond ? "✅" : "❌") \(name)")
    if negative { negatives += 1 } else { positives += 1 }
    if !cond { failures += 1 }
}

@main
struct ContextBudgetTruthTable {

    static func main() {
        // ── 1. 算法本体 ─────────────────────────────────────────────
        print("── 1. ContextBudget.keepCount ──")

        check("空数组 → 0", ContextBudget.keepCount(charCounts: [], budget: 10_000) == 0)

        check("单条 → 1（预算再小也留这一条）",
              ContextBudget.keepCount(charCounts: [50_000], budget: 100) == 1)

        check("全部在预算内 → 全保留（不做无意义的压缩）",
              ContextBudget.keepCount(charCounts: [100, 200, 300], budget: 10_000) == 3)

        check("预算刚好等于总量 → 全保留",
              ContextBudget.keepCount(charCounts: [4_000, 6_000], budget: 10_000) == 2)

        // 从最新往回累计：300+200 = 500，再加 1000 超 800 → 只保留最后两条
        check("超预算从最新往回截（保留够预算的那几条）",
              ContextBudget.keepCount(charCounts: [1_000, 200, 300], budget: 800) == 2)

        // minKeep 下限：最后一条就超预算，也必须再往前多保一条
        check("最后一条本身超预算 → 仍保 minKeep 条",
              ContextBudget.keepCount(charCounts: [10, 20, 50_000], budget: 1_000) == 2)

        check("budget = 0 → 只保 minKeep",
              ContextBudget.keepCount(charCounts: [1, 2, 3, 4, 5], budget: 0) == 2)

        check("minKeep 大于总数 → 不会越界",
              ContextBudget.keepCount(charCounts: [1, 2], budget: 0, minKeep: 10) == 2)

        check("负数/脏字符数按 0 处理（不 panic、不误判超预算）",
              ContextBudget.keepCount(charCounts: [-5, -1, 100], budget: 100) == 3)

        // 用户真实会话（2026-10-24，NAS sessions.json「车机开发与副驾投屏设计」）：
        // 20 条共 142,576 字符，其中第 13 条单条 132,904 —— 按 1 万字预算从最新往回：
        // 699 + 3 + 613 + 13 + 843 + 21 = 2,192，再加 132,904 超预算 → 停止 ⇒ 保留 6 条。
        let realSession = [33, 2_268, 165, 3_062, 27, 1_002, 40, 146, 148, 151, 147, 146, 145,
                           132_904, 21, 843, 13, 613, 3, 699]
        let realKeep = ContextBudget.keepCount(charCounts: realSession,
                                               budget: ContextBudget.defaultCharacterBudget)
        check("真实会话：20 条 / 14.3 万字 → 按 1 万字预算保留 6 条（不再被条数口径挡在门外）",
              realKeep == 6)

        // 反证：旧「保留最近 20 条」口径对这个会话会算出 20（= 一条都不压）
        check("反证：旧条数口径（keepLast=20）对这个会话保留 20 条 → 与按体量结果相异",
              Swift.min(20, realSession.count) != realKeep, negative: true)

        // 反证：按条数上限 5 条的结果也 ≠ 按预算结果（口径确实不同，不是恒真）
        check("反证：按条数上限 5 条的结果 ≠ 按预算结果（口径确实不同）",
              Swift.min(5, realSession.count) != realKeep, negative: true)

        // 反证（另一个真实会话「AVATR车机应用优化」：44 条 / 1.34 万字，消息个头均匀）：
        // 按体量应**全留 44 条**（没超 1 万字预算，不该无谓压缩），旧条数口径只肯留 20。
        let uniformSession = Array(repeating: 300, count: 44)   // 13,200 字符 > 1 万，会被压
        let uniformShort = Array(repeating: 200, count: 44)     // 8,800 字符 < 1 万，应全留
        check("反证：均匀短消息会话——按体量全留 44 条，旧条数口径只留 20 条（两者必然不同）",
              ContextBudget.keepCount(charCounts: uniformShort, budget: 10_000) == 44
                && Swift.min(20, uniformShort.count) == 20,
              negative: true)
        check("反证：均匀会话略微超预算时按体量压到 ≤ 44 且 > 20（旧口径一定取 20）",
              ContextBudget.keepCount(charCounts: uniformSession, budget: 10_000) != Swift.min(20, 44),
              negative: true)

        // ── 2. 结果 ────────────────────────────────────────────────
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 0.25)

        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
    }
}
