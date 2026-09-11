// MARK: - Hermes捷径面板 + 快捷指令面板（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - v2.0.96 Hermes 捷径面板（官方斜杠命令 + 功能注释，点击填充输入框）

struct HermesShortcutSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // 官方命令（hermes-agent 文档）：命令 + 中文功能注释
    private let items: [(cmd: String, desc: String)] = [
        ("/help", "查看全部可用命令"),
        ("/new", "开启全新会话（清空上下文）"),
        ("/model deepseek-v4-flash", "切换模型（如 deepseek-v4-flash）"),
        ("/compress", "压缩当前上下文，节省 token"),
        ("/memory", "查看与管理 AI 记忆"),
        ("/skills", "浏览、搜索、安装技能"),
        ("/skill <名称>", "加载指定技能到当前会话"),
        ("/cron", "定时任务管理（查看/创建/暂停）"),
        ("/voice on", "开启语音对话模式"),
        ("/voice off", "关闭语音模式"),
        ("/undo", "撤销上一轮对话"),
        ("/title <名称>", "给当前会话命名"),
        ("/usage", "查看 Token 用量统计"),
        ("/status", "查看会话与系统状态"),
        ("/personality <名称>", "切换 AI 人格"),
        ("/reasoning high", "设置思考深度（none/low/medium/high）"),
        ("/background <任务>", "后台运行长任务（不阻塞对话）"),
        ("/queue <任务>", "排队等待下一轮处理"),
        ("/fast", "切换优先快速处理"),
        ("/resume <名称>", "恢复历史会话"),
        ("/sethome", "把当前聊天设为默认投递位置"),
        ("/update", "更新 Hermes 到最新版"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.cmd) { item in
                    Button {
                        onPick(item.cmd)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.cmd)
                                .font(.system(size: Typography.subhead, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Text(item.desc)
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Hermes 捷径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

// MARK: - v2.0.43 快捷指令面板（常用 prompt 模板，点击填充输入框）

struct QuickPromptSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    // v3.0.6 fix：知识库快捷指令仅本地 AI 显示（云端无）；默认含，ChatView 按模式传
    var includeKB: Bool = true

    private var prompts: [(icon: String, name: String, prompt: String)] {
        var list: [(icon: String, name: String, prompt: String)] = [
            ("character.bubble", "翻译", "请将以下内容翻译成英文（保留原意）：\n"),
            ("list.bullet.rectangle", "总结", "请用 3-5 条要点总结以下内容：\n"),
            ("pencil.and.outline", "润色", "请润色以下文字，使其更通顺、专业、简洁：\n"),
            ("doc.text", "写周报", "请根据以下工作内容生成一份结构化周报：\n"),
            ("chevron.left.forwardslash.chevron.right", "写代码", "请实现以下功能，给出完整代码并简要解释：\n"),
            ("curlybraces", "解释代码", "请逐段解释以下代码的作用和逻辑：\n"),
            ("lightbulb", "头脑风暴", "请围绕以下主题给出 5 个有创意的点子：\n"),
            ("checklist", "待办清单", "请把以下内容整理成清晰的待办清单：\n"),
            ("textformat", "取标题", "请为以下内容取 3 个简洁贴切的标题：\n"),
            ("person.2", "角色扮演", "请扮演一个资深嵌入式硬件工程师，回答以下问题：\n"),
        ]
        // v2.0.104b：知识库快捷指令（@知识库 前缀触发知识库检索问答）——仅本地 AI 有
        if includeKB {
            list.append(("books.vertical.fill", "知识库", "@知识库 "))
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快捷指令")
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(prompts, id: \.name) { p in
                        Button {
                            onPick(p.prompt)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: p.icon)
                                    .font(.system(size: Typography.headline))
                                    .foregroundStyle(Color.accentColor)
                                Text(p.name)
                                    .font(.system(size: Typography.subhead, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

