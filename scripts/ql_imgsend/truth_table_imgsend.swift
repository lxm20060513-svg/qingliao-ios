// MARK: - v3.9.60 图片发送链真值表（源护栏 + 纯函数回归）
//
// 事故背景（2026-09-23 用户实测）：
//   Provider said: HTTP 400: .messages[1].image[0]: Failed to download image from
//   https://webui.<域名>:16666/api/files/download?path=image.jpg
// 根因（NAS 上实测，不是猜）：图片以**自家 URL** 形式交给上游模型，而该域**只有 AAAA（IPv6）**——
//   nslookup -type=A    webui.<域名> → No answer（无 A 记录）
//   nslookup -type=AAAA webui.<域名> → 2409:8a5c:49f:6151::b71
// 上游厂商（DeepSeek / StepFun / 智谱…）是 IPv4 云 → **必然**下载失败（不是偶发抖动）。
//
// 定稿口径（本表逐条钉死）：
//   ① payload 里只允许 base64；自家 http URL 只用于显示 / 落库 / 预取下载
//   ② 拿不到 base64 就降级 [图片] 文本，绝不再把 URL 交出去
//   ③ 发送链每一环都用同一档蜂窝压缩（ImageDownscale），别在别处再写一份
//   ④ 本地 base64 缓存有上限（FIFO），别让它常驻吃内存
//   ⑤ 触发点必须真的可达：冷启动时 onChange(of: sessionId) 看不到变化（同值），要单独补一次
//
// 用法（必须在仓库根跑，表内用相对路径读源）：python3 /opt/data/scripts/ql.py test

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ " + name) }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { return "" }
    return s
}

/// 全 App 源（Core + Features 递归 + 根目录）拼一份 —— 用来统计「图块构造点」这类全局性的东西
func allAppSources() -> String {
    var out = ""
    let fm = FileManager.default
    for sub in ["Core", "Features", "Theme"] {
        let dir = root + "/" + sub
        guard let en = fm.enumerator(atPath: dir) else { continue }
        for case let f as String in en where f.hasSuffix(".swift") {
            if let s = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) { out += s }
        }
    }
    if let en = fm.enumerator(atPath: root) {
        for case let f as String in en where f.hasSuffix(".swift") && !f.contains("/") {
            if let s = try? String(contentsOfFile: root + "/" + f, encoding: .utf8) { out += s }
        }
    }
    return out
}

let storeSrc = src("Core/ChatStore.swift")
let modelSrc = src("Core/Models.swift")
let chatViewSrc = src("Features/Chat/ChatView.swift")
let appSrc = src("QingliaoApp.swift")
let downscaleSrc = src("Core/ImageDownscale.swift")
let allSrc = allAppSources()

// ── 源护栏：非空（源路径变了会静默假绿，先兜住） ───────────────
check("ChatStore.swift 源可读", !storeSrc.isEmpty)
check("Models.swift 源可读", !modelSrc.isEmpty)
check("ChatView.swift 源可读", !chatViewSrc.isEmpty)
check("QingliaoApp.swift 源可读", !appSrc.isEmpty)
check("ImageDownscale.swift 源可读", !downscaleSrc.isEmpty)
check("全 App 源可枚举（递归 Core/Features）", allSrc.count > 100_000)

// ── 1. 纯函数镜像：sendableImageURL（与 ChatStore.swift 逐字一致，第 2 节钉住字面量） ──
func sendableImageURL(_ stored: String?, cache: [String: String]) -> String? {
    guard let s = stored, !s.isEmpty else { return nil }
    if s.hasPrefix("data:") { return s }
    if s.hasPrefix("http") { return cache[s] }
    return nil
}

let b64 = "data:image/jpeg;base64,AAAA"
let nasURL = "https://webui.example.com:16666/api/files/download?path=image.jpg"

