// 测试替身：只提供 UserDefaultsKey.chatDrafts 一个常量。
// 为什么需要：Models.swift 带 `import SwiftUI`，Linux 上编不了；行为表要真跑生产源码
// ChatDraftStore.swift，又必须解析 UserDefaultsKey.chatDrafts 这个符号。
// ⚠️ 替身与真值**不许漂移** —— truth_table_draft.swift 会读 Models.swift 与本源文件逐字比对键字面量，
//    两处不一致直接判红。
enum UserDefaultsKey { static let chatDrafts = "qingliao_chat_drafts" }
