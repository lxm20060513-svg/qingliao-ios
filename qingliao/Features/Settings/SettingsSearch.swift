import SwiftUI

// MARK: - v4.0.22 设置页搜索（视图层）
//
// 顶部一行自绘搜索框 + 结果区。结果行**复用设置页自己的 SettingRow**（图标尺寸/行高/行尾值单行
// 口径全部继承）—— 不再手搓第三种行样式，否则下一轮「观感不一致」就是从这里来的。
//
// 为什么不用系统 `.searchable`：设置页是自绘 PageHeader + 单页平铺（v3.9.88 用户拍板回退到 3.9.87 形态），
// 系统搜索栏会另起一条导航栏样式且依赖导航栈，与全站顶栏观感不一致。

struct SettingsSearchBar: View {
    @Binding var text: String

    // v4.0.61：补两处原生搜索行为——键盘按「搜索」提交后收起键盘；聚焦态交给系统管（配合下面的 .focused）。
    // ⚠️ 别把这里换成系统 `.searchable`：本文件头注已记录 v3.9.88 用户拍板回退的原因
    //    （系统搜索栏依赖导航栈、会另起一条导航栏，与自绘 PageHeader 顶栏观感打架）。原生化 ≠ 换组件。
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索设置项（如 模型、记忆、提醒）", text: $text)
                .font(.system(size: Typography.subhead))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }   // v4.0.61：系统搜索键提交即收键盘（原生行为）
            if !text.isEmpty {
                Button {
                    text = ""
                    Haptics.tap()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        // v4.0.68（用户 2026-10-07 拍板「卡底统一成品牌淡色系，含搜索框一起换」）：
        // 搜索框原本是 .secondarySystemGroupedBackground（纯白不透明）—— 压在彩化页底上，
        // 它就是设置页那块「白底」本尊。改走统一出口 pastelFill（与全站卡片同一份淡彩真源 +
        // 0.8pt 描边；纯渐变不描边的话框界会糊在页底渐变里，描边是口径不是装饰）。
        .pastelFill(cornerRadius: Radius.field)
        .padding(.horizontal, Spacing.xxl)
        .padding(.bottom, Spacing.sm)
    }
}

/// 搜索结果区：只在查询非空时插在设置页最上面 —— 各分组照旧全在下面，
/// 所以点「需要滚到分组看」的结果时滚动锚点一定在树上（不需要「先清查询、等一帧再滚」那种时序把戏）。
struct SettingsSearchList: View {
    let query: String
    let onOpen: (SettingsSearchEntry) -> Void

    var body: some View {
        let hits = SettingsSearchIndex.match(query)
        if hits.isEmpty {
            empty
        } else {
            SectionHeader("搜索结果")
            VStack(spacing: 0) {
                ForEach(Array(hits.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, Spacing.rowDividerInset)
                    }
                    SettingRow(icon: entry.icon, iconColor: .gray, title: entry.title,
                               value: entry.group, chevron: true)
                        .tapButton { onOpen(entry) }
                }
            }
            .pastelCard()
            Text("共 \(hits.count) 项")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.sm)
        }
    }

    private var empty: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("没找到「\(query)」")
                .font(.system(size: Typography.body))
                .foregroundStyle(.primary)
            Text("换个词试试，比如「模型」「记忆」「提醒」「推送」")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }
}
