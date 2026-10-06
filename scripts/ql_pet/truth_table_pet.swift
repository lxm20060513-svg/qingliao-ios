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
/// 去掉注释再判代码。
/// v4.0.0：原实现只剥「整行以 // 开头」，**剥不掉缩进注释与行尾注释** ——
///   于是注释里作为反面教材写着的坏 API 会被当代码命中，护栏自己判自己红。
/// 现改为：先去掉每行 `//` 之后的内容（字符串字面量里的 // 罕见，代价可接受）。
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if let i = line.firstIndex(of: "/"), i == line.startIndex,
               line.index(after: i) < line.endIndex, line[line.index(after: i)] == "/" {
                return ""
            }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }
        .joined(separator: "\n")
}

// v4.0.6：Quirk 模型从 PetAvatar.swift 提到 PetModel.swift（设置页要做多选，file private 跨文件不可见）。
// 断言随实现搬家：读两个文件，代码断言各自落到正确的那个里。
let pm = read("qingliao/Features/Chat/PetModel.swift")
let pmC = stripComments(pm)
let av = read("qingliao/Features/Chat/PetAvatar.swift")
let ps = read("qingliao/Features/Settings/PetStudioSheet.swift")
let sc = read("qingliao/Features/Settings/SettingsCore.swift")
let scom = read("qingliao/Features/Settings/SettingsCommon.swift")
let pa = read("qingliao/Features/Chat/PetPainter.swift")
let la = read("qingliao/Core/LiveActivityAttributes.swift")
let lw = read("qingliaoWidget/QingliaoLiveActivityWidget.swift")
let psC = stripComments(ps)
let cv = read("qingliao/Features/Chat/ChatView.swift")
let avC = stripComments(av)

check("读得到宠物形象源文件（路径没被挪）", !av.isEmpty)
check("读得到宠物模型源文件（v4.0.6 Quirk 新家）", !pm.isEmpty)
check("读得到宠物设置页源文件", !ps.isEmpty)
check("读得到聊天页源文件（路径没被挪）", !cv.isEmpty)

// MARK: - 1. 走动动作存在且进了随机池
check("Quirk 枚举有踱步动作（strollLeft / strollRight）",
      pmC.contains("case strollLeft") && pmC.contains("case strollRight"))
check("踱步进随机池（不然新动作永远不播，等于白加）",
      pmC.contains(".strollLeft, .strollRight,"))
check("isStroll 判定存在（镜像/颠步都靠它分流）",
      pmC.contains("var isStroll: Bool"))

// MARK: - 2. 位移是真位移（旧四个动作全是 0.0x 幅度，观感「贴着晃」）
check("踱步有真位移（0.145×size ≈ 14pt，非 0 幅度形变）",
      avC.contains("case .some(.strollLeft): return -size * 0.145")
      && avC.contains("case .some(.strollRight): return size * 0.145"))
check("踱步有上下颠步（quirkyBob 纵向起伏）",
      avC.contains("var quirkyBob: CGFloat"))
check("颠步幅度 0.03×size（≈3pt，够看又不夸张）",
      avC.contains("return strollPhase ? -size * 0.03 : 0"))
check("踱步有身体前倾（2.5°，重心前移的身体感）；v4.0.58 起原地踏步共用同一档前倾",
      avC.contains("case .some(.strollLeft), .some(.strollRight), .some(.march): return 2.5"))

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
      avC.contains("case .some(.strollLeft): return -size * 0.145")
      && avC.contains("case .some(.strollRight): return size * 0.145"))
check("镜像：只朝左走时翻（strollLeft→-1 / 其余→1），与位移方向配对",
      avC.contains("current == .strollLeft ? -1.0 : 1.0"))
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
check("playStroll 结束时 quirky 归 nil（回原位）",
      avC.contains("withAnimation(.easeInOut(duration: d * 0.3)) { quirky = nil }"))
check("循环按 isStroll 分流（踱步走四段，其余仍两段）",
      avC.contains("if q.isStroll") && avC.contains("await playStroll(q, duration: d)"))
check("playStroll 每步都重查 animate/取消（后台/减弱时立刻收住）",
      stripComments(avC.components(separatedBy: "func playStroll").last ?? "")
          .components(separatedBy: "guard animate, !Task.isCancelled else { return }").count >= 3)

