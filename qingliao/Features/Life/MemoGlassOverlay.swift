import SwiftUI

// MARK: - v4.0.76 备忘录毛玻璃浮层（用户拍板规格）
//
// 「玻璃面板浮起：点击触发弹窗，背景缓慢模糊，半透明磨砂玻璃从底部浮起，背景不完全遮挡」
//
// 为什么不用系统 sheet：presentationBackground 是全仓红线（v3.9.23 起），且系统 sheet
// 无法做出「背景模糊从 0 缓入」的节拍。这里自绘根级浮层：
//   · 第一层：背景页上盖 ultraThinMaterial 的模糊罩，opacity 0→1 缓入（≈ backdrop 0→26px）；
//     罩本身半透明 + 材质薄，「背景不完全遮挡」——隐约可见页面轮廓
//   · 第二层：面板 = .ultraThinMaterial + 白 42/255 罩色 + hero 圆角，从底部 24pt、
//     0.94 缩放浮起（Motion.emerge；关闭反向 .settle）
// 动画真源单一：isPresented 变化 → withAnimation 驱动 blurOn/panelOn 两个相位；
// 点模糊罩任意处收起；面板内内容照常交互（命中测试只在罩层）。

/// 备忘录毛玻璃浮层容器。
/// 用法：ZStack 顶层挂 `MemoGlassOverlay(isPresented: $show) { 内容 }`，
/// 内容复用原 sheet 的主体（NavigationStack 外壳去掉，顶栏照旧自绘）。
struct MemoGlassOverlay<Content: View>: View {
    @Binding var isPresented: Bool
    /// 内容避让：面板最大高度（占屏比），超出内部滚动
    var maxHeightRatio: CGFloat = 0.82
    @ViewBuilder var content: () -> Content

    /// 模糊罩相位（0→1：背景缓慢模糊）
    @State private var blurOn = false
    /// 面板相位（0.94→1 缩放 + 底部 24pt→0 浮起 + 透明→不透明）
    @State private var panelOn = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                // 第一层：背景模糊罩——材质+淡白底，「背景不完全遮挡」；点击收起
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(blurOn ? 1 : 0)
                    .overlay(Color.white.opacity(0.10))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .transition(.opacity)
            }
            if isPresented {
                // 第二层：玻璃面板——半透明磨砂 + 白 42/255，自底部浮起
                VStack(spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: maxHeightRatio * UIScreen.main.bounds.height, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                                .fill(Color.white.opacity(42.0 / 255.0))
                        )
                        // 上缘一条细高光，玻璃的「厚度感」；描边极淡避免脏边
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                .scaleEffect(panelOn ? 1 : 0.94)
                .offset(y: panelOn ? 0 : 24)
                .opacity(panelOn ? 1 : 0)
                .transition(.opacity)
            }
        }
        .animation(nil, value: isPresented)          // 相位动画全由 dismiss/present 闭包驱动（见下）
        .onAppear { if isPresented { present() } }   // v4.0.76 审查④：宿主用外层 if 门控挂载（showAll=true 才插入），
                                                     // onChange 永不触发 → 面板恒 opacity 0 隐形；插入时已在展示态就手动播 present
        .onChange(of: isPresented) { _, on in
            if on { present() } else { dismissAnimate() }
        }
    }

    /// 打开：相位瞬置起点 → 下一拍 emerge 浮起。模糊罩走 flow（「缓慢模糊」比面板慢半拍到位）
    private func present() {
        blurOn = false
        panelOn = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.02))
            withAnimation(Motion.flow) { blurOn = true }
            withAnimation(Motion.emerge) { panelOn = true }
        }
    }

    /// 收起：反向。面板先走（settle 无回弹），模糊罩随 flow 淡出后由 if 移除
    private func dismissAnimate() {
        withAnimation(Motion.settle) { panelOn = false }
        withAnimation(Motion.flow) { blurOn = false }
    }

    private func dismiss() {
        isPresented = false
    }
}
