// MARK: - 图片圈注面板（v4.0.50 待做池⑦ · 用户拍板「只做图片圈注」）
//
// 用户拍板范围（App 任务卡 f2bed7088e35 → 选项 1）：
//   「只做图片圈注：选图 → 圈注 → 与原图一起发」。
// 实现口径：在选中的图片上直接画笔画，点「完成」把笔画**烘焙进原图**（输出一张图、长宽比与原图一致），
// 再由既有图片链路发出 —— vision 既看得到原内容，也看得到圈注，且**零后端改动**。
//
// 几何口径全部收在 `Core/ImageAnnotationKit.swift`（纯逻辑、可脱壳单测）：归一化点 + 等比适配矩形，
// 本文件只做接线（Canvas 回显 + DragGesture 采集 + 烘焙）。
import SwiftUI

struct ImageAnnotateSheet: View {
    /// 待圈注的原图
    let source: UIImage
    /// 完成回调（回传烘焙后的图；无笔画时原样回传）
    var onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [ImageAnnotation.Stroke] = []
    @State private var colorIndex = 0
    @State private var widthRatio: Double = ImageAnnotateSheet.widths[1]

    /// 调色板（条数必须 == ImageAnnotation.paletteCount，护栏钉死）
    static let inkColors: [Color] = [.red, .yellow, .blue, .green]
    /// 笔宽档（归一化：笔宽 / 图片显示宽度 → 换屏宽观感一致）
    static let widths: [Double] = [0.004, 0.008, 0.014]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let rect = ImageAnnotation.fitRect(
                        contentW: Double(source.size.width),
                        contentH: Double(source.size.height),
                        containerW: Double(geo.size.width),
                        containerH: Double(geo.size.height))
                    ZStack {
                        Color.black
                        Image(uiImage: source)
                            .resizable()
                            .scaledToFit()
                        inkCanvas(rect: rect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(drawGesture(geo: geo))
                }
                controlBar
            }
            .navigationTitle("圈注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 弹窗完成胶囊统一左位（本仓铁律）；取消在右
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 画布回显（只读，不拦手势）

    private func inkCanvas(rect: (x: Double, y: Double, w: Double, h: Double)) -> some View {
        Canvas { ctx, _ in
            for s in strokes {
                let pts = s.points.map { ImageAnnotation.denormalize($0, inRect: rect) }
                guard let first = pts.first else { continue }
                let style = StrokeStyle(lineWidth: max(1, s.widthRatio * rect.w),
                                        lineCap: .round, lineJoin: .round)
                let color = Self.color(at: s.colorIndex)
                if pts.count == 1 {
                    // 单点 = 一个圆点（点一下也算标注）
                    let r = style.lineWidth / 2
                    ctx.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(color))
                } else {
                    var path = Path()
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    ctx.stroke(path, with: .color(color), style: style)
                }
            }
        }
        .allowsHitTesting(false)   // 手势挂在 ZStack 上，Canvas 只画
    }

    // MARK: - 采集

    private func drawGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let p = ImageAnnotation.normalize(
                    canvasX: Double(value.location.x),
                    canvasY: Double(value.location.y),
                    contentW: Double(source.size.width),
                    contentH: Double(source.size.height),
                    containerW: Double(geo.size.width),
                    containerH: Double(geo.size.height)) else { return }   // 落在留白 → 不画
                strokes = ImageAnnotation.appending(strokes, point: p,
                                                    colorIndex: colorIndex,
                                                    widthRatio: widthRatio)
            }
    }

    // MARK: - 底部工具条（颜色 / 笔宽 / 撤销 / 清空）

    private var controlBar: some View {
        HStack(spacing: Spacing.xl) {
            HStack(spacing: Spacing.lg) {
                ForEach(0..<Self.inkColors.count, id: \.self) { i in
                    Circle()
                        .fill(Self.color(at: i))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white.opacity(i == colorIndex ? 0.95 : 0.2),
                                                 lineWidth: i == colorIndex ? 2.5 : 1))
                        .onTapGesture { colorIndex = i }
                }
            }
            Divider().frame(height: 22)
            HStack(spacing: Spacing.lg) {
                ForEach(0..<Self.widths.count, id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 6 + CGFloat(i) * 5, height: 6 + CGFloat(i) * 5)
                        .opacity(widthRatio == Self.widths[i] ? 1 : 0.5)
                        .onTapGesture { widthRatio = Self.widths[i] }
                }
            }
            Spacer(minLength: 0)
            Button { strokes = ImageAnnotation.undo(strokes) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(strokes.isEmpty)
            Button { strokes = ImageAnnotation.clear() } label: {
                Image(systemName: "trash")
            }
            .disabled(strokes.isEmpty)
        }
        .font(.system(size: Typography.headline))
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.xl)
        .background(.ultraThinMaterial)
    }

    // MARK: - 收尾

    private func finish() {
        onDone(Self.bake(source, strokes: strokes))
        dismiss()
    }

    private static func color(at index: Int) -> Color {
        let i = min(max(index, 0), inkColors.count - 1)
        return inkColors[i]
    }

    /// 把笔画**烘焙进原图**：
    /// · 渲染器尺寸 = `source.size`、`format.scale = source.scale` → 输出像素尺寸与**长宽比恒等于原图**；
    /// · 笔宽 = `widthRatio × 图像宽度` → 换屏宽画的圈落到图上比例一致（不拉伸、不变形）。
    static func bake(_ image: UIImage, strokes: [ImageAnnotation.Stroke]) -> UIImage {
        guard !strokes.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let w = Double(image.size.width)
            let rect = (x: 0.0, y: 0.0, w: w, h: Double(image.size.height))
            for s in strokes {
                let pts = s.points.map { ImageAnnotation.denormalize($0, inRect: rect) }
                guard let first = pts.first else { continue }
                let ink = color(at: s.colorIndex)
                let lw = max(1, s.widthRatio * w)
                if pts.count == 1 {
                    // 单点 = 圆点
                    let r = lw / 2
                    let dot = UIBezierPath(ovalIn: CGRect(x: first.x - r, y: first.y - r,
                                                          width: r * 2, height: r * 2))
                    ink.setFill()
                    dot.fill()
                } else {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    path.lineWidth = lw
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    ink.setStroke()
                    path.stroke()
                }
            }
        }
    }
}
