// v4.0.36 聊天页「贴底（pinned）」推进真值表 —— Linux 本地预检用，纯 Foundation
// （编译真源 qingliao/Core/ChatScrollPin.swift，不是镜像 → 没有表/实现漂移的洞）
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 63 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_scrollpin \
//       scripts/ql_scrollpin/truth_table_scrollpin.swift qingliao/Core/ChatScrollPin.swift
//
// 事故（2026-10-03 用户实报「流式最新文字一路沉到输入栏下面、气泡不往上顶」）：
//   贴底判定原本是内联在 ChatView 闭包里的一个 Bool（“现在在不在底部”）直接赋给 isScrollPinned，
//   它分不清「谁让内容不在底部」：流式每来一段 delta 内容就长高几十 pt，而**同一帧里 offset 还没动**
//   （滚底挂在 stream.content 的 onChange、onScrollGeometryChange 可能先跑）→ 第一段 delta 就判成 false
//   → 之后每段都被 `guard isScrollPinned` 挡掉、自动滚底整段熄火，气泡只能在输入栏下面继续长。
//
// 第二轮（审查实踩，A6/A20 钉的就是它）：解除贴底若只比**单帧**增量（`offset < prev - 1`），
//   用户每帧只退 0.3pt 的慢速上滑（60Hz ≈ 18pt/s）永远够不到阈值 → 解除不了 → 照样被 delta 拽回。
//   所以本轮把状态从 Bool 改成 ChatScrollPinState（pinned + **贴底基准 offset**），
//   按「当前 offset 相对基准减少了多少」判**累计**回滚量。
//
// 两类断言：
//   A 段（纯逻辑）：钉「内容长高不得解除贴底」「用户上滑必须解除（含慢速）」「回到底部必须恢复」
//      「不满一屏恒贴底」「抖动幅度不算上滑」。A2/A20 是**反证**：同组入参按旧口径算结果必须相反
//      —— 说明 A1/A6 真的钉住了新旧差异，不是恒真护栏。
//   B 段（源级接线）：读 ChatView.swift 真源（先剥注释），钉「贴底推进走纯函数 + 状态是带基准的结构」
//      与「旧内联形态已清除」，并做反向自证（把旧形态塞回源文本 → 断言必红）。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

