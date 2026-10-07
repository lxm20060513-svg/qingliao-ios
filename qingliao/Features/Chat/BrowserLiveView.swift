import SwiftUI

// MARK: - 浏览器实时画面（方案A：截图轮询）
// 数据链：Hermes 侧 browser_agent.py watch 循环截图 → 推 NAS 轻聊web/data/files/browser_live_<site>.jpg
// → App 走 auth.request(带 X-Auth-Token) 拉图，1s 轮询刷新（.task 驱动，随视图销毁自动取消）。
// 会话结束判据：HTTP 404（watch 收尾删 NAS 同名 jpg）或连续 5 次网络失败；单次抖动只累计不判死。
// 蜂窝降级：带 query 的 GET 会落 relay 分支（二进制必坏）→ 显示提示但不判死，切回 Wi-Fi 自动恢复。
//
// v4.0.75（用户拍板「Muse 那种」→ 选项 2）：**消息流内实时卡**替代 4.0.74 的全屏 sheet——
//   · 画面嵌在聊天消息列表里（toolStepCards 之后），聊天照常可打字指挥，不再被弹窗盖住；
//   · 点 × 随时收起（4.0.74 的 interactiveDismissDisabled「关不掉」随之废除）；
//   · 点画面开全屏（复用 ImageViewer，与问题卡点图同一套）。
// 呈现层变了，数据链（轮询/404 判死/蜂窝降级）逐字保留。

/// sheet(item:) 要求 Identifiable（site+ts 组合防同毫秒重复标记重弹）
struct BrowserLiveSession: Codable, Identifiable {
    let site: String
    let url: String
    let ts: Date
    var id: String { "\(site)|\(ts.timeIntervalSince1970)" }
    /// 远端文件名，如 browser_live_httpbin.org.jpg
    var remoteName: String { "browser_live_\(site).jpg" }
}

/// 会话间共享的「当前直播」状态（Hermes 推消息 → 解析出 session → 消息流出卡）
/// v4.0.74 审查修复：标 @MainActor——Swift 6 下 static let 持非 Sendable 必炸，且 @Published 会被后台落库路径并发写。
@MainActor
final class BrowserLiveCenter: ObservableObject {
    static let shared = BrowserLiveCenter()
    @Published var activeSession: BrowserLiveSession?

