import SwiftUI

// v4.0.143 · 工作台「进行项目」
//
// 位置：WorkspaceView 的 LazyVStack 里，夹在「进行中」与「长期目标」之间（父视图挂 .scrollDepth()，
// 本文件内部**不**再挂第二层 —— 同容器叠两层会 0.965² ≈ 0.931，比别的块明显更缩）。
//
// 设计口径（方案图 v1 已与用户对齐）：
//   · 一行一个项目：多彩图标 + 名称 + 状态胶囊 + 版本 + 一行 meta（本批进度 / 最近动作）
//   · 有清单才画进度条；没清单只写「N 项待做」，绝不编百分比
//   · 数据 6 小时没更新 → 卡头标「数据可能过期」，不拿旧快照冒充实时
//   · 点行进详情：本批清单 / 最近提交 / 版本历史 / 仓库位置

/// 项目状态胶囊的配色（单一真源：状态文字 → 前景字色 + 彩色底）。
/// 彩色淡底浓度一律走 `Tint.coloredFill(scheme)`（浅色 0.15 / 深色 0.22），不写字面量
/// —— 全仓真值表禁止裸 0.14/0.15（同屏两种写法，下一轮 grep 只找得到一半）。
enum ProjectStatusStyle {
    static func colors(_ status: String, scheme: ColorScheme) -> (fg: Color, tint: Color) {
        switch status {
        case "开发中": return (Color(hex: 0x4A5AE0), Color(hex: 0x5B6CFF))
        case "待验收": return (Color(hex: 0xC9791B), Color(hex: 0xFFA53D))
        case "已发布": return (Color(hex: 0x1E8A57), Color(hex: 0x2FBF71))
        case "暂停":   return (Color(hex: 0x7B8194), Color(hex: 0x8E94A6))
        case "规划中": return (Color(hex: 0x7A46D8), Color(hex: 0xA66BFF))
        default:       return (Color.secondary, Color.secondary)
        }
    }

    /// 胶囊底：彩色淡底单一真源
    static func background(_ status: String, scheme: ColorScheme) -> Color {
        colors(status, scheme: scheme).tint.opacity(Tint.coloredFill(scheme))
    }
}

extension Color {
    /// #RRGGBB → Color（项目图标底色由采集器下发）
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// "#5B6CFF" → Color；解析失败给蓝紫兜底（不让某个项目配错色就整块空白）
    init(hexString: String) {
        let s = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        self.init(hex: UInt32(s, radix: 16) ?? 0x5B6CFF)
    }
}

struct WorkspaceProjectsSection: View {
    /// v4.0.144：数据由父视图（WorkspaceView）统一拉好再传进来 —— 同「待你处理」的 pendingItems 口径。
    /// 🚨 为什么不再自拉：自拉版把 task 回调挂在「Group + 空态 EmptyView」上，
    /// SwiftUI 空态不会把任何节点插入渲染层 → `.task`/`onAppear` **永不触发** → 首屏永远空
    /// → 整块永久消失（v4.0.143 真机实测「工作台没有进行项目」，后端 projects.json 有数据、接口 200）。
    /// 父级 `if !projects.isEmpty` 门控后，本视图拿到的一定非空，也没有空态生命周期问题。
    let projects: [QLProject]
    let generatedAt: Int
    /// v4.0.145（用户：台账要能手动刷）：卡头刷新按钮 → 父级再拉一次 /api/agent/projects。
    /// 声明顺序在 generatedAt 之后，**实参必须按同一顺序传**（SwiftUI 参数序 = 声明序，CI 才过）。
    let onRefresh: () async -> Void

    @Environment(\.colorScheme) private var scheme

    @State private var detail: QLProject?
    @State private var showAll = false
    /// 刷新中（在飞闸门：防连点重复请求）
    @State private var isRefreshing = false
    /// 图标旋转角度（每次点 +360°，一圈到位；不用无限循环动画，避免请求结束后停不下来）
    @State private var spin: Double = 0