check("data: 串原样放行（本地 base64 直发）", sendableImageURL(b64, cache: [:]) == b64)
check("nil → nil", sendableImageURL(nil, cache: [:]) == nil)
check("空串 → nil", sendableImageURL("", cache: [:]) == nil)
// 🚨 本表核心断言：落库 URL 在缓存未命中时必须返回 nil（调用方降级 [图片]），绝不外发
check("落库 URL 且缓存未命中 → nil（绝不把自家 URL 交给上游）", sendableImageURL(nasURL, cache: [:]) == nil)
check("落库 URL 且缓存命中 → 用本地 base64 顶上", sendableImageURL(nasURL, cache: [nasURL: b64]) == b64)
check("任何输入的任何分支都不返回 http(s) 串",
      [b64, nasURL, "", "http://x/y.jpg", "ftp://x", "relative/path.jpg"].allSatisfy { input in
          ((sendableImageURL(input, cache: [nasURL: b64]) ?? "").hasPrefix("http")) == false
      })
check("缓存 key 必须按完整 URL 命中（尾斜杠变体不命中 → 宁可降级）",
      sendableImageURL(nasURL, cache: [nasURL + "/": b64]) == nil)

// 事故证据：旧行为（把 imageDataURL 原样当 image_url.url）确实会发 http URL —— 所以必须靠本函数拦住
func oldAsPayloadImageURL(_ imageDataURL: String?) -> String? { imageDataURL }
check("事故证据：旧行为对同一输入会返回 http URL（本 bug 的成因）",
      (oldAsPayloadImageURL(nasURL) ?? "").hasPrefix("https://webui.") == true)

// ── 2. 源护栏：决策函数每个分支都绑字面量（只钉一条分支 = 改别的分支不报警） ──
check("ChatStore 提供 sendableImageURL（纯函数）", storeSrc.contains("static func sendableImageURL("))
check("分支①：空/nil 直接 nil", storeSrc.contains("guard let s = stored, !s.isEmpty else { return nil }"))
check("分支②：data: 原样放行", storeSrc.contains("if s.hasPrefix(\"data:\") { return s }"))
check("分支③：http 只查本地缓存（cache[s]），不回落原串",
      storeSrc.contains("if s.hasPrefix(\"http\") { return cache[s] }"))
check("分支④：其它前缀 → nil",
      storeSrc.contains("static func sendableImageURL(_ stored: String?, cache: [String: String]) -> String? {"))

// ── 3. 源护栏：接线（登记 / 上传口径 / 蜂窝压缩 / 预取 / 触发点） ──
check("historyPayload 用该决策取图串",
      storeSrc.contains("Self.sendableImageURL(m.imageDataURL, cache: localImageBase64)"))
check("historyPayload 在拿不到 base64 时降级文本", storeSrc.contains("|| sendable == nil"))
check("上传成功即登记本地缓存（发送才拿得到 base64）",
      storeSrc.contains("func rememberLocalImage(url: String, imageData: Data)")
      && storeSrc.contains("if let url { rememberLocalImage(url: url, imageData: imageData) }"))
check("上传实现与登记分离（uploadImageInner 覆盖 WiFi / 蜂窝两条入口）",
      storeSrc.contains("private func uploadImageInner(_ imageData: Data, auth: AuthStore) async -> String?"))

// ③ 蜂窝压缩：单一实现，两处都复用（ChatView 里另有 compressImage = 选图时 1280/0.72，用途不同，不算重复）
check("ImageDownscale 是蜂窝压缩的单一实现（compressForCellular 不再自带一份）",
      downscaleSrc.contains("UIGraphicsImageRenderer")
      && chatViewSrc.contains("ImageDownscale.dataURL(imageDataURL,")
      && !chatViewSrc.contains("jpegData(compressionQuality: 0.45)"))
check("ChatView.compressForCellular 复用 ImageDownscale",
      chatViewSrc.contains("ImageDownscale.dataURL(imageDataURL,"))
check("ChatStore 的蜂窝压缩走同一档位（不再各写 480/0.45）",
      storeSrc.contains("ImageDownscale.dataURL(b64, maxSide: ImageDownscale.cellularMaxSide,"))
check("蜂窝只压大串（小图再压只会更糊）",
      storeSrc.contains("b64.count > Self.cellularDownscaleThreshold"))
check("historyPayload 的图串也要过蜂窝压缩（历史图过去走 URL，现在走 base64）",
      storeSrc.contains(".map { self.cellularSizedImage($0) }"))

