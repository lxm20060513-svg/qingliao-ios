import Foundation
import UIKit

// MARK: - v3.9.71 抽取链编排（输入收口的总入口）
//
// 三层按"越省事越优先"排队，任何一层给出强格式就停：
//   ① 规则（IntentPipeline，纯本机、零延迟）—— 强格式（快递单号/链接/电话/金额/地址）
//   ② 端侧 OCR（Vision）—— 图片入口先取字，再回到 ①（标记 provenance = .ocr）
//   ③ 端侧语义（Foundation Models，iOS 26 且设备支持）—— 规则认不出的模糊文本
//   ④ 云端兜底（/api/agent/intent/extract，6 秒超时）—— 前面都认不出，且已登录
// 全挂了就返回 ① 的 .text 兜底（动作条只给「问 AI / 复制」，绝不猜）。
//
// 契约（后端未部署时 App 完全可用）：④ 是可选加速，不是依赖——后端没接线时这里静默返回 nil。

@MainActor
enum IntentExtractor {

    /// 云端兜底超时（超过就不等了，直接用本地兜底；用户已经等了一次点击）
    private static let cloudTimeout: TimeInterval = 6

    // MARK: 文本入口（手动粘贴 / 大爆炸选词 / 分享进来的文本）

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
        var ocrText: String?
        if let t = await IntentOCRExtractor.recognizeText(in: image), !t.isEmpty { ocrText = t }

        if let t = ocrText {
            var rule = IntentPipeline.classify(text: t)
            if rule.kind != .text {
                // 字是 OCR 认出来的：标记来源，便于排查"是不是认错了"
                rule.provenance = .ocr
                return rule
            }
            if let onDevice = await onDeviceExtract(t) { return onDevice }
        }

        // 前面都认不出：把图直接交给云端视觉模型（能看图，比 OCR 出字再判更准）。未登录就到此为止。
        let b64 = ocrText == nil ? jpegBase64(image) : nil
        if let cloud = await cloudExtract(text: ocrText, imageBase64: b64, auth: auth) { return cloud }

        // OCR 有字但没有强格式 → 至少让用户能对这段字「问 AI / 复制」
        guard let t = ocrText else { return nil }
        return IntentPipeline.classify(text: t)
    }

    // MARK: - ②③④ 各层

    private static func onDeviceExtract(_ text: String) async -> RecognizedIntent? {
        guard #available(iOS 26.0, *) else { return nil }
        return await IntentOnDeviceExtractor.extract(text)
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

        var fields: [String: String] = [:]
        if let f = j["fields"] as? [String: Any] {
            for (k, v) in f { fields[k] = String(describing: v) }
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
    private static func jpegBase64(_ image: UIImage, maxDimension: CGFloat = 1600,
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
