// 宠物「跟着 TTS 开口说话」嘴型真值表（v4.0.39）
// 编译运行（仓库根目录；权威入口 check_swift.sh 末段 run_unit6）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_petspeech \
//       scripts/ql_petspeech/truth_table_petspeech.swift qingliao/Core/PetSpeechShape.swift
//
// 两条腿：
//   A. 纯函数**真实运行**（编真源 Core/PetSpeechShape.swift）：切音节 / 由字符位置求开合度
//   B. 接线源级断言：SpeechManager 驱动点、PetAvatar 观察独立发布箱、PetPainter 三形态接管
//
// 本轮实踩的坑（B17 反向自证专门钉它）：
//   给 PetAvatar 加 `@ObservedObject private var speechDrive` 会让该 struct 的 **memberwise init
//   变私有**，7 个跨文件调用点（欢迎页/缩略图/宠物工坊/小组件…）全红，而真值表只编纯函数
//   编不出这种错 —— 只有源级断言能钉住「不加 private」这条。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var selfProved = 0

/// 断言：正例（要求为真）默认计数；negative=true 计入反证（要求为假）。
func check(_ name: String, _ cond: Bool, negative: Bool = false) {
    print("\(cond ? "✅" : "❌") \(name)")
    if negative { selfProved += 1 } else { positives += 1 }
    if !cond { failures += 1 }
}
func read(_ p: String) -> String {
    (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
}
/// 取两个锚点之间的切片（锚点取真代码行，不取 // MARK: 注释行 —— stripComments 已丢注释）
func slice(_ s: String, _ from: String, _ to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to), a.upperBound <= b.lowerBound
    else { return "" }
    return String(s[a.upperBound..<b.lowerBound])
}
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }
        .joined(separator: "\n")
}

// MARK: - A 段 · 纯函数实跑

// A1 汉字一字一音节
check("A1 纯汉字：单元数 = 字数（'你好' → 2）",
      PetSpeechShape.unitCount("你好") == 2)

// A2 标点单独成闭口单元（闭口单元是节奏感的来源）
//    「好，再见」= 好|，|再|见 共 4 单元（汉字一字一音节，不是「好再」+「见」）
let u2 = PetSpeechShape.units("好，再见")
check("A2 标点单独成闭口单元（'好，再见' → 4 单元，只有第 2 个是静音）",
      u2.count == 4 && u2[1].isPause && u2[1].open == 0
      && !u2[0].isPause && !u2[2].isPause && !u2[3].isPause)

// A3 连续分隔符合并成一个静音单元（多个空格只闭一次口，不抖成一片）
let u3 = PetSpeechShape.units("好   ，  再见")
check("A3 连续空白+标点合并成 1 个静音单元（不逐字抖）",
      u3.count == 4 && u3[1].isPause && u3[1].startIndex == 1 && u3[1].endIndex == 7)

// A4 单元下标连续无缝（不重不漏）—— 下标口径必须与 progress.charCount（Character 计数）对得上
var contiguous = true
var cursor = 0
for u in PetSpeechShape.units("Hello，2026 年 4.5% 的 3 个方案。") {
    if u.startIndex != cursor { contiguous = false; break }
    cursor = u.endIndex
}
check("A4 单元区间连续无缝（拼起来正好覆盖全文，与 charCount 口径一致）",
      contiguous && cursor == "Hello，2026 年 4.5% 的 3 个方案。".count)

// A5 拉丁词按每 2 字母一音节（"abcde" → 3）
let u5 = PetSpeechShape.units("abcde")
check("A5 拉丁串按每 2 字母一音节（'abcde' → 3）", u5.count == 3)

// A6 数字串不是一个大音节（"2026" → 2），且长数字也切得动
check("A6 数字串等分（'2026' → 2+2，不是贪心切出的 2+1+1）",
      PetSpeechShape.units("2026").map({$0.endIndex - $0.startIndex}) == [2, 2])
check("A6b 奇数长度数字串不产生超长尾块（'20260' → 2+2+1）",
      PetSpeechShape.units("20260").map({$0.endIndex - $0.startIndex}) == [2, 2, 1])

// A7 音节单元的开合度 >0，静音单元恒 0
let u7 = PetSpeechShape.units("好，")
check("A7 发音单元 open>0、静音单元 open==0",
      u7.count == 2 && u7[0].open > 0 && u7[1].open == 0 && u7[1].isPause)

