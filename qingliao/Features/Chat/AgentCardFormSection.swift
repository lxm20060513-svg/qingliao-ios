import SwiftUI

// MARK: - v4.0.104（#25）：ql-card 可交互表单段
//
// 一句话：AI 把「要你填/选的东西」出成表单卡，你在卡内填完点提交，内容合成一条用户消息发回会话。
//
// 三条口径（改动务必保持，护栏脚本 ql_cardform 会拦）：
//   ① **提交只经宿主回调**（ChatView 传进来的闭包最终走 sendCore 全链路：落库/排队/流式互斥/权限
//      闸门全复用）。本视图不执行任何动作、不直连后端、不写 UserDefaults（一切落账走 CardFormStore）。
//   ② **无回调 = 只读降级**：会话导出、卡片画廊预览等没有宿主回调的路径，渲染成「字段名：值」静态行，
//      行为与旧版逐字一致（零回归）。
//   ③ **已提交 = 幂等**：本地有回执就不再现输入控件（同一张卡不会被提交两次），只显示「已提交 · 时刻」
//      + 提交内容摘要；清缓存重进仍是已提交态。
//
// 注意：整个表单段是**一个独立小 View**（与 AgentCardTable 同口径）—— 别塞回 AgentResultCard.body，
// 那边已经堆了 6 个段，再挤进去会踩 SwiftUI type-check 超时。

struct AgentCardFormSection: View {

    let form: AgentCard.Form
    /// 卡片标题（参与指纹）
    let title: String
    /// 所属消息 id（参与指纹：不同消息的同题卡必须是两张不同的卡）
    let seed: String
    /// 提交回调：传合成文本（nil = 只读降级）
    let onSubmit: ((String) -> Void)?

    @State private var values: [String: String] = [:]
    @State private var submitted: CardFormStore.Submission?
    @State private var inFlight = false
    @FocusState private var focusedKey: String?

    private var fingerprint: UInt64 {
        CardFormStore.fingerprint(seed: seed, title: title, signature: form.signature)
    }

    /// 可交互 = 有宿主回调 且 本卡还没提交过
    private var canSubmit: Bool { onSubmit != nil && submitted == nil }

    /// 还差哪些必填项（非空 → 提交按钮禁用并提示）
    private var missing: [String] { form.missingRequired(values: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let receipt = submitted {
                receiptView(receipt)
            } else if canSubmit {
                inputs
                submitRow
            } else {
                readOnlyRows
            }
        }
        .onAppear(perform: loadReceipt)
    }

    // MARK: 可交互态

    @ViewBuilder
    private var inputs: some View {
        ForEach(form.fields, id: \.key) { field in
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text(field.label)
                        .font(.system(size: Typography.tiny, weight: .medium))
                        .foregroundStyle(.secondary)
                    if field.required {
                        Text("必填")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                if field.kind == .choice {
                    choiceRow(field)
                } else {
                    textRow(field)
                }
            }
        }
    }

    private func textRow(_ field: AgentCard.FormField) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField(field.placeholder ?? field.label, text: binding(field))
                .font(.system(size: Typography.subhead))
                .keyboardType(field.kind == .number ? .decimalPad : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedKey, equals: field.key)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(Color.secondary.opacity(Tint.subtle),
                            in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            if let unit = field.unit, !unit.isEmpty {
                Text(unit)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func choiceRow(_ field: AgentCard.FormField) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(field.options, id: \.self) { option in
                let selected = form.value(field, in: values) == option
                Button {
                    Haptics.tap()
                    values[field.key] = option
                } label: {
                    Text(option)
                        .font(.system(size: Typography.tiny, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.xs)
                }
                .glassPillStroke()
            }
            Spacer(minLength: 0)
        }
    }

    private var submitRow: some View {
        HStack(spacing: Spacing.md) {
            if !missing.isEmpty {
                Text("还差：\(missing.joined(separator: "、"))")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: submit) {
                Text(form.submitLabel)
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .lineLimit(1)
            }
            .glassPillStroke()
            .opacity(missing.isEmpty ? 1 : 0.45)
            .disabled(!missing.isEmpty || inFlight)
        }
    }

    // MARK: 已提交 / 只读降级

    private func receiptView(_ receipt: CardFormStore.Submission) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(Color.accentColor)
                Text(CardFormStore.submittedText(receipt.at))
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !receipt.summary.isEmpty {
                Text(receipt.summary)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            // 「重填」：清掉本地回执 → 输入控件重新出现（用户想再算一次/填错时的自救入口；
            // 没这一步，已提交的卡就永久锁死 —— 审查提的「死胡同」）
            Button(action: retry) {
                Text("重填")
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .lineLimit(1)
            }
            .glassPillStroke()
        }
    }

    /// 清凭证 + 清输入态 → 回到可填写状态（幂等：没回执时也安全）
    private func retry() {
        CardFormStore.shared.clear(for: fingerprint)
        submitted = nil
        values = [:]
        Haptics.tap()
    }

    private var readOnlyRows: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(form.fields, id: \.key) { field in
                HStack(spacing: Spacing.sm) {
                    Text(field.label)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                    if let v = currentValue(field) {
                        Text(v)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.primary)
                    }
                    if let unit = field.unit, !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 读写

    private func loadReceipt() {
        submitted = CardFormStore.shared.submission(for: fingerprint)
    }

    private func currentValue(_ field: AgentCard.FormField) -> String? {
        let v = form.value(field, in: values)
        return v.isEmpty ? nil : v
    }

    private func binding(_ field: AgentCard.FormField) -> Binding<String> {
        Binding(get: { values[field.key] ?? "" },
                set: { values[field.key] = $0 })
    }

    /// 提交：合成文本 → 先落本地回执（幂等）→ 再交宿主回调发消息
    private func submit() {
        guard canSubmit, !inFlight, missing.isEmpty else { return }
        let text = form.compose(values: values)
        guard !text.isEmpty else { return }   // 全空又无模板 → 不发空消息
        inFlight = true
        focusedKey = nil
        let receipt = CardFormStore.Submission(values: values, summary: text)
        CardFormStore.shared.record(receipt, for: fingerprint)
        submitted = receipt
        Haptics.tap()
        onSubmit?(text)
        inFlight = false
    }
}
