// MARK: - v3.9.110 AI 中途追问「问题卡」
//
// 由头（用户 2026-09 从三方案对比稿拍板）：AI 干长任务时中途需要用户确认一个选择，
// 原来只能发一条推送消息、用户不知道怎么回。现在后端 ask_user.py 推 task_type=question
// 的条目 → App 注入会话成一张**可作答卡**。
//
// 用户拍板的三条口径（**改动前先读这三条，别按自己的偏好改**）：
//   1. **方案 A「会话内联」**——卡落在对话流里（AI 侧、头像位置与普通回复一致），
//      答完原地变「已回答」并接上 AI 的后续动作；不做顶部横幅、不做任务中心卡。
//   2. **快捷选项 + 自由输入都要**——后端给了选项就渲染成胶囊（点一下即答），
//      同时始终保留输入框（选项之外还能自己打字）。
//   3. **卡一直留着**——不主动收起、不超时消失；用户任何时候回 App 都能作答。
//      （App 侧对应纪律：question 类**不 markDone**，见 InboxStore.consumeOne/answerQuestion）
//
// 视觉：卡底走全站唯一真源 `.pastelCard()`。v4.0.71：随 v4.0.67「全站淡彩迁移」对齐 ——
// 同页 AI 气泡早已是淡彩，这张卡当初漏迁，玻璃压在环境渐变页底上会发灰（那轮迁移的定性）。
// 依旧不自己拼 RoundedRectangle + fill + stroke。
//
// v4.0.71「卡里带图 + 刷新」（用户 2026-10-07 从三方案对比稿拍板**方案 A「整宽画面 + 工具条」**）：
//   · 题干里独立成行的 `MEDIA:<容器路径>` → 卡内渲染「浏览器画面」块（工具条 + 整宽图 + 刷新胶囊）；
//     图走**免鉴权媒体端点**（与 AI 发图完全同一条路，后端零改动），路径行本身不进正文展示。
//   · 刷新 = **端上就地换帧**，不再问 AI 一轮：地址加 `&r=N` 绕开 N 端图片缓存重拉同一路径，
//     Hermes 侧有常驻帧发布器每 2 秒把当前浏览器画面覆盖写入该路径 → 点一下就是「最新一帧」。
//   · 点图开全屏（复用 ImageViewer：原生捏合/双击缩放 + 存相册）—— 二维码/验证码在手机上才看得清。
import SwiftUI
import UIKit   // 长按卡头「复制题干」用 UIPasteboard（与仓内其它复制入口同款）

struct ChatQuestionCard: View {
    let message: ChatMessage
    /// 作答回调（传用户答案原文）。**nil = 只读渲染**（会话导出/预览等无宿主回调的路径自动退回只读）。
    var onAnswer: ((String) -> Void)? = nil
    /// 删除该条消息（长按**卡头**出的菜单项）。nil = 不提供删除入口（只读路径）。
    /// ⚠️ 菜单刻意只挂**卡头**、不挂整卡：卡里有 TextField，整卡级 contextMenu 会抢掉输入框的
    ///    长按选中/粘贴手势（同 ChatMessageBubble 里「气泡级 contextMenu 抢 UITextView 手势」那处实测 bug）。
    var onDelete: (() -> Void)? = nil

    private enum Layout {
        /// 输入框高度（输入类控件走 Radius.field 口径，高取 34 = 单行正文 17.9 + 上下各 8）
        static let fieldHeight: CGFloat = 34
        /// 头部圆形图标边长
        static let iconSize: CGFloat = 22
    }

    /// 服务器地址：与 ChatMessageBubble 用**同一个 AppStorage key**（AuthStore 写、两处读）。
    /// v4.0.71 卡里带图要靠它拼免鉴权媒体 URL。
    @AppStorage("qingliao_server") private var serverURL = ""
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    /// v4.0.71：刷新计数 —— 既当 cache-buster（0 = 首帧不带参），又给图片视图换 identity 逼它重拉
    @State private var screenNonce = 0
    /// v4.0.71：已载入的画面（点图开全屏要把它喂给 ImageViewer —— 它吃的是 [UIImage]）
    @State private var screenImage: UIImage?
    @State private var showScreen = false
    @FocusState private var focused: Bool

