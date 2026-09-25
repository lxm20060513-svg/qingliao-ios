import SwiftUI

// MARK: - v3.9.26 能力示例（卡片画廊）
//
// 背景：AI 回复里支持 ```ql-card 围栏协议（见 Core/AgentCardParser.swift + docs/agent-card-protocol.md），
// 有 5 种形态（result / metrics / list / table / status）。但用户在聊天里只能「碰运气」遇到，
// 没有任何地方能看到「AI 能出什么样的卡」。
//
// 本页把 5 种形态各用样例数据渲染一张，入口在 设置 → AI 智能 → 能力示例。
// **零后端**：AgentCard 是普通 struct（memberwise init），样例数据在 App 内直接构造，
// 不走 Hermes、不改后端 schema；渲染**直接复用聊天里的 AgentResultCard**——
// 所见即聊天里所得，不做「演示专用样式」（否则展示与真实渲染会漂移）。
//
// ⚠️ 维护提醒：AgentCard 加新字段/新形态时，本页要同步补一个样例（否则画廊与真实能力脱节）。

struct CardGallerySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    protocolGuide
                    ForEach(Self.samples) { sample in
                        VStack(alignment: .leading, spacing: 6) {
                            caption(sample)
                            // 与聊天里同一渲染路径（不是演示样式）
                            AgentResultCard(card: sample.card)
                        }
                    }
                    // v3.9.27：协议速览（卡片怎么触发的，一眼明白）
                    footerNote
                }
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.vertical, Spacing.section)
            }
            .scrollContentBackground(.hidden)   // v3.9.27：同款规则——列表自带底别盖系统玻璃
            .navigationTitle("能力示例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: 协议速览（v3.9.27：结果类回复自动出卡 + 示例可复制）

    @State private var exampleCopied = false

    /// 卡片 JSON 示例（与后端 system prompt 注入的示例同款，可直接复制到聊天里试渲染）
    private static let exampleJSON =
        """
        ```ql-card
        {"type":"result","title":"NAS 体检","status":{"text":"全部正常","tone":"ok"},
         "fields":[{"key":"存储池","value":"健康","tone":"ok"},
                   {"key":"内存","value":"62%","tone":"info"}],
         "metrics":[{"label":"CPU","value":"12","unit":"%"}],
         "footer":"检查时间 今天 09:20"}
        ```
        """

    @ViewBuilder
    private var protocolGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("卡片是怎么出现的？")
                .font(.system(size: Typography.subhead, weight: .semibold))
            Text("AI 回复检查、诊断、清单、对比这类结果时，会自动把关键信息整理成卡片附在文字后面——不用你开口要。闲聊和普通问答不会出卡片。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = Self.exampleJSON
                exampleCopied = true
                UISelectionFeedbackGenerator().selectionChanged()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    exampleCopied = false
                }
            } label: {
                Label(exampleCopied ? "已复制，去聊天里粘贴发送试试" : "复制示例，去聊天里试试",
                      systemImage: exampleCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var footerNote: some View {
        Text("卡片完全离线解析，失败时自动退回普通文字显示，不会丢内容。")
            .font(.system(size: Typography.tiny))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 顶部说明（三段式：图标 + 标题 + 一句人话）

    @ViewBuilder
    private var intro: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(Tint.subtle), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 会把结构化结果整理成卡片")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Text("下面 5 种是当前支持的形态，聊天里自动出现，不需要你去要。")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 每张卡上方的说明行（参考图的三段式：图标 + 粗体名 + 一句灰字）

    @ViewBuilder
    private func caption(_ s: Sample) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: s.icon)
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(s.desc)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 样例

    struct Sample: Identifiable, Sendable {
        let id: String
        let icon: String
        let name: String
        let desc: String
        let card: AgentCard
    }

    static let samples: [Sample] = [
        Sample(
            id: "result", icon: "checkmark.seal.fill",
            name: "结论卡",
            desc: "跑完检查后给一句结论 + 关键项，不用读完整段日志",
            card: AgentCard(
                kind: .result, title: "NAS 体检", subtitle: "3 项检查完成",
                status: AgentCard.Status(text: "全部正常", tone: .ok),
                fields: [
                    .init(key: "存储池", value: "健康", tone: .ok),
                    .init(key: "内存占用", value: "62%", tone: .info),
                    .init(key: "容器", value: "6 个运行中", tone: .ok),
                ],
                metrics: [], items: [], table: nil,
                footer: "检查时间 今天 09:20"
            )
        ),
        Sample(
            id: "metrics", icon: "chart.bar.fill",
            name: "指标卡",
            desc: "数值类结果用大号数字排开，变化时数字会滚动",
            card: AgentCard(
                kind: .metrics, title: "实时占用", subtitle: "每 10 秒刷新",
                status: nil,
                fields: [],
                metrics: [
                    .init(label: "CPU", value: "12", unit: "%", tone: .ok),
                    .init(label: "内存", value: "3.8", unit: "GB", tone: .warn),
                    .init(label: "温度", value: "46", unit: "°C", tone: .info),
                ],
                items: [], table: nil, footer: nil
            )
        ),
        Sample(
            id: "list", icon: "checklist",
            name: "清单卡",
            desc: "多条待办/多步任务，逐条带状态色",
            card: AgentCard(
                kind: .list, title: "今天要做的事", subtitle: "3 条",
                status: nil, fields: [], metrics: [],
                items: [
                    .init(title: "把照片备份到 NAS", subtitle: "还剩 12 GB 没传", status: "进行中", tone: .warn),
                    .init(title: "检查路由器固件", subtitle: nil, status: "已完成", tone: .ok),
                    .init(title: "给绿萝浇水", subtitle: nil, status: "未开始", tone: .info),
                ],
                table: nil, footer: "睡前提醒一次"
            )
        ),
        Sample(
            id: "table", icon: "tablecells.fill",
            name: "表格卡",
            desc: "多列对比（各模型用量、各设备状态）不走样",
            card: AgentCard(
                kind: .table, title: "本周模型用量", subtitle: "按调用次数排序",
                status: nil, fields: [], metrics: [], items: [],
                table: AgentCard.Table(
                    columns: ["模型", "调用", "花费"],
                    rows: [
                        ["deepseek-flash", "128", "¥0.42"],
                        ["glm-5.2", "31", "¥0.18"],
                        ["mimo-v2.5", "9", "免费"],
                    ]
                ),
                footer: nil
            )
        ),
        Sample(
            id: "plan", icon: "list.clipboard.fill",
            name: "任务计划卡",
            desc: "多步任务收尾时按执行顺序汇报各步完成度",
            card: AgentCard(
                kind: .plan, title: "备份照片到 NAS", subtitle: "3 步任务",
                status: AgentCard.Status(text: "2/3 完成", tone: .ok),
                fields: [], metrics: [],
                items: [
                    .init(title: "扫描相册", subtitle: "发现 128 张新照片", status: "完成", tone: .ok),
                    .init(title: "上传到 NAS", subtitle: "已传 86 张", status: "进行中", tone: .warn),
                    .init(title: "生成缩略图", subtitle: nil, status: "待开始", tone: .info),
                ],
                table: nil, footer: nil
            )
        ),
        Sample(
            id: "status", icon: "waveform.path.ecg",
            name: "状态卡",
            desc: "多服务/多设备巡检，异常项一眼看见",
            card: AgentCard(
                kind: .status, title: "服务状态", subtitle: "4 项巡检",
                status: AgentCard.Status(text: "1 项异常", tone: .error),
                fields: [
                    .init(key: "轻聊后端", value: "运行中", tone: .ok),
                    .init(key: "Hermes 网关", value: "运行中", tone: .ok),
                    .init(key: "语音识别", value: "未响应", tone: .error),
                ],
                metrics: [], items: [], table: nil,
                footer: "上次巡检 今天 09:20"
            )
        ),
    ]
}
