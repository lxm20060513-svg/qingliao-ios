import SwiftUI

/// P4 冷启动（条目 17 / 18）：三页共用的「一句话 + 一个动作」引导卡。
///
/// 分工：**文案与闸门全在 `Core/WorkbenchOnboard.swift`**（纯 Foundation，有 43+ 条真值表断言
/// 与变异自证盯着）；本文件只负责画和点 —— 视图里不许出现第二份文案（真值表扫全仓字面量）。
///
/// 「一个动作」的落点：把示例指令投进 `ComposerSeedBox`（一次性投递，会话页取走后填进输入框，
/// 用户改一改就能发）；不在会话页时再顺手切到会话页。
/// 🚨 **不自动聚焦键盘**：键盘已开保持、未开不弹（用户口径）——所以这里绝不碰 `inputFocus`。
struct OnboardGuideCard: View {
    let guide: OnboardGuide
    /// 点完之后的补充动作（各页自己接，比如滚到位）；默认什么都不做
    var afterAction: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(guide.title)
                .font(.system(size: Typography.headline, weight: .semibold))
                .foregroundStyle(.primary)
            Text(guide.line)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: fire) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(guide.action)
                }
                .font(.system(size: Typography.subhead, weight: .semibold))
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(Capsule().fill(Color.accentColor.opacity(Tint.faint)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .pastelCard()
    }

    private func fire() {
        // 不在会话页 → 先切到会话页（示例指令的去处：`target` 恒为 .chat），再投递。
        // 🚨 判定必须用「本卡在哪一页」（`guide.page`）——写成 `target != .chat` 是**死分支**
        //    （三页 target 都是 .chat），点完只投递、页面不动，用户观感＝按钮没反应。
        if guide.page != .chat { QingliaoRouteHandoff.request(route(guide.target)) }
        ComposerSeedBox.shared.put(guide.seed)
        afterAction()
    }

    /// 引导卡自己的落点映射（口径文件的 `OnboardPage` 不依赖 UI 层类型，映射留在这一处）
    private func route(_ page: OnboardPage) -> QingliaoDeepLink.Route {
        switch page {
        case .chat: return .chat
        case .life: return .life
        case .board: return .dashboard
        }
    }
}