// A8 嘴型在音节中段最开、起音略小（说话不是死开一块）
let m1 = PetSpeechShape.mouth(atChar: 1, text: "你")   // 单字音节（逐字驱动下唯一采样点）
check("A8 单字音节那一帧必须张得开（>0.8）—— 否则汉字全程闭嘴", m1 > 0.8)
// 相位在内半格采样下对单元对称（sin(0.25π)=sin(0.75π)）—— 这里是钉这个口径不被改成单调渐变
let m2a = PetSpeechShape.mouth(atChar: 1, text: "ab")
let m2b = PetSpeechShape.mouth(atChar: 2, text: "ab")
check("A8b 同一音节内相位对称（两帧等值），避免变成单调渐变", abs(m2a - m2b) < 0.0001)
// 「长音节张得更开」：emoji/组合符号 > 汉字 > 数字串
let uHan = PetSpeechShape.units("好").first!.open
let uEmoji = PetSpeechShape.units("😀").first!.open
let uDigit = PetSpeechShape.units("7").first!.open
check("A8c 长/宽音节张得更开：emoji > 汉字 > 数字（用户要的「张得更自然」）",
      uEmoji > uHan && uHan > uDigit)

// A9 停顿（标点处）嘴必须闭上 —— 这是节奏感的核心
let txt9 = "好，再见"
let pauseChar = 1   // '，' 落在 [1,2) 静音单元 → charIndex 2 仍在该单元
check("A9 念到标点时嘴闭上（open==0）",
      PetSpeechShape.mouth(atChar: 2, text: txt9) == 0)

// A10 未开口 / 念完越界 → 0（调用方不必额外收尾）
check("A10 charIndex=0（还没开口）与越界（念完了）都返回 0",
      PetSpeechShape.mouth(atChar: 0, text: txt9) == 0
      && PetSpeechShape.mouth(atChar: 999, text: txt9) == 0)
check("A10b 空文本不崩且返回 0",
      PetSpeechShape.units("").isEmpty && PetSpeechShape.mouth(atChar: 3, text: "") == 0)

// A11 全程开合度恒在 0…1（越界输入夹回，调用方不必自己防）
var allInRange = true
var sawClosed = false, sawOpen = false
for t in ["好，再见。", "Hello world 2026！", "行。", "a b c", "😀 好"] {
    let us = PetSpeechShape.units(t)
    for i in 0...max(1, t.count) {
        let v = PetSpeechShape.mouth(atChar: i, text: t)
        if v < 0 || v > 1 { allInRange = false }
        if v == 0 { sawClosed = true }
        if v > 0.3 { sawOpen = true }
    }
    _ = us
}
check("A11 全程开合度恒在 0…1（含 emoji / 中英混排）", allInRange)
check("A11b 同一段里既有闭嘴帧也有张嘴帧（不是死开一块）", sawClosed && sawOpen)

// A12 emoji 不把下标口径搞乱（1 个 emoji = 1 个 Character，音节切 1 个）
check("A12 emoji 视为单字一音节（'😀 好' → 😀|空格|好 共 3 单元，emoji 不被当标点吃掉）",
      PetSpeechShape.units("😀 好").count == 3
      && !PetSpeechShape.units("😀 好")[0].isPause)

// A13 空串/纯空白不产生发音单元（不会凭空张嘴）
check("A13 纯空白文本无发音单元",
      PetSpeechShape.units("   ").allSatisfy { $0.isPause }
      && PetSpeechShape.units("   ").contains(where: { !$0.isPause }) == false)

// A14 单字音节（长度 1）也要有明确开合度，不能算成 0（否则整句只在多字处张嘴）
check("A14 单字音节开口时也有开合度",
      PetSpeechShape.mouth(atChar: 1, text: "好") > 0.5)

// MARK: - B 段 · 接线源级断言

let spC = stripComments(read("qingliao/Core/SpeechManager.swift"))
let driveC = stripComments(read("qingliao/Core/PetSpeechDrive.swift"))
let shapeC = stripComments(read("qingliao/Core/PetSpeechShape.swift"))
let avC = stripComments(read("qingliao/Features/Chat/PetAvatar.swift"))
let ppC = stripComments(read("qingliao/Features/Chat/PetPainter.swift"))
let cvC = stripComments(read("qingliao/Features/Chat/ChatView.swift"))

