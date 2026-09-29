import UIKit
import SwiftUI

// MARK: - v3.4.25 统一触感反馈工具
// 全站触感一处封装：语义化 API（成功/警告/轻点/长按），替代散落的 UIImpactFeedbackGenerator。
// 用 UINotificationFeedbackGenerator 表达结果类反馈（成功✓/失败✗），impact 表达动作类。

// MARK: - v4.0.9 点击震动总开关
//
// 用户可在 设置 → 外观与显示 → 点击震动 关掉全站触感。
//
// **闸门只加在这一个文件里**，是刻意的设计：全站有 144 处 `Haptics.*` 调用点，
// 若在调用点逐个加 `if enabled`，漏一处就漏一处震动，且以后新增调用点还会再漏。
// 在 4 个语义入口（tap/press/success/error）统一 early-return，一个开关覆盖全部，
// 且**新增调用点自动受控**，无需记得改。
//
// ⚠️ 配套纪律：裸 `UIImpactFeedbackGenerator()` / `UINotificationFeedbackGenerator()` /
//    `UISelectionFeedbackGenerator()` **不允许**再散落在业务代码里——那种写法绕过本闸门，
//    用户关了开关它照震。需要的强度/类型用下面的 `raw*` 入口，别自己 new generator。
@MainActor
enum Haptics {
    /// 设置项 key（与设置页 SettingRow 共用同一 key，勿各写一份字符串）
    static let enabledKey = "qingliao_haptics_enabled"

    /// 全站震动总开关。**默认开**（老用户行为不变：key 缺失 = 开）
    ///
    /// ⚠️ 这里刻意**不用** `@AppStorage`：Swift 不允许 property wrapper 应用于
    /// static 存储属性（wrappedValue 初始化处编译报错），且全仓无 static @AppStorage 先例。
    /// 改为直读 UserDefaults —— key 与设置页 `SettingRow` 的 `@AppStorage(Haptics.enabledKey)`
    /// 仍是同一个，改动即时双向生效。
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    /// 闸门：关掉时任何震动入口直接返回
    @inline(__always)
    private static func gated() -> Bool { enabled }

    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let notifyGen = UINotificationFeedbackGenerator()
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectGen = UISelectionFeedbackGenerator()

    /// 轻点类动作：发送消息、开关切换
    static func tap() {
        guard gated() else { return }
        lightGen.impactOccurred()
    }

    /// 长按菜单呼出、拖拽开始等中等强度确认
    static func press() {
        guard gated() else { return }
        mediumGen.impactOccurred()
    }

    /// 操作成功：复制完成、发送成功、拉取到新推送
    static func success() {
        guard gated() else { return }
        notifyGen.notificationOccurred(.success)
    }

    /// 操作失败/警告：发送失败、内容为空
    static func error() {
        guard gated() else { return }
        notifyGen.notificationOccurred(.error)
    }

    // MARK: - 裸 generator 收编入口（v4.0.9）
    //
    // 此前有 17 处直接 `UIImpactFeedbackGenerator(...).impactOccurred()`，绕过封装。
    // 它们现已全部改走下面几个入口 → 受总开关统一管辖。
    // 新增触感一律用这些，别再自己 new generator。

    /// 列表/分段选择变化（对应 UISelectionFeedbackGenerator）
    static func selection() {
        guard gated() else { return }
        selectGen.selectionChanged()
    }

    /// 中等震动（对应 UIImpactFeedbackGenerator(style: .medium)）
    static func medium() {
        guard gated() else { return }
        mediumGen.impactOccurred()
    }

    /// 强震动（对应 UIImpactFeedbackGenerator(style: .heavy)）
    static func heavy() {
        guard gated() else { return }
        heavyGen.impactOccurred()
    }

    /// 长按蓄力：先 prepare() 再震（prepare 本身不产生震动，但开关关闭时整套都该跳过）
    static func prepareHeavy() {
        guard gated() else { return }
        heavyGen.prepare()
        heavyGen.impactOccurred()
    }

    /// 硬质短促震动（对应 UIImpactFeedbackGenerator(style: .rigid)）
    static func rigid() {
        guard gated() else { return }
        rigidGen.impactOccurred()
    }

    /// 轻震动（对应 UIImpactFeedbackGenerator(style: .light)）
    static func light() {
        guard gated() else { return }
        lightGen.impactOccurred()
    }

    /// 通知类反馈（对应 UINotificationFeedbackGenerator 的 success/error/warning）
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard gated() else { return }
        notifyGen.notificationOccurred(type)
    }
}
