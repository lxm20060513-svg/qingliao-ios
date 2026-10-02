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
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
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
            .glassListCard()
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
