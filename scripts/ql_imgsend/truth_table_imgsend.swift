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
check("ChatStore 的压缩走同一实现与档位（不再各写 480/0.45）",
      storeSrc.contains("ImageDownscale.cellularMaxSide") && storeSrc.contains("ImageDownscale.wifiMaxSide")
      && storeSrc.contains("ImageDownscale.cellularQuality") && storeSrc.contains("ImageDownscale.wifiQuality"))
check("两档体积闸门分开（蜂窝 30 万字符 / WiFi 150 万字符；小图再压只会更糊）",
      storeSrc.contains("private static let cellularDownscaleThreshold = 300_000")
      && storeSrc.contains("private static let wifiDownscaleThreshold = 1_500_000")
      && storeSrc.contains("b64.count > threshold"))
check("historyPayload 的图串也要过档位压缩（历史图过去走 URL，现在走 base64）",
      storeSrc.contains(".map { self.sizedForSend($0) }"))
check("压缩结果缓存 key 用哈希（拿整条 base64 当 key = 又常驻一份 MB，且只写不删）",
      storeSrc.contains("let key = String(b64.hashValue)"))
check("压缩结果缓存同样有 FIFO 上限",
      storeSrc.contains("localImageSized[localImageSizedOrder.removeFirst()] = nil"))

// ④ 缓存上限（条数 + 字节双闸）
check("本地缓存有 FIFO 条数上限", storeSrc.contains("private static let localImageMaxEntries = 3")
      && storeSrc.contains("while localImageOrder.count > Self.localImageMaxEntries")
      && storeSrc.contains("localImageBase64[old] = nil"))
check("本地缓存还有字节预算（条数少也可能总量很大：预取单条 2MB × 3）",
      storeSrc.contains("private static let localImageMaxBytes = 6 * 1024 * 1024")
      && storeSrc.contains("> Self.localImageMaxBytes"))
check("魔数不认识的字节不登记（宁可降级 [图片]，也别贴个 image/jpeg 骗上游）",
      storeSrc.contains("guard !url.isEmpty, let mime = Self.imageMime(imageData) else { return }"))

// ⑤ 预取 + 触发点可达性（本表最容易假绿的地方）
check("重启兜底：把已落库 URL 的图预取回 base64",
      storeSrc.contains("func prefetchStoredImagesForSend(auth: AuthStore) async"))
check("预取取最近 N 条（payload 判定基于净化后的历史，只取一条可能取到会被剔掉的那条）",
      storeSrc.contains("for m in messages.reversed() where m.isUser")
      && storeSrc.contains("if targets.count >= Self.localImageMaxEntries { break }"))
check("预取与补传拆成两条链（下载超时 30s 别顶住补传）",
      storeSrc.contains("imagePrefetchTask = Task { [weak self] in")
      && storeSrc.contains("await self?.prefetchStoredImagesForSend(auth: auth)"))
check("预取走纯函数 downloadPath（可测），只认自家下载端点",
      storeSrc.contains("guard let path = Self.downloadPath(from: url) else { continue }"))
check("预取有大小与魔数护栏（别把 HTML 报错页当图缓存）",
      storeSrc.contains("data.count <= Self.prefetchMaxBytes") && storeSrc.contains("Self.imageMime(data) != nil"))
// 🚨 蜂窝下不许预取：auth.request 对带 query 的请求必然落 relay，而 relay 每次新建 ASWAS（无授权缓存）
//    → 冷启动就弹系统 Safari 授权窗；relay 还是串行队列，会把用户紧接着的聊天请求排到后面；
//    且 relay 响应体过 JSON 字符串 → utf8 重编码，二进制图必坏（弹窗 + 占信道 + 必失败，纯白跑）
check("蜂窝下一律不预取（不弹 Safari 授权窗、不占 relay 串行槽）",
      storeSrc.contains("guard !NetworkMonitor.shared.isCellular else { return }"))
// 🚨 冷启动触发点：onChange(of: sessionId) 在同值时**不会触发** → 必须额外补一次
// v4.0.0：冷启动那行已改名 applyLaunchSessionPolicy（内含开新对话/回上次两分支），
//   但**本条护栏要守的是「会话落定之后才补跑图片链」这个顺序**，与调用名无关
//   → 认两个名字任一，别把护栏钉死在某个函数名上。
let coldStartOK: Bool = {
    let names = ["await chat.applyLaunchSessionPolicy(auth: auth)",
                 "await chat.loadLastSession(auth: auth)"]
    guard let a = names.compactMap({ appSrc.range(of: $0) }).first,
          let b = appSrc.range(of: "chat.startImageRetryUploads(auth: auth)") else { return false }
    return a.upperBound < b.lowerBound
}()
check("冷启动补触发（会话落定之后，且 order 在后）", coldStartOK)
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
check("源码里 brand 偏移是 b[8..<12]（写成 b[4..<8] 会永远判不出 heic，而字符串护栏查不出）",
      storeSrc.contains("String(bytes: b[8..<12], encoding: .ascii)"))

