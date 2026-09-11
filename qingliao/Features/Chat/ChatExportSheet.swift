// MARK: - 会话导出面板（格式选择 sheet，v3.4.28）
// 点「导出会话记录」/ 归档提示条「归档」→ 弹出本面板，选格式后走系统 fileExporter。
// 格式与图片能力：PDF/HTML 真图嵌入；txt/md 占位文字。

import SwiftUI
import UniformTypeIdentifiers

struct ChatExportSheet: View {
    let title: String
    let messages: [ChatMessage]
    let onExport: (ChatExportFormat) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // 会话概况
                Section {
                    HStack(spacing: 14) {
                        overviewItem(icon: "bubble.left.and.bubble.right",
                                     color: .blue, value: "\(messages.count)", label: "消息")
                        overviewItem(icon: "photo",
                                     color: .green, value: "\(imageCount)", label: "图片")
                        overviewItem(icon: "doc.text",
                                     color: .orange, value: "\(textMsgCount)", label: "文字")
                    }
                    .padding(.vertical, 4)
                }

                Section("选择导出格式") {
                    formatRow(format: .pdf,
                              icon: "doc.richtext", tint: .red,
                              name: "PDF 文档", desc: "图片原样嵌入 · 适合打印存档",
                              badge: imageCount > 0 ? "含图" : nil)
                    formatRow(format: .html,
                              icon: "safari", tint: .blue,
                              name: "HTML 网页", desc: "图片内嵌 · 浏览器打开即看",
                              badge: imageCount > 0 ? "含图" : nil)
                    formatRow(format: .markdown,
                              icon: "number", tint: .purple,
                              name: "Markdown (.md)", desc: "结构化排版 · 图片为占位")
                    formatRow(format: .plainText,
                              icon: "doc.plaintext", tint: .gray,
                              name: "纯文本 (.txt)", desc: "最简单通用 · 图片为占位")
                }
            }
            .navigationTitle("导出会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 子视图

    private var imageCount: Int {
        messages.filter { $0.imageDataURL != nil && !($0.imageDataURL ?? "").isEmpty }.count
    }
    private var textMsgCount: Int {
        messages.filter { $0.imageDataURL == nil || ($0.imageDataURL ?? "").isEmpty }.count
    }

    private func overviewItem(icon: String, color: Color, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Typography.body))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: Typography.body, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatRow(format: ChatExportFormat, icon: String, tint: Color,
                           name: String, desc: String, badge: String? = nil) -> some View {
        Button {
            dismiss()
            onExport(format)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: Typography.headline))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: Typography.body, weight: .medium))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: Typography.tiny, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                        }
                    }
                    Text(desc)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 导出格式

enum ChatExportFormat {
    case pdf
    case html
    case markdown
    case plainText
}
