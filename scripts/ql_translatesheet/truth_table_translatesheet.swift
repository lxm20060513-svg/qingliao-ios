import Foundation

// MARK: - v3.9.82 译文弹窗 真值表（源码形态，本机可跑）
//
// 用户 2026-09-25 拍板：「这个卡片改弹窗吧，跟 AI 速记弹窗一致」。
// 参照物 = `QuickCaptureSheet`（Features/OrbQuickMenu.swift）—— 从「浮在球上方的译文卡」改成弹窗。
//
// 本表钉九件事（都是「本机一眼能查、真机上才看得出来」的形态）：
//   ① 形态逐条对齐参照物：档位 medium+large / 边距 Spacing.section / 内容贴顶 / 标题 headline 粗体 /
//      正文卡走 overlayGlassCard(Radius.card，与速记输入卡同档) / 背景不覆盖（交给系统玻璃底）；
//   ② 四颗动作都在（关闭 / 复制 / 换一张 / 发给 AI），复制带 1.6s 即时反馈；
//   ③ **识别浮层里不许再有译文卡**：translatedCard / copyTranslation / copiedTranslation 全清零，
//      旧卡那套限高常量 translationMaxHeight 也不许带进弹窗（防两套形态并存）；
//   ④ 译文只有一条出口：浮层 onTranslated → 宿主 `.sheet(item:)` → TranslateSheet；
//   ⑤ 宿主的 sheet 必须带 onDismiss 复位（本仓踩过：present 被挡掉后 item 一直非 nil → 再也弹不出来）；
//   ⑥ 「发给 AI」仍是**唯一通道**：宿主 askAI 是唯一出口，.qingliaoTaskSend 只 post 一次，
//      弹窗自己不 post（否则以后改通道要改两处）；
//   ⑦ 弹窗里的「换一张」要能接回翻译模式（startInTranslateMode），且事后必须复位
//      （否则下一次拍照莫名出译文）；
//   ⑧ 速记那条路没被误伤（QuickCaptureSheet 仍在宿主上挂着）；
//   ⑨ TranslateSheet.swift 落在 project.yml 的 sources（`qingliao` 目录）覆盖范围内。

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它（注释里讲清「不许出现什么」时，否则会被自己染红）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
/// 去掉全部空白 —— 顺序/相邻类断言不受缩进漂移影响
func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }

let sheet = src("qingliao/Features/TranslateSheet.swift")
let overlay = src("qingliao/Features/OrbIdentifyOverlay.swift")
let dock = src("qingliao/Features/DockTabView.swift")
let orbMenu = src("qingliao/Features/OrbQuickMenu.swift")
let proj = src("project.yml")

// MARK: 0. 文件到位
check("① 新文件 Features/TranslateSheet.swift 存在且非空", sheet.count > 500)
check("① 三个老文件仍可读（路径没挪）", !overlay.isEmpty && !dock.isEmpty && !orbMenu.isEmpty)

// MARK: 1. 参照物还在 + 形态逐条对齐
check("① 参照物 QuickCaptureSheet 仍在 OrbQuickMenu.swift", orbMenu.contains("struct QuickCaptureSheet"))
check("① 档位与参照物同档 .presentationDetents([.medium, .large])",
      flat(sheet).contains(".presentationDetents([.medium,.large])"))
check("① 参照物自己也是 medium+large（没被顺手改掉）",
      flat(orbMenu).contains(".presentationDetents([.medium,.large])"))
check("① 边距口径 .padding(Spacing.section)", flat(sheet).contains(".padding(Spacing.section)"))
check("① 内容贴顶 alignment: .top", flat(sheet).contains("alignment:.top)"))
check("① 标题=Typography.headline 粗体", flat(sheet).contains("Typography.headline,weight:.bold)"))
check("① 标题图标走主色 Color.accentColor", sheet.contains("Color.accentColor"))
check("① 正文卡走玻璃口径 overlayGlassCard(cornerRadius: Radius.card)",
      flat(sheet).contains("overlayGlassCard(cornerRadius:Radius.card)"))
check("① 正文卡圆角与速记输入卡同档（参照物也是 Radius.card）",
      flat(orbMenu).contains("overlayGlassCard(cornerRadius:Radius.card)"))
check("① 背景**不覆盖**：交给系统玻璃底（不许出现 presentationBackground）",
      !stripCommentLines(sheet).contains("presentationBackground"))
check("① 原文留 2 行小字（只有译文用户没法验）", flat(sheet).contains(".lineLimit(2)"))
check("① 译文区吃掉中间全部高度 .frame(maxHeight: .infinity)",
      flat(sheet).contains(".frame(maxHeight:.infinity)"))

// MARK: 2. 四颗动作 + 复制反馈
check("② 四颗动作齐：关闭/复制/换一张/发给 AI",
      ["\"关闭\"", "已复制", "\"换一张\"", "\"发给 AI\""].allSatisfy { sheet.contains($0) })
