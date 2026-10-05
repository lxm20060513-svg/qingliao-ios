// v4.0.6：卡通宠物自定义页（设置页顶部大头像点进来）
//
// ⚠️ 三个必须记住的口径（都写在代码里，别凭记忆改）：
//  1. **单一真源**：`PetKeys.style / .face / .motion / .quirks` 四个 key 由本文件与 PetAvatar
//     共用同一组 `@AppStorage`，所以改完**不需要通知**——聊天页、消息头像、灵动岛自动跟着变。
//     这里绝不能自己 `UserDefaults.set` 另写一份，否则两处会漂。
//  2. **只管 idle**：表情设置只改「待机脸」（PetPainter 的 idle 分支）。
//     thinking（AI 在回）/ alert（后端离线）由宿主信号驱动，表情选到它们也没用 —— 那是语义通道，
//     宠物只是冗余表达，不能反过来说「AI 在回的时候它在笑」。
//  3. **从外观页搬来的**：形象三选一 + 动画三档原来在 `AppearanceSheet`（v3.9.78），
//     用户 2026-09-29 要求「外观里面的聊天页选项移动到卡通宠物头像的设置里」→ 那两段**搬到这里**，
//     外观页不再重复（两处都能改 = 迟早不一致）。搬家不是复制，故 AppearanceSheet 里那两段已删。
//
//  布局口径沿用「外观」页既有的三选一 idiom（缩略图 + 名称 + 选中蓝框），缩略图**按显示尺寸直接画**
// 并用 keepDetail 绕过 76pt 简化阈值 —— 绝不退回「96 画 + frame 52 塞」那套（v3.9.78 真机报修：
// frame 只改布局槽位、不缩放画面，96pt 画布会从 52pt 槽位四周各溢出 22pt，压住卡片边框和自家名字）。

import SwiftUI

struct PetStudioSheet: View {
    @Environment(\.dismiss) private var dismiss

    // v3.9.78：从 AppearanceSheet 搬来，与聊天页 PetAvatar 共用同一组 key
    @AppStorage(PetKeys.style) private var petStyle: PetStyle = .liquid
    @AppStorage(PetKeys.motion) private var petMotion: PetMotion = .system
    // v4.0.6：常态表情 + 行为动作勾选集
    @AppStorage(PetKeys.face) private var petFace: PetFace = .calm
    @AppStorage(PetKeys.quirks) private var quirksRaw: String = ""

    /// 大头像预览：点一下就摸一下（复用聊天页同一条互动口径：单击=抚摸，触感+表情）
    @State private var patTrigger = 0
    /// 动作预览：手动定格某个动作（nil = 不定格）
    @State private var previewQuirk: Quirk? = nil
    @State private var previewToken = 0

    /// 当前勾选的动作。⚠️ 与 PetAvatar 同款：key 缺失 = 全开（老用户升级后行为不变），
    /// key 存在但为空串 = 全关（用户主动关的）—— 两种语义必须分开，见 PetKeys.enabledQuirks。
    private var enabled: Set<Quirk> { PetKeys.enabledQuirks() }

    private var petName: String { petStyle.name }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 大头像预览
                Section {
                    VStack(spacing: Spacing.sm) {
                        PetAvatar(size: 120, state: .idle, patTrigger: patTrigger,
                                  keepDetail: true, quirkPreview: previewQuirk)
                            // 点哪都算「摸一下」：预览区不做别的交互，避免和下面列表抢手势
                            .contentShape(Rectangle())
                            .onTapGesture {
                                patTrigger += 1
                                Haptics.light()
                            }
                            .accessibilityLabel("\(petName) 预览")
                            .accessibilityHint("轻点摸一下")

                        Text(previewQuirk == nil
                             ? "\(petName) · \(petFace.name)脸"
                             : "正在预览：\(previewQuirk!.name)")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)

                        Text("轻点摸一下 · 聊天页顶部也是这只")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
                }

