// MARK: - v3.9.80 色彩令牌口径 · 真值表（tone 色淡底一律走 Tint，不留字面 opacity）
//
// 背景（improve-ui 只读审计发现 + 用户 2026-09-25 回「1」= 按计划落地）：
//   Agent 卡头部状态图标的**淡色胶囊底**写的是字面 `0.14`，而同文件另两处同类底
//   （状态胶囊 :100、清单项状态胶囊 :218）走令牌 `Tint.subtle`（0.12）。
//   后果不是「看着不一样」（0.12 与 0.14 肉眼几乎分不出），而是**改口径时这一处会被落下**：
//   以后调 Tint.subtle 或换深浅色策略，头部图标底还停在 0.14 → 又变成「每处各调一下」。
//   契约源：`qingliao/Theme/Tint.swift:3-16`（v3.9.19 把全库 37 个 opacity 字面量收敛成四档，
//   用户 2026-09-14 拍板；subtle 0.12 = 淡色胶囊底、淡色分组底，最常用）。
// 计划全文：`/opt/data/scripts/qingliao_docs/design-plans/agent-card-status-icon-tint.md`
//
// ⚠️ 本表**扫全仓**（`qingliao/Features` 逐文件）：v3.9.80 先把 Agent 卡头部图标底从字面 0.14 收成 `Tint.subtle`，
//   随后用户拍板「顺带收口」同 role 另两处（`SessionsView` 的 tag 胶囊底、`ConnectorPanelSheet` 的 tint 色块底），
//   于是负断言从「只扫一个文件」升级成「扫 Features 目录」。
//   唯一豁免：`ConnectorPanelSheet.swift` 的 `.white.opacity(0.14)` 是**深色描边**，
//   Tint.swift:15 明文「深浅色各自取值由调用点决定（浅色 0.08 / 深色 0.14~0.22）」→ 不算违规。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

let cardSrc = src("qingliao/Features/Chat/AgentResultCard.swift")
let tintSrc = src("qingliao/Theme/Tint.swift")

// ── 1. 源可读 + Tint 契约在位（空了后面全是空真） ──────────────
check("AgentResultCard.swift 源可读", !cardSrc.isEmpty)
check("Tint.swift 源可读", !tintSrc.isEmpty)
check("Tint 四档语义在位（faint 0.08 / subtle 0.12 / soft 0.16 / strong 0.22）",
      tintSrc.contains("static let faint: CGFloat = 0.08")
      && tintSrc.contains("static let subtle: CGFloat = 0.12")
      && tintSrc.contains("static let soft: CGFloat = 0.16")
      && tintSrc.contains("static let strong: CGFloat = 0.22"))

// ── 2. 头部状态图标底走令牌（本次落地的那一处） ────────────────
check("Agent 卡头部状态图标底走 Tint.subtle（不再写字面 0.14）",
      cardSrc.contains(".background(toneColor(card.status?.tone).opacity(Tint.subtle), in: Capsule())"))
check("旧字面形态清零：本文件不再有 tone/tag 色底的字面 opacity(0.14)",
      !stripCommentLines(cardSrc).contains(".opacity(0.14)"))

// ── 2b. 同 role 另两处（v3.9.80 用户拍板「顺带收口」） ────────────
check("SessionsView 的 tag 胶囊底走 Tint.subtle（原先字面 0.14）",
      src("qingliao/Features/Sessions/SessionsView.swift")
        .contains(".background(tagColor(t).opacity(Tint.subtle), in: Capsule())"))
check("ConnectorPanelSheet 的 tint 色块底走 Tint.subtle（原先字面 0.14）",
      src("qingliao/Features/Dashboard/ConnectorPanelSheet.swift")
        .contains(".background(tint.opacity(Tint.subtle), in: RoundedRectangle(cornerRadius: 11))"))
check("深色描边保留 0.14（Tint.swift 明文允许调用点自定深浅取值，不属违规）",
      src("qingliao/Features/Dashboard/ConnectorPanelSheet.swift")
        .contains(".strokeBorder(.white.opacity(0.14), lineWidth: 0.8)"))

// ── 2c. 全仓扫描：彩色淡底不许再有字面 0.14 ────────────────────────
let featDir = "qingliao/Features"
var scannedFiles = 0
var offenders: [String] = []
if let en = FileManager.default.enumerator(atPath: featDir) {
    for case let rel as String in en where rel.hasSuffix(".swift") {
        guard let body = try? String(contentsOfFile: featDir + "/" + rel, encoding: .utf8) else { continue }
        scannedFiles += 1
        for (n, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }   // 注释里讲历史不算
            if line.contains(".opacity(0.14)") && !line.contains(".white.opacity(0.14)") {
                offenders.append("\(rel):\(n + 1)")
            }
        }
    }
}
check("Features 目录扫到源码（扫到 \(scannedFiles) 个文件；扫 0 个说明路径口径变了，下面就是空真）",
      scannedFiles > 50)
check("彩色淡底字面 0.14 全仓清零（豁免只剩深色描边 .white.opacity(0.14)）—— 违规点：\(offenders)",
      offenders.isEmpty)

// ── 3. 同文件另两处同类底仍是令牌（防被误改回字面量） ─────────────
check("状态胶囊底（:100）仍走 Tint.subtle",
      cardSrc.components(separatedBy: "toneColor(tone).opacity(Tint.subtle)").count - 1 >= 1)
check("清单项状态胶囊底仍走 Tint.subtle",
      cardSrc.contains(".background(toneColor(item.tone).opacity(Tint.subtle), in: Capsule())"))

print("色彩令牌口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
