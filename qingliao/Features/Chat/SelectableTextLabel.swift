import SwiftUI
import UIKit

// MARK: - v2.0.125 可选取文字视图（UITextView 包装）
// 长按文字 → 弹出自定义编辑菜单（复制/引用/分享/大爆炸/选择文本/重新生成/删除/撤回）
// 点「选择文本」→ 菜单消失，手按位置的词被选中，出现原生拖动手柄，可自由拖动选取范围。
// 纯 SwiftUI Text 无法程序化选中文字，必须用 UITextView（isSelectable）实现。
//
// ⚠️ iOS 26+ 关键坑（v2.0.124 曾在此改坏）：
//  - iOS 26 起弃用 textView(_:editMenuForTextIn:) 委托，长按时不再调用 → 必须实现
//    textView(_:editMenuForTextInRanges:)，否则自定义菜单全丢、只弹系统默认菜单
//  - iOS 26 弃用的是 UITextView.selectedRange（NSRange 版），UITextInput 的
//    selectedTextRange（UITextRange 版）依然有效 —— 选中文字统一用 selectedTextRange

struct SelectableTextLabel: UIViewRepresentable {
    // v3.0.44 性能：sizeThatFits 高度缓存（跨 LazyVStack cell 存活）
    // 长文本每次被 sizeThatFits 问高度都全量排版 = 滚动卡主因；同文本+同宽命中即免二次排版。
    // NSCache 线程安全 + LRU 自动清理防内存暴涨；key = 文本hash|宽度|字号。
    // （NSCache 官方线程安全，static let 惰性初始化亦线程安全，故 nonisolated(unsafe) 是安全逃逸）
    nonisolated(unsafe) static let heightCache = NSCache<NSString, NSNumber>()
    // v3.0.44：上限防流式期间增量死条目无限累积（NSCache 默认 countLimit=0 不限）
    nonisolated(unsafe) static let heightCacheInit: Void = {
        SelectableTextLabel.heightCache.countLimit = 512
    }()

    let attributedText: NSAttributedString
    let fallbackColor: UIColor          // 无颜色属性的文本用此色（用户消息白字 / AI 消息 label）
    // v2.0.125：行距可配（AI 回复行距缩小；用户消息保持原行距）
    var lineSpacing: CGFloat = 3
    // v2.0.130：AI 消息行距从设置实时读（UserDefaults 直读，不依赖 SwiftUI 参数传递时机——修复"调了没生效"）
    var lineSpacingFromSettings: Bool = false
    // v3.0.11 fix：AI 消息统一满容器宽（流式宽度恒定，消除"字变小/排版每帧跳变"）
    // —— v3.0.2/a253fe4 引入的"按内容宽收缩"在流式内容增长时会跳变（v3.0.4 曾修复又被同天回退），
    // 用户消息保持内容自适应（短文本窄气泡，微信风格）不受影响。
    var fillWidth: Bool = false
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    var onShare: () -> Void = {}
    var onBigBang: () -> Void = {}
    // v3.0.8：onSelectText 已随「选择文本」菜单项移除（复制选中覆盖），不再使用
    var onDelete: () -> Void = {}
    var onRegenerate: (() -> Void)? = nil
    var onWithdraw: (() -> Void)? = nil
    // v3.3.0：多选合并转发入口（文字长按菜单）
    var onMultiSelect: () -> Void = {}