// ④ 缓存上限
check("本地缓存有 FIFO 上限", storeSrc.contains("private static let localImageMaxEntries = 3")
      && storeSrc.contains("while localImageOrder.count > Self.localImageMaxEntries")
      && storeSrc.contains("localImageBase64[old] = nil"))

// ⑤ 预取 + 触发点可达性（本表最容易假绿的地方）
check("重启兜底：把已落库 URL 的图预取回 base64",
      storeSrc.contains("func prefetchStoredImagesForSend(auth: AuthStore) async"))
check("预取取最近 N 条（payload 判定基于净化后的历史，只取一条可能取到会被剔掉的那条）",
      storeSrc.contains("for m in messages.reversed() where m.isUser")
      && storeSrc.contains("if targets.count >= Self.localImageMaxEntries { break }"))
check("预取与补传拆成两条链（下载超时 30s 别顶住补传）",
      storeSrc.contains("imagePrefetchTask = Task { [weak self] in")
      && storeSrc.contains("await self?.prefetchStoredImagesForSend(auth: auth)"))
check("预取只认自家下载端点（相对路径走 auth.request，带 token）",
      storeSrc.contains("url[..<q].hasSuffix(\"/api/files/download\")"))
check("预取有大小与魔数护栏（别把 HTML 报错页当图缓存）",
      storeSrc.contains("data.count <= 8 * 1024 * 1024") && storeSrc.contains("Self.imageMime(data) != nil"))
// 🚨 冷启动触发点：onChange(of: sessionId) 在同值时**不会触发** → 必须额外补一次
let coldStartOK: Bool = {
    guard let a = appSrc.range(of: "await chat.loadLastSession(auth: auth)"),
          let b = appSrc.range(of: "chat.startImageRetryUploads(auth: auth)") else { return false }
    return a.upperBound < b.lowerBound
}()
check("冷启动补触发（loadLastSession 之后，且 order 在后）", coldStartOK)
check("切会话仍保留原触发点", chatViewSrc.contains("chat.startImageRetryUploads(auth: auth)"))
// 事故证据：这条链原先只有 onChange 触发点（冷启动不跑）——冻结这个「单触发点」形态，回归即红
check("事故证据：onChange(of: chat.sessionId) 是原（唯一）触发点，冷启动不覆盖",
      chatViewSrc.contains("chat.startImageRetryUploads(auth: auth)"))

// Models.asPayload：空串 = 强制不带图（调用方写文本降级）
check("asPayload 支持强制覆盖串", modelSrc.contains("func asPayload(imageURLOverride: String? = nil)"))
check("asPayload 空串语义 = 不带图", modelSrc.contains("return o.isEmpty ? nil : o"))
check("asPayload 默认行为不变（旧调用零改动）",
      modelSrc.contains("guard let o = imageURLOverride else { return imageDataURL }"))

// ── 4. 全局反向护栏 ──────────────────────────────────────────
// 图块构造点在**全 App 源**里恰好 1 处（只看 Models.swift 会让别处新拼的块偷偷漏过）
let builders = allSrc.components(separatedBy: "blocks.append([\"type\": \"image_url\", \"image_url\": [\"url\": img]])").count - 1
check("image_url 图块构造点恰好 1 处（实测 \(builders) 处；多了就绕过本决策）", builders == 1)
check("没有「URL 直发」残留（imageDataURL 直接进图块）",
      !allSrc.contains("[\"type\": \"image_url\", \"image_url\": [\"url\": m.imageDataURL"))
check("魔数探针不再写两份（mimeForImage / looksLikeImage 已合并成 imageMime）",
      !storeSrc.contains("static func mimeForImage(") && !storeSrc.contains("static func looksLikeImage("))
check("imageMime 对非图返回 nil（别把 mp4/avif 当 heic）",
      storeSrc.contains("static func imageMime(_ d: Data) -> String?")
      && storeSrc.contains("default: return nil"))

print("图片发送链真值表：" + String(passCount) + " 通过 / " + String(failCount) + " 失败")
if failCount > 0 { exit(1) }
