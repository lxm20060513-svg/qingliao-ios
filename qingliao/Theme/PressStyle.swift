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


// MARK: - v3.9.34 命中区 / 可点封装（手感补齐两件套）

extension View {
    /// 命中区外扩到 ≥44pt（Apple HIG 最小可点尺寸），**布局占位零变化**：
    /// 先按 h/v 外扩并 contentShape 撑开命中框，再用等量负 padding 抵消 ——
    /// 控件视觉尺寸、相邻间距、所在行高全部不变（SwiftUI 命中测试不裁剪子视图越界区域）。
    /// - Parameters:
    ///   - h: 水平外扩量（20pt 宽图标用 12 → 44；32pt 用 6 → 44）
    ///   - v: 垂直外扩量（同上；32×30 的控件用 7 → 44）
    /// ⚠️ 这两个数是「44 减去控件视觉边长」反推的几何值，不属 Spacing 审美档，故不套令牌。
    /// ⚠️ 真机待验证：负 padding 恢复的是**布局**尺寸，外扩那圈是否真能接住点击取决于父容器
    ///    不裁剪越界子视图（SwiftUI 默认不裁）。若真机某处外扩区不响应，该处退路是直接写
    ///    `.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())`（命中区准，但会撑开间距）。
    func hitArea44(h: CGFloat = 12, v: CGFloat = 12) -> some View {
        padding(.horizontal, h)
            .padding(.vertical, v)
            .contentShape(Rectangle())
            .padding(.horizontal, -h)
            .padding(.vertical, -v)
    }

    /// 把一行/一张卡变成可点控件：Button + PressStyle + 轻触感（与全站既有写法一致）。
    /// 保留 `.onTapGesture { … }` 的行式调用形态，只补齐「按下去有高亮 + 松手有震动」。
    /// 触感放 action 而不进 PressStyle.makeBody —— 与 PressStyle 头注 ①②同一理由。
    /// 显式 @MainActor：Haptics 是 @MainActor 类型，标注后本方法调用它的隔离性与
    /// 仓内既有写法（View 内 `Button { Haptics.tap() … }`）完全同形，不留 Swift 6 并发隐患。
    @MainActor
    func tapButton(_ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            self.contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