    // v3.0.13：布局跟踪——SwiftUI 只在 observed 属性变化时调 updateUIView，气泡在展开/折叠动画
    // 期间宽度渐进变化时 updateUIView 可能不重进，导致 UITextView 的 NSTextContainer 锁在动画起始的
    // 窄宽 → 展开后字体等比缩小（刷新即恢复的根因）。用重写 layoutSubviews 捕获一切宽度变化，
    // 一旦宽度变化就重置指纹强制重排，且触发 intrinsic 尺寸失效，杜绝"压进小气泡缩小"。
    final class TrackingTextView: UITextView {
        var onWidthChange: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat = -1
        override func layoutSubviews() {
            super.layoutSubviews()
            // 强制文本容器宽跟随当前显示宽（widthTracksTextView 兜底，动画期间旧窄宽才能被刷新）
            let cw = bounds.width - textContainerInset.left - textContainerInset.right
            if textContainer.size.width != cw {
                textContainer.size = CGSize(width: max(cw, 0), height: textContainer.size.height)
            }
            if bounds.width != lastWidth {
                lastWidth = bounds.width
                onWidthChange?(bounds.width)
            }
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = TrackingTextView()
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
        // v3.0.13：宽度变化 → 立即信息 intrinsic 尺寸失效，让 SwiftUI 重新测量/调用 sizeThatFits；
        // 并重置指纹，下次 updateUIView 按新宽重排容器
        tv.onWidthChange = { [weak context = context.coordinator, weak tv] _ in
            tv?.invalidateIntrinsicContentSize()
            tv?.setNeedsLayout()
            context?.lastKey = ""
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.textColor = fallbackColor
        // v3.0.7 fix：兜底字号跟随聊天字号设置（原硬编码 15，设置调大后无属性 run 仍是 15 → 大小不齐）
        let uiFontSize = UserDefaults.standard.double(forKey: "qingliao_font_size")
        tv.font = UIFont.systemFont(ofSize: CGFloat(uiFontSize > 0 ? uiFontSize : 15))
        // 行距：AI 消息从设置实时读（0-6），用户消息用固定值
        let spacing = lineSpacingFromSettings
            ? UserDefaults.standard.double(forKey: "qingliao_ai_line_spacing")
            : lineSpacing
        // v2.0.132：内容指纹——文本/行距/颜色/字号未变化则跳过重建（LazyVStack 滚动
        // 复用 cell 时 SwiftUI 反复调 updateUIView，重设 attributedText + layoutIfNeeded
        // 是长记录滑动卡顿主因；同内容直接 return 保留现有布局）
        // v3.0.7 fix：字号加入指纹——设置改字号后同文本不再被指纹命中跳过（旧字大小不齐根因）
        // v3.0.12 fix：宽度加入指纹——AI 长消息折叠/展开、旋转或气泡宽度变化时，即使文本
        // 指纹未变，UITextView 的 NSTextContainer 宽度也须跟随刷新，否则字体被压进旧的小
        // 容器宽里等比例变小（刷新窗口即恢复的现象根因）。宽度一变强制重排。
        let key = "\(attributedText.string.hashValue)|\(spacing)|\(fallbackColor.cgColor)|\(uiFontSize)|\(Int(tv.bounds.width))"
        if context.coordinator.lastKey == key {
            return
        }
        context.coordinator.lastKey = key
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        let attr = NSMutableAttributedString(attributedString: attributedText)
        attr.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: attr.length))
        tv.attributedText = attr
        tv.layoutIfNeeded()
        tv.invalidateIntrinsicContentSize()
    }

    // v2.0.130：修复"AI 回复文字显示不完整断句"——
    // SwiftUI 用 intrinsicContentSize 布局时宽度未定，UITextView 按单行宽度算高度 → 多行被裁。
    // 🚨 防 .infinity 提案：宽度为无穷时 UITextView 按单行换行算高度 → 仍会裁切，须钳制到气泡最大宽。
    // v3.0.4 fix（气泡自适应+无抖动）：宽度 = min(单行内容宽, 最大宽)——单行短文本窄气泡，
    // 多行超宽自动钳制为最大宽；宽度随文本单调增长（短→窄 长→宽），流式时平滑不跳变
    // （区别于 v3.0.2 按高度判断单行 → 边界抖动"字时大时小"）。
    /// v3.0.44：缓存 key 用的当前字号（与 updateUIView 内实际渲染字号一致）
    private func tvFontSize() -> CGFloat {
        let s = UserDefaults.standard.double(forKey: "qingliao_font_size")
        return CGFloat(s > 0 ? s : 15)
    }

