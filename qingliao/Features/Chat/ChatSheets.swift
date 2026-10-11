// MARK: - Hermes捷径面板 + 快捷指令面板（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - v2.0.96 Hermes 捷径面板（官方斜杠命令 + 功能注释，点击填充输入框）

struct HermesShortcutSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // v4.0.121（2026-10-11）：只保留轻聊里**真正生效**的两条——后端 stream_api._worker 就地应答，
    // 不调用模型（实测 0.01s、toolSeq=0）。其余 Hermes CLI 命令（/model /skills /cron /memory…）
    // 在轻聊里不生效：api_server 侧没有斜杠命令拦截，点了只是把文本发给模型自由发挥
    // （线上实测 /new 被当普通消息跑出 71 步工具 / 23.5 分钟），属「可见入口不可用」，已下线。
    // 等价功能都在 App 内：模型→设置·模型管理，记忆→设置·AI 记忆，技能→技能页，定时→任务中心。
    private let items: [(cmd: String, desc: String)] = [
        ("/new", "开启全新会话（清空上下文）"),
        ("/help", "查看轻聊里可用的指令"),
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
                        .padding(.vertical, Spacing.xs)
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
            .padding(.bottom, Spacing.lg)

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
                            .padding(.vertical, Spacing.section)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - v3.9.48 输入栏展开态的「模型快选」（右下角胶囊 → 点一下就切走）

/// 和设置里的「模型管理」(`ModelSheet`) 分工：那张面板管**provider 增删 / 同步 / TTS / 视觉模型**，
/// 这里只管"当场换一个模型接着聊"——选完即写即收起。
/// 数据同源 `ModelProvidersCache`（模型管理每次同步成功都会落这份缓存），
/// 所以本面板**零网络请求**、打开就是列表；从没同步过才只剩去设置那一条路。
/// ⚠️ 写的是主模型两把 key（`qingliao_model` / `qingliao_provider`），与 `ModelSheet.setModel` 同一口径；
///    配了 Agent 模型时它不生效（视觉 > Agent > 主），面板顶部照 `ModelSheet` 的话术把这件事说清楚，
///    不静默骗人。
struct ComposerModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    // 默认值必须与全站其余读点逐字一致（自查清单第 3 条）
    @AppStorage("qingliao_model") private var modelName = "deepseek-v4-flash"
    @AppStorage("qingliao_provider") private var provider = "opencode"
    @AppStorage(UserDefaultsKey.agentModel) private var agentModel = ""

    private let groups: [(id: String, models: [String])]

    init() { groups = ModelProvidersCache.load() }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.box")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("还没有可选的模型")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                        Text("先到 设置 › 模型管理 同步一次模型列表")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !agentModel.isEmpty {
                            Section {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: Typography.subhead))
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("聊天实际使用 Agent 模型：\(agentModel)")
                                            .font(.system(size: Typography.subhead, weight: .medium))
                                        Text("配置了 Agent 模型时优先使用，这里换主模型不生效；可在设置页「Agent 模型」改为跟随主模型")
                                            .font(.system(size: Typography.tiny))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        ForEach(groups, id: \.id) { g in
                            Section(g.id) {
                                ForEach(g.models, id: \.self) { m in
                                    modelRow(m, in: g.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("切换模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func modelRow(_ m: String, in p: String) -> some View {
        Button {
            modelName = m
            provider = p
            Haptics.success()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(p)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if m == modelName && p == provider {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换到模型 \(m)（\(p)）")
    }
}

