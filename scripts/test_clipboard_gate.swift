// 剪贴板提示去重逻辑真值表（v3.8.1）
// 被测逻辑：qingliao/Core/ClipboardPromptGate.swift（生产代码，非镜像）
// 用法：./check_swift.sh 第 7 步

import Foundation

var failures = 0
var total = 0

func check(_ name: String, _ expect: Bool, _ actual: Bool) {
    total += 1
    if expect == actual {
        print("✅ \(name)")
    } else {
        print("❌ \(name) — 期望 \(expect)，实际 \(actual)")
        failures += 1
    }
}

// ① 冷启动首次见到新内容：没处理过 → 应提示
check("首次启动·剪贴板有新内容 → 提示",
      false,
      ClipboardPromptGate.isHandled(changeCount: 5, lastHandledChange: -1,
                                    lastHandledUptime: 0, currentUptime: 120))

// ② 同一份内容、同一次开机内再次进 App：处理过 → 不再提示
check("同一次开机·同一份内容再进 App → 不提示",
      true,
      ClipboardPromptGate.isHandled(changeCount: 5, lastHandledChange: 5,
                                    lastHandledUptime: 100, currentUptime: 300))

// ③ 用户又拷贝了新内容：changeCount 变了 → 应提示（回归用例：别把去重做成一刀切）
check("拷贝了新内容（changeCount 变化）→ 提示",
      false,
      ClipboardPromptGate.isHandled(changeCount: 6, lastHandledChange: 5,
                                    lastHandledUptime: 100, currentUptime: 130))

// ④ 设备重启过：uptime 变小、changeCount 从头计数 → 旧记录作废，应提示
check("设备重启后·changeCount 回退 → 记录作废、提示",
      false,
      ClipboardPromptGate.isHandled(changeCount: 2, lastHandledChange: 12,
                                    lastHandledUptime: 90000, currentUptime: 40))

// ⑤ 边界：uptime 相等（同一瞬间重复调用）仍按 changeCount 比较
check("边界·uptime 相等且 changeCount 相同 → 不提示",
      true,
      ClipboardPromptGate.isHandled(changeCount: 9, lastHandledChange: 9,
                                    lastHandledUptime: 500, currentUptime: 500))

// ⑥ 边界：uptime 相等但 changeCount 不同 → 提示
check("边界·uptime 相等但 changeCount 不同 → 提示",
      false,
      ClipboardPromptGate.isHandled(changeCount: 10, lastHandledChange: 9,
                                    lastHandledUptime: 500, currentUptime: 500))

// ── v3.9.72：探测门（用户报「剪切板有内容不要每次进 App 都提示」）──
// 新门口径：比"上次进 App 时看到的那一版"，内容没变就静默；不再比"上次处理过的那一版"
// （从没点过忽略、或中途设备重启，都不该让同一份内容每次进 App 重弹）。
check("v3.9.72·同一份内容再进 App → 静默（不探不提示）",
      true,
      ClipboardPromptGate.decide(changeCount: 7, lastSeenChange: 7) == .silentSameContent)

check("v3.9.72·剪贴板变了 → 探一次（保住「在别处拷了链接切回来」那条路）",
      true,
      ClipboardPromptGate.decide(changeCount: 8, lastSeenChange: 7) == .probe)

check("v3.9.72·首次（还没有记录）→ 探一次",
      true,
      ClipboardPromptGate.decide(changeCount: 3, lastSeenChange: -1) == .probe)

check("v3.9.72·设备重启后计数回退（8 → 2）→ 仍算变了，探一次",
      true,
      ClipboardPromptGate.decide(changeCount: 2, lastSeenChange: 8) == .probe)

check("v3.9.72·自动收起时长在合理区间（0 = 永不收起、过大 = 形同不收起）",
      true,
      ClipboardBanner.autoHideSeconds > 3 && ClipboardBanner.autoHideSeconds <= 30)

// 源码级护栏：UI 层必须真的用新门 + 挂自动收起（别被改回旧门 / 悄悄拆掉定时）
let chatSrc = (try? String(contentsOfFile: "qingliao/Features/Chat/ChatView.swift", encoding: .utf8)) ?? ""
check("v3.9.72·ChatView 用 decide 门", true, chatSrc.contains("ClipboardPromptGate.decide("))
// 计数式：定义 1 处 + 两个弹条分支各 1 处 = 3；只拆掉其中一处也必须报红
// （首版只写 contains → 实测「拆掉定位分支那次调用」仍绿，等于半个护栏）
func occurrences(_ needle: String, in hay: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}
check("v3.9.72·自动收起接线完整（定义+两个弹条分支 = 3）",
      true, occurrences("scheduleClipboardAutoHide()", in: chatSrc) >= 3)
check("v3.9.72·交互取销接线完整（定义 + 四处按钮 = 5）",
      true, occurrences("cancelClipboardAutoHide()", in: chatSrc) >= 5)

print(failures == 0 ? "🎉 剪贴板去重真值表全部通过（\(total) 条）" : "❌ 剪贴板去重真值表失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
