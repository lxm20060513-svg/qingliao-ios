import Foundation

/// v4.0.39：TTS 朗读时 header 宠物的**嘴型节奏**（纯逻辑，可单测）。
///
/// 需求：AI 回复被朗读时，页头那只宠物要「跟着开口说话」，而不是一个静止图标。
///
/// ⚠️ 为什么是独立文件 + 独立发布箱（而不是挂 `SpeechManager.progress`）：
///   `SpeechManager.shared` 被聊天列表里每颗气泡观察，逐字进度全程 ≈12.5Hz 变化；
///   把嘴型再挂到它上面（或直接让 PetAvatar 观察它）会把整片聊天列表按 12.5Hz 重算
///   （与 v3.9.77 `SpokenProgress` 同一条教训）。因此口型有自己的小发布箱
///   （`PetSpeechDrive`），**只在音节/静音边界变化时写**（一帧一次），不是每 0.08s 一次。
///
/// 口径（刻意做「有开有合」，不做逐字抖动）：
///   · 文本按**标点 / 空白 / 换行**切音节：汉字一字一音节；拉丁字母串按每 2 字母一音节；
///     数字串每 2 位一音节（念「2026」不是一个音）。
///   · 标点与空白本身是**闭口单元**（念到逗号要停 → 嘴闭上），这就是节奏感的来源。
///   · 每个音节内按相位让开合度**先小后大再收**（说话时嘴不是死开一块），
///     长音节张得更开（>0 越界一律夹回 0…1，调用方不必自己防）。
enum PetSpeechShape {

    /// 一个发音单元（音节或静音段），区间按 **Character 下标** 半开区间 [startIndex, endIndex)
    struct Unit: Equatable {
        let startIndex: Int
        let endIndex: Int
        /// 该单元的最大开合度 0…1；静音段为 0
        let open: Double
        /// 是否是静音/标点单元（嘴必须闭上）
        let isPause: Bool
    }

    // MARK: - 切分（纯函数）