    /// v3.0.44：缓存 key —— 文本|宽度|字号|行距 齐全，与 updateUIView 渲染指纹一致
    /// （宽度/字号 rounded 避免 Int 截断在换行临界错 1 行）
    private func measureKey(_ text: String, width: CGFloat) -> String {
        let spacing = lineSpacingFromSettings
            ? UserDefaults.standard.double(forKey: "qingliao_ai_line_spacing")
            : lineSpacing
        return "\(text.hashValue)|\(text.count)|\(width.rounded())|\(tvFontSize().rounded())|\(spacing)"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        _ = Self.heightCacheInit   // 触发 countLimit 初始化
        let maxWidth = UIScreen.main.bounds.width - 60
        // v3.0.5 review fix：优先用容器提案宽（iPad 分栏等窄容器），无提案才用屏幕宽
        let available = (proposal.width.map { $0.isFinite ? $0 : nil } ?? nil) ?? maxWidth
        let upperBound = min(available, maxWidth)
        let text = attributedText.string
        // v3.0.44 fix：命中/写入前校验 tv 实际内容 == 目标文本，否则跳过缓存
        //（防先于 updateUIView 用空/旧 tv 测出错误高度污染真实 key）
        let tvMatches = (uiView.text == text)
        let key = measureKey(text, width: fillWidth ? upperBound : 0)
        if fillWidth {
            // v3.0.44：命中高度缓存直接返回（长文本滚动不再重复全量排版）
            if tvMatches, let h = Self.heightCache.object(forKey: key as NSString) {
                return CGSize(width: upperBound, height: h.doubleValue)
            }
            // v3.0.11 fix：满容器宽——宽度恒定（只随行数长高），流式内容增长时布局不跳变
            let size = uiView.sizeThatFits(CGSize(width: upperBound, height: .greatestFiniteMagnitude))
            if tvMatches {
                Self.heightCache.setObject(NSNumber(value: size.height), forKey: key as NSString)
            }
            return CGSize(width: upperBound, height: size.height)
        }
        // 非 fillWidth（用户消息自适应气泡）同样走缓存，key 用最终计算宽度
        let contentW = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
        let target = max(min(contentW + 10, upperBound), 1)
        let wKey = measureKey(text, width: target)
        if tvMatches, let h = Self.heightCache.object(forKey: wKey as NSString) {
            return CGSize(width: target, height: h.doubleValue)
        }
        let size = uiView.sizeThatFits(CGSize(width: target, height: .greatestFiniteMagnitude))
        if tvMatches {
            Self.heightCache.setObject(NSNumber(value: size.height), forKey: wKey as NSString)
        }
        return CGSize(width: target, height: size.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: SelectableTextLabel
        // v2.0.132：上次渲染的内容指纹（文本长度|行距|颜色），未变则跳过重建
        var lastKey = ""
        init(parent: SelectableTextLabel) { self.parent = parent }

        // iOS 26+ 新 API（部署目标 26.0，唯一生效路径；旧 API editMenuForTextIn 已弃用不再调用）
        // 🚨 关键坑（v2.0.124/125 改坏根源）：iOS 26 全面转向 NSRange 体系（selectedRanges:
        // [NSRange]、UITextField 新 API 直接 [NSRange]），ranges 的 [NSValue] 包装的是 **NSRange**，
        // 必须用 rangeValue 取；124/125 用 nonretainedObjectValue as? UITextRange 转换必然失败
        // → 返回 nil → 系统默认菜单（自定义项全丢）。
        // ⚠️ 返回 nil = 显示系统默认菜单（Apple 文档原话），任何情况都要返回自定义菜单
        func textView(_ textView: UITextView,
                      editMenuForTextInRanges ranges: [NSValue],
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let first = ranges.first else { return nil }
            // 兼容两种包装：优先 UITextRange（nonretainedObjectValue），失败回退 NSRange（rangeValue）
            let nsRange: NSRange
            if let tr = first.nonretainedObjectValue as? UITextRange {
                let loc = textView.offset(from: textView.beginningOfDocument, to: tr.start)
                let len = textView.offset(from: tr.start, to: tr.end)
                nsRange = NSRange(location: loc, length: len)
            } else {
                nsRange = first.rangeValue
            }
            return buildMenu(for: nsRange, in: textView)
        }

        /// 自定义编辑菜单：复制选中/复制整段/引用/分享/大爆炸/选择文本/重新生成/撤回/删除
        private func buildMenu(for range: NSRange, in textView: UITextView) -> UIMenu {
            var children: [UIMenuElement] = []

            // v3.0.2 fix：区分「复制选中」和「复制整段」——选中文字后点复制应只复制选区，
            // 之前一律走 onCopy() 复制整段（用户 bug：选中几个字却复制全文）。
            // 有实际选区 → 复制选中文本；无选区（长按空白/未选中）→ 复制整段。
            let hasSelection = range.length != 0 && textView.selectedTextRange != nil
            children.append(UIAction(title: hasSelection ? "复制选中" : "复制",
                                     image: UIImage(systemName: "doc.on.doc")) { _ in
                if hasSelection {
                    // 复制当前选中文本（精确选区）
                    if let selected = textView.selectedTextRange,
                       let text = textView.text(in: selected),
                       !text.isEmpty {
                        UIPasteboard.general.string = text
                    } else {
                        self.parent.onCopy()   // 兜底整段
                    }
                } else {
                    self.parent.onCopy()   // 整段复制
                }
            })
            // v3.0.2：始终提供「复制整段」（AI 长回复整段复制）
            children.append(UIAction(title: "复制整段", image: UIImage(systemName: "doc.on.doc.fill")) { _ in
                self.parent.onCopy()
            })
            children.append(UIAction(title: "引用", image: UIImage(systemName: "quote.opening")) { _ in
                self.parent.onQuote()
            })
            children.append(UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self.parent.onShare()
            })
            // v3.3.0：多选合并转发入口
            children.append(UIAction(title: "多选", image: UIImage(systemName: "checkmark.circle")) { _ in
                self.parent.onMultiSelect()
            })
            children.append(UIAction(title: "大爆炸", image: UIImage(systemName: "burst.fill")) { _ in
                self.parent.onBigBang()
            })

            // v3.0.8：移除「选择文本」——已有「复制选中」（长按选区直接复制），该入口冗余
            // （原 v2.0.127 选中手柄功能：系统原生长按已有文本选择手柄，无需重复入口）

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
