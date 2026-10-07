// MARK: - v3.7.0 生活页「备忘录」栏目
// v3.9.14：体验升级——便签化卡片 / 置顶 / 相对时间 / 来源图标 / 折叠 / 可编辑 / 一键发给 AI
// v3.9.17：按用户选定的方案 A 改版——
//   ① 「备忘录」+「添加」胶囊搬到卡片外，做页级标题行（与 LifeCardsSection 的「生活数据」同款：
//      粗体 15pt 标题 + Spacer + 淡色胶囊，卡片里只装内容）
//   ② 卡片只显示 1 条（置顶优先、其次最后修改时间倒序）
//   ③ 点整块 → 弹「全部备忘」列表（半屏，可拖到全屏）；原卡片内的「全部 N 条」折叠行随之删除
// v3.9.33：单卡形态定稿（用户定稿：「不做堆叠卡片，就一张卡片，卡片复制生活数据卡片的圆角及高度，
//   卡片长度铺满手机」）——
//   · **堆叠取消**：原「主卡 + 2 层错位卡边」（layerInset/Drop 四个常量、stackedLayers、
//     stackedLayerShape、stackBottomSpace）整块删除，页面上只有一张卡
//   · **圆角/高度对齐「生活数据」各卡**：`.pastelCard()`（Radius.card = 16 + 0.8pt 描边）
//     + 卡高走 MemoCardMetrics.minHeight（与行情卡同口径），不再用便签形态的 Radius.inset(12)
//   · 宽度：`.frame(maxWidth: .infinity)` 铺满内容区（左右各 14pt 页边距与其它卡齐平）
//   · 只有 1 条时点卡片直接进详情（列表页是多余的一跳）；≥2 条才走「全部备忘」列表
import SwiftUI
import Observation   // v4.0.77：浮层状态提到页级单例（@Observable）

// MARK: - v3.9.33 页级单卡几何（对齐「生活数据」卡片，真机微调只改这一处）

/// 用户定稿：「卡片复制生活数据卡片的圆角及高度，卡片长度铺满手机」
/// 圆角由 `.pastelCard()` 给（Radius.card = 16，与生活数据各卡同参）。
/// 高度用 **minHeight** 兜住而不是写死 height —— 两张卡内容结构不同，写死会在字号放大时裁切：
///   行情卡 LifeStockCard 实测算式：
///     上内边距 12 + 标题行 ≈15.5（subhead 13）+ 6 + 价格 ≈23.9（headline 20）+ 2 + 明细 ≈11.9（tiny 10）+ 下内边距 12 ≈ 83
///   备忘卡 2 行正文（15pt，每行 ≈17.9）+ 6 + 元信息行 ≈13.1 + 上下内边距 24 ≈ 78.9 < 83
/// → 1 行或 2 行备忘都是 83pt，卡片恒等高、与旁边卡片对齐；超长正文限 2 行，点开看全部
enum MemoCardMetrics {   // v3.9.35：private 去掉——TodoSection 复用同高常量
    /// 与「生活数据」行情卡同高（≈83pt）
    static let minHeight: CGFloat = 83
    /// 页级单卡正文行数上限
    static let lineLimit = 2
}

