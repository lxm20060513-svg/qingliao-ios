// MARK: - v4.0.x AI 消息图片渲染 · 真值表（加载态骨架 + 换入淡入）
//
// 背景（2026-09-28 用户要求按 libraries.dev `libraries review` 方法论全盘评审 UI）：
// 评审 21 个等待/进行态位点后只剩 4 个真缺口，本轮落地其一 —— `AIImageView` 的远程加载态原来是
// 裸 `ProgressView()`（240×120 一块白 + 转圈）。问题不在「转圈丑」，而在**它旁边就躺着现成的件**：
// `Theme/Skeleton.swift` 的骨架屏 v3.9.0 就建好了，它自己的注释写明了用途「只用于首次加载占位」，
// 而这里正是一次首次加载。所以这是**接线**，不是新建组件。
//
// 本表钉三件「下次重构容易丢」的事：
//   ① 加载态必须是骨架，且与真图**同圆角**（Radius.inset）—— 圆角不一，换入瞬间会跳版；
//   ② 换入走淡入且尊重「减弱动态效果」（与 Skeleton.swift 自身口径一致：reduceMotion 下静态）；
//   ③ 缓存命中不加动画（最快路径，骨架几乎没出现过，加动画反而闪）。
//
// 另一半（录音电平反应点）在 `scripts/ql_inputbar` 表里钉。
// 用法（必须在仓库根跑）：python3 /opt/data/scripts/ql.py test

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

let bubbleSrc = src("Features/Chat/ChatMessageBubble.swift")

// AIImageView 是本文件最后一个类型，切片到文件尾即「只有它」
let aiSlice: String = {
    guard let a = bubbleSrc.range(of: "struct AIImageView: View {") else { return "" }
    return String(bubbleSrc[a.lowerBound...])
}()

check("切片命中（锚点丢了会让下面全部假绿）", !aiSlice.isEmpty && aiSlice.contains("func loadRemote"))

check("加载态是骨架屏且与真图同圆角（Radius.inset，换入不跳版）",
      aiSlice.contains("SkeletonBlock(width: 240, height: 120, cornerRadius: Radius.inset)"))
check("裸转圈占位已清零（转圈只说「在等」，骨架还说「等来的东西长在这、有这么大」）",
      !aiSlice.contains("ProgressView()"))
check("换入淡入在位：.transition(.opacity) + withAnimation 包住状态变更（缺一样都不动）",
      aiSlice.contains(".transition(.opacity)")
      && aiSlice.contains("withAnimation(.easeOut(duration: 0.18)) { image = img }"))
check("「减弱动态效果」下直接落图（淡入也是动态效果；与 Skeleton 自身口径一致）",
      aiSlice.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion")
      && aiSlice.contains("guard animated, !reduceMotion else {"))
check("缓存命中不加动画（最快路径，骨架几乎没出现过）",
      aiSlice.contains("revealImage(cached, animated: false)"))
check("两条网络路径（URLSession / CFStream 自签降级）都走淡入 —— 降级路径不许被落下",
      aiSlice.components(separatedBy: "revealImage(img, animated: true)").count - 1 == 2)
check("自签证书降级链未被动过（StreamHTTPClient 仍在，用户 NAS 图片仍能加载）",
      aiSlice.contains("StreamHTTPClient()"))
check("同圆角口径与失败占位一致（placeholder 也是 Radius.inset）",
      aiSlice.contains("cornerRadius: Radius.inset, style: .continuous)"))

print("AI 消息图片渲染真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
