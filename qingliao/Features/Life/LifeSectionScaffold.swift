import SwiftUI

// MARK: - 生活页 Section 脚手架（工作线 B：抽出 4 个 Section 逐字重复的样板）
//
// 为什么要有这个文件（真实事故，不是洁癖）：
//   MiniCapsule 当年就是 MemoSection / TodoSection 各抄一份 `private struct`，第三个使用者
//   RecordSection 直接写 `MiniCapsule(...)` → `cannot find in scope`，而本机预检只跑
//   `swiftc -parse`（**纯语法、不做名字解析**）当场全绿，只有 CI Archive 才炸。
//   本文件里的四个组件都遵守同一条规则：**跨文件复用必须是非 private 的单一来源**。
//
// 本文件只收「去掉标识符后逐字相同、只差文案/占位符/回调」的部分，各 Section 真实不同的
// 地方一律留在原文件，不为了收拢把差异硬塞成参数：
//   · LifeSectionHeader      ← 4 份 pageHeader（标题 + 条件副标题 + Spacer + 「添加」胶囊）
//   · LifeEmptyStateCard     ← 4 份 emptyTap（图标 + 主副文 + 同几何 16 圆角 83pt 引导卡）
//   · LifeDeleteConfirm      ← 3 份 deleteConfirm(on:) + 备忘录弹窗内那一份同款 alert
//   · LifeNoteComposeSheet   ← 备忘/待办两份 addSheet（TextEditor 外壳，差占位符与标题）
//
// 刻意**没有**收进来的：
//   · 页级卡的点击（备忘录/待办/目标各一份）：1 条直达详情、≥2 条原位展开的骨架相同，但直达分支
//     要写的 state 各不相同（待办多 editDraft/detailEditing，目标多 detailCurrent），抽出来要传
//     3~4 个 inout 闭包，收益低于可读性损失 → 保留各自实现。
//     ⚠️ v4.0.97 起口径分叉：**备忘录不再是 openCard()** —— 页级卡换成彩色叠卡，点卡 = toggleExpand
//     （层层展开 / 整齐叠回）；待办与目标仍是「页级圆环卡 + 卡下展开列表」。
//   · 记录的新建弹窗：三字段 + Picker 单位，与 TextEditor 外壳完全不同构 → 不动。
//   · 卡片/行卡（MemoNoteCard / TodoRowCard / GoalRowCard / RecordRowCard）：结构各不相同，
//     只有「外层几何」相同，已由 LifeEmptyStateCard 与各 Section 自己的 topCard 各自承担。

// MARK: 页级标题行

