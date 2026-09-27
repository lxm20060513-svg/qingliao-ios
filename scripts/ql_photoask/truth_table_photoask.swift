// MARK: - v4.0.x「拍照识别 · 就地看」真值表（纯口径 + 源护栏）
//
// 口径来源（用户 2026-09-27 拍板）：
//   「长按智慧球的拍照识别功能改成不发送当前对话框，直接在当页做」
//   三问确认：① 拍完显示**AI 看图回答**（内容与旧口径发给 AI 的逐字一致，只是就地显示，不进会话）
//             ② **不要**「发到会话」按钮（看完即走）
//             ③ 呈现形态 = **球上浮层卡**（与现有「AI 识别」同一形态：背景虚化 + 球心扫描环）
//                —— 用户先选过「全屏页」又当场改回本形态，所以本表钉的是浮层这条链：
//                宿主的照片进 `OrbIdentifyOverlay`（新增 photoAsk 三段），**不许再有第二个整屏页**。
//
// 旧口径（v3.9.93 ~ 改前，**已作废**）：相机拍完 → `ShareRouter.enqueue(sourceName: "拍照识别")` →
//   切聊天页 → 0.35s 闸 → post `.qingliaoShareIncoming` → ChatView.drainShareInbox 自动压图 sendCore
//   —— 也就是把「帮我看看这张照片」+ 图**发进当前会话**。
//
// 本表钉死的东西：
//   ① 提示词/超时/文案全在 `PhotoAskKit` 一处（不许第二处写死，否则两处措辞各自漂移）
//   ② 浮层三段齐全：askingPhoto / photoAnswer / photoFailed，且**失败可重试**（静默退回 = 用户以为
//      「点了没反应」，本仓明令禁止）；等回答时扫描环要继续转（否则像卡死）
//   ③ **不进会话**：这条链不碰 ShareRouter / SharedPayload / .qingliaoShareIncoming / ChatStore，
//      也没有「发到会话」按钮
//   ④ 图块仍只有**一个**构造点（复用 ImageBlocks，别在带图一问一答里另拼一份）
//   ⑤ 带图时模型取源走视觉档（CloudConfig.effectiveVisionModel）
//   ⑥ 宿主接线：`identifyPhoto` 是识别浮层的**载荷**（设/清成对，漏清 = 下次 AI 识别误用老照片）、
//      收口清单里清掉、拍完不切页、0.35s 闸仍在
//   ⑦ 重拍/换图走 openCameraOrAlbum（无相机设备 present .camera 会抛 NSInvalidArgumentException，本仓已踩）
//   ⑧ 防连点（等回答时再拍一张不叠第二次）+ 原图留在 lastImage 供「重试」
//   ⑨ 卡形走共享玻璃（overlayGlassCard + 浮层投影，不手搓 material）、长回答卡内滚动限高
//
// 用法（必须在仓库根跑，表内用相对路径读源）：
//   check_swift.sh 第 34 段（**唯一跑本表的入口**）—— 它把本表复制成 main.swift，再带上
//   `qingliao/Core/PhotoAskKit.swift` 一起编（多文件时 swiftc 只允许 main.swift 有顶层代码），
//   然后运行；`python3 /opt/data/scripts/ql.py test` 只扫 /opt/data/scripts/*/ 下的表，**不跑仓内 scripts/**。
// 为什么要带源一起编：提示词/超时/失败文案是**纯口径**，直接调生产代码比在表里镜像一份更不容易漂移。

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

/// 去掉整行注释后再做「不许出现 XX」这类否定断言 —— 否则注释里提到的历史写法会把护栏判红
/// （本仓口径：护栏要钉**真实产物**，注释不是产物）。
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 全 App 源（Core + Features + Theme 递归）拼一份 —— 用来数「图块构造点」这类全局性的东西
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
    return out
}


// MARK: 源

let dockSrc = src("Features/DockTabView.swift")
let overlaySrc = src("Features/OrbIdentifyOverlay.swift")   // v4.0.x：就地看这条 UI 就落在 AI 识别浮层里
let kitSrc = src("Core/PhotoAskKit.swift")
let blocksSrc = src("Core/ImageBlocks.swift")
let modelsSrc = src("Core/Models.swift")
let intentsSrc = src("Core/AppIntents.swift")
let downscaleSrc = src("Core/ImageDownscale.swift")
let allSrc = allAppSources()

