import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏实时活动：展示「AI 正在回复」+ 计时 + 模型名。
///
/// 计时用 `Text(_:style: .timer)` 交给系统自走——侧载免费签名没有推送更新，
/// App 被挂起时文本不会再刷新，只有系统计时钟照走，所以进度表达必须靠它。
struct QingliaoLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QingliaoActivityAttributes.self) { context in
            // 锁屏 / 不支持灵动岛设备的横幅
            self.lockScreenBanner(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    self.elapsedLabel(state: context.state, size: 15)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.sessionTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(self.statusText(context.state))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                self.elapsedLabel(state: context.state, size: 12)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    /// 已用时（系统自走）
    private func elapsedLabel(state: QingliaoActivityAttributes.ContentState, size: CGFloat) -> some View {
        Text(state.startedAt, style: .timer)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func statusText(_ state: QingliaoActivityAttributes.ContentState) -> String {
        if !state.isAnswering { return "已完成" }
        return state.modelName.isEmpty ? "AI 正在回复" : "AI 正在回复 · \(state.modelName)"
    }

    /// 锁屏横幅（与展开态同风格，避免两套观感割裂——轻聊本地/云端 UI 统一是既定红线）
    private func lockScreenBanner(state: QingliaoActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(statusText(state))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            elapsedLabel(state: state, size: 15)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