/// 页级标题行：粗体标题 + 条件副标题 + Spacer + 右侧「添加」淡色胶囊。
/// 副标题只在有内容时出现（空态不加计数），`subtitle` 传 nil 即为「不显示」。
struct LifeSectionHeader: View {
    let title: String
    /// nil = 不显示副标题（各 Section 在 store 为空时传 nil）
    let subtitle: String?
    /// 仅记录副标题较长（可能截断）时传 1，其余 nil —— 不做全局 lineLimit，避免改动其它三处观感
    let subtitleLineLimit: Int?
    let addAccessibilityLabel: String
    let onAdd: () -> Void
    /// 记录区专用（v4.0.22 「扫账单」）：可选的次要动作，排在「添加」左边。
    /// nil = 不显示（备忘/待办/目标三处不传，观感零变化）。
    var secondaryAction: (title: String, action: () -> Void)? = nil
    /// 行首图标底符号（v4.0.84 方案 B①）：nil = 不显示。
    /// 与 sectionIconTint 成对传，缺一不显示 —— 免得出现「有色块没符号」的半截形态。
    var sectionIcon: String? = nil
    /// 行首图标底色；与 sectionIcon 成对传
    var sectionIconTint: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let sectionIcon, let sectionIconTint {
                // v4.0.84 方案 B①：边长 20 是本仓的第三档
                //（列表行 36 / 记录分类卡自报），几何仍只此一处 —— 走 BadgeShell，
                // 别在这里手写 cornerRadius（LifeBadges.swift 头注：「迟早漂移」）。
                Image(systemName: sectionIcon)
                    .font(.system(size: 20 * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .modifier(BadgeShell(size: 20, color: sectionIconTint))
            }
            Text(title)
                .font(.system(size: Typography.body, weight: .bold))
            if let subtitle {
                subtitleText(subtitle)
            }
            Spacer(minLength: 0)
            if let secondaryAction {
                Button(action: secondaryAction.action) {
                    // v4.0.26：统一成主胶囊样式（tone 默认 .accent = 原生液态玻璃）。
                    // 原为 .neutral（淡灰底+描边老样式），与右边「添加」并排像两个体系的按钮。
                    Text(secondaryAction.title).pill(.page)
                }
                .buttonStyle(PressStyle())
            }
            Button(action: onAdd) {
                Text("添加").pill(.page)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(addAccessibilityLabel)
        }
        .padding(.top, Spacing.sm)
    }

    @ViewBuilder
    private func subtitleText(_ s: String) -> some View {
        let base = Text(s)
            .font(.system(size: Typography.subhead))
            .foregroundStyle(.secondary)
        if let subtitleLineLimit {
            base.lineLimit(subtitleLineLimit)
        } else {
            base
        }
    }
}

// MARK: 空态引导卡

/// 空态 = 可点引导卡：与页级单卡**同几何**（`.pastelCard()` 16 圆角 + MemoCardMetrics.minHeight），
/// 所以「空态 ↔ 有内容」切换时页面不跳变。四个 Section 只差图标与两句文案。
struct LifeEmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let onTap: () -> Void
    // 🚫 卡内 CTA 胶囊（v4.0.84 方案 B⑤ 的「＋ 记一条 / ＋ 建一个 / ＋ 建目标 / ＋ 写一条 / ＋ 记一笔」）
    //    已在 v4.0.85 整体移除：栏目头 LifeSectionHeader 本来就有一颗「添加」胶囊，
    //    卡内同行再放一颗 CTA = 同屏同一件事两个入口（用户 2026-10-09 真机截图圈出三颗要求删掉）。
    //    真值表 ql_uitokens 已反向钉死（组件与五个调用点都不得再现）。整卡仍是可点入口（onTap）。

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.minHeight, alignment: .leading)
            .pastelCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: 删除二次确认

/// 「删除这一条？」二次确认（破坏性按钮 + 取消，message 说清删的是哪条、截断到 40 字）。
///
/// 🚨 必须挂在**自己那棵视图树上**（页卡宿主一份、弹窗内一份）：宿主级 alert 在 sheet 之上
/// 呈现不出来 → 弹窗里长按/左滑删除 = 点了没反应（SR35，备忘/待办/目标/记录都各踩过一次）。
/// 本 modifier 不改变这件事，只是让四处不再各抄一份 Binding 手写版。
///
/// `onDelete` 只在 `pending` 非 nil 时带值调用，`onCancel` 负责把 pending 复位（两处按钮都走它）。
struct LifeDeleteConfirm<Item>: ViewModifier {
    let title: String
    let pending: Item?
    let onCancel: () -> Void
    let onDelete: (Item) -> Void
    let message: (Item) -> String

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { onCancel() } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pending { onDelete(item) }
                onCancel()
            }
            Button("取消", role: .cancel) { onCancel() }
        } message: {
            Text(pending.map(message) ?? "")
        }
    }
}

// MARK: 新建（TextEditor 外壳：备忘 / 待办共用）

/// 「新建一条」弹窗外壳：大号 TextEditor + 占位符 + 取消/保存 toolbar + medium/large 高度。
/// 保存按钮在空白（trim 后）时禁用；`onSave` 收到的已是原样文本，是否 trim 由调用方按各自口径处理。
///
/// ⚠️ 正文由本视图自己的 @State 持有，而 SwiftUI 会**保留已 present 过视图的状态** → 调用方
/// 必须靠 `.id(...)` 换实例来保证每次打开是空白（生活页两个调用方都是 `startAdd()` 自增一个
/// 会话序号，见 MemoSection / TodoSection 注释）。原来正文是宿主 @State，靠显式 `draft = ""` 复位。
///
/// v4.0.76：备忘录的新建改走毛玻璃浮层（MemoGlassOverlay）——系统 toolbar 在浮层里没有
/// 导航栏可挂 → 自绘顶栏（与 MemoDetailSheet.topBar 同款小胶囊）；`formSheet` 参数默认 true
/// 保持旧 sheet 行为（待办仍用），false = 浮层内容形态（备忘录用）。
struct LifeNoteComposeSheet: View {
    let title: String
    let placeholder: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    /// true = 系统 sheet 形态（NavigationStack + toolbar）；false = 毛玻璃浮层内容形态（自绘顶栏）
    var formSheet: Bool = true