struct MemoSection: View {
    @State private var store = MemoStore.shared
    /// v4.0.77：三个浮层的开关（全部列表 / 详情 / 新建）**提到页级单例**——
    /// 浮层本体不再挂在本 section 自己的 ZStack 里（本 section 只是生活页滚动区的一行，
    /// 浮层会被限制在卡片那一行的几何里）。详见 MemoGlassPresenter / MemoGlassLayerHost 顶部注释。
    private var glass = MemoGlassPresenter.shared
    /// v3.9.20：卡片 → 「全部备忘」列表的原生 zoom 转场（同看板卡片 / 资讯→大爆炸那套）
    @Namespace private var memoZoomNS

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                // v3.9.17：标题行在卡片外（原来是卡片内的图标 + 灰字 + 计数胶囊）
                pageHeader
                if store.memos.isEmpty {
                    emptyTap
                } else {
                    memoCard
                }
            }
            .modifier(MemoSectionBodyChrome(host: self))
            // 🚨 v4.0.77 只读审查（中）：删除确认框**跟着浮层上收到页级宿主**了
            // （原来挂在这一行上 → 行被 LazyVStack 回收时「点了删除没反应」）→ 见 MemoGlassLayerHost。

            // 🚨 v4.0.77：三个毛玻璃浮层**搬出本 section**（用户实报「备忘录卡片现在点击只在现有
            // 卡片大小内弹，我是要那种全屏弹出那种」）——本 section 只是生活页滚动区（LifeView 的
            // LazyVStack）里的**一行**，浮层挂在这里 → 几何被限制在这一行里：轻纱只盖住卡片那一条、
            // 面板贴着卡片边缘长出、列表一滚浮层跟着跑。
            // 现在：开关在 MemoGlassPresenter（页级单例，本 section 只改状态），
            //      浮层本体由 MemoGlassLayerHost 渲染、挂在 **LifeView body 最外层**（真正的全屏层）。
            //      ↓ 见本文件底部 MemoGlassPresenter / MemoGlassLayerHost
        }
    }

    // MARK: 页级标题行（v3.9.17：与「生活数据」同款——标题在卡片外，右侧放宽/实心胶囊）

    /// v3.9.4：只留文字 + 胶囊（去图标）；v3.9.19：尺寸走 .pill(.page) 口径
    /// 外壳已收进 LifeSectionHeader（工作线 B：待办/目标/记录三份同款）
    private var pageHeader: some View {
        LifeSectionHeader(
            title: "备忘录",
            subtitle: store.memos.isEmpty ? nil : "\(store.memos.count) 条",
            subtitleLineLimit: nil,
            addAccessibilityLabel: "添加备忘录",
            onAdd: startAdd
        )
    }

    /// v3.9.14：空态改成"可点的引导卡"——原来那句话是说明书腔，现在点了就能写
    /// v3.9.33：与单卡同几何（16 圆角 + 同高），空态 ↔ 有内容不跳变
    private var emptyTap: some View {
        LifeEmptyStateCard(
            icon: "square.and.pencil",
            title: "记点什么",
            subtitle: "聊天里长按消息、大爆炸选词，都能存进来",
            onTap: startAdd
        )
    }

    /// 页级标题行与空态引导卡共用这一个入口（正文改由 LifeNoteComposeSheet 自己的 @State 持有，
    /// 靠 addSession 换实例保证每次空白）
    private func startAdd() {
        glass.addSession += 1
        glass.showAdd = true
    }

    // MARK: 单卡（v3.9.33：页面上只有这一张卡——原 2 层错位卡边整块删除）

    @ViewBuilder
    private var memoCard: some View {
        if let top = store.sorted.first {
            Button {
                openCard()
            } label: {
                MemoNoteCard(item: top, compact: true)
            }
            .buttonStyle(PressStyle())
            .contextMenu { memoMenuItems(top, onDelete: { glass.pendingDelete = $0 }) }
            // v3.9.20：卡片即 zoom 源（≥2 条点开「全部备忘」时从这张卡放大展开）
            .matchedTransitionSource(id: "memo-all", in: memoZoomNS)
            .accessibilityLabel(store.sorted.count == 1
                                ? "备忘录，1 条，点开查看"
                                : "备忘录，共 \(store.sorted.count) 条，点开查看全部")
        }
    }

    /// 点卡片：只有 1 条时「全部备忘」列表是多余的一跳 → 直接进详情。
    /// ⚠️ 新增 / 全部列表 / 详情三个 sheet 共用 MemoSection 这一个宿主，同时只能 present 一个
    ///（原因见 openDetailFromAll 的长注释），所以这里必须二选一，绝不能两个都置真。
    private func openCard() {
        if store.sorted.count == 1, let only = store.sorted.first {
            glass.detail = only
        } else {
            glass.showAll = true
        }
    }

    // MARK: 全部备忘列表（v3.9.17 半屏 sheet → v4.0.76 毛玻璃浮层内容）
    //
    // 主体抽成 MemoAllListBody（下方独立 struct）：原 allSheet 的 NavigationStack 外壳由
    // MemoGlassOverlay 替代，回调全部上提由宿主闭包注入（浮层收起、清空确认、开详情、删除）。

    /// v3.9.17：先收掉「全部备忘」列表，等它 dismiss 完再执行动作
    /// （v4.0.76 起浮层是同 ZStack 的层序关系，不再有 sheet 的 present 竞争；
    /// 但保留 500ms 缓冲让列表收起动画播完，观感与老路径一致）
    private func afterAllDismissed(_ action: @escaping () -> Void) {
        glass.showAll = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !glass.showAll else { return }   // 期间用户又点开了列表 → 放弃这次动作
            action()
        }
    }

    /// 从列表点一条 → **先收列表，再开详情**（v3.9.21 真机回归后确认必须这样，勿再改）
    ///
    /// 🚨 真正原因（比原注释说的"同帧 present 丢弹窗"更根本）：MemoSection 上**链式挂了三个 `.sheet`**
    /// （showAdd / showAll / detail），它们共用同一个宿主视图；两个同时为真时 **只有一个会生效**，
    /// 于是"列表还开着就 present 详情"= 详情被吞掉 → 真机表现为**点一条打不开详情**。
    /// v3.9.20 曾为了保留"列表行→详情"的 zoom 转场（zoom 要求源行在呈现时仍在屏上）把这里改成直接
    /// `detail = m`，真机回归即挂 —— zoom 再好看也不能拿功能换。
    /// 若日后仍想要那个转场，正确做法是把 detail 这个 sheet **挂到 allSheet 的内容视图内部**（分层宿主），
    /// 而不是让两个 sheet 共用一个宿主。
    private func openDetailFromAll(_ m: MemoItem) {
        afterAllDismissed { glass.detail = m }
    }

    // MARK: 长按菜单（卡片 / 列表两处共用）

    /// v3.9.17：带回调——「全部备忘」列表里触发的删除/发消息必须先收掉 sheet（同帧 present 会丢），
    /// 卡片上的长按则直接执行
    /// v4.0.77：菜单项内容提到**文件级**（memoCardMenuItems）——页级浮层宿主也要用同一套，
    /// 这里只做转发。⚠️ 名字必须与文件级那个不同，否则就是自己调自己（无限递归）。
    @ViewBuilder
    private func memoMenuItems(_ m: MemoItem,
                               onDelete: @escaping (MemoItem) -> Void,
                               onSend: ((MemoItem) -> Void)? = nil) -> some View {
        memoCardMenuItems(m, onDelete: onDelete, onSend: onSend)
    }

    /// v3.9.14：把备忘内容作为一条用户消息发给 AI，并切回聊天页（转发到文件级 memoSendToAI）。
    private func sendToAI(_ m: MemoItem) { memoSendToAI(m) }

    // MARK: 新增

    // v4.0.77：原 addSheet（新建浮层的内容）已搬到页级宿主 MemoGlassLayerHost —— 见本文件底部。
}

