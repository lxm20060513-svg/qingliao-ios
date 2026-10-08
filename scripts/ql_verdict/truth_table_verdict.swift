// P1 首屏结论条（VerdictBar）真值表 —— Linux 本地预检用
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 92 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_verdict \
//       scripts/ql_verdict/truth_table_verdict.swift qingliao/Core/WorkbenchVerdict.swift
//
// 为什么需要这张表（这四类问题编译不报、真机才炸，而且**只有肉眼**看得见）：
//   ① **不许显示 0、也不许显示 `--`**：这是清单里的硬口径。界面上多一个「0」不会报错，
//      但会让人觉得「这东西没在干活」；少一个判断就会在断网/冷启动时露出 `--`。
//   ② **「昨夜」是跨天窗口**：昨天 20:00 → 今天 09:00，且现在还没到 09:00 时右端必须收到「现在」
//      —— 否则会把「未来」统计进来（比显示 0 更糟：数字是假的）。
//   ③ **断网只降级一槽**：本地两项（待你处理 / 今日步）绝不能因为网络失败而消失，
//      否则用户断网时看到整条空白，以为功能没了。
//   ④ **唯一真源 / 唯一读口**：三个槽位的文案只在 `WorkbenchVerdict` 里写一次；
//      `/api/agent/tasks/night` 这个读口全 App 只能出现一处；结论条只能挂在工作模式壳里
//      （生活模式那份代码不许知道它存在）。
//
// 口径：断言只看**代码**（`code()` 先剥掉整行注释）——注释里为了讲清道理举的例子字面量
// 不该被当成违规；反过来，代码里真出现就是真违规。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0
func check(_ name: String, _ cond: Bool) {
    total += 1
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉**整行注释**后的源码
func code(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 仓库内所有 .swift（相对路径），用于「唯一引用点 / 唯一读口」这类全仓断言
func swiftFiles() -> [String] {
    var out: [String] = []
    let root = "qingliao"
    guard let en = FileManager.default.enumerator(atPath: root) else { return out }
    for case let p as String in en where p.hasSuffix(".swift") {
        out.append("\(root)/\(p)")
    }
    return out.sorted()
}

// ⚠️ main.swift 里的顶层全局默认是 @MainActor 孤立的，nonisolated 的辅助函数碰不到它们
//（Swift 6 会直接报「main actor-isolated var can not be referenced from a nonisolated context」）。
// 所以时区/日历一律用**函数返回**，不靠可变全局。
func shanghaiCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return c
}

func date(_ s: String, _ cal: Calendar) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
}

let cal = shanghaiCalendar()

typealias V = WorkbenchVerdict
typealias C = WorkbenchVerdict.Counts

let zero = C(pending: 0, todaySteps: 0, nightTotal: 0, nightFailed: 0)

print("=== A. 三个槽位：数量、顺序、名字都是钉死的 ===")
check("A1 恰好 3 个槽位", V.Slot.allCases.count == 3)
check("A2 顺序 = 待你处理 · 目标今日步 · 昨夜任务",
      V.Slot.allCases.map { $0.label } == ["待你处理", "目标今日步", "昨夜任务"])
check("A3 槽位 rawValue 稳定（下钻/埋点按它对齐）",
      V.Slot.allCases.map { $0.rawValue } == ["pending", "todaySteps", "night"])

print("=== B. 加载中：不给数字、不闪 0 ===")
check("B1 .loading 不给任何格子", V.chips(.loading).isEmpty)
check("B2 .loading 给一句人话", V.hint(.loading) == V.loadingHint)
check("B3 .loading 不给动作按钮（没什么可点的）", V.actionTitle(.loading) == nil)
check("B4 .loading 不算空态、也不算断网", !V.isEmpty(.loading) && !V.isOffline(.loading))

print("=== C. 空态（三槽都空）：一句引导 + 一个动作按钮 ===")
let emptyReady = V.State.ready(zero)
check("C1 三槽都空 → 认得出是空态", V.isEmpty(emptyReady))
check("C2 空态三格全是人话（都清了/还没推进/无任务）",
      V.chips(emptyReady).map { $0.value } == [V.emptyPending, V.emptySteps, V.emptyNight])
check("C3 空态三格都不是数字", V.chips(emptyReady).allSatisfy { !$0.hasNumber })
check("C4 空态无人话之外的提醒", V.chips(emptyReady).allSatisfy { !$0.warn })
check("C5 空态文案 = 今天还没有要处理的事", V.hint(emptyReady) == V.emptyHint)
check("C6 空态动作 = 说一句话就能开始", V.actionTitle(emptyReady) == V.startAction)

