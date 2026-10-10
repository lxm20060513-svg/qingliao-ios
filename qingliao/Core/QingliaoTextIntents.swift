import AppIntents
import Foundation

// MARK: - 划词类动作（v4.0.91 · 配合 iOS 27 快捷指令的「获取所选文字 / 获取屏幕上有什么」）
//
// 场景：任意 App（微信 / Safari / 邮件 / 公众号）里选中一段文字 → 交给轻聊。
// 两条入口，**都不新增 Siri 短语**（每 App 最多 10 条 App Shortcuts，本仓已用 9 条）：
//   · 快捷指令：「获取所选文字」/「获取屏幕上有什么」→ 把文本喂进下面的 `文字` 参数
//     （String 参数能吃系统的任意文本输入源：所选文字、剪贴板、上一步的输出）
//   · 共享表单：分享扩展本来就收纯文本（project.yml 里 NSExtensionActivationSupportsText），
//     划词分享 → 轻聊，走的还是同一批 intent
//
// ⚠️ 回答的**去处**要说清楚（别当成 bug 又来修）：这里走的是后端一次性接口
//    `/api/stream/chat`（非流式、无界面 intent 里唯一可行的链路），所以
//    **答案会回给快捷指令的下一步**（可念、可存备忘、可继续追问），
//    **不会**自动落进 App 里的某个会话 —— 会话落库是 App 自己调 `/api/sessions/merge` 干的，
//    无界面进程里没有那套流式任务。想要「落进会话」的用法：在快捷指令里接一步「打开轻聊」，
//    或者直接把答案接到「记到轻聊备忘录」。
//
// 与 AskQingliaoIntent 的分工：那条是「我有个问题要问」（问题在手），这条是「这段文字要处理」
// （材料在手）。两者后端链路相同，只是提示词形态不同 —— 别把两条合并成一条带可选参数的。

struct AskAboutTextIntent: AppIntent {

    static var title: LocalizedStringResource { "拿这段文字问轻聊" }

    static var description: IntentDescription {
        IntentDescription("把选中/分享来的一段文字交给轻聊的 AI 回答（例如「这条合同条款对我有什么风险」），返回值可直接接下一步")
    }

    @Parameter(title: "文字", description: "要处理的文字，可接快捷指令的「获取所选文字」")
    var text: String

    @Parameter(title: "问题", description: "留空按「这段文字是什么意思」处理")
    var question: String?

    @Parameter(title: "回答风格", description: "留空按「一句话」处理")
    var style: AskStyle?

    @Parameter(title: "朗读回答", description: "关掉则只回一句提示，不在这里念正文", default: true)
    var readAloud: Bool

    /// 送进模型的文字上限：一次划词/分享的资料量级足够，再长就该走文件或会话了
    /// （提示词太长会把主模型的上下文挤爆，回答质量反而掉）。
    static let textLimit = 4000

    static var parameterSummary: some ParameterSummary {
        Summary("拿这段文字问轻聊 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw QingliaoIntentError(message: "选中的文字是空的（检查一下「获取所选文字」那一步）")
        }
        let auth = try QingliaoIntentClient.auth()
        let answer = try await QingliaoIntentClient.oneShot(
            Self.prompt(text: body, question: question ?? "", style: style ?? .concise), auth: auth)
        guard readAloud else {
            // 只回提示：完整回答仍走 value，需要时在快捷指令里接「显示结果」「记到轻聊备忘录」
            return .result(value: answer, dialog: "轻聊已回答")
        }
        return .result(value: answer, dialog: qlDialog(QingliaoAIReply.shorten(answer)))
    }

    /// 提示词组装（纯函数 → 可被真值表钉住：划词场景必须带上下文、风格前缀只在开头出现一次）
    static func prompt(text: String, question: String, style: AskStyle) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = q.isEmpty ? "这段文字是什么意思？" : q
        let material = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
        return """
        \(style.instructionPrefix)下面是我从别处选中（或分享进来）的一段文字，请只针对它回答。

        【文字】
        \(material)

        【我的问题】
        \(ask)
        """
    }
}