/// 切片：`from` 之后到 `to` 之前（to 取不到时到文件尾）
func between(_ s: String, _ from: String, _ to: String) -> String {
    guard let a = s.range(of: from) else { return "" }
    let tail = String(s[a.upperBound...])
    guard let b = tail.range(of: to) else { return tail }
    return String(tail[..<b.lowerBound])
}

/// a 是否出现在 b 之前（查「先清后设」这类**顺序**断言）
func precedes(_ s: String, _ a: String, _ b: String) -> Bool {
    guard let ra = s.range(of: a), let rb = s.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

let overlayClean = stripCommentLines(overlaySrc)
let dockClean = stripCommentLines(dockSrc)
let camSlice = between(dockClean, "private func handleCameraShot(", "private func dispatchQuickAction")
// ⚠️ 锚点必须取**代码行**：切片前源被 stripCommentLines 去了整行注释，拿 "// MARK: ..." 当锚点会切出空串
//   （切空了下面这组断言就全变「空真」，护栏静默失效 —— 本仓踩过这个坑）。
let photoRegion = between(overlayClean, "private var askingPhotoCard", "private func openCameraOrAlbum")
let askSlice = between(overlayClean, "private func askPhoto(", "private func openCameraOrAlbum")

check("源可读（读不到时下面全是空真）",
      !overlaySrc.isEmpty && !kitSrc.isEmpty && !blocksSrc.isEmpty && !intentsSrc.isEmpty
      && !dockSrc.isEmpty && !allSrc.isEmpty)
check("浮层里「拍照识别」那段切片取到（切片空了下面几条就是空真）",
      !photoRegion.isEmpty && !askSlice.isEmpty)

// MARK: ① 单一真源：提示词 / 超时 / 文案只在 PhotoAskKit 一处

check("PhotoAskKit 是提示词的唯一定义处（提示词逐字 = 旧口径那句，用户要的是同一份内容）",
      PhotoAskKit.prompt == "帮我看看这张照片")
check("提示词字符串全 App 只出现 1 次（写死第二处 = 两处措辞各自漂移；只数代码、不数注释）",
      stripCommentLines(allSrc).components(separatedBy: "帮我看看这张照片").count - 1 == 1
      && kitSrc.contains("帮我看看这张照片"))
check("超时 = 120s（与 QingliaoIntentClient.oneShot 默认同源：后端要跑 Hermes 工具循环，给小了长回答被掐断）",
      PhotoAskKit.timeout == 120)
check("这条链真的在用这套口径（PhotoAskKit.prompt / .timeout 都被引用，不是写了没用）",
      askSlice.contains("PhotoAskKit.prompt") && askSlice.contains("PhotoAskKit.timeout"))

// MARK: ② 浮层三段齐全 + 失败可重试 + 忙碌态

check("等待态文案非空（拿到回答前要看得出来在跑）",
      !PhotoAskKit.waitingTitle.isEmpty && !PhotoAskKit.waitingDetail.isEmpty)
check("失败态标题非空（失败必须出声）", !PhotoAskKit.failureTitle.isEmpty)
// 口径（v4.0.x 审查修正）：后端 200 但正文为空**不在这里兜底** —— `oneShot` 自己先抛
// 「轻聊没有返回内容」，照片链落到 catch 显示 `failureDetail(error)`（真因）。原先那条「空回答文案」
// 断言是**空真**（分支不可达），已换成下面两条真口径。
check("空正文由 oneShot 抛错（不在浮层里再造不可达分支）",
      stripCommentLines(intentsSrc).contains("轻聊没有返回内容"))
check("照片链失败态带真因（failureDetail(error)）",
      overlayClean.contains("PhotoAskKit.failureDetail(error)"))
check("浮层三段齐全：askingPhoto / photoAnswer / photoFailed",
      overlayClean.contains("case askingPhoto") && overlayClean.contains("case photoAnswer(")
      && overlayClean.contains("case photoFailed("))
check("三段都接上了卡（写了枚举不接卡 = 空白浮层）",
      overlayClean.contains("case .askingPhoto:") && overlayClean.contains("case .photoAnswer(let text):")
      && overlayClean.contains("case .photoFailed(let detail):"))
check("等回答时扫描环继续转（isBusy 含 askingPhoto；不算忙 = 球心环停住像卡死）",
      between(overlayClean, "private var isBusy: Bool", "private func absoluteBallCenter")
        .contains("if case .askingPhoto = phase"))
check("失败态给的是「重试」（原图还在 → 直接重问，别只能关掉重来）",
      overlayClean.contains("private func photoFailedCard") && photoRegion.contains("askPhoto(img)"))

struct FakeError: LocalizedError {
    var errorDescription: String? { "HTTP 502: bad gateway" }
}
check("失败详情带真因（原样透出首行，不笼统说「失败」）",
      PhotoAskKit.failureDetail(FakeError()).contains("HTTP 502"))
check("失败详情单行且截断 ≤80 字（长错误不许把卡片撑爆）",
      PhotoAskKit.failureDetail(FakeError()).count <= 80
      && !PhotoAskKit.failureDetail(FakeError()).contains("\n"))
check("压图失败（error == nil）也有话说",
      !PhotoAskKit.failureDetail(nil).isEmpty && PhotoAskKit.failureDetail(nil) != PhotoAskKit.failureTitle)

// MARK: ③ 不进会话（本次口径变更的核心）

check("这条链不碰分享管道（旧口径：ShareRouter 入队发进当前会话）",
      !photoRegion.contains("ShareRouter") && !photoRegion.contains("SharedPayload")
      && !photoRegion.contains(".qingliaoShareIncoming"))
check("这条链不落 ChatStore（聊天记录里不许多出这一问一答）",
      !photoRegion.contains("ChatStore") && !photoRegion.contains("chat."))
check("这条链不发任何 .qingliaoTaskSend（那是「发进会话」的通道）",
      !photoRegion.contains(".qingliaoTaskSend"))
check("没有「发到会话」按钮（用户明确不要：看完即走）",
      !photoRegion.contains("发到会话") && !photoRegion.contains("发送"))
check("宿主切片也不再走分享管道 / 不切页（旧口径的 selected = .chat / skipBurstOnce 已撤）",
      !camSlice.isEmpty && !camSlice.contains("ShareRouter") && !camSlice.contains(".qingliaoShareIncoming")
      && !camSlice.contains("selected = .chat") && !camSlice.contains("skipBurstOnce()"))
check("宿主拍完把照片交给识别浮层就地看图（identifyPhoto = image + showIdentify = true）",
      camSlice.contains("identifyPhoto = image") && camSlice.contains("showIdentify = true"))

// MARK: ④ 图块构造仍是唯一入口（带图一问一答复用 ImageBlocks）

let blockLiteral = "blocks.append([\"type\": \"image_url\", \"image_url\": [\"url\": img]])"
check("全 App 图块构造点恰好 1 处（多一处 = 绕过「只准 base64」那条决策）",
      allSrc.components(separatedBy: blockLiteral).count - 1 == 1)
check("那 1 处就在 ImageBlocks（唯一入口）", blocksSrc.contains(blockLiteral))
check("Models.swift 已改为调 ImageBlocks（不再自己拼块）",
      modelsSrc.contains("ImageBlocks.content(text: content, img: img)")
      && !modelsSrc.contains(blockLiteral))
check("带图一问一答也用同一个入口（不在 AppIntents 里另拼一份）",
      intentsSrc.contains("ImageBlocks.content(text: prompt, img:") && !intentsSrc.contains(blockLiteral))

// MARK: ⑤ 带图 → 视觉档取源；图片只走 base64

let modelSlice = between(stripCommentLines(intentsSrc), "static func modelForImage", "static func inboxTexts")
check("带图时走视觉档（CloudConfig.effectiveVisionModel），没有视觉档才退 Agent / 主模型",
      modelSlice.contains("effectiveVisionModel()") && modelSlice.contains("UserDefaultsKey.agentModel")
      && modelSlice.contains("CloudConfig.mainModelAndProvider"))
check("文本一问一答只是带图那条的 nil 分支（不写第二份 payload 拼装）",
      intentsSrc.contains("oneShot(prompt, auth: auth, imageDataURL: nil, timeout: timeout)"))
check("发出去的图是 data URL（UIImage → ImageDownscale.dataURL(from:) + 网络分档）",
      askSlice.contains("ImageDownscale.dataURL(from:") && askSlice.contains("currentMaxSide")
      && downscaleSrc.contains("\"data:image/jpeg;base64,\""))

// MARK: ⑥ 宿主接线（位态 / 载荷 / 收口 / 呈现形态）

check("identifyPhoto 是宿主的位态（UIImage?，识别浮层的载荷）",
      dockSrc.contains("@State private var identifyPhoto: UIImage?"))
check("照片从宿主交进浮层（photoAskImage: identifyPhoto）",
      dockSrc.contains("photoAskImage: identifyPhoto"))
check("收口清单里清了它（漏一个 = 「点了没反应」/ 下次误用老照片）",
      between(dockSrc, "private func handleOrbAction", "switch action.id").contains("identifyPhoto = nil"))
check("浮层每条关闭路径都清载荷（onClose / onTranslated / 切页 / askAI —— 至少 4 处）",
      dockClean.components(separatedBy: "identifyPhoto = nil").count - 1 >= 4)
check("呈现形态与「AI 识别」同源：就地看这条 UI 在 OrbIdentifyOverlay 里",
      overlaySrc.contains("photoAskImage") && overlaySrc.contains("private func askPhoto("))
check("不再有第二个整屏看图页（两套形态并存正是这次返工的原因）",
      !FileManager.default.fileExists(atPath: root + "/Features/PhotoAskView.swift"))
check("相机 → 浮层之间有 0.35s 闸（同一宿主两种呈现同帧一收一开会被吞；照 askAI）",
      camSlice.contains("try? await Task.sleep(for: .seconds(0.35))"))

// MARK: ⑦ 相机闸 + 相册兜底

check("重拍 / 换图走 openCameraOrAlbum（无相机设备 present .camera 会抛 NSInvalidArgumentException）",
      photoRegion.contains("openCameraOrAlbum()")
      && overlayClean.contains("UIImagePickerController.isSourceTypeAvailable(.camera)"))

// MARK: ⑧ 防连点 + 原图留存（次序也是口径）

check("等回答时再拍一张不叠第二次（guard phase != .askingPhoto）",
      askSlice.contains("guard phase != .askingPhoto else { return }"))
check("每次提问先把原图存进 lastImage（失败「重试」要用）",
      askSlice.contains("lastImage = image"))
check("⚠️ 顺序：onAppear 里「清 lastImage」必须在「askPhoto(img)」之前（反过来把刚存的原图当场清掉，「重试」就没图了）",
      precedes(between(overlayClean, ".onAppear {", "if reduceMotion"), "lastImage = nil", "askPhoto(img)"))

// MARK: ⑨ 卡片走共享组件 / 尺寸走 Theme 令牌（不许手搓第二套）

check("三张卡走共享玻璃卡 overlayGlassCard（浮层里不手搓 material —— 本仓卡形与玻璃只许走共享组件）",
      photoRegion.contains(".overlayGlassCard()") && !photoRegion.contains(".ultraThinMaterial"))
check("卡形与「AI 识别」原来的卡同一套投影（scanningCard 同款，改一处全浮层一起变）",
      photoRegion.contains(".shadow(color: .black.opacity(0.12), radius: 12, y: 4)"))
check("长回答卡内滚动限高（不限高 = 长回答把球顶出屏幕）",
      photoRegion.contains(".frame(maxHeight: 240)"))
check("字号 / 间距全走 Theme 令牌（不写魔法数字，改令牌能全 App 一起变）",
      photoRegion.contains("Typography.") && photoRegion.contains("Spacing."))

print("拍照识别就地看真值表：" + String(passCount) + " 通过 / " + String(failCount) + " 失败")
if failCount > 0 { exit(1) }