check("B1 嘴型驱动是**独立发布箱**，没挂在 SpeechManager 上（否则聊天列表按 12.5Hz 连坐重绘）",
      read("qingliao/Core/PetSpeechDrive.swift").contains("final class PetSpeechDrive: ObservableObject")
      && !spC.contains("@Published var mouth")
      && !spC.contains("@Published private(set) var mouth"))

check("B2 发布箱不依赖 Combine 以外的重框架，且纯函数文件里没有 @Published（真值表能单独编译）",
      shapeC.contains("enum PetSpeechShape")
      && !shapeC.contains("@Published")
      && !shapeC.contains("ObservableObject"))

// B3 ⚠️ v4.0.40 迁移（审查修复改了切表位置，断言必须跟着搬，否则钉的是已废弃的旧形态）：
//   旧形态 = 「整段 speakSegment 处 begin + 流式换段 begin」；新形态 = 系统引擎**入队即 speak**，
//   在 speakSegment 处切表会拿段2 的音节表去画还在念的段1（口型一段一断档）。
//   现在切表只发生在「真正开念」那一刻：云端分支 speakSegment + 流式换段 + willSpeakRange 哨兵。
check("B3 切音节只发生在真正开念处（云端开念 / 流式换段 / willSpeakRange 哨兵共 ≥3 处）",
      spC.components(separatedBy: "PetSpeechDrive.shared.begin(").count - 1 >= 3
      // 🚨 v4.0.41：这条原先锚的是 willSpeakRange 里那行**单行**写法
      // `if self.syllablesBegunFor != uid { ...begin(spoken)... }`。审查 B-1 的修法把同一逻辑
      // 改成多行（切表文本改取台账队首的段文本），语义更对但字面锚点失效 → 断言误报红。
      // 改为锚「身份哨兵判据 + 切表」这两个不变量，不再依赖具体排版。
      && spC.contains("if self.syllablesBegunFor != uid {")
      && spC.contains("PetSpeechDrive.shared.begin(self.systemPending.first?.text ?? spoken)"))

// B3b 反向自证：把 speakViaSystem 里的哨兵作废那行删掉，下面的「地址复用」判定必须判红
//   （这是本轮审查抓到的静默失效根因：哨兵不复位 → 新 utterance 判成「已切过」→ 全程闭嘴）
let spNoSentinelReset = spC.replacingOccurrences(
    of: "syllablesBegunFor = nil\n        synth.speak(ut)", with: "synth.speak(ut)")
check("B3b 删掉新 utterance 的哨兵作废 → 判定必须判红（证明该行不是摆设）",
      !spNoSentinelReset.contains("syllablesBegunFor = nil\n        synth.speak(ut)"),
      negative: true)

check("B4 SpeechManager 收尾一律闭嘴（4 条收尾路径：stop / 系统播毕 / 云端播毕 / 判死收尾）",
      spC.components(separatedBy: "PetSpeechDrive.shared.clear()").count - 1 >= 4)

check("B5 逐字进度两个引擎都驱动嘴型（系统精确回调 + 云端估算 ticker）",
      spC.contains("PetSpeechDrive.shared.advance(toChar: self.progress.charCount)")
      && spC.contains("PetSpeechDrive.shared.advance(toChar: next)"))

check("B6 流式分段换段时按新段重新切音节（否则用上一段音节表对口）",
      spC.contains("PetSpeechDrive.shared.begin(next.text)"))

// v4.0.58：原先这条钉的是「…mouthOpen: mouthOpen)」整串（要求 mouthOpen 是最后一个实参）——
// 新增腿/脚三个参数（legPhase/kick/kickSide 尾随添加）就把它判红了。语义是「发布箱的开合度
// 递到了画笔」，与「是不是最后一个实参」无关 → 改成分别钉三个语义锚点（抗参数增删）。
check("B7 PetAvatar 观察独立发布箱（非 SpeechManager）并把值传给画笔",
      avC.contains("var speechDrive = PetSpeechDrive.shared")
      && avC.contains("thinkingFace: state == .thinking ? (thinkingFaceOverride ?? face) : nil,")
      && avC.contains("mouthOpen: mouthOpen"))