// MARK: - 5. 🚨 姿态复位：不动时不能卡在抬起
check("animate 变 false 时复位 strollPhase + quirky（否则回前台僵在半抬）",
      avC.contains("strollPhase = false")
      && avC.contains("quirky = nil"))
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
//
// v4.0.0 终解：**透明 overlay 扩边**（不是 inset 形状）。
// 中途试过两种写法都编不过，是当时在猜 API：
//   ① `Rectangle().inset(by: EdgeInsets)` → Rectangle 的 inset(by:) 收 CGFloat；
//   ② `Path(insetBy:)` → 该重载根本不存在。
// 现写法用的都是 iOS 17 起就有的稳定 API，且 overlay 不参与父级布局（撑宽 frame 会挤走旁边文字）。
check("命中域靠透明 overlay 扩边（横向 96+18×2，盖住 14pt 位移）",
      cv.contains("Color.clear") && cv.contains("96 + 18 * 2"))
check("扩边层挂了 contentShape（Color.clear 本身不构成命中形状）",
      cv.contains(".contentShape(Rectangle())"))
// 反向：不再用那两个编不过的写法
check("代码里不再用 Rectangle().inset(by:)（收 CGFloat，编译失败）",
      !stripComments(cv).contains("Rectangle().inset("))
check("代码里不再用 Path(insetBy:)（该重载不存在）",
      !stripComments(cv).contains("Path(insetBy:"))

// MARK: - 7. 旧四动作不得被改坏（v3.9.85 回归）
for (n, v) in [("歪头", "case .some(.headTilt): return 6"), ("张望", "case .some(.lookAround): return -3")] {
    check("旧动作「\(n)」角度未被改坏（\(v)）", avC.contains(v))
}
check("旧动作池里四个老动作都还在",
      pmC.contains("[.headTilt, .lookAround, .happyWiggle, .stretch,"))
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
// v4.0.6：blinkLoop 的 id 仍是 animate；quirkyLoop 的 id 加进了勾选串
// （"\(animate)-\(quirksRaw)"）—— 用户在设置页改勾选必须立刻重挂循环，
// 否则新勾的动作要等下次进聊天页才生效。两条都断言，别让谁把 id 简化回去。
// v4.0.6：blinkLoop 的 id 是 animate；quirkyLoop 的 id 加进了勾选串。
// 断言只钉「quirkyLoop 那行的 id 里同时出现 animate 和 quirksRaw」——
// 不去逐字匹配 `\(...)` 插值写法（那写法每次改格式就假红，护栏会自己变成噪声）。
let quirkTaskLine = av.split(separator: "\n")
    .first { $0.contains("await quirkyLoop()") } ?? ""
check("眨眼循环由 animate 驱动（可被关闭）",
      avC.contains(".task(id: animate) { await blinkLoop() }"))
check("动作循环的 id 同时含 animate 与 quirksRaw（改勾选立刻重挂）",
      quirkTaskLine.contains(".task(id:") && quirkTaskLine.contains("animate")
      && quirkTaskLine.contains("quirksRaw"))
check("动作循环真在跑 quirkyLoop（不是留了个空 task）",
      quirkTaskLine.contains("await quirkyLoop()"))

// MARK: - 9. v4.0.6 常态表情（PetFace）
check("PetFace 枚举存在四张常态脸（calm/happy/sleepy/playful）",
      pmC.contains("case calm") && pmC.contains("case happy")
      && pmC.contains("case sleepy") && pmC.contains("case playful"))
check("表情只作用于 idle（thinking/alert 不被 face 覆盖）",
      // 画师里 face 只出现在 idle 分支的 switch 上
      pa.range(of: "case .idle") != nil
      && !pa.components(separatedBy: "case .thinking").dropFirst().contains(where: { seg in
           let tail = seg.prefix(400)
           return tail.contains("switch face") }))
// 反向红线：表情**不能**新增状态枚举（PetState 仍四态）——状态语义归宿主，宠物只是冗余表达
check("PetState 仍是四态（表情没有混进状态枚举）",
      !pmC.contains("case face") && pmC.contains("case alert"))
