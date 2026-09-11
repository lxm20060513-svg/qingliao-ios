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

print(failures == 0 ? "🎉 剪贴板去重真值表全部通过（\(total) 条）" : "❌ 剪贴板去重真值表失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
