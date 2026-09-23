import Foundation

// MARK: - v3.9.71 端侧语义抽取（Foundation Models，iOS 26）
//
// 规则层认不出来的模糊文本（"楼下那家店刷了三百多"）交给**设备上的模型**判类型。
// 只在满足两个前提时才用：
//   ① 设备支持（SystemLanguageModel.availability == .available，iPhone 15 Pro 及更新的 A17 Pro+）
//   ② 规则层给的是 .text 兜底（强格式已经有答案，没必要再问一遍）
// 不满足就交给云端兜底（IntentExtractor），App 不会因为端侧不可用而少功能。
//
// ⚠️ 本文件是**唯一没法在本机真值表里跑**的一层（要 iOS 26 SDK + 真机神经引擎），
//    所以它刻意只做"文本 → 结构"这一件事，判断规则全部留在 IntentPipeline（那份有 130 项真值表）。
//    改动这里之后必须真机各测一遍：支持设备（可用）+ 老设备（自动退云端）。

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum IntentOnDeviceExtractor {

    /// 引导生成的结构（@Generable = 让模型直接吐这个类型，不用自己解 JSON）
    @Generable
    struct Payload {
        @Guide(description: "内容类型，只能是以下之一：express=快递单号, address=地址, contact=电话或邮箱, link=链接, amount=金额或读数, datetime=日期时间, text=普通文本")
        var kind: String

        @Guide(description: "一句话中文摘要，不超过 20 字")
        var title: String

        @Guide(description: "关键值：amount 填数字（不带单位）；express 填单号；contact 填电话或邮箱；datetime 填 ISO8601 时间；其它留空")
        var value: String

        @Guide(description: "金额或读数的单位：元 / 度 / kWh；其它类型留空")
        var unit: String
    }

    /// 设备是否可用端侧模型
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 判类型。失败/不可用返回 nil（调用方接云端兜底或原样兜底）
    static func extract(_ text: String) async -> RecognizedIntent? {
        guard isAvailable else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 500 else { return nil }

        // 单轮任务，开新 session（多轮上下文会互相污染）
        let session = LanguageModelSession(instructions: """
            你在做内容识别。只判断下面这段内容属于哪种类型，并给一行摘要。
            不要解释，不要输出思考过程，不要给建议。
            """)
        let prompt = "内容：\(trimmed)"
        guard let response = try? await session.respond(to: prompt, generating: Payload.self) else { return nil }
        let p = response.content

        guard let kind = IntentKind(rawValue: p.kind.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // 端侧只说"是金额/是链接"这种；真正的强格式由规则层拿。这里守住：模型说是链接却没有链接，
        // 一律降级成 text（宁可让用户点"问 AI"，也不能凭空给个假结论）
        if kind == .link, IntentPipeline.classify(text: trimmed).kind != .link { return nil }

        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        let value = p.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = p.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { fields["value"] = value }
        if !unit.isEmpty { fields["unit"] = unit }
        if kind == .contact, value.contains("@") { fields["type"] = "email" }

        var intent = RecognizedIntent(kind: kind,
                                      title: title.isEmpty ? String(trimmed.prefix(20)) : title,
                                      fields: fields,
                                      raw: trimmed,
                                      confidence: 0.7,          // 端侧 0.6~0.9 区间，取中
                                      provenance: .onDevice,
                                      actions: [])
        intent.actions = IntentPipeline.actions(for: intent)
        return intent
    }
}
#endif
