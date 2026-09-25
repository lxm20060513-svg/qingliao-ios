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

// ── v3.9.72：旧门（比"上次处理过的那一版"）已**下线** ──────────────────────
// v3.8.1 的 `isHandled` + `handledClipChange` / `handledClipUptime` 两个 @AppStorage 在 v3.9.72
// 换门后只写不读（真值表曾有 6 条断言在替它背书 = 假信心），已随生产代码一并删除。
// 这里改成**反向断言**：旧门不得复活（去注释后判，注释里提到历史符号名不算违规）。
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
let chatCode = stripCommentLines((try? String(contentsOfFile: "qingliao/Features/Chat/ChatView.swift", encoding: .utf8)) ?? "")
check("能读到 ChatView 源码（路径别改）", true, !chatCode.isEmpty)
check("v3.9.72·旧门 isHandled 不得复活", true, !chatCode.contains("ClipboardPromptGate.isHandled"))
check("v3.9.72·旧记账 markClipboardHandled 不得复活（单一真值源）", true, !chatCode.contains("markClipboardHandled"))
check("v3.9.72·旧 @AppStorage 键不得复活", true,
      !chatCode.contains("qingliao_clip_handled_change") && !chatCode.contains("qingliao_clip_handled_uptime"))

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

check("v3.9.72·ChatView 用 decide 门", true, chatCode.contains("ClipboardPromptGate.decide("))
// 计数式：定义 1 处 + 两个弹条分支各 1 处 = 3；只拆掉其中一处也必须报红
// （首版只写 contains → 实测「拆掉定位分支那次调用」仍绿，等于半个护栏）
func occurrences(_ needle: String, in hay: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}
check("v3.9.72·自动收起接线完整（定义+两个弹条分支 = 3）",
      true, occurrences("scheduleClipboardAutoHide()", in: chatCode) >= 3)
check("v3.9.72·交互取销接线完整（定义 + 四处按钮 = 5）",
      true, occurrences("cancelClipboardAutoHide()", in: chatCode) >= 5)

// ── v3.9.76：用户报「剪贴板内容识别现在连第一次都不弹窗了」→ 挖出两条真缺陷 ──────────
// ① 位置探测失败会**把整条链一起吞掉**：旧写法是「guard let isLocation = ... else { return }」，
//    位置那一层在真机抛错（nil）时，连后面「普通链接」的提示也一起消失，用户看到的就是"永远不弹"。
// 现在必须解耦：位置探测失败只当"不是位置链接"，继续往下走链接探测。
check("v3.9.76·位置探测失败不再阻断链接探测（旧 guard let 形态不得复活）",
      true,
      !chatCode.contains("guard let isLocation")
      && chatCode.contains("let isLocation = await MapClipboardDetector.hasLocationLink()")
      && chatCode.contains("if isLocation == true"))
// ② 点了「识别」却读不到剪贴板 / 抽取失败时静默 return = 像按钮坏了 → 统一走「失败必出声」出口
// ⚠️ 这是**计数代理**断言：出口删一处就红、别处多写一处就绿，只能当"至少这么多"的下限。
//   v3.9.76 从 5 降到 4：`extract(text:auth:)` 返回**非可选**（那个 `guard let result` 是死分支），
//   删掉它是对的行为 —— 这类断言的价值仅限于"别把出口删光"。
check("v3.9.76·识别失败出声出口存在且接线完整（定义 + 3 处调用 ≥ 4）",
      true,
      occurrences("flashNoContent(", in: chatCode) >= 4)
check("v3.9.76·失败文案走变量（图片/剪贴板共用槽位，不得再写死「图里…」）",
      true,
      chatCode.contains("Text(intentNoContentHintText)"))

// ── v3.9.76：口径放开（用户拍板「1」）——本地能识别的**结构化类型**都提示，不再只认链接 ──
// 判断逻辑（哪几类命中就值得问一句）故意放在不 import UIKit 的 ClipboardPromptGate.swift 里 → 这里可测；
// 取值逻辑（detection API）依赖 UIKit、本机编不了 → 只能用源码级断言钉住"探测范围别被缩回链接一项"。
// 诚实边界：**纯文字仍然不提示**（没有对应 pattern，要判断只能真读内容 = 弹系统「允许粘贴」）。
check("v3.9.76·链接命中 → 值得提示", true, ClipboardIntentHits(link: true).any)
check("v3.9.76·地址命中 → 值得提示", true, ClipboardIntentHits(address: true).any)
check("v3.9.76·联系方式命中 → 值得提示", true, ClipboardIntentHits(contact: true).any)
check("v3.9.76·金额命中 → 值得提示", true, ClipboardIntentHits(amount: true).any)
check("v3.9.76·快递单号命中 → 值得提示", true, ClipboardIntentHits(express: true).any)
check("v3.9.76·时间命中 → 值得提示", true, ClipboardIntentHits(datetime: true).any)
check("v3.9.76·都没命中 → 不打扰", true, !ClipboardIntentHits().any)
check("v3.9.76·类别名可读（提示条文案）", true,
      ClipboardIntentHits(link: true, address: true).label == "链接 / 地址")
