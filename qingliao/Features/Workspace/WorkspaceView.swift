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
// v4.0.109（第二批 = 用户 2026-10-14 的四条：「工作区右上角的任务中心胶囊删掉」+
// 「长期目标从生活页搬进工作台 +「待你处理」聚合 + 工具格」）：
//   ① 页头右上「任务中心」胶囊**删除** —— 入口只留「进行中」那张卡（用户口径：那一颗多余）；
//   ② 长期目标**整块搬进来**（`GoalsSection()` 原样复用，含它的页级浮层宿主 `GoalsGlassLayerHost`）；
//      生活页对应板块**已拿掉**（`LifeSection.goals` case 一并删除，含「自定义板块」列表项）；
//   ③ 「待你处理」聚合 —— AI 问过、我还没答的问题卡（跨会话），真源与解析见 `Core/WorkspacePendingKit.swift`
//      （走 `/api/sessions/list`，**零后端改动**）；没有待答卡时这一块**不渲染**（宁缺勿占位）；
//   ④ 工具格 —— 知识库 / 网盘文件 / MCP 工具 / 技能库 / 定时任务 / 邮件接入（后两项 v4.0.x 从设置页移入；
//      六格排两行 3+3，单行会挤到 8.8pt，图标见 `toolsBoard` 注释）。
// v4.0.113（用户 2026-10-15「把定时提醒和文件管理从设置移动到工作台的工具里」）：
//   ① 工具格 6 → **8 格**（每行 4 格 → 正好两行排满）：末尾补「定时提醒」(`bell.badge.fill` / pink)
//      与「文件管理」(`folder.fill` / indigo) —— 色沿用设置页原来那两颗，用户认色不认位置；
//   ② 两个 sheet（`QuickReminderSheet` / `FilesManagerSheet`）随入口从设置页`settingsCold*`
//      迁到本页 `workspaceCold1`，`.medium/.large` 两档 detents 与设置页时代逐字同口径；
//   ③ 设置页侧同批撤：两行 SettingRow（+ 分隔线）、两个 @State、两个 `openSearchEntry` case、
//      两条搜索索引（34 → 32）—— 入口搬走而索引留着 = 「搜得到、点下去没这行」。
//   功能本体一行未动：定时提醒仍是 `QuickReminderScheduler`（纯本地系统通知，App 不在也响），
//   聊天页长按气泡「提醒我」用的还是同一个 `QuickReminderSheet`；文件管理仍是上传目录浏览。
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
//   · 页头右侧胶囊：v4.0.109 **已删**（用户要求；原为「任务中心」`pill(.topBar)` 入口，
//     见下面页头那段注释）。`pill(.topBar)` 档本身仍在用（别的地方），只是本页页头不再带胶囊。
// ⚠️ 例外：「卡片圆角 22」只针对卡面容器。`BadgeShell` 的 28pt 图标底板**不是卡片**（圆角 = 0.305×边长
//    ≈ 8.5，几何只此一处）；筛选 chip 与各类胶囊一律 `Capsule()`，都不在圆角口径内。
struct WorkspaceView: View {
    /// tab 激活态（由 DockTabView 传）——只在激活时拉产物，避免 TabView 预建时白跑请求
    var isActive: Bool = true
    /// v4.0.109：「待你处理」点进某条会话后，通知宿主切到聊天 tab。
    /// 口径与 `SessionsView.onOpenSession` 一致：**本页只负责把会话装进 ChatStore**（`chat.loadById`），
    /// 「切 tab + 退出会话首页」由宿主 `DockTabView` 做（selected / showSessionHome 都在那边）。
    var onOpenSession: (() -> Void)? = nil
    /// v4.0.115：工作台工具格「会议纪要」—— 交给宿主（DockTabView）走**与长按球菜单同一条路**
    /// （先切聊天页再弹全屏页，实现见 DockTabView 的 openMinutesPage）。
    /// 🚨 本页**不自己 present**：那条路上 ChatView 不在视图树，整理完那张卡由 MeetingMinutesView post、
    /// 唯一接收方是 ChatView 的 onReceive → 卡静默丢失，而页内还显示「已放进会话」（v4.0.115 审查 P1）。
    var onOpenMinutes: (() -> Void)? = nil

    @Environment(AuthStore.self) private var auth
    /// v4.0.109：待你处理点进会话 → 该会话标已读（口径同 `SessionsView.open`）
    @Environment(ChatStore.self) private var chat
    /// 页底环境渐变用（与生活 / 看板页同款：浅深各一套，`EnvironmentGlowLayers` 自带兜底色）
    @Environment(\.colorScheme) private var colorSchemeEnv

    /// 产物根别名（后端 `QL_EXTRA_ROOTS` 的别名，勿改成绝对路径）
    /// v4.0.114（用户「AI 生产的其他产物也要加到产物里」）：**单根 → 双根**。
    ///   office    = AI 成品**文档**（office-mcp 写的 Word/Excel/PPT/PDF）
    ///   artifacts = AI 的**其它产物**（截图/图/代码/数据/压缩包/音频…）
    /// 根层把两个根**合并成一个列表**（用户不必知道东西落在哪个根），进子目录后只列当前那个根。
    private static let artifactRoots = ["office", "artifacts"]