// MARK: - v4.0.77 备忘录浮层的「页级宿主」
//
// 🚨 为什么单开一个宿主（用户 2026-10-08 实报）：
//    「备忘录卡片现在点击只在现有卡片大小内弹，我是要那种全屏弹出那种」
// 4.0.76 把三个毛玻璃浮层挂在 MemoSection 自己的 ZStack 里，而 MemoSection 只是生活页滚动区
// 里的一行 → 浮层几何被限制在这一行：轻纱只罩住卡片那一条、面板从卡片边缘长出、随列表滚走。
// 浮层要「全屏」就必须挂在**页面根**、滚动区之外。
//
// 做法：三个开关（showAll / detail / showAdd）提到页级单例 MemoGlassPresenter，MemoSection 只改状态；
// 浮层本体由本 struct 渲染，挂载点 = LifeView body 最外层的 `.overlay`（全屏层）。
// 视图树内顺序仍是：全部列表 < 详情 < 新建（后开的盖在前面）。

@MainActor
@Observable
final class MemoGlassPresenter {
    static let shared = MemoGlassPresenter()

    /// 「全部备忘」列表浮层
    var showAll = false
    /// 「新建备忘」浮层
    var showAdd = false
    /// 详情浮层（nil = 不显示）
    var detail: MemoItem?
    /// 宿主删除二次确认（浮层内的「删除」先收浮层、错峰 350ms 再置这里 → 由 MemoSection 的
    /// LifeDeleteConfirm 呈现；alert 是窗口级，盖在浮层之上）
    var pendingDelete: MemoItem?
    /// 新建浮层的会话序号：每次打开自增，配合 `.id()` 强制换新实例（保证每次都是空编辑器）
    var addSession = 0

    private init() {}

    /// 🚨 v4.0.77 只读审查（中）：**宿主销毁时清状态** —— 单例不会随视图树消失，页面被系统回收后
    /// 重建，开关还是 true → 回到生活页会「莫名又弹着上次那个浮层」。挂在 MemoGlassLayerHost
    /// 的 .onDisappear 上（宿主与生活页同生共死）。
    func reset() {
        showAll = false
        showAdd = false
        detail = nil
        pendingDelete = nil
        addSession = 0
    }
}

/// 备忘录浮层的页级宿主（挂 LifeView 根 → 全屏；轻纱盖住整页含页头）
struct MemoGlassLayerHost: View {
    private var glass = MemoGlassPresenter.shared
    private var store = MemoStore.shared

