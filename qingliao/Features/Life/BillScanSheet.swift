import SwiftUI
import PhotosUI

// MARK: - v4.0.22 候选池⑪ App 入口：拍照/选图 → 后端识别 → 确认 → 入账
//
// 定位：账本页那颗「扫账单」（生活页记录区页级标题行）。
// 为什么识别与入账分两步（后端刻意不写账本）：识别错的金额自动进账本 = 用户看到假数字；
// 后端只做「图 → 结构化字段」（intent_api.extract_bill），写入走 App 的
// RecordStore.addDetailed —— 与聊天页一句话记账 / 生活页手写 / 动作条同一个落库口径。
//
// 与「拍照识别」浮层（OrbIdentifyOverlay）的关系：那条链路是「图 → 一段回答」，走 /api/stream/chat；
// 本条是「图 → 结构化账单字段」，走 /api/agent/intent/bill。取图/压缩/兜底三件事照抄它（同一档压缩判据、
// 同一套「没有相机就走相册」的闸），不新造第二份 —— 但回答去向完全不同，别合并。

struct BillScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth

    @State private var phase: Phase = .pick
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var shot: UIImage?
    @State private var draft: BillDraft?
    @State private var draftTitle = ""
    @State private var draftAmount = ""
    @State private var draftCategory = BillScanKit.categories.first ?? "餐饮"
    @State private var saving = false
    /// 保存后的一句实话（如「这条刚记过」）—— 连点去重命中时不能假装记上了
    @State private var saveNote: String?

    private enum Phase: Equatable {
        case pick                // 还没选图
        case working             // 识别中
        case ready               // 有草稿，等用户确认
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    switch phase {
                    case .pick: pickPane
                    case .working: workingPane
                    case .ready: readyPane
                    case .failed(let message): failedPane(message)
                    }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xxl)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("扫账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    recognize(image)
                } else {
                    phase = .failed("这张图读不出来，换一张试试")
                    Haptics.error()
                }
                photoItem = nil   // 复位：不然连选同一张不会再触发 onChange
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // 相机内容必须 ignoresSafeArea —— 只换 fullScreenCover 容器不够，内容默认仍受
            // 安全区约束 → 顶部露宿主黑边（v3.9.75 用户实测报过，ChatView/识别浮层同款写法）
            CameraPicker { image in recognize(image) }
                .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 选图（第一屏）

    private var pickPane: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("拍一张账单，自动认金额")
                .font(.system(size: Typography.title, weight: .semibold))
            Text("外卖/超市小票、支付账单截图都行。认出来的金额先给你过一眼，确认后才记进账本。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.md) {
                Button { openCameraOrAlbum() } label: {
                    Text("拍照").pill(.primary, tone: .accent)
                }
                .buttonStyle(PressStyle())
                Button { showPhotoPicker = true } label: {
                    Text("从相册选").pill(.primary, tone: .neutral)
                }
                .buttonStyle(PressStyle())
            }
            .padding(.top, Spacing.xs)
        }
        .padding(.top, Spacing.xxl)
    }

    // MARK: 识别中

    private var workingPane: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("正在读金额、日期、分类…")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.xxl)
    }

    // MARK: 待确认（识别成功）

    private var readyPane: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            thumb
            if let draft, BillScanKit.needsReview(draft) {
                Label("识别把握不大，请核对金额", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.orange)
            }
            amountField
            titleField
            categoryPicker
            if let date = draft?.date, !date.isEmpty {
                Text("消费日期 \(date)")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            actionRow
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if let shot {
            Image(uiImage: shot)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("金额（元）")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            TextField("没认出来就手填", text: $draftAmount)
                .font(.system(size: Typography.title, weight: .semibold))
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("事项")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            TextField("如 便利店购物", text: $draftTitle)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("分类")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BillScanKit.categories, id: \.self) { c in
                        Button {
                            draftCategory = c
                            Haptics.selection()
                        } label: {
                            Text(c).pill(.topBar, tone: draftCategory == c ? .accent : .neutral)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: Spacing.xs) {
            // 连点去重命中时的那句实话（不假装记上了）
            if let saveNote {
                Text(saveNote)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Spacing.md) {
                Button { retake() } label: {
                    Text("重选").pill(.primary, tone: .neutral)
                }
                .buttonStyle(PressStyle())
                Button { save() } label: {
                    Text(saving ? "记账中…" : "记入账本").pill(.primary, tone: .accent)
                }
                .buttonStyle(PressStyle())
                .disabled(!canSave || saving)
                .opacity(canSave && !saving ? 1 : 0.5)
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: 失败

    private func failedPane(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.md) {
                if shot != nil {
                    Button { retry() } label: {
                        Text("重试").pill(.primary, tone: .accent)
                    }
                    .buttonStyle(PressStyle())
                }
                Button { retake() } label: {
                    Text("重选").pill(.primary, tone: .neutral)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.top, Spacing.xxl)
    }

    // MARK: 动作

    /// 无摄像头设备（模拟器 / 部分 iPad）走相册 —— 与 ChatView v3.0.86、识别浮层同一道闸，
    /// 别在两处写出不同判据（直接 present .camera 会抛 NSInvalidArgumentException）。
    private func openCameraOrAlbum() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showPhotoPicker = true
        }
    }

    private func retake() {
        shot = nil
        draft = nil
        draftTitle = ""
        draftAmount = ""
        saving = false
        saveNote = nil
        phase = .pick
        Haptics.tap()
    }

    private func retry() {
        guard let image = shot else { retake(); return }
        saveNote = nil
        recognize(image)
    }

    private func recognize(_ image: UIImage) {
        guard phase != .working else { return }   // 防连点：识别中再选一张不叠第二次
        shot = image
        phase = .working
        Haptics.tap()
        Task { @MainActor in
            let dataURL = await ImageDownscale.dataURL(from: image,
                                                       maxSide: ImageDownscale.currentMaxSide,
                                                       quality: ImageDownscale.currentQuality)
            guard let dataURL, let b64 = BillScanKit.base64(from: dataURL) else {
                phase = .failed("图片处理失败，换一张试试")
                Haptics.error()
                return
            }
            do {
                let json = try await auth.json("/api/agent/intent/bill", method: "POST",
                                               body: ["image_b64": b64], timeout: 90)
                guard let found = BillScanKit.draft(from: json) else {
                    phase = .failed(BillScanKit.failText(from: json))
                    Haptics.error()
                    return
                }
                draft = found
                draftTitle = BillScanKit.title(found)
                draftAmount = found.amount.map { String(format: "%.2f", $0) } ?? ""
                draftCategory = found.category
                phase = .ready
                Haptics.success()
            } catch {
                phase = .failed("识别失败：\(error.localizedDescription)")
                Haptics.error()
            }
        }
    }

    /// 手填/改正后的金额（"1,234.5" 这种带千分位逗号的也认）
    ///
    /// ⚠️ 必须挡 `isFinite`：`Double("inf")` / `Double("Infinity")` / `Double("1e400")`
    /// 在 Swift 里返回的是 **inf 而不是 nil**（长按粘贴 / iPad 外接键盘能输进来），
    /// 只判 `> 0` 就会把 inf 写进账本 → 「本月合计」与 CSV 导出全变 inf。
    /// 上限对齐后端 `_norm_bill`（> 1 亿当没认出来）—— 两头口径必须一致。
    private var parsedAmount: Double? {
        let raw = draftAmount.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value.isFinite, value > 0, value <= 100_000_000 else { return nil }
        return BillScanKit.money(value)
    }

    private var canSave: Bool { parsedAmount != nil }

    private func save() {
        guard !saving, let value = parsedAmount else { Haptics.error(); return }
        saving = true
        saveNote = nil
        let typed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = RecordStore.shared.addDetailed(
            kind: "amount",
            title: typed.isEmpty ? draftCategory : typed,
            amount: value,
            unit: "元",
            note: draft.map(BillScanKit.note) ?? "扫账单",
            category: draftCategory,
            source: BillDraft.source)
        guard let added else {
            Haptics.error()      // 标题空 = addDetailed 拒收（理论上到不了：上面已回退分类名）
            saving = false
            return
        }
        // `inserted == false` = 2 秒内同额同摘要命中「连点去重」，返回的是**已存在**那条。
        // 不能当新建给成功反馈（否则用户以为记了两笔），也不 repeat 记账 —— 给一句实话，让他自己判。
        guard added.inserted else {
            Haptics.tap()
            saveNote = "这条刚记过（2 秒内同额同摘要），没有重复记账"
            saving = false
            return
        }
        Haptics.success()
        dismiss()
    }
}