check("face 有独立存储 key（PetKeys.face）", pmC.contains("static let face"))
check("ChatView 侧的 painter 调用带上 face", avC.contains("face: face,"))
check("每种形象都接了 face 分支（不能只改液态那只）",
      stripComments(pa).components(separatedBy: "case .idle").count >= 4)

// MARK: - 10. v4.0.6 行为动作多选
check("PetKeys 有 quirks 勾选 key", pmC.contains("static let quirks"))
// 关键语义红线：key 缺失 = 全开（老用户行为不变）；空串 = 全关（用户主动关的）
check("勾选集语义区分「没设过」(全开) 与「空串」(全关)",
      pmC.contains("func enabledQuirks()")
      && pmC.contains("string(forKey:")          // 读原始串：区分「没这个 key」和「空串」
      && pmC.contains("UserDefaults.standard.object(forKey:") == false)
check("PetAvatar 读 quirksRaw 并过滤动作池", avC.contains("@AppStorage(PetKeys.quirks)"))
check("quirky 状态是 Optional（Quirk 里没有 .none）",
      avC.contains("@State private var quirky: Quirk? = nil")
      && !pmC.contains("case none"))
check("全关时彻底不播动作（randomElement 空池直接跳过，不是硬塞一个默认）",
      avC.contains("Quirk.pool.filter { enabledQuirks.contains($0) }")
      && avC.contains("guard let q = pool.randomElement() else { continue }"))

// MARK: - 11. v4.0.6 设置页：大头像 + 表情 + 动作多选 + 外观页不再重复
check("设置页有卡通宠物自定义页", !ps.isEmpty && psC.contains("struct PetStudioSheet"))
check("设置页顶部有宠物大头像入口", sc.contains("petStudioBanner") && sc.contains("showPetStudio = true"))
check("头像直接用 PetAvatar(size:) 画，没套 frame 去缩（v3.9.78 报修口径）",
      sc.contains("PetAvatar(size: 96, state: .idle, keepDetail: true)")
      && !stripComments(sc).contains("PetAvatar(size: 96).frame"))
check("自定义页提供形象/表情/动作/动画四组",
      psC.contains("\"形象\"") && psC.contains("\"常态表情\"")
      && psC.contains("\"行为动作\"") && psC.contains("\"动画\""))
check("行为动作用多选勾选（不是三档）", psC.contains("func quirkToggle") && psC.contains("setAllQuirks"))
// 🚨 手势边界：动作行右侧有「试一下」Button，勾选手势若挂整行会跟它抢点击
// （谁生效取决于 SwiftUI 命中仲裁，不可预期）。钉住：onTapGesture 只挂在左侧勾选块上。
let quirkRowSlice = ps.components(separatedBy: "private func quirkToggle")
    .last?.components(separatedBy: "private func quirkHint").first ?? ""
check("勾选手势只挂在左侧勾选块（不与「试一下」Button 抢点击）",
      quirkRowSlice.contains(".onTapGesture { toggle(q) }")
      && !quirkRowSlice.components(separatedBy: "Spacer(minLength: 0)").last!
        .contains(".onTapGesture"))
check("无障碍用 contain 而非 combine（combine 会把「试一下」吞成一个不可点的元素）",
      quirkRowSlice.contains("accessibilityElement(children: .contain)"))
check("表情缩略图逐张渲染（faceOverride，否则四张脸长得一样）",
      psC.contains("faceOverride: f") && avC.contains("var faceOverride: PetFace?"))
check("配置页与聊天页共用同一组 key（联动靠共享 @AppStorage，不靠通知）",
      psC.contains("@AppStorage(PetKeys.style)") && psC.contains("@AppStorage(PetKeys.face)")
      && psC.contains("@AppStorage(PetKeys.motion)") && psC.contains("@AppStorage(PetKeys.quirks)"))
// 搬迁红线：外观页那两段（形象三选一 + 动画三档）必须已经不在了
check("外观页不再重复「聊天页形象」配置（已搬走，不是复制）",
      !scom.contains("Section(\"聊天页形象\")") && !scom.contains("func petOption"))
check("外观页不再持有宠物 key（避免半联动）",
      !scom.contains("@AppStorage(PetKeys.style)") && !scom.contains("@AppStorage(PetKeys.motion)"))