    // MARK: 产物库状态
    @State private var entries: [RemoteFileEntry] = []
    /// 面包屑栈（相对**所在根**的各层目录名；空 = 该根顶层）
    @State private var dirStack: [String] = []
    /// 当前所在的根别名；**空串 = 根层**（两根合并显示的那一层）
    @State private var currentRoot = ""
    @State private var loading = false
    /// 列表级失败（拉不到目录）
    @State private var failureText = ""
    /// 动作级失败（下载/预览失败），与列表失败分开，免得盖掉已取到的列表
    @State private var actionError = ""
    @State private var filter: WorkspaceArtifactFilter = .all
    // v4.0.114（用户「产物库内容也可以删除吧」·方案 3）：⋯ 单删 + 选择态批量。
    // ⚠️ 后端 /api/files/delete 是**真删**（rmtree / os.remove，无回收站）→ 一律二次确认。
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var deleteConfirmText = ""
    @State private var confirmDelete = false
    @State private var deleteTargets: [RemoteFileEntry] = []
    @State private var quickLookURL: URL?
    /// 正在下载的产物 path（在飞闸门：防狂点重复下载）
    @State private var preparingPath = ""

    // MARK: 任务中心
    @State private var showTaskCenter = false
    // MARK: v4.0.110 进行中卡实时化（本仓 v4.0.108 首版只是静态入口卡，用户报「并没有实时显示」）
    /// 进行中任务（/api/agent/tasks/active，与 TaskCenterView 同一读路径，零后端改动）
    @State private var activeTasks: [AuthStore.ActiveTask] = []
    /// 页面存活期间每 2s 一轮（口径同 TaskCenterView.startActivePolling；tab 切走即停）
    @State private var activeTimer: Timer?
    /// v4.0.110：卡面直接停任务（原口径「停止都在任务中心」→ 用户要求任务卡上就要有停止）
    @State private var stopTarget: AuthStore.ActiveTask?

    // MARK: v4.0.109 待你处理（跨会话未答问题卡）
    @State private var pendingItems: [WorkspacePendingKit.Item] = []
    /// 最多露几行（超出的走页脚汇总）——工作区不是第二个待办中心，别把第一屏撑满
    private static let pendingMaxRows = 3

    // MARK: v4.0.109 工具格入口（v4.0.115 起 9 个）
    @State private var showKB = false
    @State private var showSkills = false
    @State private var showTasks = false   // v4.0.x 从设置页移来的「定时任务」
    @State private var showMail = false    // v4.0.x 从设置页移来的「邮件接入」
    @State private var showCloud = false
    @State private var showMCP = false
    // v4.0.124：第 10 格「Hermes 插件」（已安装 + 官方插件库）
    @State private var showPlugins = false
    @State private var showReminder = false // v4.0.113 从设置页移来的「定时提醒」
    @State private var showFiles = false    // v4.0.113 从设置页移来的「文件管理」

    // MARK: v4.0.143 栏目自定义（排序 + 隐藏）—— key 与生活页 life_section_* 同族
    @AppStorage("workspace_section_order") private var sectionOrderRaw = ""
    @AppStorage("workspace_section_hidden") private var sectionHiddenRaw = ""
    @State private var showSectionEditor = false

    /// 当前目录（相对**所在根**；空 = 该根顶层）
    private var currentPath: String { dirStack.joined(separator: "/") }

    /// 是否在根层（两根合并显示的那一层）
    private var atRootLevel: Bool { currentRoot.isEmpty }

    /// 请求用的路径参数（后端 resolve_path 认 `<别名>/xxx` 形态）；**根层返回空串 = 「拉全部根」**
    private var requestPath: String {
        atRootLevel ? "" : (dirStack.isEmpty ? currentRoot : currentRoot + "/" + currentPath)
    }

    private var visibleFiles: [RemoteFileEntry] {
        entries.filter { !$0.isDir && filter.match($0.name) }
    }
    private var visibleDirs: [RemoteFileEntry] { entries.filter(\.isDir) }

    // MARK: - v4.0.143 栏目顺序 / 显隐（口径逐条对齐生活页 LifeView.orderedSections）

