// MARK: - 长期目标卡片口径真值表（v4.0.46）
//
// 用户原话（2026-10-04）：*「app端长期目标卡片首页只显示当前进行中的步骤，
//   已完成的不用在卡片首页显示，不然卡片会被撑得很大」*
//
// 背景：v4.0.45 按「看得见已划掉的步骤 + 下一步」把最近 3 条已完成（划掉）+「…前面还有
//   N 步已完成」+「…还有 N 步」都排在卡片上 → 8/9 完成时卡片又被撑长。v4.0.46 收敛成
//   **只显示当前进行中的那一步**（= nextStep，带序号 + 状态标）；完成度由上方进度条
//   `doneCount/total` 表达；全量步骤清单（含已完成）只在详情页。
//
// 本表钉两件事：
//   ① 首页/列表卡（compact）分支只渲染一行「第k步 + 状态标」，不得出现已完成行/折叠计数
//   ② 详情页仍保留全量步骤清单（已完成照样划掉、带「第N步」）—— 不许「首页收敛」误伤详情页

import Foundation

var pass = 0, fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo: String = {
    if let e = ProcessInfo.processInfo.environment["QL_REPO"], !e.isEmpty { return e }
    // #filePath = <repo>/scripts/ql_*/truth_table_*.swift → 上溯三级到仓库根
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()
let path = repo + "/qingliao/Features/Life/GoalsSection.swift"
let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
if raw.isEmpty { print("❌ 读不到 \(path)"); exit(1) }

/// 去注释：注释里提到旧口径不算数
let src = raw.split(separator: "\n").map { line -> String in
    guard let r = line.range(of: "//") else { return String(line) }
    return String(line[line.startIndex..<r.lowerBound])
}.joined(separator: "\n")

func count(_ needle: String) -> Int {
    src.components(separatedBy: needle).count - 1
}

/// 数子串（限定在一段文本内）
func count(in hay: String, _ needle: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}

print("── ① 首页/列表卡（compact）：只显示进行中那一步 ──")
ok(src.contains("if compact, !goal.isFinished, let s = goal.nextStep"),
   "compact 分支只取 nextStep（进行中那一步）")
ok(src.contains("第\\(goal.doneCount + 1)步 \\(s.title)"),
   "进行中步骤带序号「第k步」（与详情页同口径）")
ok(src.contains("nextStepStatusMark(goal, s)"),
   "进行中步骤仍带状态标（进行中 / 预计 X 开始）")

// 旧口径的四个痕迹必须消失（回退即红）
ok(count("cardShownDoneSteps") == 0, "不再有 cardShownDoneSteps（列最近 3 条已完成）")
ok(count("cardHiddenDoneCount") == 0, "不再有 cardHiddenDoneCount")
ok(count("cardRestStepCount") == 0, "不再有 cardRestStepCount")
ok(!src.contains("…前面还有"), "不再出「…前面还有 N 步已完成」")
ok(!src.contains("…还有 "), "不再出「…还有 N 步」折叠行")

// 卡片区段内不许有已完成行（划掉 / 对勾 / ForEach 批量渲染）
if let a = src.range(of: "if compact, !goal.isFinished, let s = goal.nextStep"),
   let b = src.range(of: "if let s = goal.nextStep, !compact") {
    let card = String(src[a.lowerBound..<b.lowerBound])
    ok(!card.contains("checkmark"), "卡片区段无对勾图标（已完成不在卡片上）")
    ok(!card.contains("strikethrough"), "卡片区段无划掉样式")
    ok(!card.contains("ForEach"), "卡片区段无批量渲染（只一行进行中步骤）")
    ok(count(in: card, "Image(systemName:") == 1, "卡片区段只有 1 个图标（进行中圆圈）")
} else {
    ok(false, "找不到卡片区段边界（compact 块或详情页块被改名 → 需同步本表）")
}

print("── ② 详情页：全量步骤清单不许被误伤 ──")
ok(src.contains("ForEach(Array(g.steps.enumerated()), id: \\.element.id)"),
   "详情页仍遍历全部步骤（enumerated，身份稳定）")
ok(count("checkmark.circle.fill") >= 1, "详情页已完成步骤仍打勾")
ok(src.contains(".strikethrough(s.done)"), "详情页已完成步骤仍划掉")
ok(src.contains("Text(\"第\\(idx + 1)步\")"), "详情页步骤仍带「第N步」序号")

print("\n通过 \(pass) 项，失败 \(fail) 项")
exit(fail == 0 ? 0 : 1)