check("外观页留了搬迁说明注释（防止后来人搬回去）",
      scom.contains("搬去 PetStudioSheet"))

// MARK: - 12. v4.0.6 灵动岛/挂件同步（挂件读不到主 App 的 UserDefaults）
check("ContentState 带 petFace 下发（免费签名无 App Groups）",
      la.contains("var petFace: String"))
check("petFace 刻意不给默认参数（漏传编译不过）",
      stripComments(la).contains("petFace: String)") && !stripComments(la).contains("petFace: String = "))
check("解码有兜底（旧活动缺该键 → 平静脸，身份不断层）",
      la.contains("decodeIfPresent(String.self, forKey: .petFace)"))
check("挂件按 petFace 画 idle 脸", lw.contains("face: face,") && lw.contains("PetFace.from(faceRaw)"))
check("LiveActivityManager 四处下发都带 petFace",
      read("qingliao/Core/LiveActivityManager.swift")
        .components(separatedBy: "petFace: PetFace.current.rawValue").count - 1 == 4)

// MARK: - 13. v4.0.10 思考气泡三点动画概率不启动（同一坑：脉冲必须有 false→true 边沿）
let petAvatarAnimSrc = read("qingliao/Features/Chat/PetAvatar.swift")
check("ThinkingDots 消隐时复位（视图复用后仍有 false→true 边沿）",
      petAvatarAnimSrc.contains(".onDisappear { pulse = false }"))
check("ThinkingDots 出现时置位（与上一行成对，缺一即概率不跳）",
      petAvatarAnimSrc.contains(".onAppear { if animated { pulse = true } }"))
check("不许改用异步翻转（Swift 6 严格并发下闭包捕获 View 编译不过）",
      !petAvatarAnimSrc.contains("DispatchQueue.main.async"))

// MARK: - 14. v4.0.26 手部动作（三只形象都有手 + 5 组手势动作）
//
// 这批的核心风险是**静默失效**：手画了但看不见、动作写了但手瞬移、手僵在半空。
// 每条断言都对应一个真实踩过的坑（首版就翻在「看不见」上）。
let paC = stripComments(pa)
check("手部绘制函数存在", paC.contains("private func hand("))
check("三只形象都调了 hand（下层 3 处 + 身前补画 1 处）",
      paC.components(separatedBy: "hand(&").count - 1 >= 4)
// 🚨 可见性：首版手中心 0.175 紧贴主形边缘 → 只露出 ≈2.6pt，用户反馈「完全没看到手」
check("手基准贴到身体外缘（0.115，而非首版翻车的 0.175）",
      paC.contains("0.115 + h.fold"))
check("手色比身体深一档（同色系 = 隐形）",
      paC.contains("Pal.liquidDeep") && paC.contains("Pal.beastBottom") && paC.contains("Pal.botBottom"))
check("合到身前的手改画在主形之上（否则整只手被圆盖住 → 实测露出 0%）",
      paC.contains("handsInFront"))
check("身前/体侧的判据是手的水平偏移阈值（0.20）", paC.contains("> 0.20"))
// 🚨 姿势必须可插值：否则 withAnimation 只能整块跳变（手「啪」地瞬移）
check("PetHandSide / PetHandPose conform VectorArithmetic",
      pa.contains("extension PetHandSide: VectorArithmetic")
      && pa.contains("extension PetHandPose: VectorArithmetic"))
check("VectorArithmetic 覆盖全部四个分量（漏一个 → 那分量不动，手摆一半卡住）",
      paC.contains("Double(lift * lift + fold * fold + spread * spread + swing * swing)"))
// 动作进池 + 分流
check("5 个手势动作都进随机池",
      pmC.contains(".waveHello, .clap, .heartHands, .cheer, .chinRest]"))
check("isHandAction 判定存在（身体层与手势层的分流依据）",
      pmC.contains("var isHandAction: Bool"))
check("循环按 isHandAction 接力到手部编排",
      avC.contains("} else if q.isHandAction {"))
// 编排完整性
check("五个编排函数都在（挥手/鼓掌/比心/欢呼/托腮）",
      ["playWave", "playClap", "playHeartHands", "playCheer", "playChinRest"]
        .allSatisfy { avC.contains("func \($0)() async") })
