// MARK: - v3.4.29 统一按压反馈样式
//
// 背景：全工程 `.buttonStyle(.plain)` 有 119 处，其中可见交互按钮（卡片/胶囊/行/图标钮）
// 绝大多数没有任何按压反馈 —— 点下去"没反应感"，是"轻快感"最直接的缺口。
//
// 只用视觉反馈（缩放 + 透明度），**触感一律留在各自 action 里**，原因：
//   ① `ButtonStyle.makeBody(configuration:)` 不在 @MainActor 隔离下，直接调用
//      @MainActor 的 Haptics 有 Swift 6 严格并发的编译风险（本地 check_swift 查不出，
//      只有 CI Archive 会暴露，一次 = 20 分钟白跑）；
//   ② 部分按钮 action 内已有 Haptics（如发送、新建会话），Style 里再响一次 = 双响。
//
// 用法：`.buttonStyle(PressStyle())`（写成显式构造，不做静态成员推断，零类型推断风险）

import SwiftUI

struct PressStyle: ButtonStyle {
    /// 按压缩放比例（卡片类 0.96 较自然；小图标可传 0.9）
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}
