//
//  MenuIconTile.swift
//  v4.0.70：长按气泡菜单的彩色图标（用户 2026-10-07 看三档对比稿拍板方案 C：彩色圆角块 + 白符号）
//
//  ⚠️ 为什么不直接用 SF Symbol：UIMenu 把菜单项图片一律按 template 渲染（染成文字色），
//     Symbol 本身没有颜色可保留 → 现状就是清一色黑白符号。
//     唯一能让系统菜单保住颜色的做法：给**非 Symbol 位图** + 显式 `.withRenderingMode(.alwaysOriginal)`
//     （UIAction(image:) 认这个开关，见 ql-ui 记录里的 exchangetuts 实测）。
//     所以这里在本地把「圆角色块 + 白符号」画成一张位图交给系统。
//
//  三档渲染（v4.0.77 起）：
//   · tile(...)  —— 26pt 圆角色块（r=8）+ 15pt 白符号。给 UIKit 菜单用（SelectableTextLabel 的气泡菜单）。
//   · small(...) —— **20pt 缩小版**圆角色块（r=6）+ 11.5pt 白符号。给 SwiftUI `.contextMenu` 用：
//                  用户 2026-10-08 口径「长按 AI 输出气泡弹出的菜单，每个功能图标采用缩小版的圆角图标，
//                  而不是现在这种简洁风格图标」——原先那一档是 glyph（只有彩色符号、无底色块）。
//   · glyph(...) —— 只有彩色符号、底色透明。留给「不要色块」的 SwiftUI 菜单兜底：被 template 染色
//                  也只是退化成单色符号（与改动前一模一样），绝不会出现黑方块。
//
//  颜色用**固定色值**（不用 systemBlue 这类动态色）：位图是烘死的，动态色会在深色/浅色下被烘成同一份，
//  而固定色在两种菜单底色上都成立，也就不必关心烘焙时的 trait。
//
//  不缓存：菜单每行长按才构建一次，画 13 张 26pt 位图约 1~2ms，不值得为此引入全局可变状态
//  （Swift 6 严格并发下 static var 缓存要额外隔离，收益不成比例）。
//

import UIKit

/// 菜单图标配色（语义分组：复制/分享类=蓝，选择/整理类=青，归档类=紫，变更类=橙，钉与删除单独）
enum MenuIconTint {
    case blue, teal, purple, orange, indigo, red

    /// 定稿稿里的固定色值（浅色/深色下都用这一套）
    var uiColor: UIColor {
        switch self {
        case .blue:   return UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1)   // #007AFF
        case .teal:   return UIColor(red: 0.19, green: 0.69, blue: 0.78, alpha: 1)   // #30B0C7
        case .purple: return UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)   // #AF52DE
        case .orange: return UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)   // #FF9500
        case .indigo: return UIColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1)   // #5856D6
        case .red:    return UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1)   // #FF3B30
        }
    }
}

enum MenuIconTile {
    /// 色块边长 / 圆角半径 / 符号字号（对比稿定稿值）
    private static let side: CGFloat = 26
    private static let corner: CGFloat = 8
    private static let glyphPoint: CGFloat = 15
    /// v4.0.77：**缩小版**参数（SwiftUI 长按气泡菜单用）
    private static let smallSide: CGFloat = 20
    private static let smallCorner: CGFloat = 6
    private static let smallGlyphPoint: CGFloat = 11.5
    /// 缩小版符号的 alpha —— 见 `small(...)` 注释里的「染色兜底」
    private static let smallGlyphAlpha: CGFloat = 0.8

    /// 彩色圆角块 + 白符号（UIKit 菜单项用）
    static func tile(_ symbol: String, _ tint: MenuIconTint) -> UIImage? {
        let color = tint.uiColor
        let rect = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let image = UIGraphicsImageRenderer(size: rect.size).image { ctx in
            // 圆角裁剪与填充全走 CoreGraphics：CGPath 与 cgContext.fill 都是线程无关 API
            // （本仓 ChatComponents 已有 `ctx.cgContext.fill(imgRect)` 的同款用法，口径照抄）。
            // 不用 UIBezierPath.addClip()：那是 UIKit 类，Swift 6 隔离标注不稳，没必要冒这个险。
            ctx.cgContext.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.cgContext.clip()
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fill(rect)
            drawGlyph(symbol, in: rect, color: .white)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// v4.0.77：**缩小版圆角图标**（20pt 色块，r=6，11.5pt 白符号）——长按 AI 气泡菜单用。
    /// 用户口径：「每个功能图标采用缩小版的圆角图标，而不是现在这种简洁风格图标」
    /// （此前那一档是 `glyph`＝只有彩色符号、没有色块，看着比 UIKit 菜单里的圆角色块「简」一档）。
    ///
    /// 为什么符号用 0.8 alpha 而不是纯白：SwiftUI 的 `.contextMenu` 对位图染色行为不稳定
    /// （见文件头说明）。原样渲染时 0.8 白叠在饱和色块上肉眼与纯白无异；**万一**被当 template 染色，
    /// 色块变成菜单文字色，但符号仍留 0.2 的 alpha 差 → 还能看清符号，不会退化成「一个空方块」。
    static func small(_ symbol: String, _ tint: MenuIconTint) -> UIImage {
        let color = tint.uiColor
        let rect = CGRect(origin: .zero, size: CGSize(width: smallSide, height: smallSide))
        let image = UIGraphicsImageRenderer(size: rect.size).image { ctx in
            ctx.cgContext.addPath(CGPath(roundedRect: rect, cornerWidth: smallCorner, cornerHeight: smallCorner, transform: nil))
            ctx.cgContext.clip()
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fill(rect)
            guard let glyph = UIImage(systemName: symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: smallGlyphPoint,
                                                                                     weight: .semibold))?
                .withTintColor(UIColor.white.withAlphaComponent(smallGlyphAlpha), renderingMode: .alwaysOriginal)
            else { return }
            let size = glyph.size
            glyph.draw(in: CGRect(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2,
                                  width: size.width,
                                  height: size.height))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// 只有彩色符号、底色透明（SwiftUI contextMenu 用；被染色也不比现状差）
    /// 返回**非可选**：SwiftUI 的 Image(uiImage:) 不收可选值；符号名打错时回落成一张空图
    /// （菜单里就是这一项没有图标，不会崩、也不会画错），比强制解包安全。
    static func glyph(_ symbol: String, _ tint: MenuIconTint) -> UIImage {
        guard let base = symbolImage(symbol) else { return UIImage() }
        let size = base.size
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            base.withTintColor(tint.uiColor, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// 指定字号的原始符号图
    private static func symbolImage(_ symbol: String) -> UIImage? {
        UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphPoint, weight: .semibold))
    }

    /// 把符号画在矩形正中（尺寸按符号自身大小，不做拉伸）
    private static func drawGlyph(_ symbol: String, in rect: CGRect, color: UIColor) {
        guard let glyph = symbolImage(symbol)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = glyph.size
        glyph.draw(in: CGRect(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2,
                              width: size.width,
                              height: size.height))
    }
}