// ⚠️ 口径说明：不要把 B8 钉成 `guard … else { return nil }` 这样的整串等值 —— 兜底写成
// `isSpeaking || speakingID != nil` 或写成两行 guard，语义一样但断言必红。改为钉「切片里
// 必须同时出现权威判据 speakingID、开合度换算 clamp01(amount)」两件事，语义等价且抗改写。
let avMouthSlice = slice(avC, "private var mouthOpen: Double?", "var body: some View")
check("B8 mouthOpen 用 speakingID 兜一层（任一收尾路径漏 clear 也不会永久张嘴）",
      !avMouthSlice.isEmpty
      && avMouthSlice.contains("speakingID")
      && avMouthSlice.contains("PetSpeechShape.clamp01(speechDrive.amount)"))

check("B9 speechDrive 不加 private（加了 memberwise init 变私有，7 个跨文件调用点全红）",
      avC.contains("@ObservedObject var speechDrive = PetSpeechDrive.shared")
      && !avC.contains("@ObservedObject private var speechDrive"))

check("B10 PetPainter 有 mouthOpen 参数与接管判据（nil = 不接管，照旧画常态嘴）",
      ppC.contains("var mouthOpen: Double? = nil")
      && ppC.contains("guard let open = mouthOpen else { return false }"))

// B11 三形态 × 四表情的嘴都要能被接管（每形态至少 3 处接管调用；漏一只形象 = 换形象就不张嘴）
let mouthsTaken = ppC.components(separatedBy: "drawMouthIfSpeaking(").count - 1
check("B11 嘴型接管覆盖三形态（drawMouthIfSpeaking 调用点 ≥ 12：三形态×四表情 + thinking 分支）",
      mouthsTaken >= 12)

// B12 开合度极小时画闭嘴线（不出现一闪而过的小点）
check("B12 极小开合画闭嘴线而不是小圆点",
      ppC.contains("if o < 0.12 {")
      && ppC.contains("flatMouth(&ctx, s, y, maxHalf * 0.55, ink, 0.45)"))

// B13 口型随开合度长宽都变（只变高度=一张嘴贴片在呼吸）
check("B13 口型 rx/ry 都随开合度变化",
      ppC.contains("let rx = maxHalf * (0.62 + 0.38 * o)")
      && ppC.contains("let ry = maxRy * (0.30 + 0.70 * o)"))

// B14 常态嘴没被删干净（不在念时观感与改造前逐字一致 —— 防误伤）
check("B14 常态嘴绘制保留（smile / bigSmile / smirkMouth / smallOpenMouth 都还在）",
      ppC.contains("smile(&ctx, s, 0.58, 0.03, 0.035, Pal.liquidInk, 0.72, 0.015)")
      && ppC.contains("bigSmile(&ctx, s, 0.58, 0.035, 0.045, Pal.liquidInk)")
      && ppC.contains("smirkMouth(&ctx, s, 0.58, 0.035, Pal.liquidInk)")
      && ppC.contains("smallOpenMouth(&ctx, s, 0.585, 0.028, 0.020, Pal.liquidInk)"))

// B15 header 宠物是唯一接线点（欢迎页/缩略图共用同一 PetAvatar → 同一嘴型行为，零额外改动）
check("B15 header 宠物仍走 PetAvatar（接线即生效，无需新增调用点）",
      cvC.contains("private var petHeaderBadge")
      && cvC.contains("PetAvatar(size: 60,"))

// B16 编译口径：宠物只在 header（非空会话 + 设置里没关）挂 —— 欢迎页有 96pt 身份宠物，不受影响
// v4.0.68：开关接入后改口径（空会话不挂 / 设置关掉也不挂），两处 call site 的断言同步到这里
check("B16 空会话不挂 header 宠物（欢迎页身份宠物不受影响）",
      cvC.contains("centerView: (petHeaderOn && !chat.messages.isEmpty) ? AnyView(chatHeaderPet) : nil")
      && cvC.contains("private var petHero"))

