import Foundation

// 分享协议（ShareLinkCodec）的本地断言 —— 纯 Foundation，可在 Linux 预检环境直接跑。
// 入口：check_swift.sh 第 29 段（多文件编译时只有 main.swift 允许顶层代码 → 脚本里先 cp 成 main.swift）。
// 口径（本文件钉死的东西）：URL / 剪贴板两条通道的往返无损、残载荷与版本不符整条丢弃、
// 别的 scheme（含既有 qingliao://chat 深链）绝不接管 —— 协议改了这里必红。

var failures = 0
var checks = 0
@MainActor func check(_ name: String, _ ok: Bool) {
    checks += 1
    if !ok { failures += 1; print("❌ \(name)") }
}

// MARK: 1. inline 通道：文本 / 链接 / 说明 / 来源名
let p1 = ShareLinkCodec.Payload(id: ShareLinkCodec.newID(), kind: .inline,
                                text: "https://example.com/a?b=1&c=2#frag", note: "帮我看看这个",
                                sourceName: "Example Page", hasImage: false)
check("inline 判定", ShareLinkCodec.kind(text: p1.text, hasImage: false) == .inline)
guard let u1 = ShareLinkCodec.url(for: p1) else { fatalError("组装 URL 失败") }
let back1 = ShareLinkCodec.payload(from: u1)
check("URL scheme/host", u1.scheme == "qingliao" && u1.host == "share")
check("inline 往返", back1 == p1)
check("inline 文案", ShareLinkCodec.message(for: p1) == "帮我看看这个\n\nhttps://example.com/a?b=1&c=2#frag")
check("URL 里 & 数量 = 参数数（载荷未污染 query）",
      u1.absoluteString.components(separatedBy: "&").count == 6)   // v,id,k,t,n,s 各一段

// MARK: 2. 刁钻字符往返（中文 / emoji / 换行 / URL 保留字符）
let tricky = "中文 🎉 emoji\n换行 + 加号 & 和号 = 等号 # 井号 ? 问号 / 斜杠 % 百分号 \"引号\""
let p2 = ShareLinkCodec.Payload(id: "id-2", kind: .inline, text: tricky, note: "",
                                sourceName: nil, hasImage: false)
guard let u2 = ShareLinkCodec.url(for: p2), let back2 = ShareLinkCodec.payload(from: u2) else {
    fatalError("刁钻字符组装/解析失败")
}
check("刁钻字符往返无损", back2.text == tricky)
check("URL 里没有裸露的 # & 载荷字符",
      !u2.absoluteString.replacingOccurrences(of: "qingliao://share?", with: "").contains("#"))

// MARK: 3. base64url padding：长度 %4 == 2 / 3 / 0 三种都要能解回
for n in [1, 2, 3, 4, 5, 6, 7, 8] {
    let s = String(repeating: "A", count: n)
    let p = ShareLinkCodec.Payload(id: "pad-\(n)", kind: .inline, text: s, note: "", sourceName: nil, hasImage: false)
    let ok = ShareLinkCodec.url(for: p).flatMap(ShareLinkCodec.payload(from:))?.text == s
    check("padding n=\(n) 往返", ok)
}

// MARK: 4. 超长文本 → 剪贴板通道（URL 里不许再带正文）
let longText = String(repeating: "长文本🧵", count: 1_500)   // UTF-8 远超 4000 字节
check("超长文本判定为剪贴板通道", ShareLinkCodec.kind(text: longText, hasImage: false) == .clipboard)
let pLong = ShareLinkCodec.Payload(id: "long-1", kind: .clipboard, text: longText, note: "摘要",
                                   sourceName: nil, hasImage: false)
guard let uLong = ShareLinkCodec.url(for: pLong), let clipLong = ShareLinkCodec.clipboardItem(pLong, imageJPEG: nil)[ShareLinkCodec.pasteboardType] as? Data else {
    fatalError("超长文本载荷组装失败")
}
check("剪贴板通道的 URL 只带元信息（无 t/n/s）",
      !uLong.absoluteString.contains("t=") && !uLong.absoluteString.contains("n="))
check("剪贴板通道 URL 仍能判出 kind/id",
      ShareLinkCodec.payload(from: uLong)?.kind == .clipboard && ShareLinkCodec.payload(from: uLong)?.id == "long-1")
let decodedLong = ShareLinkCodec.payload(fromClipboardItem: [ShareLinkCodec.pasteboardType: clipLong])
check("超长文本剪贴板往返无损", decodedLong?.payload.text == longText && decodedLong?.payload.note == "摘要")
check("超长文本文案", ShareLinkCodec.message(for: decodedLong!.payload) == "摘要\n\n" + longText)