check("② 复制即时反馈 1.6s 后收回（不留假的「已复制」）", stripCommentLines(sheet).contains("seconds(1.6)"))
check("② 复制写剪贴板 UIPasteboard", sheet.contains("UIPasteboard.general.string"))
check("② 复制是主操作（accent 胶囊）", flat(sheet).contains("pill(.primary,tone:.accent)"))
check("② 弹窗自己不 post 通知（发给 AI 由宿主单通道发）",
      !stripCommentLines(sheet).contains("qingliaoTaskSend"))

// MARK: 3. 识别浮层里不许再有译文卡
let overlayCode = stripCommentLines(overlay)
check("③ 浮层里 translatedCard 已清零", !overlayCode.contains("translatedCard"))
check("③ 浮层里 copyTranslation 已清零", !overlayCode.contains("copyTranslation"))
check("③ 浮层里 copiedTranslation 已清零", !overlayCode.contains("copiedTranslation"))
check("③ 浮层里旧限高常量 translationMaxHeight 已清零", !overlayCode.contains("translationMaxHeight"))
check("③ 浮层 Phase 里 .translated 已删（本层不再有译文态）", !overlayCode.contains(".translated("))
check("③ 弹窗里也不许带旧限高形态", !stripCommentLines(sheet).contains("translationMaxHeight"))

// MARK: 4. 译文只有一条出口
check("④ 浮层新增 onTranslated 回调", overlay.contains("onTranslated"))
check("④ 浮层成功路径回宿主（onTranslated(source, …)）", overlayCode.contains("onTranslated(source"))
check("④ 宿主挂在 .sheet(item: $translateResult) 上", flat(dock).contains(".sheet(item:$translateResult"))
check("④ 宿主用 TranslateSheet(result: r, …)", flat(dock).contains("TranslateSheet(result:r,"))
check("④ 数据模型 TranslateResult 是 Identifiable（sheet(item:) 前提）",
      sheet.contains("struct TranslateResult: Identifiable"))
check("④ 弹窗档位只在 sheet 里写一次（宿主不重复设档）", !dock.contains("presentationDetents"))

// MARK: 5. onDismiss 复位（本仓踩过的坑）
check("⑤ 宿主 sheet 带 onDismiss 复位", flat(dock).contains("onDismiss:{translateResult=nil}"))
// v3.9.82：合法复位点**恰好两处** —— ① onDismiss（present 被挡掉后 item 不会一直非 nil，与速记同款）；
// ② handleOrbAction 的统一收口（桌面快捷方式是绕过菜单的第二入口，进分支前必须收干净，否则译文 sheet 会压住
// 新开的识别浮层 / 与语音全屏 cover 互顶）。既不许少（漏掉 ① 会滞留、漏掉 ② 会「点了没反应」），也不许多
// （散落第三处复位 = 任何一次外部复位都可能掐掉正在呈现的弹窗，必查）。
check("⑤ 复位恰两处：onDismiss + handleOrbAction 收口",
      flat(dock).components(separatedBy: "translateResult=nil").count - 1 == 2)

// MARK: 6. 「发给 AI」单通道
check("⑥ 宿主有唯一出口 private func askAI(", dock.contains("private func askAI("))
// 只在**代码行**里数（注释里讲清「复用既有通道」会带上这个名字）
check("⑥ .qingliaoTaskSend 只 post 一次",
      flat(stripCommentLines(dock)).components(separatedBy: ".qingliaoTaskSend").count - 1 == 1)
check("⑥ 浮层调用点走 askAI（不再内联自己 post）", flat(dock).contains("onAskAI:{askAI($0)}"))
check("⑥ 弹窗的「发给 AI」也走同一出口", flat(dock).contains("onAskAI:{askAI($0)},") || flat(dock).contains("onAskAI:{askAI($0)},onRetry"))
check("⑥ askAI 里保留 0.35s 切页闸", dock.contains("seconds(0.35)"))

// MARK: 7. 「换一张」接回翻译模式 + 事后复位
check("⑦ 浮层新增 startInTranslateMode 参数", overlay.contains("startInTranslateMode"))
check("⑦ 浮层 onAppear 用 startInTranslateMode 起手（不再写死 false）",
      flat(overlayCode).contains("translateMode=startInTranslateMode"))
check("⑦ 宿主在「换一张」时置真并重开浮层",
      flat(dock).contains("identifyStartTranslate=true") && flat(dock).contains("showIdentify=true"))
check("⑦ 浮层调用点透传 startInTranslateMode", flat(dock).contains("startInTranslateMode:identifyStartTranslate"))
check("⑦ 事后复位 ≥2 处（onTranslated / onClose / askAI 都要清）",
      flat(dock).components(separatedBy: "identifyStartTranslate=false").count - 1 >= 2)

// MARK: 8. 速记没被误伤 + ⑨ 入库路径
check("⑧ 速记弹窗仍在宿主上挂着（QuickCaptureSheet(mode: mode)）",
      flat(dock).contains("QuickCaptureSheet(mode:mode)"))
check("⑧ 速记 onDismiss 复位没被动过", flat(dock).contains("onDismiss:{quickCapture=nil}"))
check("⑨ TranslateSheet.swift 落在 project.yml sources 覆盖的 qingliao 目录",
      proj.contains("- qingliao") && sheet.contains("struct TranslateSheet: View"))

// MARK: 汇总
print("译文弹窗真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