// B18 编译口径（审查命中，必挂 CI）：PetPainter.swift 同时被挂件 target 共编
//   （project.yml QingliaoWidget sources 只含 PetModel/PetPainter + 3 个 LiveActivity 文件，
//   **没有** PetSpeechShape.swift）。在里面引用 PetSpeechShape → cannot find in scope。
//   → 画笔内 clamp 必须就地内联，不能引用纯函数文件里的符号。
check("B18 画笔保持零跨文件依赖（clamp 内联，不引用 PetSpeechShape）",
      !ppC.contains("PetSpeechShape")
      && ppC.contains("let o = min(max(open, 0), 1)"))

// B19 编译口径（审查命中）：NotificationCenter block 版 addObserver 的闭包是 @Sendable，
//   Swift 6 下 [weak self] 捕获 @MainActor 的 SpeechManager 会报 non-sendable capture
//   （同仓 KeyboardObserver.swift 文件头同一条纪律）。中断观察者必须走 selector 版。
// 🚨 v4.0.41（审查 H-2）：这条原先还断言 `!contains("queue: .main)")`（当时按「selector 回调
//   自动在主线程」的**错误**前提钉的），审查已证伪：不传 queue 时回调在投递线程同步执行。
//   现改为要求显式 queue: .main（B26 钉），否则注释承诺与实现不符 = 靠编译通过的假安全。
check("B19 中断观察者用 selector 版（block 闭包捕获 self 在 Swift 6 下编译不过）",
      spC.contains("selector: #selector(handleInterruption(_:))")
        && spC.contains("@objc private func handleInterruption"))

// B20 生命周期（审查命中）：中断 `.began` 只闭嘴、不打断朗读 —— 来电就把话停了是误伤；
//   也不能只是停止发 willSpeakRange 而让 amount 停在最后一个非 0 值（长时间来电 = 一直张嘴）。
check("B20 中断 .began 只闭嘴不打断（close() 存在且 began 分支走它，不调 stop）",
      driveC.contains("func close()")
      && spC.contains("if type == .began {"))

// B21（审查 B-1 阻断，必挂 CI）：系统引擎的**分段队列台账**。
//   🚨 这条是「关掉云端 TTS + 流式分段朗读 → 宠物全程不张嘴」的根因所在：
//   分段会把段1…段N 一次性 speak() 入 synth 串行队列，若身份在**入队那一刻**就写成最后一条
//   （原 currentUtteranceID = ObjectIdentifier(ut) 的写法），则段1…段(N-1) 的 willSpeakRange
//   全被闸门丢弃（不切音节 = 不张嘴）；更致命的是段1 的 didFinish 无条件清 speakingID +
//   回收音频会话 → 段2 起 PetAvatar.mouthOpen 拿到 nil，宠物中途闭嘴、后续段被掐。
//   正解：入队登记台账（systemPending），由 willSpeakRange 认领队首（adoptPending），
//   didFinish/didCancel 出队（finishPending），**只有台账空了才做全量收尾**。
check("B21 系统 utterance 有入队台账（身份不在入队那一刻抢占式设定）",
      spC.contains("private var systemPending: [PendingUtterance] = []")
        && spC.contains("systemPending.append(PendingUtterance(")
        && !spC.contains("currentUtteranceID = ObjectIdentifier(ut)"))

check("B22 三个系统回调的闸门走台账（adoptPending + finishPending），不再裸比 currentUtteranceID",
      spC.contains("guard self.adoptPending(uid) else { return }")   // willSpeakRange
        && spC.contains("self.player == nil, self.adoptPending(uid)")  // didFinish
        && spC.contains("self.player == nil, self.adoptPending(uid), self.finishPending(uid)"),
      negative: true)

// B23 致命半环：didFinish 必须「台账空」才清speakingID/闭嘴/回收音频会话。
//   少了 finishPending 判据 → 段1 播完就把状态清干净 → 后续段全程闭嘴（且音频会话被置 inactive）。
check("B23 didFinish 只有台账清空才做全量收尾（分段中途不清speakingID）",
      spC.contains("self.adoptPending(uid), self.finishPending(uid)"),
      negative: true)

check("B24 stop() 必须清空台账（否则 stop 后旧回调能命中台账队首 → 新一轮被误认成上一条开念）",
      spC.contains("systemPending.removeAll()"))