    /// 卡面最多露几行 —— 工作台不是项目看板，别把第一屏撑满（超出走「查看全部」）
    private static let maxRows = 4

    private var visible: [QLProject] { Array(projects.prefix(Self.maxRows)) }
    private var runningCount: Int { projects.filter(\.running).count }
    private var isStale: Bool {
        let now = Int(Date().timeIntervalSince1970)
        return generatedAt > 0 && now - generatedAt > ProjectTime.staleAfter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            rows
            if projects.count > Self.maxRows { allButton }
        }
        .sheet(item: $detail) { p in
            NavigationStack { ProjectDetailView(project: p) }
        }
        .sheet(isPresented: $showAll) {
            NavigationStack { ProjectsAllList(projects: projects) }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text("进行项目")
                .font(.system(size: Typography.body, weight: .bold))
            if runningCount > 0 {
                Text("\(runningCount) 个在做")
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(Color(hex: 0x1E8A57))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(hex: 0x2FBF71).opacity(0.16), in: Capsule())
            }
            Spacer(minLength: Spacing.sm)
            if isStale {
                Text("数据可能过期")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
            // v4.0.145：手动刷新（每 10 分钟有 cron 自动同步，这里是「马上要最新」的入口）
            Button {
                guard !isRefreshing else { return }
                Haptics.tap()
                isRefreshing = true
                withAnimation(.easeInOut(duration: 0.55)) { spin += 360 }
                Task {
                    await onRefresh()
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x22C3B0))
                    .rotationEffect(.degrees(spin))
                    .opacity(isRefreshing ? 0.55 : 1)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新进行项目")
        }
    }

    // MARK: - 列表

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, p in
                Button {
                    Haptics.tap()
                    detail = p
                } label: {
                    row(p)
                }
                .buttonStyle(.plain)
                if idx < visible.count - 1 {
                    Divider().opacity(0.5).padding(.leading, 50)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private func row(_ p: QLProject) -> some View {
        HStack(spacing: Spacing.xl) {
            Text(p.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 34, color: Color(hexString: p.colorHex)))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                titleLine(p)
                Text(metaLine(p))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            trailing(p)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .contentShape(Rectangle())
    }

    private func titleLine(_ p: QLProject) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(p.name)
                .font(.system(size: Typography.subhead + 2, weight: .medium))
                .lineLimit(1)
            if !p.status.isEmpty {
                Text(p.status)
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(ProjectStatusStyle.colors(p.status, scheme: scheme).fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(ProjectStatusStyle.background(p.status, scheme: scheme), in: Capsule())
            }
            if p.running {
                Circle()
                    .fill(Color(hex: 0x2FBF71))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func trailing(_ p: QLProject) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(p.versionText)
                .font(.system(size: Typography.tiny, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(ProjectTime.ago(p.lastCommitAt))
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
        }
    }

    /// 一行 meta：本批剩余 → 下一步 → 未提交改动，最多两段（行窄，宁少不多）
    private func metaLine(_ p: QLProject) -> String {
        var parts: [String] = []
        if p.hasProgress {
            parts.append("本批 \(p.done)/\(p.total)")
        } else if !p.batchTitle.isEmpty {
            parts.append(p.batchTitle)
        }
        if !p.nextStep.isEmpty {
            parts.append("下一步：\(p.nextStep)")
        } else if !p.lastCommitText.isEmpty {
            parts.append(p.lastCommitText)
        }
        if p.dirtyCount > 0 { parts.append("改动 \(p.dirtyCount) 个文件") }
        return parts.prefix(2).joined(separator: " · ")
    }

    private var allButton: some View {
        Button {
            Haptics.tap()
            showAll = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("查看全部 \(projects.count) 个项目")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: Typography.tiny, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
    }

    // MARK: - 数据（v4.0.144：拉取上移到 WorkspaceView.loadProjects，空态由父级门控）
}

// MARK: - 全部项目列表

struct ProjectsAllList: View {
    let projects: [QLProject]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(projects) { p in
                    NavigationLink {
                        ProjectDetailView(project: p)
                    } label: {
                        simpleRow(p)
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.5).padding(.leading, 50)
                }
            }
            .padding(.vertical, Spacing.xs)
            .pastelCard(cornerRadius: Radius.hero)
            .padding(.horizontal, Spacing.pageInset)
            .padding(.top, Spacing.xxl)
        }
        .navigationTitle("全部项目")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func simpleRow(_ p: QLProject) -> some View {
        HStack(spacing: Spacing.xl) {
            Text(p.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 34, color: Color(hexString: p.colorHex)))
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: Typography.body, weight: .medium))
                Text(p.versionText)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            Text(p.status.isEmpty ? "—" : p.status)
                .font(.system(size: Typography.tiny, weight: .medium))
                .foregroundStyle(ProjectStatusStyle.colors(p.status, scheme: scheme).fg)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(ProjectStatusStyle.background(p.status, scheme: scheme), in: Capsule())
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .contentShape(Rectangle())
    }
}

