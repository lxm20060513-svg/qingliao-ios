import SwiftUI
// ⚠️ .quickLookPreview 是 QuickLook 框架的 View 扩展，不 import 直接 Archive 编译失败（本仓其它使用点都带这一行）
import QuickLook

// MARK: - #17：ql-card「AI 成品文件段」
//
// 一句话：AI 把生成的文件（Word/Excel/PPT/PDF/图片，落后端只读别名根 `office/` 下）出成一张卡，
// 点「查看」→ 下载（下载中显示「准备中…」）→ 失败在卡内红字显示原因 → 成功 QuickLook 预览。
//
// 四条口径（改动务必保持，护栏脚本 ql_file 会拦）：
//   ① **下载只走共享入口** `RemoteFiles.fetchToTemp`（单一真源：设置页「文件」与本品共用同一实现）。
//      本视图**不自己拼下载 URL**（`/api/files/download?path=` 只在 FilesManagerKit 里构造一次），
//      **不写 UserDefaults**，也**不硬编码 `office/` 前缀** —— path 由卡片直接下发，一键透传。
//   ② **path 必填**：解析层已保证到这里 `file.path` 非空（缺 path 的段在上游整段丢弃）；
//      本段因此**绝不会**出现「无 path 的空壳按钮」。
//   ③ **失败绝不静默**：失败文案复用共享文案（`RemoteFiles.fetchToTemp` 返回值）就地红字显示，不弹窗。
//   ④ 整个文件段是**独立小 View**（与 AgentCardTable / AgentCardFormSection 同口径）—— 别塞回
//      AgentResultCard.body，那边已堆了 7 个段，再挤进去会踩 SwiftUI type-check 超时。

struct AgentCardFileSection: View {

    let file: AgentCard.File

    /// 登录态：根视图已 `.environment(auth)` 全树注入（同 ChatView / AgentActionCard 的取法），
    /// 卡片自查拿客户端，**不需要任何跨层回调**。
    @Environment(AuthStore.self) var auth

    private enum Phase: Equatable {
        case idle
        case preparing
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                iconBadge
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(file.name)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                viewButton
            }
            if case .failed(let reason) = phase {
                Text(reason)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Tint.faint),
                    in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
        .quickLookPreview($quickLookURL)
    }

    // MARK: 行内容

    private var iconBadge: some View {
        Image(systemName: icon)
            .font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 28, height: 28)
            .background(Color.accentColor.opacity(Tint.subtle),
                        in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
    }

    /// 副行：`类型 · 大小`；大小未知（size <= 0）只显示类型。
    private var subtitle: String {
        guard file.size > 0 else { return typeLabel }
        return typeLabel + " · " + RemoteFiles.humanSize(file.size)
    }

    @ViewBuilder
    private var viewButton: some View {
        if case .preparing = phase {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("准备中…")
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Button(action: open) {
                Text("查看")
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .lineLimit(1)
            }
            .glassPillStroke()
        }
    }

    // MARK: 类型映射

    private var icon: String {
        switch file.kind {
        case .docx:  return "doc.text.fill"
        case .xlsx:  return "tablecells.fill"
        case .pptx:  return "play.rectangle.fill"
        case .pdf:   return "doc.richtext.fill"
        case .image: return "photo.fill"
        case .other: return "doc.fill"
        }
    }

    private var typeLabel: String {
        switch file.kind {
        case .docx:  return "Word 文档"
        case .xlsx:  return "Excel 表格"
        case .pptx:  return "PPT 演示"
        case .pdf:   return "PDF 文档"
        case .image: return "图片"
        case .other: return "文件"
        }
    }

    // MARK: 下载 + 预览

    private func open() {
        guard phase != .preparing else { return }   // 在飞闸门：防狂点重复下载
        Haptics.tap()
        phase = .preparing
        Task { await performOpen() }
    }

    /// 走共享下载入口（WiFi/蜂窝分流、失败文案、文件名净化全在 RemoteFiles 里），
    /// 成功 → QuickLook 预览；失败 → 卡内红字（复用共享文案）。
    @MainActor
    private func performOpen() async {
        switch await RemoteFiles.fetchToTemp(auth, path: file.path, name: file.name) {
        case .success(let url):
            quickLookURL = url
            phase = .idle
        case .failure(let reason):
            phase = .failed(reason.message)
        }
    }
}