check("编排入口按动作分派（playHandAction）",
      avC.contains("func playHandAction(_ q: Quirk) async"))
// 🚨 手不能僵在半空：每条编排末尾都得放回贴身
let handSeg = String(av[av.range(of: "MARK: v4.0.26 手部动作编排")!.lowerBound...])
    .components(separatedBy: "private var decoration")[0]
check("每条编排末尾都把手放回贴身（≥5 次 .rest）",
      handSeg.components(separatedBy: "quirkyHands = .rest").count - 1 >= 5)
check("编排每段都重查 animate/取消（后台/减弱时立刻收住）",
      handSeg.components(separatedBy: "guard animate, !Task.isCancelled else { return }").count >= 5)
if let oc = av.range(of: ".onChange(of: animate)") {
    let seg = String(av[oc.lowerBound...])
    let cut = seg.range(of: ".task(id: animate)")?.lowerBound ?? seg.endIndex
    check("手部复位写在 onChange(of: animate) 的 else 分支（回前台不会看到手悬着）",
          seg[seg.startIndex..<cut].contains("quirkyHands = .rest"))
} else {
    check("存在 onChange(of: animate) 监听", false)
}
// 缩略图与播放必须同一套姿势值，否则设置页和真机对不上
check("有 representativePose（各动作的代表姿势）",
      avC.contains("static func representativePose(_ q: Quirk) -> PetHandPose"))
check("设置页预览走 representativePose（缩略图定格该动作）",
      avC.contains("if let q = quirkPreview { return Self.representativePose(q) }"))
check("Canvas 把手部姿势传进画笔（不传 = 手永远贴身；v4.0.31 尾随 thinkingFace 参数，字面串同步）",
      avC.contains("handPose: currentHandPose,\n                       thinkingFace:"))
check("欢呼的身体配合（缩放 + 蹦）也在（手举起来时身体不能钉在地上）",
      avC.contains("case .some(.cheer): return 1.06") && avC.contains("if q == .cheer { return strollPhase"))

// MARK: - 15. v4.0.31 header 中央宠物按新规格回归（v4.0.28 删除被用户拍板推翻：62pt + 全动作 + 表情映射）
//
// 旧删除护栏已整体反转——同一批护栏不能同时钉「删干净」与「在」，v4.0.28 的 4 条删除断言
// 改写为存在断言；「别误伤其它宠物」方向的断言保留并扩展（欢迎页 petHero 不动、消息头像 30pt 已删是本版需求1）。
let cvC = stripComments(cv)
let lgC = stripComments(read("qingliao/Theme/LiquidGlass.swift"))
let cbC = stripComments(read("qingliao/Features/Chat/ChatMessageBubble.swift"))
let paAC = stripComments(read("qingliao/Features/Chat/PetAvatar.swift"))
let ppC = stripComments(read("qingliao/Features/Chat/PetPainter.swift"))
check("header 中央宠物已回归（petHeaderBadge 在，v4.0.36 起 60pt）",
      cvC.contains("private var petHeaderBadge") && cvC.contains("PetAvatar(size: 60,"))
check("v4.0.36 宠物尺寸旧值清零（62pt 不得残留：同屏只许一处 header 尺寸）",
      !cvC.contains("PetAvatar(size: 62,"))
check("header 宠物 keepDetail 旁路简化阈值（v4.0.32 真机报修「没有手」：60/62<76 会被简化成头+眼+嘴）",
      cvC.contains("keepDetail: true,\n                  thinkingFaceOverride: .sleepy"))
check("ChatView 给 PageHeader 传 centerView（空会话=欢迎页不挂 + 设置里关掉也不挂，v4.0.68）",
      cvC.contains("centerView: (petHeaderOn && !chat.messages.isEmpty) ? AnyView(chatHeaderPet) : nil"))
check("聊天页宠物总开关是单一真源键（PetKeys.headerVisible：设置页开关 + 聊天页渲染共用）",
      pm.contains("static let headerVisible = \"qingliao_pet_header_visible\"")
      && cvC.contains("@AppStorage(PetKeys.headerVisible) private var petHeaderOn = true"))
check("设置页「外观与显示」恒有这颗开关（关掉后从这里还能开回来）",
      sc.contains("title: \"聊天页宠物\",\n                       toggle: $petHeaderOn)"))