    /// 已答态判据：卡里存到了用户答案
    private var answered: Bool { !(message.questionAnswer ?? "").isEmpty }

    /// 题干 / 选项。题干每帧从 content 现拆（短文本 O(n) 可忽略）；
    /// 选项优先用落库的 questionOptions（解析口径变更时不至于两处不一致）。
    private var questionBody: String { ChatMessage.splitQuestion(message.content).body }
    private var options: [String] {
        if let o = message.questionOptions, !o.isEmpty { return o }
        return ChatMessage.splitQuestion(message.content).options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHead
            Text(bodyText)
                .font(.system(size: Typography.body))
                .foregroundStyle(answered ? Color.secondary : Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)   // 题干长度不可控，别被压成一行截断
            // v4.0.71：题干带了 MEDIA 行 → 卡内嵌「浏览器画面」（待答/已答都留着：答完还能刷新看 AI 干到哪步）
            if let screenURL { screenBlock(screenURL) }
            if answered {
                answerBlock
            } else if onAnswer != nil {
                // 无回调（会话导出 / 预览等路径）→ 只读渲染题干，不画输入控件：
                // 画了却点不动等于「点了没反应」，比不画更差。
                if let err = message.questionError { answerFailedHint(err) }
                answerInputs
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v4.0.68 全站口径：彩底上的卡一律 pastelCard（本卡 v4.0.71 补迁）
        .pastelCard()
        // v4.0.71：点图开全屏（与 ChatView 的图片出口同一套 View，可缩放/存相册）
        .fullScreenCover(isPresented: $showScreen) {
            if let img = screenImage { ImageViewer(images: [img], index: 0) }
        }
    }

    // MARK: - v4.0.71 卡里带图（浏览器画面 + 刷新）

    /// 展示/复制用正文：已摘掉 MEDIA 行（容器路径不能当正文念给用户看）
    private var bodyText: String { Self.stripScreenLine(questionBody).text }

    /// 要嵌进卡里的画面路径 = 题干里独立成行的 `MEDIA:<容器路径>`
    private var screenPath: String? { Self.stripScreenLine(questionBody).path }

    /// 免鉴权媒体 URL；拿不到服务器地址时 nil → 卡照旧只渲染文字（不画半个空框）
    private var screenURL: String? {
        guard let p = screenPath, !serverURL.isEmpty else { return nil }
        return Self.mediaURL(p, serverURL: serverURL)
    }

    /// 本次取图地址：刷新后加 `&r=N` 绕开图片缓存（后端只读 p，多余 query 忽略不计）
    private var screenFetchURL: String? {
        guard let u = screenURL else { return nil }
        return screenNonce == 0 ? u : u + "&r=\(screenNonce)"
    }

    @ViewBuilder
    private func screenBlock(_ url: String) -> some View {
        // v4.0.71：本轮取图的轮次。回吐要认这一轮——上一轮在途的加载（loadRemote 的降级路径走
        //   Task.detached）可能在新实例之后才回调，不认轮次就会把旧帧盖到新帧上（审查抓到的竞态）。
        let nonce = screenNonce
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("实时画面 · 浏览器")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    refreshScreen()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                        Text("刷新")
                            .font(.system(size: Typography.tiny))
                    }
                    .pill(.page, tone: .accent)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("刷新浏览器画面")
            }
            // v4.0.71：这里**不传** displayWidthPT —— 它只服务 `data:image/` 分支（本卡 url 恒为
            //   媒体端点，永远命中不了），传个 345 等于在「尺寸唯一出口」之外再硬编一份机型相关宽度。
            //   卡内尺寸只由 fillAspect（铺满可用宽 + 定比例）一处决定。
            AIImageView(url: screenFetchURL ?? url,
                        fillAspect: 1.6) { img in
                guard nonce == screenNonce else { return }   // 上一轮的表：晚到也不认
                screenImage = img
            }
            // 刷新 = 换 identity 重拉（@State 归零 → 骨架 → 新帧淡入），不是把旧图原地留着骗人
            .id(screenNonce)
            .onTapGesture {
                guard screenImage != nil else { return }   // 还没加载出来就点：不响应，好过弹个空白全屏
                showScreen = true
            }
            .accessibilityLabel("浏览器画面，点开可全屏放大")
        }
    }

    private func refreshScreen() {
        Haptics.tap()
        // v4.0.71：刷新要**连旧帧一起清**。只换 identity 的话：新帧在途/失败时卡面显示
        //   「图片加载失败」占位，而 `screenImage` 里仍留着上一帧 → 点图会弹出**旧画面**（审查抓到）。
        screenImage = nil
        screenNonce += 1
    }

    /// 摘出题干里**独立成行**的 `MEDIA:<路径>`（只认第一条，多张只嵌第一张）。
    /// 「独立成行」是刻意的：AI 正文顺嘴提一句 MEDIA: 不该被吃掉（口径同 ChatMessageBubble 的 MEDIA 协议）。
    static func stripScreenLine(_ body: String) -> (text: String, path: String?) {
        var path: String?
        let kept = body.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("MEDIA:") else { return true }
            let p = String(t.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return true }
            if path == nil { path = p }
            return false
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    /// 容器路径 → 免鉴权媒体 URL。**口径与 ChatMessageBubble.expandMediaMarks 逐字一致**
    /// （base64url：+→- /→_ 去 =；服务器端把 /opt/data 映射到宿主 hermes-data）。
    /// 两处一旦不一致：同一张图 AI 发得出去、卡里却 404 —— 真值表钉了这条双写一致。
    static func mediaURL(_ path: String, serverURL: String) -> String? {
        guard !path.isEmpty, !serverURL.isEmpty else { return nil }
        let b64 = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(serverURL)/api/stream/media?p=\(b64)"
    }

    // MARK: - 头部

    private var cardHead: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle().fill(headTint.opacity(Tint.subtle))
                Circle().strokeBorder(headTint.opacity(0.26), lineWidth: 0.8)
                Image(systemName: headIcon)
                    .font(.system(size: Typography.caption, weight: .bold))
                    .foregroundStyle(headTint)
            }
            .frame(width: Layout.iconSize, height: Layout.iconSize)

            Text(headTitle)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(headTint)

            Spacer(minLength: 0)

            if let ts = message.timestamp {
                Text(Self.relativeTime(Int(ts / 1000)))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { questionCardMenu }
    }

    /// 长按卡头的菜单：只给「复制题干」与「删除」。
    /// ⚠️ 刻意**不是**整份 cardMenu（那份含「引用/分享/撤回/重新生成」等对问题卡无意义的项）；
    ///    但总得有条清理路径：AI 已超时退出的追问卡按口径「一直留着」，没删除入口就永远删不掉。
    @ViewBuilder
    private var questionCardMenu: some View {
        Button {
            UIPasteboard.general.string = bodyText
        } label: {
            Label("复制题干", systemImage: "doc.on.doc")
        }
        if let onDelete {
            Button(role: .destructive) { onDelete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// v4.0.46 **四态**口径（改了这里要同步真值表 scripts/ql_ask_card/truth_table_ask_card.swift）：
    ///   待答 → 「AI 需要你确认」 | 已提交未确认 → 「已提交 · 等 AI 确认」
    ///   AI 已取走 → 「AI 已收到」   | 条目过期清理 → 「卡片已过期」（不是 AI 收的，别报假回执）
    private var headTitle: String {
        if !answered { return "AI 需要你确认" }
        if message.questionAcked { return "AI 已收到" }
        if message.questionExpired { return "卡片已过期" }
        return "已提交 · 等 AI 确认"
    }

    private var headIcon: String {
        if !answered { return "questionmark" }
        if message.questionAcked { return "checkmark" }
        if message.questionExpired { return "exclamationmark" }
        return "paperplane.fill"
    }

    private var headTint: Color {
        if !answered { return .orange }
        if message.questionAcked { return .green }
        if message.questionExpired { return .secondary }
        return .orange
    }

    /// v4.0.46：答案下方的回执行（用户报「选完卡之后给个回馈，不然不确定回复完成没」）——
    /// 「已提交」= 后端队列里还等着；「AI 已收到」= 真的送达了；「已过期」= 照实说没送到。
    private var receiptText: String {
        if message.questionAcked { return "AI 已收到，会接着按你的选择往下做" }
        if message.questionExpired { return "这卡已过期（AI 侧没等到答复），需要的话让 AI 重发一张" }
        return "已送出，等 AI 确认…"
    }

    private var receiptTint: Color {
        if message.questionAcked { return .green }
        if message.questionExpired { return .orange }
        return .secondary
    }

    /// 作答**没送到**：回退待答态的同时把原因说出来。
    /// ⚠️ 别静默停在「已回答」——用户以为 AI 收到了，而 AI 侧长轮询其实一直在等到超时。
    private func answerFailedHint(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.orange)
            Text("上次没送到：\(reason)。重新选一个或再打一次即可。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 待答：选项胶囊 + 自由输入

    @ViewBuilder
    private var answerInputs: some View {
        if !options.isEmpty {
            // 🚨 一排放不下就落竖排（ViewThatFits 两稿）——别用 fixedSize 硬撑：
            // 那会关掉 SwiftUI 最后的压缩兜底，超宽时整行溢出被两端裁掉（比换行更难查）。
            // 宽度账（390pt 屏）：气泡可用宽 = AdaptiveLayout.bubbleMaxWidth(竖屏) 369
            // − 卡内左右 padding 12×2 = 345pt；
            // 单颗胶囊 = 字数 ×15 + 左右 14×2，四颗 4 字 = 88×4 + 间隙 6×3 = 370 > 345 → 必落竖排。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { optionButtons }
                VStack(alignment: .leading, spacing: 6) { optionButtons }
            }
        }
        HStack(spacing: Spacing.md) {
            TextField("也可以直接打字回答…", text: $draft, axis: .vertical)
                .font(.system(size: Typography.subhead))
                .multilineTextAlignment(.leading)   // 显式钉左：TextField 默认对齐不保证
                .lineLimit(1...3)
                .focused($focused)
                .padding(.horizontal, Spacing.xl)
                .frame(minHeight: Layout.fieldHeight)
                .background(Color.secondary.opacity(Tint.faint),
                            in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
                )
                .submitLabel(.send)
                .onSubmit { submit(draft) }

            Button {
                submit(draft)
            } label: {
                Text("发送").pill(.primary, tone: .accent)
            }
            .buttonStyle(PressStyle())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .accessibilityLabel("发送回答")
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        ForEach(options, id: \.self) { opt in
            Button {
                submit(opt)
            } label: {
                // 选项 = 主操作（点一下 AI 就继续跑），走 primary 档；色调统一 accent。
                Text(opt).pill(.primary, tone: .accent)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("回答：\(opt)")
        }
    }

    // MARK: - 已答：答案留痕

    private var answerBlock: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2.5)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(message.questionAnswer ?? "")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // v4.0.46：回执行（「你」+ 送达到哪一步）——用户报「选完卡不确定回复完成没」
                HStack(spacing: Spacing.sm) {
                    Text("你")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                    Text(receiptText)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(receiptTint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.secondary.opacity(Tint.faint),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 提交

    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !answered, let onAnswer else { return }
        Haptics.success()
        focused = false
        draft = ""
        onAnswer(text)
    }

    /// 相对时间（卡头右上角）：只做「刚刚 / N 分钟前 / N 小时前 / N 天前」四档，
    /// 超过 7 天退回日期——不引第三方、不依赖会话列表那套 relativeTime（它带"昨天"等口语档，
    /// 与卡片这种短标签口径不同）。
    static func relativeTime(_ seconds: Int) -> String {
        let diff = Int(Date().timeIntervalSince1970) - seconds
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60) 分钟前" }
        if diff < 86400 { return "\(diff / 3600) 小时前" }
        if diff < 86400 * 7 { return "\(diff / 86400) 天前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