    var body: some View {
        ZStack {
            if glass.showAll {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAll },
                    set: { if !$0 { glass.showAll = false } }
                )) {
                    MemoAllListBody(
                        store: store,
                        onDone: { glass.showAll = false },
                        onClear: { },   // v4.0.76 审查⑤：触发由 MemoAllListBody 内部 listConfirmClear 直接驱动（MiniCapsule「清空」处）
                        onOpenDetail: { openDetailFromAll($0) },
                        onDeleteInList: { _ in },   // 列表内左滑删除由 MemoAllListBody 自己的确认框管
                        onConfirmClear: {
                            store.removeAll()
                            glass.showAll = false
                            Haptics.success()
                        },
                        menuFor: { m, del, snd in
                            AnyView(memoCardMenuItems(m, onDelete: del, onSend: snd))
                        },
                        onSendToAI: { memoSendToAI($0) }
                    )
                }
            }
            if let m = glass.detail {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.detail != nil },
                    set: { if !$0 { glass.detail = nil } }
                )) {
                    MemoDetailSheet(item: m, onDelete: { item in
                        glass.detail = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            glass.pendingDelete = item
                        }
                    }, onDismiss: { glass.detail = nil })
                }
            }
            if glass.showAdd {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAdd },
                    set: { if !$0 { glass.showAdd = false } }
                )) {
                    // 新建浮层内容（原 MemoSection.addSheet）：外壳已收进 LifeNoteComposeSheet，
                    // 这里只差占位符与标题；每次打开换新实例（.id）→ 打开即空白。
                    LifeNoteComposeSheet(
                        title: "新建备忘",
                        placeholder: "写点什么…",
                        onSave: { text in
                            if store.add(content: text, source: "manual") {
                                Haptics.success()
                            }
                            glass.showAdd = false
                        },
                        onCancel: { glass.showAdd = false },
                        formSheet: false   // v4.0.76：毛玻璃浮层形态（自绘顶栏）
                    )
                    .id(glass.addSession)
                }
            }
        }
        // 🚨 v4.0.77 只读审查（中）：宿主销毁即清状态 —— 页面重建后不会「莫名又弹上次那个浮层」
        // （单例状态不随视图树消失；见 MemoGlassPresenter.reset）
        .onDisappear { glass.reset() }
        // 🚨 v4.0.77 只读审查（中）：**删除确认框必须与浮层同宿主**。原来它挂在 MemoSection 那一行
        // （生活页滚动区里的 LazyVStack 行），而浮层已上收到本宿主 —— 全屏详情里点「删除」要靠一行
        // 可能被 LazyVStack 回收的视图去弹 alert，行不在时表现为「点了删除没反应」。现在跟着浮层上收。
        // alert 是窗口级 → 盖在毛玻璃浮层之上（与旧版观感一致）。
        .modifier(LifeDeleteConfirm(
            title: "删除这条备忘？",
            pending: glass.pendingDelete,
            onCancel: { glass.pendingDelete = nil },
            onDelete: { store.delete($0) },
            message: { $0.content.prefix(40).description }
        ))
    }

    /// v3.9.17 → v3.9.21 真机回归后定稿：从列表点一条必须**先收列表、等收起动画播完再开详情**
    /// （同帧直接切会丢弹窗；v4.0.76 起浮层是同 ZStack 层序，仍保留 500ms 缓冲以保持同一观感）。
    private func openDetailFromAll(_ m: MemoItem) {
        glass.showAll = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !glass.showAll else { return }   // 期间用户又点开了列表 → 放弃这次动作
            glass.detail = m
        }
    }
}

// MARK: - v4.0.77 长按菜单项（卡片 / 全部列表 / 页级浮层三处共用）

/// ⚠️ 名字必须与 `MemoSection.memoMenuItems` 区分（那个只是转发到本函数），否则会自己调自己。
/// 🚨 **文件级函数默认非 MainActor 隔离**（只有 View 的成员才是）→ 本体里调 `Haptics`/`MemoStore`
/// 这类 MainActor API 必须显式 `@MainActor`；否则只有 CI Archive 会报 `call to main actor-isolated
/// static method 'success()' in a synchronous nonisolated context`（本机 `-parse` 查不出；仓内先例：
/// ImageCache.swift 的全局函数都带 `@MainActor`）。
@MainActor
@ViewBuilder
private func memoCardMenuItems(_ m: MemoItem,
                               onDelete: @escaping (MemoItem) -> Void,
                               onSend: ((MemoItem) -> Void)? = nil) -> some View {
    Button {
        MemoStore.shared.togglePin(m)
        Haptics.success()
    } label: {
        Label(m.pinned ? "取消置顶" : "置顶", systemImage: m.pinned ? "pin.slash" : "pin")
    }
    Button {
        if let onSend { onSend(m) } else { memoSendToAI(m) }
    } label: {
        Label("发给 AI", systemImage: "paperplane")
    }
    Button {
        UIPasteboard.general.string = m.content
        Haptics.success()
    } label: {
        Label("复制", systemImage: "doc.on.doc")
    }
    Button(role: .destructive) {
        onDelete(m)
    } label: {
        Label("删除", systemImage: "trash")
    }
}

