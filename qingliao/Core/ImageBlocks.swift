import Foundation

// MARK: - 图块构造的**唯一入口**（v4.0.x 收口）
//
// 为什么要有这一层：`scripts/ql_imgsend/truth_table_imgsend.swift` 钉着「全 App 里 image_url
// 图块构造点**恰好 1 处**」——多一处就等于绕过了那条决策：图片必须以 base64 内嵌发送，
// 绝不许把自家 URL 交给上游（2026-09-23 实锤：自家域只有 AAAA，上游是 IPv4 云 → 必现
// `HTTP 400 .messages[1].image[0]: Failed to download image from https://webui.<域名>...`）。
//
// v4.0.x 的「拍照识别」全屏看图页也要发图（`QingliaoIntentClient.oneShot(imageDataURL:)`）——
// 它**不改**这条决策，只复用同一个构造点：收口到这里，而不是在那个文件里另拼一份块。
//
// ⚠️ 真值表是按**字面量**数构造点的，所以本文件里那一行的变量名必须保持 `img`
//    —— 改个名不改语义也会让护栏数不到 → 假红。
//    同理：这里刻意**不**把那行原样抄进注释（ql_imgsend 表数的是源文件原文，注释里出现也算一处，
//    本文件刚创建时就因为注释抄了一遍而假红过）。

enum ImageBlocks {

    /// 文本 + 图的 content 块。
    /// `text` 为空 → 只给图块（纯图消息，后端 `_msg_has_image` 认得住，净化时不会被当空文本剔掉）。
    static func content(text: String, img: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        blocks.append(["type": "image_url", "image_url": ["url": img]])
        return blocks
    }
}
