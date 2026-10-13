// MARK: - v4.0.104 待做池⑫ 专注计时（番茄钟）浮层 + 计量进度条
//
// 呈现形态与习惯/备忘/待办三张浮层**1:1 同形**（MemoGlassOverlay 毛玻璃全屏），
// 宿主仍是 HabitGlassLayerHost（已挂在 LifeView 根 → 全屏、盖住页头）。
// 状态放在**本文件自己的**页级单例 FocusGlassPresenter，不去动共享的 LifeGlassPresenterBase
// （那是四栏共用的基类，为一栏加字段会波及另一栏已验收的行为）。
//
// 口径（真值表 scripts/ql_focus 钉住）：
//   · 剩余时间由 FocusTimerStore 现算 → 浮层只是显示器，关掉再打开不会「停表/归零」
//   · 开始专注时若该习惯还不是「时长」维度 → **当场升级**（目标 = 所选分钟数），
//     这一步在 UI 上有明示（文案写在按钮上方），不是偷偷改用户的东西
//   · 「结束并记录」记已过整分钟；「放弃本轮」= 一条都不记

import SwiftUI
import Observation

/// 专注计时浮层的页级开关（挂 LifeView 根那只宿主渲染）
@MainActor
@Observable
final class FocusGlassPresenter {
    static let shared = FocusGlassPresenter()

    /// 打开浮层时针对的习惯（nil = 关闭）
    var habitId: String?
    /// 上次选中的预设分钟（再打开时沿用）
    var preset: Int = 25

    private init() {}

    func open(habitId: String, preset: Int? = nil) {
        self.habitId = habitId
        if let preset { self.preset = preset }
    }

    func close() { habitId = nil }

    /// 宿主销毁即清状态（与 HabitGlassPresenter.reset 同款，避免页面重建后莫名弹回上次那层）
    func reset() { habitId = nil }
}

// MARK: - 计量进度条（行卡 / 详情共用一枚，避免两处各画各的）

struct MetricProgressBar: View {
    let fraction: Double
    var height: CGFloat = 5
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 专注计时浮层内容

struct FocusTimerBody: View {
    let habitId: String
    let onClose: () -> Void

    /// 显式 internal init（v4.0.104 修 CI 编译错）：合成 memberwise init 在 CI 上被报成
    /// `'FocusTimerBody' initializer is inaccessible due to 'private' protection level`
    ///（调用点在 HabitSection.swift 打开浮层处）。本机 `-parse` 查不出，只有 CI 的 Archive 才炸 ——
    /// 显式写出与合成版**逐字同义**（同参数、同默认值），但访问级别确定为 internal，不再随合成规则变。
    /// 结构体里那两个单例引用是 `private var`（不走 memberwise），`@State private var selected` 自带默认值。
    init(habitId: String, onClose: @escaping () -> Void) {
        self.habitId = habitId
        self.onClose = onClose
    }

    private var focus = FocusTimerStore.shared
    private var store = HabitStore.shared
    /// 选中的预设分钟（默认沿用 presenter 记住的档）
    @State private var selected: Int = FocusGlassPresenter.shared.preset

