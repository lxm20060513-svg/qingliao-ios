// MARK: - ChatView 导出/分享/消息操作（从 ChatView.swift 拆出，v3.0.81）

import SwiftUI
import PDFKit

extension ChatView {
    /// v2.0.96：消息撤回（标记 withdrawn → 显示"已撤回"占位 + 服务器同步）
    func withdrawMessage(_ msg: ChatMessage) {
        if let idx = chat.messages.firstIndex(where: { $0.id == msg.id }) {
            chat.messages[idx].withdrawn = true
            Task { await chat.saveToServer(auth: auth) }
        }
    }

    /// v2.0.92：分享会话卡片（最近 15 条渲染成图片 → 系统分享/微信）
    func shareSessionCard() {
        let msgs = Array(chat.messages.suffix(15))
        guard !msgs.isEmpty else { return }
        let rows = msgs.map { msg -> (role: String, text: String) in
            if msg.withdrawn { return (msg.role, "[已撤回]") }
            var t = msg.content.replacingOccurrences(of: "\n", with: " ")
            if t.count > 120 { t = String(t.prefix(120)) + "…" }
            return (msg.role, t)
        }
        let card = SessionCardView(rows: rows)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3   // @3x 高清
        guard let img = renderer.uiImage else { return }
        presentShare([img])
    }

    /// v3.3.0：多选合并发送——勾选消息按时间序打包成一张卡片图片 → 系统分享（微信可发）
    /// 内容只丢原文不加工；图片/语音/撤回消息降级为占位文本
    func mergeAndShare() {
        let picked = chat.messages.filter { selectedMsgIDs.contains($0.id) }
        guard !picked.isEmpty else { return }
        if picked.count > Self.maxMergeCount {
            mergeTooMany = true
            return
        }
        let rows = picked.map { msg -> (role: String, text: String) in
            if msg.withdrawn { return (msg.role, "[已撤回]") }
            if let img = msg.imageDataURL, !img.isEmpty { return (msg.role, "[图片]") }
            if msg.audioPath != nil { return (msg.role, "[语音]") }
            var t = msg.content.replacingOccurrences(of: "\n", with: " ")
            if t.count > 120 { t = String(t.prefix(120)) + "…" }
            return (msg.role, t)
        }
        let card = SessionCardView(rows: rows)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3   // @3x 高清
        guard let img = renderer.uiImage else { return }
        exitSelectMode()
        presentShare([img])
    }

    /// v2.0.36：单条删除（按索引精确删除，防同内容 hash id 误删）
    /// v2.0.102：同步移除对应排队项（修复排队消息删除后"复活"自动重发）
    func deleteMessage(_ msg: ChatMessage) {
        if let idx = chat.messages.firstIndex(where: { $0.timestamp == msg.timestamp && $0.role == msg.role && $0.content == msg.content }) {
            withAnimation { chat.messages.remove(at: idx) }
            pendingQueue.removeAll { $0.text == msg.content && $0.imageData == msg.imageDataURL }
            Task { await chat.saveToServer(auth: auth) }
        }
    }

    /// v2.0.36+88：系统分享（微信分享扩展不支持纯文本 → 自动转 原图/URL/文字图片）
    func shareMessage(_ msg: ChatMessage) {
        // 1) 图片消息：分享原图（微信支持图片；原来分享 "[图片]" 文本会失败）
        if let urlStr = msg.imageDataURL, !urlStr.isEmpty,
           let img = dataURLImage(urlStr) {
            presentShare([img])
            return
        }
        let text = msg.content
        guard !text.isEmpty else { return }
        // 2) 纯链接：分享 URL（微信支持网页链接）
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           !trimmed.contains(" ") {
            presentShare([url])
            return
        }
        // 3) 普通文本：渲染成文字图片再分享（微信唯一接受的文本形态）
        if let img = textShareImage(text) {
            presentShare([img])
        } else {
            presentShare([text])   // 兜底：渲染失败退回原始文本
        }
    }

