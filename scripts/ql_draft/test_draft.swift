import Foundation

// 轻聊输入框草稿 · 行为真值表（v4.0.103 待做池 #5）
// 编的是**生产源码** qingliao/Core/ChatDraftStore.swift（纯 Foundation，Linux 可编）——不是镜像实现。
// 这条链路的退化在本地**完全静默**：草稿丢了不崩溃、不打日志、编译全绿、其它表照旧过，
// 只有用户「切会话 / 杀后台回来」才发现打的字没了。所以下列四件事必须真跑：
//   ① 按会话隔离（A 的草稿不许出现在 B）
//   ② 重载仍在（= 「杀后台回来还在」的语义）
//   ③ 发送才清（clear 之后重载仍空，不许「复活」）
//   ④ 容量上限收敛（聊过几百个会话不许变成几百条常驻 UserDefaults）
var pass = 0
var fail = 0
@MainActor func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let suiteName = "ql-draft-test-" + UUID().uuidString
let suite: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

// 测试里把节流窗口拉到 600s：这样「没 flush 就不落盘」是**确定性事实**，
// 而不是「第 36 行到第 37 行之间主线程别被饿置超过 0.4s」的赌注（CI 负载重时会假红）。
// 生产值本身由下面那条断言与源码契约表一起钉住（defaultCoalesceWindow = 0.4）。
@MainActor func fresh() -> ChatDraftStore { ChatDraftStore(defaults: suite, coalesceWindow: 600) }

ck("默认节流窗口 = 0.4s（出厂口径，注入不影响生产值）", ChatDraftStore.defaultCoalesceWindow == 0.4)

let longText = "你好，这是 A 会话里打了一半的话"
let s1 = fresh()
ck("初始：任何会话都没有草稿", s1.draft(for: "A").isEmpty && s1.draft(for: "B").isEmpty)

s1.set(longText, for: "A")
ck("写入即读回", s1.draft(for: "A") == longText)
s1.set("B 的草稿", for: "B")
ck("按会话隔离：A 不受 B 影响", s1.draft(for: "A") == longText && s1.draft(for: "B") == "B 的草稿")
s1.set("飘在外面的字", for: "")
ck("空 sid 不落档（读回空）", s1.draft(for: "").isEmpty)

// 写盘有 0.4s 节流（ChatDraftStore.defaultCoalesceWindow；键盘每敲一下都整表写盘是纯浪费）。
// 先取证节流窗口内确实没落盘 —— 这正是「离开前台 / 切会话必须 flush」这条接线的存在理由：
s1.set("还没落盘的 C", for: "C")
ck("节流窗口内尚未写盘（刻意取舍，靠 flush 两时机兜底：离开前台 / 切会话）", fresh().draft(for: "C").isEmpty)

// 模拟「离开前台 / 切会话」的显式落盘点：
s1.flush()
let s2 = fresh()
ck("flush 后重载仍在 = 杀后台回来草稿还在",
   s2.draft(for: "A") == longText && s2.draft(for: "B") == "B 的草稿" && s2.draft(for: "C") == "还没落盘的 C")

s2.clear(for: "A")
ck("clear 后本会话为空", s2.draft(for: "A").isEmpty)
ck("clear 不误伤别的会话", s2.draft(for: "B") == "B 的草稿")
// clear 是明确语义点（用户刚点发送）→ 内部直接 flush，不需要外部再补一次
let s3 = fresh()
ck("clear 立即落盘、重载不复活（无需额外 flush）", s3.draft(for: "A").isEmpty && s3.draft(for: "B") == "B 的草稿")

s3.set("", for: "B")
ck("写空串 = 删除该键（盘上不留空条目）", fresh().draft(for: "B").isEmpty)

let s4 = fresh()
for i in 0..<55 {
    // 每次写入隔 ~2ms：ChatDraftStore 用 Date() 记最后写入时刻做容量淘汰，
    // 紧循环里时间戳可能撞成同值 → 排序不稳定会让「留最新」这条变成掷骰子。
    Thread.sleep(forTimeInterval: 0.002)
    s4.set("draft-\(i)", for: "s\(i)")
}
s4.flush()   // 容量淘汰发生在内存镜像里，读盘取证前先落盘
let rawCount = suite.dictionary(forKey: UserDefaultsKey.chatDrafts)?.count ?? -1
ck("超上限后盘上收敛到 \(ChatDraftStore.maxSessions) 份（实得 \(rawCount)）", rawCount == ChatDraftStore.maxSessions)
ck("淘汰的是最旧的", s4.draft(for: "s0").isEmpty && s4.draft(for: "s4").isEmpty)
ck("留下的是最新的", s4.draft(for: "s5") == "draft-5" && s4.draft(for: "s54") == "draft-54")

UserDefaults().removePersistentDomain(forName: suiteName)
print(fail == 0 ? "✅ ALL PASS（\(pass) 项）" : "❌ \(fail) 项失败")
exit(fail == 0 ? 0 : 1)
