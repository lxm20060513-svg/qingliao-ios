import Foundation

// 轻聊剪贴板历史 · 行为真值表（v4.0.104 待做池 #11）
// 编的是**生产源码** qingliao/Core/ClipboardHistoryStore.swift（纯 Foundation，Linux 可编）——不是镜像实现。
//
// 为什么必须真跑：这条链路的退化**全静默** —— 空串/超长被悄悄存进去、去重没做（同一段文本堆几十条）、
// 上限没兜住（剪一百次变一百条常驻 UserDefaults）、关掉开关后照旧入库、盘中结构一坏整表读不回来……
// 编译全绿、-parse 全绿、其它表照旧过，只有用户装机用久了才发现。
//
// ⚠️ 替身：Models.swift 带 `import SwiftUI`，Linux 上编不了 → 这里内联只提供两个键常量的 UserDefaultsKey。
//    替身与真值**不许漂移** —— truth_table_clipboard.swift 会读 Models.swift 与本文件逐字比对键字面量。
enum UserDefaultsKey {
    static let clipboardHistory = "qingliao_clipboard_history"
    static let clipboardHistoryEnabled = "qingliao_clipboard_history_enabled"
}

var pass = 0
var fail = 0
@MainActor func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func freshSuite() -> UserDefaults {
    let name = "ql-clipboard-test-" + UUID().uuidString
    return UserDefaults(suiteName: name) ?? .standard
}

@MainActor func fresh(_ d: UserDefaults) -> ClipboardHistoryStore { ClipboardHistoryStore(defaults: d) }

let suite = freshSuite()
let s = fresh(suite)

ck("出厂上限 = 100（真值表逐字钉同一常量）", ClipboardHistoryStore.maxEntries == 100)
ck("单条长度上限 = 2000", ClipboardHistoryStore.maxLength == 2000)
ck("默认开（新盘 isEnabled = true）", s.isEnabled)

// ① 空串 / 纯空白不入库
ck("空串不入库（返回 nil）", s.record("", source: "手动") == nil && s.count == 0)
ck("纯空白不入库（trim 后为空）", s.record("   \n\t ", source: "手动") == nil && s.count == 0)

// ② trim 归一
let e1 = s.record("  你好  ", source: "手动")
ck("trim 归一：首尾空白被剥掉", e1?.text == "你好" && s.allEntries.first?.text == "你好")

// ③ 去重：完全相同 → 不新增，只更新时间戳并置顶
let firstAt = s.allEntries.first!.at
let eDup0 = s.record("重复内容", source: "手动")
let eDup0At = s.allEntries.first!.at
Thread.sleep(forTimeInterval: 0.02)
let eDup1 = s.record("重复内容", source: "首页卡")
ck("去重：同一正文第二次不入新条（count 只 +1 一次）", s.count == 2 && eDup0?.id == eDup1?.id)
ck("去重：时间戳被刷新为现在（比第一次新）", s.allEntries.first!.at > eDup0At && eDup0At >= firstAt)
ck("去重：刷新后置顶（仍是第一条）", s.allEntries.first?.text == "重复内容")

// ④ 超长拒收（> 2000）
let tooLong = String(repeating: "a", count: 2001)
ck("超长（2001）拒收", s.record(tooLong, source: "手动") == nil && s.count == 2)
let justFit = String(repeating: "b", count: 2000)
ck("恰好 2000 长度收下", s.record(justFit, source: "手动") != nil && s.count == 3)

// ⑤ 上限 100：插 101 条不同正文 → 只留最新 100，最旧被淘汰
let cap = fresh(freshSuite())
for i in 0..<101 {
    cap.record("条目-\(i)", source: "手动")
    Thread.sleep(forTimeInterval: 0.001)
}
ck("上限收敛：插 101 条 → count == 100", cap.count == 100, "实得 \(cap.count)")
ck("淘汰最旧：第 0 条已不在", !cap.allEntries.contains { $0.text == "条目-0" })
ck("保留最新：第 100 条仍在", cap.allEntries.contains { $0.text == "条目-100" })

// ⑥ 删单条
let del = fresh(freshSuite())
let a = del.record("要删的", source: "手动")!
del.record("留下的", source: "手动")
ck("remove 命中：返回 true 且该条消失", del.remove(id: a.id) && !del.allEntries.contains { $0.id == a.id })
ck("remove 误伤邻居：另一条还在", del.allEntries.contains { $0.text == "留下的" })
ck("remove 不存在的 id：返回 false 不崩", del.remove(id: "nope") == false)

// ⑦ 开关关掉后 record 不动库
let toggled = fresh(freshSuite())
toggled.record("开着的", source: "手动")
ck("开关关掉：isEnabled = false", { toggled.isEnabled = false; return !toggled.isEnabled }())
ck("关掉后 record 一律 nil 且不入库", toggled.record("关了之后的", source: "手动") == nil && toggled.count == 1)
toggled.isEnabled = true
ck("重新打开后 record 恢复", toggled.record("又开了", source: "手动") != nil && toggled.count == 2)

// ⑧ 清空
let clrSuite = freshSuite()
let clr = fresh(clrSuite)
clr.record("x", source: "手动")
clr.record("y", source: "手动")
clr.clearAll()
ck("clearAll 清空内存", clr.count == 0)
ck("clearAll 落盘：同一 suite 新实例重载仍空", fresh(clrSuite).count == 0)

// ⑨ 持久化：新实例重载仍在 + 按时间倒序
let pers = freshSuite()
let p1 = fresh(pers)
p1.record("最早", source: "手动")
Thread.sleep(forTimeInterval: 0.02)
p1.record("最新", source: "首页卡")
let p2 = fresh(pers)
ck("新实例重载：两条都在", p2.count == 2)
ck("重载后按时间倒序（最新在前）", p2.allEntries.first?.text == "最新" && p2.allEntries.last?.text == "最早")
ck("来源字段往返不丢", p2.allEntries.first?.source == "首页卡")
ck("clearAll 后重载（同一 suite 新实例）空", { p2.clearAll(); return fresh(pers).count == 0 }())

// ⑩ 盘中结构坏了：只跳过坏条，不整表丢弃（Linux 嵌套字典坑的反向自证）
let broken = freshSuite()
broken.set([["ok", 1.0, "手动", "id1"], ["坏条只有一项"], [123, 4.0, "x", "id3"]],
           forKey: UserDefaultsKey.clipboardHistory)
let bl = fresh(broken)
ck("坏条只跳过：长度不对 / 正文非字符串都被跳掉，好的留下", bl.count == 1 && bl.allEntries.first?.text == "ok")

print(fail == 0 ? "✅ ALL PASS（\(pass) 项）" : "❌ \(fail) 项失败")
exit(fail == 0 ? 0 : 1)
