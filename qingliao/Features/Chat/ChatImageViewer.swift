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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.leading, 16)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Button {
                    UIImageWriteToSavedPhotosAlbum(images[index], nil, nil, nil)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 44)
            }
        }
    }
}

// 单图页：双击/捏合缩放
struct ImageViewerPage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .animation(Motion.snap, value: scale)
            .gesture(MagnificationGesture()
                .onChanged { scale = max(1, min($0, 4)) })
            .onTapGesture(count: 2) {
                scale = scale == 1 ? 2.2 : 1
            }
    }
}

// MARK: - v2.0.36 会话导出文档（.txt）