/// v3.9.14：把备忘内容作为一条用户消息发给 AI，并切回聊天页。
/// 备忘存下来只能复制粘贴没意义——能直接接着办才是轻聊备忘录区别于系统备忘录的地方。
@MainActor
private func memoSendToAI(_ m: MemoItem) {
    NotificationCenter.default.post(name: .qingliaoMemoSend, object: m.content)
    Haptics.success()
}

// MARK: - 备忘正文链接识别（点链接跳系统浏览器）
//
// ⚠️ 为什么不能直接 `Text(AttributedString(正文))` 就完事：SwiftUI 只有**走 Markdown 解析**
// 才会给 URL 打 .link 属性，纯文本 → AttributedString 出来的还是一坨无属性的字，链接照样点不了。
// 聊天页能点是因为那边经过 markdown 渲染管线。备忘正文是用户手写/从聊天原样存过来的裸文本，
// 所以这里显式用 NSDataDetector 扫一遍 http/https（外加常见裸域名前缀），手动挂 .link。
//
// 点击由调用处的 `.environment(\.openURL)` 统一接管 → UIApplication.open 进系统浏览器
// （不弹内嵌 SFSafari 预览），与聊天页 AI 消息同一口径。
private enum MemoLinkDetector {
    /// NSDataDetector 构造较贵（要加载链接规则），全 App 复用同一个实例
    nonisolated(unsafe) static let shared: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
}

private func memoLinkified(_ text: String) -> AttributedString {
    var attr = AttributedString(text)
    // 裸域名（example.com/path 这种没写协议的）也认，否则「粘贴来的网址」多半识别不出来
    guard let detector = MemoLinkDetector.shared else { return attr }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    for hit in detector.matches(in: text, options: [], range: range) {
        guard let url = hit.url, url.scheme != nil else { continue }
        // 换算成 AttributedString 的索引区间。NSDataDetector 给的是 UTF-16 的 NSRange，
        // 必须先过 `Range(_:in:)` 拿到 String.Index，再交给 AttributedString.Index(_:within:)——
        // 注意这两处签名都**没有参数标签**（`Range(nsRange:in:)` / `attr.ranges(of:)` 都不存在，
        // 只有 CI Archive 才拦得住，见 scripts/ql_memo 真值表）。
        guard let strRange = Range(hit.range, in: text) else { continue }
        guard let lower = AttributedString.Index(strRange.lowerBound, within: attr),
              let upper = AttributedString.Index(strRange.upperBound, within: attr) else { continue }
        let r = lower..<upper
        // 只挂 .link + 下划线，**不**预置前景色：SwiftUI 渲染 .link 段时自带 accentColor，
        // 而上面那条 .foregroundStyle(.primary) 优先级高于属性里的颜色（写了也会被盖掉，
        // 反而在不同主题下出现"以为没生效"的错觉）。非链接段继续走 .primary。
        attr[r].link = url
        attr[r].underlineStyle = .single
    }
    return attr
}

// MARK: - v3.9.18 自绘顶栏用的小胶囊
// 为什么不用系统 toolbar：iOS 26 会把导航栏按钮渲染成玻璃胶囊，尺寸由系统定（字号/controlSize 都压不小），
// 用户反馈「关闭/编辑/复制胶囊太大」→ 自绘顶栏 + `.toolbar(.hidden, for: .navigationBar)`，尺寸完全可控。
// 口径：tiny 字号 + h10/v5（比页级标题行的 h10/v4 略高一点，因为它是顶部主操作区）。

// MiniCapsule 已抽到 LifeCapsule.swift（v3.9.71）：跨文件复用必须是**非 private 的单一来源**，
// 原来这里那份 private 版本是 copy-paste 来源，第三个使用者（RecordSection）因此编译不过。