                // MARK: 形象（v3.9.78 搬来）
                Section("形象") {
                    HStack(spacing: 10) {
                        ForEach(PetStyle.allCases) { style in
                            petOption(style)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }

                // MARK: 常态表情（v4.0.6）
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(PetFace.allCases) { f in
                            faceOption(f)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    Text("表情只作用于「待机」：AI 正在回是思考脸、后端离线是提醒脸，这两种由真实状态决定，改不动（宠物是状态的冗余提示，不是唯一信息通道）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("常态表情")
                }

                // MARK: 行为动作（v4.0.6）
                Section {
                    VStack(spacing: 8) {
                        ForEach(Quirk.pool) { q in
                            quirkToggle(q)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    // v4.0.7：与「试一下」同款淡底胶囊（用户：胶囊风格没统一，别再混系统 .bordered）
                    HStack(spacing: 10) {
                        Button("全开") { setAllQuirks(true) }
                            .buttonStyle(.plain)
                            .font(.system(size: Typography.caption, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xxs)
                            .background(Capsule().fill(Color.accentColor.opacity(Tint.subtle)))
                        Button("全关") { setAllQuirks(false) }
                            .buttonStyle(.plain)
                            .font(.system(size: Typography.caption, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xxs)
                            .background(Capsule().fill(Color.accentColor.opacity(Tint.subtle)))
                    }
                    .padding(.vertical, Spacing.xxs)
                    Text("勾掉的动作待机时就不会再出现。动作在 2~5 秒随机触发一次，不影响思考/提醒脸的稳重感。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("行为动作")
                }

                // MARK: 动画档（v3.9.78 搬来）
                Section("动画") {
                    HStack(spacing: 10) {
                        ForEach(PetMotion.allCases) { motion in
                            motionOption(motion)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    Text("「减弱 / 关闭」可省电：关掉后形象静止显示，AI 正在回 / 后端离线仍由文案和角标承担。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI形象")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 形象选项（v3.9.78 搬来，注释同步搬）

    private func petOption(_ style: PetStyle) -> some View {
        let selected = petStyle == style
        return Button {
            petStyle = style
            // 换形象后立刻让它动一下，确认「联动」不是错觉
            patTrigger += 1
        } label: {
            VStack(spacing: Spacing.xs) {
                PetAvatar(size: 52, state: .idle, styleOverride: style,
                          faceOverride: petFace, keepDetail: true)
                Text(style.name)
                    .font(.system(size: Typography.caption, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("形象：\(style.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 表情选项（v4.0.6）

    private func faceOption(_ f: PetFace) -> some View {
        let selected = petFace == f
        return Button {
            petFace = f
            patTrigger += 1
        } label: {
            VStack(spacing: Spacing.xxs) {
                PetAvatar(size: 46, state: .idle, faceOverride: f, keepDetail: true)
                Text(f.name)
                    .font(.system(size: Typography.caption, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("表情：\(f.name)，\(f.blurb)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 行为动作行（v4.0.6）

    private func quirkToggle(_ q: Quirk) -> some View {
        let on = enabled.contains(q)
        return HStack(spacing: Spacing.sm) {
            // ⚠️ v4.0.6：点击区只包左侧「勾选圈 + 文字」，**不**给整行挂 onTapGesture ——
            // 整行挂手势会跟右边的「试一下」Button 抢点击（谁生效取决于 SwiftUI 的命中仲裁，不可预期）。
            // 右侧按钮自己管自己，行为干净。
            HStack(spacing: Spacing.sm) {
                // 勾选圈（自绘：不用系统 Toggle，行高更紧凑、点击区更大）
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(q.name)
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text(quirkHint(q))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(q) }
            Spacer(minLength: 0)
            // 「试一下」：把这个动作在上面的预览区定格演一遍（不改变勾选状态）
            Button {
                previewQuirk = q
                previewToken += 1
                Task {
                    try? await Task.sleep(for: .seconds(q.duration))
                    guard !Task.isCancelled else { return }
                    previewQuirk = nil
                }
            } label: {
                Text("试一下")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Capsule().fill(Color.accentColor.opacity(Tint.subtle)))
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("行为动作：\(q.name)，\(quirkHint(q))")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func quirkHint(_ q: Quirk) -> String {
        switch q {
        case .headTilt: return "歪头好奇一下"
        case .lookAround: return "左右张望"
        case .happyWiggle: return "开心扭扭身子"
        case .stretch: return "伸个懒腰"
        case .strollLeft: return "往左踱几步"
        case .strollRight: return "往右踱几步"
        // v4.0.58：腿部动作
        case .march: return "原地抬脚踏步"
        case .kick: return "抬腿踢一下"
        case .kickFlurry: return "左右腿连踢三下"
        // v4.0.27：手部动作组（加了 case 就必须在这里补，漏一个只有 CI Archive 抓得到）
        case .waveHello: return "挥手打个招呼"
        case .clap: return "鼓鼓掌"
        case .heartHands: return "比个心"
        case .cheer: return "举手欢呼"
        case .chinRest: return "托着腮发呆"
        }
    }

    private func toggle(_ q: Quirk) {
        var set = enabled
        if set.contains(q) { set.remove(q) } else { set.insert(q) }
        writeQuirks(set)
        Haptics.light()
    }

    private func setAllQuirks(_ on: Bool) {
        writeQuirks(on ? Set(Quirk.pool) : [])
        Haptics.light()
    }

    /// 写回勾选集（走同一个 key，PetAvatar 立刻生效）。
    /// ⚠️ 「全关」要写成**空串**而不是删 key —— 删了 key 会被当成「没设过」→ 回全开（见 PetKeys 注释）。
    private func writeQuirks(_ set: Set<Quirk>) {
        // 保持 Quirk.pool 的固定顺序，避免同集合写出不同串（无实际影响，但便于真值表断言）
        let ordered = Quirk.pool.filter { set.contains($0) }
        quirksRaw = ordered.map(\.rawValue).joined(separator: ",")
    }

    /// v3.9.78 原本在外观页，v4.0.6 搬「聊天页形象」时连 UI 一起搬过来。
    /// ⚠️ 搬走时**只搬了调用点、漏了定义** —— 外观页那段被整段删除后
    /// `motionOption` 全仓无定义，Archive 报 cannot find 'motionOption' in scope。
    /// -parse 查不出（成员不存在只有 Archive 拦得住）。
    private func motionOption(_ motion: PetMotion) -> some View {
        let selected = petMotion == motion
        return Button {
            petMotion = motion
        } label: {
            Text(motion.name)
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("宠物动画：\(motion.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