check("PageHeader 叠加管道已恢复（LiquidGlass 里 centerView 属性 + overlay 在）",
      lgC.contains("var centerView: AnyView? = nil")
      && lgC.contains(".overlay(alignment: .center) {"))
check("庆祝触发器已回归（petCelebrate + 忙→闲 +1）",
      cvC.contains("@State private var petCelebrate = 0")
      && cvC.contains("if was && !now { petCelebrate += 1 }"))
check("欢迎页身份宠物不受影响（petHero 仍 96pt）",
      cvC.contains("PetAvatar(size: 96,"))
// 反向自证锚：把上一行改成 !contains 即可验证护栏有牙（勿真改，这里注释记录）。
check("表情映射三参数在（方案 A：thinking=sleepy / alert=calm / celebrate=happy）",
      cvC.contains("thinkingFaceOverride: .sleepy")
      && cvC.contains("alertFaceOverride: .calm")
      && cvC.contains("celebrateFace: .happy")
      && paAC.contains("var thinkingFaceOverride: PetFace? = nil")
      && paAC.contains("var alertFaceOverride: PetFace? = nil")
      && paAC.contains("var celebrateFace: PetFace? = nil"))
check("思考托腮 + 出错张望在（PetAvatar 状态映射）",
      paAC.contains("withAnimation(.easeInOut(duration: 0.4)) { quirky = .chinRest }")
      && paAC.contains("playLookAround()"))
check("PetPainter thinking 态吃 thinkingFace（三形态分派在）",
      ppC.contains("var thinkingFace: PetFace? = nil")
      && ppC.components(separatedBy: "thinkingFace == .sleepy").count - 1 == 3
      && paAC.contains("thinkingFace: state == .thinking ? (thinkingFaceOverride ?? face) : nil"))
check("庆祝换脸限时回落在（celebrateFaceActive）",
      paAC.contains("@State private var celebrateFaceActive: PetFace? = nil")
      && paAC.contains("celebrateFaceActive = nil"))

// MARK: - 16. v4.0.31 消息气泡两侧头像已删（用户拍板需求1；思考气泡 38pt 宠物保留）
check("AI 头像计算属性已删（aiAvatar 清零）", !cbC.contains("aiAvatar"))
check("用户头像（渐变圆 Q）已删", !cbC.contains("Text(\"Q\")"))
check("30pt 消息头像全仓清零（46=设置页表情缩略图保留）",
      !stripComments(read("qingliao/Features/Chat/ChatView.swift")).contains("PetAvatar(size: 30")
      && !cbC.contains("PetAvatar(size: 30"))
check("思考气泡 38pt 宠物已删（v4.0.32 用户复看截图拍板：思考期也不留头像，只留三点气泡本体）",
      !stripComments(read("qingliao/Features/Chat/ChatView.swift")).contains("PetAvatar(size: 38"))
check("气泡留白只在对侧：AI 左贴边 / 用户右贴边（内容侧不留 Spacer 12，v4.0.37 用户要求「往左贴到边」）",
      cbC.contains("if message.isUser { Spacer(minLength: 12) }")
      && cbC.contains("if !message.isUser { Spacer(minLength: 12) }"))
check("欢迎页身份宠物仍在（防误伤）", cvC.contains("private var petHero"))

// MARK: - 17. v4.0.37 待机微动作间隔改为 2~5 秒随机（用户拍板）
// 间隔值是「单一真源 + 设置页文案同源」，不是散落的 `Double.random(in:)`：
// 改值时护栏逼红，提醒同步 PetStudioSheet 文案与渲染稿脚本里的旧数字。
check("间隔常量落在 PetMotionTiming.idleQuirkInterval（单一真源）",
      pmC.contains("enum PetMotionTiming")
      && pmC.contains("static let idleQuirkInterval: [Double] = [2, 3, 4, 5]"))
check("quirkyLoop 走该常量取随机间隔，不写裸 random",
      paAC.contains("PetMotionTiming.idleQuirkInterval.randomElement() ?? 3"))
check("旧的 6~14s 间隔已清零",
      !paAC.contains("Double.random(in: 6...14)")
      && !stripComments(read("qingliao/Features/Settings/PetStudioSheet.swift")).contains("6~14"))