// MARK: - 备忘卡视觉（v3.9.17：抽成独立 struct——页级单卡 / 全部列表两处共用）
//
// v3.9.33：圆角与卡片底改走全站口径 `.pastelCard()`（Radius.card 16 + Tint.line 0.8pt 描边），
//   原「便签形态 12 圆角 + 自绘不透明底」随堆叠卡边一起废弃（用户定稿：与生活数据卡一致）。
//   置顶态仍有独立标记：主题色描边 + 一层淡色罩（只在这张卡上叠，不改 pastelCard 本身）。
//   ⚠️ 这层罩用 `.overlay`（叠在内容之上）而不是 `.background`：pastelCard 的渐变底也要在罩层之下，不能被实色盖住，
//   放到它下面会被整块遮住（等于没有）。不透明度很低（Tint.faint），对正文/元信息的观感影响可忽略，
//   换来置顶卡一眼可辨——这是刻意选择，不是漏改。
//
// 两处形态只差三件事（其余完全同一套视觉）：
//   compact = true   页级单卡：正文 2 行 + 卡高兜底到「生活数据」行情卡同高（MemoCardMetrics）
//   compact = false  全部备忘列表行：正文 3 行 + 自然高度（列表要能一眼扫到更多字）

private struct MemoNoteCard: View {
    let item: MemoItem
    /// v3.9.33：页级单卡形态（限 2 行 + 与生活数据卡等高）；列表行用默认 false
    var compact: Bool = false

    var body: some View {
        // v4.0.65（用户 2026-10-06 看对比稿拍板「备忘走 A」）：**列表行**行首加来源色块。
        // 页级单卡（compact）保持原样 —— 用户 v3.9.37 明确要求单卡「连图标也不要」（见 metaRow 注释），
        // 且单卡行首突然放大显得突兀。稿：scripts/ql_memo_todo/mock/out/memo_todo_icons.png
        HStack(alignment: .top, spacing: 10) {
            if !compact {
                SourceBadge(source: item.source, symbol: item.sourceIcon)
            }
            // 栈间距按全仓口径写字面值（Spacing.swift 第 4 条：栈间距与内边距混在同一个令牌名下有歧义）
            VStack(alignment: .leading, spacing: 6) {
                Text(item.content)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? MemoCardMetrics.lineLimit : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 单卡形态把元信息行压到卡底：与行情卡「数值在上、明细在下」同一读法；
                // 1 行备忘时卡片不塌（高度由 minHeight 兜住）
                if compact { Spacer(minLength: 0) }
                metaRow
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : 0,
               alignment: .topLeading)
        .pastelCard()
        // 置顶态罩层（见本 struct 上方注释：为什么不放 background）
        .overlay {
            if item.pinned {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.accentColor.opacity(Tint.faint))
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(Tint.strong), lineWidth: 0.8)
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }

    private var metaRow: some View {
        // v3.9.35：方案 A「卡内第二层」——元信息收进淡色小底（对比稿 rgba(120,120,128,.06) 圆角 12），
        // 与行情卡「数值在上、明细收小底在下」同一读法；小底属卡内 chip，走 Radius.chip 档
        //（护栏约定：共用卡组件内不出现 inset/field/hero 卡片级圆角，卡角唯一 = pastelCard 16）
        // v3.9.35：Spacer 挪到背景外——原来 Spacer 在 HStack 里、background 挂整个 HStack，
        // 胶囊被撑满卡宽；现在背景只包住内容，胶囊随文字自适应，Spacer 只负责靠左
        //
        // v3.9.37（用户要求）：**时间胶囊拿掉、不再要胶囊点缀** —— Radius.chip 小底整层删除，
        // 元信息回到纯文字（时间、来源图标都是裸文本 + 间距）。
        // 另：**页级单卡（compact）元信息一样都不显示**（用户原话「在卡片首页连时间也不要显示，弹窗页显示即可」+
        // 「（来源图标）连图标也不要」）—— 时间与来源都只在弹窗页出现：
        // 「全部备忘」列表行（compact=false）与详情页（item.subtitle）。置顶仍靠主题色描边识别（见上方罩层）。
        HStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(Color.accentColor)
                }
                // v3.9.14：来源用图标代替文字（省一行宽度，一眼看出从哪来的）
                // v3.9.37：页级单卡不再显示来源图标（用户「连图标也不要」），与时间同口径
                // v4.0.65 审查（严重，本批自伤）：**整块删除** —— 列表行行首已有来源色块
                //（SourceBadge，见本 struct 的 body）→ 这里再画一枚灰图标 = 同一来源在同一行
                // 出现两次、配色口径还分裂（一个彩色一个灰）。单卡（compact）本轮行首没加色块，
                // 但它本就要求「连图标也不要」→ 两种形态都不需要它。
                // 稿：scripts/ql_memo_todo/mock/out/memo_todo_icons.png
                if !compact {
                    Text(item.timeText)
                        .font(.system(size: Typography.caption))
                }
            }
            .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - v4.0.76 「全部备忘」浮层内容（原 allSheet 的 NavigationStack 内主体，逐字平移）
//
// 回调全部由宿主注入：浮层是同 ZStack 层序，不再有 sheet present 竞争；删除确认/清空确认
// 仍挂本主体内部（浮层盖在生活页上，宿主层的 alert 会被浮层压住看不见——与原 sheet 时代同理由）。

struct MemoAllListBody: View {
    let store: MemoStore
    let onDone: () -> Void
    /// 清空入口（v4.0.76 起占位：触发改由内部 listConfirmClear 直接驱动，见 MiniCapsule「清空」）
    let onClear: () -> Void
    let onOpenDetail: (MemoItem) -> Void
    let onDeleteInList: (MemoItem) -> Void
    let onConfirmClear: () -> Void
    /// 长按菜单内容（宿主 memoMenuItems + afterAllDismissed 包装，闭包注入）
    let menuFor: (MemoItem,
                  @escaping (MemoItem) -> Void,
                  @escaping (MemoItem) -> Void) -> AnyView

