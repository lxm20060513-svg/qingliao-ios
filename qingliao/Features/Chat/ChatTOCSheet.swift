import SwiftUI

// MARK: - 消息气泡

// MARK: - v3.0.27 章节列表弹窗（纯静态章节标题展示，不做大纲导航）
// v4.0.12：WelcomeSuggestion 结构随欢迎页 4 颗建议胶囊一并删除（唯一使用者已下线，无残留死代码）。

struct TOCSheet: View {
    let headers: [MarkdownRenderer.TOCItem]
    // v3.4.25：章节点击导航回调——传入后行可点，滚动到对应消息并高亮（复用 highlightTarget 机制）
    var onNavigate: ((MarkdownRenderer.TOCItem) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(headers) { item in
                    HStack(spacing: 8) {
                        ForEach(0..<item.level, id: \.self) { _ in
                            Color.clear.frame(width: 8)
                        }
                        Circle()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .font(.system(size: item.level == 1 ? 16 : (item.level == 2 ? 14 : 13),
                                          weight: item.level == 1 ? .bold : .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        if onNavigate != nil {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: Typography.caption, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // v3.4.25：真导航（此前注释自认"点击导航不可靠"，highlightTarget 机制已稳定后启用）
                        onNavigate?(item)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("章节列表")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.plain)
        }
    }
}
