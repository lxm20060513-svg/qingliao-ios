import Foundation
import UIKit

// MARK: - v3.9.71 抽取链编排（输入收口的总入口）
//
// 四层按"越省事越优先"排队，任何一层给出强格式就停：
//   ① 规则（IntentPipeline，纯本机、零延迟）—— 强格式（快递单号/链接/电话/金额/地址）
//   ② 端侧 OCR（Vision）—— 图片入口先取字，再回到 ①（标记 provenance = .ocr）
//   ③ 端侧语义（Foundation Models，iOS 26 且设备支持）—— 规则认不出的模糊文本
//   ④ 云端兜底（/api/agent/intent/extract，6 秒超时）—— 前面都认不出，且已登录
// 全挂了就返回 ① 的 .text 兜底（动作条只给「问 AI / 复制」，绝不猜）。
//
// **本版实际接线的输入源只有三条**（别被历史注释误导）：
//   · 聊天页图片预览条「识别」 · 大爆炸选词「识别」 · 剪贴板链接提示「识别」
// 尚未接线的入口（写在这里，免得后人以为已经在工作）：系统分享收件（drainShareInbox）、
// 聊天输入框粘贴、文件导入、消息长按菜单。这些是后续批次的事，本版没接。
//
// 并发纪律（v3.9.71 双审查打回，本机预检查不出、只有 CI Archive 会炸）：
//   · `UIImage` 不是 Sendable。它在 @MainActor 的 extract(image:) 里**只能交给 scanImage 一次**，
//     之后再回主隔离碰它 = `sending 'image' risks causing data races`（Swift 6 下是错误而非警告）。
//     所以 OCR 与 JPEG 编码全部收进 scanImage 的同一个后台闭包——顺带修掉"12MP 原图编码跑主线程"。
//   · 云端兜底是**可选加速，不是依赖**：后端没接线时这里静默返回 nil，App 功能不缺。

@MainActor
enum IntentExtractor {

    /// 云端兜底超时（超过就不等了，直接用本地兜底；用户已经等了一次点击）
    private static let cloudTimeout: TimeInterval = 6

    // MARK: 文本入口（手动粘贴 / 大爆炸选词）

    static func extract(text: String, auth: AuthStore?) async -> RecognizedIntent {
        let rule = IntentPipeline.classify(text: text)
        if rule.kind != .text { return rule }        // 强格式：本机已有答案，不再问人也不问云

        if let onDevice = await onDeviceExtract(text) { return onDevice }
        if let cloud = await cloudExtract(text: text, imageBase64: nil, auth: auth) { return cloud }
        return rule                                   // 兜底（只给问 AI / 复制）
    }

    // MARK: 图片入口（拍照 / 选图）

    /// 返回 nil = 图里确实什么都没有（调用方保持安静，不要弹"识别失败"）
    static func extract(image: UIImage, auth: AuthStore?) async -> RecognizedIntent? {
        let scan = await scanImage(image)             // image 到此为止，之后一律不再碰它
        let ocrText = scan.ocrText

        if let t = ocrText, !t.isEmpty {
            var rule = IntentPipeline.classify(text: t)
            if rule.kind != .text {
                // 字是 OCR 认出来的：标记来源，便于排查"是不是认错了"
                rule.provenance = .ocr
                return rule
            }
            if let onDevice = await onDeviceExtract(t) { return onDevice }
        }

        // 前面都认不出：把图交给云端视觉模型（能看图，比 OCR 出字再判更准）。未登录就到此为止。
        if let cloud = await cloudExtract(text: ocrText, imageBase64: scan.jpegBase64, auth: auth) {
            return cloud
        }

        // OCR 有字但没有强格式 → 至少让用户能对这段字「问 AI / 复制」
        guard let t = ocrText, !t.isEmpty else { return nil }
        return IntentPipeline.classify(text: t)
    }

    /// 一次扫描的结果（Sendable 值类型，可安全跨并发域）
    private struct Scan: Sendable {
        var ocrText: String?
        var jpegBase64: String?
    }