// MARK: - 详情

struct ProjectDetailView: View {
    let project: QLProject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                head
                if project.hasProgress { progressBlock }
                if !project.batchItems.isEmpty { batchBlock }
                if !project.recentCommits.isEmpty { commitsBlock }
                if !project.recentReleases.isEmpty { releasesBlock }
                repoBlock
            }
            .padding(.horizontal, Spacing.pageInset)
            .padding(.vertical, Spacing.xxl)
        }
        .background(EnvironmentGlowLayers(scheme: scheme))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .presentationDetents([.large])
    }

    private var head: some View {
        HStack(spacing: Spacing.xxl) {
            Text(project.icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 52, color: Color(hexString: project.colorHex)))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(project.name)
                    .font(.system(size: 22, weight: .bold))
                Text("\(project.versionText) · \(ProjectTime.ago(project.lastCommitAt))更新")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            blockTitle(project.batchTitle.isEmpty ? "本批进度" : project.batchTitle)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(Tint.subtle))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hexString: project.colorHex).opacity(0.75),
                                                      Color(hexString: project.colorHex)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * project.progressFraction))
                }
            }
            .frame(height: 7)
            HStack {
                Text("\(project.done) / \(project.total) 项完成")
                Spacer()
                if !project.nextStep.isEmpty { Text("下一步：\(project.nextStep)") }
            }
            .font(.system(size: Typography.tiny))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var batchBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockTitle("清单")
            ForEach(project.batchItems) { item in
                HStack(spacing: Spacing.lg) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(item.done ? Color(hex: 0x2FBF71) : Color.secondary.opacity(0.5))
                    Text(item.title)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(item.done ? Color.secondary : Color.primary)
                        .strikethrough(item.done, color: .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.sm)
            }
        }
        .padding(Spacing.xxl)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private var commitsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockTitle("最近更新")
            ForEach(project.recentCommits.prefix(5)) { c in
                HStack(alignment: .top, spacing: Spacing.lg) {
                    Text(ProjectTime.ago(c.at))
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .leading)
                    Text(c.text)
                        .font(.system(size: Typography.subhead))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.sm)
            }
        }
        .padding(Spacing.xxl)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private var releasesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockTitle("版本历史")
            ForEach(project.recentReleases.prefix(5)) { r in
                HStack(alignment: .top, spacing: Spacing.lg) {
                    Text(r.version)
                        .font(.system(size: Typography.tiny, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProjectTime.ago(r.at))
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                        if !r.note.isEmpty {
                            Text(r.note)
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.sm)
            }
        }
        .padding(Spacing.xxl)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private var repoBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            blockTitle("位置")
            Text(project.repo.isEmpty ? "—" : project.repo)
                .font(.system(size: Typography.tiny, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !project.branch.isEmpty {
                Text("分支 \(project.branch)" + (project.dirtyCount > 0 ? " · \(project.dirtyCount) 个文件未提交" : ""))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private func blockTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: Typography.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, Spacing.xs)
    }
}