check("设置页文案已同步为 2~5 秒",
      stripComments(read("qingliao/Features/Settings/PetStudioSheet.swift")).contains("2~5 秒随机触发"))

// MARK: - 18. v4.0.58 会走路的小脚（用户拍板「给卡通宠物加上会走路的小脚，要能实际走路，踢腿等动作」）
// 三只形象共用一套腿几何：髋点在**身体内部**（y=0.705，三只半径 0.37~0.40 → 下缘 0.87~0.90），
// 腿画在主形之前 → 腿骨上半段被圆身体压住，只露脚掌 + 一小截腿（与手同一条画法）。
// 摆腿 = 髋不动、脚掌走弧线：抬脚 0.042 + 外摆 0.048（≈4.6pt@96pt）落在体外可见区。
// 数值体检（脚掌可见高度/横向步幅/@24·60·96pt）在 scripts/ql_pet/check_leg_geometry.py（段 5d）。
// ⚠️ MARK 是「// 注释」→ stripComments 会把整行洗成空串，所以切片必须切**原始文本**（下面两条 raw），
//    切完再 stripComments 做代码断言。（首版把切片切在 paC 上 → 段是空的 → 6 条假红。）
let paRaw = read("qingliao/Features/Chat/PetPainter.swift")
let avRaw = read("qingliao/Features/Chat/PetAvatar.swift")
let legSeg = paRaw.components(separatedBy: "// MARK: 腿/脚（v4.0.58").count > 1
    ? stripComments(paRaw.components(separatedBy: "// MARK: 腿/脚（v4.0.58")[1].components(separatedBy: "private func soft(")[0])
    : ""
check("腿/脚绘制段落在（PetPainter「腿/脚（v4.0.58」段）", !legSeg.isEmpty && legSeg.contains("private func leg("))
check("三只形象都画了腿（leg 调用 6 处 = 每只形象两只脚）",
      paC.components(separatedBy: "leg(&layer, s, side:").count - 1 >= 6)
let iLegCall = paC.range(of: "leg(&layer, s, side: -1)")
let iShellCall = paC.range(of: "shell(&layer, s, radius: 0.40,")
check("腿画在主形之前（髋关节被圆身体压住 → 与手同一条画法）",
      iLegCall != nil && iShellCall != nil && iLegCall!.lowerBound < iShellCall!.lowerBound)
check("几何常量被钉住（髋 x=±0.085 / 髋 y=0.705 / 站定脚 y=0.960 / 抬脚 0.042）",
      legSeg.contains("let hipX: CGFloat = 0.5 + side * 0.085")
      && legSeg.contains("let hipY: CGFloat = 0.705")
      && legSeg.contains("let stanceY: CGFloat = 0.960")
      && legSeg.contains("let footY = stanceY - CGFloat(liftPhase) * 0.042 - kickAmount * 0.045"))
check("步态相位是 0…1 标量（Double? = 站定；不引入自定义姿势结构，插值发生在 keyframe 之间）",
      paC.contains("var legPhase: Double? = nil") && paC.contains("var kick: Double = 0")
      && paC.contains("var kickSide: CGFloat = -1"))
check("左右腿错半个周期", legSeg.contains("side < 0 ? t : t + 0.5"))
check("抬脚只发生在摆动相（max(0, -sin(ang))：支撑相脚掌贴地不动）",
      legSeg.contains("max(0, -sin(ang))"))
check("腿骨旋转角与脚掌位移共用同一个 dx（防「腿斜着、脚掌却是正的」断腿感）",
      legSeg.contains("let phi = -((dx + pendulum) /"))
check("腿不受 simplify 门控（脚是这一版主角），只有高光/肉垫受门控（防误伤小尺寸）",
      legSeg.contains("guard !simplify else { return }")
      && paC.components(separatedBy: "leg(&layer, s, side:").count - 1 >= 6)
check("三只形象的脚各有形态（liquid 高光 / beast 三颗肉垫 / robot 鞋面条）",
      legSeg.contains("Pal.liquidDeep") && legSeg.contains("Pal.beastEarIn")
      && legSeg.contains("Pal.botTop"))
check("三个腿部动作都进了池（插在中间：头尾字面量被上文两段钉住）",
      pmC.contains(".march, .kick, .kickFlurry,"))