    /// 图里能做的两件事一次做完，**全程后台**：
    ///   ① Vision OCR 取字（perform 阻塞）
    ///   ② 认不出字时才把图压成 JPEG base64（4MB 原图编码放主线程 = 明显掉帧，审查第 9 条）
    /// 为什么要合成一个函数：`UIImage` 非 Sendable，主隔离把它交出去之后就不能再用——
    /// 两个 await 分别传 image 会直接踩 Swift 6 的 sending 报错（审查第 3 条）。
    nonisolated private static func scanImage(_ image: UIImage) async -> Scan {
        // nonisolated(unsafe)：这张图只被下面那个后台闭包使用一次，主隔离交出后不再触碰
        // （不加这行，@Sendable 闭包捕获 UIImage 在 Swift 6 下编译不过——与那个 dispatch 闭包同源）
        nonisolated(unsafe) let img = image
        return await withCheckedContinuation { (cont: CheckedContinuation<Scan, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let text = IntentOCRExtractor.recognizeText(in: img)
                let jpeg = (text?.isEmpty ?? true) ? jpegBase64(img) : nil
                cont.resume(returning: Scan(ocrText: text, jpegBase64: jpeg))
            }
        }
    }

    // MARK: - ②③④ 各层

    private static func onDeviceExtract(_ text: String) async -> RecognizedIntent? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await IntentOnDeviceExtractor.extract(text)
        #else
        // 工具链没有 FoundationModels 模块（旧 Xcode）：这层直接不存在。
        // 不写这个分支会出现"文件里有 #if、调用点没有"的不对称——换工具链就编译不过。
        return nil
        #endif
    }

    private static func cloudExtract(text: String?, imageBase64: String?,
                                     auth: AuthStore?) async -> RecognizedIntent? {
        guard let auth else { return nil }
        guard text != nil || imageBase64 != nil else { return nil }
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let imageBase64 { body["image_b64"] = imageBase64 }

        guard let j = try? await auth.json("/api/agent/intent/extract", method: "POST",
                                           body: body, timeout: cloudTimeout) else { return nil }
        guard (j["ok"] as? Bool) == true,
              let kindRaw = j["kind"] as? String,
              let kind = IntentKind(rawValue: kindRaw) else { return nil }

        // 字段收敛：JSON 里的 null 会经 String(describing:) 变成字面量 "<null>"，那会被当成单位/数值显示给用户
        var fields: [String: String] = [:]
        if let f = j["fields"] as? [String: Any] {
            for (k, v) in f {
                if let s = v as? String, !s.isEmpty { fields[k] = s }
                else if let n = v as? NSNumber { fields[k] = n.stringValue }
            }
        }
        let title = (j["title"] as? String) ?? ""
        let raw = text ?? ""
        var intent = RecognizedIntent(kind: kind,
                                      title: title.isEmpty ? String(raw.prefix(20)) : title,
                                      fields: fields,
                                      raw: raw,
                                      confidence: (j["confidence"] as? Double) ?? 0.6,
                                      provenance: .cloud,
                                      actions: [])
        intent.actions = IntentPipeline.actions(for: intent)
        return intent
    }

    // MARK: - 上传前的图片压缩
    //
    // 原图直传（4800×3600、4MB+）在蜂窝下要等十几秒，还容易被 relay 的 URL 长度限制顶掉。
    // 长边压到 1600、JPEG 0.7：文字类内容仍可辨认，体积通常 150~400KB。
    // nonisolated：只在 scanImage 的后台闭包里调用（这活儿绝不能占主线程）
    nonisolated private static func jpegBase64(_ image: UIImage, maxDimension: CGFloat = 1600,
                                              quality: CGFloat = 0.7) -> String? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        var target = size
        let longSide = max(size.width, size.height)
        if longSide > maxDimension {
            let scale = maxDimension / longSide
            target = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: quality), data.count <= 2_500_000 else { return nil }
        return data.base64EncodedString()
    }
}