    /// 把待念文本切成发音单元。空文本 → 空数组。
    /// - 注意：下标口径与 `SpeechManager.progress.charCount` 一致（都按 **Character** 计数，
    ///   不是 UTF-16 码元）—— 混用会让嘴型相对语音整体偏移。
    static func units(_ text: String) -> [Unit] {
        var out: [Unit] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if isSeparator(ch) {
                // 连续分隔符合并成一个静音单元（连续空白只需要一次闭口）
                var j = i
                while j < chars.count && isSeparator(chars[j]) { j += 1 }
                out.append(Unit(startIndex: i, endIndex: j, open: 0, isPause: true))
                i = j
                continue
            }
            let (end, open) = syllableLength(chars, from: i)
            out.append(Unit(startIndex: i, endIndex: end, open: open, isPause: false))
            i = end
        }
        return out
    }

    /// 当前字符所在音节向后吃几个字符，以及该音节的开合度。
    private static func syllableLength(_ chars: [Character], from i: Int) -> (Int, Double) {
        let first = chars[i]
        if isLatinLetter(first) {
            let end = latinRunEnd(chars, from: i)
            let n = chunkSize(end - i)
            return (i + n, 0.82)
        }
        if first.isNumber, let f = first.wholeNumberValue {
            let end = digitRunEnd(chars, from: i)
            let n = chunkSize(end - i)
            // 「0」整串念「零」，口型略收；其余数字串正常。
            // ⚠️ 原来还有 `chars[i..<end].contains(".")` 分支，但「.」是标点、
            //   会被 isSeparator 先吃掉成静音单元，永远进不到这里 —— 恒 false 的死分支，已删。
            //   小数点处闭口这个效果由「标点 = 静音单元」天然保证。
            return (i + n, f == 0 ? 0.7 : 0.78)
        }
        // 其余：汉字/全角符号/emoji 按单字一音节
        return (i + 1, openValue(first))
    }

    /// 拉丁字母串结束下标（不含分隔符/数字）
    private static func latinRunEnd(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count, isLatinLetter(chars[j]) { j += 1 }
        return j
    }

    /// 数字串结束下标
    private static func digitRunEnd(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j].isNumber { j += 1 }
        return j
    }

    /// 单字音节的开合度：emoji 类张得更开，汉字次之。
    ///
    /// ⚠️ 实踩坑：原来用 `unicodeScalars.count > 1` 判「宽字符」想给 emoji 更大的口型，
    ///   但 😀 的 scalars.count **就是 1**（单 scalar 字符）→ 与汉字完全同值，该分支形同虚设
    ///   （真值表 A8c 当场判红才看出来）。改用语义判定：`isSymbol && 非 ASCII` 即 emoji/装饰符。
    private static func openValue(_ c: Character) -> Double {
        isEmojiLike(c) ? 0.95 : 0.88
    }

    /// 一段同质串切成每块多长（**等分**，不能靠 ceil 逐次贪心）。
    ///
    /// ⚠️ 实踩坑：贪心 `n = ceil(len/2)` 逐次切会切出「2+1+1」——
    ///   首块吃 ceil(4/2)=2 之后剩 2 字符，下一轮 ceil(2/2)=1 → 「2026」被念成 3 个音节且
    ///   节奏忽长忽短。正确做法：先算块数 `k = ceil(len/chunk)`，再按 `ceil(len/k)` 定块长，
    ///   4 → k=2 → 块长 2 → 「2+2」；5 → k=3 → 块长 2 → 「2+2+1」（test A5 口径）。
    private static func chunkSize(_ len: Int) -> Int {
        if len <= 2 { return len }          // 1~2 字符整体算一个音节（「ab」「20」各 1 个）
        let k = (len + 1) / 2              // 目标块数
        return max(1, (len + k - 1) / k)   // 块长 = ceil(len/k)
    }

    /// 是否是静音/分隔符单元。
    ///
    /// ⚠️ 实踩坑：Swift 的 `Character.isSymbol` **包含 emoji**（实测 😀.isSymbol == true）。
    ///   判据里直接写 `|| c.isSymbol` → 所有 emoji 被当成标点合并进静音单元，
    ///   念到「好😀」时 emoji 处嘴一直闭着；A8c 真值表当场判红才暴露。
    ///   Character 上**没有** isEmoji 可用（swiftc 6.0.3 实测无该成员），
    ///   所以用 Unicode 码位区间兜：U+1F300–U+1FAFF 是主要 emoji 区（另补 ©®™ 与常见符号）。
    private static func isSeparator(_ c: Character) -> Bool {
        if isEmojiLike(c) { return false }               // emoji 是发音单元，不是分隔符
        return c == " " || c == "\n" || c == "\t" || c == "\r" || c.isPunctuation || c.isSymbol
    }

    /// emoji 判定：非 ASCII 的符号，且落在 emoji 码位区（Character 无 isEmoji，只能自己判）
    private static func isEmojiLike(_ c: Character) -> Bool {
        guard c.isSymbol, !c.isASCII, let v = c.unicodeScalars.first?.value else { return false }
        return (0x1F300...0x1FAFF).contains(v) || (0x2600...0x27BF).contains(v) || (0x2190...0x21FF).contains(v)
    }

    private static func isLatinLetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    // MARK: - 由字符位置求嘴型（纯函数）

    /// 念到第 `charIndex` 个字符时的开合度（0 = 闭嘴，1 = 全开）。
    /// - 越界（念完了 / 还没开始）一律返回 0 → 嘴自动闭上，不需要调用方额外收尾。
    /// - `charIndex` 落在两个单元之间（理论上不会发生）按「后面那个还没开始」处理 → 0。
    static func mouth(atChar charIndex: Int, units: [Unit]) -> Double {
        guard charIndex > 0, !units.isEmpty else { return 0 }
        guard let u = units.first(where: { charIndex > $0.startIndex && charIndex <= $0.endIndex })
        else { return 0 }
        if u.isPause { return 0 }
        let len = max(1, u.endIndex - u.startIndex)
        // 单元内相位 0…1（正弦形：起音小 → 中段全开 → 收音略收）
        //
        // ⚠️ 实踩坑：相位**不能**直接用 (charIndex - start) / len。
        //   逐字进度下，单字音节（汉字，占正文绝大多数）只会命中 t == 1 这一个采样点；
        //   若 sin(π·1) = 0 → 每个汉字那帧嘴都是闭的 → 整句只有多字音节才张嘴，
        //   看起来就是「大部分时候嘴不动」。
        //   正解：采样点落在单元**内半格**（(i - start - 0.5) / len），于是
        //   单字音节 → t=0.5（正中峰值，全开），双字音节 → t=0.25/0.75（一开一合）。
        let t = (Double(charIndex - u.startIndex) - 0.5) / Double(len)
        let phase = sin(.pi * min(max(t, 0), 1))
        return clamp01(u.open * (0.68 + 0.32 * phase))
    }

    /// 便捷入口：直接给文本求嘴型（单测与预览用；App 侧走 units 缓存版）
    static func mouth(atChar charIndex: Int, text: String) -> Double {
        mouth(atChar: charIndex, units: units(text))
    }

    /// 整段文本的单元数（单测/诊断用）
    static func unitCount(_ text: String) -> Int { units(text).count }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }
}