    /// v3.9.38：列表内左滑删除的二次确认（挂浮层内部，宿主那个被浮层盖住）
    @State private var pendingDeleteInList: MemoItem?
    /// v3.9.110：清空二次确认（同上）
    @State private var confirmClearAll = false
    /// v4.0.76 审查⑤：顶栏「清空」胶囊触发入口（宿主 onClear 回调经它写进本内部状态；
    /// 直接暴露 Binding 语义更糊，用「闭包置内部 @State」保状态私有）
    @State private var listConfirmClear = false
    /// 「发给 AI」桥（宿主 sendToAI：发通知 + 震动）
    let onSendToAI: (MemoItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // v3.9.18：顶栏自绘（系统那版「完成」胶囊偏大）
            HStack(spacing: 8) {
                Text("全部备忘")
                    .font(.system(size: Typography.title, weight: .semibold))
                Text("\(store.sorted.count) 条")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !store.sorted.isEmpty {
                    MiniCapsule(title: "清空") { listConfirmClear = true }
                }
                MiniCapsule(title: "完成", accent: true) { onDone() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
            // v3.9.38：List 行容器（左滑删除走系统手势）
            List {
                ForEach(store.sorted) { m in
                    Button {
                        onOpenDetail(m)
                    } label: {
                        MemoNoteCard(item: m)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu {
                        // 删除走浮层内确认（浮层还开着时宿主 alert 被盖住）；发 AI 直接走宿主老路径
                        menuFor(m, { item in pendingDeleteInList = item }, { item in onSendToAI(item) })
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                              bottom: 8, trailing: Spacing.section))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    guard let first = offsets.first, store.sorted.indices.contains(first) else { return }
                    pendingDeleteInList = store.sorted[first]
                }
                if store.sorted.isEmpty {
                    Text("还没有备忘")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .alert("清空全部备忘？", isPresented: $confirmClearAll) {
                Button("清空 \(store.sorted.count) 条", role: .destructive) { onConfirmClear() }
                Button("取消", role: .cancel) { confirmClearAll = false }
            } message: {
                Text("将删除全部 \(store.sorted.count) 条备忘（含置顶），删除后不可恢复。")
            }
        }
        .modifier(LifeDeleteConfirm(
            title: "删除这条备忘？",
            pending: pendingDeleteInList,
            onCancel: { pendingDeleteInList = nil },
            onDelete: { store.delete($0) },
            message: { $0.content.prefix(40).description }
        ))
    }
}

// MARK: - 放大查看 / 编辑（点卡片进入）

private struct MemoDetailSheet: View {
    let item: MemoItem
    var onDelete: (MemoItem) -> Void
    /// v4.0.76：浮层收起（原 sheet 的 dismiss——浮层里没有系统 dismiss 环境，宿主注入）
    var onDismiss: () -> Void

    /// v3.9.14：本地副本——编辑/置顶后要立刻反映在本页（item 是传值进来的）
    @State private var current: MemoItem
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

    init(item: MemoItem, onDelete: @escaping (MemoItem) -> Void, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        _current = State(initialValue: item)
    }

    private var store = MemoStore.shared

    var body: some View {
        // v4.0.76：原 NavigationStack + sheet 外壳由毛玻璃浮层（MemoGlassOverlay）替代——
        // 内容主体原样保留；dismiss（关闭胶囊）走浮层的 Binding：浮层内容里没有系统 dismiss
        // 可用，改由宿主注入的 onDismiss 闭包（body 里 detail = nil → 浮层收起动画）。
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        // v3.9.14：补上编辑（MemoStore.update 早就写好了，一直没入口）
                        TextEditor(text: $editText)
                            .font(.system(size: Typography.body))
                            .lineSpacing(LineSpacing.long)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, alignment: .topLeading)
                            .padding(Spacing.lg)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    } else {
                        // v3.9.9x：正文里的链接要能识别并点开（原来纯 Text(String)，URL 只是灰字）
                        // memoLinkified 用 NSDataDetector 扫出 URL 手动挂 .link（SwiftUI 不会自动认）
                        // → 显示为主题色下划线，.textSelection 仍可长按选中复制；
                        // .environment(\.openURL) 接管点击 → UIApplication.open 直接跳系统浏览器
                        // （不弹内嵌 SFSafari 预览）。非 http(s)（如 tel:/mailto:）也交给系统处理。
                        Text(memoLinkified(current.content))
                            .font(.system(size: Typography.headline))
                            .lineSpacing(LineSpacing.long)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                UIApplication.shared.open(url)
                                return .handled
                            })
                    }
                    HStack(spacing: 6) {
                        if current.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: current.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        // subtitle 本身已含来源（"手记 · 刚刚"），别再叠一次 sourceLabel
                        Text(current.subtitle)
                            .font(.system(size: Typography.subhead))
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            // v4.0.76：编辑态浮层内没有系统下滑手势，草稿天然安全（interactiveDismissDisabled 随 sheet 一并移除）
        }
    }

