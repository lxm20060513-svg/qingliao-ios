import Foundation

// MARK: - v3.9.79 图片翻译（AI 识别浮层的「AI 翻译」胶囊）
//
// 用户拍板：「拍照/相册旁边加第三颗『AI 翻译』：点它 → 拍照或选图 → 直接出译文（不再给动作条）」，
// 方向口径选 **自动双向**（中文→英文、其他语言→中文）。
//
// 为什么单独一个纯 Foundation 文件：判方向 + 组装提示词是**可测的纯逻辑**（本仓约定：判定不进视图，
// 真值表能镜像断言）；视图侧只负责「什么时候调它」。本文件不含 SwiftUI，也不碰网络。

enum TranslateKit {

    /// 目标语言：文本里出现汉字 → 翻成英文；否则（英文 / 其他拉丁文字）→ 翻成中文。
    /// ⚠️ 已知口径限制（写清楚，别让下个会话当 bug）：日文/韩文里混写的汉字同样会被判成「中文」→ 翻成英文。
    ///    对日文来说「翻成英文」也说得过去，故不做语种识别（本机不引模型、不联网）。
    static func targetLabel(for text: String) -> String {
        containsHan(text) ? "英文" : "中文"
    }

    /// 发给 AI 的提示词 —— 与聊天页「翻译」快捷入口同一句式（「请将以下内容翻译成…（保留原意）」），
    /// 只把方向换成动态判定，并强调**只输出译文**（避免 AI 附一段解释把译文淹没）。
    static func prompt(for text: String) -> String {
        "请把下面这段文字翻译成\(targetLabel(for: text))（保留原意，只输出译文）：\n\(text)"
    }

    /// 是否含汉字（CJK 统一表意文字基本区）。判据只认基本区：扩展区/兼容区极少出现在 OCR 结果里。
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