print("=== D. 铁律：永远不出现「0」，也不出现「--」 ===")
var matrix: [V.State] = []
for pending in [0, 1, 3] {
    for steps in [0, 2] {
        for night in [nil, 0, 4] as [Int?] {
            for failed in [0, 1] {
                let c = C(pending: pending, todaySteps: steps, nightTotal: night, nightFailed: failed)
                matrix.append(.ready(c))
                matrix.append(.offline(c))
            }
        }
    }
}
let allValues = matrix.flatMap { V.chips($0) }.map { $0.value }
check("D1 矩阵覆盖 ≥ 24 个状态（正例足够密）", matrix.count >= 24)
check("D2 任何状态都不会出现裸「0」", !allValues.contains("0"))
check("D3 任何状态都不会出现「--」", !allValues.contains("--") && !allValues.contains("—"))
let humanWords: Set<String> = [V.emptyPending, V.emptySteps, V.emptyNight, "读不到"]
check("D4 没数字的格子一律是人话（不许是空白/怪符号）",
      matrix.flatMap { V.chips($0) }.filter { !$0.hasNumber }.allSatisfy { humanWords.contains($0.value) })
check("D5 每格都有槽位标签（界面上不会出现只值无名的格子）",
      matrix.flatMap { V.chips($0) }.allSatisfy { !$0.slot.label.isEmpty })

print("=== E. 有数字时：数字口径 ===")
let busy = V.State.ready(C(pending: 3, todaySteps: 2, nightTotal: 5, nightFailed: 0))
check("E1 待你处理 3 → 显 3（是数字）", V.chips(busy)[0].value == "3" && V.chips(busy)[0].hasNumber)
check("E2 今日步 2 → 显 2（是数字）", V.chips(busy)[1].value == "2" && V.chips(busy)[1].hasNumber)
check("E3 昨夜 5 / 失败 0 → 显 5（无失败就不写失败）", V.chips(busy)[2].value == "5")
check("E4 昨夜 5 / 失败 0 → 不报警", !V.chips(busy)[2].warn)
check("E5 三槽都在报数时不给多余那句话", V.hint(busy) == nil)
check("E6 有数就不给「说一句话就能开始」", V.actionTitle(busy) == nil)
check("E7 有数就不算空态", !V.isEmpty(busy))

let withFail = V.State.ready(C(pending: 0, todaySteps: 1, nightTotal: 5, nightFailed: 2))
check("E8 昨夜 5 / 失败 2 → 一并报出失败数", V.chips(withFail)[2].value == "5 · 失败 2")
check("E9 有失败 → 该格报警（要显眼）", V.chips(withFail)[2].warn)
check("E10 单个槽为 0 不影响其它槽报数",
      V.chips(withFail)[0].value == V.emptyPending && V.chips(withFail)[1].value == "1")

print("=== F. 断网：只降级「昨夜任务」一槽 ===")
let offlineBusy = V.State.offline(C(pending: 2, todaySteps: 1))
let oc = V.chips(offlineBusy)
check("F1 断网时本地「待你处理」照旧报数", oc[0].value == "2" && oc[0].hasNumber)
check("F2 断网时本地「今日步」照旧报数", oc[1].value == "1" && oc[1].hasNumber)
check("F3 断网时只「昨夜任务」降级成人话", oc[2].value == "读不到" && !oc[2].hasNumber)
check("F4 降级那一格要显眼（用户得知道是没拿到，不是没有）", oc[2].warn)
check("F5 断网 + 本地有事 → 说明白了哪一项读不到", V.hint(offlineBusy) == V.offlineHint)
check("F6 断网 + 本地有事 → 给「重试」", V.actionTitle(offlineBusy) == V.retryAction)
check("F7 断网不认成空态（别拿网络问题当「没事做」）", !V.isEmpty(offlineBusy))
let offlineIdle = V.State.offline(C(pending: 0, todaySteps: 0))
check("F8 断网 + 本地也空 → 先给引导，不吓唬用户", V.hint(offlineIdle) == V.emptyHint)
check("F9 断网 + 本地也空 → 给「说一句话就能开始」", V.actionTitle(offlineIdle) == V.startAction)

print("=== G. 下钻：每个数字都点得进去 ===")
check("G1 待你处理 → 任务中心", V.drill(.pending) == .pendingList)
check("G2 今日步 → 今日推进", V.drill(.todaySteps) == .todayStepList)
check("G3 昨夜任务 → 昨夜明细", V.drill(.night) == .nightList)
check("G4 下钻目标有标题（卡片/页面不会空白）",
      [V.Drill.pendingList, .todayStepList, .nightList].allSatisfy { !$0.title.isEmpty })

print("=== H. 「昨夜」窗口：跨天、且不许统计到未来 ===")
let w10 = V.nightWindow(now: date("2026-10-08 10:00:00", cal), calendar: cal)
check("H1 今天 10:00 → 起点=昨天 20:00",
      abs(w10.start.timeIntervalSince(date("2026-10-07 20:00:00", cal))) < 1)