check("isLegAction / isGait 判定存在，且 isGait = 踱步 + 踏步（踏步也要颠步）",
      pmC.contains("var isLegAction: Bool") && pmC.contains("var isGait: Bool { isStroll || self == .march }"))
check("踏步/踢腿/连踢时长单列（不复用踱步 2.2s）",
      pmC.contains("case .march: return 2.0") && pmC.contains("case .kick: return 1.4")
      && pmC.contains("case .kickFlurry: return 2.4"))
check("循环按 isLegAction 接腿部编排（在手部分流之前）", avC.contains("} else if q.isLegAction {"))
check("庆祝兜底也认腿部动作（4 个庆祝动作全关时抽到踢腿不会退化成半截）",
      avC.components(separatedBy: "if q.isLegAction {").count - 1 >= 2)
check("三条编排函数都在（踏步/踢腿/连踢）",
      ["playMarch", "playKick", "playKickFlurry"].allSatisfy { avC.contains("func \($0)() async") })
check("踱步升级为真迈步（4 个半步；同一句里驱动 legPhase）",
      avC.contains("withAnimation(.easeInOut(duration: d * 0.3)) { quirky = q; legPhase = 0 }")
      && avC.contains("withAnimation(.easeInOut(duration: d * 0.1)) { strollPhase = true; legPhase = step }"))
check("踱步结束脚也归位（独立一句 → 真值表钉住的那行字面量没被改坏）",
      avC.contains("withAnimation(.easeInOut(duration: d * 0.3)) { quirky = nil }")
      && avC.contains("withAnimation(.easeInOut(duration: d * 0.3)) { legPhase = nil }"))
let legChoreo = avRaw.components(separatedBy: "// MARK: v4.0.58 腿部动作编排").count > 1
    ? stripComments(avRaw.components(separatedBy: "// MARK: v4.0.58 腿部动作编排")[1].components(separatedBy: "@ViewBuilder")[0])
    : ""
check("腿部编排段在（且插在 decoration 之前，不破坏 @ViewBuilder 归属）",
      !legChoreo.isEmpty && legChoreo.contains("private func playMarch() async"))
check("腿部编排每段都重查 animate/取消（≥6 处，且统一走 legStopRequested() 早退复位）",
      legChoreo.components(separatedBy: "if legStopRequested() { return }").count - 1 >= 6
      && legChoreo.contains("private func legStopRequested() -> Bool")
      && !legChoreo.contains("guard animate, !Task.isCancelled else { return }"))
check("踢腿换边先归零再翻 side（kickSide 插值路过 0 会两条腿同时半踢）",
      legChoreo.contains("legKickSide = side"))
check("踢腿有身体配合（后仰 -4 + 双手张开 0.45 配平）",
      avC.contains("case .some(.kick): return -4") && avC.contains("spread: 0.45"))
check("切后台/关动画时腿复位（legPhase = nil + legKick = 0，防回前台腿僵在半空）",
      avC.contains("legPhase = nil\n                legKick = 0"))
check("腿参数尾随传入 Canvas（挂件靠默认值零改动）",
      avC.contains("legPhase: currentLegPhase,") && avC.contains("kickSide: currentKickSide)"))
check("挂件那条 PetPainter 调用没被腿参数动过（前缀仍与前文 ql_orbmenu 真值表一致）",
      lw.contains("PetPainter(style: style,") && !lw.contains("legPhase:"))
check("设置页三条 hint 都在（加了 case 不补 = 只有 CI Archive 抓得到）",
      psC.contains("case .march: return \"原地抬脚踏步\"")
      && psC.contains("case .kick: return \"抬腿踢一下\"")
      && psC.contains("case .kickFlurry: return \"左右腿连踢三下\""))
check("设置页预览有代表性腿脚姿势（缩略图看得出在迈步/踢腿，不是站定）",
      avC.contains("static func representativeLegs(_ q: Quirk)")
      && avC.contains("case .march, .strollLeft, .strollRight: return (0.25, 0, -1)"))
check("没有为腿引入逐帧驱动（仍是 withAnimation 段间插值，省电红线不变）",
      !avC.contains("TimelineView") && !avC.contains("CADisplayLink"))

report()
