// MARK: - ChatView 语音转文字（从 ChatView.swift 拆出，v3.0.81）
//
// v3.9.3：整条链路换成**设备端实时转写**（iOS 26 SpeechAnalyzer + SpeechTranscriber）
//   · 边说边出字：按住说话时 volatile 结果直接流进输入框
//   · 音频不上传（设备端识别），无时长上限，无网络依赖
//   · 本地/云端双模式都能用 —— 原来「云端模式无后端 ASR」把语音入口整块屏蔽了（v3.0.4）
//   详见 Core/LiveSpeechTranscriber.swift 头部注释（含 v2.0.85「侧载必闪退」误判的复盘）

import SwiftUI

extension ChatView {
    /// v2.0.96：退出语音转文字模式（按钮/空白点击共用）
    /// v3.9.3：停止识别 → 定稿 → 文本留在输入框（不再上传音频）
    func exitVoiceMode() {
        voiceStartToken += 1   // v3.9.3：作废任何"正在准备中"的启动（模型下载期间用户已点取消）
        guard voiceMode else { return }
        withAnimation(Motion.snap) { voiceMode = false }
        transcribing = true
        Task {
            let text = await liveSpeech.stop()
            transcribing = false
            voiceDiag = liveSpeech.diagnostics
            // v3.9.9：录音期间一个中间结果都没出（= 实时出字没生效）→ 自动上报一条诊断到后端
            // （data/diag/reports.jsonl），含 V/F 结果计数 + T/D/Y 音频三级计数 + 首结果耗时，
            // 这样"为什么不出字"不用再靠用户复述，直接读后端即可定位断在哪一级。
            // 正常会话（有中间结果）不上报，避免污染诊断流。
            if liveSpeech.volatileCount == 0 {
                let env = DiagnosticsStore.env()
                let ev = DiagEvent.makeEvent(kind: "voice", env: env,
                                             summary: "语音实时出字为 0：\(liveSpeech.resultStats) \(liveSpeech.pipeStats)",
                                             stack: liveSpeech.diagnostics + "\n文字长度=\(text.count)")
                _ = DiagnosticsStore.enqueue(ev)
                Task { _ = await DiagnosticsUploader.flushPending() }
                NSLog("[VOICE] 零中间结果，已上报诊断：\(liveSpeech.resultStats) \(liveSpeech.pipeStats)")
            }
            if liveSpeech.lastRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 一句话都没识别出来（说话太短 / 没靠近麦克风 / 环境太吵）
                voiceTooShort = true
                NSLog("[VOICE] 未识别到内容 \(voiceDiag)")
            } else {
                inputText = text
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// v3.0.19：限流/服务错误 → 用户友好提示（429/rate limit/tpm exhausted → 建议换模型路由）
    static func friendlyStreamError(_ error: String) -> String {
        // v3.0.19 review：截断过长原始错误（防消息里塞整页错误日志）
        let brief = error.count > 160 ? String(error.prefix(160)) + "…" : error
        let low = error.lowercased()
        if low.contains("429") || low.contains("rate limit") || low.contains("tpm") ||
           low.contains("exhausted") || low.contains("too many request") {
            return "\(brief)\n\n💡 当前模型的额度限流了（tpm 用尽）。请到「设置 → 模型管理」换一个 provider 的模型（如官方 DeepSeek 或 opencode），稍后再试。"
        }
        if low.contains("timeout") || low.contains("timed out") {
            return "\(brief)\n\n💡 请求超时，可能网络波动或服务繁忙，请重试。"
        }
        return brief
    }

    /// v2.0.101：取消本次转写（输入框回到进入语音模式前的内容）
    func cancelTranscribe() {
        // v3.9.3：必须作废"正在准备中"的启动 —— 本按钮在准备期（模型下载）就在屏幕上，
        // 原来只置 transcribing=false，几十秒后仍会进入语音模式（用户点 × 毫无效果）
        voiceStartToken += 1
        transcribing = false
        Task { await liveSpeech.cancel() }
    }

    /// v2.0.96：语音转文字模式开关（长按发送按钮进入，点按钮/空白退出）
    /// v2.0.100：进入时震动反馈
    /// v2.0.106：长按输入框进入同款路径
    /// v2.0.107：键盘两场景——长按前键盘已开 → 保持；未开 → 收回（触摸聚焦弹的，语音模式不弹键盘）
    /// v2.0.107b：震动改 heavy + prepare（原 medium 无 prepare，首次 impact 常被系统丢弃/偏弱）
    /// v3.9.3：改设备端实时转写——首次使用可能要下载语音模型（isPreparing，UI 显示"语音转换中…"）
    func toggleVoiceMode(keyboardWasUp: Bool = false) {
        if voiceMode {
            exitVoiceMode()
            return
        }
        voiceStartToken += 1
        let token = voiceStartToken
        Task {
            // 实时文本回填：进入前输入框的内容作为基线，识别的字接在后面
            liveSpeech.onTextChange = { text in inputText = text }
            // 运行期错误（结果流中断等）：收起语音 UI + 弹窗说明，别让用户卡在"录音中"
            liveSpeech.onError = { message in
                voiceMode = false
                transcribing = false
                voiceError = message
            }
            let started = await liveSpeech.start(baseline: inputText)
            voiceDiag = liveSpeech.diagnostics
            // 准备期间用户已取消（代次变了）→ 把这次启动作废收干净，别进入语音模式
            guard token == voiceStartToken else {
                await liveSpeech.cancel()
                NSLog("[VOICE] 启动被取消（准备期间用户已退出）")
                return
            }
            guard started else {
                if liveSpeech.needsPermission {
                    voiceAuthFailed = true
                } else {
                    voiceError = liveSpeech.lastError ?? "语音识别启动失败"
                }
                NSLog("[VOICE] start failed: \(voiceDiag)")
                return
            }

            let gen = UIImpactFeedbackGenerator(style: .heavy)
            gen.prepare()
            gen.impactOccurred()   // 长按激活震动反馈
            if !keyboardWasUp {
                inputFocus = false   // 键盘原本未开 → 收回触摸聚焦弹起的键盘（语音模式不弹键盘）
                // v2.0.108c：FocusState 在触摸聚焦动画中设置可能被系统覆盖（iOS27）——
                // 延迟 60ms 用 UIKit 强制 resignFirstResponder 兜底，确保键盘收回
                Task {
                    try? await Task.sleep(for: .seconds(0.06))
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
            withAnimation(Motion.snap) { voiceMode = true }
        }
    }
}
