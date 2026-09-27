import Foundation

// MARK: - v3.9.81 聊天页工具卡下面那行进度小字（与任务中心「进行中」卡片同一口径）
//
// 用户 2026-09-27 真机要求：「在聊天页的工具调用下面同步显示这段小字，也是用小字」——
// 任务中心「进行中」卡片能看到 `第 55 步 运行代码 · 837 字 · 静默 26 秒 · 最近：…`（后端
// `stream_api.py::_stream_progress_detail`），而聊天页工具卡只有「N 步工具调用」摘要 + 每步名/耗时，
// 长任务里在聊天页看不出「跑到哪了」，得专门开任务中心。
//
// **口径**（用户 2026-09-27 从编号选项拍板：1a 位置 / **2b 文案** / 3a 时机）：
//   content 为空 → 有工具：「工具：{工具名}」；无工具：「思考中」
//   有工具       → "{工具名} · {N} 字 · 静默 {秒|分} · 最近：{尾部 40 字}"
//   无工具       → "已生成 {N} 字 · 静默 {秒|分} · 最近：{尾部 40 字}"
//
// 🚨 2b = 聊天页这行**不带「第 N 步」前缀**，这是与后端 `_tool_brief` **唯一一处有意不去对齐**的差异
//    （不是漏改）：摘要行就写着「N 步工具调用」，小字再报一次步数是重复；任务中心那张卡没有摘要行，
//    所以那边保留「第 N 步」。真值表 ql_progressnote 把这条差异**显式钉住**——App 侧冒出「第 N 步」要红、
//    后端侧必须还在（谁改动谁红），其余（字数按码点 / 静默分档 / 尾部 40 字折叠空白）仍逐字对齐后端。
// 三处细节按后端来，别"顺手优化"：
//   ① 字数按**码点**计（后端 `len()` 的语义，见 StreamClient.codePointCount：`👨‍👩‍👧` 算 5 不算 1）；
//   ② 静默 <60 秒显示秒、否则显示**整分**（`%d 分`，不是「1 分 30 秒」）；
//   ③ 尾部先取**码点**后 40 位、再折叠空白（不是字素簇——否则 emoji 家族会被切半）。
enum StreamProgressText {
    /// 与后端 `PROGRESS_DETAIL_TAIL` 同值（卡片窄，尾部太长撑坏布局）
    static let detailTail = 40

    /// 工具名（后端已翻好中文，App 不维护第二份映射表，与 ToolStepRow 的既定口径一致）。
    /// **刻意不拼「第 N 步」**（口径 2b，用户 2026-09-27）：摘要行已写步数，这里只报「在干什么」。
    /// 故意写成单行恒等实现——真值表按字面钉住它，谁再加回前缀就红。
    static func toolBrief(name: String) -> String { name }

    /// 一行进度文案。纯函数（`now` 由调用方传入，不在这里读时钟）→ 真值表可逐条镜像。
    /// - Parameters:
    ///   - content: 本轮**真实**累计全文（用 `stream.content`，不用打字机平滑层的 displayContent：
    ///              后端 `st["content"]` 就是真实全文，平滑层只在展示端，拿它算字数会少那么几十个字）
    ///   - growAt: 内容最后一次增长的时刻（0 = 本流还没吐过内容）
    static func line(content: String, toolName: String,
                     growAt: TimeInterval, now: TimeInterval) -> String {
        let tool = toolBrief(name: toolName)
        if content.isEmpty {
            return tool.isEmpty ? "思考中" : "工具：\(tool)"
        }
        let chars = StreamClient.codePointCount(content)
        let silent = growAt > 0 ? max(0, Int(now - growAt)) : 0
        let silentTxt = silent < 60 ? "\(silent) 秒" : "\(silent / 60) 分"
        let tail = tailText(content, detailTail)
        if !tool.isEmpty {
            return "\(tool) · \(chars) 字 · 静默 \(silentTxt) · 最近：\(tail)"
        }
        return "已生成 \(chars) 字 · 静默 \(silentTxt) · 最近：\(tail)"
    }

    /// 尾部 n 个**码点** + 折叠空白（= 后端 `re.sub(r"\s+", " ", content[-40:]).strip()`）
    static func tailText(_ s: String, _ n: Int) -> String {
        collapseWhitespace(codePointTail(s, n))
    }

    /// 取尾部 n 个码点。按 UTF-16 逐位回退并自行合并代理对，绝不切开代理对
    /// （`String.suffix(n)` 按字素簇切——`👨‍👩‍👧` 是 1 个字素 5 个码点，两端字数就对不上了）。
    static func codePointTail(_ s: String, _ n: Int) -> String {
        guard n > 0 else { return "" }
        // v3.9.100：只切尾部 2n+1 个 UTF-16 单元（1 个码点最多占 2 个单元，多留 1 个防止
        // 高代理被切半）。原来 `Array(s.utf16)` 是全量拷贝——20 万码点回复 ≈ 400KB/次，
        // 而这行是**每秒**都要算的（审查实测单次 0.84ms → 0.007ms）。语义与旧实现逐条对拍过。
        let units = Array(s.utf16.suffix(2 * n + 1));
        var i = units.count
        var taken = 0
        while i > 0, taken < n {
            let u = units[i - 1]
            if u >= 0xDC00, u <= 0xDFFF, i >= 2,
               units[i - 2] >= 0xD800, units[i - 2] <= 0xDBFF {
                i -= 2   // 合法代理对 = 1 个码点
            } else {
                i -= 1
            }
            taken += 1
        }
        return String(decoding: units[i...], as: UTF16.self)
    }

    /// 连续空白折叠成单个空格，再去首尾空白
    /// （后端是 `\s+`→空格 再 `strip()`；实现按 Character 走，与 Python 的字符语义一致）
    static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(ch)
                inSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