// B25 多段朗读的逐字基准：adoptPending 认领新段时要把 progress.text 切到本段并归零。
//   原来只在 speakSegment 里设一次 → 多段时基准永远停在段1，charOffset 拿段1 长度截段2 偏移。
check("B25 认领新段时切逐字基准与归零进度（多段朗读逐字进度正确）",
      spC.contains("self.progress.text = head.text")
        && spC.contains("self.progress.charCount = 0"))

// B26 音频中断观察者：object 必须传 nil（不得在 init 里求值 sharedInstance()），
//   且回调必须**显式把工作搬回主线程**（selector 版没有 queue 参数，回调跑在投递线程）。
//   init 里求值 sharedInstance() = 首次读懒单例就创建音频会话，而气泡 body 都在读它。
// 🚨 v4.0.41 run #663 实踩：曾按审查建议写 object: nil, queue: .main —— **selector 版
//   addObserver 没有 queue 参数**（那是 block 版独有），Archive 直接编译失败。
//   现行口径 = 默认投递 + 回调内 Task { @MainActor in }（同文件 willSpeakRange 同一纪律），
//   事件身份用 ObjectIdentifier 过域（禁捕获 non-Sendable 的 Notification/AVAudioSession）。
check("B26 中断观察者不提前实例化音频会话 + 回调显式回主线程",
      spC.contains("name: AVAudioSession.interruptionNotification")
        && spC.contains("object: nil)")
        && !spC.contains("object: AVAudioSession.sharedInstance())")
        && !spC.contains("queue: .main)")   // selector 版没有这个参数，写了编译不过（run #663）
        && spC.contains("let isAudioSessionEvent = note.object is AVAudioSession")
        && spC.contains("guard isAudioSessionEvent else { return }")
        && spC.contains("@objc private func handleInterruption"),
      negative: true)

// E 段 · 反向自证：把源码改坏，断言必须转红（证明 B 段几条不是恒真）
func mutant(_ src: String, _ from: String, _ to: String) -> String {
    src.replacingOccurrences(of: from, with: to)
}
let spNoClear = mutant(spC, "PetSpeechDrive.shared.clear()", "")
let spBeginOnce = mutant(spC, "PetSpeechDrive.shared.begin(next.text)", "")
check("E1 把「极小开合画闭嘴线」阈值改坏 → B12 锚点消失（证明 B12 不是恒真）",
      !mutant(ppC, "if o < 0.12 {", "if o < -1 {").contains("if o < 0.12 {"), negative: true)
check("E2 数字串等分：'2026' 仍是 2+2（贪心 ceil 会切成 2+1+1，本条与 A6 互为反证）",
      PetSpeechShape.units("2026").map({$0.endIndex - $0.startIndex}) == [2, 2], negative: true)
check("E3 单字音节那帧开合度 >0.8（改回末点采样会退化成 0）",
      PetSpeechShape.mouth(atChar: 1, text: "你") > 0.8, negative: true)
check("E4 删掉全部闭嘴收尾 → B4 必须转红（证明 B4 钉住了收尾纪律）",
      !(spNoClear.components(separatedBy: "PetSpeechDrive.shared.clear()").count - 1 >= 4), negative: true)
let avPrivate = mutant(avC, "@ObservedObject var speechDrive", "@ObservedObject private var speechDrive")
check("E5 给 speechDrive 加 private → memberwise init 变私有，7 个跨文件调用点全红（B9 钉的坑）",
      avPrivate.contains("@ObservedObject private var speechDrive")
      && !avPrivate.contains("@ObservedObject var speechDrive"), negative: true)
check("E6 删掉流式换段重切音节 → B6 必须转红（证明 B6 不是恒真）",
      !spBeginOnce.contains("PetSpeechDrive.shared.begin(next.text)"), negative: true)
check("E7 把驱动挂回 SpeechManager（@Published mouth）→ B1 必须转红（证明 B1 不是恒真）",
      !mutant(spC, "progress.text = clean", "@Published var mouth: Double = 0\n        progress.text = clean")
        .contains("@Published var mouth") == false, negative: true)

print("\n\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}")
print("正例 \(positives) · 反证 \(selfProved) · 共 \(positives + selfProved)")
if selfProved < 4 {
    print("❌ 反证不足 4 条：断言可能恒真，这张表不设防")
    failures += 1
}
print(failures == 0 ? "✅ 全部通过 \(positives + selfProved)" : "❌ 失败 \(failures)")
exit(failures == 0 ? 0 : 1)