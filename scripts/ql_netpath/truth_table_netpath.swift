// 蜂窝网络路径口径 —— 源级真值表（读源文件做护栏，不 import 项目代码）
//
// 为什么必须有这张表：**「蜂窝特判走错路径」编译/真机日志都不报错，只有用户手指能发现**。
//   v4.0.60 统一了口径（蜂窝先 CFStream 直连、只读 GET 失败不降级免弹窗、写操作失败才降级 relay），
//   但 `downloadFile` 漏了 —— 蜂窝下**无条件 relay**（ASWebAuthenticationSession：必弹系统授权窗
//   且只适合小响应）。用户报「蜂窝网络下载和预览」＝ 每次下载/预览都弹窗、慢、失败，切 WiFi 就好。
//   2026-10-14 修：downloadFile 改为直连优先。
//
// ⚠️ **必须 cwd = 仓库根**（下列路径是相对路径）。

import Foundation

var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意复述了「原来那样是错的」，直接 grep 原文会被自己的注释判红）
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

let authSrc = src("qingliao/Core/AuthStore.swift")
let auth = code(authSrc)
let relaySrc = src("qingliao/Core/SafariRelay.swift")
let relay = code(relaySrc)

check("① 源可读（AuthStore / SafariRelay）", authSrc.count > 20000 && relaySrc.count > 3000)

/// 取函数体（从签名到下一个 4 空格缩进的 `}`）
func body(_ text: String, from sig: String) -> String {
    guard let r = text.range(of: sig) else { return "" }
    let rest = String(text[r.upperBound...])
    let end = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

// ── ② downloadFile：蜂窝必须直连优先（本表核心） ───────────────
let dl = body(auth, from: "func downloadFile(_ path: String, allowRelay: Bool = true) async throws -> (Data, Int) {")
check("② downloadFile 函数体切出来了（切不出 = 下面断言全是空真）", dl.count > 200)
check("② 蜂窝分支先走直连 relay.directRequest（CFStream，免授权弹窗）",
      dl.contains("relay.directRequest("))
check("② 直连在 relay.relay 之前（顺序反了 = 还是每次弹窗）",
      dl.range(of: "relay.directRequest(") != nil
      && dl.range(of: "relay.relay(") != nil
      && dl.range(of: "relay.directRequest(")!.lowerBound < dl.range(of: "relay.relay(")!.lowerBound)
check("② 成功即返回（不许直连成功还去弹窗）",
      dl.contains("(200..<300).contains(result.1) { return result }"))
check("② relay 兜底还得在（删了 = 直连不通时彻底没法下载）",
      dl.contains("relay.relay(method: \"GET\""))
check("② 假 401 走**直连重试一次**，不降级 relay 弹窗（v4.0.60 同口径）",
      dl.contains("result.1 == 401") && dl.contains("!sessionExpired"))
check("② WiFi 分支仍走 directHTTP（别把 WiFi 也拖下水）",
      dl.contains("guard NetworkMonitor.shared.isCellular else")
      && dl.contains("directHTTP(method: \"GET\""))

// ── ②b 自动路径闸门 allowRelay（v4.0.162：切到工作台必弹登录框的根因） ──────
// 自动路径 = 页面一出现就自己跑的下载（产物缩略图/后台预取）。它们若降级 relay，
// 每张图弹一次 ASWAS 系统授权窗 → 用户看到「每次切到工作台都弹登录框」。
check("② 缺省仍允许 relay（用户主动点的下载/预览行为不变）",
      auth.contains("func downloadFile(_ path: String, allowRelay: Bool = true)"))
check("② 闸门在 relay.relay 之前（挪到后面 = 弹完窗再判，等于没拦）",
      dl.range(of: "guard allowRelay else") != nil
      && dl.range(of: "relay.relay(") != nil
      && dl.range(of: "guard allowRelay else")!.lowerBound < dl.range(of: "relay.relay(")!.lowerBound)
check("② 关掉 relay 时如实失败（不许静默返回空 Data 当成功）",
      dl.contains("if let directError { throw directError }")
      && dl.contains("throw result.1 > 0 ? APIError.server(result.1) : APIError.badResponse"))
check("② 真 401 走统一收敛点（markSessionExpired），自动路径不会「永远空图且无横幅」",
      dl.contains("markSessionExpired()") && dl.contains("throw APIError.unauthorized")
      && dl.range(of: "markSessionExpired()")!.lowerBound < dl.range(of: "relay.relay(")!.lowerBound)
let thumb = code(src("qingliao/Features/Workspace/ArtifactThumbnail.swift"))
check("② 产物缩略图（自动路径）显式关 relay",
      thumb.contains("downloadFile(path, allowRelay: false)"))
// ②c 失败负缓存（v4.0.165）：自动路径失败后不许每次进页面重跑一遍超时
check("② 缩略图有失败负缓存，且 TTL 到期可重试（不是永久放弃）",
      thumb.contains("failureCache") && thumb.contains("failureTTL: TimeInterval = 60")
      && thumb.contains("if Self.recentlyFailed(path)"))
check("② 负缓存只拦「下载前」，成功必须清掉标记（否则修好也不补图）",
      thumb.range(of: "Self.recentlyFailed(path)")!.lowerBound
      < thumb.range(of: "downloadFile(path, allowRelay: false)")!.lowerBound
      && thumb.contains("Self.failureCache.removeObject(forKey: path as NSString)"))
check("② 下载失败/解码失败都要落标记（只标 catch 会漏「200 但不是图片」）",
      thumb.components(separatedBy: "Self.markFailed(path)").count - 1 >= 2)

// ── ③ relay 的性质没被误解（它不是直连） ────────────────────────
check("③ relay 仍走 ASWAS（弹窗通道），没被悄悄改成直连",
      relay.contains("func relay(method: String, path: String")
      && relay.contains("runASWAS"))
check("③ directRequest = CFStream 直连通道仍在（下载依赖它）",
      relay.contains("func directRequest(method: String, path: String"))

// ── ④ 用户可见文案诚实性（失败文案别再一律甩锅蜂窝） ─────────────
let kit = code(src("qingliao/Core/FilesManagerKit.swift"))
check("④ 下载失败文案仍带蜂窝提示（真失败时给用户退路）",
      kit.contains("蜂窝网络受限，建议连 WiFi 重试"))

print("蜂窝网络路径口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
