import SwiftUI

// MARK: - v4.0.x 一句话记账 · 会话内动作条（「真撤销」的落点）
//
// 出现在哪：聊天页输入栏**上方**（宿主 ChatView.chatComposerArea 里、intentActionBarSlot 之后），
// 由宿主用与意图动作条同一套定位/动效挂出来（不碰输入栏内部那套两层结构）。
//
// ⚠️ 为什么「撤销按钮」在这条上、而不是在会话里那张记账卡上（诚实说明缺口，别当设计而非缺口看）：
//   记账卡本体 = 会话里的 isPush 消息 + ```ql-card 围栏（走既有 AgentResultCard 渲染，
//   不新造第二套渲染体系）；但 `AgentCard` 协议**没有可交互动作位** ——
//   它只有 title/subtitle/status/fields/metrics/items/table/footer，唯一的交互是 plan 卡写死的
//   「继续下一步」（语义是追下一步，不是删账）。
//   要把按钮放进卡片本身，需要改这三个（**都不在本轮允许改的文件里**）：
//     ① qingliao/Core/AgentCardParser.swift   —— 协议加一个 actions 段（id + label）
//     ② qingliao/Features/Chat/AgentResultCard.swift —— 渲染动作胶囊并把 id 回调出去
//     ③ qingliao/Features/Chat/ChatComponents.swift + ChatMessageBubble.swift
//        —— 把宿主传进来的 onCardAction 透传到卡片（ChatView 是宿主，那一步本轮能做）
//   所以本轮把**真按钮**放在这条动作条上（它真的调 RecordStore.delete，删的就是那一笔），
//   卡片 footer 只写「撤销：点输入框上方的『撤销』」= 指路，**不是**假按钮
//   （卡上没有任何可点元素宣称自己能撤销）。
//
// 生命周期：留到用户按「撤销」或「关闭」，或离开/重建这一页。
//   刻意**不做**意图动作条那样的 5 秒窗口：记账卡是长期留在会话里的，
//   「记错了要能撤」不该被 5 秒卡掉 —— 这是本入口与意图动作条唯一的形态差异，不是抄漏。
struct ChatRecordBar: View {
    let item: RecordItem
    let category: String
    /// 真撤销（宿主实现：RecordStore.delete + 收回会话里那张卡）
    var onUndo: () -> Void
    var onClose: () -> Void

    private var summary: String {
        ChatRecordKit.barSummary(amount: item.amount ?? 0, unit: item.unit, category: category)
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("已记账 · \(item.title)")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // 撤销 = 删除类动作 → danger 淡底（Pill 口径：红/灰危险色不上玻璃）
            Button(action: onUndo) {
                Text("撤销").pill(.topBar, tone: .danger)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("撤销刚才记的这笔账")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("关闭记账提示")
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃口径：与意图动作条同档（v4.0.0 用户真机拍板的 dashboardCard，深浅底都透）
        .dashboardCard()
        .padding(.horizontal, Spacing.section)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
