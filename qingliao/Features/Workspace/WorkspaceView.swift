import SwiftUI
// ⚠️ .quickLookPreview 是 QuickLook 框架的 View 扩展，不 import 直接 Archive 编译失败（同 AgentCardFileSection 口径）
import QuickLook

// MARK: - v4.0.108 工作区（dock 第 5 档）
//
// 用户 2026-10-14：「轻聊我想在 dock 加一个 tab 叫工作区」。已拍板口径：
//   · 定位 = **干活工作台**（不是第二个文件管理器）：AI 正在干什么 / 干完的东西放哪 / 还有哪些在等我拍板；
//   · 长期目标（原在生活页）整块搬进来；
//   · 产物库首版带**分类筛选条**。
//
// 本版范围（第一批 = dock 打通 + 产物库真实接线）：
//   ① 页级标题行（大标题 + 副标题 + 右侧胶囊）；
//   ② 进行中 → 复用任务中心（`/api/agent/tasks/active` 那套全在 TaskCenterView 里，**零后端改动**）；
//   ③ 产物库 → 直接列后端**只读别名根** `office/`（= office-mcp 容器的 /data/docs，AI 生成的
//      Word/Excel/PPT/PDF 就落在那儿；v4.0.104 起 files_api.resolve_path 已支持该别名根，
//      实测 `/api/files/list?path=office` 可列）。走现成的 `RemoteFiles`（下载 / 落盘 / 失败文案单一真源）；
//      子目录（office-mcp 会按日期建目录）可进入，顶部有返回上级。
// 下一批：长期目标搬移（含生活页那块的处理）+「待你处理」聚合 + 工具四格。
// 本页宁缺勿占位：没有实现的块**不摆空壳**。
//
// 视觉口径（用户 2026-10-14：「视觉上对齐其他 tap，卡片圆角统一 22」）——五条，逐条对着仓内既有页抄：
//   · 页头 = `PageHeader` + `.safeAreaBar(edge: .top)`（与生活页 v4.0.61 / 看板页 v4.0.62 **逐字同款**；
//     本页此前是自绘 HStack 标题行 = 唯一一处不入这一口径的 tab 页）；
//   · 页底 = `.background(EnvironmentGlowLayers(scheme:))`（聊天 / 会话 / 生活 / 看板 / 设置五页同源，
//     工作区是第 6 个接页底的 tab）；
//   · 卡底 = `.pastelCard(cornerRadius: Radius.hero)`（全站卡面单一出口：淡彩玻璃 + 0.8pt 描边；此前本页
//     用的是裸 `Color.secondary.opacity(Tint.faint)` 灰底 = 与全站两种观感）；
//   · 卡片圆角 = **统一 `Radius.hero`(22)**（用户精确值正好落在既有令牌档上：卡内行卡、空态卡、提示卡、
//     返回上一级一律 22）；
//   · 行首图标底 = 全站 `BadgeShell`（v4.0.83 用户口径「小图标统一用圆角多彩图标」= 实色底 + 白符号；
//     此前是淡底 + 彩符号，是全站唯一一处不入该口径的列表）；
//   · 页头右侧胶囊 = `pill(.topBar)`（顶栏/工具条档：subhead + h14/v7；页头属顶栏，不用页级栏目头的 tiny 档）。
// ⚠️ 例外：「卡片圆角 22」只针对卡面容器。`BadgeShell` 的 28pt 图标底板**不是卡片**（圆角 = 0.305×边长
//    ≈ 8.5，几何只此一处）；筛选 chip 与各类胶囊一律 `Capsule()`，都不在圆角口径内。
struct WorkspaceView: View {
    /// tab 激活态（由 DockTabView 传）——只在激活时拉产物，避免 TabView 预建时白跑请求
    var isActive: Bool = true