check("v3.9.76·空命中 → 文案为空串", true, ClipboardIntentHits().label.isEmpty)

let detectorCode = stripCommentLines((try? String(contentsOfFile: "qingliao/Features/Chat/ClipboardIntentDetector.swift", encoding: .utf8)) ?? "")
check("v3.9.76·能读到探测器源码（路径别改）", true, !detectorCode.isEmpty)
check("v3.9.76·探测链不得退回只认链接（旧 hasWebLink 形态不得复活）",
      true,
      !chatCode.contains("ClipboardIntentDetector.hasWebLink")
      && chatCode.contains("ClipboardIntentDetector.recognizableHits()"))
// ⚠️ 首版断言扫的是**整个探测器文件** → 实测"把 patterns 集合缩回只剩 .probableWebURL"仍绿（假信心）：
//    函数体里对 values.postalAddress 等的访问把断言喂饱了。必须**切片**只看 patterns 集合那一段。
let patternsBlock: String = {
    guard let s = detectorCode.range(of: "static let patterns"),
          let e = detectorCode.range(of: "]", range: s.upperBound..<detectorCode.endIndex) else { return "" }
    return String(detectorCode[s.lowerBound..<e.upperBound])
}()
check("v3.9.76·能切到 patterns 集合（切片失败 = 这条断言白写）", true, !patternsBlock.isEmpty)
// ⚠️ v3.9.76 修正：这条原来是按「类目名」猜的（.postalAddress/.money/.dateTime…），
//   而 `UIPasteboard.DetectionPattern` **只有** .number/.probableWebSearch/.probableWebURL 三个成员
//   （Apple 文档 2026-09 核对），且 `detectedValues(for:)` 收的是 **key-path 集合**、字段是**复数数组**。
//   照旧断言 = 把编不过的写法钉成正确形态，护栏自己成了事故源。现在按真实 API 钉。
// ⚠️ 断言表达式一律**单行赋值**再传参：写成多行「行首 &&」链时 Swift 6.0.3 的解析器
//   会报 "expected ',' separator / extra argument in call"（实测 137 行那三连 && 踩到）。
let keyPathShapeOK = patternsBlock.contains("Set<PartialKeyPath<UIPasteboard.DetectedValues>>") && patternsBlock.contains("\\.probableWebURL")
check("v3.9.76·patterns 是 key-path 形态（Set<PartialKeyPath<DetectedValues>>）", true, keyPathShapeOK)
let sixKindsOK = ["\\.links", "\\.postalAddresses", "\\.phoneNumbers", "\\.emailAddresses", "\\.moneyAmounts", "\\.shipmentTrackingNumbers", "\\.calendarEvents"].allSatisfy { patternsBlock.contains($0) }
check("v3.9.76·探测范围覆盖 链接/地址/联系方式/金额/快递/日程 六类", true, sixKindsOK)
// ⚠️ 必须用正则带**负向前瞻**：直接 contains(".postalAddress") 会被真形态 `\.postalAddresses`
//   喂饱（子串包含），这条断言第一版就是这么假绿的。
let fakeNameRegex = try? NSRegularExpression(pattern: "\\.(postalAddress|phoneNumber|emailAddress|money|shipmentTrackingNumber|dateTime)(?![A-Za-z])")
check("v3.9.76·假名正则编译成功（编译不了 = 下一条是空真）", true, fakeNameRegex != nil)
let noFakeNamesOK = fakeNameRegex?.firstMatch(in: patternsBlock, range: NSRange(patternsBlock.startIndex..., in: patternsBlock)) == nil
check("v3.9.76·不得出现 DetectionPattern 的类目假名（这些成员不存在 → 编译必炸）", true, noFakeNamesOK)
let pluralFieldsOK = detectorCode.contains("!values.postalAddresses.isEmpty") && detectorCode.contains("!values.moneyAmounts.isEmpty") && !detectorCode.contains("values.postalAddress)")
check("v3.9.76·命中判定用复数数组 isEmpty（DetectedValues 没有单数字段）", true, pluralFieldsOK)
check("v3.9.76·数字类 pattern 不得混入（验证码/工号误报率高）",
      true, !patternsBlock.contains(".number"))
check("v3.9.76·三态口径保住（nil = 探测失败 → 调用方不记账）",
      true, detectorCode.contains("return nil"))
check("v3.9.76·提示条文案不得写死「链接」",
      true, !chatCode.contains("检测到剪贴板里的链接"))

print(failures == 0 ? "🎉 剪贴板去重真值表全部通过（\(total) 条）" : "❌ 剪贴板去重真值表失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
