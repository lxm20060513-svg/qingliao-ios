import SwiftUI

// MARK: - v4.0.120 AI 记住瞬间 · 提示条
//
// 出现在哪：聊天页输入栏**上方**，与一句话记账条（ChatRecordBar）同一个槽位、同一套
// 定位与动效（宿主 ChatView.chatRecordBarSlot 挂出来），视觉上属于同一类「刚发生的事，
// 可以撤」的条。
//
// 为什么长这样而不是复用 ChatRecordBar：
//   ChatRecordBar 的内容是「已记账 · 金额 + 分类 + 合计」，绑死 RecordItem 与金额单位；
//   记忆条目是自由文本、可能一次记多条，两者字段与撤销语义都不同。硬套会塞进一堆占位参数，
//   反而不如两条各自诚实。共用的只有外壳（dashboardCard 玻璃档 + 撤销 danger 胶囊 + 关闭钮），
//   那些直接沿用同一套 token。
//
// 撤销是真删：宿主调 /api/memory/delete 删掉**刚记住的这些条目**（不是标记隐藏）。
// 记忆落盘后一直留在记忆页，撤销只是把这次自动捕获撤回，不影响用户手动加的条目。
struct ChatMemoBar: View {
    let texts: [String]
    /// 真撤销（宿主实现：逐条 /api/memory/delete）
    var onUndo: () -> Void
    var onClose: () -> Void

    private var headline: String {
        guard let first = texts.first else { return "已记住" }
        return texts.count > 1 ? "已记住 · \(first) 等 \(texts.count) 条" : "已记住 · \(first)"
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(Color.accentColor)
            Text(headline)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onUndo) {
                Text("撤销").pill(.topBar, tone: .danger)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("撤销刚才记住的内容")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("关闭记住提示")
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃口径：与记账条/意图动作条同档（dashboardCard，深浅底都透）
        .dashboardCard()
        .padding(.horizontal, Spacing.section)
        // v4.0.120：12 秒自动收尾。放在**本视图自己**的 .task 里，而不是宿主 ChatView 的
        // body 修饰符链上——那条链已贴着 Swift 类型检查阈值，多一个带闭包的成员就会
        // Archive 失败（CI #608 实测）。task 绑视图身份：条被关掉/撤销即取消，不会误清下一条。
        .task(id: texts) {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            onClose()
        }
    }
}