    /// v4.0.98（用户 2026-10-11「备忘录卡片内容分主题和详细内容」）：**备忘专用** —— 正文上方多一个
    /// 单行「主题」输入框（这里的值是占位文案）。给 nil（默认）＝ 原来的单输入框一套，
    /// 待办/习惯那边一行都不用改；主题留空由 Store 兜底取正文第一行。
    var titleFieldPlaceholder: String? = nil
    /// 带主题的保存回调（只有开了主题框的调用方给）。没给 → 退回老的 `onSave(正文)`。
    var onSaveWithTitle: ((String, String) -> Void)? = nil

    @State private var text = ""
    /// 主题草稿（**独立字段**，不从正文第一行抽 —— 用户 2026-10-11 明确口径）
    @State private var headline = ""

    /// 保存出口：有主题框回传（主题, 正文），否则老路子回传正文
    private func commit() {
        if let onSaveWithTitle { onSaveWithTitle(headline, text) } else { onSave(text) }
    }

    /// 共用正文区（两种形态同一份）
    private var editorBody: some View {
        VStack(spacing: 0) {
            if let titleFieldPlaceholder {
                TextField(titleFieldPlaceholder, text: $headline)
                    .font(.system(size: Typography.title))
                    .textFieldStyle(.plain)
                    .submitLabel(.next)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .padding(.horizontal, Spacing.section)
                    .padding(.top, Spacing.md)
            }
            TextEditor(text: $text)
                .font(.system(size: Typography.title))
                .scrollContentBackground(.hidden)
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: Typography.title))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Spacing.section)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.md)
        }
    }

    /// 浮层形态的自绘顶栏（取消/保存小胶囊，标题居中——与 MemoDetailSheet.topBar 同款读法）
    private var overlayTopBar: some View {
        HStack(spacing: 8) {
            MiniCapsule(title: "取消") { onCancel() }
            Spacer(minLength: 0)
            MiniCapsule(title: "保存", accent: true) { commit() }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)
        .overlay {
            Text(title)
                .font(.system(size: Typography.headline, weight: .semibold))
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        if formSheet {
            NavigationStack {
                editorBody
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", action: onCancel)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { commit() }
                                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        } else {
            VStack(spacing: 0) {
                overlayTopBar
                editorBody
            }
        }
    }
}

// MARK: - v4.0.99 展开区共用的勾选圈（单一来源）
//
// 用户 2026-10-12「app 整体做视觉对齐」：待办 / 长期目标两张卡点开后都在卡下列一行行的条目，
// 勾选控件必须是**同一枚**。谁在各自文件里再画一枚（尺寸/描边/勾号各差一点），
// 两张卡展开后就会长得不一样 —— 而且不会报错，只有用户能看出「歪了」。
// 所以提成非 private 的跨文件单一来源（同 LifeCapsule.swift 顶部那条规矩）。
struct LifeCheckCircle: View {
    /// 🚨 **唯一尺寸真源**（v4.0.100 用户 2026-10-12「待办清单的勾选圆再变小一点，其他卡片的
    /// 勾选圆大小也一并对齐」）：v4.0.99 时是 24 / 26 / 18 三档混用（待办展开区 24、习惯行卡与
    /// 两处详情大勾 26、目标步骤行 18）—— 同一枚圈在不同卡上肉眼可辨地不一样大，用户点名对齐。
    /// 统一到 **20**（比原待办那档小一点，且 ≤ 原最大档）。**各处调用一律不传 `size`**，
    /// 以后改尺寸只改这一个数；谁再在调用点写死 size，就是又开了第二处真源。
    static let defaultSize: CGFloat = 20

    let done: Bool
    var size: CGFloat = LifeCheckCircle.defaultSize
    /// 勾上之后的填充色（待办 = 绿、长期目标 = 主题色；底色/描边/勾号一律共用）
    var tint: Color = .green

    var body: some View {
        Circle()
            .fill(done ? tint : Color.primary.opacity(0.10))
            .overlay {
                Circle()
                    .strokeBorder(done ? Color.clear : Color.primary.opacity(0.30), lineWidth: 1.4)
            }
            .overlay {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
    }
}
