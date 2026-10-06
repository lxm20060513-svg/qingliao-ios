import SwiftUI

/// 列表行行首色块（v4.0.65 · 用户 2026-10-06 看对比稿拍板「待办走 B / 备忘走 A」）
///
/// 几何与记录分类卡 CategoryBadge 同族：边长 36、圆角 = 0.305×边长（36 → 11）、
/// 符号字号 = 0.5×边长（36 → 18）、白符号。三处列表行的行首因此长一个样。
///
/// ⚠️ **只用在外层列表行（compact == false）**。页级单卡（首页那张）保持原样：
///   · 备忘——用户 v3.9.37 明确要求单卡「连图标也不要」（见 MemoSection.metaRow 注释）；
///   · 待办——同理不跟着放大，首页卡行首突然变大显得突兀，且要用户再拍一次板。
/// 稿：/opt/data/scripts/ql_memo_todo/mock/out/memo_todo_icons.png

/// 色块外壳：尺寸与圆角只此一处（两处各写一套几何 = 迟早漂移）
///
/// ⚠️ 写成 ViewModifier、不写顶层裸函数：文件内私有**泛型**函数（`func badgeShell<C: View>`）
/// 会被 v3.9.113「裸函数调用都有定义」护栏误判成未定义（那条的定义正则不认泛型签名）。
/// ViewModifier 是类型，不在它的射程内，也更贴 SwiftUI 习惯。
struct BadgeShell: ViewModifier {
    /// 边长（默认 36 = 生活卡族口径；记录分类卡 CategoryBadge 传自己的档）
    var size: CGFloat = 36
    let color: Color

    func body(content: Content) -> some View {
        RoundedRectangle(cornerRadius: size * 0.305, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay { content }
            // 来源/状态在行内已有文字或独立语义，图标不重复播报
            .accessibilityHidden(true)
    }
}

/// 来源色块：来源色底 + 白色来源符号（备忘方案 A / 行首锚点）
struct SourceBadge: View {
    let source: String
    /// 来源符号名由调用方传入（MemoItem.sourceIcon / TodoItem.sourceIcon）——
    /// 符号归数据域，本组件不重复维护第二份映射
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 36 * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .modifier(BadgeShell(color: SourceStyle.tint(source)))
    }
}

/// 待办完成状态色块：未完成浅灰底 + 白圈 / 完成绿底 + 白勾（待办方案 B）
struct TodoStatusBadge: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 36 * 0.5, weight: .medium))
            .foregroundStyle(.white)
            // 未完成底色用**不透明** systemGray：v4.0.65 审查（一般）—— 原先直接把旧 15pt 完成圈的
            // 「符号描边色」Color.secondary.opacity(0.55) 挪来当**填充色**，白圈叠半透明灰 ≈2.7:1，
            // 低于 UI 组件 3:1 门槛（看着像一块近纯灰方块，状态全靠低对比白圈传达）。
            // systemGray 不透明、深浅模式自适应，白圈叠上去 ≈3.3:1。
            .modifier(BadgeShell(color: done ? .green : Color(uiColor: .systemGray)))
    }
}