    @Environment(AuthStore.self) private var auth
    /// 页底环境渐变用（与生活 / 看板页同款：浅深各一套，`EnvironmentGlowLayers` 自带兜底色）
    @Environment(\.colorScheme) private var colorSchemeEnv

    /// 产物根别名（后端 `QL_EXTRA_ROOTS` 的别名，勿改成绝对路径）
    private static let artifactRoot = "office"

    // MARK: 产物库状态
    @State private var entries: [RemoteFileEntry] = []
    /// 面包屑栈（相对 office/ 根的各层目录名；空 = 根）
    @State private var dirStack: [String] = []
    @State private var loading = false
    /// 列表级失败（拉不到目录）
    @State private var failureText = ""
    /// 动作级失败（下载/预览失败），与列表失败分开，免得盖掉已取到的列表
    @State private var actionError = ""
    @State private var filter: WorkspaceArtifactFilter = .all
    @State private var quickLookURL: URL?
    /// 正在下载的产物 path（在飞闸门：防狂点重复下载）
    @State private var preparingPath = ""

    // MARK: 任务中心
    @State private var showTaskCenter = false

    /// 当前目录（相对 office/ 根；空 = 根）
    private var currentPath: String { dirStack.joined(separator: "/") }

    /// 请求用的路径参数（后端 resolve_path 认 `office/xxx` 别名形态）
    private var requestPath: String {
        currentPath.isEmpty ? Self.artifactRoot : Self.artifactRoot + "/" + currentPath
    }