    // MARK: v3.9.18 顶栏（自绘；v4.0.76 起浮层内也用它，「关闭」走 onDismiss）

    private var topBar: some View {
        HStack(spacing: 8) {
            if editing {
                MiniCapsule(title: "取消") { editing = false }
                Spacer(minLength: 0)
                MiniCapsule(title: "保存", accent: true) { saveEdit() }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                MiniCapsule(title: "关闭") { onDismiss() }
                Spacer(minLength: 0)
                MiniCapsule(title: "编辑") {
                    editText = current.content
                    editing = true
                }
                MiniCapsule(title: copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = current.content
                    Haptics.success()
                    copied = true
                }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)
        .overlay {
            if !editing {
                // v3.9.22：17pt → 20pt（Typography.headline）。用户两次反馈"太小"：
                // v3.9.18 自绘顶栏误用 subhead(13) → v3.9.19 回到 17pt（系统 inline 标题档）→ 仍嫌小，
                // 定稿 20pt。字号档位：tiny 10 / caption 11 / subhead 13 / body 15 / title 17 / headline 20 / titleXL 24
                Text("备忘录")
                    .font(.system(size: Typography.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(current, content: text)
        // 只有内容真变了才动本地副本的时间：store.update 在内容未变时什么都不做，
        // 这里若无条件改，详情页会显示"刚刚"而存储里没变（两处时间分叉）
        if current.content != text {
            current.content = text
            current.updatedAt = Date()
        }
        editing = false
        Haptics.success()
    }
}

// MARK: - v4.0.50 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
//
// 事故与 ChatView（v4.0.49）/ DashboardView（v4.0.50）同源：本文件 body 返回类型名里
// **内联**了每条 .sheet 内容闭包的完整类型（各 sheet 的正文视图树），dSYM 实测 body 的
// mangled 类型名 1323 字符。危险量是**名字的字符数**（≈19 字符 = 1 帧 demangler 递归，
// 每帧 ~9.3KB 主线程栈），TabView 启动即渲染本页，与其它视图叠加可吃干 1MB 栈 → 一点开就闪退。
//
// 修法 = 把 body 的修饰器链折成具名 ViewModifier 分组：父类型名里只剩组名，链在各组自己的
// applyXxx 调用里解析（各自一次 1MB 栈预算）。⚠️ 修饰器**种类/数量/顺序/参数**逐字未变
// （等价重构，视图树与身份/动画真源不动）；谁也不许把这些链再内联回 body ——
// 改链请改这里的 applyXxx，别动调用点。
extension MemoSection {
    /// 折叠组 1（2 条修饰器）：页壳（宽度对齐 + 进页面拉一次数据）
    @MainActor
    private func applyMemoSectionBodyChrome<C: View>(to content: C) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // v3.7.0：进入生活页即拉 NAS 上的备忘（本地已有则远端为空时不清本地）
            .task { await store.loadFromServer() }
    }

    /// 折叠组 2（1 条修饰器）：宿主删除确认。
    @MainActor
    private struct MemoSectionBodyChrome: ViewModifier {
        let host: MemoSection

        func body(content: Content) -> some View { host.applyMemoSectionBodyChrome(to: content) }
    }

}