    /// 从 AI 消息文本解析直播标记：[[browser_live:site|url]]（不用 Regex 字面量，工具链兼容）
    static func parseMarker(in text: String) -> BrowserLiveSession? {
        let head = "[[browser_live:"
        guard let h = text.range(of: head) else { return nil }
        // Substring.firstIndex(of:) 只收 Character，"]]"/"|" 这类多字符串必须走 range(of:)
        guard let bar = text[h.upperBound...].range(of: "|"),
              let tail = text[bar.upperBound...].range(of: "]]") else { return nil }
        let site = String(text[h.upperBound..<bar.lowerBound]).trimmingCharacters(in: .whitespaces)
        let url = String(text[bar.upperBound..<tail.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty, !url.isEmpty else { return nil }
        return BrowserLiveSession(site: site, url: url, ts: Date())
    }
}

/// 发起直播的输入面板（附件面板「浏览器」按钮 → 填 URL → 消息流里出直播卡）
struct BrowserLivePromptView: View {
    var onStart: (String, String) -> Void
    @State private var urlText = ""
    @Environment(\.dismiss) private var dismiss

    /// 宽松归一化：无 scheme 补 https://；域名合法性交给 watch 里 goto 的报错
    static func normalizeURL(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
        return "https://" + t
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("观看浏览器实时画面") {
                    TextField("网址，如 www.baidu.com", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("开始观看") {
                        if let u = Self.normalizeURL(urlText) {
                            let site = URL(string: u)?.host ?? u
                            onStart(site, u)
                        }
                    }
                    .disabled(Self.normalizeURL(urlText) == nil)
                }
                Section {
                    Text("AI 操作浏览器时画面会出现在聊天消息里（约 1 秒一帧，仅 Wi-Fi 下可用），随时可以继续打字指挥。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("🖥 浏览器直播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// v4.0.75：消息流内的实时画面卡（Muse 式）。渲染与轮询一体：有图出图、连接中出骨架、
/// 结束出收尾态；onClose（点 ×）由宿主传入——收起卡片 + 清 Center 源都在宿主回调里做。
struct BrowserLiveView: View {
    let session: BrowserLiveSession
    let auth: AuthStore
    /// 点 × 收起直播卡。nil = 不显示关闭钮（预留只读场景）
    var onClose: (() -> Void)? = nil
    @State private var uiImage: UIImage?
    @State private var status: String = "连接中…"
    @State private var ended = false
    /// 蜂窝/网络失败的独立提示态（不与 ended 混用：ended=收尾，提示可恢复）
    @State private var cellularMode = false
    /// 连续失败计数：单次抖动只累计，≥5 才判直播结束
    @State private var failCount = 0
    /// 点画面开全屏（与问题卡点图同一套 ImageViewer）
    @State private var showViewer = false

    private var filePath: String { "/api/files/download?path=\(session.remoteName)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // 卡头：直播状态点 + 站点名 + 关闭（与问题卡工具条同一读法）
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(ended ? Color.secondary : Color.green)
                    .frame(width: 5, height: 5)
                Text(ended ? "直播已结束" : "实时画面 · \(session.site)")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                            .pill(.page, tone: .neutral)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("关闭浏览器直播画面")
                }
            }
            // 画面区：占位/骨架/真图三支同一宽度，真图按宽等比（截图横幅 ~1.6），点开全屏
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .onTapGesture { showViewer = true }
                    .accessibilityLabel("浏览器画面，点开可全屏放大")
            } else if ended {
                emptyBox {
                    Label("直播已结束", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else if cellularMode {
                emptyBox {
                    Label("蜂窝网络下暂不支持实时画面，切回 Wi-Fi 自动恢复", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            } else {
                emptyBox {
                    ProgressView(status)
                }
            }
            Text(session.url)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v4.0.68 全站口径：消息流里的卡一律 pastelCard（与问题卡同底）
        .pastelCard()
        .fullScreenCover(isPresented: $showViewer) {
            if let img = uiImage { ImageViewer(images: [img], index: 0) }
        }
        // 唯一轮询入口：.task 闭包默认 MainActor 隔离，改 @State 合法；视图销毁自动取消
        //（点 × 收起 = 视图移除 = 轮询自动停，这是流内卡比全屏 sheet 干净的地方）。
        .task {
            while !ended {
                await pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 画面区的三支空态共用同一高度（≈ 真图 1.6 比例的一半），出图时不跳版
    @ViewBuilder
    private func emptyBox(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }

    private func pollOnce() async {
        // 蜂窝下带 query 的 GET 会落 relay 分支（二进制必坏）：提示但不判死，切回 Wi-Fi 后自动恢复
        if NetworkMonitor.shared.isCellular {
            cellularMode = true
            return
        }
        cellularMode = false
        // 加 no-cache 时间戳：避免 URLSession/中间层缓存同一张图；路径值做百分号编码（site 可能含中文等）
        let enc = session.remoteName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.remoteName
        let sep = filePath.contains("?") ? "&" : "?"
        let p = "\(filePath)\(sep)_t=\(Int(Date().timeIntervalSince1970 * 1000))"
            .replacingOccurrences(of: "path=\(session.remoteName)", with: "path=\(enc)")
        guard let (data, resp) = try? await auth.request(p) else {
            // 网络抖动/超时：只累计，连续 ≥5 次才判结束
            failCount += 1
            if failCount >= 5 { ended = true; status = "直播已结束" }
            return
        }
        if resp.statusCode == 404 {
            // 404 = watch 已收尾删图 → 确定结束
            ended = true
            status = "直播已结束"
            return
        }
        guard resp.statusCode == 200, let img = UIImage(data: data) else {
            failCount += 1
            if failCount >= 5 { ended = true; status = "直播已结束" }
            return
        }
        failCount = 0
        uiImage = img
        status = ""
    }
}