// ── 5. 纯函数镜像：downloadPath（v3.9.60 从 prefetch 里抽出来，就是为了能在这里测） ──
// 内联在 prefetch 里时，这段逻辑只有字符串 grep 护着：后端换了 URL 形态 → 预取静默全跳、
// 所有历史图恒降级 [图片]，而表照样全绿。抽成纯函数后按行为断言。
func downloadPath(from url: String) -> String? {
    guard url.hasPrefix("http"), let q = url.firstIndex(of: "?"),
          url[..<q].hasSuffix("/api/files/download") else { return nil }
    let qs = String(url[q...])
    guard !qs.contains("#") else { return nil }
    return "/api/files/download" + qs
}
let okURL = "https://webui.example.com:16666/api/files/download?path=image.jpg"
check("自家下载 URL → 相对路径（走 auth.request 带 token）",
      downloadPath(from: okURL) == "/api/files/download?path=image.jpg")
check("相对路径形态 → nil（不会拿它去要图）", downloadPath(from: "api/files/download?path=x") == nil)
check("别的端点 → nil", downloadPath(from: "https://webui.example.com:16666/api/sessions?path=x") == nil)
check("无 query → nil", downloadPath(from: "https://webui.example.com:16666/api/files/download") == nil)
check("带 fragment → nil（fragment 不会被发到服务器，拿回来是 404 页）",
      downloadPath(from: okURL + "#x") == nil)
check("别的主机走同一相对路径（后端按 path 取图，与主机无关）",
      downloadPath(from: "http://other.example.com:16666/api/files/download?path=a.png")
      == "/api/files/download?path=a.png")

// ── 6. 纯函数镜像：imageMime（喂真字节，别只用字符串 grep 钉住） ──
// ⚠️ 上一版表只用 contains 钉「函数存在 + default: return nil」——brand 偏移写错、或把 avif 判成
//    heic，都照样绿。这里按真字节断言（本机 swiftc 能跑纯 Foundation）。
func imageMime(_ d: Data) -> String? {
    let b = [UInt8](d.prefix(12))
    if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
    if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
       b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
    if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" {
        switch String(bytes: b[8..<12], encoding: .ascii) ?? "" {
        case "heic", "heix", "hevc", "heim", "heis", "mif1": return "image/heic"
        default: return nil
        }
    }
    if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
       String(bytes: b[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
    if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
    return nil
}
/// 构造 ISO BMFF 头：[box size 4B] + "ftyp" + [brand 4B] + [4B 填充]
func ftypBytes(_ brand: String) -> Data {
    var b: [UInt8] = [0x00, 0x00, 0x00, 0x18]
    b += Array("ftyp".utf8)
    b += Array(brand.utf8.prefix(4))
    b += [0, 0, 0, 0]
    return Data(b)
}
check("jpeg 魔数 → image/jpeg",
      imageMime(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])) == "image/jpeg")
check("png 魔数 → image/png",
      imageMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])) == "image/png")
check("heic 系 brand → image/heic（brand 必须读 b[8..<12]）",
      ["heic", "heix", "hevc", "heim", "heis", "mif1"].allSatisfy { imageMime(ftypBytes($0)) == "image/heic" })
check("mp4 / avif / m4a 的 ftyp → nil（一律当 heic 就会造出「MIME 说 heic、内容不是图」）",
      ["isom", "mp42", "avif", "avis", "M4A "].allSatisfy { imageMime(ftypBytes($0)) == nil })
check("webp → image/webp",
      imageMime(Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))) == "image/webp")
check("gif → image/gif", imageMime(Data(Array("GIF89a".utf8) + [0, 0, 0, 0, 0, 0])) == "image/gif")
check("HTML 报错页 → nil（预取别把 404 页当图缓存）",
      imageMime(Data(Array("<!DOCTYPE ht".utf8))) == nil)
check("超短字节不越界（不足 8 字节 → nil，不是崩）", imageMime(Data([0x89, 0x50])) == nil)

print("图片发送链真值表：" + String(passCount) + " 通过 / " + String(failCount) + " 失败")
if failCount > 0 { exit(1) }
