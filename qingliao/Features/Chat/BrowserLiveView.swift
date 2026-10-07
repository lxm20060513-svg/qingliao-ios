import SwiftUI

// MARK: - 浏览器实时画面（方案A：截图轮询）
// 数据链：Hermes 侧 browser_agent.py watch 循环截图 → 推 NAS 轻聊web/data/files/browser_live_<site>.jpg
// → App 走 auth.request(带 X-Auth-Token) 拉图，1s 轮询刷新（.task 驱动，随视图销毁自动取消）。
// 会话结束判据：HTTP 404（watch 收尾删 NAS 同名 jpg）或连续 5 次网络失败；单次抖动只累计不判死。
// 蜂窝降级：带 query 的 GET 会落 relay 分支（二进制必坏）→ 显示提示但不判死，切回 Wi-Fi 自动恢复。

/// sheet(item:) 要求 Identifiable（site+ts 组合防同毫秒重复标记重弹）
struct BrowserLiveSession: Codable, Identifiable {
    let site: String
    let url: String
    let ts: Date
    var id: String { "\(site)|\(ts.timeIntervalSince1970)" }
    /// 远端文件名，如 browser_live_httpbin.org.jpg
    var remoteName: String { "browser_live_\(site).jpg" }
}

/// 会话间共享的「当前直播」状态（Hermes 推消息 → 解析出 session → 弹 Sheet）
/// v4.0.74 审查修复：标 @MainActor——Swift 6 下 static let 持非 Sendable 必炸，且 @Published 会被后台落库路径并发写。
@MainActor
final class BrowserLiveCenter: ObservableObject {
    static let shared = BrowserLiveCenter()
    @Published var activeSession: BrowserLiveSession?

    /// 从 AI 消息文本解析直播标记：[[browser_live:site|url]]（不用 Regex 字面量，工具链兼容）
    static func parseMarker(in text: String) -> BrowserLiveSession? {
        let head = "[[browser_live:"
        guard let h = text.range(of: head), let bar = text[h.upperBound...].firstIndex(of: "|"),
              let tail = text[bar...].firstIndex(of: "]]") else { return nil }
        let site = String(text[h.upperBound..<bar]).trimmingCharacters(in: .whitespaces)
        let url = String(text[text.index(after: bar)..<tail]).trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty, !url.isEmpty else { return nil }
        return BrowserLiveSession(site: site, url: url, ts: Date())
    }
}

/// 发起直播的输入面板（附件面板「浏览器」按钮 → 填 URL → 拉起直播弹窗）
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
                    Text("AI 操作浏览器时画面会实时同步到这里（约 1 秒一帧，仅 Wi-Fi 下可用）。")
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

struct BrowserLiveView: View {
    let session: BrowserLiveSession
    let auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var uiImage: UIImage?
    @State private var status: String = "连接中…"
    @State private var ended = false
    /// 蜂窝/网络失败的独立提示态（不与 ended 混用：ended=收尾，提示可恢复）
    @State private var cellularMode = false
    /// 连续失败计数：单次抖动只累计，≥5 才判直播结束
    @State private var failCount = 0

    private var filePath: String { "/api/files/download?path=\(session.remoteName)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let img = uiImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                } else if ended {
                    Label("直播已结束", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if cellularMode {
                    Label("蜂窝网络下暂不支持实时画面，切回 Wi-Fi 自动恢复", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(status)
                }
                Text(session.url)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("🖥 浏览器实时画面")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        // 唯一轮询入口：.task 闭包默认 MainActor 隔离，改 @State 合法；视图销毁自动取消。
        // v4.0.74 审查修复：删掉 onReceive+Task 组合（那个 Task 是 nonisolated，改 @State 是未定义行为）。
        .task {
            while !ended {
                await pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