    /// 分享面板统一弹出（v2.0.88：iPad 必须提供 popover 锚点，否则崩溃）
    func presentShare(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
        }
        root.present(av, animated: true)
    }

    /// 文本 → 分享图片（固定白底深字，宽度固定高度自适应，微信友好）
    func textShareImage(_ text: String) -> UIImage? {
        let maxChars = 2000
        var content = textShareClean(text)
        if content.count > maxChars {
            content = String(content.prefix(maxChars)) + "\n\n…（内容过长，已截断）"
        }
        let width: CGFloat = 320
        let hPad: CGFloat = 20
        let vPad: CGFloat = 24
        let font = UIFont.systemFont(ofSize: 16)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: 0.13, alpha: 1),
            .paragraphStyle: para
        ]
        let ns = content as NSString
        let drawSize = CGSize(width: width - hPad * 2, height: .greatestFiniteMagnitude)
        let box = ns.boundingRect(with: drawSize,
                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: attrs, context: nil)
        let height = ceil(box.height) + vPad * 2
        guard height < 4000 else { return nil }   // 极端超长防爆内存
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            UIColor(white: 1, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ns.draw(with: CGRect(x: hPad, y: vPad, width: drawSize.width, height: box.height + 20),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs, context: nil)
        }
    }

    /// 分享前轻量清理 markdown 符号（转图片后更干净）
    func textShareClean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "### ", with: "")
        t = t.replacingOccurrences(of: "## ", with: "")
        t = t.replacingOccurrences(of: "# ", with: "")
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "> ", with: "")
        return t
    }

    // MARK: - v2.0.84 文件整份上传（原件存 NAS，文本类/PDF 同时提取内容给 AI）

    /// v2.0.86s：上传结果细分（区分服务器拒绝 / 蜂窝限制 / 连接失败，提示不误导）
    enum UploadResult {
        case success
        case rejected(String)       // 服务器返回错误（带信息）
        case networkFailed(String)  // 网络/连接失败（错误信息含蜂窝限制时提示 WiFi/Web）
    }

    /// 上传整份文件到 NAS（/api/files/upload；WiFi 直连可传大文件，蜂窝 relay 受限自动失败）
    func uploadFile(_ url: URL, name: String) async -> UploadResult {
        guard let data = try? Data(contentsOf: url) else { return .rejected("文件读取失败") }
        do {
            let j = try await auth.uploadMultipart("/api/files/upload", fileName: name, data: data)
            if (j["ok"] as? Bool) == true { return .success }
            return .rejected(j["message"] as? String ?? j["error"] as? String ?? "上传失败")
        } catch {
            return .networkFailed("\(error)")
        }
    }

    func sendFile(_ url: URL) {
        // v2.0.102：流式中发文件不再静默丢弃——明确提示
        guard !stream.isStreaming else {
            fileSendBlocked = true
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()

        Task {
            // v2.0.102：安全作用域在 Task 内保持到读取完成（原 defer 提前释放导致 iOS 读取失败）
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // 整份上传 NAS（原件服务器保留，可下载）
            let result = await uploadFile(url, name: name)
            var content: String
            switch result {
            case .success:
                if ["txt", "md", "log", "json", "csv"].contains(ext),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    // 文本类：上传原件 + 提取前 12000 字给 AI 阅读
                    content = "[文件: \(name)]（已上传 NAS）\n\(String(text.prefix(12000)))"
                } else if ext == "pdf" {
                    // PDF：上传原件 + PDFKit 提取文本给 AI
                    let raw = extractPDFText(from: url) ?? ""
                    content = raw.isEmpty
                        ? "[PDF: \(name)]（已上传 NAS，扫描件无文字层）"
                        : "[PDF: \(name)]（已上传 NAS）\n\(String(raw.prefix(12000)))"
                } else {
                    // Word/Excel 等：整份上传（本地不提取，文件在 NAS 可下载）
                    content = "[文件: \(name)]（已上传 NAS）"
                }
            case .rejected(let msg):
                // v2.0.86s：服务器拒绝（磁盘满/路径错误等）→ 显示具体原因
                content = "[文件: \(name)]（上传失败：\(msg)）"
            case .networkFailed(let msg):
                // v2.0.86s：蜂窝 relay 上行 ~2KB 限制大文件；WiFi 网络异常则提示重试
                if msg.contains("蜂窝") || msg.contains("文件过大") || NetworkMonitor.shared.isCellular {
                    content = "[文件: \(name)]（上传失败：蜂窝网络限制大文件，请连接 WiFi 重试或使用 Web 版上传）"
                } else {
                    content = "[文件: \(name)]（上传失败：连接异常，请重试）"
                }
            }
            // v3.0.84fix：云端模式文件消息走 startCloudStream（原 stream.start 打本地 NAS，云端 sendFile 链路报废）
            if CloudConfig.shared.isCloudMode {
                let m = ChatMessage.local(role: "user", content: content)
                chat.append(m)
                startCloudStream(for: m)
            } else {
                // v3.3.3：接住 m 作为落库锚点（防延迟回调把文件回复贴到新消息后）
                let m = ChatMessage.local(role: "user", content: content)
                chat.append(m)
                let history = chat.historyPayload()
                // v3.0.81：统一模型优先级链（免费 > 视觉 > Agent > 主模型）
                let (useModel, useProvider) = resolveModel()
                stream.pendingUserMsgId = m.id   // v3.3.3：文件消息流锚点
                await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                                   provider: useProvider, messages: history) { success, error in
                    if !success {
                        chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(error)" : stream.content + "\n\n⚠️ \(error)", agent: stream.isAgent, afterUserID: m.id)
                    } else {
                        chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: m.id)
                        showSentOK()
                        // v2.0.36：App 退后台时 AI 回复完成发本地通知
                        if UIApplication.shared.applicationState != .active {
                            NotificationHelper.notify(title: "轻聊", body: "AI 回复完成，点击查看",
                                                      sessionId: chat.sessionId)
                        }
                    }
                    Task { await chat.saveToServer(auth: auth) }
                }
            }
        }
    }

    /// PDFKit 提取文本（文本型 PDF 才有内容；扫描件无文字层返回空）
    func extractPDFText(from url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.string
    }
}
