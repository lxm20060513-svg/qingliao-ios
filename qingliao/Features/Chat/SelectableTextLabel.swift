import SwiftUI
import UIKit

// MARK: - v2.0.122 可选取文字视图（UITextView 包装）
// 长按文字 → 弹出自定义编辑菜单（复制/选取文字/引用/分享/大爆炸/重新生成/删除/撤回）
// 点「选取文字」→ 菜单消失，手按位置的词被选中，出现原生拖动手柄，可自由拖动选取范围。
// 纯 SwiftUI Text 无法程序化选中文字，必须用 UITextView（isSelectable）实现。

struct SelectableTextLabel: UIViewRepresentable {
    let attributedText: NSAttributedString
    let fallbackColor: UIColor          // 无颜色属性的文本用此色（用户消息白字 / AI 消息 label）
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    var onShare: () -> Void = {}
    var onBigBang: () -> Void = {}
    var onDelete: () -> Void = {}
    var onRegenerate: (() -> Void)? = nil
    var onWithdraw: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.dataDetectorTypes = []
        // 尺寸行为与 SwiftUI Text 一致：短文本气泡窄、长文本换行不撑爆
        //（hugging required → 按内容宽；compression low → 超宽时压缩换行）
        tv.setContentHuggingPriority(.required, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributedText
        tv.textColor = fallbackColor
        tv.font = UIFont.systemFont(ofSize: 15)   // 无字体属性文本的默认（有属性则保留）
        // 统一行距（与旧 Text 渲染 3pt 一致）
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let attr = NSMutableAttributedString(attributedString: attributedText)
        attr.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: attr.length))
        tv.attributedText = attr
        tv.layoutIfNeeded()
        tv.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: SelectableTextLabel
        init(parent: SelectableTextLabel) { self.parent = parent }

        // iOS 16+：完全接管长按编辑菜单（替代系统 拷贝/选取/全选 等）
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: UITextRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            var children: [UIMenuElement] = []

            children.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                self.parent.onCopy()
            })

            // 核心：选中手按位置的词 → 系统显示拖动手柄，可自由拖动选取范围
            children.append(UIAction(title: "选取文字", image: UIImage(systemName: "selection.pin.in.out")) { _ in
                let pos = range.start
                if let wordRange = textView.tokenizer.rangeEnclosingPosition(
                    pos, with: .word, inDirection: .layout(.right)) {
                    textView.selectedTextRange = wordRange
                } else {
                    textView.selectedTextRange = range
                }
            })

            children.append(UIAction(title: "引用", image: UIImage(systemName: "quote.opening")) { _ in
                self.parent.onQuote()
            })
            children.append(UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self.parent.onShare()
            })
            children.append(UIAction(title: "大爆炸", image: UIImage(systemName: "burst.fill")) { _ in
                self.parent.onBigBang()
            })
            if let onRegenerate = parent.onRegenerate {
                children.append(UIAction(title: "重新生成", image: UIImage(systemName: "arrow.clockwise")) { _ in
                    onRegenerate()
                })
            }
            if let onWithdraw = parent.onWithdraw {
                children.append(UIAction(title: "撤回", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                    onWithdraw()
                })
            }
            children.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.parent.onDelete()
            })
            return UIMenu(children: children)
        }
    }
}
