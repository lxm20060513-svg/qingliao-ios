import Foundation

// 宠物动画真值表（v4.0.0：走动搞怪动画 + v3.9.85 微动作回归护栏）
// 只读源码做静态断言，不 import App（headless Linux 跑不了 SwiftUI）。

final class Counter: @unchecked Sendable {
    static let shared = Counter()
    var total = 0, failures = 0
    func check(_ label: String, _ ok: Bool) {
        total += 1
        if ok { print("✅ \(label)") } else { failures += 1; print("❌ \(label)") }
    }
}
@MainActor func check(_ label: String, _ ok: Bool) {
    Counter.shared.check(label, ok)
}
@MainActor func report() -> Never {
    let c = Counter.shared
    print("\n———————————————")
    print(c.failures == 0 ? "✅ 全部通过 \(c.total)/\(c.total)" : "❌ 失败 \(c.failures)/\(c.total)")
    exit(c.failures == 0 ? 0 : 1)
}
func read(_ p: String) -> String {
    (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
}
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")
}

let av = read("qingliao/Features/Chat/PetAvatar.swift")
let cv = read("qingliao/Features/Chat/ChatView.swift")
let avC = stripComments(av)

check("读得到宠物形象源文件（路径没被挪）", !av.isEmpty)
check("读得到聊天页源文件（路径没被挪）", !cv.isEmpty)

// MARK: - 1. 走动动作存在且进了随机池
check("Quirk 枚举有踱步动作（strollLeft / strollRight）",
      avC.contains("case strollLeft") && avC.contains("case strollRight"))
check("踱步进随机池（不然新动作永远不播，等于白加）",
      avC.contains(".strollLeft, .strollRight]"))
check("isStroll 判定存在（镜像/颠步都靠它分流）",
      avC.contains("var isStroll: Bool"))

// MARK: - 2. 位移是真位移（旧四个动作全是 0.0x 幅度，观感「贴着晃」）
check("踱步有真位移（0.145×size ≈ 14pt，非 0 幅度形变）",
      avC.contains("case .strollLeft: return -size * 0.145")
      && avC.contains("case .strollRight: return size * 0.145"))
check("踱步有上下颠步（quirkyBob 纵向起伏）",
      avC.contains("var quirkyBob: CGFloat"))
check("颠步幅度 0.03×size（≈3pt，够看又不夸张）",
      avC.contains("return strollPhase ? -size * 0.03 : 0"))
check("踱步有身体前倾（2.5°，重心前移的身体感）",
      avC.contains("case .strollLeft, .strollRight: return 2.5"))

// MARK: - 3. 🚨 走动方向配对（这才是真约束；顺序本身无影响）
// 上一版这里写的是「镜像必须排在位移之前，否则横着滑」——**那条因果不成立**：
// 外层 offset 在未镜像的父空间里做，不会被内层 scaleEffect 镜像，两种顺序结果完全相同。
// 真正会让宠物「横着滑」的是**方向配错**：朝右走却朝左看。
// 已改为逐档钉住配对关系（见下），比原来的顺序断言更严、也不会误导后来人。
let iMirror = av.range(of: ".scaleEffect(x: quirkyMirror, y: 1, anchor: .bottom)")
let iOffset = av.range(of: ".offset(x: quirkyShift, y: quirkyBob)")
check("镜像层存在（朝向前进方向）", iMirror != nil)
check("位移层存在", iOffset != nil)
if let m = iMirror, let o = iOffset {
    // 顺序不作为护栏（两种都对），只记录当前实现顺序供人工参考
    print("ℹ️ 当前实现顺序：镜像在位移\(m.lowerBound < o.lowerBound ? "之前" : "之后")（顺序不影响结果，仅记录）")
}
// 🚨 真正要守的：**位移方向与镜像方向必须配对**（配错才是「横着滑」）
// 约定：strollLeft → shift<0（向左走）且 mirror<0（朝左看）；strollRight → 反之。
check("位移：strollLeft 向左（负）/ strollRight 向右（正）",
      avC.contains("case .strollLeft: return -size * 0.145")
      && avC.contains("case .strollRight: return size * 0.145"))
check("镜像：只朝左走时翻（strollLeft→-1 / 其余→1），与位移方向配对",
      avC.contains("quirky == .strollLeft ? -1.0 : 1.0"))
