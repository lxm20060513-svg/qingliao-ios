// 轻聊「欢迎页特征智能球」真值表（v3.9.57，本机可跑，不 import 项目代码）
//
// 守三件事：
//   ① 冻结判定语义 —— live=true 时 idle 不冻结；freezesMotion（减弱动态效果）优先于 live；
//      头像场景（live=false）保持 v3.9.2 起的静止态零 GPU 开销冻结设计
//   ② thinking 态永远不冻结（无论 live / freezesMotion）
//   ③ 源护栏 —— 欢迎页大球必须 live: true、接 AI 状态、带交互；
//      旧形态（气泡图标压在球上 + 渐变底圆）不得回归；消息头像/思考头像不得被误设 live
//
// 用法：python3 /opt/data/scripts/ql.py test
// 或单表：LD_LIBRARY_PATH=/opt/data/swift-libs \
//   /opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc -O \
//   -o /tmp/tt_orb scripts/ql_orb/truth_table_orb.swift && /tmp/tt_orb

import Foundation

var failures = 0
var total = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok {
        print("✅ \(name)\(detail.isEmpty ? "" : " — " + detail)")
    } else {
        print("❌ \(name)\(detail.isEmpty ? "" : " — " + detail)")
        failures += 1
    }
}

// MARK: - ① 镜像冻结判定（源：LiquidOrbAvatar.swift 的 updatePacing）

/// 与源同口径：是否走冻结路径（播完过渡后 isPaused=true）
func mirrorShouldFreeze(state: String, live: Bool, freezesMotion: Bool) -> Bool {
    (state == "idle" && !live) || freezesMotion
}

check("头像场景（live=false）idle 冻结 —— 省电设计不回退",
      mirrorShouldFreeze(state: "idle", live: false, freezesMotion: false))
check("欢迎页特征球（live=true）idle 不冻结 —— 常驻流动",
      !mirrorShouldFreeze(state: "idle", live: true, freezesMotion: false))
check("thinking 永不冻结（live=true）",
      !mirrorShouldFreeze(state: "thinking", live: true, freezesMotion: false))
check("thinking 永不冻结（live=false，头像）",
      !mirrorShouldFreeze(state: "thinking", live: false, freezesMotion: false))
check("减弱动态效果优先于 live：freezesMotion=true 时头像 idle 仍冻结",
      mirrorShouldFreeze(state: "idle", live: false, freezesMotion: true))
check("减弱动态效果优先于 live：freezesMotion=true 时特征球 idle 也冻结",
      mirrorShouldFreeze(state: "idle", live: true, freezesMotion: true))
check("减弱动态效果下 thinking 也冻结（v3.9.42 口径不变）",
      mirrorShouldFreeze(state: "thinking", live: false, freezesMotion: true))

// MARK: - ② 源护栏

print("\n=== ② 源护栏 ===")

let orbPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/LiquidOrbAvatar.swift"
let chatPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatView.swift"

let orbSrc = (try? String(contentsOfFile: orbPath, encoding: .utf8)) ?? ""
let chatSrc = (try? String(contentsOfFile: chatPath, encoding: .utf8)) ?? ""

// 读不到 → 全部护栏都会假绿，先钉住
check("护栏：LiquidOrbAvatar.swift 读得到", !orbSrc.isEmpty, orbPath)
check("护栏：ChatView.swift 读得到", !chatSrc.isEmpty, chatPath)

// 渲染器链：live 必须从 View 一路透传到 renderer（漏一层=参数恒 false，分支静默失效）
check("护栏：LiquidOrbView 透传 live 给 Surface",
      orbSrc.contains("LiquidOrbSurface(state: state, freezesMotion: reduceMotion, live: live)"))
check("护栏：makeUIView 把 live 传进 makeView",
      orbSrc.contains("context.coordinator.makeView(state: state, freezesMotion: freezesMotion, live: live)"))
check("护栏：renderer 有 live 属性且 freezesMotion 注释说明优先级",
      orbSrc.contains("var live = false") && orbSrc.contains("freezesMotion 优先于它"))
check("护栏：冻结判定写成 (state == .idle && !live) || freezesMotion",
      orbSrc.contains("let shouldFreeze = (state == .idle && !live) || freezesMotion"))

// 欢迎页：特征球本体
check("护栏：欢迎页大球 live: true（常驻流动）",
      chatSrc.contains("LiquidOrbAvatar(size: 96, thinking: aiBusy, live: true)"))
check("护栏：欢迎页大球接 AI 忙闲（aiBusy 驱动 thinking 态）",
      chatSrc.contains("LiquidOrbAvatar(size: 96, thinking: aiBusy"))
// 旧形态不得回归：气泡图标 + 渐变底圆压在球上
check("护栏：球上不再压气泡图标",
      !chatSrc.contains("bubble.left.and.bubble.right.fill"))
check("护栏：球外渐变底圆已移除",
      !chatSrc.contains("v3.4.25：粒子球版 logo 替代静态渐变圆"))

// 交互：点聚焦输入框 + 长按语音转文字（ExclusiveGesture 防 tap 补触发）
check("护栏：大球挂了 ExclusiveGesture（点/长按互斥）",
      chatSrc.contains("ExclusiveGesture(") && chatSrc.contains("LongPressGesture(minimumDuration: 0.45)"))
check("护栏：点球聚焦输入框", chatSrc.contains("inputFocus = true"))
check("护栏：长按走 toggleVoiceMode（与输入框/发送键同一路径）",
      chatSrc.contains("toggleVoiceMode(keyboardWasUp: kb.isVisible)"))
check("护栏：长按的 keyboardWasUp 用 kb.isVisible（不是 inputFocus）",
      !chatSrc.contains("toggleVoiceMode(keyboardWasUp: inputFocus)"))

// 命中域：球自身 allowsHitTesting(false)，不补 contentShape 整颗球点不到
check("护栏：大球补了 contentShape 命中域",
      chatSrc.contains(".contentShape(Rectangle())"))

// 消息头像/思考头像保持默认（不被误设 live）——误设会让长列表每个头像都常驻 30fps
check("护栏：消息头像未误设 live（默认冻结）",
      chatSrc.contains("LiquidOrbAvatar(size: 38, thinking: true)"))
let bubblePath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatMessageBubble.swift"
let bubbleSrc = (try? String(contentsOfFile: bubblePath, encoding: .utf8)) ?? ""
check("护栏：ChatMessageBubble.swift 读得到", !bubbleSrc.isEmpty, bubblePath)
check("护栏：消息头像未误设 live（默认冻结）",
      bubbleSrc.contains("LiquidOrbAvatar(size: 30, thinking: streamingAvatar)")
      && !bubbleSrc.contains("live: true"))

print(failures == 0 ? "\n🎉 真值表全部通过（\(total) 项）" : "\n💥 失败 \(failures)/\(total) 条")
exit(failures == 0 ? 0 : 1)
