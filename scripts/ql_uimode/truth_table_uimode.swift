// P0-1 界面模式真值表 —— Linux 本地预检用（编译真源 qingliao/Core/UIMode.swift）
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 90 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_uimode \
//       scripts/ql_uimode/truth_table_uimode.swift qingliao/Core/UIMode.swift
//
// 两类断言：
//   ① 纯逻辑（真编译真跑）：模式集合只有两个 / rawValue 与键钉死 / 缺省必是生活模式 /
//      **脏值必须回落**（老版本遗留串、手改坏都不许让 App 卡在「未知模式」）/ needsRestart 语义。
//   ② **源级接线**（编译不报、功能静默消失那一类）：设置页那一行 + 弹窗 + 搜索路由真的挂上了；
//      键只有一个真源（两处硬编码只改一边 = 静默失效，v4.0.71 dockOrder 的教训）；
//      并反向钉住「不做热切换」——不 import SwiftUI、不发通知、设置页不许自己按模式分流
//      （启动分流是 P0-2，已在 `Core/UIModeRoot.swift` 单点落地，见护栏 `ql_uimode_root`）。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 取 from…to 之间的切片（源级断言用；取不到返回空串 → 相关断言会红，不会假绿）
func slice(_ src: String, _ from: String, _ to: String) -> String {
    guard let a = src.range(of: from) else { return "" }
    let rest = String(src[a.upperBound...])
    guard let b = rest.range(of: to) else { return rest }
    return String(rest[..<b.lowerBound])
}

@main
struct UIModeTruthTable {

    static let modeSrc = read("qingliao/Core/UIMode.swift")
    static let sheetSrc = read("qingliao/Features/Settings/UIModeSheet.swift")
    static let coreSrc = read("qingliao/Features/Settings/SettingsCore.swift")
    static let indexSrc = read("qingliao/Core/SettingsSearchIndex.swift")

    static let key = UIMode.defaultsKey
    static let original = UserDefaults.standard.string(forKey: UIMode.defaultsKey)

    static func runAllTests() {
        let d = UserDefaults.standard

        // ── 0. 源可读（读不到 = 后面全空串假绿，先兜住）──
        positives += 1
        check("UIMode.swift 源可读", !modeSrc.isEmpty)
        positives += 1
        check("UIModeSheet.swift 源可读", !sheetSrc.isEmpty)
        positives += 1
        check("SettingsCore.swift 源可读", !coreSrc.isEmpty)
        positives += 1
        check("SettingsSearchIndex.swift 源可读", !indexSrc.isEmpty)

        // ── 1. 模式集合与取值 ──
        positives += 1
        check("恰好两个模式，且顺序 = [生活, 工作]",
              UIMode.allCases.map(\.rawValue) == ["life", "work"])
        positives += 1
        check("rawValue 与持久化串一致（life / work）",
              UIMode.life.rawValue == "life" && UIMode.work.rawValue == "work")
        positives += 1
        check("UserDefaults 键 = ql_ui_mode（与 checklist v2 第 26 项一致）", key == "ql_ui_mode")

        // ── 2. 名称/说明/图标：两个模式必须**分得清**（用户看不出差别 = 白做）──
        positives += 1
        check("两个模式各有中文名", UIMode.life.title == "生活模式" && UIMode.work.title == "工作模式")
        positives += 1
        check("两个模式说明非空且互不相同",
              !UIMode.life.subtitle.isEmpty && !UIMode.work.subtitle.isEmpty
              && UIMode.life.subtitle != UIMode.work.subtitle)
        positives += 1
        check("两个模式图标非空且互不相同",
              !UIMode.life.icon.isEmpty && !UIMode.work.icon.isEmpty
              && UIMode.life.icon != UIMode.work.icon)

        // ── 3. 读写与回落（脏值兜底是这条功能唯一可能崩的地方）──
        d.removeObject(forKey: key)
        positives += 1
        check("键缺失 → 回落生活模式（老用户/新装行为不变）", UIMode.current == .life)
        positives += 1
        check("缺省常量本身就是生活模式", UIMode.fallback == .life)

        UIMode.current = .work
        positives += 1
        check("写工作模式 → 立刻读回工作模式", UIMode.current == .work)
        UIMode.current = .life
        positives += 1
        check("写生活模式 → 立刻读回生活模式", UIMode.current == .life)

        for dirty in ["bogus", "", "Work", "life "] {
            d.set(dirty, forKey: key)
            positives += 1
            check("脏值 \(dirty.isEmpty ? "(空串)" : "\"\(dirty)\"") → 回落生活模式（不卡未知模式）",
                  UIMode.current == .life)
        }

        // ── 4. 需重启提示的语义 ──
        // ⚠️ `launchedWith` 是懒加载常量：本表**第一次**读 `needsRestart` 的那一刻它落值，
        //    所以先把它落在「生活」上，再改值验证翻转 —— 顺序不能倒，倒了这条就没检测力。
        d.removeObject(forKey: key)
        positives += 1
        check("先决：本次判定基准落在生活模式", UIMode.launchedWith == .life)
        positives += 1
        check("没改过 → 不需要重启", UIMode.needsRestart == false)
        UIMode.current = .work
        positives += 1
        check("改过（工作模式）→ 需要重启标出来", UIMode.needsRestart == true)
        UIMode.current = .life
        positives += 1
        check("改回原值 → 「需重启」随手消失（不是一次性脏标记）", UIMode.needsRestart == false)

