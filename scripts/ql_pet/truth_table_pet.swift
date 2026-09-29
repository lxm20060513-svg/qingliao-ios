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
      pmC.contains(".strollLeft, .strollRight]"))
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
check("踱步有身体前倾（2.5°，重心前移的身体感）",
      avC.contains("case .some(.strollLeft), .some(.strollRight): return 2.5"))

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

report()
