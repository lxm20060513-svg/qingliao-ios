// MARK: - #3 轻聊斜杠命令层（v1 最小集 · 单一真源）
//
// 口径（方案 .hermes/plans/2026-10-05_235848-qingliao-slash-commands.md §二/§三）：
//   v1 只有 6 条命令：/new /model /stop /usage /记一笔 /help。全部复用 App 已有能力，
//   **零新依赖、零后端改动**。命令层建在 App 侧的唯一原因：后端 api_server 端点**没有**命令分发，
//   命令文本一旦放进发送链路就会被当普通消息发给模型（污染上下文 / 复读源）。
//
// 本文件是「命令注册表 + 解析」的**唯一真源**（Core 层、纯 Foundation，Linux 可编可测）：
//   · 命令名 / 说明 / 是否带参 —— 只在这里定义；面板与帮助卡一律 `SlashCommand.allCases` 迭代，
//     **不许任何地方再手写一份命令名清单**（两份清单必然漂移）。
//   · 解析口径（前导/尾部空白容错、`/记一笔 35 咖啡` 切出 arg、未知命令返回非 nil）也只此一处。
//
// 三个返回约定（调用方靠它们分派，别在别处重写）：
//   · `parse(_:) == nil`            → 压根不是命令（照常走 sendCore）
//   · `parse(_:)?.cmd == nil`       → 是 `/` 开头的命令形态但**未注册**（本地消化，绝不发 LLM）
//   · `parse(_:)?.cmd != nil`       → 命中命令

import Foundation

/// 斜杠命令注册表（v1 六条）。
///
/// ⚠️ `rawValue` 就是命令名（不带 `/`），`expense` 用中文名 `记一笔`——`title` 统一补前导 `/`，
/// 所以面板/帮助卡里看到的是 `/new` … `/记一笔`。
enum SlashCommand: String, CaseIterable {
    case new
    case model
    case stop
    case usage
    case expense = "记一笔"
    case help

    /// 显示名（含前导 `/`），直接用于面板行与帮助卡。
    var title: String { "/" + rawValue }

    /// 一句说明（面板第二行 / 帮助卡副标题）。
    var hint: String {
        switch self {
        case .new:     return "新建会话"
        case .model:   return "切换模型 / 思考档位（下条生效）"
        case .stop:    return "停止当前回答"
        case .usage:   return "查看 token 用量"
        case .expense: return "记一笔账，如 /记一笔 35 咖啡"
        case .help:    return "列出全部命令"
        }
    }

    /// 是否需要参数（v1 只有 `/记一笔`）。
    var takesArgument: Bool { self == .expense }

    /// 面板点选后填入输入框的模板：带参命令补一个**尾空格**让用户接着打字，无参命令即命令名本身。
    var fillTemplate: String { takesArgument ? title + " " : title }
}

/// 命令解析 / 前缀匹配 / 金额抽取（纯函数，单一真源）。
enum SlashParser {
    /// 解析一行输入。
    ///
    /// 容错口径（与方案 §三 一致）：
    ///   · 允许前导/尾部空白（`" /new "` → `/new`）；
    ///   · 命令 token = 去掉前导 `/` 后**首个空白之前**的部分，其余为参数（允许参数内再带空格）；
    ///   · 无参命令（`/new`）arg = ""，带参命令空参（`/记一笔`）arg 同样 = ""；
    ///   · **未知命令也返回非 nil**（cmd = nil），由调用方分辨并本地消化（绝不发 LLM）；
    ///   · 返回 nil 仅当文本根本不是 `/` 开头的命令形态。
    static func parse(_ raw: String) -> (cmd: SlashCommand?, arg: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let token: Substring
        let arg: String
        if let sp = body.firstIndex(where: { $0.isWhitespace }) {
            token = body[..<sp]
            arg = String(body[body.index(after: sp)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = body
            arg = ""
        }
        // 单独一个 `/`（或 `/␣`）→ 不是命令，直通（别吞、别清草稿）
        guard !token.isEmpty else { return nil }
        // `/usr/bin 是什么`、`/etc/hosts 怎么改` 这类**路径/问句**不是命令（token 里还有斜杠）
        // → 直通。独立只读审查抓到：原先任何以 `/` 开头的文本都被判成命令形态，被吞 + 草稿清空 +
        // 只回一张「没有这个命令」，用户原话被销毁且无自救出口（面板此时还不弹，体感最差）。
        guard !token.contains("/") else { return nil }
        let lower = token.lowercased()
        let hit = SlashCommand.allCases.first { $0.rawValue.lowercased() == lower }
        return (hit, arg)
    }

    /// 面板前缀过滤：`"/h"` → 只剩 `/help`；`"/记"` → `/记一笔`；空前缀（`"/"`）→ 全部。
    /// ASCII 命令名大小写不敏感（`/NEW` 也能匹配）。
    static func matches(prefix raw: String) -> [SlashCommand] {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("/") { p.removeFirst() }
        p = p.lowercased()
        guard !p.isEmpty else { return SlashCommand.allCases }
        return SlashCommand.allCases.filter { $0.rawValue.lowercased().hasPrefix(p) }
    }

    /// 面板触发口径（单一真源）：文本以 `/` 开头**且不含空白**时返回其前缀，否则 nil。
    /// 语音态不在本判据里（那是宿主 ChatView 的 `voiceMode`，面板挂载点据此再收一次口）。
    static func panelPrefix(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        guard !t.contains(where: { $0.isWhitespace }) else { return nil }
        return t
    }

    /// 首个数字（整数/小数）为金额；解析不出返回 nil。
    /// `/记一笔 35 咖啡` → 35；`/记一笔 咖啡35` → 35（v1 口径：首个数字即金额，不猜语序）。
    static func leadingNumber(_ s: String) -> Double? {
        guard let r = firstNumberRange(s) else { return nil }
        return Double(s[r])
    }

    /// `/记一笔` 的「金额 + 用途」切分（单一真源）：首个数字作金额，去掉该数字后的剩余即用途。
    /// 解析不出数字返回 nil（调用方提示、不落库）；用途为空时由调用方兜底。
    static func expenseParts(_ arg: String) -> (amount: Double, item: String)? {
        guard let r = firstNumberRange(arg), let amount = Double(arg[r]) else { return nil }
        var rest = arg
        rest.removeSubrange(r)
        return (amount, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 首个数字的范围（金额抽取的唯一实现，上面两个出口都读它——免得两处各写一条正则）。
    private static func firstNumberRange(_ s: String) -> Range<String.Index>? {
        s.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression)
    }
}