check("H2 今天 10:00 → 终点=今天 09:00",
      abs(w10.end.timeIntervalSince(date("2026-10-08 09:00:00", cal))) < 1)
check("H3 窗口长度 13 小时", abs(w10.end.timeIntervalSince(w10.start) - 13 * 3600) < 1)
let w8 = V.nightWindow(now: date("2026-10-08 08:00:00", cal), calendar: cal)
check("H4 现在还没到 09:00 → 右端收到「现在」（不统计未来）",
      abs(w8.end.timeIntervalSince(date("2026-10-08 08:00:00", cal))) < 1)
check("H5 早上窗口仍然是「昨天 20:00 起」",
      abs(w8.start.timeIntervalSince(date("2026-10-07 20:00:00", cal))) < 1)
let w19 = V.nightWindow(now: date("2026-10-08 19:00:00", cal), calendar: cal)
check("H6 今天 19:00 看「昨夜」仍是 昨天 20:00→今天 09:00（不是从现在倒推）",
      w19.end < date("2026-10-08 19:00:00", cal) && abs(w19.end.timeIntervalSince(date("2026-10-08 09:00:00", cal))) < 1)
let now10 = date("2026-10-08 10:00:00", cal)
check("H7 边界：昨天 19:59:59 不算昨夜",
      !V.inNightWindow(date("2026-10-07 19:59:59", cal), now: now10, calendar: cal))
check("H8 边界：昨天 20:00:00 算昨夜（左闭）",
      V.inNightWindow(date("2026-10-07 20:00:00", cal), now: now10, calendar: cal))
check("H9 边界：今天 09:00:00 算昨夜（右闭）",
      V.inNightWindow(date("2026-10-08 09:00:00", cal), now: now10, calendar: cal))
check("H10 边界：今天 09:00:01 不算昨夜",
      !V.inNightWindow(date("2026-10-08 09:00:01", cal), now: now10, calendar: cal))
check("H11 昨天 23:00 属于「昨夜」",
      V.inNightWindow(date("2026-10-07 23:00:00", cal), now: now10, calendar: cal))
check("H12 今天 03:00 属于「昨夜」",
      V.inNightWindow(date("2026-10-08 03:00:00", cal), now: now10, calendar: cal))

print("=== I. 「今天」判定（今日步口径）===")
check("I1 今天 00:00 算今天", V.isToday(date("2026-10-08 00:00:00", cal), now: now10, calendar: cal))
check("I2 昨天 23:59 不算今天", !V.isToday(date("2026-10-07 23:59:00", cal), now: now10, calendar: cal))
check("I3 明天不算今天", !V.isToday(date("2026-10-09 00:01:00", cal), now: now10, calendar: cal))

print("=== J. 后端只读聚合口的解析（脏数据一律不猜）===")
check("J1 ok=false → 读不到（nil）", V.parseNight(["ok": false, "night": ["total": 3]]) == nil)
check("J2 没有 ok → 读不到", V.parseNight(["night": ["total": 3]]) == nil)
check("J3 没有 night → 读不到", V.parseNight(["ok": true]) == nil)
check("J4 night 里没有 total → 读不到（不许猜成 0）", V.parseNight(["ok": true, "night": ["failed": 1]]) == nil)
let okPayload: [String: Any] = [
    "ok": true,
    "night": [
        "total": 3,
        "failed": 1,
        "items": [
            ["id": "a", "title": "目标推进 · 工作台改造", "status": "done", "at": 1791400000.0],
            ["id": "b", "title": "早间简报", "status": "error", "at": 1791410000.0],
            ["title": "缺 id 也能进（id 会兜底）", "status": "done", "at": 1791405000.0],
        ],
    ],
]
if let parsed = V.parseNight(okPayload) {
    check("J5 正常载荷：total / failed 如实取出", parsed.total == 3 && parsed.failed == 1)
    check("J6 明细条数正确", parsed.items.count == 3)
    check("J7 明细按时间倒序（最新的在最上面）",
          parsed.items.map { $0.at } == parsed.items.map { $0.at }.sorted(by: >))
    check("J8 status=error 标成失败", parsed.items.first(where: { $0.title == "早间简报" })?.failed == true)
    check("J9 status=done 不标失败",
          parsed.items.first(where: { $0.title == "目标推进 · 工作台改造" })?.failed == false)
    check("J10 缺 id 时兜底一个非空 id（List 不会因为重复/空 id 炸）",
          parsed.items.allSatisfy { !$0.id.isEmpty })
} else {
    check("J5-J10 正常载荷应能解析", false)
}
let dirtyPayload: [String: Any] = [
    "ok": true,
    "night": [
        "total": 2, "failed": 0,
        "items": [
            ["id": "x", "title": "", "status": "done", "at": 1791400000.0],
            ["id": "y", "status": "done", "at": 1791400001.0],
            ["id": "z", "title": "缺时间戳", "status": "done"],
            ["id": "w", "title": "时间戳是字符串", "status": "done", "at": "not-a-number"],
            ["id": "v", "title": "唯一一条好的", "status": "done", "at": 1791400002.0],
        ],
    ],
]
if let parsedDirty = V.parseNight(dirtyPayload) {
    check("J11 坏条目（空标题/缺 title/缺或坏时间戳）全部跳过，只留好的那一条",
          parsedDirty.items.count == 1 && parsedDirty.items.first?.title == "唯一一条好的")
} else {
    check("J11 脏载荷仍应能解析出可用明细", false)
}
check("J12 负数总数钳到 0（脏数据不许变成负号）",
      V.parseNight(["ok": true, "night": ["total": -3, "failed": -1]])?.total == 0)
