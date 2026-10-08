import Foundation

// MARK: - P0-1 界面模式（工作模式 / 生活模式）
//
// 依据：`design-plans/finesse-refactor-checklist.md` v2 第 26 项（P0 模式地基）。
//
// 口径：
//   · **生活模式 = 现有 UI**（冻结基线，零行为变更）；本次工作台收敛（P1–P4）只作用于**工作模式**；
//   · 开关放设置页「外观与显示」→「界面模式」，**切换后重启 App 生效**；
//   · 不做热切换、不重建视图树 —— 半切状态（一半新 UI 一半旧 UI）最难解释也最难回退，
//     用户拍板「简单直接、可回退」优先于「切完立刻见效果」；
//   · 本文件只做「读 / 写 / 名称」一件事，启动分流在 P0-2 的**单一入口**处读 `current`（禁止散落 if）。
//
// ⚠️ UserDefaults 键**只此一处**（单一真源）：全仓别处不许再写这个键的裸字面量
//    （两处硬编码只改一边 = 静默失效，v4.0.71 dockOrder 的教训）；护栏 `ql_uimode` 钉着。
//    键放在本文件而不是 Core/Models.swift 的 UserDefaultsKey，是为了让**纯逻辑真值表**
//    能只编这一个文件就断言「读 / 写 / 脏值回落」——那边带 SwiftUI 依赖，Linux 侧编不了。

enum UIMode: String, CaseIterable, Sendable {
    /// 生活模式：现在这套界面（备忘 / 待办 / 习惯 / 长期目标 / 记录 / 定时任务 / 生活数据）
    case life
    /// 工作模式：收敛后的工作台形态（P1 起逐步落地：结论条 → 一页一职 → 深度 → 冷启动）
    case work

    /// UserDefaults 键（唯一真源）
    static let defaultsKey = "ql_ui_mode"

    /// 缺省 = 生活模式。**不许改成 .work** —— 老用户与新装默认都必须是「原来那套」，
    /// 否则等于替所有人在没同意的情况下换了 App 的样子（红线：不动在用功能）。
    static let fallback: UIMode = .life

    var title: String {
        switch self {
        case .life: return "生活模式"
        case .work: return "工作模式"
        }
    }

    /// 选择页里的一句话说明：说清「这台子围着什么事转」，别只给两个名词
    /// （用户不认识「工作模式」这四个字代表什么）。
    var subtitle: String {
        switch self {
        case .life: return "现在这套：备忘、待办、习惯、目标、记录"
        case .work: return "工作台：先给结论（待处理 / 今日步 / 昨夜任务），一页一职"
        }
    }

    /// 行/选项图标（生活=家、工作=公文包，一眼分得清）
    var icon: String {
        switch self {
        case .life: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }

    /// 当前模式。读不到 / 值非法（老版本遗留脏串、手改坏）一律回落 `fallback` ——
    /// 不能因为一个脏字符串让 App 卡在「未知模式」上（那是最难查的一类白屏）。
    static var current: UIMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let mode = UIMode(rawValue: raw) else { return fallback }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// App 本次进程**启动时**读到的模式（`static let` 懒加载，进程内只取一次）。
    /// 用途：当前值 ≠ 它 = 「改过了但还没重启」——设置页那一行要如实标出来，
    /// 否则用户切完看不到任何变化，只会以为开关坏了。
    static let launchedWith: UIMode = UIMode.current

    /// 改过但还没重启（重启后这个值自然变回 false）
    static var needsRestart: Bool { current != launchedWith }
}