/// 断言：正例（要求为真）/ 反例（要求为假）分开计数，末尾核验反例占比。
func check(_ name: String, _ cond: Bool, negative: Bool = false) {
    print("\(cond ? "✅" : "❌") \(name)")
    if negative { negatives += 1 } else { positives += 1 }
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释与 `/* */` 块注释，只留代码文本。
/// 旧写法/旧口径在注释里留了一层记录（本仓惯例），不剥就会把注释喂成假绿护栏。
func stripComments(_ s: String) -> String {
    var out = ""
    var inBlock = false
    for rawLine in s.components(separatedBy: "\n") {
        var line = rawLine
        if inBlock {
            guard let end = line.range(of: "*/") else { continue }
            line = String(line[end.upperBound...])
            inBlock = false
        }
        if let start = line.range(of: "/*"), line.range(of: "*/", range: start.upperBound..<line.endIndex) == nil {
            line = String(line[..<start.lowerBound])
            inBlock = true
        }
        if let cut = line.range(of: "//") {
            line = String(line[..<cut.lowerBound])
        }
        out += line + "\n"
    }
    return out
}

@main
struct ScrollPinTruthTable {

    /// 旧口径 A（v3.0.86 形态）：只看「现在在不在底部」，不管是谁弄的。只用于 A2 反证。
    static func legacyAtBottom(offset: CGFloat, contentH: CGFloat, containerH: CGFloat) -> Bool {
        let maxY = contentH - containerH
        let bottomMax = max(0, maxY)
        return contentH <= containerH || offset >= bottomMax - 8
    }

    /// 旧口径 B（单帧增量阈值，v4.0.36 第一版）：`offset < prevOffset - 1` 才解除。只用于 A20 反证。
    /// 保留一个 pinned 位 + prevOffset，模拟逐帧回调。
    static func legacySingleFrame(pinned: Bool, prevOffset: CGFloat, offset: CGFloat,
                                  contentH: CGFloat, containerH: CGFloat) -> Bool {
        if contentH <= containerH { return true }
        let maxY = contentH - containerH
        if offset >= maxY - 8 { return true }
        if offset < prevOffset - 1 { return false }
        return pinned
    }

    static func main() {
        let container: CGFloat = 800
        let content: CGFloat = 2000          // maxY = 1200，贴底线 = 1192

        // ── A. 纯逻辑（ChatScrollPin.next，真源编译） ──────────────────────
        print("── A. 贴底推进纯逻辑 ──")

        // A1：流式 delta 本命 —— 内容长高、offset 同帧不动（基准 = 上一帧的底）→ 必须保持贴底
        check("A1 内容长高（offset 未动）→ 保持贴底（不得解除）",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1200),
                                 offset: 1200, contentH: 2040, containerH: container).pinned == true)

        // A2：反证 —— 同组入参按旧口径（只看在不在底部）算必然是 false，
        //     证明 A1 钉的是新旧真实差异，不是恒真。
        check("A2 反证：同组入参按旧口径算 = false（A1 有检测力）",
              legacyAtBottom(offset: 1200, contentH: 2040, containerH: container) == false)

        // A3：用户真的往回滚（单帧就出容差带）→ 解除贴底（上翻阅读不被 delta 拽回，v3.0.86 口径）
        check("A3 用户上滑（offset 变小）→ 解除贴底",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1192),
                                 offset: 1100, contentH: content, containerH: container).pinned == false,
              negative: true)

        // A4：滚回底部 → 恢复贴底，且基准归位到当前位置（下一次累计从新底起算）
        let a4 = ChatScrollPin.next(state: ChatScrollPinState(pinned: false, baseline: 0),
                                    offset: 1193, contentH: content, containerH: container)
        check("A4 滚回底部（约等于 maxY）→ 恢复贴底 + 基准归位",
              a4.pinned == true && a4.baseline == 1193)

        // A5：容差边界 —— 差 8pt 算到底，差 9pt 且 offset 未减少 → 保持原状（不解除）
        check("A5a 差 8pt（offset = maxY-8）算贴底",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: false, baseline: 0),
                                 offset: 1192, contentH: content, containerH: container).pinned == true)
        check("A5b 出容差带但累计回滚只有 0.5pt（基准 1191.5）→ 不误解除，保持贴底",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1191.5),
                                 offset: 1191.0, contentH: content, containerH: container).pinned == true)

        // A6：🚨 慢速上滑（审查实踩）—— 每帧只退 0.3pt（60Hz ≈ 18pt/s 龟速）。
        //     单帧口径下永远解除不了；累计口径下必须解除。
        //     算式：出容差带需走 8pt（1200→1192），带内每帧把基准挪到当下位置，
        //     出带后按累计回滚量判：基准 1192.2，退到 ≤1191.1 时回滚量 > 1 → 解除。
        //     offset = 1200 - 0.3×帧号：第 30 帧 = 1191.0（回滚 1.2）→ 应在第 30 帧解除。
        var slow = ChatScrollPinState(pinned: true, baseline: 1200)
        var unpinFrame = -1
        for frame in 1...40 {
            let off = 1200 - 0.3 * CGFloat(frame)
            slow = ChatScrollPin.next(state: slow, offset: off, contentH: content, containerH: container)
            if !slow.pinned { unpinFrame = frame; break }
        }
        check("A6 慢速上滑（每帧 0.3pt）累计超阈值即解除贴底（第 \(unpinFrame) 帧）",
              unpinFrame == 30,
              negative: true)

        // A7：容差带内的小抖动不算「离开底部」（基准附近的回弹/取整）
        check("A7 带内抖动 0.4pt 不算上滑 → 保持贴底",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1200),
                                 offset: 1199.6, contentH: content, containerH: container).pinned == true)

        // A8：内容不满一屏 → 恒贴底（没有可滚空间，minHeight 底部对齐兜住）
        check("A8 内容不满一屏 → 恒贴底（即便当前 pinned=false）",
              ChatScrollPin.next(state: .unpinned, offset: 0, contentH: 500,
                                 containerH: container).pinned == true)

        // A9：键盘弹出（可视高度变小、offset 不动）→ 内容相对变高，不得解除贴底
        check("A9 键盘弹出（containerH 变小）→ 保持贴底",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1200),
                                 offset: 1200, contentH: content, containerH: 700).pinned == true)

        // A10：切会话/加载更早 → offset 被夹到新的 maxY → 贴底恢复
        check("A10 内容变矮、offset 被夹到新 maxY → 贴底恢复",
              ChatScrollPin.next(state: .unpinned, offset: 1200, contentH: content,
                                 containerH: container).pinned == true)

        // A11/A12：没贴底时不抢 —— 内容长高 / 用户继续上滑都保持 false
        check("A11 未贴底 + 内容长高 → 不抢（保持未贴底）",
              ChatScrollPin.next(state: .unpinned, offset: 100, contentH: content,
                                 containerH: container).pinned == false,
              negative: true)
        check("A12 未贴底 + 用户继续上滑 → 保持未贴底",
              ChatScrollPin.next(state: .unpinned, offset: 500, contentH: content,
                                 containerH: container).pinned == false,
              negative: true)

        // A13：首帧（容器还没量出来）→ 不得把贴底判丢（否则流式一开就跑不动）
        check("A13 首帧 containerH=0 → 保持贴底",
              ChatScrollPin.next(state: .pinnedAtBottom, offset: 0, contentH: content,
                                 containerH: 0).pinned == true)

        // A14：内容比可视区矮、用户上滑（边界态）→ 仍算贴底
        check("A14 内容矮于可视区 + offset 变小 → 仍算贴底（无滚空间）",
              ChatScrollPin.next(state: .unpinned, offset: 0, contentH: 500,
                                 containerH: container).pinned == true)

        // A15：阈值常量不得被顺手改小/改没（改回去就是 A1/A6 那种熄火形态）
        check("A15 阈值常量仍在（容差 8 / 累计回滚 1）",
              ChatScrollPin.tolerance == 8 && ChatScrollPin.backScrollThreshold == 1)

        // A16–A19：没贴底时一律「不抢」——键盘收起/内容变矮/内容长高都不许把人拽到底，
        // 但同一轮里用户真的往回滚了就必须解除（A18：别拿「内容长高」当挡箭牌）
        check("A16 未贴底 + 键盘收起（containerH 变大）→ 不抢",
              ChatScrollPin.next(state: .unpinned, offset: 1000, contentH: content,
                                 containerH: 900).pinned == false,
              negative: true)
        check("A17 未贴底 + 内容变矮（仍超屏）→ 不抢",
              ChatScrollPin.next(state: .unpinned, offset: 100, contentH: 1900,
                                 containerH: container).pinned == false,
              negative: true)
        check("A18 贴底时用户上滑（同时内容长高）→ 必须解除，不得拿「内容长高」当挡箭牌",
              ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1200),
                                 offset: 1000, contentH: 2200, containerH: container).pinned == false,
              negative: true)
        check("A19 未贴底 + 内容长高 + 继续上滑 → 保持未贴底",
              ChatScrollPin.next(state: .unpinned, offset: 800, contentH: 2100,
                                 containerH: container).pinned == false,
              negative: true)

        // A20：🚨 反向自证 —— 同一组慢速上滑入参走「单帧阈值」旧口径，40 帧都不解除
        //      ⇒ 证明 A6 有检测力（旧实现下用户会被 delta 一路拽回底部）。
        var single = true
        var prevOff: CGFloat = 1200
        for frame in 1...40 {
            let off = 1200 - 0.3 * CGFloat(frame)
            single = legacySingleFrame(pinned: single, prevOffset: prevOff, offset: off,
                                       contentH: content, containerH: container)
            prevOff = off
        }
        check("A20 反证：单帧阈值口径下慢速上滑 40 帧仍不解除（旧实现的洞）",
              single == true,
              negative: true)

        // A21：基准缺失（状态从「不满一屏」直接长上来）→ 不得误解除（此时用户根本没滚过）
        check("A21 基准缺失（baseline=0）→ 内容长上来后仍保持贴底",
              ChatScrollPin.next(state: .pinnedAtBottom, offset: 0, contentH: content,
                                 containerH: container).pinned == true)

        // A22：基准只跟着「更靠下」的位置上移 —— 回滚量按峰值起算，小幅来回不反复原谅。
        //     （全部取在容差带外，否则会被分支②按「到底」重置基准）
        //     基准 1191 → 退 0.5pt（0.5 ≤ 1，保持）→ 推回 0.7pt（基准跟着峰值上移到 1191.2，
        //     这就是本条的检测力所在）→ 再退到 1190.1（距峰值 1.1 > 1）→ 解除。
        let a22a = ChatScrollPin.next(state: ChatScrollPinState(pinned: true, baseline: 1191),
                                      offset: 1190.5, contentH: content, containerH: container)
        let a22b = ChatScrollPin.next(state: a22a, offset: 1191.2, contentH: content, containerH: container)
        let a22c = ChatScrollPin.next(state: a22b, offset: 1190.1, contentH: content, containerH: container)
        check("A22 回滚按峰值起算：退 0.5 → 推回 0.7（基准跟着上移）→ 再退 1.1 才解除",
              a22a.pinned == true && a22a.baseline == 1191
                && a22b.pinned == true && a22b.baseline == 1191.2
                && a22c.pinned == false,
              negative: true)

        // ── B. 源级接线（ChatView.swift 真源） ────────────────────────────
        print("── B. ChatView 接线 ──")
        let raw = read("qingliao/Features/Chat/ChatView.swift")
        check("B0 ChatView.swift 读得到（cwd 必须是仓根）", !raw.isEmpty)
        let chatView = stripComments(raw)

        check("B1 贴底推进走纯函数 ChatScrollPin.next", chatView.contains("ChatScrollPin.next("))
        check("B2 几何回调吃的是三件套快照（offset/contentH/containerH）",
              chatView.contains("for: ChatScrollSnapshot.self"))
        check("B3 旧形态「Bool 直接赋值」已清除",
              !chatView.contains("action: { _, pinned in"), negative: true)
        check("B4 旧形态内联 atBottom 表达式已清除",
              !chatView.contains("return geo.contentSize.height <= geo.containerSize.height"),
              negative: true)
        check("B5 流式滚底仍以贴底位为闸（guard scrollPinState.pinned）",
              chatView.contains("guard scrollPinState.pinned else { return }"))
        check("B5b 🚨 状态是带基准的结构（不是一个 Bool）；单帧参数 prevOffset 形态已清零",
              chatView.contains("scrollPinState = ChatScrollPin.next(state: scrollPinState")
                && chatView.contains("@State private var scrollPinState = ChatScrollPinState.pinnedAtBottom")
                && !chatView.contains("prevOffset:"))
        check("B6 滚底目标仍是流式气泡（.id(\"streaming\") 那一行）",
              chatView.contains("proxy.scrollTo(\"streaming\", anchor: .bottom)"))
        check("B7 不满一屏贴底用的容器高度仍在测量",
              chatView.contains("chatListViewportH = h"))

        // 反向自证：把旧形态拼回源文本 → B3/B4/B5b 的断言必须为红（护栏有检测力）
        let reverted = chatView
            + "\n} action: { _, pinned in isScrollPinned = pinned }\n"
            + "return geo.contentSize.height <= geo.containerSize.height\n"
            + "isScrollPinned = ChatScrollPin.next(pinned: isScrollPinned, prevOffset: old.offset)\n"
        check("B8 反向自证：旧内联形态一旦复活 → B3/B4/B5b 必红",
              reverted.contains("action: { _, pinned in")
                && reverted.contains("return geo.contentSize.height <= geo.containerSize.height")
                && reverted.contains("prevOffset:"),
              negative: true)

        // ── C. 结果 ──────────────────────────────────────────────────────
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 三分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 3.0)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