    private var habit: HabitItem? { store.habits.first { $0.id == habitId } }
    /// 当前这一轮是不是本习惯的
    private var isMine: Bool { focus.session?.habitId == habitId }
    /// 正在为**别的**习惯计时（同一时刻只允许一轮）
    private var otherRunning: Bool {
        if let s = focus.session { return s.habitId != habitId }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let h = habit { header(h) } else { missingHabit }
                    if isMine { runningBlock } else if otherRunning { otherBlock } else { pickBlock }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 顶栏（口径同 HabitDetailSheet.topBar：小胶囊 + 居中标题）

    private var topBar: some View {
        HStack(spacing: 8) {
            MiniCapsule(title: "关闭") { onClose() }
            Spacer(minLength: 0)
            Text("专注计时")
                .font(.system(size: Typography.body, weight: .semibold))
            Spacer(minLength: 0)
            // 与左胶囊同宽的占位，保证标题真居中
            Color.clear.frame(width: 46, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 头部（习惯名 + 今日进度）

    private func header(_ h: HabitItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(h.title)
                .font(.system(size: Typography.headline))
                .frame(maxWidth: .infinity, alignment: .leading)
            if h.isMetric {
                HStack(spacing: 8) {
                    Text(HabitKit.progressText(h, on: Date()))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    MetricProgressBar(fraction: HabitKit.progressFraction(h, on: Date()))
                        .frame(maxWidth: 140)
                }
            } else {
                Text("还没设成可计量的习惯（下面开始专注时会自动设为「时长」）")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    private var missingHabit: some View {
        Text("这个习惯已被删除，专注记录无处可记。")
            .font(.system(size: Typography.body))
            .foregroundStyle(.secondary)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard()
    }

    // MARK: 选择时长 + 开始

    private var pickBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 到点自动收尾（或刚手动结束）后的回执：不写这句，用户会以为「时间到了但没记上」
            if let rec = focus.lastRecord, rec.habitId == habitId {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Typography.tiny))
                    Text("已记录 \(rec.minutes) 分钟到「\(habit?.title ?? "该习惯")」")
                        .font(.system(size: Typography.caption, weight: .medium))
                }
                .foregroundStyle(Color.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(Tint.subtle), in: Capsule())
                .accessibilityLabel("已记录 \(rec.minutes) 分钟")
            }
            Text("专注多久")
                .font(.system(size: Typography.subhead, weight: .medium))
            HStack(spacing: 8) {
                ForEach(HabitKit.focusPresets, id: \.self) { m in
                    Button {
                        selected = m
                        FocusGlassPresenter.shared.preset = m
                        Haptics.selection()
                    } label: {
                        Text("\(m) 分")
                            .font(.system(size: Typography.subhead,
                                          weight: selected == m ? .semibold : .regular))
                            .foregroundStyle(selected == m ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selected == m ? Color.green : Color.secondary.opacity(Tint.subtle),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
            // ⚠️ 明示「开始会改这个习惯的形态」，不让用户在不知情的情况下被改数据
            if let h = habit, !(h.isMetric && h.metric == .duration) {
                Text(h.isMetric
                     ? "「\(h.title)」当前是\(h.metric == .duration ? "时长" : "量")维度，开始后会改成「时长」（目标 \(selected) 分钟）。"
                     : "「\(h.title)」还没设过计量，开始后会自动设为「时长」习惯（目标 \(selected) 分钟）。")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            Button {
                start()
            } label: {
                Text("开始专注 \(selected) 分钟")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.green, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(habit == nil)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    // MARK: 进行中

    private var runningBlock: some View {
        let planned = focus.session?.plannedMinutes ?? selected
        let total = Double(max(1, planned)) * 60
        let left = Double(focus.remaining)
        let progress = max(0, min(1, 1 - left / total))
        return VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    Text(HabitKit.focusClock(focus.remaining))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("计划 \(planned) 分钟")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)

            Text("退到后台、锁屏都不会停表；回来自动对表。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button {
                    let mins = focus.stop()
                    Haptics.success()
                    if mins > 0 { onClose() }
                } label: {
                    Text("结束并记录")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())

                Button {
                    focus.cancel()
                    Haptics.light()
                    onClose()
                } label: {
                    Text("放弃本轮")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(Tint.subtle), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
            Text("「结束并记录」把已过的整分钟记进今天；「放弃本轮」一条都不记。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    // MARK: 别的习惯正在计时（同一时刻只允许一轮）

    private var otherBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            let s = focus.session
            let name = store.habits.first { $0.id == s?.habitId }?.title ?? "另一个习惯"
            Text("正在为「\(name)」专注 \(HabitKit.focusClock(focus.remaining))")
                .font(.system(size: Typography.body))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("同一时刻只跑一轮。先结束它，再给这个习惯开始。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Button {
                let mins = focus.stop()
                Haptics.success()
                if mins > 0 { onClose() }
            } label: {
                Text("结束那一轮并记录")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    // MARK: 开始（含「自动升级成时长习惯」）

    private func start() {
        guard let h = habit else { return }
        if !(h.isMetric && h.metric == .duration) {
            store.updateMetric(h, metric: .duration, target: Double(selected), unit: "分钟")
        }
        focus.start(habitId: habitId, minutes: selected)
        FocusGlassPresenter.shared.preset = selected
        Haptics.success()
    }
}