// 镜像只能挂在 Canvas 层，不能盖住 overlay 的角标/思考点
check("镜像在 .overlay(alignment: .topTrailing) 之前（不把角标翻过来）",
      av.range(of: ".overlay(alignment: .topTrailing)") == nil
      || (iMirror.map { av.range(of: ".overlay(alignment: .topTrailing)")!.lowerBound > $0.lowerBound } ?? false))
// 锚点统一底部：位移与颠步从「脚」出发，不整体漂浮
check("位移与旋转锚点都是 .bottom（脚不离地）",
      avC.contains(".rotationEffect(.degrees(quirkyAngle), anchor: .bottom)")
      && avC.contains(".offset(x: quirkyShift, y: quirkyBob)"))

// MARK: - 4. 编排：走出去 → 颠步 → 顿一下 → 走回
check("有独立踱步编排函数 playStroll（不是复用两段式）",
      avC.contains("func playStroll(_ q: Quirk, duration d: TimeInterval)"))
check("playStroll 结束时 quirky 归 .none（回原位）",
      avC.contains("withAnimation(.easeInOut(duration: d * 0.3)) { quirky = .none }"))
check("循环按 isStroll 分流（踱步走四段，其余仍两段）",
      avC.contains("if q.isStroll") && avC.contains("await playStroll(q, duration: d)"))
check("playStroll 每步都重查 animate/取消（后台/减弱时立刻收住）",
      stripComments(avC.components(separatedBy: "func playStroll").last ?? "")
          .components(separatedBy: "guard animate, !Task.isCancelled else { return }").count >= 3)

// MARK: - 5. 🚨 姿态复位：不动时不能卡在抬起
check("animate 变 false 时复位 strollPhase + quirky（否则回前台僵在半抬）",
      avC.contains("strollPhase = false")
      && avC.contains("quirky = .none"))
// 那两句必须落在 onChange(of: animate) 的 else 分支里，而不是别处
if let oc = av.range(of: ".onChange(of: animate)") {
    let seg = String(av[oc.lowerBound...])
    let cut = seg.range(of: ".task(id: animate)")?.lowerBound ?? seg.endIndex
    check("复位写在 onChange(of: animate) 的 else 分支（不是无关位置）",
          seg[seg.startIndex..<cut].contains("strollPhase = false"))
} else {
    check("存在 onChange(of: animate) 监听", false)
}

// MARK: - 6. 🚨 命中域：位移溢出后仍可点（抚摸不失灵）
check("命中域横向扩到 ±18pt（盖住 14pt 位移，宠物在框外也点得到）",
      cv.contains("leading: -18") && cv.contains("trailing: -18"))
check("命中域不是裸 Rectangle()（否则位移段失灵）",
      !cv.contains(".contentShape(Rectangle())   // 形象自身"))

// MARK: - 7. 旧四动作不得被改坏（v3.9.85 回归）
for (n, v) in [("歪头", "case .headTilt: return 6"), ("张望", "case .lookAround: return -3")] {
    check("旧动作「\(n)」角度未被改坏（\(v)）", avC.contains(v))
}
check("旧动作池里四个老动作都还在",
      avC.contains("[.headTilt, .lookAround, .happyWiggle, .stretch,"))
check("眨眼/呼吸两循环仍在（不被走路取代）",
      avC.contains("func blinkLoop()") && avC.contains("func startBreath()"))

// MARK: - 8. 省电红线：走动不得常驻逐帧渲染
check("走路是「定时+withAnimation」驱动，没有常驻 TimelineView/逐帧循环",
      !avC.contains("TimelineView"))
// ⚠️ 纠错记录：曾断言「Canvas 走 .drawingGroup() 栅格化」——v3.9.78 换原生矢量时已**去掉**
//   （原生 Path 本身就是矢量，无需离屏缓存），照旧断言是假红。红线应盯「不引入新的常驻驱动」。
check("没有常驻的逐帧驱动（只有 blinkLoop/quirkyLoop 两个可取消的 Task 循环）",
      !avC.contains("TimelineView") && !avC.contains("CADisplayLink")
      && !avC.contains("Timer.scheduledTimer"))
check("动画循环可被 animate 开关取消（.task(id: animate)）",
      avC.components(separatedBy: ".task(id: animate)").count - 1 >= 2)

report()