    private var visibleFiles: [RemoteFileEntry] {
        entries.filter { !$0.isDir && filter.match($0.name) }
    }
    private var visibleDirs: [RemoteFileEntry] { entries.filter(\.isDir) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                activeCard
                artifactBoard
            }
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.section * 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await load() }
        .task(id: isActive) { if isActive && entries.isEmpty { await load() } }
        .quickLookPreview($quickLookURL)
        .fullScreenCover(isPresented: $showTaskCenter) { TaskCenterView() }
        // 页头：挂系统 `safeAreaBar`（滚动时内容在页头下沿走系统级模糊/渐隐），与生活页 / 看板页同款。
        // 口径见文件头「视觉口径」第 1 条；自绘标题行已整块退役，别再往滚动内容里塞回一行标题。
        .safeAreaBar(edge: .top) {
            PageHeader(title: "工作区",
                       subtitle: "AI 替我干的活 · 产物 \(visibleFiles.count) 个",
                       trailing: AnyView(taskCenterPill))
        }
        // 页底：与聊天 / 会话 / 生活 / 看板 / 设置五页同源同法。纯视觉层：垫在整页最底层、
        // 卡片玻璃透出彩底；不改布局、不拦手势。
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
    }

    // MARK: - 页头右侧胶囊

    /// 页头右上唯一入口。胶囊口径 = 顶栏 / 工具条档（`pill(.topBar)`：subhead + h14/v7）——
    /// 页头属顶栏，不用页级栏目头的 tiny 档（`pill(.page)`）。
    /// ⚠️ 页头本体走 `PageHeader` + `.safeAreaBar`（见 body），本视图不再自绘标题行。
    private var taskCenterPill: some View {
        Button {
            Haptics.tap()
            showTaskCenter = true
        } label: {
            Text("任务中心").pill(.topBar)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - 进行中

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("进行中")
            Button {
                Haptics.tap()
                showTaskCenter = true
            } label: {
                HStack(spacing: Spacing.md) {
                    badge("arrow.triangle.2.circlepath", tint: .accentColor)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("正在干的活")
                            .font(.system(size: Typography.subhead, weight: .medium))
                        Text("进行中任务、实时进度、停止都在任务中心")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Spacing.sm)
                    Text("打开")
                        .font(.system(size: Typography.tiny, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(Spacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pastelCard(cornerRadius: Radius.hero)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 产物库

    private var artifactBoard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("产物")
            filterBar
            if !actionError.isEmpty {
                Text(actionError)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            artifactCard
        }
    }

    /// 分类筛选条。⚠️ 筛选 chip **不在** `PillSize` 三档口径内（Pill.swift 头注释明确排除），
    /// 保持自绘 `Capsule()` 与 `Tint` 淡底 —— 这两条都不是「卡片」，不参与 22 圆角口径。
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(WorkspaceArtifactFilter.allCases) { f in
                    Button {
                        Haptics.tap()
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.system(size: Typography.caption, weight: .semibold))
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.xs)
                            .background(f == filter
                                        ? Color.accentColor.opacity(Tint.soft)
                                        : Color.secondary.opacity(Tint.faint),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    @ViewBuilder
    private var artifactCard: some View {
        if loading && entries.isEmpty {
            hint("正在取产物…", spinning: true)
        } else if !failureText.isEmpty {
            hint(failureText, tone: .red)
        } else if visibleDirs.isEmpty && visibleFiles.isEmpty {
            emptyHint
        } else {
            VStack(spacing: Spacing.sm) {
                if !dirStack.isEmpty { backRow }
                ForEach(visibleDirs) { d in dirRow(d) }
                ForEach(visibleFiles) { f in artifactRow(f) }
            }
        }
    }

    /// 空态：根目录空（AI 还没产出过）与子目录空分开说，别让用户以为坏了
    @ViewBuilder
    private var emptyHint: some View {
        if currentPath.isEmpty {
            VStack(spacing: Spacing.xs) {
                Text("还没有 AI 生成的文档")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text("在聊天里让 AI 做一份 Word / Excel / PPT / PDF，成品会出现在这里")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity)
            .pastelCard(cornerRadius: Radius.hero)
        } else {
            hint(filter == .all ? "这一层是空的" : "这一层没有「\(filter.rawValue)」类型的文件")
        }
    }

    /// 返回上一级：做成与目录行 / 产物行同族的**行卡**（22 圆角），右侧显示当前目录 ——
    /// 原先是全宽灰胶囊，和上下两张卡圆角/材质都不一路（用户口径「卡片圆角统一 22」后不再留特例）。
    private var backRow: some View {
        Button {
            Haptics.tap()
            if !dirStack.isEmpty { dirStack.removeLast() }
            entries = []
            Task { await load() }
        } label: {
            HStack(spacing: Spacing.md) {
                badge("arrow.up.left", tint: Color(uiColor: .systemGray))
                Text("返回上一级")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Spacer(minLength: Spacing.sm)
                Text(currentPath)
                    .font(.system(size: Typography.tiny))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard(cornerRadius: Radius.hero)
        }
        .buttonStyle(.plain)
    }

    private func dirRow(_ d: RemoteFileEntry) -> some View {
        Button {
            Haptics.tap()
            dirStack.append(d.name)
            entries = []
            Task { await load() }
        } label: {
            HStack(spacing: Spacing.md) {
                badge("folder.fill", tint: .orange)
                Text(d.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard(cornerRadius: Radius.hero)
        }
        .buttonStyle(.plain)
    }

    private func artifactRow(_ f: RemoteFileEntry) -> some View {
        HStack(spacing: Spacing.md) {
            badge(iconName(f.name), tint: .accentColor)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(f.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeText(f))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            if preparingPath == f.path {
                ProgressView().controlSize(.small)
            } else {
                Button { open(f) } label: {
                    Text("查看")
                        .font(.system(size: Typography.tiny, weight: .semibold))
                        .lineLimit(1)
                }
                .glassPillStroke()
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(cornerRadius: Radius.hero)
    }

    // MARK: - 小组件

    /// 栏目头标题：口径 = 生活页各板块头（`Typography.body` 粗体 + 右侧胶囊），别用更大字号
    /// （本页此前用 `Typography.title`/semibold，比全站栏目头大一档 = 视觉不齐的一处来源）。
    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: Typography.body, weight: .bold))
    }

    /// 行首图标底（**不是卡片**）：几何/配色只此一处 = `BadgeShell`（v4.0.83 用户口径
    /// 「小图标统一用圆角多彩图标」：实色底 + 白符号）；28pt 档 → 圆角 ≈ 8.5、符号 14pt。
    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28 * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .modifier(BadgeShell(size: 28, color: tint))
    }

    private func hint(_ text: String, spinning: Bool = false, tone: Color? = nil) -> some View {
        HStack(spacing: Spacing.sm) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(tone ?? Color.secondary)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .center)
        .pastelCard(cornerRadius: Radius.hero)
    }

    private func iconName(_ name: String) -> String {
        let e = RemoteFiles.ext(name)
        if RemoteFiles.imageExts.contains(e) { return "photo.fill" }
        switch e {
        case "doc", "docx", "md", "txt", "rtf": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        case "ppt", "pptx", "key": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }

    private func sizeText(_ f: RemoteFileEntry) -> String {
        let time = RemoteFiles.modifiedText(f.mtime)
        guard f.size > 0 else { return time }
        return RemoteFiles.humanSize(f.size) + " · " + time
    }

    // MARK: - 数据

    /// 拉当前目录（走 files_api 的别名根；`entries` 复位由调用方负责，避免旧目录内容一闪）
    @MainActor
    private func load() async {
        loading = true
        failureText = ""
        do {
            let (data, resp) = try await auth.request("/api/files/list?path="
                                                      + RemoteFiles.queryEncoded(requestPath))
            guard (200..<300).contains(resp.statusCode) else {
                failureText = "取产物失败（HTTP \(resp.statusCode)）"
                entries = []
                loading = false
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // ⚠️ parent 必须传 requestPath（带 `office/` 别名根前缀），**不能传 currentPath**：
            //    parseEntries 拿 parent 拼出的 entry.path 会原样交给下载口
            //    （/api/files/download?path=…），而后端 resolve_path 只对 `office` / `office/xxx`
            //    走别名根，少了前缀会回落到 uploads/ 与 ROOT → 404「文件不存在」。
            //    （v4.0.108 审查抓出：本地预检与 CI 全绿、只有真机点「查看」才暴露。）
            //    面包屑仍走 currentPath / dirStack，与本行无耦合。
            entries = RemoteFiles.parseEntries(obj?["entries"], parent: requestPath)
            loading = false
        } catch {
            failureText = RemoteFiles.failureReason(error)
            entries = []
            loading = false
        }
    }

    /// 下载 → QuickLook 预览（下载/落盘/失败文案全走 RemoteFiles 单一真源）
    private func open(_ f: RemoteFileEntry) {
        guard preparingPath != f.path else { return }
        Haptics.tap()
        preparingPath = f.path
        actionError = ""
        Task { @MainActor in
            let r = await RemoteFiles.fetchToTemp(auth, path: f.path, name: f.name)
            preparingPath = ""
            switch r {
            case .success(let url): quickLookURL = url
            case .failure(let reason): actionError = reason.message
            }
        }
    }
}

/// 产物库分类筛选（用户拍板：首版就要筛选条）
enum WorkspaceArtifactFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case word = "Word"
    case excel = "Excel"
    case ppt = "PPT"
    case pdf = "PDF"
    case image = "图片"

    var id: String { rawValue }

    /// 按扩展名归类（与 AgentCard.File 的类型口径对齐）
    func match(_ name: String) -> Bool {
        let e = RemoteFiles.ext(name)
        switch self {
        case .all:   return true
        case .word:  return ["doc", "docx", "md", "txt", "rtf"].contains(e)
        case .excel: return ["xls", "xlsx", "csv"].contains(e)
        case .ppt:   return ["ppt", "pptx", "key"].contains(e)
        case .pdf:   return e == "pdf"
        case .image: return RemoteFiles.imageExts.contains(e)
        }
    }
}