    /// 已存顺序在前；串里没出现的（新增栏目）按 allCases 补后面
    private var orderedSections: [WorkspaceSection] {
        var seen = Set<WorkspaceSection>()
        let saved = sectionOrderRaw.split(separator: ",")
            .compactMap { WorkspaceSection(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        var merged = saved
        for s in WorkspaceSection.allCases where !seen.contains(s) { merged.append(s) }
        return merged
    }
    private var hiddenSections: Set<WorkspaceSection> {
        Set(sectionHiddenRaw.split(separator: ",").compactMap { WorkspaceSection(rawValue: String($0)) })
    }
    private var visibleSections: [WorkspaceSection] {
        let h = hiddenSections
        return orderedSections.filter { !h.contains($0) }
    }

    var body: some View {
        ScrollView {
            // v4.0.117（用户 2026-10-15「生活页这种上下滑动的动效能不能应用到所有页面」→ 拍板「加工作台」）：
            // 六个块挂上生活页那一档滚动层次（`scrollDepth` ＝ 卡片进出视口时 scale 0.965 / opacity 0.75）。
            // 🚨 容器由 `VStack` 改 **`LazyVStack`** 是**必要条件**、不是风格选择：`scrollDepth` 走的是
            //    `scrollTransition`，只在 Lazy 容器里按元素位置算 identity；挂在非 Lazy 的 VStack 上 =
            //    每块**恒为非 identity** → 五个块常驻缩小 + 半透明（与会话列表 List 那个坑同一病根，
            //    `SessionsView.swift:1184` 有实测记录：卡比同屏未挂的卡窄 ~14pt）。改回 VStack = 复发。
            // ⚠️ 只挂这**一层**：工具格内部不许再挂（同容器叠两层 → 0.965² ≈ 0.931 / 0.75² ≈ 0.56，比看板
            //    明显更缩更暗，与「跟看板/生活页同一档层次」的初衷相反）。块数钉在 ql_uitokens 表，加块同步改
            //    （v4.0.143 加「进行项目」：5 → 6）。
            LazyVStack(alignment: .leading, spacing: Spacing.section) {
                // v4.0.143：按用户自定义顺序渲染（排序 / 隐藏；口径同生活页「自定义板块」）。
                // 默认顺序 = WorkspaceSection.allCases：待你处理 → 进行中 → 进行项目 → 长期目标 → 产物库 → 工具格。
                // 「待你处理」原先强行排最上，现在交给用户排（自定义优先；它仍是唯一需要动手的一块）。
                ForEach(Array(visibleSections.enumerated()), id: \.element) { _, section in
                    sectionBody(section)
                }
                sectionEditorEntry
            }
            .padding(.horizontal, Spacing.pageInset)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.section * 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // v4.0.x：系统 .refreshable → 自绘液体杯子下拉刷新（用户定案）
        .pullRefreshCup { await load(); await loadPending() }
        .task(id: isActive) {
            guard isActive else { stopActivePolling(); return }
            // v4.0.110：每次激活都刷新产物（原「仅 entries 为空才拉」= AI 新产物永远不出现的根因：
            // 首次拉过之后列表非空，AI 再生成也永不重拉）。keepOnFailure：静默刷新失败保留旧列表。
            await load(keepOnFailure: true)
            await loadPending()   // 每次进页刷新待答卡：AI 可能刚问过新问题
            startActivePolling()  // v4.0.110：进行中卡实时轮询（本页存活期间）
        }
        .onDisappear { stopActivePolling() }
        // v4.0.110：停止确认（形态逐字同 TaskCenterView：系统 alert，危险确认类不走锚定浮层）
        .alert("停止这个任务？", isPresented: Binding(get: { stopTarget != nil },
                                                  set: { if !$0 { stopTarget = nil } })) {
            Button("停止", role: .destructive) {
                if let t = stopTarget { stopTask(t) }
                stopTarget = nil
            }
            Button("取消", role: .cancel) { stopTarget = nil }
            if let t = stopTarget { Text("「\(t.title)」将被中断，已生成的部分内容会保留。") }
        }
        .quickLookPreview($quickLookURL)
        .fullScreenCover(isPresented: $showTaskCenter, onDismiss: {
            // v4.0.110：任务中心里可能停了任务 / 任务刚结束——回来立刻刷新卡面，不等下一轮 2s
            Task { @MainActor in activeTasks = await auth.fetchActiveTasks() }
        }) { TaskCenterView() }
        // 长期目标的**页级浮层宿主**（v4.0.109 随 GoalsSection 从生活页一起搬来）。
        // ⚠️ 必须挂**整页最外层**（滚动区之外）——挂回 section 那一行里 = 几何被行限制，
        //    浮层又变回「只在卡片大小内弹」（生活页 v4.0.76 备忘录的原坑，勿回退）。
        // AnyView 收类型名：本页同属「启动链 demangler」家族，别把宿主类型名内联进 body（见 ql_typestack 护栏）。
        .overlay { AnyView(GoalsGlassLayerHost()) }
        // 页头：挂系统 `safeAreaBar`（滚动时内容在页头下沿走系统级模糊/渐隐），与生活页 / 看板页同款。
        // 口径见文件头「视觉口径」第 1 条；自绘标题行已整块退役，别再往滚动内容里塞回一行标题。
        // v4.0.109：右上「任务中心」胶囊已删（用户要求）——`PageHeader` 的 trailing 传空即可，别补别的按钮。
        .safeAreaBar(edge: .top) {
            PageHeader(title: "工作台",
                       subtitle: "AI 替我干的活 · 产物 \(visibleFiles.count) 个")
        }
        // 页底：与聊天 / 会话 / 生活 / 看板 / 设置五页同源同法。纯视觉层：垫在整页最底层、
        // 卡片玻璃透出彩底；不改布局、不拦手势。
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
        // v4.0.109：工具格的 sheet 下沉背景层冷组（防主 body 类型栈膨胀；口径同设置页 settingsColdN）。
        // v4.0.x：4→6 格后已含定时任务/邮件接入两个 sheet。
        // 拆多组是因为「每组顶层修饰器 ≤4 条」的深度上限（见 scripts/ql_wstools/truth_table_wstools.swift）。
        .background(workspaceCold1())
        .background(workspaceCold2())
        .background(workspaceCold3())
    }

    // MARK: - v4.0.143 栏目渲染

    /// 栏目 → 视图。顺序由 visibleSections 定，这里只管映射；每块各挂一次滚动层次
    /// （ql_uitokens 表按字面计数钉「恰好 6 处」，注释里别写带点括号的修饰器名，会被算进去）。
    @ViewBuilder
    private func sectionBody(_ section: WorkspaceSection) -> some View {
        switch section {
        case .pending:
            // 有才显示：没有待答卡就整块不占位（与隐藏不同，这是数据态而非用户设置）
            if !pendingItems.isEmpty { pendingBoard.scrollDepth() }
        case .active:
            activeCard.scrollDepth()
        case .projects:
            // 空态自己在 WorkspaceProjectsSection 里吞掉（EmptyView），不占版面
            WorkspaceProjectsSection().scrollDepth()
        case .goals:
            // v4.0.109：长期目标整块从生活页搬来（原样复用 GoalsSection，未改它一行）
            GoalsSection().scrollDepth()
        case .artifacts:
            artifactBoard.scrollDepth()
        case .tools:
            toolsBoard.scrollDepth()
        }
    }

    /// v4.0.143：页底「自定义栏目」入口 —— 与生活页 sectionEditorEntry 同款低调样式
    private var sectionEditorEntry: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(hiddenSections.isEmpty ? "自定义栏目（排序 / 隐藏）"
                                        : "自定义栏目 · 已隐藏 \(hiddenSections.count) 个栏目")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .pastelCard()
        .contentShape(Rectangle())
        .tapButton { showSectionEditor = true }
    }

    // MARK: - 进行中

    /// v4.0.110：卡面实时化——有任务时显示当前任务标题 + 进度摘要 + 转圈 + 停止按钮；
    /// 无任务回落静态空态。点卡仍进任务中心（完整列表在那里），停止可直接在卡上做。
    /// 停止判据与任务中心同源（仅 kind=stream 且 running）；bg 作业后端无 cancel 端点，不亮停止。
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
                        if let first = activeTasks.first {
                            Text(first.title.isEmpty ? "正在处理" : first.title)
                                .font(.system(size: Typography.subhead, weight: .medium))
                                .lineLimit(1)
                            Text(activeCardSubtitle(first))
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("正在干的活")
                                .font(.system(size: Typography.subhead, weight: .medium))
                            Text("暂无进行中的任务，点开看任务中心")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Spacing.sm)
                    // 有任务才转圈：空态不摆假进度
                    if !activeTasks.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }
                    // v4.0.110：卡面直接停（判据与任务中心同源：仅 kind=stream 且 running——
                    // bg 作业后端无 cancel 端点；嵌套 Button 内层优先消费点击，不会触发外层进任务中心）
                    if let first = activeTasks.first, first.kind == "stream", first.status == "running" {
                        Button {
                            Haptics.tap()
                            stopTarget = first
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: Typography.body, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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

    /// 卡面副标题：当前任务的进度摘要（后端 detail = 第 N 步 xxx · 字数 · 静默时长）+ 超出 1 条的计数。
    /// 单行 lineLimit 截断；两条都没有时给兜底文案，别留空行。
    private func activeCardSubtitle(_ first: AuthStore.ActiveTask) -> String {
        var parts: [String] = []
        if !first.detail.isEmpty { parts.append(first.detail) }
        if activeTasks.count > 1 { parts.append("还有 \(activeTasks.count - 1) 个") }
        return parts.isEmpty ? "任务进行中" : parts.joined(separator: " · ")
    }

    /// v4.0.110：拉进行中任务 + 定时刷新（口径逐字同 TaskCenterView.startActivePolling：2s 一轮、
    /// 起手立即拉一次；停 = tab 切走 / 页面消失）。数据 2s 一换，视图重算即得最新进度与条数。
    private func startActivePolling() {
        activeTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                activeTasks = await auth.fetchActiveTasks()
            }
        }
        activeTimer = t
        Task { @MainActor in
            activeTasks = await auth.fetchActiveTasks()
        }
    }

    private func stopActivePolling() {
        activeTimer?.invalidate()
        activeTimer = nil
    }

    /// v4.0.110：卡面停止（复用任务中心同一条链路：auth.streamStop → 立刻刷新卡面）
    private func stopTask(_ t: AuthStore.ActiveTask) {
        Task { @MainActor in
            await auth.streamStop(taskId: t.id)
            // 停完立刻刷新，别等下一轮 2s
            activeTasks = await auth.fetchActiveTasks()
        }
    }

    // MARK: - 产物库

    private var artifactBoard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                sectionTitle("产物")
                Spacer(minLength: Spacing.sm)
                // v4.0.114：有产物才给「选择」（空目录摆一颗没用的按钮 = 占位）。
                if !entries.isEmpty {
                    Button(selecting ? "取消" : "选择") {
                        Haptics.tap()
                        selecting.toggle()
                        if !selecting { picked = [] }
                    }
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            filterBar
            if !actionError.isEmpty {
                Text(actionError)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            artifactCard
            if selecting { batchBar }
        }
        // v4.0.114：单删与批删**共用一个 alert**（同一视图挂两个 .alert 在旧系统上只有最后一个生效，
        // 与其赌版本不如只留一个）；文案随目标动态换。
        .alert(deleteConfirmText, isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { Task { await deleteNow() } }
            Button("取消", role: .cancel) { deleteTargets = [] }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    /// 选择态底部条（v4.0.114）：勾选计数 + 删除入口。
    /// ⚠️ 选择态下**行点击 = 勾选**、不再进目录/查看（否则点一下误入目录、勾选全乱）。
    private var batchBar: some View {
        HStack(spacing: Spacing.sm) {
            Text(picked.isEmpty ? "勾选要删除的产物" : "已选 \(picked.count) 项")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.sm)
            Button(role: .destructive) {
                let targets = entries.filter { picked.contains($0.path) }
                guard !targets.isEmpty else { return }
                deleteTargets = targets
                deleteConfirmText = "删除 \(targets.count) 项？"
                confirmDelete = true
            } label: {
                Text(picked.isEmpty ? "删除" : "删除(\(picked.count))")
                    .font(.system(size: Typography.tiny, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(picked.isEmpty)
        }
        .padding(Spacing.section)
        .pastelCard(cornerRadius: Radius.hero)
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
                        // v4.0.114：换筛选就清勾选——被筛掉的项还留着勾，删除等于打黑箱。
                        picked = []
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
            // v4.0.110：失败态同样给 backRow（子目录拉取失败 ≠ 困死在该层）
            VStack(spacing: Spacing.sm) {
                if !atRootLevel { backRow }
                hint(failureText, tone: .red)
            }
        } else if visibleDirs.isEmpty && visibleFiles.isEmpty {
            // v4.0.110：空目录也要给 backRow——原实现空态分支不渲染返回按钮，
            // 用户进空文件夹（如日期目录）就被困住，只能杀页重来（真机实报）。
            VStack(spacing: Spacing.sm) {
                if !atRootLevel { backRow }
                emptyHint
            }
        } else {
            VStack(spacing: Spacing.sm) {
                if !atRootLevel { backRow }
                ForEach(visibleDirs) { d in dirRow(d) }
                ForEach(visibleFiles) { f in artifactRow(f) }
            }
        }
    }

    /// 空态：根目录空（AI 还没产出过）与子目录空分开说，别让用户以为坏了
    @ViewBuilder
    private var emptyHint: some View {
        if atRootLevel {
            VStack(spacing: Spacing.xs) {
                Text("还没有 AI 生成的产物")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text("在聊天里让 AI 做文档、出图、跑数据，成品都会出现在这里")
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
            if !dirStack.isEmpty {
                dirStack.removeLast()
            } else {
                currentRoot = ""        // v4.0.114：从某个根的顶层再退 → 回到「两根合并」的根层
            }
            entries = []
            Task { await load() }
        } label: {
            HStack(spacing: Spacing.md) {
                badge("arrow.up.left", tint: Color(uiColor: .systemGray))
                Text("返回上一级")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Spacer(minLength: Spacing.sm)
                Text(requestPath)
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

    /// 目录行。⚠️ v4.0.114 起**不再是 Button**：行尾要挂「⋯」菜单，而 SwiftUI 里 Button 套 Button
    /// 的命中区域会打架（点 ⋯ 可能连带进目录）→ 改 HStack + contentShape + onTapGesture。
    private func dirRow(_ d: RemoteFileEntry) -> some View {
        HStack(spacing: Spacing.md) {
            // v4.0.114（审查 P2）：点击区**只覆盖左侧内容**，不含行尾 ⋯ 菜单 ——
            // 光把 Button 换成 onTapGesture 并没有消除与菜单的命中竞争（父级 contentShape(Rectangle())
            // 仍把整行圈进去），只是换了对手。这里把 tap 收到内容 HStack 上，菜单独立在外。
            // 顺带补上 Button 语义（改手势后 VoiceOver 会读不出「可进目录」）。
            HStack(spacing: Spacing.md) {
                badge("folder.fill", tint: .orange)
                Text(d.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.sm)
                if !selecting {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { tapDir(d) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(d.name)
            .accessibilityHint(selecting ? "轻点勾选" : "轻点进入文件夹")

            rowTrailing(d)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(cornerRadius: Radius.hero)
    }

    /// 点目录：选择态 = 勾选，否则进目录。
    private func tapDir(_ d: RemoteFileEntry) {
        if selecting { togglePick(d.path); return }
        Haptics.tap()
        // v4.0.114：从 entry.path（形如 `artifacts/2026-10-15/xxx`）拆出**根与层**——
        // 根层是两根合并的，此时光靠 d.name 已不知道进的是哪个根。
        let comps = d.path.split(separator: "/").map(String.init)
        currentRoot = comps.first ?? ""
        dirStack = Array(comps.dropFirst())
        entries = []
        Task { await load() }
    }

    private func artifactRow(_ f: RemoteFileEntry) -> some View {
        HStack(spacing: Spacing.md) {
            // v4.0.143（用户 2026-10-21「产物库加图片缩略图，现在只有文件名」）：
            // 图片直接出真缩略图（带 token 下载 + 3x 下采样 + 进程内缓存，见 ArtifactThumbnail）；
            // 其余类型仍走图标 badge —— 判定用 RemoteFiles.imageExts 这一处真源，不在行里另写扩展名表。
            if RemoteFiles.imageExts.contains(RemoteFiles.ext(f.name)) {
                ArtifactThumbnail(path: f.path)
            } else {
                badge(iconName(f.name), tint: .accentColor)
            }
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
            if !selecting {
                if preparingPath == f.path {
                    ProgressView().controlSize(.small)
                } else {
                    Button { open(f) } label: {
                        Text("查看")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                            .lineLimit(1)
                    }
                    // v4.0.x：系统胶囊样式（.bordered 自带 Capsule 材质底），不再自绘玻璃描边
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            rowTrailing(f)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(cornerRadius: Radius.hero)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { togglePick(f.path) } }
    }

    // MARK: - v4.0.114 删除（⋯ 单删 + 选择态批量）

    /// 行尾：选择态 = 勾选圈；否则 = 「⋯」菜单（删除）。
    /// ⚠️ 单删**也要二次确认**：后端是真删（无回收站），点错就没了。
    @ViewBuilder
    private func rowTrailing(_ e: RemoteFileEntry) -> some View {
        if selecting {
            // v4.0.114（复核 P2）：拆点击区时把行尾也一起排除在外了 —— 选择态点这枚勾选圈
            // 没反应（内容区能点、`artifactRow` 整行能点，两态口径不一致）。补回命中 + VoiceOver 语义。
            Image(systemName: picked.contains(e.path) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Typography.title))
                .foregroundStyle(picked.contains(e.path) ? Color.accentColor : Color.secondary.opacity(Tint.faint))
                .padding(.leading, Spacing.xs)
                .contentShape(Rectangle())
                .onTapGesture { togglePick(e.path) }
                .accessibilityLabel(picked.contains(e.path) ? "已勾选" : "未勾选")
                .accessibilityAddTraits(.isButton)
        } else {
            Menu {
                Button(role: .destructive) {
                    deleteTargets = [e]
                    deleteConfirmText = e.isDir ? "删除「\(e.name)」及其中的内容？" : "删除「\(e.name)」？"
                    confirmDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func togglePick(_ path: String) {
        Haptics.tap()
        if picked.contains(path) { picked.remove(path) } else { picked.insert(path) }
    }

    /// 回读后丢弃**不在当前目录**的勾选（v4.0.114）：进目录/切根后旧的勾选若留着，
    /// 批量删除会打到用户已经看不见的条目上。
    private func prunePicks() {
        picked = picked.intersection(Set(entries.map { $0.path }))
    }

    /// 执行删除（单条 / 批量同一实现）。**中途失败不中断**：删掉的算删掉，失败项红字列出
    /// （与设置页「文件管理」的批量删除同口径）。
    private func deleteNow() async {
        let targets = deleteTargets
        deleteTargets = []
        guard !targets.isEmpty else { return }
        actionError = ""
        var failed: [String] = []
        var reason = ""   // v4.0.143：后端给的原因（只读挂载 / 权限）—— 原先只报「N 项失败」，
                          // 用户完全不知道为什么，只能反复点（真机报「产物删除失败」就是这么来的）
        for e in targets {
            do {
                let j = try await auth.json("/api/files/delete", method: "POST", body: ["path": e.path])
                if (j["ok"] as? Bool) == true {
                    entries.removeAll { $0.path == e.path }
                    picked.remove(e.path)
                } else {
                    failed.append(e.name)
                    if reason.isEmpty, let m = j["error"] as? String, !m.isEmpty { reason = m }
                }
            } catch {
                failed.append(e.name)
                if reason.isEmpty { reason = "请求未送达或服务器无响应" }
            }
        }
        if failed.isEmpty {
            Haptics.tap()
            if targets.count > 1 { selecting = false; picked = [] }
        } else {
            let head = failed.prefix(3).joined(separator: "、")
            actionError = "\(failed.count) 项删除失败：\(head)\(failed.count > 3 ? " 等" : "")"
                + (reason.isEmpty ? "" : " · \(reason)")
        }
    }

    // MARK: - v4.0.109 待你处理

    /// 「待你处理」聚合：AI 问过、还没被我回答的问题卡（**跨会话**，不必记得是哪条会话问的）。
    /// ⚠️ 没有待答卡时**整块不渲染**（其上 if 判空）——工作区不摆空壳。
    private var pendingBoard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("待你处理")
            VStack(spacing: Spacing.sm) {
                ForEach(pendingItems.prefix(Self.pendingMaxRows)) { item in
                    pendingRow(item)
                }
                if pendingItems.count > Self.pendingMaxRows {
                    Text("还有 \(pendingItems.count - Self.pendingMaxRows) 件在等你回答")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.xs)
                }
            }
        }
    }

    private func pendingRow(_ item: WorkspacePendingKit.Item) -> some View {
        Button {
            Haptics.tap()
            Task { @MainActor in
                // 口径同 `SessionsView.open`：打开会话即已读（upTo 用会话最后一条消息时间，防角标复亮）
                chat.markRead(item.sessionId, upTo: item.time)
                if await chat.loadById(item.sessionId, auth: auth) { onOpenSession?() }
            }
        } label: {
            HStack(spacing: Spacing.md) {
                badge("questionmark.bubble.fill", tint: .orange)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.question)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.sessionTitle + " · " + WorkspacePendingKit.relative(item.time))
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                Text("去回答")
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard(cornerRadius: Radius.hero)
        }
        .buttonStyle(.plain)
    }

    /// 拉待答卡。失败**静默**（不占位、不报错）：它只是便利入口，拉不到不该给页面添红字。
    /// 数据 = `/api/sessions/list`（与会话列表页同一条读路径，零后端改动）。
    @MainActor
    private func loadPending() async {
        guard let j = try? await auth.json("/api/sessions/list") else { return }
        let items = WorkspacePendingKit.parse(j)
        if items != pendingItems { withAnimation(Motion.tap) { pendingItems = items } }
    }

    // MARK: - v4.0.109 工具格（v4.0.x 起 4→6 格、**每行 4 格**排 4+2）

    /// 工具入口**每行 4 格**（用户 2026-10-14 口径「按 4 个一行的图标排列」）：6 格排两行 4 + 2。
    /// 六格依次 = 知识库 / 网盘文件 / MCP 工具服务 / 技能库 / 定时任务 / 邮件接入
    /// （后两格 v4.0.x 从设置页移入）。
    /// ⚠️ 4 列后每格宽（393 屏）= (393 − 页边距 18×2 − 卡内边距 16×2 − 格间距 6×3) ÷ 4 ≈ **76.75pt**
    ///    （375 屏 ≈ 72.25pt）；标题最长的「MCP 工具」≈42pt @10pt，`toolCell` 的
    ///    `.lineLimit(1) + .minimumScaleFactor(0.8)` 已兜住 —— 原 3+3 每格 ~104pt 是为旧口径（格更宽）。
    /// ⚠️ **第二行只有 2 格 → 必须左对齐**：`LazyVGrid` 固定 4 列天然左起，别改成「两格各占半屏」的均分
    ///    （那会让两行的格宽不一致，同屏两种观感）。将来加第 7、8 格时第二行自动补齐，不用再改布局。
    /// ⚠️ 技能库刻意用 `sparkles`、不是设置页那颗 `books.vertical.fill`：与知识库**同一行**，
    ///    同符号会分不开（同一个功能在设置页仍是书那颗，别去改那边）；
    ///    六格六色不撞（green / blue / teal / purple / red / blue）同样是为了同屏可分辨；
    ///    ⚠️ 邮件接入的 blue 与网盘文件同色——两者都属「外部服务接入」，且分处两行（网盘在第一行、邮件在第二行）。
    private var toolsBoard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("工具")
            // 每行 4 格 = `LazyVGrid` 固定 4 列 flexible（形态同 `SettingsCommon` 的三列格那处先例）。
            // 原「两行 HStack 各 3 格」（每格 ~104pt）已按用户口径退役，别改回去。
            // v4.0.114（用户「工具里上下行间距、图标左右间距都拉开点，保持视觉平衡」）：
            // 左右 6 → 10（Spacing.lg）、上下 8 → 12（Spacing.xl）—— 行距 ≥ 列距，视觉上不歪。
            // 每格因此窄约 3pt（375pt 屏 72.3 → 69.3），图标有 44pt 底、文字有 minimumScaleFactor 兜着。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.lg), count: 4),
                      spacing: Spacing.xl) {
                toolCell("知识库", symbol: "books.vertical.fill", tint: .green) { showKB = true }
                toolCell("网盘文件", symbol: "externaldrive.fill", tint: .blue) { showCloud = true }
                toolCell("MCP 工具", symbol: "puzzlepiece.extension.fill", tint: .teal) { showMCP = true }
                toolCell("技能库", symbol: "sparkles", tint: .purple) { showSkills = true }
                // v4.0.x：定时任务 / 邮件接入从设置页移入（色沿用设置页原色）
                toolCell("定时任务", symbol: "clock.badge.fill", tint: .red) { showTasks = true }
                toolCell("邮件接入", symbol: "envelope.fill", tint: .blue) { showMail = true }
                // v4.0.113：定时提醒 / 文件管理从设置页移入（色沿用设置页原色：pink / indigo）。
                // 排到 8 格后每行 4 格 × 两行正好排满，格子尺寸与 v4.0.x 六格时逐点相同
                // （`GridItem(.flexible())` 只是把行宽均分，与格数无关）。
                toolCell("定时提醒", symbol: "bell.badge.fill", tint: .pink) { showReminder = true }
                toolCell("文件管理", symbol: "folder.fill", tint: .indigo) { showFiles = true }
                // v4.0.115（用户 2026-10-15「会议纪要功能加入工作台的工具栏」）：第 9 格。
                // 图标沿用长按宠物菜单里「会话纪要」那颗 `list.bullet.rectangle` —— 同一个功能两个入口，
                // 符号一致用户才认得出是同一件事；色取 orange（前 8 格未用，同屏可分辨）。
                // ⚠️ 9 格 = 4 + 4 + 1（第三行只一格，LazyVGrid 固定 4 列天然左对齐，不用改布局）。
                // 🚨 不自己 present 纪要页：那条路 ChatView 不在树 → 卡静默丢失（理由见 onOpenMinutes 声明处）。
                toolCell("会议纪要", symbol: "list.bullet.rectangle", tint: .orange) { onOpenMinutes?() }
                // v4.0.124：第 10 格「Hermes 插件」——已安装（含手动装/桌面端）+ 官方插件库浏览/安装/启停。
                // 图标 shippingbox（包裹 = 插件包），色 mint（前 9 格未用，同屏可分辨）。
                // ⚠️ 10 格 = 4 + 4 + 2，LazyVGrid 固定 4 列天然左对齐，不用改布局。
                toolCell("Hermes 插件", symbol: "shippingbox.fill", tint: .mint) { showPlugins = true }
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity)
            .pastelCard(cornerRadius: Radius.hero)
        }
    }

    /// 一格 = 图标底（`BadgeShell`，与全站小图标同一出口）+ 名称。整格可点（`contentShape` 兜住图标右侧空白）。
    private func toolCell(_ title: String, symbol: String, tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: Spacing.xs) {
                badge(symbol, tint: tint)
                Text(title)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具格的 sheet（背景层冷组）

    /// 行为型深层修饰器下沉背景层（`.background` 不影响布局，语义等价）——口径同设置页 `settingsColdN`。
    /// 拆两组是因为「每组顶层修饰器 ≤4 条」的深度上限（见 `ql_typestack` 护栏）。
    private func workspaceCold1() -> some View {
        Color.clear
            .sheet(isPresented: $showKB) {
                KBView()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
            .sheet(isPresented: $showSkills) {
                SkillsLibrarySheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
                    // 与设置页同一份口径：sheet 内长按站点需要本层宿主（根层 zIndex 画不到 sheet 之上）
                    .anchorMenuHost()
            }
            // v4.0.113：定时提醒 / 文件管理（原挂设置页 sheet 冷组，随工具格入口一起搬来）。
            // 顶层 4 条是本层上限（§77 类型栈深度护栏口径），再加 sheet 请新开 workspaceCold3。
            .sheet(isPresented: $showReminder) {
                QuickReminderSheet()
                    .anchorMenuHost()   // v4.0.105：sheet 内长按站点需要本层宿主（根层 zIndex 4 画不到 sheet 之上）
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
            .sheet(isPresented: $showFiles) {
                FilesManagerSheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
    }

    private func workspaceCold2() -> some View {
        Color.clear
            .sheet(isPresented: $showCloud) {
                CloudDriveSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
            .sheet(isPresented: $showMCP) {
                MCPSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
            .sheet(isPresented: $showTasks) {
                TasksView()
                    .anchorMenuHost()   // v4.0.105：sheet 内长按站点需要本层宿主（根层 zIndex 4 画不到 sheet 之上）
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showMail) {
                MailSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
    }

    /// v4.0.124：第 3 组 sheet 冷层——工具格到 10 格后新增「Hermes 插件」，
    /// 前两组各已 4 条（每组顶层 ≤4 条是深度上限，见 truth_table_wstools.swift）。
    private func workspaceCold3() -> some View {
        Color.clear
            .sheet(isPresented: $showPlugins) {
                PluginsSheet()
                    .presentationDetents([.medium, .large])
                    .scrollContentBackground(.hidden)
            }
            // v4.0.143：栏目自定义（排序 + 隐藏）
            .sheet(isPresented: $showSectionEditor) {
                WorkspaceSectionEditorSheet(visible: visibleSections, hidden: Array(hiddenSections))
            }
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

    /// 拉当前目录。**根层**（currentRoot 为空）把两个根各拉一次再合并；子目录只拉当前那一个根。
    /// `entries` 复位由调用方负责，避免旧目录内容一闪。
    /// v4.0.110：keepOnFailure=true（静默刷新场景）失败时保留旧列表——别把用户正看到的产物顶没。
    @MainActor
    private func load(keepOnFailure: Bool = false) async {
        loading = true
        failureText = ""
        if atRootLevel {
            // v4.0.114：根层 = 两根合并。**一个根挂了不拖垮另一个** ——
            // 只要有一个根拿到了就照常显示；全挂才报错（否则 artifacts 这种新目录一空就把 office 一起拖没）。
            // v4.0.114（审查 P2）：判定不能用 `merged.isEmpty` ——「A 根正常返回**空目录**、B 根失败」
            // 会把空目录误判成失败；改为按根计数，只有**所有**根都失败才算失败。
            var merged: [RemoteFileEntry] = []
            var okCount = 0
            var firstErr = ""
            for root in Self.artifactRoots {
                switch await fetchList(root) {
                case .ok(let list): okCount += 1; merged += list
                case .fail(let msg): if firstErr.isEmpty { firstErr = msg }
                }
            }
            if okCount == 0 {
                // 全部根都失败。静默刷新（keepOnFailure）时不报错也不清列表 ——
                // 旧写法「不清 entries 却仍设 failureText」自相矛盾（列表还在、同时挂红字）。
                if !keepOnFailure {
                    failureText = firstErr
                    entries = []
                    prunePicks()   // 审查 P2：失败清空后必须同步收勾，否则留下「已选 N 项」的死按钮
                }
            } else {
                entries = Self.stableOrder(merged)
                prunePicks()
            }
            loading = false
            return
        }
        switch await fetchList(requestPath) {
        case .ok(let list):
            entries = list
            prunePicks()
        case .fail(let msg):
            failureText = msg
            if !keepOnFailure {
                entries = []
                prunePicks()   // 审查 P2：同上，失败清空必须同步收勾
            }
        }
        loading = false
    }

    private enum FetchOutcome { case ok([RemoteFileEntry]); case fail(String) }

    /// 拉一层目录（走 files_api 的别名根）。path 形如 `office` / `office/2026-10-15`。
    private func fetchList(_ path: String) async -> FetchOutcome {
        do {
            // v4.0.110：改 POST 形态——蜂窝下「带 query 的 GET」直连会静默挂 10s 超时（v2.0.5 已知坑、
            // v4.0.60 后 GET 失败不降级 relay）→ 4G 下产物列表恒空（真机实报）。POST 蜂窝直连通、
            // 失败还有 relay 兜底。后端同批已支持 POST JSON {path}（GET 保留，向后兼容旧 App）。
            let (data, resp) = try await auth.request("/api/files/list",
                                                      method: "POST",
                                                      body: ["path": path])
            guard (200..<300).contains(resp.statusCode) else {
                return .fail("取产物失败（HTTP \(resp.statusCode)）")
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // ⚠️ parent 必须传带别名根前缀的 path（如 `office/xxx`），**不能传 currentPath**：
            //    parseEntries 拿 parent 拼出的 entry.path 会原样交给下载口
            //    （/api/files/download?path=…），而后端 resolve_path 只对 `office` / `office/xxx`
            //    走别名根，少了前缀会回落到 uploads/ 与 ROOT → 404「文件不存在」。
            //    （v4.0.108 审查抓出：本地预检与 CI 全绿、只有真机点「查看」才暴露。）
            return .ok(RemoteFiles.parseEntries(obj?["entries"], parent: path))
        } catch {
            return .fail(RemoteFiles.failureReason(error))
        }
    }

    /// 合并后的稳定顺序：目录在前，各自按名称 —— 两个根混一起也得每次一样，
    /// 否则刷新一次顺序就变（用户会以为列表「跳了」）。
    private static func stableOrder(_ list: [RemoteFileEntry]) -> [RemoteFileEntry] {
        list.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
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
    // v4.0.114（用户「AI 生产的其他产物也要加到产物里」）：产物不止文档 —— 补齐 AI 会产出的其它形态。
    // 顺序=使用频率直觉：文档类在前（原有），其它在后。
    case code = "代码"
    case data = "数据"
    case archive = "压缩包"
    case audio = "音频"
    case other = "其他"

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
        // v4.0.114：其它产物的归类。刻意**不抢**上面已收的扩展名
        //（md/txt/rtf 归 Word 一族、csv 归 Excel —— 别在这里再收一遍，否则「全部」之外会重复出现）。
        case .code:    return ["py", "swift", "js", "ts", "sh", "json", "yml", "yaml",
                               "html", "css", "sql", "java", "c", "h", "cpp"].contains(e)
        case .data:    return ["db", "sqlite", "parquet", "tsv", "xml", "log"].contains(e)
        case .archive: return ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains(e)
        case .audio:   return ["mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov"].contains(e)
        case .other:   return !WorkspaceArtifactFilter.allCases.contains { f in
            f != .other && f != .all && f.match(name)
        }
        }
    }
}
