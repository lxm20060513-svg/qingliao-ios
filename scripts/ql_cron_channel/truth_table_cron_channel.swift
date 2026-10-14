// 定时任务「信息推送通道」—— 源级真值表（读源文件做护栏，不 import 项目代码）
//
// 为什么必须有这张表：通道是**两条腿**（微信由 Hermes 的 deliver 决定、App 任务中心由
//   ql_task_push.py 决定），App 侧只暴露一个四档选择。三处真值必须逐字对齐：
//     iOS CronChannel.all  ↔  后端 cron_api.CHANNELS  ↔  投递器 ql_task_push.APP_PUSH_CHANNELS
//   对不齐的表现全是**静默失效**：选了「仅 App」结果微信还是响、选了「仅微信」App 里还在冒
//   卡片、后端收到不认识的档位被丢弃回默认——编译不报错、日志不报错、只有用户手指能发现。
//
// ⚠️ 必须 cwd = 仓库根（下列路径是相对路径）。

import Foundation

var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意复述了「那样做是错的」，直接 grep 原文会被自己的注释判红）
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

/// 取函数/结构体体（从签名开始做**花括号配对**，取到深度归零）
/// ⚠️ 不能用「遇到第一个 4 空格缩进的 } 就收」：同名的 save()/init() 在别的 sheet 里也有，
///    早停会切到隔壁结构体上，断言会指着别人的代码说通过（本表第一次就踩了）。
func body(_ text: String, from sig: String) -> String {
    guard let r = text.range(of: sig) else { return "" }
    // depth 从 1 起：签名自带的 { 也要算，否则属性/方法体的第一个闭括号就会被当成
    // 结构体结束（真踩过：CronTask 切到 channelLabel 之前就停了）。
    var depth = 1
    var started = true
    var collected: [String] = []
    for line in text[r.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
        collected.append(String(line))
        var inStr = false
        var esc = false
        for ch in line {
            if esc { esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "\"" { inStr.toggle(); continue }
            guard !inStr else { continue }
            if ch == "{" { depth += 1; started = true }
            if ch == "}" { depth -= 1 }
        }
        if started && depth <= 0 { break }
    }
    return collected.joined(separator: "\n")
}

let settingRaw = src("qingliao/Features/Settings/SettingsCommon.swift")
let setting = code(settingRaw)

check("① 源可读（SettingsCommon）", settingRaw.count > 30000)

// ── ② 四档集合与后端逐字一致（改一边必须改另一边） ───────────────
let channelIDs = ["both", "wechat", "app", "none"]
let declared = channelIDs.filter { setting.contains("CronChannel(id: \"\($0)\"") }
check("② 四档 id 齐全 both/wechat/app/none（当前 \(declared.count)/4）", declared.count == 4)
for id in channelIDs {
    check("② 档位 \(id) 有 id + label 配对",
          setting.contains("CronChannel(id: \"\(id)\", label: "))
}
let labels = ["\"微信 + App\"", "\"仅微信\"", "\"仅 App\"", "\"不推送\""]
check("② 四档文案齐全（微信 + App / 仅微信 / 仅 App / 不推送）",
      labels.allSatisfy { setting.contains("label: \($0)") })

// ── ③ 默认档与兜底 ────────────────────────────────────────────
check("③ 新建默认档 = both（= 改动前老口径，不偷偷改变既有习惯）",
      setting.contains("static let defaultID = \"both\""))
check("③ 认不出的通道值说「未知通道」（不许硬套一个看着正常的档位）",
      setting.contains("未知通道"))
let chanStruct = body(setting, from: "struct CronChannel {")
check("③ label(_:) 有 fallback 分支", chanStruct.contains("?? \"未知通道\""))

// ── ④ CronTask 解析与展示 ─────────────────────────────────────
check("④ CronTask.channel 是**可选**（老后端不下发该键 → nil，不显示假通道）",
      setting.contains("let channel: String?"))
check("④ load() 从 d[\"channel\"] 解析（键名与后端下发一致）",
      setting.contains("channel: d[\"channel\"] as? String"))
let taskStruct = body(setting, from: "struct CronTask: Identifiable {")
check("④ channelLabel 走 CronChannel.label（不许各写一份映射）",
      taskStruct.contains("channel.map { CronChannel.label($0) }"))
let tasksView = body(setting, from: "struct TasksView: View {")
check("④ 列表行渲染 t.channelLabel（设了看得到）", tasksView.contains("t.channelLabel"))
check("④ 列表行用 if let 包住（nil 时整行不出现，不留空壳）",
      tasksView.contains("if let ch = t.channelLabel"))

// ── ⑤ 保存必须把通道写进去（新建 + 编辑两处） ──────────────────
let sheet = body(setting, from: "struct NewTaskSheet: View {")
check("⑤ NewTaskSheet 有 channel 状态", sheet.contains("@State private var channel"))
check("⑤ 编辑回填 editing?.channel，新建落默认档",
      sheet.contains("_channel = State(initialValue: editing?.channel ?? CronChannel.defaultID)"))
check("⑤ 选择器按 CronChannel.all 渲染（不是手抄四份判断）",
      sheet.contains("ForEach(CronChannel.all"))
check("⑤ 选中态 = accent 高亮（channel == c.id）",
      sheet.contains("accent: channel == c.id"))
// ⚠️ 必须在 NewTaskSheet 切片**内**取 save()：本文件里有好几个 sheet 都叫 save()，
//    直接在全文件搜会切到隔壁那个（拿到 0 命中还以为自己没写）。
let saveBody = body(sheet, from: "private func save() {")
let chCount = saveBody.components(separatedBy: "\"channel\": channel").count - 1
check("⑤ PATCH + POST 两个请求体都带 channel（当前命中 \(chCount)/2）", chCount == 2)

// ── ⑥ 反例：App 不许自己拼 Hermes 的 deliver ──────────────────
check("🚫 App 代码里不出现 deliver 字面量（通道只传 channel，deliver 由后端落成 weixin/local）",
      !setting.contains("\"deliver\""))
check("🚫 App 不把通道值塞进 deliver（自造 token 会让 Hermes 判 delivery_failed）",
      !setting.contains("deliver_for") && !setting.contains("deliver: channel"))
check("🚫 四档里不许混入后端老口径值 all/origin（两套命名混用 = 选「全部渠道」会静默失效）",
      !setting.contains("CronChannel(id: \"all\"") && !setting.contains("CronChannel(id: \"origin\""))
check("🚫 通道选择器不许写成 @AppStorage（通道是**每条任务**的属性，全局键会串任务）",
      !sheet.contains("@AppStorage"))

print("—— 定时任务推送通道真值表：\(passCount) 通过 / \(failCount) 失败 ——")
if failCount > 0 { exit(1) }