        // ── 5. 设置页接线（源级）──
        positives += 1
        check("设置页有「界面模式」行",
              coreSrc.contains("title: \"界面模式\""))
        positives += 1
        check("行点击开弹窗（showUIMode）",
              coreSrc.contains("showUIMode = true"))
        positives += 1
        check("弹窗真的挂到视图链上（UIModeSheet() 有调用点）",
              coreSrc.contains("UIModeSheet()"))
        positives += 1
        check("单开冷组 settingsCold9（1…4 条上限，不许往已有组里塞第 5 条）",
              coreSrc.contains("private func settingsCold9() -> some View {")
              && coreSrc.contains(".background(settingsCold9())"))
        positives += 1
        check("行尾值走 uiModeValue（改完立刻刷新 + 标「重启后生效」）",
              coreSrc.contains("value: uiModeValue") && coreSrc.contains("UIMode.needsRestart"))
        positives += 1
        check("设置页读键走单一真源 UIMode.defaultsKey",
              coreSrc.contains("@AppStorage(UIMode.defaultsKey)"))
        positives += 1
        check("搜索可直达（openSearchEntry 有 uiMode 路由）",
              coreSrc.contains("case \"uiMode\": showUIMode = true"))
        positives += 1
        check("设置页搜索索引已登记「界面模式」（否则肉眼可见却搜不到）",
              indexSrc.contains("route: \"uiMode\", title: \"界面模式\""))

        // ── 6. 弹窗行为（源级）──
        positives += 1
        check("选中即写盘（UIMode.current = mode）", sheetSrc.contains("UIMode.current = mode"))
        positives += 1
        check("点当前项不写盘（guard mode != current）", sheetSrc.contains("guard mode != current else { return }"))
        positives += 1
        check("当场提示重启（alert 文案含「重启 App 后生效」）",
              sheetSrc.contains("showRestartHint") && sheetSrc.contains("重启 App 后生效"))
        positives += 1
        check("选项由枚举铺出（不硬编码两行）", sheetSrc.contains("ForEach(UIMode.allCases"))
        positives += 1
        check("顶栏「完成」在左位（全站弹窗口径）", sheetSrc.contains(".cancellationAction"))

        // ── 7. 反向断言：这些一旦出现就是做错了 ──
        negatives += 1
        check("反例：SettingsCore 不许出现裸字面量 \"ql_ui_mode\"（键唯一真源）",
              !coreSrc.contains("\"ql_ui_mode\""))
        negatives += 1
        check("反例：UIModeSheet 不许出现裸字面量 \"ql_ui_mode\"", !sheetSrc.contains("\"ql_ui_mode\""))
        negatives += 1
        check("反例：键字面量全仓只许在 UIMode.swift 出现一次（防又加一处常量）",
              modeSrc.components(separatedBy: "\"ql_ui_mode\"").count - 1 == 1)
        negatives += 1
        check("反例：缺省不许改成工作模式（改了 = 替老用户换掉在用界面）",
              modeSrc.contains("static let fallback: UIMode = .life"))
        negatives += 1
        check("反例：UIMode.swift 不许 import SwiftUI（要能被纯逻辑表编译，且与 UI 解耦）",
              !modeSrc.contains("import SwiftUI"))
        negatives += 1
        check("反例：不做热切换 —— UIMode.swift 不许有通知广播",
              !modeSrc.contains("NotificationCenter"))
        negatives += 1
        check("反例：不做热切换 —— UIModeSheet 不许有通知广播", !sheetSrc.contains("NotificationCenter"))
        negatives += 1
        check("反例：弹窗里不许按裸串判模式（\"work\" / \"life\" 只从枚举取）",
              !sheetSrc.contains("\"work\"") && !sheetSrc.contains("\"life\""))
        negatives += 1
        check("反例：设置页不许自己按模式分流（分流只在 UIModeRoot 单点，SettingsCore 不许出现 UIMode.work）",
              !coreSrc.contains("UIMode.work"))
        negatives += 1
        check("反例：UIModeSheet 不许自己落 UserDefaults（写盘只走 UIMode.current 一个口）",
              !sheetSrc.contains("UserDefaults"))
        negatives += 1
        check("反例：选中后不许自动关弹窗（提示一闪而过 = 用户没看见「要重启」）",
              !slice(sheetSrc, "UIMode.current = mode", "showRestartHint = true").contains("dismiss()"))
        negatives += 1
        check("反例：UIMode.swift 不许碰任何 UI 框架（UIKit 也不行）",
              !modeSrc.contains("UIKit"))
        negatives += 1
        // 「界面模式」那一行必须是跳到弹窗的行，不是开关（开关语义 = 关掉是什么？说不清）
        let uiModeRow = slice(coreSrc, "title: \"界面模式\"", "Divider()")
        negatives += 1
        check("反例：界面模式行不许写成 toggle（口径是「选一个」，不是「开/关」）",
              !uiModeRow.isEmpty && !uiModeRow.contains("toggle:"))

        // ── 收尾：还原真实 UserDefaults，别留下本表改过的值 ──
        if let original { d.set(original, forKey: key) } else { d.removeObject(forKey: key) }
    }

    static func main() {
        runAllTests()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 4.0)
        print(  check_readback())
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }

    /// 自证：本表跑完必须把键还原成进来时的样子（否则会污染后面要跑的其它表/真机数据）
    static func check_readback() -> String {
        let now = UserDefaults.standard.string(forKey: UIMode.defaultsKey)
        return now == original ? "✅ 收尾：UserDefaults 键已还原（\(now ?? "nil")）"
                               : "❌ 收尾：UserDefaults 键未还原（进来 \(original ?? "nil") / 现在 \(now ?? "nil")）"
    }
}
