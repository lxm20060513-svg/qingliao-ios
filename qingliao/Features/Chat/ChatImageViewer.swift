// MARK: - 图片大图查看器（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - v2.0.36 图片大图查看器（双击/捏合缩放 + 保存相册）

struct ImageViewPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]   // v2.0.62：全部图片消息（相册翻页）
    var index: Int
    // v3.4.29：zoom 转场源 id（被点气泡的消息 id）；空 = 不做转场（走系统默认呈现）
    var sourceID: String = ""
}

// MARK: - v3.4.29 图片 zoom 转场源修饰器
// iOS 18+ matchedTransitionSource 需与目标侧 .navigationTransition(.zoom(sourceID:in:)) 配对；
// ns 为空时原样返回（不参与转场）。抽成修饰器避免在每个图片分支写 if 分支。
struct ZoomSourceModifier: ViewModifier {
    let id: String
    let ns: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

extension View {
    func zoomSource(id: String, ns: Namespace.ID?) -> some View {
        modifier(ZoomSourceModifier(id: id, ns: ns))
    }
}

// v2.0.62：相册式查看器——横向滑动翻页 + 每页双击/捏合缩放 + 保存
struct ImageViewer: View {
    let images: [UIImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(0..<images.count, id: \.self) { i in
                    ImageViewerPage(image: images[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            VStack {
                HStack {
                    if images.count > 1 {
                        Text("\(index + 1) / \(images.count)")
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.xs)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.leading, Spacing.section)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Typography.display))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(Spacing.section)
                }
                Spacer()
                Button {
                    UIImageWriteToSavedPhotosAlbum(images[index], nil, nil, nil)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: Typography.body, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, Spacing.md)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 44)
            }
        }
    }
}

// 单图页：v3.9.27 双击/捏合缩放 + **放大后可随意拖动**（用户反馈：放大后不能拖动看边角）。
// 拖动只在 scale > 1 时生效；松手按边界夹紧回弹，拖不动时整体回中。
// 独立小 struct（本仓类级坑：深嵌套大 body 里塞手势易触发 CI type-check 超时）。
struct ImageViewerPage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    // 拖动偏移（pt 值）
    @State private var offset: CGSize = .zero
    // 拖动起点时的 offset 快照（手势 onChanged 里 translation + startOffset = 新位置；
    // 不冻结快照就会以「当前 offset」为基底逐帧累加 = 位移翻倍飞出）
    @State private var dragStartOffset: CGSize = .zero
    // 手势进行中标记（首帧冻结 dragStartOffset 用）
    @State private var dragging = false
    // 捏合进行中的基准值：MagnificationGesture 是增量值（从 1 开始），必须乘上当前 scale
    @State private var gestureBase: CGFloat = 1

    /// 当前缩放下允许的最大拖动距离：放大 N 倍时可视窗口外多出 (N-1)/2 倍宽/高
    private func maxOffset(size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1 else { return .zero }
        // 显示尺寸按 scaledToFit 近似：图片以短边贴容器；用宽高各半的富余量夹紧
        let w = (UIScreen.main.bounds.width * (scale - 1)) / 2
        let h = (UIScreen.main.bounds.height * (scale - 1)) / 2
        return CGSize(width: max(0, w), height: max(0, h))
    }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .animation(Motion.snap, value: scale)
                .animation(Motion.snap, value: offset)
                .gesture(MagnificationGesture()
                    .onChanged { value in
                        // 捏合起点以当前 scale 为基准（否则每次捏合都从 1 重算，先拖后捏会跳变）
                        if gestureBase == 1 { gestureBase = scale }
                        scale = max(1, min(gestureBase * value, 6))
                    }
                    .onEnded { _ in
                        gestureBase = 1
                        if scale <= 1.02 {   // 回缩到 ≈1 时一并归位（吸附）
                            scale = 1
                            offset = .zero
                        } else {
                            clampOffset(container: geo.size)
                        }
                    })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard scale > 1 else { return }
                            if !dragging { dragging = true; dragStartOffset = offset }
                            // 跟手拖动：超出边界给 0.35 的阻尼（微信式橡皮筋）
                            let m = maxOffset(size: geo.size, scale: scale)
                            offset = CGSize(width: damped(value.translation.width + dragStartOffset.width, max: m.width),
                                            height: damped(value.translation.height + dragStartOffset.height, max: m.height))
                        }
                        .onEnded { _ in
                            dragging = false
                            clampOffset(container: geo.size)
                        })
                .onTapGesture(count: 2) {
                    if scale > 1 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = 2.2
                    }
                }
                .contentShape(Rectangle())
        }
    }

    private func damped(_ v: CGFloat, max m: CGFloat) -> CGFloat {
        if v > m { return m + (v - m) * 0.35 }
        if v < -m { return -m + (v + m) * 0.35 }
        return v
    }

    /// 松手后把 offset 夹回允许范围（越界部分回弹）
    private func clampOffset(container: CGSize) {
        let m = maxOffset(size: container, scale: scale)
        offset = CGSize(width: max(-m.width, min(m.width, offset.width)),
                        height: max(-m.height, min(m.height, offset.height)))
    }
}

// MARK: - v2.0.36 会话导出文档（.txt）