check("J13 负数失败数钳到 0",
      (V.parseNight(["ok": true, "night": ["total": 2, "failed": -1]])?.failed ?? -9) == 0)
check("J14 字符串型 total 当读不到（不做隐式转换猜数）",
      V.parseNight(["ok": true, "night": ["total": "3"]]) == nil)

print("=== K. 源码护栏：唯一真源 / 唯一读口 / 唯一挂载点 ===")
let logicPath = "qingliao/Core/WorkbenchVerdict.swift"
let barPath = "qingliao/Features/Workbench/VerdictBar.swift"
let storePath = "qingliao/Core/WorkbenchVerdictStore.swift"
let rootPath = "qingliao/Core/UIModeRoot.swift"
let logicCode = code(read(logicPath))
let barCode = code(read(barPath))
let rootCode = code(read(rootPath))

check("K1 纯逻辑文件不许 import SwiftUI（真值表要能在 Linux 编跑）",
      !logicCode.contains("import SwiftUI"))
check("K2 纯逻辑文件不许 import UIKit / EventKit 这类平台框架",
      !logicCode.contains("import UIKit") && !logicCode.contains("import EventKit"))
check("K3 三个槽位的名字只在纯逻辑里写一次（界面不许再抄一份）",
      !barCode.contains("\"待你处理\"") && !barCode.contains("\"目标今日步\"") && !barCode.contains("\"昨夜任务\""))
check("K4 空态/断网态那几句人话也只在纯逻辑里写一次",
      !barCode.contains("\"都清了\"") && !barCode.contains("\"读不到\"") && !barCode.contains("\"说一句话就能开始\""))
check("K5 三格顺序由 Slot.allCases 决定（界面不硬写顺序）",
      barCode.contains("WorkbenchVerdict.chips(") && !barCode.contains("ForEach([WorkbenchVerdict.Slot"))

let barRefs = swiftFiles().filter { read($0).contains("VerdictBar(") && $0 != barPath }
check("K6 全仓只有工作模式壳引用结论条（实得 \(barRefs.count) 处：\(barRefs.joined(separator: ", ")))",
      barRefs == [rootPath])
check("K7 生活模式那份代码（DockTabView.swift）不知道结论条存在",
      !read("qingliao/Features/DockTabView.swift").contains("VerdictBar"))
if let lifeSlice = rootCode.range(of: "case .life:") {
    let tail = String(rootCode[lifeSlice.upperBound...])
    let lifeBranch = tail.components(separatedBy: "case .work:").first ?? ""
    check("K8 生活模式分支里不许出现结论条", !lifeBranch.contains("VerdictBar"))
} else {
    check("K8 生活模式分支里不许出现结论条", false)
}
check("K9 结论条挂在 WorkbenchRoot 里（工作模式壳内）",
      rootCode.contains("safeAreaInset") && rootCode.contains("VerdictBar()"))

let readPort = "/api/agent/tasks/night"
let portFiles = swiftFiles().filter { code(read($0)).contains(readPort) }
check("K10 夜任务读口全 App 只有一处（实得 \(portFiles.count) 处：\(portFiles.joined(separator: ", ")))",
      portFiles == [storePath])
check("K11 结论条链路不许出现写接口（P1 只读承诺）",
      !barCode.contains("\"POST\"") && !code(read(storePath)).contains("\"POST\"")
        && !code(read(storePath)).contains("\"DELETE\""))
check("K12 取数器只在结论条链路里被用（不许别处偷偷再取一份）",
      swiftFiles().filter { $0 != storePath && $0 != barPath && read($0).contains("WorkbenchVerdictStore") }.isEmpty)

print("\n——— 汇总 ———")
print("共 \(total) 条断言 · \(failures) 失败")
exit(failures == 0 ? 0 : 1)
