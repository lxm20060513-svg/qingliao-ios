// MARK: - #3 斜杠命令面板（v1）
//
// 面板本体（Features/Chat/SlashCommandPanel.swift）+ 命令落地卡文案（SlashCardKit）。
//
// 面板由 ChatInputBar 以 **`.overlay` 常驻层级**挂载、用 opacity/offset 显隐 ——
// **绝不允许 `if 命令模式 { … }` 把面板插进输入栏 VStack 子节点**：那会改 TextField 的父级/兄弟集合
// → 重建 → 键盘弹一下又收回（本仓老坑，见 ChatInputBar.fullInputBar 注释 / 真值表 ql_inputbar）。
//
// 行内容 = 命令名（`SlashCommand.title`）+ 一句说明（`hint`），列表一律迭代 `SlashCommand.allCases`
// ——命令名清单只有 Core/SlashCommands.swift 一份，不在这里再写死一遍。

import SwiftUI

/// 斜杠命令浮层面板：行高 44、玻璃材质、点击回调 `onPick`。
/// 高度上限 200pt，超出滚动（v1 六条远不到上限，留作 v2 扩展）。
struct SlashCommandPanel: View {
    /// 当前输入前缀（含前导 `/`，由 `SlashParser.panelPrefix` 产出）——决定过滤结果。
    let prefix: String
    /// 点选回调（宿主据 `SlashCommand.takesArgument` 决定填入模板）。
    var onPick: (SlashCommand) -> Void

    /// 单行高度（HIG 最小可点 44）。
    static let rowHeight: CGFloat = 44
    /// 内容高度上限（超出滚动）。
    static let maxContentHeight: CGFloat = 200

    private var items: [SlashCommand] { SlashParser.matches(prefix: prefix) }

    /// 面板内容高度：按匹配条数算、封顶 `maxContentHeight`。
    /// 输入栏用它做 `.overlay` 的向上位移（面板底边贴在输入栏上缘之上），故对外可见。
    static func height(itemCount: Int) -> CGFloat {
        min(CGFloat(itemCount) * rowHeight, maxContentHeight)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // allCases 的过滤结果：注册表改一处，面板自动跟着变。
                ForEach(items, id: \.self) { cmd in
                    Button { onPick(cmd) } label: { row(cmd) }
                        .buttonStyle(PressStyle())
                }
            }
        }
        .frame(height: Self.height(itemCount: items.count))
        .frame(maxWidth: 360)
        // 玻璃底走全站统一出口（a11yGlass：含「降低透明度」降级），描边口径同全站 0.8pt
        .a11yGlass(.regular,
                   in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
                   stroke: Color.primary.opacity(Tint.faint))
        .padding(.horizontal, Spacing.md)
    }

    private func row(_ cmd: SlashCommand) -> some View {
        HStack(spacing: Spacing.md) {
            Text(cmd.title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(cmd.hint)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: Self.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 命令落地卡文案（```ql-card 协议 → AgentCardParser → AgentResultCard，零新渲染体系）

/// `/help` / 未知命令 / `/usage` 的只读卡片文案构造（单一真源）。
///
/// 为什么走 ```ql-card 而不是自绘视图：会话里的卡片统一由 AgentResultCard 渲染（与记账卡同族），
/// 自绘第二套必然与全站卡形/导出/长按菜单分叉。
enum SlashCardKit {
    /// `/help`：命令表（迭代注册表，不手写清单）。
    static func helpText() -> String {
        let list: [[String: String]] = SlashCommand.allCases.map {
            ["title": $0.title, "subtitle": $0.hint]
        }
        return qlCard([
            "type": "list",
            "title": "斜杠命令",
            "subtitle": "命令不进 AI，仅本机执行",
            "list": list,
            "footer": "带参命令示例：/记一笔 35 咖啡",
        ])
    }

    /// 未知命令提示卡（`/foobar`）：不发 LLM，本地消化。
    static func unknownCommandText() -> String {
        qlCard([
            "type": "result",
            "title": "没有这个命令",
            "subtitle": "输入 /help 看列表；这条想当普通消息发给 AI 的话，删掉开头的斜杠再发一次",
            "status": ["text": "提示", "tone": "info"],
        ])
    }

    /// 通用本地提示卡（记账参数解析失败 / 用量拉取失败等）。
    static func noticeText(_ message: String) -> String {
        qlCard([
            "type": "result",
            "title": message,
            "status": ["text": "提示", "tone": "info"],
        ])
    }

    /// `/usage`：只读用量卡（与看板 Token 用量卡同源数据）。
    static func usageText(_ usage: TokenUsage) -> String {
        qlCard([
            "type": "metrics",
            "title": "Token 用量",
            "subtitle": "今日 / 本月 · 只读",
            "status": ["text": "只读", "tone": "info"],
            "metrics": [
                ["label": "今日", "value": usage.today.totalM, "unit": "M"],
                ["label": "本月", "value": usage.month.totalM, "unit": "M"],
            ],
            "fields": [
                ["key": "今日输入/输出", "value": "\(usage.today.inputM) / \(usage.today.outputM)"],
                ["key": "本月输入/输出", "value": "\(usage.month.inputM) / \(usage.month.outputM)"],
                ["key": "缓存命中", "value": "今日 \(usage.today.cacheM) · 本月 \(usage.month.cacheM)"],
            ],
            "footer": "与看板「Token 用量」卡同源",
        ])
    }

    /// 统一序列化：sortedKeys → 同一条内容每次结果一致（落库/去重/导出比对才稳定）。
    private static func qlCard(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "```ql-card\n" + json + "\n```"
    }
}
