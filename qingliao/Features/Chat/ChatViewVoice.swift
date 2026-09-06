// MARK: - ChatView 语音转文字（从 ChatView.swift 拆出，v3.0.81）

import SwiftUI

extension ChatView {
    /// v2.0.96：退出语音转文字模式（按钮/空白点击共用）
    /// v2.0.96c：停止录音 → 上传转写 → 文字回填输入框
    /// v3.0.19：语音指令模式退出 → 停止录音 → 转写 → 自动发送（uploadAndTranscribe 内分支）
    func exitVoiceMode() {
        guard voiceMode else { return }
        withAnimation(.easeOut(duration: 0.2)) { voiceMode = false }
        uploadAndTranscribe()   // v3.0.77 整段录音：uploadAndTranscribe 内统一 stop() 取完整音频
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

    /// v2.0.96c：上传录音转写（服务器 faster-whisper）
    /// v2.0.100：transcribing 动画（输入框「语音转换中…」+ 按钮转圈）+ 完成/失败震动
    /// v2.0.101：停止按钮（transcribeToken 代次——停止/重录使旧 Task 结果作废，杜绝竞态回填）
    /// v3.0.77：移除 v3.0.36 分段流式——分段每 2s 对录音器 stop/resume（局部/独立文件名）导致段音频读不到，
    ///          语音转文字恒判"录音太短"。改回整段录音一次转写（v3.0.35 稳定方式）。
    /// v3.1.4+：stop() 返回 nil 时（音频会话未就绪就松手），静默跳过不报错
    func uploadAndTranscribe() {
        // 整段录音：松手后取完整音频一次 ASR（不依赖分段 voiceSegments）
        guard let url = voiceRecorder.stop() else {
            voiceDiag = "stop()=nil recordOK=\(String(describing: voiceRecorder.lastRecordOK))"
            NSLog("[VOICE] \(voiceDiag)")
            // v3.1.4+：音频会话未就绪就松手（异步启动中），不显示错误提示（用户无感知）
            return
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let sz: Int = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
        voiceDiag = "size=\(sz) exists=\(exists) recordOK=\(String(describing: voiceRecorder.lastRecordOK)) ver=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
        NSLog("[VOICE] \(voiceDiag)")
        guard exists, let data = try? Data(contentsOf: url), data.count > 100 else {
            voiceDiag += " → data≤100B"
            NSLog("[VOICE] tooShort \(voiceDiag)")
            voiceTooShort = true
            return
        }
        NSLog("[VOICE] OK data.count=\(data.count)")
        transcribeToken += 1
        let token = transcribeToken
        transcribing = true
        Task {
            do {
                let text = try await auth.asrTranscribe(data)
                guard token == transcribeToken else { return }
                transcribing = false
                if !text.isEmpty {
                    if inputText.isEmpty {
                        inputText = text
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                } else {
                    voiceTooShort = true
                }
            } catch {
                guard token == transcribeToken else { return }   // v3.0.86 fix：先校验代次再复位（与成功分支同序）——旧代次 Task 失败不得关掉新一轮转写动画
                transcribing = false
                voiceTooShort = true
            }
        }
    }

    // v3.0.77：移除 v3.0.36 分段流式（startVoiceSegments/flushVoiceSegment/stopVoiceSegments）——整段录音无分段循环

    /// v2.0.101：停止转写（代次递增使旧 Task 结果作废 + 立即隐藏转换动画）
    func stopTranscribe() {
        transcribeToken += 1
        transcribing = false
    }

    /// v2.0.96：语音转文字模式开关（长按发送按钮进入，点按钮/空白退出）
    /// v2.0.100：进入时震动反馈（UIImpactFeedbackGenerator medium）
    /// v2.0.106：长按输入框进入同款路径
    /// v2.0.107：键盘两场景——长按前键盘已开 → 保持；未开 → 收回（触摸聚焦弹的，语音模式不弹键盘）
    /// v2.0.107b：震动改 heavy + prepare（原 medium 无 prepare，首次 impact 常被系统丢弃/偏弱）
    /// v3.1.4+：start() 改异步（音频会话后台配置），先显示语音 UI 再等录音就绪
    func toggleVoiceMode(keyboardWasUp: Bool = false) {
        // v3.0.4：云端模式无后端 ASR → 屏蔽语音转文字入口（双重保护，避免误入）
        guard !CloudConfig.shared.isCloudMode else { return }
        if voiceMode {
            exitVoiceMode()
        } else {
            // v3.1.4+：start() 现在同步返回 true（UI 立即切换），音频会话在后台配置
            // 录音实际就绪需要短暂时间，但 UI 反馈是即时的
            let started = voiceRecorder.start()
            if started {
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
                withAnimation(.easeOut(duration: 0.2)) { voiceMode = true }
            } else {
                // v3.0.19 review fix #2：麦克风失败 → 重置语音指令标志（防残留劫持下次转文字）
                voiceAuthFailed = true   // 麦克风权限被拒
            }
        }
    }
}