// MARK: 5. 边界：正好 4000 字节走 inline，4001 字节走剪贴板
let b4000 = String(repeating: "a", count: 4_000)
let b4001 = String(repeating: "a", count: 4_001)
check("4000 字节边界 = inline", ShareLinkCodec.kind(text: b4000, hasImage: false) == .inline)
check("4001 字节边界 = clipboard", ShareLinkCodec.kind(text: b4001, hasImage: false) == .clipboard)
check("带图一律走剪贴板", ShareLinkCodec.kind(text: "hi", hasImage: true) == .clipboard)

// MARK: 6. 图片通道
let fakeJPEG = Data((0..<2_048).map { UInt8($0 % 251) })
let pImg = ShareLinkCodec.Payload(id: "img-1", kind: .clipboard, text: "", note: "",
                                  sourceName: nil, hasImage: true)
guard let uImg = ShareLinkCodec.url(for: pImg),
      let itemImg = ShareLinkCodec.clipboardItem(pImg, imageJPEG: fakeJPEG)[ShareLinkCodec.pasteboardType] as? Data,
      let decodedImg = ShareLinkCodec.payload(fromClipboardItem: [ShareLinkCodec.pasteboardType: itemImg]) else {
    fatalError("图片载荷组装/解析失败")
}
check("图片字节往返一致", decodedImg.imageJPEG == fakeJPEG)
check("图片载荷 hasImage 正确", decodedImg.payload.hasImage && decodedImg.payload.kind == .clipboard)
check("带图 URL 带 img=1", uImg.absoluteString.contains("img=1"))
check("只分享一张图（无文字无来源）→ 文案为空串（走纯图片消息）", ShareLinkCodec.message(for: pImg) == "")
check("空正文但有来源名 → 兜底文案", ShareLinkCodec.message(for: ShareLinkCodec.Payload(
    id: "x", kind: .inline, text: "", note: "", sourceName: "某网页标题", hasImage: false)) == "（分享自 某网页标题）")
check("只填说明也能成消息（说明 + 空正文）", ShareLinkCodec.message(for: ShareLinkCodec.Payload(
    id: "y", kind: .inline, text: "  ", note: " 帮我润色 ", sourceName: nil, hasImage: false)) == "帮我润色")

// MARK: 7. 不接管别人的 URL / 残载荷要拒
check("qingliao://chat 深链不归本协议（DockTabView 的既有路径不受影响）",
      ShareLinkCodec.payload(from: URL(string: "qingliao://chat?session=abc")!) == nil)
check("qingliao://sessions 不归本协议", ShareLinkCodec.payload(from: URL(string: "qingliao://sessions")!) == nil)
check("别的 scheme 不归本协议", ShareLinkCodec.payload(from: URL(string: "https://example.com/?v=1&id=x&k=inline")!) == nil)
check("版本不符 → 整条丢弃", ShareLinkCodec.payload(from: URL(string: "qingliao://share?v=99&id=x&k=inline&t=YQ")!) == nil)
check("inline 缺正文 → 丢弃（不发空消息）", ShareLinkCodec.payload(from: URL(string: "qingliao://share?v=1&id=x&k=inline")!) == nil)
check("缺 id → 丢弃", ShareLinkCodec.payload(from: URL(string: "qingliao://share?v=1&k=inline&t=YQ")!) == nil)
check("未知 kind → 丢弃", ShareLinkCodec.payload(from: URL(string: "qingliao://share?v=1&id=x&k=weird&t=YQ")!) == nil)
check("剪贴板条目里没有我们的类型 → nil",
      ShareLinkCodec.payload(fromClipboardItem: ["public.utf8-plain-text": Data("hi".utf8)]) == nil)
check("剪贴板条目版本不符 → nil",
      ShareLinkCodec.payload(fromClipboardItem: [ShareLinkCodec.pasteboardType:
        #"{"v":9,"id":"a","k":"inline","t":"hi"}"#.data(using: .utf8)!]) == nil)

// MARK: 8. 令牌唯一
check("newID 唯一", Set((0..<200).map { _ in ShareLinkCodec.newID() }).count == 200)
check("载荷版本为 1", ShareLinkCodec.payloadVersion == 1)
check("剪贴板类型是自定义类型（不复用标准文本/图片类型）",
      ShareLinkCodec.pasteboardType.hasPrefix("com.qingliao.app2.") && !ShareLinkCodec.pasteboardType.hasPrefix("public."))

print("共 \(checks) 条断言，失败 \(failures) 条")
if failures > 0 { exit(1) }
print("✅ ShareLinkCodec 全部通过")
