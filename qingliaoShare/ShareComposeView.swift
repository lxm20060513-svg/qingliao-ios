import SwiftUI

/// 分享扩展的可见界面。用户拍板「所有可见 UI 入口必须可用，不接受占位」，所以每个元素都有实际作用：
///   · **内容预览**：文本/链接按原文显示（截断，但发出的始终是完整内容）；图片显示真实缩略图
///     —— 发送前用户能看清「要发什么」；
///   · **补充说明输入框**：真实输入，随消息一起发出（空 = 只发内容本身）；
///   · **发送到轻聊 / 取消** 两个按钮；
///   · **结果如实显示**：已交给轻聊（短暂提示后自动收起）/ 已放进剪贴板（iOS 18 起扩展拉不起宿主
///     App，这时**明说**要手动打开轻聊，绝不给一个假的「已发送」）。
struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel
    let onCancel: () -> Void
    let onFinish: () -> Void

    /// 视觉档位：扩展是独立 target，主 App 的 Theme 令牌文件**没有**编进来（与挂件 target 同款做法：
    /// 不把整套令牌为一个卡片搬进扩展），所以这里用自己的具名常量，不散写字面量。
    private enum Layout {
        static let padding: CGFloat = 16
        static let gap: CGFloat = 12
        static let corner: CGFloat = 16
        static let previewMaxHeight: CGFloat = 160
        static let previewLines = 6
        static let buttonHeight: CGFloat = 46
    }
    private enum FontSize {
        static let title: CGFloat = 17
        static let body: CGFloat = 15
        static let caption: CGFloat = 13
    }
    /// 主按钮颜色：与主 App 的强调色同族（扩展里不引 Theme，颜色只此一处）
    private let accent = Color(red: 0.36, green: 0.62, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.gap) {
            header
            switch model.phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取分享内容…")
                        .font(.system(size: FontSize.body))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                cancelButton
            case .empty(let why):
                Text(why)
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                cancelButton
            case .ready, .sending:
                preview
                noteField
                actionButtons
            case .handedOff:
                statusLine(icon: "checkmark.circle.fill",
                           tint: .green,
                           text: "已交给轻聊，正在切换…")
            case .needsManualOpen(let why):
                statusLine(icon: "exclamationmark.circle.fill",
                           tint: .orange,
                           text: why)
                Button {
                    onFinish()
                } label: {
                    Text("知道了，去打开轻聊")
                        .font(.system(size: FontSize.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)   // 分享面板的材质由系统给，这里只保证不是纯色块
    }

    // MARK: - 部件

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: FontSize.title))
                .foregroundStyle(accent)
            Text("发送到轻聊")
                .font(.system(size: FontSize.title, weight: .semibold))
            Spacer()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: Layout.previewMaxHeight)
                .clipShape(RoundedRectangle(cornerRadius: Layout.corner, style: .continuous))
        }
        if !model.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.text)
                    .font(.system(size: FontSize.body))
                    .lineLimit(Layout.previewLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 截断只影响「显示」：发出去的是完整内容。写清楚，免得用户以为被截了
                Text("发送的是完整内容")
                    .font(.system(size: FontSize.caption))
                    .foregroundStyle(.tertiary)
            }
        } else if model.image != nil {
            Text("发送这张图片")
                .font(.system(size: FontSize.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private var noteField: some View {
        TextField("补充说明（可选，会跟内容一起发）", text: $model.note, axis: .vertical)
            .font(.system(size: FontSize.body))
            .lineLimit(1...3)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: Layout.corner, style: .continuous))
    }

    private var actionButtons: some View {
        HStack(spacing: Layout.gap) {
            Button {
                onCancel()
            } label: {
                Text("取消")
                    .font(.system(size: FontSize.body, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
            }
            .buttonStyle(.bordered)
            .disabled(model.phase == .sending)

            Button {
                Task { await model.send() }
            } label: {
                HStack(spacing: 6) {
                    if model.phase == .sending {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.phase == .sending ? "发送中…" : "发送")
                        .font(.system(size: FontSize.body, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(model.phase == .sending)
        }
    }

    private var cancelButton: some View {
        Button {
            onCancel()
        } label: {
            Text("取消")
                .font(.system(size: FontSize.body, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
        }
        .buttonStyle(.bordered)
    }

    private func statusLine(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: FontSize.title))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: FontSize.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
